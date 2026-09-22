#!/usr/bin/env bash
# graphe.sh — compile todo.md en graphe.json (dependances + exclusions), detecte les cycles.
# Usage : graphe.sh [--dry-run] [--verifier-seulement] [manifeste]
#         graphe.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
MANIFESTE="$ROOT/todo.md"
DRY_RUN=0
VERIFIER_SEULEMENT=0

show_help() {
  cat <<'EOF'
Usage:
  graphe.sh [--dry-run] [--verifier-seulement] [manifeste]
  graphe.sh --help

Produit .orchestrator/etat/graphe.json a partir de todo.md.
Le graphe contient : noeuds, aretes, cycles, eligibles, suspendues.
Sortie : 0 si compilation OK, 3 si cycle detecte, 4 si manifeste invalide.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verifier-seulement) VERIFIER_SEULEMENT=1; shift ;;
    *) MANIFESTE="$1"; shift ;;
  esac
done

SORTIE="$ETAT_DIR/graphe.json"
MATRICE="$ROOT/orchestrator/matrice.json"
mkdir -p "$ETAT_DIR" "$ETAT_DIR/taches"
require python3 sha256sum
[[ -f "$MANIFESTE" ]] || die "manifeste introuvable : $MANIFESTE"

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN] manifeste=%s\n' "$MANIFESTE"
  printf '[DRY-RUN] sortie=%s\n' "$SORTIE"
  printf '[DRY-RUN] verifier_seulement=%s\n' "$VERIFIER_SEULEMENT"
fi

SHA="$(sha256sum "$MANIFESTE" | awk '{print $1}')"

python3 - "$MANIFESTE" "$SORTIE" "$SHA" "$ETAT_DIR" "$VERIFIER_SEULEMENT" "$MATRICE" <<'PY'
import json, os, re, sys, datetime

manifeste, sortie, sha, etat_dir, verifier, matrice_path = sys.argv[1:7]
verifier = verifier == '1'
allowed_priorites = {'P1', 'P2', 'P3', 'P4'}
line_re = re.compile(r'^- \[[ x]\] ')
id_re = re.compile(r'^T-[0-9]{3,}$')
noeuds = {}
errors = []
raw_entries = []

with open(manifeste, encoding='utf-8') as fh:
    for lineno, brut in enumerate(fh, start=1):
        line = brut.rstrip('\n')
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        if not line_re.match(s):
            continue
        parts = [p.strip() for p in s.split('|')]
        if len(parts) < 5:
            errors.append(f'ligne {lineno}: nombre de champs insuffisant ({len(parts)})')
            continue
        ident = re.sub(r'^- \[[ x]\] ', '', parts[0]).strip()
        prio, perim, critere, gates = parts[1:5]
        extras = parts[5:]
        if not id_re.match(ident):
            errors.append(f'ligne {lineno}: identifiant invalide: {ident}')
        if prio not in allowed_priorites:
            errors.append(f'ligne {lineno}: priorite invalide: {prio}')
        if not perim:
            errors.append(f'ligne {lineno}: perimetre vide')
        if not critere:
            errors.append(f'ligne {lineno}: critere vide')
        if not gates:
            errors.append(f'ligne {lineno}: gates vide')
        deps = ''
        conflits = ''
        for extra in extras:
            if not extra:
                continue
            if extra.startswith('deps:'):
                deps = extra[len('deps:'):]
            elif extra.startswith('conflit:'):
                conflits = extra[len('conflit:'):]
            else:
                champ = extra.split(':', 1)[0]
                errors.append(f'ligne {lineno}: champ inconnu: {champ}')
        if ident in noeuds:
            errors.append(f'ligne {lineno}: doublon d identifiant: {ident}')
        raw_entries.append((lineno, ident, prio, perim, critere, gates, deps, conflits))
        noeuds[ident] = {
            'etat': 'PENDING',
            'priorite': prio,
            'perimetre': [p.strip() for p in perim.split(',') if p.strip()],
            'critere': critere,
            'gates': gates,
            'deps': [d.strip() for d in deps.split(',') if d.strip()],
            'conflits': [c.strip() for c in conflits.split(',') if c.strip()],
            'tentatives': 0,
        }

# validation des dependances et conflits apres lecture complete
lower_map = {k.lower(): k for k in noeuds}
for lineno, ident, _, _, _, _, _, _ in raw_entries:
    n = noeuds.get(ident, {})
    for dep in n.get('deps', []):
        if dep in noeuds:
            continue
        if dep.lower() in lower_map:
            errors.append(f'ligne {lineno}: casse divergente: {dep}')
        else:
            errors.append(f'ligne {lineno}: dependance inconnue: {dep}')
    for conflit in n.get('conflits', []):
        if conflit in noeuds:
            continue
        if conflit.lower() in lower_map:
            errors.append(f'ligne {lineno}: casse divergente: {conflit}')
        else:
            errors.append(f'ligne {lineno}: conflit inconnu: {conflit}')

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(4)

# reprise de l'etat courant si un .env existe deja
et_dir = os.path.join(etat_dir, 'taches')
if os.path.isdir(et_dir):
    for f in os.listdir(et_dir):
        if not f.endswith('.env'):
            continue
        tid = f[:-4]
        if tid not in noeuds:
            continue
        for l in open(os.path.join(et_dir, f), encoding='utf-8'):
            if '=' not in l:
                continue
            k, v = l.rstrip('\n').split('=', 1)
            if k == 'etat':
                noeuds[tid]['etat'] = v
            elif k == 'tentatives':
                try:
                    noeuds[tid]['tentatives'] = int(v or 0)
                except ValueError:
                    noeuds[tid]['tentatives'] = 0

aretes = []
for tid, n in noeuds.items():
    for d in n['deps']:
        aretes.append({'de': d, 'vers': tid, 'type': 'dependance', 'condition': f'{d}.etat == DONE'})

def prefixe(p):
    return p[:-3] if p.endswith('/**') else p.rstrip('/')

def recouvre(a, b):
    pa, pb = prefixe(a), prefixe(b)
    return pa == pb or pa.startswith(pb + '/') or pb.startswith(pa + '/')

for tid, n in noeuds.items():
    for autre, m in noeuds.items():
        if tid >= autre:
            continue
        if autre in n['conflits'] or tid in m['conflits']:
            aretes.append({'de': tid, 'vers': autre, 'type': 'exclusion', 'condition': f'non ({tid}.etat in [RUNNING, REVIEWED, PUBLISHED])'})
            continue
        conflict_found = False
        for pa in n['perimetre']:
            for pb in m['perimetre']:
                if recouvre(pa, pb):
                    aretes.append({'de': tid, 'vers': autre, 'type': 'exclusion', 'condition': f'non ({tid}.etat in [RUNNING, REVIEWED, PUBLISHED])'})
                    conflict_found = True
                    break
            if conflict_found:
                break

adj = {t: [a['vers'] for a in aretes if a['type'] == 'dependance' and a['de'] == t] for t in noeuds}
degre = {t: 0 for t in noeuds}
for _, succ in adj.items():
    for s in succ:
        degre[s] += 1
file = sorted([t for t in noeuds if degre[t] == 0])
vus = 0
while file:
    t = file.pop(0)
    vus += 1
    for s in adj[t]:
        degre[s] -= 1
        if degre[s] == 0:
            file.append(s)
cycles = [t for t in noeuds if degre[t] > 0] if vus != len(noeuds) else []

suspendues, eligibles = [], []
for t, n in noeuds.items():
    if n['etat'] in ('DONE', 'FAILED'):
        continue
    deps_satisfaites = all(noeuds[d]['etat'] == 'DONE' for d in n['deps'])
    if not deps_satisfaites:
        suspendues.append(t)
    elif n['etat'] in ('PENDING', 'READY'):
        eligibles.append(t)

graphe = {
    'schema_version': '4.0',
    'compile_le': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'manifeste_sha256': sha,
    'noeuds': noeuds,
    'aretes': aretes,
    'cycles': cycles,
    'suspendues': sorted(suspendues),
    'eligibles': sorted(eligibles),
}

# machine a etats (Phase 5 / P3-a) : propagee depuis matrice.json si presente.
# Tout etat reference dans les transitions doit etre declare ; sinon rc 4.
machine = None
if os.path.exists(matrice_path):
    try:
        with open(matrice_path, encoding='utf-8') as fh:
            machine = json.load(fh).get('machine_etats')
    except Exception as exc:
        print(f'matrice illisible : {exc}', file=sys.stderr)
        sys.exit(4)
if machine:
    etats_declares = set(machine.get('etats', []))
    merrs = []
    for src, dsts in (machine.get('transitions') or {}).items():
        if src not in etats_declares:
            merrs.append(f'machine_etats : etat source inconnu : {src}')
        for d in dsts:
            if d not in etats_declares:
                merrs.append(f'machine_etats : etat cible inconnu : {d}')
    for e in merrs:
        print(e, file=sys.stderr)
    if merrs:
        sys.exit(4)
    graphe['machine_etats'] = machine

if not verifier:
    with open(sortie, 'w', encoding='utf-8') as f:
        json.dump(graphe, f, ensure_ascii=False, indent=2)

if cycles:
    print(f"CYCLE DETECTE : {' -> '.join(cycles)}", file=sys.stderr)
    sys.exit(3)
print(f"graphe compile : {len(noeuds)} taches, {len(aretes)} aretes, {len(eligibles)} eligibles, {len(suspendues)} suspendues")
PY
