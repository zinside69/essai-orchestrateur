#!/usr/bin/env bash
# couts.sh — agrege le cout et les tokens des agents, par tache et au total.
# Usage : couts.sh [--jours 7] [--format markdown|json|tsv]
#         couts.sh --help
#
# (2026-09-22, essai de publication, defaut 7) Source : journal/couts.jsonl, une
# ligne par appel a claude (journaliser_cout, lib.sh). Etat courant des taches :
# etat/taches/*.env ; verdict : derniere decision de journal/decisions.jsonl.
# Seuils d'alerte : bloc « couts » de orchestrator/matrice.json — alerte
# seulement, aucun agent n'est arrete. Appele par tableau-de-bord.sh et
# dashboard-web.sh. Tests N5 et N6.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

JOURS=7
FORMAT=markdown
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
    --jours) JOURS="${2:?valeur manquante pour --jours}"; shift 2 ;;
    --format) FORMAT="${2:?valeur manquante pour --format}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done
[[ "$JOURS" =~ ^[0-9]+$ ]] || die "--jours attend un entier : $JOURS"

require jq python3
COUTS_J="$ORCH_DIR/journal/couts.jsonl"
DEC="$ORCH_DIR/journal/decisions.jsonl"
TACHES="$ORCH_DIR/etat/taches"
M="$ROOT/orchestrator/matrice.json"
# (2026-09-24) Meme date de reference que tableau-de-bord.sh (ORCH_AUJOURDHUI).
# AVANT : DEPUIS="$(date -u -d "-${JOURS} days" +%FT%TZ)"
DEPUIS="$(date -u -d "${ORCH_AUJOURDHUI:-now} -${JOURS} days" +%FT%TZ)"

AGREGAT="$(python3 - "$COUTS_J" "$DEC" "$TACHES" "$M" "$DEPUIS" "$JOURS" <<'PY'
import json, os, sys

couts_p, dec_p, taches_p, matrice_p, depuis, jours = sys.argv[1:7]

def jsonl(p):
    lignes = []
    if os.path.exists(p):
        for l in open(p, encoding='utf-8'):
            l = l.strip()
            if l:
                try:
                    lignes.append(json.loads(l))
                except ValueError:
                    pass
    return lignes

def nombre(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0

# Seuils par defaut = ceux livres dans matrice.json.
seuils = {'tache_ambre_usd': 1.0, 'tache_rouge_usd': 3.0,
          'jour_ambre_usd': 10.0, 'jour_rouge_usd': 25.0}
if os.path.exists(matrice_p):
    bloc = json.load(open(matrice_p, encoding='utf-8')).get('couts', {})
    seuils.update({k: float(v) for k, v in bloc.items() if k in seuils})

# (2026-09-28, O49) Tarifs de reference (matrice.json, couts.prix_reference) :
# le cout annonce de chaque appel est confronte au cout attendu ; un appel a
# plusieurs modeles, ou a un modele absent de la table, n'est pas juge. Test MD4.
prix, ecart_max = {}, 0.15
if os.path.exists(matrice_p):
    bloc_prix = json.load(open(matrice_p, encoding='utf-8')).get('couts', {})
    prix = bloc_prix.get('prix_reference', {}) or {}
    ecart_max = float(bloc_prix.get('ecart_prix_max', 0.15))

def alerte(v, ambre, rouge):
    return 'ROUGE' if v >= rouge else ('AMBRE' if v >= ambre else 'VERT')

# Etat courant et verdict de chaque tache.
etats = {}
if os.path.isdir(taches_p):
    for n in os.listdir(taches_p):
        if n.endswith('.env'):
            for l in open(os.path.join(taches_p, n), encoding='utf-8'):
                if l.startswith('etat='):
                    etats[n[:-4]] = l.strip().split('=', 1)[1]
verdicts = {}
for d in jsonl(dec_p):
    if d.get('tache'):
        verdicts[d['tache']] = d.get('verdict') or 'aucun'

# Les horodatages sont en ISO UTC : la comparaison de chaines suffit.
lignes = [l for l in jsonl(couts_p) if str(l.get('ts', '')) >= depuis]

CLES_TOKENS = ('entree', 'cache_lu', 'cache_ecrit', 'sortie', 'reflexion')
def tokens_vides():
    return {k: 0 for k in CLES_TOKENS}

par_tache, par_jour = {}, {}
tot_tokens = tokens_vides()
for l in lignes:
    t = l.get('tache', '?')
    e = par_tache.setdefault(t, {'tache': t, 'auteur_usd': 0.0, 'relecteur_usd': 0.0,
                                 'appels': 0, 'mesures_absentes': 0, 'tours': 0,
                                 'duree_s': 0.0, 'tokens': tokens_vides(), 'modeles': set()})
    c = nombre(l.get('cout_usd'))
    e['relecteur_usd' if l.get('role') == 'relecteur' else 'auteur_usd'] += c
    e['appels'] += 1
    e['mesures_absentes'] += 1 if l.get('mesure') != 'ok' else 0
    e['tours'] += int(nombre(l.get('tours')))
    e['duree_s'] += nombre(l.get('duree_ms')) / 1000.0
    for k in CLES_TOKENS:
        v = int(nombre((l.get('tokens') or {}).get(k)))
        e['tokens'][k] += v
        tot_tokens[k] += v
    e['modeles'].update(l.get('modeles') or [])
    jour = str(l.get('ts', ''))[:10]
    par_jour[jour] = par_jour.get(jour, 0.0) + c

# (2026-09-28, O49) Cout annonce contre cout attendu au tarif de reference.
ecarts_prix, non_juges = [], 0
for l in lignes:
    if l.get('mesure') != 'ok':
        continue
    m = l.get('modeles') or []
    if len(m) != 1 or m[0] not in prix:
        non_juges += 1
        continue
    tk = l.get('tokens') or {}
    attendu = sum(nombre(tk.get(k)) * nombre(prix[m[0]].get(k))
                  for k in ('entree', 'cache_lu', 'cache_ecrit', 'sortie')) / 1e6
    annonce = nombre(l.get('cout_usd'))
    if attendu > 0 and abs(annonce - attendu) / attendu > ecart_max:
        ecarts_prix.append({'tache': l.get('tache', '?'), 'role': l.get('role', '?'), 'modele': m[0],
                            'annonce_usd': round(annonce, 6), 'attendu_usd': round(attendu, 6),
                            'ecart_pct': round(100 * (annonce - attendu) / attendu, 1)})

# Une tache qui a depense sans rien livrer : ni DONE ni PUBLISHED, et pas en cours.
SANS_RESULTAT = ('RED', 'FAILED', 'PARKED', 'BLOCKED', 'ESCALATED')
taches, par_verdict = [], {}
for t in sorted(par_tache):
    e = par_tache[t]
    e['total_usd'] = round(e['auteur_usd'] + e['relecteur_usd'], 6)
    e['auteur_usd'] = round(e['auteur_usd'], 6)
    e['relecteur_usd'] = round(e['relecteur_usd'], 6)
    e['duree_s'] = round(e['duree_s'], 1)
    e['modeles'] = sorted(e['modeles'])
    e['etat'] = etats.get(t, '-')
    e['verdict'] = verdicts.get(t, 'aucun')
    e['alerte'] = alerte(e['total_usd'], seuils['tache_ambre_usd'], seuils['tache_rouge_usd'])
    par_verdict[e['verdict']] = round(par_verdict.get(e['verdict'], 0.0) + e['total_usd'], 6)
    taches.append(e)

total = round(sum(e['total_usd'] for e in taches), 6)
entree_totale = tot_tokens['entree'] + tot_tokens['cache_lu'] + tot_tokens['cache_ecrit']
jour_max = max(par_jour.items(), key=lambda kv: kv[1]) if par_jour else ('-', 0.0)
out = {
    'periode_jours': int(jours),
    'depuis': depuis,
    'seuils': seuils,
    'totaux': {
        'cout_usd': total,
        'auteur_usd': round(sum(e['auteur_usd'] for e in taches), 6),
        'relecteur_usd': round(sum(e['relecteur_usd'] for e in taches), 6),
        'appels': sum(e['appels'] for e in taches),
        'mesures_absentes': sum(e['mesures_absentes'] for e in taches),
        'tokens': tot_tokens,
        'part_cache_lu': round(tot_tokens['cache_lu'] / entree_totale, 3) if entree_totale else 0.0,
        'cout_sans_resultat_usd': round(sum(e['total_usd'] for e in taches if e['etat'] in SANS_RESULTAT), 6),
        'cout_par_verdict': par_verdict,
        'cout_max_jour': {'jour': jour_max[0], 'usd': round(jour_max[1], 6)},
        'alerte_jour': alerte(jour_max[1], seuils['jour_ambre_usd'], seuils['jour_rouge_usd']),
        'base': sorted({str(l.get('base')) for l in lignes if l.get('base')}),
    },
    'prix': {'ecart_max': ecart_max, 'ecarts': ecarts_prix, 'non_juges': non_juges},
    'taches': taches,
}
print(json.dumps(out, ensure_ascii=False))
PY
)"

# Montants a 2 decimales, tokens en milliers : ce que lit un humain.
case "$FORMAT" in
  json)
    printf '%s\n' "$AGREGAT"
    ;;
  tsv)
    jq -r '"tache\tetat\tverdict\tauteur_usd\trelecteur_usd\ttotal_usd\ttours\tduree_s\tentree\tcache_lu\tsortie\tmodeles\talerte",
           (.taches[] | [.tache, .etat, .verdict, .auteur_usd, .relecteur_usd, .total_usd, .tours, .duree_s,
                         .tokens.entree, .tokens.cache_lu, .tokens.sortie, (.modeles | join(",")), .alerte] | @tsv)' <<<"$AGREGAT"
    ;;
  markdown)
    jq -r '
      def usd: . * 100 | round / 100 | tostring | if test("\\.") then . else . + ".0" end | . + " $";
      def kt: if . >= 1000 then (. / 1000 | round | tostring) + " k" else tostring end;
      .totaux as $t |
      "## Couts et tokens — \(.periode_jours) derniers jours",
      "",
      "| Indicateur | Valeur | Alerte |",
      "|---|---|---|",
      "| Cout total (auteur / relecteur) | \($t.cout_usd | usd) (\($t.auteur_usd | usd) / \($t.relecteur_usd | usd)) | - |",
      "| Appels a claude (mesures absentes) | \($t.appels) (\($t.mesures_absentes)) | - |",
      "| Jour le plus cher | \($t.cout_max_jour.jour) : \($t.cout_max_jour.usd | usd) | \($t.alerte_jour) |",
      "| Cout des taches sans resultat | \($t.cout_sans_resultat_usd | usd) | - |",
      "| Part du cache dans les tokens d entree | \($t.part_cache_lu * 100 | round) % | - |",
      "| Cout par verdict | \($t.cout_par_verdict | to_entries | map("\(.key) \(.value | usd)") | join(", ") | if . == "" then "-" else . end) | - |",
      "| Cout incoherent avec le tarif de reference (ecart > \(.prix.ecart_max * 100 | round) %) | \(.prix.ecarts | length) appel(s) ; \(.prix.non_juges) non juge(s) | \(if (.prix.ecarts | length) > 0 then "ROUGE" else "VERT" end) |",
      (.prix.ecarts[] | "| ↳ \(.tache) \(.role) \(.modele) | annonce \(.annonce_usd | usd), attendu \(.attendu_usd | usd) (\(.ecart_pct) %) | ROUGE |"),
      "",
      "Seuils par tache : ambre \(.seuils.tache_ambre_usd | usd), rouge \(.seuils.tache_rouge_usd | usd) ; par jour : ambre \(.seuils.jour_ambre_usd | usd), rouge \(.seuils.jour_rouge_usd | usd). Tarif public calcule par Claude Code (base : \($t.base | join(",") | if . == "" then "-" else . end)).",
      "",
      "| Tache | Etat | Verdict | Auteur | Relecteur | Total | Tours | Duree | Entree (dont cache) | Sortie | Modeles | Alerte |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|",
      (.taches[] | "| \(.tache) | \(.etat) | \(.verdict) | \(.auteur_usd | usd) | \(.relecteur_usd | usd) | \(.total_usd | usd) | \(.tours) | \(.duree_s) s | \((.tokens.entree + .tokens.cache_lu + .tokens.cache_ecrit) | kt) (\(.tokens.cache_lu | kt)) | \(.tokens.sortie | kt) | \(.modeles | join(", ")) | \(.alerte) |")
    ' <<<"$AGREGAT"
    ;;
  *)
    die "format inconnu : $FORMAT"
    ;;
esac
