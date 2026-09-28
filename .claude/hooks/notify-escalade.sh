#!/usr/bin/env bash
# Notification — pousse une alerte quand une session attend une décision humaine.
set -Eeuo pipefail

INPUT="$(cat)"
SESSION="$(jq -r '.session_id // "inconnue"' <<<"$INPUT")"
CWD="$(jq -r '.cwd // ""' <<<"$INPUT")"
MESSAGE="$(jq -r '.message // "Claude Code attend une décision"' <<<"$INPUT")"

# AVANT : NTFY_TOPIC="${NTFY_TOPIC:-mon-projet-agents}"
# AVANT :
# AVANT : # Notification push mobile — bouton de réponse directe
# AVANT : curl -sS \
# AVANT :   -H "Title: Agent bloqué — $SESSION" \
# AVANT :   -H "Priority: high" \
# AVANT :   -H "Tags: robot,stop_sign" \
# AVANT :   -H "Actions: view, Ouvrir la session, ${SESSION_URL:-https://claude.ai/code}" \
# AVANT :   -d "$(printf '%s\n%s\n%s' "$MESSAGE" "$CWD" "$SESSION")" \
# AVANT :   "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
#   (2026-09-23, O19) Le sujet ne venait que de l'environnement, ou il n'est
#   jamais exporte (la configuration vit dans ~/.orchestrateur.env) : le hook
#   publiait sur « mon-projet-agents », sujet public au nom generique — message,
#   dossier du projet et session lisibles par qui s'y abonne. Desormais : sujet
#   lu comme partout ailleurs (environnement, puis ORCHESTRATEUR_ENV), passe par
#   un fichier de configuration curl en 600 (defaut 46 : rien de secret dans
#   `ps`), et RIEN d'envoye sans sujet. Autonome : ce hook ne source pas lib.sh.
#   Test K12.
SUJET="${NTFY_TOPIC:-}"
FICHIER_ENV="${ORCHESTRATEUR_ENV:-$HOME/.orchestrateur.env}"
if [[ -z "$SUJET" && -r "$FICHIER_ENV" ]]; then
  SUJET="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?NTFY_TOPIC[[:space:]]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\2/p' "$FICHIER_ENV" | head -1)"
fi

# Un nom de sujet ntfy ne contient que [A-Za-z0-9_-] : tout autre caractere (un
# guillemet, un retour a la ligne) pourrait ajouter une ligne au fichier -K.
[[ "$SUJET" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || SUJET=""

# Notification push mobile — bouton de réponse directe
if [[ -n "$SUJET" ]]; then
  CFG="$(mktemp)"
  chmod 600 "$CFG"
  printf 'url = "https://ntfy.sh/%s"\n' "$SUJET" >"$CFG"
  curl -sS -K "$CFG" \
    -H "Title: Agent bloqué — $SESSION" \
    -H "Priority: high" \
    -H "Tags: robot,stop_sign" \
    -H "Actions: view, Ouvrir la session, ${SESSION_URL:-https://claude.ai/code}" \
    -d "$(printf '%s\n%s\n%s' "$MESSAGE" "$CWD" "$SESSION")" >/dev/null || true
  rm -f "$CFG"
fi

# Trace horodatée locale, utilisée par run-task.sh pour le compteur blocked
printf '%s\t%s\t%s\t%s\n' \
  "$(date -u +%FT%TZ)" "$SESSION" "$CWD" "$MESSAGE" \
  >> "${CLAUDE_PROJECT_DIR:-.}/.orchestrator/escalations.tsv"
