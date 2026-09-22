#!/usr/bin/env bash
# prune-contexte.sh — prune documentaire pilotée par mesure (Phase 5 / P3-b).
# Usage : prune-contexte.sh [--doc F] [--sortie F.md] [--dry-run]
#
# Principe (conf. Nisi, WorkOS) : mesurer au lieu d'assumer. Pour chaque
# document injecté dans le contexte des agents, on mesure le score des suites
# de non-régression (run-manifeste + run-replay) AVEC puis SANS le document
# (neutralisé puis restauré). delta = avec - sans :
#   POSITIVE (delta > 0) : le document est conservé ;
#   NEUTRE   (delta = 0) : candidat à la prune (n'améliore aucune métrique) ;
#   NEGATIVE (delta < 0) : quarantaine (dégrade les métriques).
# Journal : .orchestrator/journal/prune-docs.jsonl — exploité par M16.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

DRY_RUN=0
SORTIE=""
DOC_CIBLE=""

show_help() {
  cat <<'EOF'
Usage:
  prune-contexte.sh [--doc F] [--sortie F.md] [--dry-run]

Options:
  --doc F      évalue uniquement le document F (chemin relatif à la racine)
  --sortie F   rapport markdown (defaut: .orchestrator/logs/prune-rapport.md)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --doc) DOC_CIBLE="${2:?valeur manquante}"; shift 2 ;;
    --sortie) SORTIE="${2:?valeur manquante}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq awk grep
PRUNE_LOG="$ORCH_DIR/journal/prune-docs.jsonl"
QUAR_DOCS="$ORCH_DIR/etat/quarantaine-docs.tsv"
SORTIE="${SORTIE:-$LOG_DIR/prune-rapport.md}"
mkdir -p "$(dirname "$PRUNE_LOG")" "$(dirname "$QUAR_DOCS")" "$(dirname "$SORTIE")"

# Documents réellement injectés dans le contexte des agents (les PDF/HTML de
# phases sont des artefacts de livraison, hors périmètre par construction).
if [[ -n "$DOC_CIBLE" ]]; then
  DOCS=("$DOC_CIBLE")
else
  DOCS=(CLAUDE.md .claude/reviewer-invariants.md .claude/agents/reviewer-diff.md)
fi

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN prune] docs=%s\n' "${DOCS[*]}"
  printf '[DRY-RUN prune] journal=%s rapport=%s\n' "$PRUNE_LOG" "$SORTIE"
  exit 0
fi

# Score combiné : taux de cas manifeste + taux de succès du replay (moyenne).
mesure() {
  local mani replay_out
  mani="$("$ROOT/tests/run-manifeste.sh" 2>/dev/null | grep -oE '[0-9]+/[0-9]+ cas' | head -1 | cut -d/ -f1)"
  replay_out="$("$ROOT/tests/run-replay.sh" --seuil-deja-tranchees 1 --seuil-couvertes 0 2>/dev/null \
    | grep 'success_rate' | grep -oE '[0-9.]+$')"
  awk -v m="${mani:-0}" -v r="${replay_out:-0}" 'BEGIN{printf "%.3f", (m/13 + r)/2}'
}

TS="$(date -u +%FT%TZ)"
BASELINE="$(mesure)"
log "prune-contexte : baseline=$BASELINE"

RAPPORT_TMP="$(mktemp)"
{
  printf '%s\n' "# Rapport de prune documentaire — $TS"
  printf '\n%s\n' "Baseline (tous documents présents) : $BASELINE"
  printf '\n%s\n' '| Document | Avec | Sans | Delta | Contribution | Décision |'
  printf '%s\n' '|---|---:|---:|---:|---|---|'
} >"$RAPPORT_TMP"

for doc in "${DOCS[@]}"; do
  F="$ROOT/$doc"
  if [[ ! -f "$F" ]]; then
    log "document absent, ignoré : $doc"
    continue
  fi
  BAK="$(mktemp)"
  cp "$F" "$BAK"
  # Neutralise le document (restauration garantie même en cas d'échec)
  mv "$F" "$F.pruned"
  SANS="$(mesure)"
  mv "$F.pruned" "$F"
  cmp -s "$BAK" "$F" || cp "$BAK" "$F"
  rm -f "$BAK"
  DELTA="$(awk -v a="$BASELINE" -v s="$SANS" 'BEGIN{printf "%+.3f", a-s}')"
  CONTRIB="$(awk -v d="$DELTA" 'BEGIN{ if (d+0 > 0) print "POSITIVE"; else if (d+0 < 0) print "NEGATIVE"; else print "NEUTRE" }')"
  case "$CONTRIB" in
    POSITIVE) DECISION_TXT="conserver" ;;
    NEUTRE)   DECISION_TXT="candidat prune" ;;
    NEGATIVE) DECISION_TXT="quarantaine" ;;
  esac
  printf '| %s | %s | %s | %s | %s | %s |\n' "$doc" "$BASELINE" "$SANS" "$DELTA" "$CONTRIB" "$DECISION_TXT" >>"$RAPPORT_TMP"
  jq -nc --arg ts "$TS" --arg d "$doc" --argjson avec "$BASELINE" --argjson sans "$SANS" \
    --arg delta "$DELTA" --arg c "$CONTRIB" \
    '{ts_utc:$ts,doc:$d,score_avec:$avec,score_sans:$sans,delta:($delta|tonumber),contribution:$c}' \
    >>"$PRUNE_LOG"
  if [[ "$CONTRIB" == "NEGATIVE" ]]; then
    grep -qF "$doc" "$QUAR_DOCS" 2>/dev/null || printf '%s\t%s\t%s\n' "$doc" "$TS" "delta_negatif" >>"$QUAR_DOCS"
    log "quarantaine documentaire : $doc (delta=$DELTA)"
  fi
done

{
  printf '\n%s\n' '## Règle de décision'
  printf '%s\n' 'Seuls les documents à contribution POSITIVE mesurée sont conservés sans réserve.'
  printf '%s\n' 'NEUTRE = candidat à la prune ; NEGATIVE = quarantaine immédiate (jamais de prune sur intuition).'
} >>"$RAPPORT_TMP"
cp "$RAPPORT_TMP" "$SORTIE"
rm -f "$RAPPORT_TMP"
printf 'prune_baseline=%s docs=%s rapport=%s\n' "$BASELINE" "${#DOCS[@]}" "$SORTIE"
exit 0
