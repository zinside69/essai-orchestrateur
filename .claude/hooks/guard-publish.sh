#!/usr/bin/env bash
# PreToolUse — interdit toute publication ou fusion depuis un agent.
set -Eeuo pipefail

INPUT="$(cat)"
CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT")"

refuser() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Publication et fusion : réservées au harnais
if grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+(create|merge|close|edit|review)' <<<"$CMD"; then
  refuser "Ouverture, fusion ou revue de PR réservée au harnais. Un agent ne publie jamais."
fi

if grep -Eq '(^|[[:space:];&|(])gh[[:space:]]+(release|workflow|secret|auth)[[:space:]]' <<<"$CMD"; then
  refuser "Commande gh sensible réservée au harnais (release, workflow, secret, auth)."
fi

# Toute écriture d'état de l'orchestrateur
if grep -Eq '\.orchestrator/(state|logs)' <<<"$CMD"; then
  refuser "Écriture dans l'état de l'orchestrateur interdite depuis un agent."
fi

exit 0
