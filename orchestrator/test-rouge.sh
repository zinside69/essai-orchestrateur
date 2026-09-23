#!/usr/bin/env bash
# test-rouge.sh — mesure si les tests de l'agent echouent SANS son code.
# Usage : test-rouge.sh T-NNN
#
# (2026-09-22, feuille de route du cp32) Un test qui passe aussi sans le
# correctif ne prouve pas le correctif. A l'essai 6 du bac a sable iziGSM, la
# revue l'avait releve (« trois tests qui passeraient sans le correctif ») :
# c'etait un jugement du modele. Ici c'est une mesure du harnais :
#   1. les fichiers de test ajoutes ou modifies par l'agent (motifs de
#      gates.json -> test_rouge.fichiers) ;
#   2. un worktree TEMPORAIRE sur l'integration, sans le code de l'agent, ou
#      l'on depose ses seuls fichiers de test ;
#   3. le controle designe (test_rouge.controle) y est lance : il DOIT echouer.
# Resultat dans state/T-NNN.test-rouge.json, champ statut :
#   rouge          — les tests echouent sans le code : ils prouvent quelque chose
#   jamais-rouge   — ils passent aussi sans le code : ils ne prouvent rien
#   aucun-test     — l'agent n'a ajoute ni modifie aucun fichier de test
#   non-configure  — pas de bloc test_rouge dans gates.json (comportement d'avant)
#   erreur         — mesure impossible (controle introuvable, worktree)
# decide.sh en tire la regle Q3. Sortie toujours 0 : la mesure informe la
# decision, elle ne l'interrompt pas. Tests A1 a A4.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: test-rouge.sh T-NNN}"
BRANCH="$AGENT_BRANCH_PREFIX/$TASK_ID"
SORTIE="$STATE_DIR/$TASK_ID.test-rouge.json"
JOURNAL="$LOG_DIR/test-rouge-$TASK_ID.log"
G="$ROOT/orchestrator/gates.json"   # celui du depot principal, jamais celui de l'agent (R1)
WT_ROUGE="$WORKTREE_ROOT/$TASK_ID-rouge"

require git jq

ecrire() {  # ecrire <statut> [rc] ; fichiers et controle viennent du contexte
  jq -nc --arg t "$TASK_ID" --arg s "$1" --arg c "${CONTROLE:-}" --argjson rc "${2:-null}" \
    --argjson f "$(printf '%s\n' "${FICHIERS[@]+"${FICHIERS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '{tache:$t, statut:$s, controle:$c, fichiers:$f, rc:$rc}' >"$SORTIE"
  log "test-rouge $TASK_ID : $1"
}
FICHIERS=()
CONTROLE=""

if [[ ! -f "$G" ]] || ! jq -e '.test_rouge.fichiers | length > 0' "$G" >/dev/null 2>&1; then
  ecrire non-configure; exit 0
fi
CONTROLE="$(jq -r '.test_rouge.controle // "test"' "$G")"
CMD="$(jq -r --arg c "$CONTROLE" '.gates[$c] // empty' "$G")"
[[ -n "$CMD" ]] || { ecrire erreur; exit 0; }

# 1. Fichiers de test touches par l'agent (ajoutes, modifies, renommes).
mapfile -t MOTIFS < <(jq -r '.test_rouge.fichiers[]' "$G")
while IFS= read -r f; do
  for m in "${MOTIFS[@]}"; do
    # Motif de chemin a la maniere des gates : dans [[ == ]], * couvre aussi « / ».
    # shellcheck disable=SC2053
    if [[ "$f" == $m ]]; then FICHIERS+=("$f"); break; fi
  done
done < <(git -C "$ROOT" diff --name-only --diff-filter=AMR "$INTEGRATION_BRANCH...$BRANCH")
(( ${#FICHIERS[@]} > 0 )) || { ecrire aucun-test; exit 0; }

# 2. Worktree temporaire sur l'integration, avec les seuls tests de l'agent.
if git -C "$ROOT" worktree list --porcelain | grep -q "$WT_ROUGE"; then
  git -C "$ROOT" worktree remove --force "$WT_ROUGE" || true
fi
nettoyer() { git -C "$ROOT" worktree remove --force "$WT_ROUGE" >/dev/null 2>&1 || true; }
trap nettoyer EXIT
if ! git -C "$ROOT" worktree add -q --detach "$WT_ROUGE" "$INTEGRATION_BRANCH" >>"$JOURNAL" 2>&1; then
  ecrire erreur; exit 0
fi
preparer_worktree "$WT_ROUGE"
git -C "$WT_ROUGE" checkout -q "$BRANCH" -- "${FICHIERS[@]}"

# 3. Le controle doit echouer sans le code de l'agent.
set +e
( cd "$WT_ROUGE" && bash -c "$CMD" ) >>"$JOURNAL" 2>&1
RC=$?
set -e
if (( RC != 0 )); then ecrire rouge "$RC"; else ecrire jamais-rouge "$RC"; fi
