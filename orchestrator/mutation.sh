#!/usr/bin/env bash
# mutation.sh — le harnais joue les mutations DEMANDEES par l'agent (ADR 0003, R3).
# Usage : mutation.sh T-NNN <worktree de l'agent>
# Met a jour state/T-NNN.preuves.json ; code 0 toujours (le resultat est dans le fichier).
#
# (2026-09-25, O41) « Test vu rouge » ne prouve que l'echec AVANT le code, pas que
# le test garde le defaut ; et sur un fichier critique (migration, ADR 0002)
# l'agent ne peut pas muter lui-meme pour le prouver. Il demande donc la
# mutation (demandes_action : fichier, diff exact, controle) ; le harnais :
#   1. cree une COPIE jetable : worktree detache sur le commit de l'agent, prepare
#      comme le sien (preparer-worktree.sh du projet) — le worktree de l'agent
#      n'est jamais touche ;
#   2. y applique la mutation (git apply) et rejoue le controle designe
#      (gates.json, lu dans ROOT) ;
#   3. consigne : controle ROUGE = « rouge-vu », preuve soldee d'office ;
#      controle VERT = « reste-vert », preuve a fournir (le test ne garde pas le
#      defaut) ; mutation inapplicable ou controle inconnu = preuve a fournir.
# La copie est toujours supprimee. Tests MU1 a MU3 ; decision P16 : decide.sh.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: mutation.sh T-NNN <worktree>}"
WT_AGENT="${2:?usage: mutation.sh T-NNN <worktree>}"
PREUVES="$STATE_DIR/$TASK_ID.preuves.json"
G="$ROOT/orchestrator/gates.json"
# (2026-10-22, O80) Garde d'entree (lib.sh), avant meme de savoir s'il y a une mutation a jouer :
# un worktree au .git detourne se dit a chaque passage, jamais en silence. Test SB27.
exiger_un_worktree_intact "$WT_AGENT" "la preuve par mutation"

[[ -f "$PREUVES" ]] || exit 0
N="$(jq '[.[] | select(.type == "mutation" and .statut == "a_fournir")] | length' "$PREUVES")"
(( N > 0 )) || exit 0
require git jq

# (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
# AVANT : COMMIT="$(git -C "$WT_AGENT" rev-parse HEAD)"
COMMIT="$(git_du_worktree "$WT_AGENT" rev-parse HEAD)"
mkdir -p "$LOG_DIR"

# consigner <id> <resultat> <statut> <detail>
consigner() {
  jq --arg id "$1" --arg r "$2" --arg s "$3" --arg d "$4" --arg ts "$(date -u +%FT%TZ)" \
    'map(if .id == $id then . + {resultat:$r, statut:$s, detail_mutation:$d, le:$ts}
         + (if $s == "soldee" then {origine:"harnais"} else {} end) else . end)' \
    "$PREUVES" >"$PREUVES.tmp" && mv "$PREUVES.tmp" "$PREUVES"
  log "$TASK_ID : mutation $1 -> $2"
}

while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  controle="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .controle // "test"' "$PREUVES")"
  cmd="$(jq -r --arg c "$controle" '.gates[$c] // empty' "$G" 2>/dev/null || true)"
  if [[ -z "$cmd" ]]; then
    consigner "$id" inapplicable a_fournir "controle « $controle » absent de gates.json"
    continue
  fi
  # (2026-10-22, defaut 128, O80) Le sandbox doit pouvoir demarrer avant toute copie. Sans
  # lui, preuve a fournir : un refus ne vaut jamais « rouge vu ». Tests SB14 et SB16.
  if ! sandbox_disponible; then
    consigner "$id" inapplicable a_fournir "bwrap introuvable ou incapable de demarrer : controle non lance, aucun code de l'agent hors sandbox"
    continue
  fi
  copie="$(mktemp -d)/mutation-$TASK_ID"
  journal="$LOG_DIR/mutation-$TASK_ID-$id.log"
  if ! sous_verrou_depot git -C "$ROOT" worktree add -q --detach "$copie" "$COMMIT" >"$journal" 2>&1; then
    consigner "$id" inapplicable a_fournir "copie jetable impossible a creer (voir $journal)"
    rmdir "$(dirname "$copie")" 2>/dev/null || true
    continue
  fi
  (
    preparer_worktree "$copie"
    jq -r --arg id "$id" '.[] | select(.id == $id) | .diff' "$PREUVES" >"$copie/.mutation.diff"
    # (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
    # AVANT : if ! git -C "$copie" apply "$copie/.mutation.diff" >>"$journal" 2>&1; then
    if ! git_du_worktree "$copie" apply "$copie/.mutation.diff" >>"$journal" 2>&1; then
      consigner "$id" inapplicable a_fournir "git apply refuse la mutation (voir $journal)"
      exit 0
    fi
    rm -f "$copie/.mutation.diff"
    # (2026-10-18, defaut 128, O80) Le controle rejoue le code de l'agent : il tourne dans
    # le sandbox (lib.sh), dont la disponibilite est verifiee avant la copie. Test SB13.
    # AVANT :     if ( cd "$copie" && bash -c "$cmd" ) >>"$journal" 2>&1; then
    if lancer_dans_le_sandbox "$copie" bash -c "$cmd" >>"$journal" 2>&1; then
      consigner "$id" reste-vert a_fournir "controle « $controle » vert sous la mutation : le test ne garde pas le defaut"
    else
      consigner "$id" rouge-vu soldee "controle « $controle » rouge sous la mutation"
    fi
  ) || consigner "$id" inapplicable a_fournir "preparation de la copie en echec (voir $journal)"
  # (2026-10-18, defaut 128) Caches de vite partages vides avant de retirer la copie. Test SB15.
  vider_caches_partages_agent "$copie" || true
  sous_verrou_depot git -C "$ROOT" worktree remove --force "$copie" >>"$journal" 2>&1 || rm -rf "$copie"
  rmdir "$(dirname "$copie")" 2>/dev/null || true
done < <(jq -r '.[] | select(.type == "mutation" and .statut == "a_fournir") | .id' "$PREUVES")
exit 0
