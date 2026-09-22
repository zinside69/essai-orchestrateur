#!/usr/bin/env bash
# PreToolUse — bloque tout push et tout contournement par shell imbriqué.
set -Eeuo pipefail

INPUT="$(cat)"
CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT")"

refuser() {
  jq -n --arg raison "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $raison
    }
  }'
  exit 0
}

# 1. Push direct ou déguisé
if grep -Eq '(^|[[:space:];&|(])git[[:space:]]+push' <<<"$CMD"; then
  refuser "Push interdit depuis un worktree d'agent (Phase 1, Q1). Le harnais pousse, pas l'agent."
fi

# 2. Contournement par --no-verify
if grep -Eq 'git[[:space:]]+push.*--no-verify' <<<"$CMD"; then
  refuser "Contournement de hook git détecté."
fi

# 3. Shell imbriqué : neutralise tout matcher de commande
if grep -Eq '(bash|sh|zsh|dash)[[:space:]]+-c' <<<"$CMD"; then
  refuser "Shell imbriqué : contournement de politique. Reformule la commande directement."
fi

# 4. Exfiltration réseau
if grep -Eq '(^|[[:space:];&|(])(curl|wget|nc|scp|ssh)[[:space:]]' <<<"$CMD"; then
  refuser "Accès réseau sortant interdit depuis un agent."
fi

# 5. Action infra destructive
if grep -Eq '(terraform[[:space:]]+(apply|destroy)|kubectl[[:space:]]+(delete|apply)|docker[[:space:]]+(rm|run|system))' <<<"$CMD"; then
  refuser "Action infra : escalade humaine requise (Q3)."
fi

exit 0
