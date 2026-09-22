#!/usr/bin/env bash
# Notification — pousse une alerte quand une session attend une décision humaine.
set -Eeuo pipefail

INPUT="$(cat)"
SESSION="$(jq -r '.session_id // "inconnue"' <<<"$INPUT")"
CWD="$(jq -r '.cwd // ""' <<<"$INPUT")"
MESSAGE="$(jq -r '.message // "Claude Code attend une décision"' <<<"$INPUT")"

NTFY_TOPIC="${NTFY_TOPIC:-mon-projet-agents}"

# Notification push mobile — bouton de réponse directe
curl -sS \
  -H "Title: Agent bloqué — $SESSION" \
  -H "Priority: high" \
  -H "Tags: robot,stop_sign" \
  -H "Actions: view, Ouvrir la session, ${SESSION_URL:-https://claude.ai/code}" \
  -d "$(printf '%s\n%s\n%s' "$MESSAGE" "$CWD" "$SESSION")" \
  "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true

# Trace horodatée locale, utilisée par run-task.sh pour le compteur blocked
printf '%s\t%s\t%s\t%s\n' \
  "$(date -u +%FT%TZ)" "$SESSION" "$CWD" "$MESSAGE" \
  >> "${CLAUDE_PROJECT_DIR:-.}/.orchestrator/escalations.tsv"
