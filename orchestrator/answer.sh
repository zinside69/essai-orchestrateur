#!/usr/bin/env bash
# answer.sh — repond a une escalade si une regle de l'answer-book la couvre.
# Usage : answer.sh [--dry-run] T-NNN
#         answer.sh --help
# Sortie : 0 = reponse appliquee  10 = aucune regle  20 = refus de niveau
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

# (2026-09-23, O24) Chemin surchargeable : un test pose sa variante dans un dossier
# jetable au lieu de reecrire le vrai answer-book le temps du test.
# AVANT : BOOK="$ROOT/orchestrator/answer-book.md"
BOOK="${ORCH_ANSWER_BOOK:-$ROOT/orchestrator/answer-book.md}"
SCHEMA="$ROOT/orchestrator/answer-book.schema.json"
ETAT_DIR="$ORCH_DIR/etat"
ESCALADES="$ETAT_DIR/escalades/escalades.jsonl"
REFUS="$ORCH_DIR/journal/refus.jsonl"
DRY_RUN=0
TASK_ID=""

show_help() {
  cat <<'EOF'
Usage:
  answer.sh [--dry-run] T-NNN
  answer.sh --suggerer T-NNN <raisons> <niveau>
  answer.sh --help

Lit la derniere escalade ouverte d'une tache, cherche la premiere regle active
qui couvre exactement son motif, puis applique la reponse via repondre.sh.
Sorties : 0 appliquee, 10 aucune regle, 20 refus de niveau.
EOF
}

# (2026-09-23, O25, decision de l'operateur) Mode suggestion : le clone ne repond
# plus seul, il PROPOSE. escalade.sh l'appelle a l'ouverture, avant d'ecrire
# l'escalade, avec ses raisons et son niveau : lecture seule, aucune ecriture (pas
# meme le refus L4), sortie « R-xxx decision » sur stdout. Codes inchanges :
# 0 regle trouvee, 10 aucune, 20 niveau L4. Tests K17, K18.
SUGGERER=0
SUGG_RAISONS=""
SUGG_NIVEAU=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --suggerer)
      [[ $# -ge 4 ]] || die "usage: answer.sh --suggerer T-NNN <raisons> <niveau>"
      SUGGERER=1; TASK_ID="$2"; SUGG_RAISONS="$3"; SUGG_NIVEAU="$4"; shift 4 ;;
    *)
      [[ -z "$TASK_ID" ]] || die "argument inattendu : $1"
      TASK_ID="$1"
      shift ;;
  esac
done

[[ -n "$TASK_ID" ]] || die "usage: answer.sh [--dry-run] T-NNN"
require awk jq python3
[[ -f "$BOOK" ]] || die "answer-book absent : $BOOK"
[[ -f "$SCHEMA" ]] || die "schema absent : $SCHEMA"
# AVANT : [[ -f "$ESCALADES" ]] || exit 10
(( SUGGERER == 1 )) || [[ -f "$ESCALADES" ]] || exit 10
mkdir -p "$ORCH_DIR/journal"

ENVF="$ETAT_DIR/taches/$TASK_ID.env"
[[ -f "$ENVF" ]] || die "tache inconnue : $TASK_ID"

if (( SUGGERER == 1 )); then
  # L'escalade n'est pas encore ecrite : raisons et niveau viennent de l'appelant.
  META=("$SUGG_RAISONS" "$SUGG_NIVEAU" "")
else
readarray -t META < <(python3 - "$ESCALADES" "$TASK_ID" <<'PY'
import json, sys
sys.stdout.reconfigure(newline=chr(10))
p, task = sys.argv[1:3]
found = None
for line in open(p, encoding='utf-8'):
    if not line.strip():
        continue
    row = json.loads(line)
    if row.get('tache') == task and row.get('statut') == 'ouverte':
        found = row
if not found:
    sys.exit(10)
print(found.get('raisons', ''))
print(found.get('niveau', ''))
print(found.get('expire_le', ''))
PY
) || exit 10
fi

RAISONS="${META[0]:-}"
NIVEAU="${META[1]:-}"
EXPIRE_LE="${META[2]:-}"
PERIM="$(sed -n 's/^perimetre=//p' "$ENVF" | head -1)"
# (2026-09-23, O27) Date de reference surchargeable : le replay juge chaque cas
# historique a SA date, pas au jour ou tourne la preuve. Sans cela, l'echeance
# d'une regle (R-010 : 2026-10-31) faisait virer la 5e preuve au rouge sans aucun
# changement de code. Format verifie : une date mal formee comparerait faux.
# AVANT : AUJOURDHUI="$(date -u +%F)"
AUJOURDHUI="${ORCH_AUJOURDHUI:-$(date -u +%F)}"
[[ "$AUJOURDHUI" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "ORCH_AUJOURDHUI mal formee (AAAA-MM-JJ attendu) : $AUJOURDHUI"

niveau_num() {
  case "$1" in
    L1) echo 1 ;;
    L2) echo 2 ;;
    L3) echo 3 ;;
    L4) echo 4 ;;
    *) echo 99 ;;
  esac
}

match_glob() {
  local path="$1" pattern="$2"
  # shellcheck disable=SC2053
  [[ "$path" == $pattern ]]
}

if [[ "$NIVEAU" == "L4" ]]; then
  (( SUGGERER == 0 )) || exit 20
  if (( DRY_RUN == 1 )); then
    printf '[DRY-RUN answer] clone_refus_niveau task=%s niveau=%s\n' "$TASK_ID" "$NIVEAU"
  else
    jq -c -n --arg t "$TASK_ID" --arg n "$NIVEAU" --arg ts "$(date -u +%FT%TZ)" \
      '{tache:$t, origine:"clone", issue:"clone_refus_niveau", niveau:$n, ts:$ts}' >>"$REFUS"
    printf 'niveau critique L4 : refus de traitement par le clone\n' >&2
  fi
  exit 20
fi

DECISION=""
REGLE=""
while IFS='|' read -r id quand nmax dec portee expire _; do
  case "$id" in ''|'#'*) continue ;; esac
  id="$(echo "$id" | xargs)"
  quand="$(echo "$quand" | xargs)"
  nmax="$(echo "$nmax" | xargs)"
  dec="$(echo "$dec" | xargs)"
  portee="$(echo "$portee" | xargs)"
  expire="$(echo "$expire" | xargs)"

  [[ "${quand#quand:}" == "$RAISONS" ]] || continue
  if (( $(niveau_num "$NIVEAU") > $(niveau_num "${nmax#niveau_max:}") )); then
    continue
  fi
  [[ "${expire#expire_le:}" > "$AUJOURDHUI" || "${expire#expire_le:}" == "$AUJOURDHUI" ]] || continue
  if [[ "${portee#portee:}" != "-" ]]; then
    match_glob "$PERIM" "${portee#portee:}" || continue
  fi
  DECISION="${dec#decision:}"
  REGLE="$id"
  break
done < "$BOOK"

[[ -n "$REGLE" ]] || exit 10

if (( SUGGERER == 1 )); then
  printf '%s %s\n' "$REGLE" "$DECISION"
  exit 0
fi

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN answer] task=%s niveau=%s regle=%s decision=%s expire=%s\n' \
    "$TASK_ID" "$NIVEAU" "$REGLE" "$DECISION" "$EXPIRE_LE"
  exit 0
fi

RESPONSE_ORIGINE=clone RESPONSE_REGLE="$REGLE" \
  "$ROOT/orchestrator/repondre.sh" "$TASK_ID" "$DECISION" >/dev/null
printf 'clone: %s -> %s (regle %s)\n' "$TASK_ID" "$DECISION" "$REGLE"
