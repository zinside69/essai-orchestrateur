#!/usr/bin/env bash
# reconcile.sh — interroge GitHub pour refermer les taches et detecter les derives.
# Usage : reconcile.sh [--dry-run]
#         reconcile.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"
DRY_RUN=0

show_help() {
  cat <<'EOF'
Usage:
  reconcile.sh [--dry-run]
  reconcile.sh --help

Synchronise l'état local des tâches avec les PR publiées et détecte les dérives de SHA après revue.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "argument inattendu : $1" ;;
  esac
done

mkdir -p "$ETAT_DIR/taches" "$ORCH_DIR/journal"
require jq git
(( DRY_RUN == 1 )) || require gh

derives=0

for f in "$ETAT_DIR"/taches/*.env; do
  [[ -f "$f" ]] || continue
  TASK_ID="$(basename "$f" .env)"
  ETAT="$(sed -n 's/^etat=//p' "$f" | head -1)"
  BRANCHE="$(sed -n 's/^branche=//p' "$f" | head -1)"

  [[ "$ETAT" == "PUBLISHED" ]] || continue
  [[ -n "$BRANCHE" ]] || continue

  if (( DRY_RUN == 1 )); then
    printf '[DRY-RUN reconcile] inspect task=%s branch=%s etat=%s\n' "$TASK_ID" "$BRANCHE" "$ETAT"
    continue
  fi

  PR_STATE="$(gh pr view "$BRANCHE" --json state,mergedAt --jq '.state' 2>/dev/null || echo INCONNU)"
  case "$PR_STATE" in
    MERGED)
      transition_etat "$f" DONE reconcile || log "transition refusee : $TASK_ID -> DONE"
      log "$TASK_ID : PR fusionnee -> DONE"
      ;;
    CLOSED)
      transition_etat "$f" PARKED reconcile || log "transition refusee : $TASK_ID -> PARKED"
      log "$TASK_ID : PR fermee sans fusion -> PARKED"
      derives=$((derives + 1))
      ;;
    OPEN)
      SHA_REVUE="$(jq -r --arg t "$TASK_ID" 'select(.tache==$t) | .sha_head' "$ORCH_DIR/journal/decisions.jsonl" 2>/dev/null | tail -1)"
      SHA_PUBLIE="$(git -C "$ROOT" rev-parse --short "$BRANCHE" 2>/dev/null || echo absent)"
      if [[ -n "$SHA_REVUE" && "$SHA_REVUE" != "$SHA_PUBLIE" ]]; then
        log "DERIVE : $TASK_ID revue sur $SHA_REVUE, publiee sur $SHA_PUBLIE — revue invalidee"
        transition_etat "$f" PARKED reconcile || log "transition refusee : $TASK_ID -> PARKED"
        printf 'derive_sha=revue:%s publie:%s\n' "$SHA_REVUE" "$SHA_PUBLIE" >>"$f"
        tmp="$STATE_DIR/$TASK_ID.derive.json"
        jq -n '{raisons:["P5:derive-apres-revue"]}' >"$tmp"
        "$ROOT/orchestrator/escalade.sh" "$TASK_ID" "$tmp" 2>/dev/null || true
        derives=$((derives + 1))
      fi
      ;;
  esac
done

if (( DRY_RUN == 0 )); then
  N_P4="$(jq -s --arg iso "$(date -u -d '-24 hours' +%FT%TZ)" '[.[] | select(.ts_utc > $iso and (.raisons | any(startswith("P4"))))] | length' "$ORCH_DIR/journal/decisions.jsonl" 2>/dev/null || echo 0)"
  if (( N_P4 >= 3 )); then
    log "ALERTE : $N_P4 sorties de reviewer non conformes en 24 h"
    tmp="$STATE_DIR/reviewer-panne.json"
    jq -n '{raisons:["P4:reviewer-en-panne-repetee"]}' >"$tmp"
    "$ROOT/orchestrator/escalade.sh" "-" "$tmp" 2>/dev/null || true
  fi
fi

log "Reconciliation terminee — $derives derive(s) detectee(s)"
