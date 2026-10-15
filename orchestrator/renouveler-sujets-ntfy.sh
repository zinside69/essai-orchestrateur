#!/usr/bin/env bash
# renouveler-sujets-ntfy.sh — tire deux noms neufs et imprevisibles pour les sujets ntfy.
# Usage : orchestrator/renouveler-sujets-ntfy.sh [--appliquer]
#         orchestrator/renouveler-sujets-ntfy.sh --help
#
# (2026-10-13, O17) Sur ntfy.sh, un sujet est public pour qui connait son nom : il
# lit les alertes, jetons des boutons compris, et peut repondre avant l'humain. Le
# jeton (128 bits, usage unique) empeche de deviner ou de rejouer une reponse, pas de
# lire puis d'utiliser une notification pas encore traitee. Sans sujet reserve
# (payant), la seule barriere est le secret du nom : ce script en tire deux de
# 128 bits (32 caracteres hexadecimaux, /dev/urandom) et les ecrit dans le fichier de
# reglages, a renouveler des qu'un nom a pu etre vu ailleurs.
#
# Sans --appliquer : apercu, rien n'est ecrit et aucun nom n'est affiche.
# Avec : le fichier est sauvegarde (<fichier>.AAAAMMJJ-HHMMSS, droits 600), les lignes
# NTFY_TOPIC et NTFY_TOPIC_REPONSE sont remplacees (ajoutees si absentes), toute autre
# ligne reste identique, puis le seul nom du sujet d'ALERTE est affiche : c'est celui
# qu'on tape dans l'application ntfy (celui des reponses voyage dans les boutons).
# A lancer par l'humain dans son propre terminal : les noms ne doivent apparaitre
# dans aucun journal ni aucune conversation.
# Fichier : ORCHESTRATEUR_ENV, sinon ~/.orchestrateur.env. Codes : 0 = fait ; 1 = erreur.
# Tests RN1 a RN4.
set -Eeuo pipefail

die() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

APPLIQUER=0
for arg in "$@"; do
  case "$arg" in
    --appliquer) APPLIQUER=1 ;;
    --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "argument inconnu : $arg (voir --help)" ;;
  esac
done

FICHIER_REGLAGES="${ORCHESTRATEUR_ENV:-$HOME/.orchestrateur.env}"
[[ -f "$FICHIER_REGLAGES" ]] || die "fichier de reglages absent : $FICHIER_REGLAGES (rien n'est cree)"

# nom_de_sujet_neuf — 32 caracteres hexadecimaux, soit 128 bits tires au hasard.
nom_de_sujet_neuf() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

# remplacer_ou_ajouter <fichier> <NOM> <valeur> : remplace la premiere ligne
# « NOM=… » (avec ou sans export), ou l'ajoute a la fin si elle manque. Une seule
# definition est gardee, comme lire_reglage_orchestrateur (lib.sh) n'en lit qu'une.
remplacer_ou_ajouter() {
  local fichier="$1" nom="$2" valeur="$3" copie
  copie="$(mktemp "$fichier.XXXXXX")"
  awk -v nom="$nom" -v valeur="$valeur" '
    BEGIN { motif = "^[[:space:]]*(export[[:space:]]+)?" nom "[[:space:]]*=" ; deja_ecrite = 0 }
    $0 ~ motif && deja_ecrite == 0 { print nom "=" valeur ; deja_ecrite = 1 ; next }
    { print }
    END { if (deja_ecrite == 0) print nom "=" valeur }
  ' "$fichier" >"$copie"
  chmod 600 "$copie"
  mv "$copie" "$fichier"
}

printf 'Fichier de reglages : %s\n' "$FICHIER_REGLAGES"
printf 'Variables renouvelees : NTFY_TOPIC (alertes), NTFY_TOPIC_REPONSE (boutons)\n'
printf 'Attention : les boutons des notifications deja recues ne marcheront plus ;\n'
printf 'repondre a une escalade encore ouverte au PC (orchestrator/repondre.sh).\n'

if (( APPLIQUER == 0 )); then
  printf '\nApercu seulement : rien n est ecrit. Relancer avec --appliquer, dans ton propre terminal.\n'
  exit 0
fi

SAUVEGARDE="$FICHIER_REGLAGES.$(date +%Y%m%d-%H%M%S)"
[[ ! -e "$SAUVEGARDE" ]] || die "sauvegarde deja presente : $SAUVEGARDE (relancer dans une seconde)"
cp -p "$FICHIER_REGLAGES" "$SAUVEGARDE"
chmod 600 "$SAUVEGARDE"

SUJET_ALERTE="$(nom_de_sujet_neuf)"
SUJET_REPONSE="$(nom_de_sujet_neuf)"
while [[ "$SUJET_REPONSE" == "$SUJET_ALERTE" ]]; do
  SUJET_REPONSE="$(nom_de_sujet_neuf)"
done

remplacer_ou_ajouter "$FICHIER_REGLAGES" NTFY_TOPIC "$SUJET_ALERTE"
remplacer_ou_ajouter "$FICHIER_REGLAGES" NTFY_TOPIC_REPONSE "$SUJET_REPONSE"

printf '\nSauvegarde : %s\n' "$SAUVEGARDE"
printf 'Nouveau sujet d alerte (a taper dans l application ntfy) : %s\n' "$SUJET_ALERTE"
printf '\nA faire maintenant :\n'
printf '  1. dans l application ntfy, s abonner au nouveau sujet ci-dessus ;\n'
printf '  2. se desabonner de l ancien sujet ;\n'
printf '  3. systemctl --user restart orchestrateur-ecouteur\n'
printf 'Une variable NTFY_TOPIC posee dans l environnement d un processus l emporte sur ce fichier.\n'
