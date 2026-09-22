#!/usr/bin/env bash
# publisher.sh — pousse la branche et ouvre/merge la PR. Exécuté par le harnais uniquement.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: publisher.sh T-NNN}"
WT="${2:?chemin du worktree}"
DECISION="$STATE_DIR/$TASK_ID.decision.json"
BRANCH="$AGENT_BRANCH_PREFIX/$TASK_ID"

require git gh jq

VERDICT="$(jq -r '.verdict' "$DECISION")"
REVUE="$(jq -r  '.axe_d_revue.verdict'  "$DECISION")"
RISQUE="$(jq -r '.axe_c_risque'         "$DECISION")"
CONF="$(jq -r   '.axe_d_revue.confiance' "$DECISION")"
RAISONS="$(jq -r '.raisons | join(" · ")' "$DECISION")"

[[ "$VERDICT" == "PARK" ]] && {
  log "PARK — aucune publication. Décision : $DECISION"
  "$ROOT/.claude/hooks/notify-escalade.sh" <<<"$(jq -n \
    --arg s "$TASK_ID" --arg c "$WT" \
    --arg m "PARK sur $TASK_ID : $RAISONS" \
    '{session_id:$s, cwd:$c, message:$m}')"
  exit 20
}

# --- Corps de PR : la traçabilité complète de la décision -----------------
BODY="$(mktemp)"
{
  printf '## Tâche %s\n\n' "$TASK_ID"
  printf 'Décision automatique : **%s**\n\n' "$VERDICT"
  printf '| Axe | Valeur |\n|---|---|\n'
  printf '| A — Gates | %s |\n'  "$(jq -r '.axe_a_gates' "$DECISION")"
  printf '| B — Volume | %s fichiers / %s lignes |\n' \
    "$(jq -r '.axe_b_volume.fichiers' "$DECISION")" "$(jq -r '.axe_b_volume.lignes' "$DECISION")"
  printf '| C — Risque | %s |\n' "$RISQUE"
  printf '| D — Revue | %s (confiance %s) |\n' "$REVUE" "$CONF"
  printf '| E — Nature | %s |\n\n' "$(jq -r '.axe_e_nature' "$DECISION")"
  printf '**Règles appliquées** : %s\n\n' "$RAISONS"
  printf '%s\n\n' '---'
  jq -r 'if (.rejets | length) > 0 then
           "### Rejets signalés\n\n" +
           ([.rejets[] | "- `\(.code)` (\(.gravite)) \(.fichier // "—"):\(.ligne // 0) — \(.constat)"] | join("\n"))
         else "Aucun rejet signalé par la revue." end' "$STATE_DIR/$TASK_ID.revue.json"
  printf '\n\n> Revue produite par un modèle distinct (%s) sur un contexte neuf.\n' \
    "$(jq -r '.modele_reviewer' "$STATE_DIR/$TASK_ID.revue.json")"
} >"$BODY"

# --- Push de la branche d'agent (harnais uniquement) ---------------------
cd "$ROOT"
git push -u origin "$BRANCH"

case "$VERDICT" in
  AUTO_MERGE)
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" \
      --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
      --label "agent,auto-merge" >/dev/null
    # La fusion attend les gates requis — jamais un merge immédiat
    gh pr merge "$BRANCH" --squash --auto --delete-branch
    log "PR ouverte vers $INTEGRATION_BRANCH avec auto-merge activé (attente des checks requis)"
    ;;
  PR_DRAFT)
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" --draft \
      --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
      --label "agent,draft" >/dev/null
    log "PR en brouillon ouverte vers $INTEGRATION_BRANCH"
    ;;
  PR_READY)
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" \
      --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
      --label "agent,revue-humaine" >/dev/null
    log "PR prête pour revue humaine — notification requise"
    ;;
esac

rm -f "$BODY"
