#!/usr/bin/env bash
# suivi-socle.sh — regenere la page de suivi du socle depuis la specification et git.
# Usage : suivi-socle.sh [--format html|json] [--projet <dossier>] [--jours 3650] > page.html
#         suivi-socle.sh --help
#
# (2026-09-23) La page de suivi etait tenue a la main a chaque checkpoint : ses
# chiffres divergeaient du depot des le commit suivant. Tout vient desormais
# d'une source versionnee, lue sans rien executer :
#   - defauts ouverts et resolus   <- tableau du chapitre 7 (`| Oxx |`, `| ✅ Oxx |`)
#   - defauts corriges (total)     <- plus haut numero du tableau du chapitre 6
#   - defauts corriges par version <- lignes `_Version …_` du chapitre 0
#     (« defauts 32 a 37 », « defauts 27 et 28 », « defaut 45 », « 26e defaut ») ;
#     les numeros qu'aucune ligne ne cite reviennent a la premiere version 3.x
#   - controles par version        <- lignes `printf 'X1 OK` de tests/run-phase4.sh,
#     comptees a chaque commit (git log), JAMAIS en lancant les tests
#   - feuille de route, verdict, priorites <- docs/feuille-de-route.md
#   - couts (facultatif)           <- couts.sh --format json du projet --projet
# Gabarit : docs/suivi/gabarit.html ; le script y remplace `/*DONNEES*/null` par
# le JSON, la page se dessine seule. Publication : hors du script (Artifact).
# Tests V1 a V3 (run-phase4.sh).
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

FORMAT=html
# AVANT : PROJET=""
#   (2026-09-28) --projet se repete (un par projet orchestre), voir plus bas. Test V7.
PROJETS=()
JOURS=3650
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) sed -n '2,3p' "$0" | sed 's/^# //'; exit 0 ;;
    --format) FORMAT="${2:?valeur manquante pour --format}"; shift 2 ;;
    # AVANT :     --projet) PROJET="${2:?valeur manquante pour --projet}"; shift 2 ;;
    --projet) PROJETS+=("${2:?valeur manquante pour --projet}"); shift 2 ;;
    --jours) JOURS="${2:?valeur manquante pour --jours}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done
[[ "$FORMAT" == html || "$FORMAT" == json ]] || die "format inconnu : $FORMAT"
[[ "$JOURS" =~ ^[0-9]+$ ]] || die "--jours attend un entier : $JOURS"

require git python3
# (2026-09-28) jq fusionne les couts de plusieurs projets (--projet repete).
require jq
CHAP="$ROOT/docs/specification/chapitres"
PRES="docs/specification/chapitres/00-presentation.md"
P4="tests/run-phase4.sh"
FDR="$ROOT/docs/feuille-de-route.md"
GABARIT="$ROOT/docs/suivi/gabarit.html"
for f in "$CHAP/00-presentation.md" "$CHAP/06-defauts-corriges.md" "$CHAP/07-ouverts.md" "$ROOT/$P4" "$FDR"; do
  [[ -f "$f" ]] || die "source absente : $f"
done
[[ "$FORMAT" == json || -f "$GABARIT" ]] || die "gabarit absent : $GABARIT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Compte des controles : une ligne `printf 'X1 OK\n'` par controle de run-phase4.
compter_controles() { grep -cE "^[[:space:]]*printf '[A-Z]+[0-9]+[a-z]? OK" || true; }
derniere_version() { grep -oE '^_Version [0-9]+\.[0-9]+' | tail -1 | sed 's/^_Version //' || true; }

# Historique : une ligne « version<TAB>controles<TAB>commit<TAB>date » par commit
# qui touche run-phase4 ou le chapitre 0, du plus recent au plus ancien. L'etat
# du disque passe en tete (commit « disque ») : la page suit le travail en cours.
{
  # (2026-09-26, O32 — appele O28 dans le todo : le O28 du chap. 7 est le controle E2E) La ligne « disque » ne sert que s'il y a du travail non commite dans les deux
  # fichiers dont elle tire ses valeurs. Sur un depot propre elle faisait dire a l'info-bulle
  # « modifications non commitees » et masquait le vrai commit et sa date. Si git status echoue
  # (ex. dubious ownership), on la garde : mieux vaut l'ancien comportement qu'une page qui n'a
  # rien lu (V3). Test V6.
  # AVANT : printf '%s\t%s\tdisque\t%s\n' "$(derniere_version <"$ROOT/$PRES")" \
  # AVANT :   "$(compter_controles <"$ROOT/$P4")" "$(date +%F)"
  if ! ETAT_GIT="$(git -C "$ROOT" status --porcelain -- "$P4" "$PRES" 2>/dev/null)" || [[ -n "$ETAT_GIT" ]]; then
    printf '%s\t%s\tdisque\t%s\n' "$(derniere_version <"$ROOT/$PRES")" \
      "$(compter_controles <"$ROOT/$P4")" "$(date +%F)"
  fi
  git -C "$ROOT" log --format='%h %cs' -- "$P4" "$PRES" | while read -r h d; do
    # Un commit anterieur au chapitre 0 (ou a run-phase4) n'a pas le fichier :
    # git show echoue, la ligne est ignoree — sans `|| true`, set -e sortait muet.
    v="$(git -C "$ROOT" show "$h:$PRES" 2>/dev/null | derniere_version || true)"
    n="$(git -C "$ROOT" show "$h:$P4" 2>/dev/null | compter_controles || true)"
    if [[ -n "$v" && -n "$n" ]]; then printf '%s\t%s\t%s\t%s\n' "$v" "$n" "$h" "$d"; fi
  done
} >"$TMP/historique.tsv"

printf '{}' >"$TMP/couts.json"
# AVANT : if [[ -n "$PROJET" ]]; then
# AVANT :   [[ -d "$PROJET/.orchestrator" ]] || die "--projet : pas de .orchestrator dans $PROJET"
# AVANT :   # ROOT et ORCH_STATE sont exportes par lib.sh : couts.sh doit lire le projet,
# AVANT :   # pas le socle.
# AVANT :   env -u ORCH_STATE ROOT="$(cd "$PROJET" && pwd)" \
# AVANT :     "$ROOT/orchestrator/couts.sh" --format json --jours "$JOURS" >"$TMP/couts.json" \
# AVANT :     || die "--projet : couts.sh a echoue dans $PROJET"
# AVANT : fi
#   (2026-09-28) --projet se repete : les couts de TOUS les projets orchestres
#   sont additionnes. La page ne montrait qu'un projet, celui d'essai du 23/09
#   (4,15 $), alors que le ticket 05 d'iziGSM en avait coute 66,76. Chaque tache
#   porte le nom de son projet (les numeros T-NNN se repetent d'un projet a
#   l'autre). Avec plusieurs projets, les totaux qui ne s'additionnent pas (cout
#   par verdict, jour le plus cher) sont retires plutot que faux. Test V7.
if (( ${#PROJETS[@]} > 0 )); then
  for P in "${PROJETS[@]}"; do
    [[ -d "$P/.orchestrator" ]] || die "--projet : pas de .orchestrator dans $P"
    # ROOT et ORCH_STATE sont exportes par lib.sh : couts.sh doit lire le projet,
    # pas le socle.
    env -u ORCH_STATE ROOT="$(cd "$P" && pwd)" \
      "$ROOT/orchestrator/couts.sh" --format json --jours "$JOURS" \
      | jq -c --arg p "$(basename "$(cd "$P" && pwd)")" '. + {projet: $p} | .taches |= map(. + {projet: $p})' \
      >>"$TMP/couts-projets.jsonl" \
      || die "--projet : couts.sh a echoue dans $P"
  done
  jq -s '
    def somme(f): map(f // 0) | add;
    if length == 1 then .[0] + {projets: [.[0].projet]} else
    .[0] + {
      projets: map(.projet),
      totaux: ((.[0].totaux + {
                 cout_usd: somme(.totaux.cout_usd), auteur_usd: somme(.totaux.auteur_usd),
                 relecteur_usd: somme(.totaux.relecteur_usd), appels: somme(.totaux.appels),
                 mesures_absentes: somme(.totaux.mesures_absentes),
                 cout_sans_resultat_usd: somme(.totaux.cout_sans_resultat_usd),
                 tokens: (map(.totaux.tokens // {}) | reduce .[] as $t ({}; reduce ($t | keys[]) as $k (.; .[$k] += $t[$k])))})
               | .part_cache_lu = (((.tokens.entree // 0) + (.tokens.cache_lu // 0) + (.tokens.cache_ecrit // 0)) as $e
                                   | if $e > 0 then ((.tokens.cache_lu // 0) / $e * 1000 | round / 1000) else 0 end)
               | del(.cout_par_verdict, .cout_max_jour, .alerte_jour)),
      prix: {ecart_max: .[0].prix.ecart_max, ecarts: (map(.prix.ecarts // []) | add), non_juges: somme(.prix.non_juges)},
      taches: (map(.taches) | add)
    } end' "$TMP/couts-projets.jsonl" >"$TMP/couts.json"
fi

SCRIPTS="$(git -C "$ROOT" ls-files '*.sh' .githooks/pre-push | wc -l | tr -d ' ')"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf '-')"

DONNEES="$(python3 - "$CHAP" "$FDR" "$TMP/historique.tsv" "$TMP/couts.json" "$SCRIPTS" "$COMMIT" <<'PY'
import datetime, html, json, re, sys

chap, fdr_p, hist_p, couts_p, scripts, commit = sys.argv[1:7]

def lire(p):
    with open(p, encoding='utf-8') as f:
        return f.read()

def md(s):
    """Markdown en ligne -> HTML : echappement, `code`, **gras**, \\| de tableau."""
    s = html.escape(s.replace('\\|', '|').strip(), quote=False)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    return re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', s)

def cellules(ligne):
    """Cellules d'une ligne de tableau markdown ; un \\| n'est pas un separateur."""
    return [c.strip() for c in re.split(r'(?<!\\)\|', ligne.strip())[1:-1]]

def version_cle(v):
    return tuple(int(x) for x in v.split('.'))

# Chapitre 6 : total des defauts corriges = plus haut numero du tableau.
numeros = [int(m) for m in re.findall(r'^\| (\d+) \|', lire(chap + '/06-defauts-corriges.md'), re.M)]
total = max(numeros) if numeros else 0

# Chapitre 0 : versions 3.x et defauts qu'elles citent.
versions = []
for v, date, texte in re.findall(r'^_Version (\d+\.\d+) — (\S+) — (.*)_$', lire(chap + '/00-presentation.md'), re.M):
    if version_cle(v) < (3, 0):
        continue
    cites = set()
    for a, b in re.findall(r'défauts (\d+) à (\d+)', texte):
        cites.update(range(int(a), int(b) + 1))
    for a, b in re.findall(r'défauts (\d+) et (\d+)', texte):
        cites.update((int(a), int(b)))
    # (2026-09-24) Liste a virgules : « defauts 58, 59 et 60 » (ligne v3.25). Sans
    # ce motif, les trois numeros echouaient a la v3.0 et la v3.25 affichait 0. Test V4.
    for liste in re.findall(r'défauts ((?:\d+, )+\d+ et \d+)', texte):
        cites.update(int(n) for n in re.findall(r'\d+', liste))
    cites.update(int(n) for n in re.findall(r'défaut (\d+)', texte))
    cites.update(int(n) for n in re.findall(r'(\d+)e défaut', texte))
    versions.append({'version': v, 'date': date, 'numeros': sorted(n for n in cites if 1 <= n <= total)})
# (2026-09-24) Un defaut appartient a la PREMIERE version qui le cite : une ligne
# posterieure peut le rappeler (la v3.26 cite en exemple « defauts 58, 59 et 60 »),
# sans qu'il soit compte deux fois. Les versions sont dans l'ordre du chapitre 0. Test V5.
deja = set()
for x in versions:
    x['numeros'] = [n for n in x['numeros'] if n not in deja]
    deja.update(x['numeros'])
attribues = {n for x in versions for n in x['numeros']}
if versions:
    versions[0]['numeros'] = sorted(set(versions[0]['numeros']) | (set(range(1, total + 1)) - attribues))
for x in versions:
    x['nombre'] = len(x['numeros'])

# Chapitre 7 : ouverts et resolus. Un code peut revenir (O7 reproduit) : ses
# constats s'ajoutent. Un code marque ✅ n'est plus ouvert, meme cite plus haut.
ouverts, resolus = {}, {}
for ligne in lire(chap + '/07-ouverts.md').splitlines():
    m = re.match(r'^\| (✅ )?(O\d+) \|', ligne)
    if not m:
        continue
    c = cellules(ligne)
    if m.group(1):
        v = re.search(r'Résolu en v(\d+\.\d+)', c[1])
        resolus[m.group(2)] = {'code': m.group(2), 'version': v.group(1) if v else '', 'texte': md(c[1])}
    else:
        ouverts.setdefault(m.group(2), []).append(md(c[1]))

# Feuille de route : verdict, etapes, priorites.
fdr = lire(fdr_p)
verdict = re.search(r'^Verdict : \*\*(.+?)\*\* — (.*)$', fdr, re.M)
STATUTS = {'x': 'fait', '~': 'en partie', ' ': 'à faire'}
etapes = [{'statut': STATUTS[s], 'titre': md(t), 'detail': md(d)}
          for s, t, d in re.findall(r'^- \[([x~ ])\] \*\*(.+?)\*\* — (.*)$', fdr, re.M)]
priorites = [(c[0], c[1]) for c in (cellules(l) for l in fdr.splitlines() if re.match(r'^\| O\d+ \|', l))]
ordre = [code for code, _ in priorites]
prio = dict(priorites)
liste_ouverts = [{'code': code, 'constat': '<br>'.join(ouverts[code]), 'priorite': prio.get(code, 'à classer')}
                 for code in sorted(ouverts, key=lambda k: (ordre.index(k) if k in ordre else len(ordre), int(k[1:])))
                 if code not in resolus]

# Controles : la ligne la plus recente de chaque version (le disque en tete).
controles = {}
with open(hist_p, encoding='utf-8') as f:
    for l in f:
        v, n, h, d = l.rstrip('\n').split('\t')
        if v and v not in controles:
            controles[v] = {'version': v, 'controles': int(n), 'commit': h, 'date': d}
par_version = sorted(controles.values(), key=lambda x: version_cle(x['version']))

couts = json.loads(lire(couts_p)) or None
print(json.dumps({
    'genere': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'),
    'commit': commit,
    'version_spec': versions[-1]['version'] if versions else '',
    'scripts': int(scripts),
    'verdict': {'titre': md(verdict.group(1)), 'detail': md(verdict.group(2))} if verdict else None,
    'etapes': etapes,
    'defauts': {'corriges': total, 'par_version': versions},
    'controles': {'actuel': par_version[-1]['controles'] if par_version else 0, 'par_version': par_version},
    'ouverts': liste_ouverts,
    'resolus': sorted(resolus.values(), key=lambda x: int(x['code'][1:])),
    'couts': couts,
}, ensure_ascii=False))
PY
)"

if [[ "$FORMAT" == json ]]; then
  printf '%s\n' "$DONNEES"
  exit 0
fi
# `</` echappe : un texte contenant </script> ne doit pas fermer le bloc de donnees.
# Marqueur present exactement une fois : un second (dans un commentaire) prendrait
# la substitution a la place du script, et la page resterait vide.
[[ "$(grep -cF '/*DONNEES*/null' "$GABARIT")" == 1 ]] \
  || die "gabarit : le marqueur /*DONNEES*/null doit figurer exactement une fois : $GABARIT"
printf '%s' "$DONNEES" >"$TMP/donnees.json"
python3 - "$GABARIT" "$TMP/donnees.json" <<'PY'
import sys
page = open(sys.argv[1], encoding='utf-8').read()
donnees = open(sys.argv[2], encoding='utf-8').read().replace('</', '<\\/')
sys.stdout.write(page.replace('/*DONNEES*/null', donnees, 1))
PY
