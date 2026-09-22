#!/usr/bin/env bash
# restore.sh — reconstruit completement l'etat de l'orchestrateur depuis git.
# Usage : restore.sh [--dry-run] <chemin-du-depot> [remote]
#         restore.sh --help
set -Eeuo pipefail

DRY_RUN=0
DEPOT=""
REMOTE="origin"
BRANCHE_ETAT="${BRANCHE_ETAT:-orchestrator/etat}"

show_help() {
  cat <<'EOF'
Usage:
  restore.sh [--dry-run] <chemin-du-depot> [remote]
  restore.sh --help

Reconstruit .orchestrator/etat et .orchestrator/journal depuis la branche d'état,
vérifie l'intégrité du journal, recompile le graphe puis réconcilie l'état.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      if [[ -z "$DEPOT" ]]; then
        DEPOT="$1"
      elif [[ "$REMOTE" == "origin" ]]; then
        REMOTE="$1"
      else
        echo "argument inattendu : $1" >&2
        exit 1
      fi
      shift ;;
  esac
done

[[ -n "$DEPOT" ]] || { echo "usage: restore.sh [--dry-run] <chemin-du-depot> [remote]" >&2; exit 1; }
cd "$DEPOT" || { echo "depot introuvable : $DEPOT" >&2; exit 1; }
WT_ETAT="$(dirname "$PWD")/wt-etat"

if (( DRY_RUN == 1 )); then
  echo "[DRY-RUN 1/6] fetch $REMOTE $BRANCHE_ETAT"
  echo "[DRY-RUN 2/6] restauration .orchestrator/etat et .orchestrator/journal"
  echo "[DRY-RUN 3/6] verify-journal.sh .orchestrator/journal/decisions.jsonl"
  echo "[DRY-RUN 4/6] graphe.sh todo.md"
  echo "[DRY-RUN 5/6] reconcile.sh"
  echo "[DRY-RUN 6/6] scheduler.sh --inventaire"
  exit 0
fi

echo "[1/6] Recuperation de la branche d'etat"
git fetch "$REMOTE" "$BRANCHE_ETAT" >/dev/null
mkdir -p "$WT_ETAT"
git worktree add "$WT_ETAT" "$REMOTE/$BRANCHE_ETAT" --detach >/dev/null 2>&1 || true

echo "[2/6] Restauration de l'etat et des journaux"
mkdir -p .orchestrator/etat .orchestrator/journal .orchestrator/logs .orchestrator/state
cp -a "$WT_ETAT/.orchestrator/etat/." .orchestrator/etat/ 2>/dev/null || true
cp -a "$WT_ETAT/.orchestrator/journal/." .orchestrator/journal/ 2>/dev/null || true

echo "[3/6] Verification de la chaine du journal"
if [[ -x orchestrator/verify-journal.sh && -f .orchestrator/journal/decisions.jsonl ]]; then
  orchestrator/verify-journal.sh .orchestrator/journal/decisions.jsonl || {
    echo "CHAINE ROMPUE — arret. Ne pas reprendre avant inspection." >&2
    exit 1
  }
fi

echo "[4/6] Recompilation du graphe depuis le manifeste"
if [[ -x orchestrator/graphe.sh && -f todo.md ]]; then
  orchestrator/graphe.sh todo.md >/dev/null || echo "AVERTISSEMENT : recompilation du graphe en echec"
fi

echo "[5/6] Reconciliation de l'etat des taches avec le journal"
if [[ -x orchestrator/reconcile.sh ]]; then
  orchestrator/reconcile.sh --dry-run || true
fi

echo "[6/6] Etat du pipeline"
if [[ -x orchestrator/scheduler.sh ]]; then
  orchestrator/scheduler.sh --inventaire || true
fi

echo
echo "Reconstruction terminee. Verifier : escalades ouvertes, taches BLOCKED, disjoncteur."
