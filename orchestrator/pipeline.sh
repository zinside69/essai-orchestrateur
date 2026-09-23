#!/usr/bin/env bash
# pipeline.sh — enchaine les etapes Phase 1, 2 et 3 pour une tache, avec transitions d'etat.
# Usage : pipeline.sh [--dry-run] T-NNN
#         pipeline.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"
DRY_RUN=0
TASK_ID=""

show_help() {
  cat <<'EOF'
Usage:
  pipeline.sh [--dry-run] T-NNN
  pipeline.sh --help

Enchaîne : run-task -> verify-evidence -> review -> decide -> publisher/journal/escalade.
En mode --dry-run, vérifie les dépendances de fichiers et affiche le flux sans exécuter Claude ni GitHub.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      [[ -z "$TASK_ID" ]] || die "argument inattendu : $1"
      TASK_ID="$1"
      shift ;;
  esac
done

[[ -n "$TASK_ID" ]] || die "usage: pipeline.sh [--dry-run] T-NNN"
F="$ETAT_DIR/taches/$TASK_ID.env"
D="$ROOT/orchestrator"
WT="$WORKTREE_ROOT/$TASK_ID"
DECISION="$STATE_DIR/$TASK_ID.decision.json"
REVUE="$STATE_DIR/$TASK_ID.revue.json"
GATE_V="$STATE_DIR/$TASK_ID.verdict.json"

[[ -f "$F" ]] || die "etat absent pour $TASK_ID (lancer scheduler.sh)"

# Transition d'etat gardee par la machine a etats (Phase 5 / P3-a).
transition() {
  local next="$1"
  if ! transition_etat "$F" "$next" pipeline; then
    log "transition refusee par la machine a etats : -> $next (tache $TASK_ID)"
  fi
}

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN pipeline] task=%s\n' "$TASK_ID"
  for f in "$D/run-task.sh" "$D/verify-evidence.sh" "$D/review.sh" "$D/decide.sh" "$D/publisher.sh" "$D/journal.sh" "$D/escalade.sh"; do
    [[ -f "$f" ]] || die "script manquant : $f"
    printf '[DRY-RUN pipeline] found %s\n' "$f"
  done
  printf '[DRY-RUN pipeline] state=%s\n' "$F"
  printf '[DRY-RUN pipeline] flow=run-task -> verify-evidence -> review -> decide -> publisher/journal/escalade\n'
  exit 0
fi

# 1. Execution de l'auteur (Phase 1)
# AVANT : if ! "$D/run-task.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1; then
# AVANT :   rcg=$?
# AVANT :   if (( rcg == 10 )); then
# AVANT :     transition RED
# AVANT :   else
# AVANT :     transition FAILED
# AVANT :   fi
# AVANT :   exit "$rcg"
# AVANT : fi
#   (2026-09-22, essai de publication, defauts 10 et 2) Dans « if ! cmd », $?
#   est celui de la negation : rcg valait TOUJOURS 0. Des controles rouges
#   devenaient FAILED au lieu de RED et le pipeline sortait en 0. Et une vraie
#   panne passait FAILED sans prevenir personne (meme esprit que le defaut 30).
#   Trois issues distinctes desormais. Tests Y3 et Y4.
set +e
"$D/run-task.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
rcg=$?
set -e
if (( rcg != 0 )); then
  case "$rcg" in
    10)
      # Controles rouges : le cas normal d'un nouvel essai (RED -> RUNNING).
      #   (2026-09-22, T-002 sur GitHub, defaut 12) Faux : le graphe ne relance
      #   que PENDING/READY, une tache RED restait figee sans prevenir personne —
      #   alors que l'agent de T-002 avait ecrit quoi faire. RED escalade (P11,
      #   non derive : L3 par defaut, les canaux de L2 visent une PR qui n'existe
      #   pas), avec la conclusion de l'agent dans le texte de l'alerte. Test Y4.
      # AVANT :       transition RED ;;
      transition RED
      ESC_RED="$STATE_DIR/$TASK_ID.escalade-rouge.json"
      RAISONS_GATE="$(jq -r '(.raisons // []) | join(",")' "$GATE_V" 2>/dev/null || true)"
      DETAIL_AGENT="$(jq -Rr 'fromjson? | select(.type == "result") | .result // empty' \
        "$LOG_DIR/run-$TASK_ID.jsonl" 2>/dev/null | tail -c 600 || true)"
      jq -nc --arg r "$RAISONS_GATE" --arg d "$DETAIL_AGENT" \
        '{raisons: ["P11:controles-rouges(" + $r + ")"], detail: $d}' >"$ESC_RED"
      "$D/escalade.sh" "$TASK_ID" "$ESC_RED" || true ;;
    20)
      # gate.sh demande un humain (risque, perimetre) : ses raisons font l'escalade.
      transition PARKED
      "$D/escalade.sh" "$TASK_ID" "$GATE_V" || true ;;
    *)
      # Panne : worktree, preparation, agent. Quelqu'un doit le savoir. P10 n'est
      # derive nulle part dans escalade.json : L3 par defaut (ntfy prioritaire, e-mail).
      transition FAILED
      ESC_RUN="$STATE_DIR/$TASK_ID.escalade-run-task.json"
      jq -nc --arg rc "$rcg" '{raisons: ["P10:run-task-echoue(rc=" + $rc + ")"]}' >"$ESC_RUN"
      "$D/escalade.sh" "$TASK_ID" "$ESC_RUN" || true ;;
  esac
  exit "$rcg"
fi

# 1bis. Evidence pack obligatoire (Phase 5 / P1-d)
# Aucune revue sans preuve non-code : absence d'artefact = escalade (P8).
set +e
"$D/verify-evidence.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
EV_RC=$?
set -e
if (( EV_RC != 0 )); then
  transition PARKED
  RAISON_EV="$(cat "$STATE_DIR/$TASK_ID.evidence.raison" 2>/dev/null || printf 'P8:evidence-manquante')"
  tmp="$STATE_DIR/$TASK_ID.escalade-evidence.json"
  jq -n --arg r "$RAISON_EV" '{raisons:[$r]}' >"$tmp"
  "$D/escalade.sh" "$TASK_ID" "$tmp" || true
  exit 20
fi

# Evidence pack complet : la tache est verifiee (Phase 5 / P3-a)
transition VERIFIED

# 1ter. Preuve « test vu rouge » mesuree (2026-09-22) : les tests de l'agent
# rejoues sur l'integration, sans son code. Le resultat (state/T.test-rouge.json)
# nourrit la regle Q3 de decide.sh ; la mesure n'interrompt jamais le pipeline.
"$D/test-rouge.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 || true

# 2. Revue croisee a contexte neuf (Phase 2)
if ! "$D/review.sh" "$TASK_ID" "$WT" "$INTEGRATION_BRANCH" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1; then
  transition PARKED
  tmp="$STATE_DIR/$TASK_ID.escalade-fallback.json"
  jq -n '{raisons:["P5:invariant-contexte-neuf"]}' >"$tmp"
  "$D/escalade.sh" "$TASK_ID" "$tmp" || true
  exit 20
fi

# 3. Matrice de decision (Phase 2)
set +e
"$D/decide.sh" "$TASK_ID" "$GATE_V" "$REVUE" "$WT" "$INTEGRATION_BRANCH" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
DEC_RC=$?
set -e
if (( DEC_RC != 0 )); then
  # Preuve de gates invalide (P7) ou décision bloquante : escalade + journal.
  transition PARKED
  "$D/escalade.sh" "$TASK_ID" "$DECISION" || true
  "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
  exit 20
fi
VERDICT="$(jq -r '.verdict' "$DECISION")"
transition REVIEWED

# 4. Escalade ou publication selon le verdict
if [[ "$VERDICT" == "PARK" ]]; then
  transition PARKED
  "$D/escalade.sh" "$TASK_ID" "$DECISION" || true
  "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
  exit 20
fi

# (2026-09-21, essai 6 du bac a sable) La decision est journalisee AVANT la
# tentative de publication. Elle ne l'etait qu'APRES une publication reussie :
# l'essai 6 a decide AUTO_MERGE, la publication a echoue, et le journal ne
# contenait aucune decision — invariant I8 (toute decision est journalisee)
# viole. Une decision existe des qu'elle est prise, qu'elle aboutisse ou non.
"$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true

"$D/publisher.sh" "$TASK_ID" "$WT" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 || {
  transition PARKED
  # (2026-09-21, essai 6) Un echec de publication n'etait signale a personne :
  # tache mise en pause en silence, alors qu'une decision de fusion venait
  # d'etre prise (esprit de M1). Escalade dediee ; la raison P9 n'etant derivee
  # nulle part dans escalade.json, escalade.sh retombe sur L3 par defaut
  # (ntfy prioritaire, e-mail).
  ESC_PUB="$STATE_DIR/$TASK_ID.escalade-publication.json"
  jq -nc --arg v "$VERDICT" '{raisons: ["P9:publication-echouee(" + $v + ")"]}' >"$ESC_PUB"
  "$D/escalade.sh" "$TASK_ID" "$ESC_PUB" || true
  exit 20
}

transition PUBLISHED
# AVANT : "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
#   (2026-09-21) Deplacee avant la publication, ci-dessus : sinon une decision
#   dont la publication echoue n'etait jamais journalisee.
"$D/escalade.sh" "$TASK_ID" "$DECISION" || true
log "$TASK_ID : pipeline termine en $VERDICT"
