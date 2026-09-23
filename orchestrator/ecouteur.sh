#!/usr/bin/env bash
# ecouteur.sh — execute les reponses envoyees par les boutons ntfy du telephone.
# Usage : ecouteur.sh                  suit le sujet de reponse (sans fin)
#         ecouteur.sh --message "..."  traite un seul message (tests, depannage)
#         ecouteur.sh --help
#
# (2026-09-22, choix de l'operateur : repondre depuis le telephone) escalade.sh
# ajoute a chaque alerte (hors L1) des boutons qui publient « T-NNN <reponse>
# <jeton> » sur le sujet NTFY_TOPIC_REPONSE (~/.orchestrateur.env). Ce sujet est
# public en ecriture pour qui connait son nom : un message n'est execute que si
#   1. il a exactement la forme attendue (tache, reponse d'une liste fermee,
#      jeton de 32 caracteres hexadecimaux) — le texte n'est JAMAIS evalue ;
#   2. son jeton est celui d'une escalade OUVERTE de cette tache ;
#   3. cette escalade n'a pas expire.
# La reponse passe alors par repondre.sh (origine « ntfy »), qui ferme
# l'escalade : le jeton ne sert qu'une fois. Chaque message, execute ou refuse,
# est journalise (journal/ecouteur.jsonl) ; l'issue est confirmee sur le sujet
# d'alerte. « modifier » n'a pas de bouton : il exige un texte. Tests B1 a B5.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
JOURNAL_ESC_T="$ETAT_DIR/escalades/escalades.jsonl"
JOURNAL_ECOUTE="$ORCH_DIR/journal/ecouteur.jsonl"
DERNIER="$ETAT_DIR/ecouteur.dernier"   # identifiant ntfy du dernier message lu
ORCHESTRATEUR_ENV="${ORCHESTRATEUR_ENV:-$HOME/.orchestrateur.env}"
MESSAGE_SEUL=""
MODE_SEUL=0

# Copie de lire_var_env d'escalade.sh (qui n'est pas sourcable : il s'execute
# a l'inclusion). Meme regle : l'environnement d'abord, puis le fichier.
lire_var_env() {
  local nom="$1" valeur ligne
  valeur="${!nom:-}"
  if [[ -n "$valeur" ]]; then printf '%s' "$valeur"; return 0; fi
  [[ -r "$ORCHESTRATEUR_ENV" ]] || return 1
  ligne="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${nom}[[:space:]]*=" "$ORCHESTRATEUR_ENV" 2>/dev/null)" || return 1
  valeur="${ligne#*=}"
  valeur="${valeur#\"}"; valeur="${valeur%\"}"
  valeur="${valeur#\'}"; valeur="${valeur%\'}"
  valeur="$(printf '%s' "$valeur" | tr -d '[:space:]')"
  [[ -n "$valeur" ]] || return 1
  printf '%s' "$valeur"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) sed -n '2,5p' "$0" | sed 's/^# //'; exit 0 ;;
    --message) MESSAGE_SEUL="${2?valeur manquante pour --message}"; MODE_SEUL=1; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq
mkdir -p "$ORCH_DIR/journal" "$ETAT_DIR"

journaliser() {  # journaliser <issue> <raison> <corps>
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg i "$1" --arg r "$2" --arg c "$3" \
    '{ts:$ts, issue:$i, raison:$r, corps:($c | .[0:200])}' >>"$JOURNAL_ECOUTE"
}

confirmer() {  # confirmer <texte> : sur le sujet d'alerte, si configure
  local sujet
  sujet="$(lire_var_env NTFY_TOPIC)" || return 0
  # AVANT :   curl -sS -H "Title: Reponse recue" -H "Tags: robot" -d "$1" "https://ntfy.sh/$sujet" >/dev/null 2>&1 || true
  #   (2026-09-23, defaut 46) le sujet d'alerte se lisait dans `ps` : URL par curl_prive. Test B6.
  curl_prive "https://ntfy.sh/$sujet" -- -sS -H "Title: Reponse recue" -H "Tags: robot" -d "$1" >/dev/null 2>&1 || true
}

# traiter <corps> : 0 si la reponse a ete executee, 1 sinon (refus ou echec).
traiter() {
  local corps="$1" tache reponse jeton
  # 1. Forme stricte, sur le texte brut : trois mots, rien d'autre.
  if [[ ! "$corps" =~ ^(T-[0-9]{1,6})\ (republier|approuver|refuser|reporter)\ ([0-9a-f]{32})$ ]]; then
    journaliser refuse forme "$corps"
    log "ecouteur : message refuse (forme)"
    return 1
  fi
  tache="${BASH_REMATCH[1]}"; reponse="${BASH_REMATCH[2]}"; jeton="${BASH_REMATCH[3]}"
  # 2 et 3. Escalade ouverte de CETTE tache, avec CE jeton, non expiree.
  if ! jq -e --arg t "$tache" --arg j "$jeton" --arg now "$(date -u +%FT%TZ)" \
       'select(.tache == $t and .statut == "ouverte" and .jeton == $j and .expire_le > $now)' \
       "$JOURNAL_ESC_T" >/dev/null 2>&1; then
    journaliser refuse jeton "$corps"
    log "ecouteur : $tache $reponse refuse (jeton inconnu, deja utilise ou expire)"
    confirmer "Refuse : $tache $reponse (jeton inconnu, deja utilise ou escalade expiree)"
    return 1
  fi
  if RESPONSE_ORIGINE=ntfy "$ROOT/orchestrator/repondre.sh" "$tache" "$reponse" "via bouton ntfy" \
       >>"$LOG_DIR/ecouteur.log" 2>&1; then
    journaliser execute "$reponse" "$corps"
    log "ecouteur : $tache $reponse execute"
    confirmer "Execute : $tache $reponse"
    return 0
  fi
  journaliser echec "$reponse" "$corps"
  log "ecouteur : $tache $reponse en echec (voir $LOG_DIR/ecouteur.log)"
  confirmer "Echec : $tache $reponse (voir $LOG_DIR/ecouteur.log sur le PC)"
  return 1
}

if (( MODE_SEUL == 1 )); then
  traiter "$MESSAGE_SEUL"
  exit $?
fi

# --- Boucle : flux JSON du sujet de reponse ----------------------------------
require curl
SUJET="$(lire_var_env NTFY_TOPIC_REPONSE)" || die "NTFY_TOPIC_REPONSE absent de $ORCHESTRATEUR_ENV : pas de boutons, rien a ecouter"
cd "$ROOT"
log "ecouteur : a l'ecoute de ntfy.sh/<sujet de reponse> pour $ROOT"
while true; do
  # Reprise apres coupure sans rejouer les messages deja lus : since=<dernier id>.
  depuis="$(cat "$DERNIER" 2>/dev/null || printf 'all')"
  while IFS= read -r ligne; do
    [[ "$(jq -r '.event // empty' <<<"$ligne" 2>/dev/null)" == "message" ]] || continue
    jq -r '.id' <<<"$ligne" >"$DERNIER"
    traiter "$(jq -r '.message // ""' <<<"$ligne")" || true
  # AVANT :   done < <(curl -sSN "https://ntfy.sh/$SUJET/json?since=$depuis" 2>/dev/null || true)
  #   (2026-09-23, defaut 46) le sujet de reponse restait lisible dans `ps` et
  #   `systemctl status` tant que l'ecouteur tournait : URL par curl_prive. Test B6.
  done < <(curl_prive "https://ntfy.sh/$SUJET/json?since=$depuis" -- -sSN 2>/dev/null || true)
  sleep 5   # flux coupe (reseau, veille) : on se reconnecte
done
