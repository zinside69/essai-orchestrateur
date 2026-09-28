#!/usr/bin/env bash
# conception.sh — relecture de CONCEPTION d'une tache, avant que l'agent code (ADR 0003, R1).
# Usage : conception.sh T-NNN
# Sortie : state/T-NNN.conception.json | code 0 = conforme (ou rien a relire), 20 = doute
#
# (2026-09-25, O39) Ticket 18 iziGSM : le ticket prescrivait « echec du mouvement
# => cle liberee », avec le test qui la validait ; le mouvement n'etant pas
# atomique, le stock aurait ete compte deux fois. Un agent fidele l'aurait code,
# gate.sh et la revue de diff l'auraient laisse passer : ils jugent le code
# contre le ticket, jamais le ticket. Ici un modele DISTINCT de l'agent (celui du
# relecteur de diff), en contexte neuf et en lecture seule, relit la declaration
# de la tache et le ticket qu'elle cite, sans aucun code a juger.
#
# Activee par le projet seulement : "conception": true dans orchestrator/gates.json
# (decision de l'operateur, comme test_rouge). Sans elle : rien, code 0.
# Un verdict « conforme », ou une decision humaine de passer outre
# (state/T-NNN.conception-outre, ecrit par « repondre.sh modifier »), ne vaut que
# pour l'empreinte de la declaration : la modifier fait relire. Un « doute » n'est
# jamais garde : « approuver » (ticket amende) fait relire. Sortie illisible =
# doute (jamais conforme). Tests CO1 a CO6.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: conception.sh T-NNN}"
G="$ROOT/orchestrator/gates.json"
SORTIE="$STATE_DIR/$TASK_ID.conception.json"
OUTRE="$STATE_DIR/$TASK_ID.conception-outre"
BRUT="$STATE_DIR/$TASK_ID.conception-brut.json"
mkdir -p "$STATE_DIR"

if [[ ! -f "$G" ]] || ! jq -e '.conception == true' "$G" >/dev/null 2>&1; then
  exit 0
fi
require claude jq sha256sum

EMPREINTE="$(empreinte_tache "$TASK_ID")"
if [[ "$(cat "$OUTRE" 2>/dev/null || true)" == "$EMPREINTE" ]]; then
  log "$TASK_ID : conception en doute, mais l'humain a passe outre (consigne transmise a l'agent)"
  exit 0
fi
if jq -e --arg e "$EMPREINTE" '.verdict == "conforme" and .empreinte == $e' "$SORTIE" >/dev/null 2>&1; then
  log "$TASK_ID : conception deja relue, conforme (meme declaration)"
  exit 0
fi

declare -A TACHE=()
while IFS='=' read -r k v; do [[ -n "$k" ]] && TACHE[$k]="$v"; done < <(parse_task "$TASK_ID")
MODELE="$(jq -r '.revue.modele_reviewer' "$ROOT/orchestrator/matrice.json")"

PROMPT="RELECTURE DE CONCEPTION — tâche $TASK_ID

Tu relis la CONCEPTION d'une tâche AVANT qu'un agent la code. Il n'y a aucun code à juger.
Tu n'écris rien, tu ne lances rien : tu lis.

Déclaration de la tâche :
- Périmètre : ${TACHE[perimetre]:-non spécifié}
- Critère de done : ${TACHE[critere]:-non spécifié}
- Contrôles : ${TACHE[gates]:-non spécifiés}

Si le critère cite un fichier de ticket, lis-le en entier (critères d'acceptation, tests prescrits,
amendements). Lis aussi le CLAUDE.md du projet : ses invariants sont opposables.

Cherche une PRESCRIPTION (critère, test prescrit, consigne) qui :
1. validerait un défaut de sûreté des données : opération non atomique, course, reprise après échec
   partiel, écrasement, double comptage ;
2. contredirait un invariant déclaré du projet ;
3. ferait prouver par un test ce que ce test ne peut pas voir : mock à la place de la base,
   unitaire à la place d'un geste d'écran.

Rends « doute » seulement pour un risque concret, en citant la prescription et le scénario qui casse.
Dans les textes, cite avec « », jamais avec des guillemets droits (ils cassent le JSON).
Réponds UNIQUEMENT par un objet JSON, sans texte autour :
{\"verdict\":\"conforme\"|\"doute\",\"constats\":[{\"prescription\":\"...\",\"risque\":\"...\",\"amendement\":\"...\"}]}"

set +e
( cd "$ROOT" && claude -p "$PROMPT" \
    --model "$MODELE" \
    --permission-mode plan \
    --max-turns 12 \
    --output-format json \
    --allowed-tools "Read,Grep,Glob" ) >"$BRUT" 2>"$BRUT.err"
RC=$?
set -e
journaliser_cout "$TASK_ID" conception "$BRUT"

# AVANT : if (( RC == 0 )) && jq -e '.result | fromjson | (.verdict == "conforme" or .verdict == "doute") and (.constats | type == "array")' \
# AVANT :      "$BRUT" >/dev/null 2>&1; then
# AVANT :   jq -c --arg e "$EMPREINTE" --arg t "$TASK_ID" '.result | fromjson | {tache:$t, verdict, constats, empreinte:$e}' "$BRUT" >"$SORTIE"
#   (2026-09-27, O43) Lecture par json_du_modele (lib.sh) : un JSON entre balises
#   Markdown ou entoure de texte se lit ; rien de lisible => fail-safe, comme
#   avant. Tests CO7, CO8 (CO5 : sans JSON, toujours doute).
JSON_CO="$(json_du_modele "$BRUT" || true)"
if (( RC == 0 )) && [[ -n "$JSON_CO" ]] \
   && jq -e '(.verdict == "conforme" or .verdict == "doute") and (.constats | type == "array")' <<<"$JSON_CO" >/dev/null 2>&1; then
  jq -c --arg e "$EMPREINTE" --arg t "$TASK_ID" '{tache:$t, verdict, constats, empreinte:$e}' <<<"$JSON_CO" >"$SORTIE"
else
  # Fail-safe : une relecture illisible ne laisse jamais partir la tache.
  # AVANT :   jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
  # AVANT :     --arg brut "$(jq -r '.result // empty' "$BRUT" 2>/dev/null | head -c 800 || true)" \
  #   (2026-09-27, O43) « head -c » coupait en OCTETS : l'alerte finissait au
  #   milieu d'un caractere accentue (« pi� »). Coupe en caracteres par jq. Test CO9.
  jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
    --arg brut "$(jq -r '(.result // "") | .[0:800]' "$BRUT" 2>/dev/null || true)" \
    '{tache:$t, verdict:"doute", empreinte:$e,
      constats:[{prescription:"(relecture illisible)", risque:("sortie du relecteur de conception non conforme : " + $brut), amendement:"relancer la relecture (approuver) ou trancher (modifier)"}]}' >"$SORTIE"
fi

if [[ "$(jq -r .verdict "$SORTIE")" == conforme ]]; then
  log "$TASK_ID : conception conforme"
  exit 0
fi
log "$TASK_ID : conception en DOUTE ($(jq '.constats | length' "$SORTIE") constat(s))"
exit 20
