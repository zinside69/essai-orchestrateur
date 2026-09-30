#!/usr/bin/env bash
# guard-git.sh — PreToolUse Bash (ADR 0004, D1 couche 2). Pour un agent, git est
# en LECTURE SEULE : seules passent les sous-commandes de la liste blanche
# ci-dessous ; toute autre (commit, add, push, reset, stash, commit-tree,
# update-ref...) est refusee AVANT execution. Code 2 : Claude Code bloque l'outil
# et transmet le motif a l'agent (meme mecanisme que guard-ecriture.sh).
# Pourquoi une liste blanche : une liste noire oublie toujours une forme
# (commit-tree, update-ref, alias). Ce que ce hook laisserait passer, la couche 3
# le rattrape : run-task.sh compare la tete de la branche avant et apres l'agent.
# Ne vise que les agents : run-task.sh pose ORCH_AGENT_TACHE ; une session humaine
# ou de maintenance du socle n'est pas concernee. run-task.sh passe ce hook par
# --settings depuis le DEPOT PRINCIPAL : la copie du worktree ne compte pas.
set -uo pipefail
[[ -n "${ORCH_AGENT_TACHE:-}" ]] || exit 0

LECTURE="status diff log show ls-files grep blame rev-parse describe ls-tree cat-file shortlog"
refus() { printf '%s\n' "$1" >&2; exit 2; }

COMMANDE="$(jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -n "$COMMANDE" ]] || refus "Commande refusee : commande illisible (ADR 0004)."

# Decoupage grossier mais prudent : chaque separateur de commande (; & | ( ) ` et
# fin de ligne) et chaque guillemet ouvre un nouveau segment. Ainsi
# « bash -c "git commit" », « $(git commit) » ou « xargs git commit » presentent
# git en tete de segment. Un faux positif (« echo "git push" ») est refuse :
# dans le doute on ferme ; l'agent a une autre formulation.
SEGMENTS="$(printf '%s' "$COMMANDE" | tr ";&|()\`\"'" '[\n*]')"

# Mots qui precedent la vraie commande d'un segment : affectations (X=y),
# enveloppes (xargs, env, timeout...) avec leurs options et nombres, mots du shell.
ENVELOPPES=" xargs env command exec nice nohup time timeout sudo stdbuf { } ! if then else elif do while until "

while IFS= read -r segment; do
  read -ra mots <<<"$segment"
  n=${#mots[@]}; i=0
  while (( i < n )); do
    m="${mots[$i]}"
    if [[ "$m" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then ((i++)); continue; fi
    if [[ "$ENVELOPPES" == *" $m "* ]]; then
      ((i++))
      while (( i < n )) && [[ "${mots[$i]}" == -* || "${mots[$i]}" =~ ^[0-9]+[smhd]?$ ]]; do ((i++)); done
      continue
    fi
    break
  done
  (( i < n )) || continue
  [[ "${mots[$i]##*/}" == git ]] || continue

  # Options globales de git : celles qui prennent une valeur separee la sautent aussi.
  ((i++))
  while (( i < n )) && [[ "${mots[$i]}" == -* ]]; do
    case "${mots[$i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) i=$((i + 2)) ;;
      *) ((i++)) ;;
    esac
  done
  # « git » seul n'affiche que l'aide ; il ne change rien.
  (( i < n )) || continue
  sous="${mots[$i]}"
  [[ " $LECTURE " == *" $sous "* ]] && continue
  refus "git est en lecture seule pour un agent (ADR 0004) : « git $sous » refuse. Le harnais commite ton travail lui-meme, apres les controles. N'utilise que : $LECTURE."
done <<<"$SEGMENTS"
exit 0
