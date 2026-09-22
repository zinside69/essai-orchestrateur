#!/usr/bin/env bash
# sauvegarde.sh — commit l'etat sur la branche orpheline ; ne la pousse que vers ORCH_ETAT_REMOTE.
# AVANT : sauvegarde.sh — commit l'etat sur la branche orpheline et la pousse.
#   (2026-09-21) Ligne 2 relue par generer-spec.sh pour l'inventaire : elle doit
#   dire ce que fait le script. Le push vers origin a disparu le meme jour (58b3d20).
# Usage : sauvegarde.sh [--dry-run]
#         sauvegarde.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
BRANCHE_ETAT="${BRANCHE_ETAT:-orchestrator/etat}"
WT_ETAT="$(dirname "$ROOT")/wt-etat"
DRY_RUN=0

# (2026-09-21) Le push est OPT-IN. Par defaut, l'etat est committe sur la branche
# orpheline LOCALE et ne quitte pas la machine. journal/ contient les raisons, les
# decisions et le texte des notifications, donc du contenu de projet : le pousser
# sur « origin », comme le faisait ce script, c'etait le publier sur le depot de
# code du projet orchestre, sans aucune porte. Pour pousser, nommer le remote :
# ORCH_ETAT_REMOTE=<nom>. Un nom qui ne designe aucun remote arrete tout AVANT le
# commit, plutot que d'echouer apres.
ORCH_ETAT_REMOTE="${ORCH_ETAT_REMOTE:-}"

# (2026-09-21, 58b3d20) Texte d'aide mis en accord avec le push opt-in. Lignes
# d'origine citees ici : un commentaire place dans le texte ci-dessous
# s'afficherait avec l'aide.
# AVANT : Copie la portion versionnée de .orchestrator vers un worktree dédié à la branche orchestrator/etat,
# AVANT : committe les changements et pousse la branche d'état.
show_help() {
  cat <<'EOF'
Usage:
  sauvegarde.sh [--dry-run]
  sauvegarde.sh --help

Copie la portion versionnée de .orchestrator vers un worktree dédié à la branche orchestrator/etat
et committe les changements. La branche reste locale : elle n'est poussée que si
ORCH_ETAT_REMOTE nomme un remote existant (jamais « origin » par défaut).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require git jq rsync
mkdir -p "$ETAT_DIR/taches" "$ORCH_DIR/journal"

if [[ -n "$ORCH_ETAT_REMOTE" ]] && ! git -C "$ROOT" remote get-url "$ORCH_ETAT_REMOTE" >/dev/null 2>&1; then
  die "ORCH_ETAT_REMOTE=$ORCH_ETAT_REMOTE ne designe aucun remote — rien n'a ete committe"
fi

if [[ ! -d "$WT_ETAT/.git" && ! -f "$WT_ETAT/.git" ]]; then
  if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCHE_ETAT"; then
    git -C "$ROOT" worktree add "$WT_ETAT" "$BRANCHE_ETAT" >/dev/null
  else
    die "branche $BRANCHE_ETAT inexistante — la creer avant la premiere sauvegarde"
  fi
fi

mkdir -p "$WT_ETAT/.orchestrator/etat/taches" "$WT_ETAT/.orchestrator/journal"

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN sauvegarde] %s -> %s/.orchestrator/etat/taches/\n' "$ETAT_DIR/taches/" "$WT_ETAT"
  printf '[DRY-RUN sauvegarde] %s -> %s/.orchestrator/etat/\n' "$ETAT_DIR/graphe.json" "$WT_ETAT"
  printf '[DRY-RUN sauvegarde] %s -> %s/.orchestrator/etat/\n' "$ETAT_DIR/escalades/" "$WT_ETAT"
  printf '[DRY-RUN sauvegarde] %s -> %s/.orchestrator/journal/\n' "$ORCH_DIR/journal/" "$WT_ETAT"
  printf '[DRY-RUN sauvegarde] push : %s\n' "${ORCH_ETAT_REMOTE:-aucun (ORCH_ETAT_REMOTE non defini)}"
  exit 0
fi

rsync -a --delete "$ETAT_DIR/taches/" "$WT_ETAT/.orchestrator/etat/taches/"
[[ -f "$ETAT_DIR/graphe.json" ]] && rsync -a "$ETAT_DIR/graphe.json" "$WT_ETAT/.orchestrator/etat/"
[[ -d "$ETAT_DIR/escalades" ]] && rsync -a "$ETAT_DIR/escalades/" "$WT_ETAT/.orchestrator/etat/escalades/"
rsync -a "$ORCH_DIR/journal/" "$WT_ETAT/.orchestrator/journal/"

cd "$WT_ETAT"
git add -f -A .orchestrator

if git diff --cached --quiet; then
  log "Etat inchange — rien a sauvegarder"
  exit 0
fi

NB="$(git diff --cached --numstat | wc -l | tr -d ' ')"
git -c user.name="orchestrateur" -c user.email="orchestrateur@local" commit -q -m "etat: $(date -u +%FT%TZ) — $NB fichiers"
if [[ -z "$ORCH_ETAT_REMOTE" ]]; then
  log "Etat sauvegarde en local ($NB fichiers) — push non demande (ORCH_ETAT_REMOTE vide)"
  exit 0
fi
# (2026-09-21, 58b3d20) Push vers le remote NOMME, jamais vers origin par
# defaut : origin, c'est le depot de code du projet orchestre.
# AVANT : git push -u origin "$BRANCHE_ETAT" >/dev/null
# AVANT : log "Etat sauvegarde et pousse ($NB fichiers)"
git push -u "$ORCH_ETAT_REMOTE" "$BRANCHE_ETAT" >/dev/null
log "Etat sauvegarde et pousse vers $ORCH_ETAT_REMOTE ($NB fichiers)"
