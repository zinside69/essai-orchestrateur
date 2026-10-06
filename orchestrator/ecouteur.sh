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
# (2026-10-06, O65 partie 3) « lancer » : bouton propose apres une reponse ntfy
# qui remet la tache en READY ; lance scheduler.sh --tache. Tests LA1 a LA6.
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
# (2026-10-06, O65 partie 3) Duree de validite d'un bouton « Lancer » (choix de l'operateur).
DUREE_PROPOSITION_LANCEMENT_HEURES=24

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

# projets_declares : les autres projets servis par cet ecouteur, un par ligne.
# (2026-09-25, O36) ORCH_PROJETS (~/.orchestrateur.env) : chemins ABSOLUS de
# projets orchestres, separes par « : », sans espace. Un chemin relatif, ou sans
# .orchestrator/, est ignore et signale : jamais resolu depuis le dossier courant.
# Sans ORCH_PROJETS : aucun, l'ecouteur ne sert que son projet (comme avant).
projets_declares() {
  local liste p
  local -a chemins
  liste="$(lire_var_env ORCH_PROJETS)" || return 0
  IFS=':' read -ra chemins <<<"$liste"
  for p in "${chemins[@]}"; do
    [[ -n "$p" && "$p" != "$ROOT" ]] || continue
    if [[ "$p" != /* || ! -d "$p/.orchestrator" ]]; then
      log "ecouteur : ORCH_PROJETS : « $p » ignore (chemin absolu d'un projet orchestre attendu)"
      continue
    fi
    printf '%s\n' "$p"
  done
}

# proposer_lancement_si_ready <T-NNN>
# (2026-10-06, O65 partie 3) Si la reponse a remis la tache en READY, envoie une
# notification « Tache prete » avec un bouton « Lancer » : jeton de 128 bits,
# valable 24 h, range dans etat/lancements.jsonl du projet de la tache. Appele
# dans traiter(), donc avec ROOT et ORCH_STATE du projet de la tache. Test LA1.
proposer_lancement_si_ready() {
  local tache="$1" orch_projet etat jeton expiration sujet_reponse sujet_alerte actions
  orch_projet="${ORCH_STATE:-$ROOT/.orchestrator}"
  etat="$(sed -n 's/^etat=//p' "$orch_projet/etat/taches/$tache.env" 2>/dev/null | head -1)"
  # Seule une tache READY attend un lancement
  [[ "$etat" == READY ]] || return 0
  # Sans sujet de reponse ni sujet d'alerte, aucun bouton possible
  sujet_reponse="$(lire_var_env NTFY_TOPIC_REPONSE)" || return 0
  sujet_alerte="$(lire_var_env NTFY_TOPIC)" || return 0
  jeton="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  expiration="$(date -u -d "+${DUREE_PROPOSITION_LANCEMENT_HEURES} hours" +%FT%TZ)"
  jq -nc --arg t "$tache" --arg j "$jeton" --arg ts "$(date -u +%FT%TZ)" --arg exp "$expiration" \
    '{tache:$t, jeton:$j, statut:"proposee", propose_le:$ts, expire_le:$exp}' >>"$orch_projet/etat/lancements.jsonl"
  actions="$(actions_ntfy "$tache" "$jeton" "$sujet_reponse" lancer)"
  # Sujet et jeton dans le fichier -K de curl_prive, jamais en argument (defaut 46)
  curl_prive "https://ntfy.sh/$sujet_alerte" "Actions: $actions" -- -sS -H "Title: Tache prete" -H "Tags: rocket" \
    -d "$tache est prete (READY). Lancer d'ici (valable ${DUREE_PROPOSITION_LANCEMENT_HEURES} h, plafond du jour applique), ou au PC : orchestrator/scheduler.sh --tache $tache" \
    >/dev/null 2>&1 || true
  log "ecouteur : lancement de $tache propose sur le telephone (valable ${DUREE_PROPOSITION_LANCEMENT_HEURES} h)"
}

# lancer_tache_proposee <T-NNN> <jeton> <corps> : 0 si la tache est lancee.
# (2026-10-06, O65 partie 3) Jeton d'une proposition « proposee » et non expiree
# de cette tache, cherche dans le projet de l'ecouteur puis ceux d'ORCH_PROJETS.
# Consomme seulement si le lancement part : un refus du planificateur (plafond du
# jour, conflit...) le laisse valable jusqu'a son expiration. La raison du refus
# revient sur le telephone. Tests LA2 a LA6.
lancer_tache_proposee() {
  local tache="$1" jeton="$2" corps="$3" projet orch_projet lancements trouve=0 sortie raison
  while IFS= read -r projet; do
    if [[ "$projet" == "$ROOT" ]]; then orch_projet="$ORCH_DIR"; else orch_projet="$projet/.orchestrator"; fi
    lancements="$orch_projet/etat/lancements.jsonl"
    if jq -e --arg t "$tache" --arg j "$jeton" --arg now "$(date -u +%FT%TZ)" \
         'select(.tache == $t and .jeton == $j and .statut == "proposee" and .expire_le > $now)' \
         "$lancements" >/dev/null 2>&1; then
      trouve=1; break
    fi
  done < <(printf '%s\n' "$ROOT"; projets_declares)
  # Jeton inconnu, deja utilise ou expire
  if (( trouve == 0 )); then
    journaliser refuse jeton-lancement "$corps"
    log "ecouteur : $tache lancer refuse (jeton inconnu, deja utilise ou expire)"
    confirmer "Refuse : $tache lancer (jeton inconnu, deja utilise ou expire)"
    return 1
  fi
  # Le planificateur DU projet de la tache decide : memes gardes qu'au PC
  if sortie="$(cd "$projet" && ROOT="$projet" ORCH_STATE="$orch_projet" "$projet/orchestrator/scheduler.sh" --tache "$tache" 2>&1)"; then
    printf '%s\n' "$sortie" >>"$LOG_DIR/ecouteur.log"
    jq -c --arg t "$tache" --arg j "$jeton" --arg ts "$(date -u +%FT%TZ)" \
      'if .tache == $t and .jeton == $j then . + {statut:"utilisee", utilisee_le:$ts} else . end' \
      "$lancements" >"$lancements.tmp" && mv "$lancements.tmp" "$lancements"
    journaliser execute lancer "$corps"
    log "ecouteur : $tache lancee"
    confirmer "Lancee : $tache"
    return 0
  fi
  printf '%s\n' "$sortie" >>"$LOG_DIR/ecouteur.log"
  raison="$(grep -m1 'non lancee' <<<"$sortie" | sed 's/^\[ERREUR\] //' || true)"
  [[ -n "$raison" ]] || raison="planificateur en echec (voir $LOG_DIR/ecouteur.log sur le PC)"
  journaliser refuse planificateur "$corps"
  log "ecouteur : $tache non lancee : $raison"
  confirmer "Non lancee : $raison"
  return 1
}

# traiter <corps> : 0 si la reponse a ete executee, 1 sinon (refus ou echec).
traiter() {
  local corps="$1" tache reponse jeton
  # 1. Forme stricte, sur le texte brut : trois mots, rien d'autre.
  # AVANT :   if [[ ! "$corps" =~ ^(T-[0-9]{1,6})\ (republier|approuver|refuser|reporter)\ ([0-9a-f]{32})$ ]]; then
  #   (2026-10-06, O65 partie 3) « lancer » s'ajoute a la liste fermee.
  if [[ ! "$corps" =~ ^(T-[0-9]{1,6})\ (republier|approuver|refuser|reporter|lancer)\ ([0-9a-f]{32})$ ]]; then
    journaliser refuse forme "$corps"
    log "ecouteur : message refuse (forme)"
    return 1
  fi
  tache="${BASH_REMATCH[1]}"; reponse="${BASH_REMATCH[2]}"; jeton="${BASH_REMATCH[3]}"
  # (2026-10-06, O65 partie 3) « lancer » ne repond a aucune escalade : son jeton
  # est celui d'une proposition de lancement (etat/lancements.jsonl).
  if [[ "$reponse" == lancer ]]; then
    lancer_tache_proposee "$tache" "$jeton" "$corps"
    return $?
  fi
  # (2026-09-25, O36) Quel projet ? Celui dont une escalade porte CE jeton pour
  # CETTE tache : le projet de l'ecouteur d'abord, puis ceux d'ORCH_PROJETS. Le
  # jeton (128 bits, usage unique) suffit a les departager, meme quand deux
  # projets ont une tache du meme numero. Trouve ailleurs : la suite de traiter()
  # lit SES escalades et lance SON repondre.sh — d'ou les variables locales
  # ci-dessous, qui masquent celles du projet de l'ecouteur pour cet appel seul
  # (journal de l'ecouteur et confirmations inchanges). Tests MP1 a MP3.
  local p esc_p trouve=0
  while IFS= read -r p; do
    if [[ "$p" == "$ROOT" ]]; then esc_p="$JOURNAL_ESC_T"; else esc_p="$p/.orchestrator/etat/escalades/escalades.jsonl"; fi
    if jq -e --arg t "$tache" --arg j "$jeton" 'select(.tache == $t and .jeton == $j)' "$esc_p" >/dev/null 2>&1; then
      trouve=1; break
    fi
  done < <(printf '%s\n' "$ROOT"; projets_declares)
  if (( trouve == 1 )) && [[ "$p" != "$ROOT" ]]; then
    local JOURNAL_ESC_T="$esc_p"
    local -x ROOT="$p" ORCH_STATE="$p/.orchestrator"
    log "ecouteur : $tache $reponse — jeton d'une escalade du projet $p"
  fi
  # 2 et 3. Escalade ouverte de CETTE tache, avec CE jeton, non expiree.
  if ! jq -e --arg t "$tache" --arg j "$jeton" --arg now "$(date -u +%FT%TZ)" \
       'select(.tache == $t and .statut == "ouverte" and .jeton == $j and .expire_le > $now)' \
       "$JOURNAL_ESC_T" >/dev/null 2>&1; then
    journaliser refuse jeton "$corps"
    log "ecouteur : $tache $reponse refuse (jeton inconnu, deja utilise ou expire)"
    confirmer "Refuse : $tache $reponse (jeton inconnu, deja utilise ou escalade expiree)"
    return 1
  fi
  # (2026-09-25, O34) Escalade dont le diff n'a pas pu etre montre en entier
  # dans la notification (demandes d'ecriture trop longues) : l'approbation a
  # distance est interdite — le bouton est retire, mais « Refuser » porte le
  # meme jeton. L'escalade reste ouverte : approuver depuis le PC. Test EP4.
  if [[ "$reponse" == approuver ]] \
     && jq -e --arg t "$tache" --arg j "$jeton" \
          'select(.tache == $t and .statut == "ouverte" and .jeton == $j and .approbation_distante == false)' \
          "$JOURNAL_ESC_T" >/dev/null 2>&1; then
    journaliser refuse approbation-distante "$corps"
    log "ecouteur : $tache approuver refuse (diff non montre dans la notification — approuver depuis le PC)"
    confirmer "Refuse : $tache approuver (diff trop long pour le telephone — lire les demandes et approuver depuis le PC)"
    return 1
  fi
  if RESPONSE_ORIGINE=ntfy "$ROOT/orchestrator/repondre.sh" "$tache" "$reponse" "via bouton ntfy" \
       >>"$LOG_DIR/ecouteur.log" 2>&1; then
    journaliser execute "$reponse" "$corps"
    log "ecouteur : $tache $reponse execute"
    confirmer "Execute : $tache $reponse"
    proposer_lancement_si_ready "$tache"
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
