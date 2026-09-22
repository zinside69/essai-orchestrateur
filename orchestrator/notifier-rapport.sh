#!/usr/bin/env bash
# notifier-rapport.sh — diffuse le rapport quotidien de supervision.
# Usage : notifier-rapport.sh [--dry-run] [fichier_markdown]
#         notifier-rapport.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

DRY_RUN=0
RAPPORT="${1:-$LOG_DIR/dashboard.md}"

show_help() {
  cat <<'EOF'
Usage:
  notifier-rapport.sh [--dry-run] [fichier_markdown]
  notifier-rapport.sh --help

Diffuse le rapport quotidien sur le canal digest L1 et, si configure, sur ntfy.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) RAPPORT="$1"; shift ;;
  esac
done

[[ -f "$RAPPORT" ]] || die "rapport introuvable : $RAPPORT"
mkdir -p "$ORCH_DIR/journal"

OBJET="Tableau de bord quotidien"
EXTRAIT="$(sed -n '1,40p' "$RAPPORT")"

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN notifier-rapport] sujet=%s\n' "$OBJET"
  printf '[DRY-RUN notifier-rapport] source=%s\n' "$RAPPORT"
  printf '%s\n' "$EXTRAIT"
  exit 0
fi

printf '%s\tL1\tRAPPORT\t%s\n' "$(date -u +%FT%TZ)" "$RAPPORT" >>"$ORCH_DIR/journal/digest.tsv"
if [[ -n "${NTFY_TOPIC:-}" ]]; then
  curl -sS -H "Title: $OBJET" -H "Priority: default" -H "Tags: chart_with_upwards_trend" \
    -d "$EXTRAIT" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null || true
fi
log "Rapport diffuse : $RAPPORT"
