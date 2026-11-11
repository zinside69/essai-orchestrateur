#!/usr/bin/env bash
# etat-tache.sh — chaine d'etapes d'une tache : conception, agent, controles, relecture, PR, fin.
# Usage : etat-tache.sh T-NNN
#         etat-tache.sh --help
#
# (2026-11-08) Vue d'avancement demandee par l'operateur : une ligne par etape, avec son etat
# (✔ fait, ✘ en echec, « en cours… », « à venir ») et un detail court. Lecture seule : le script
# lit l'etat de la tache (ORCH_STATE) et n'ecrit rien. Tests ET1 a ET7.
#
# Passages multiples : une tache peut repasser plusieurs fois (correction, relance). Le fichier
# d'une etape ne compte pour le passage en cours que s'il est au moins aussi recent que celui de
# l'etape d'avant ; sinon il vient d'un passage precedent, et l'etape est la premiere non faite.
# La comparaison de dates passe par « -ot » de bash, identique sous GNU et sous BSD (Mac).
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

show_help() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  show_help
  exit 0
fi
TASK_ID="${1:?usage: etat-tache.sh T-NNN}"
require jq

FICHE="$ORCH_DIR/etat/taches/$TASK_ID.env"
[[ -f "$FICHE" ]] || die "tache inconnue : $TASK_ID (aucune fiche $FICHE)"

FICHIER_CONCEPTION="$STATE_DIR/$TASK_ID.conception.json"
FICHIER_PASSE_OUTRE="$STATE_DIR/$TASK_ID.conception-outre"
FICHIER_AGENT="$STATE_DIR/$TASK_ID.state"
FICHIER_DEMANDES="$STATE_DIR/$TASK_ID.demandes.json"
FICHIER_CONTROLES="$STATE_DIR/$TASK_ID.verdict.json"
FICHIER_RELECTURE="$STATE_DIR/$TASK_ID.revue.json"
FICHIER_DECISION="$STATE_DIR/$TASK_ID.decision.json"
FICHIER_TRANSITIONS="$ORCH_DIR/journal/transitions.jsonl"

valeur_de() {  # valeur_de <fichier cle=valeur> <cle> : la valeur, ou vide
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 || true
}

ETAT_TACHE="$(valeur_de "$FICHE" etat)"
BLOCAGE="$(valeur_de "$FICHE" blocage)"

# --- Suivi du passage en cours -------------------------------------------------------------
# FICHIER_PRECEDENT : fichier de la derniere etape faite dans ce passage (vide au depart).
# PASSAGE_ARRETE : 1 des qu'une etape n'est pas faite ; les suivantes sont alors « à venir ».
FICHIER_PRECEDENT=""
PASSAGE_ARRETE=0

ligne() {  # ligne <etape> <etat et detail>
  printf '%-12s %s\n' "$1" "$2"
}

fichier_du_passage_en_cours() {  # vrai si le fichier existe et n'est pas plus ancien que l'etape d'avant
  local fichier="$1"
  [[ -f "$fichier" ]] || return 1
  [[ -z "$FICHIER_PRECEDENT" ]] && return 0
  if [[ "$fichier" -ot "$FICHIER_PRECEDENT" ]]; then
    return 1
  fi
  return 0
}

etape_non_faite() {  # etape_non_faite <etape> : premiere etape absente du passage en cours
  if (( PASSAGE_ARRETE == 1 )); then
    ligne "$1" 'à venir'
    return
  fi
  if [[ "$ETAT_TACHE" == RUNNING ]]; then
    ligne "$1" 'en cours…'
  else
    ligne "$1" "à venir  (tâche $ETAT_TACHE)"
  fi
  PASSAGE_ARRETE=1
}

etape_faite() {  # etape_faite <etape> <fichier> <detail> : etape reussie de ce passage
  ligne "$1" "$3"
  FICHIER_PRECEDENT="$2"
}

etape_en_echec() {  # etape_en_echec <etape> <detail> : la suite du passage n'a pas eu lieu
  ligne "$1" "$2"
  PASSAGE_ARRETE=1
}

# --- Conception ----------------------------------------------------------------------------
afficher_conception() {
  local conception_activee=1
  # Un projet sans relecture de conception n'ecrit jamais conception.json : si l'agent a deja
  # un fichier, l'etape n'existe pas pour ce projet.
  if [[ ! -f "$FICHIER_CONCEPTION" && -f "$FICHIER_AGENT" ]]; then
    conception_activee=0
  fi
  if (( conception_activee == 0 )); then
    ligne conception 'non activée pour ce projet'
    return
  fi
  if ! fichier_du_passage_en_cours "$FICHIER_CONCEPTION"; then
    etape_non_faite conception
    return
  fi
  local verdict nombre_de_constats
  verdict="$(jq -r '.verdict // "illisible"' "$FICHIER_CONCEPTION" 2>/dev/null || echo illisible)"
  nombre_de_constats="$(jq -r '.constats | length' "$FICHIER_CONCEPTION" 2>/dev/null || echo 0)"
  local constats_en_clair="$nombre_de_constats constat"
  if (( nombre_de_constats > 1 )); then
    constats_en_clair="$nombre_de_constats constats"
  fi
  if [[ "$verdict" == conforme ]]; then
    etape_faite conception "$FICHIER_CONCEPTION" 'conforme ✔'
    return
  fi
  # Un doute que l'humain a passe outre (repondre.sh modifier) laisse partir l'agent.
  local passe_outre_apres_le_doute=0
  if [[ -f "$FICHIER_PASSE_OUTRE" && ! "$FICHIER_PASSE_OUTRE" -ot "$FICHIER_CONCEPTION" ]]; then
    passe_outre_apres_le_doute=1
  fi
  if (( passe_outre_apres_le_doute == 1 )); then
    etape_faite conception "$FICHIER_PASSE_OUTRE" "$verdict, passé outre par l'humain ✔  ($constats_en_clair)"
    return
  fi
  etape_en_echec conception "$verdict ✘  ($constats_en_clair)"
}

# --- Agent ---------------------------------------------------------------------------------
afficher_agent() {
  if (( PASSAGE_ARRETE == 1 )) || ! fichier_du_passage_en_cours "$FICHIER_AGENT"; then
    etape_non_faite agent
    return
  fi
  local code_retour tours cout demandes
  code_retour="$(valeur_de "$FICHIER_AGENT" claude_rc)"
  tours="$(valeur_de "$FICHIER_AGENT" tours)"
  cout="$(valeur_de "$FICHIER_AGENT" cout_usd)"
  # Le cout est journalise avec toutes ses decimales (11.641820600000003) : deux suffisent ici.
  if [[ "$cout" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    cout="$(printf '%.2f' "$cout")"
  fi
  demandes="$(jq -r 'length' "$FICHIER_DEMANDES" 2>/dev/null || echo 0)"
  if [[ "$code_retour" == 0 ]]; then
    etape_faite agent "$FICHIER_AGENT" "terminé ✔  ($tours tours, ${cout:-?} \$, $demandes demande(s) d'écriture)"
  else
    etape_en_echec agent "en échec ✘  (code ${code_retour:-inconnu}, $tours tours)"
  fi
}

# --- Controles (une ligne par controle) -----------------------------------------------------
noms_des_controles() {  # liste de la fiche (gates=a,b), sinon celle du verdict
  local liste
  liste="$(valeur_de "$FICHE" gates)"
  if [[ -n "$liste" ]]; then
    tr ',' '\n' <<<"$liste"
    return
  fi
  jq -r '.preuve.gates[]?.nom' "$FICHIER_CONTROLES" 2>/dev/null || true
}

afficher_controles() {
  local controles_du_passage=1
  if (( PASSAGE_ARRETE == 1 )) || ! fichier_du_passage_en_cours "$FICHIER_CONTROLES"; then
    controles_du_passage=0
  fi
  local un_controle_rouge=0 nom code_retour
  while IFS= read -r nom; do
    [[ -n "$nom" ]] || continue
    if (( controles_du_passage == 0 )); then
      etape_non_faite "$nom"
      continue
    fi
    code_retour="$(jq -r --arg n "$nom" '[.preuve.gates[]? | select(.nom == $n) | .rc][0] // "absent"' "$FICHIER_CONTROLES")"
    if [[ "$code_retour" == 0 ]]; then
      ligne "$nom" 'vert ✔'
    elif [[ "$code_retour" == absent ]]; then
      ligne "$nom" 'non joué ✘'
      un_controle_rouge=1
    else
      ligne "$nom" "rouge ✘  (code $code_retour)"
      un_controle_rouge=1
    fi
  done < <(noms_des_controles)
  if (( controles_du_passage == 1 )); then
    FICHIER_PRECEDENT="$FICHIER_CONTROLES"
    (( un_controle_rouge == 0 )) || PASSAGE_ARRETE=1
  fi
}

# --- Relecture -----------------------------------------------------------------------------
afficher_relecture() {
  if (( PASSAGE_ARRETE == 1 )) || ! fichier_du_passage_en_cours "$FICHIER_RELECTURE"; then
    etape_non_faite relecture
    return
  fi
  local verdict confiance rejets
  verdict="$(jq -r '.verdict // "illisible"' "$FICHIER_RELECTURE" 2>/dev/null || echo illisible)"
  confiance="$(jq -r '.confiance // "?"' "$FICHIER_RELECTURE" 2>/dev/null || echo '?')"
  rejets="$(jq -r '.rejets | length' "$FICHIER_RELECTURE" 2>/dev/null || echo 0)"
  if [[ "$verdict" == accord ]]; then
    etape_faite relecture "$FICHIER_RELECTURE" "accord ✔  (confiance $confiance)"
  else
    # Un desaccord n'arrete pas la chaine : la decision peut tout de meme publier (PR a relire).
    etape_faite relecture "$FICHIER_RELECTURE" "$verdict ✘  (confiance $confiance, $rejets rejet(s))"
  fi
}

# --- PR ------------------------------------------------------------------------------------
tache_publiee() {
  [[ -f "$FICHIER_TRANSITIONS" ]] || return 1
  jq -e --arg t "$TASK_ID" 'select(.tache == $t and .vers == "PUBLISHED")' "$FICHIER_TRANSITIONS" >/dev/null 2>&1
}

afficher_pr() {
  if (( PASSAGE_ARRETE == 1 )) || ! fichier_du_passage_en_cours "$FICHIER_DECISION"; then
    etape_non_faite PR
    return
  fi
  local verdict
  verdict="$(jq -r '.verdict // "illisible"' "$FICHIER_DECISION" 2>/dev/null || echo illisible)"
  if tache_publiee; then
    etape_faite PR "$FICHIER_DECISION" "publiée ✔  (décision $verdict)"
  else
    etape_en_echec PR "non publiée ✘  (décision $verdict)"
  fi
}

# --- Fin -----------------------------------------------------------------------------------
afficher_fin() {
  case "$ETAT_TACHE" in
    DONE)   ligne fin 'DONE ✔' ;;
    FAILED) ligne fin 'FAILED ✘' ;;
    *)      ligne fin "à venir  (tâche $ETAT_TACHE, blocage ${BLOCAGE:-none})" ;;
  esac
}

printf '%s — état %s\n' "$TASK_ID" "$ETAT_TACHE"
afficher_conception
afficher_agent
afficher_controles
afficher_relecture
afficher_pr
afficher_fin
