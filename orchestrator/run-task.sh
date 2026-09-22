#!/usr/bin/env bash
# Lance une tâche de todo.md : snapshot -> worktree isolé -> Claude headless -> porte -> commit.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: run-task.sh T-NNN}"
MAX_TURNS="${MAX_TURNS:-60}"
MODEL="${MODEL:-sonnet}"

require git jq claude

mapfile -t T < <(parse_task "$TASK_ID")
[[ ${#T[@]} -gt 0 ]] || die "tâche $TASK_ID absente de todo.md"

declare -A TACHE
for kv in "${T[@]}"; do TACHE["${kv%%=*}"]="${kv#*=}"; done

WT="$WORKTREE_ROOT/$TASK_ID"
BRANCH="$AGENT_BRANCH_PREFIX/$TASK_ID"
TAG="pre-task/$TASK_ID"
LOG="$LOG_DIR/run-$TASK_ID.jsonl"
STATE="$STATE_DIR/$TASK_ID.state"

# --- 0. Reprise possible ? ------------------------------------------------
if [[ -f "$STATE" ]] && grep -q '^session_id=' "$STATE"; then
  SESSION_ID="$(sed -n 's/^session_id=//p' "$STATE")"
  log "Reprise de la session $SESSION_ID"
  REPRISE=(--resume "$SESSION_ID")
else
  REPRISE=()
fi

# --- 1. Snapshot : rollback en une commande -------------------------------
cd "$ROOT"
git rev-parse --verify "$INTEGRATION_BRANCH" >/dev/null 2>&1 || {
  git switch -c "$INTEGRATION_BRANCH" main && git switch -
}
git tag -f "$TAG" "$INTEGRATION_BRANCH" >/dev/null
log "Snapshot posé : $TAG -> rollback = git reset --hard $TAG"

# --- 2. Worktree isolé ----------------------------------------------------
if git worktree list --porcelain | grep -q "$WT"; then
  git worktree remove "$WT" --force || true
fi
git worktree add -b "$BRANCH" "$WT" "$INTEGRATION_BRANCH"
log "Worktree créé : $WT (branche $BRANCH)"
preparer_worktree "$WT"

# --- 3. Neutralisation push (couche 4) -----------------------------------
cd "$WT"
if git remote get-url origin >/dev/null 2>&1; then
  git config remote.origin.pushurl "no-push://interdit"
  log "pushurl neutralisée dans le worktree"
fi

# --- 4. Contexte de tâche -------------------------------------------------
cat >"$WT/.claude-task.md" <<EOF
# Tâche en cours — $TASK_ID

Périmètre autorisé : ${TACHE[perimetre]:-non spécifié}
Critère de done    : ${TACHE[critere]:-non spécifié}
Gates à passer     : ${TACHE[gates]:-lint,typecheck,test}

## Invariants (non négociables)
- Aucun secret en dur, aucune clé dans le code ou les commits.
- Aucun push. Aucun \`git checkout main\`. Aucune commande infra.
- Toute nouvelle dépendance exige un ADR dans docs/adr/ avant l'installation.
- Toute migration de base ou modification de schéma = arrêt et escalade.
- Ne touche QUE les fichiers du périmètre ci-dessus. Si tu dois en sortir, arrête-toi.
EOF

# (2026-09-21) La fiche de tache n'appartient pas au code du projet. Sans cette
# exclusion, le « git add -A » de l'etape 7 l'embarquait dans la branche de
# l'agent (constate sur le bac a sable : commit reduit a .claude-task.md), d'ou
# elle aurait ete fusionnee — et elle masquait le controle « diff:vide » de
# gate.sh quand l'agent n'avait rien ecrit. Exclusion locale au depot
# (info/exclude, partage par les worktrees) : le .gitignore du projet reste intact.
exclure_localement "$WT" .claude-task.md

# --- 5. Lancement headless ------------------------------------------------
PROMPT="Lis .claude-task.md et CLAUDE.md, puis implémente la tâche $TASK_ID.
Vérifie que les gates passent avant de conclure. Commit sur la branche courante.
Si une décision d'architecture, une dépendance, un secret ou une action
destructive est nécessaire, n'agis pas : explique le blocage et arrête-toi."

# Skill de l'etape (2026-09-21) : designe par orchestrator/skills.json. Le prompt
# commence par « /<skill> » : Claude Code charge le skill AVANT que l'agent ne
# commence, au lieu de compter sur lui pour y penser. Le reste du prompt devient
# les arguments du skill. Vide = comportement d'avant, sans skill.
SKILL_IMPL="$(skill_pour implementation "$TASK_ID")"
if [[ -n "$SKILL_IMPL" ]]; then
  PROMPT="/$SKILL_IMPL $PROMPT"
  log "Skill d'implémentation : $SKILL_IMPL"
fi

set +e
claude -p "$PROMPT" "${REPRISE[@]}" \
  --model "$MODEL" \
  --output-format stream-json --verbose \
  --max-turns "$MAX_TURNS" \
  --permission-mode acceptEdits \
  >"$LOG" 2>&1
CLAUDE_RC=$?
set -e

# --- 6. Capture de session et coût ---------------------------------------
SESSION_ID="$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$LOG" 2>/dev/null | head -1 || true)"
COUT="$(jq -r 'select(.type=="result") | .total_cost_usd // empty' "$LOG" 2>/dev/null | tail -1 || true)"
TOURS="$(jq -r 'select(.type=="result") | .num_turns // empty' "$LOG" 2>/dev/null | tail -1 || true)"

{
  printf 'session_id=%s\n' "${SESSION_ID:-}"
  printf 'claude_rc=%s\n' "$CLAUDE_RC"
  printf 'cout_usd=%s\n' "${COUT:-0}"
  printf 'tours=%s\n' "${TOURS:-0}"
  printf 'skill_demande=%s\n' "${SKILL_IMPL:-}"
} >"$STATE"

log "Session ${SESSION_ID:-inconnue} | coût ${COUT:-0} USD | $TOURS tours"

# --- 7. Commit automatique (agent) ---------------------------------------
cd "$WT"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git -c user.name="agent-$TASK_ID" -c user.email="agent@local" \
      commit -q -m "$TASK_ID: implémentation automatique (session ${SESSION_ID:-n/a})"
  log "Commit agent créé sur $BRANCH"
fi

# --- 8. Porte -------------------------------------------------------------
set +e
"$(dirname "$0")/gate.sh" "$TASK_ID" "$INTEGRATION_BRANCH" "$WT" >/dev/null
GATE_RC=$?
set -e

case "$GATE_RC" in
  0)
    log "VERDICT vert — tâche $TASK_ID prête pour revue (branche $BRANCH, non poussée)"
    ;;
  10)
    log "VERDICT rouge — gates échouées. Logs : $LOG_DIR/gate-$TASK_ID-*.log"
    ;;
  20)
    log "VERDICT escalade — décision humaine requise."
    "$ROOT/.claude/hooks/notify-escalade.sh" <<<"$(jq -n \
      --arg s "${SESSION_ID:-inconnue}" \
      --arg c "$WT" \
      --arg m "Tâche $TASK_ID : escalade (voir $STATE_DIR/$TASK_ID.verdict.json)" \
      '{session_id:$s, cwd:$c, message:$m}')"
    ;;
esac

cd "$ROOT"
exit $GATE_RC
