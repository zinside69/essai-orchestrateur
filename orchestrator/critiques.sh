#!/usr/bin/env bash
# critiques.sh — doctrine d'ecriture des agents (ADR 0002, 2026-09-24).
# Bibliotheque sourcee par gate.sh, publisher.sh, repondre.sh, run-task.sh et le
# hook .claude/hooks/guard-ecriture.sh : UNE seule definition de « fichier
# critique » et de « dans le perimetre » pour les trois verrous (empecher avant,
# detecter apres, refuser de publier). Aucune dependance a lib.sh : le hook la
# source seule, depuis le depot principal.

# Nom du compte rendu que l'agent depose a la racine de son worktree : seul
# fichier hors perimetre qu'il peut ecrire ; jamais committe (exclusion locale).
COMPTE_RENDU_AGENT=".compte-rendu-agent.json"

# Liste des fichiers critiques : celle du depot principal, jamais celle du
# worktree (meme regle que gates.json, M3). ORCH_CRITIQUES la designe pour un
# processus lance hors de ROOT (le hook de l'agent).
critiques_fichier() {
  printf '%s\n' "${ORCH_CRITIQUES:-${ROOT:?ROOT non defini}/orchestrator/fichiers-critiques.json}"
}

# motif_couvre <motif> <chemin> — glob bash ou « * » traverse les dossiers ;
# « ** » vaut « * » ; « **/x » couvre aussi « x » a la racine.
motif_couvre() {
  local motif="$1" chemin="$2" m
  m="${motif//\*\*/*}"
  # shellcheck disable=SC2053  # motif voulu : comparaison par glob
  [[ "$chemin" == $m ]] && return 0
  if [[ "$motif" == '**/'* ]]; then
    m="${motif#\*\*/}"; m="${m//\*\*/*}"
    # shellcheck disable=SC2053
    [[ "$chemin" == $m ]] && return 0
  fi
  return 1
}

# est_critique <chemin relatif> — rc 0 si le chemin est critique. Liste absente
# ou illisible : TOUT est critique (fermer par defaut, comme M2).
est_critique() {
  local chemin="$1" liste motif
  liste="$(critiques_fichier)"
  [[ -r "$liste" ]] || return 0
  while IFS= read -r motif; do
    [[ -n "$motif" ]] || continue
    motif_couvre "$motif" "$chemin" && return 0
  done < <(jq -r '((.familles // {}) | .[][]), (.projet // [])[]' "$liste" 2>/dev/null || printf '**\n')
  return 1
}

# dans_perimetre <perimetre « a/**,b/** »> <chemin> — perimetre vide : aucune
# restriction (tache sans perimetre declare ; seule la liste critique s'applique).
dans_perimetre() {
  local perimetre="$1" chemin="$2" motif
  local -a _motifs
  [[ -n "${perimetre//[[:space:],]/}" ]] || return 0
  IFS=',' read -r -a _motifs <<<"$perimetre"
  for motif in "${_motifs[@]}"; do
    motif="${motif//[[:space:]]/}"
    [[ -n "$motif" ]] || continue
    motif_couvre "$motif" "$chemin" && return 0
  done
  return 1
}

# empreinte_diff_fichier <depot> <base> <tete> <fichier> — empreinte du diff de
# CE fichier : sert a reconnaitre une modification approuvee (demande appliquee)
# tant qu'elle n'a pas ete retouchee depuis.
empreinte_diff_fichier() {
  git -C "$1" diff "$2" "$3" -- "$4" | sha256sum | cut -d' ' -f1
}

# fichiers_fautifs <depot> <base> <tete> <perimetre> [approuvees] — une ligne
# par fichier modifie qu'un agent n'avait pas le droit d'ecrire :
# « critique:<chemin> » ou « hors-perimetre:<chemin> ». Un fichier dont le diff
# a l'empreinte enregistree dans <approuvees> (« chemin<TAB>empreinte », ecrit
# par repondre.sh a l'application d'une demande) est autorise.
fichiers_fautifs() {
  local depot="$1" base="$2" tete="$3" perimetre="$4" approuvees="${5:-}" f emp
  # Liste absente : fermer par defaut, mais le DIRE — sans cela, chaque fichier
  # serait signale « critique » et l'alerte tromperait l'humain sur la cause.
  if [[ ! -r "$(critiques_fichier)" ]]; then
    printf 'liste-absente:orchestrator/fichiers-critiques.json\n'
    return 0
  fi
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$COMPTE_RENDU_AGENT" ]] || continue
    if [[ -n "$approuvees" && -f "$approuvees" ]]; then
      emp="$(empreinte_diff_fichier "$depot" "$base" "$tete" "$f")"
      grep -qxF "$f"$'\t'"$emp" "$approuvees" && continue
    fi
    if est_critique "$f"; then
      printf 'critique:%s\n' "$f"
    elif ! dans_perimetre "$perimetre" "$f"; then
      printf 'hors-perimetre:%s\n' "$f"
    fi
  done < <(git -C "$depot" diff --name-only "$base" "$tete")
}
