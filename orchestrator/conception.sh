#!/usr/bin/env bash
# conception.sh — relecture de CONCEPTION d'une tache, avant que l'agent code (ADR 0003, R1).
# Usage : conception.sh T-NNN
# Sortie : state/T-NNN.conception.json | code 0 = conforme (ou rien a relire), 20 = doute
#          21 = relecteur en panne (2026-10-26, O87 : erreur de Claude Code, rien n'a ete relu)
#               ou claude introuvable dans le PATH (2026-11-10, O95, cause « dependance »)
#
# (2026-09-25, O39) Ticket 18 iziGSM : le ticket prescrivait « echec du mouvement
# => cle liberee », avec le test qui la validait ; le mouvement n'etant pas
# atomique, le stock aurait ete compte deux fois. Un agent fidele l'aurait code,
# gate.sh et la revue de diff l'auraient laisse passer : ils jugent le code
# contre le ticket, jamais le ticket. Ici un modele DISTINCT de l'agent (celui du
# relecteur de diff), en contexte neuf et en lecture seule, relit la declaration
# AVANT : # de la tache et le ticket qu'elle cite, sans aucun code a juger.   (2026-10-30, O90 : le code cite se lit)
# de la tache, le ticket qu'elle cite et le code existant que ce ticket cite.
#
# Activee par le projet seulement : "conception": true dans orchestrator/gates.json
# (decision de l'operateur, comme test_rouge). Sans elle : rien, code 0.
# Un verdict « conforme », ou une decision humaine de passer outre
# (state/T-NNN.conception-outre, ecrit par « repondre.sh modifier »), ne vaut que
# pour l'empreinte de la declaration : la modifier fait relire. Un « doute » n'est
# jamais garde : « approuver » (ticket amende) fait relire. Sortie illisible =
# doute (jamais conforme). Tests CO1 a CO6.
# (2026-10-26, O87) Deux exceptions : une erreur de Claude Code (is_error, ou code non nul
# sans sortie lisible) est une PANNE, code 21, jamais un doute ; un relecteur coupe par son
# plafond de tours est relance une fois avec trois fois plus de tours. Tests CO11 a CO16.
# (2026-10-30, O91) Le verdict est demande en sortie structuree (schema) ; s'il reste illisible,
# le texte entier est garde et l'alerte donne son chemin. Tests CO26, CO27.
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
# AVANT : require claude jq sha256sum
#   (2026-11-10, O95) claude se verifie plus bas, apres le passe-outre et le conforme garde :
#   sur T-016 (08/11), un shell sans claude sortait ici en erreur, lue en doute (P15), alors
#   que l'humain avait deja passe outre. Tests CO29, CO30.
require jq sha256sum

EMPREINTE="$(empreinte_tache "$TASK_ID")"
if [[ "$(cat "$OUTRE" 2>/dev/null || true)" == "$EMPREINTE" ]]; then
  log "$TASK_ID : conception en doute, mais l'humain a passe outre (consigne transmise a l'agent)"
  exit 0
fi
# --- Un « conforme » doit reposer sur du code lu (2026-10-30, O90) --------------
# Pourquoi : un « conforme » laisse partir l'agent et reste garde pour la meme declaration. Rendu
# sur le seul texte du ticket, il ne vaut pas relecture. On le change donc en doute, que l'humain
# tranche : « approuver » relance la relecture, « modifier » passe outre.
# Ce qui compte pour du code : tout fichier declare qui n'est pas un .md (le ticket et le CLAUDE.md
# sont des .md). Un ticket sans aucun code a lire finit donc en doute, a passer par « modifier ».
# Limite : la declaration n'est pas prouvee, la sortie json de Claude Code ne liste pas ses outils.
# La prescription commence par « (relecture » : ce constat est ecrit par le socle, le bloc O88 ne le
# transmet donc pas au relecteur suivant. Tests CO20 a CO25.
fichiers_de_code_lus() {  # fichiers_de_code_lus <fichier verdict> : un chemin par ligne, sans les .md
  # Seule une vraie liste compte, et seules ses chaines. « .md » est cherche suivi de n'importe quoi
  # sauf une lettre ou un chiffre : le relecteur annote parfois ses chemins (« t.md (ticket) »,
  # « t.md:1-40 »), et « .mdx » reste du code. Dans le doute, le chemin ne compte pas : le conforme
  # est refuse, jamais accepte a tort. Tests CO20, CO22.
  jq -r '.fichiers_lus
         | if type == "array" then .[] else empty end
         | strings
         | select(test("\\.md([^a-z0-9]|$)"; "i") | not)' "$1"
}
conforme_sans_code_lu() {  # conforme_sans_code_lu <fichier verdict> : vrai si « conforme » et aucun code declare
  local fichier_verdict="$1"
  [[ "$(jq -r .verdict "$fichier_verdict")" == conforme ]] || return 1
  [[ -z "$(fichiers_de_code_lus "$fichier_verdict")" ]]
}
changer_en_doute_sans_code_lu() {  # changer_en_doute_sans_code_lu <fichier verdict> : reecrit le verdict en doute
  local fichier_verdict="$1"
  # Les constats du relecteur restent, a la suite de celui du socle. Test CO25.
  jq -c '.verdict = "doute"
         | .constats = [{prescription:"(relecture sans code lu)",
                         risque:"le relecteur a rendu conforme sans déclarer aucun fichier de code ouvert : son avis ne porte que sur le texte du ticket",
                         amendement:"approuver relance la relecture, ou modifier pour passer outre"}] + .constats' \
    "$fichier_verdict" >"$fichier_verdict.n" || die "conception : impossible de reecrire $fichier_verdict en doute"
  mv "$fichier_verdict.n" "$fichier_verdict"
}

# AVANT : if jq -e --arg e "$EMPREINTE" '.verdict == "conforme" and .empreinte == $e' "$SORTIE" >/dev/null 2>&1; then
#   (2026-10-30, O90, revue) Un conforme ecrit avant la garde, sans code declare, n'est plus honore :
#   l'agent serait parti sans controle. Test CO23.
if jq -e --arg e "$EMPREINTE" '.verdict == "conforme" and .empreinte == $e' "$SORTIE" >/dev/null 2>&1 \
   && ! conforme_sans_code_lu "$SORTIE"; then
  log "$TASK_ID : conception deja relue, conforme (meme declaration)"
  exit 0
fi
# --- claude introuvable : une panne, jamais un doute (2026-11-10, O95) ----------
# Pourquoi : sans claude, rien n'est relu et le ticket n'est pas en cause. Meme code que les
# autres pannes (21) ; la cause « dependance » donne a pipeline.sh le geste a dire. Test CO29.
if ! command -v claude >/dev/null 2>&1; then
  jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
    '{tache:$t, verdict:"panne", empreinte:$e, cause:"dependance", message:"dependance manquante : claude"}' >"$SORTIE"
  log "$TASK_ID : relecteur de conception non lance — dependance manquante : claude"
  exit 21
fi

declare -A TACHE=()
while IFS='=' read -r k v; do [[ -n "$k" ]] && TACHE[$k]="$v"; done < <(parse_task "$TASK_ID")
MODELE="$(jq -r '.revue.modele_reviewer' "$ROOT/orchestrator/matrice.json")"

# (2026-10-13, O71) La consigne demande tous les constats en une fois : sur le ticket 05,
# ils étaient venus par lots (3, 3, 1, puis conforme), soit 4 relectures payées. Test CO10.
# AVANT : Tu relis la CONCEPTION d'une tâche AVANT qu'un agent la code. Il n'y a aucun code à juger.
#   (2026-10-30, O90, revue) Cette phrase contredisait « ouvre le code » plus bas. Test CO19.
PROMPT="RELECTURE DE CONCEPTION — tâche $TASK_ID

Tu relis la CONCEPTION d'une tâche AVANT qu'un agent la code. Le code de cette tâche n'existe pas encore : appuie-toi sur le code existant que le ticket cite.
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
Relis tout le ticket avant de répondre, puis rends TOUS tes constats en une fois : un constat
gardé pour une relecture suivante coûte une relecture et un amendement du ticket de plus.
Dans les textes, cite avec « », jamais avec des guillemets droits (ils cassent le JSON).
Réponds UNIQUEMENT par un objet JSON, sans texte autour :
{\"verdict\":\"conforme\"|\"doute\",\"constats\":[{\"prescription\":\"...\",\"risque\":\"...\",\"amendement\":\"...\"}]}"

# (2026-10-30, O90) Sur T-010, trois relectures sur cinq ont rendu « conforme » en 2 ou 3 tours,
# sans trace d'une lecture du code cite. La consigne demande d'ouvrir ce code et de declarer les
# fichiers ouverts ; le controle de cette declaration est plus bas (conforme_sans_code_lu).
# Tests CO19 a CO21.
PROMPT="$PROMPT

Avant de répondre, ouvre le code que le ticket cite ou modifie : un avis sur le seul texte du ticket ne vaut pas relecture.
Ajoute à l'objet JSON le champ \"fichiers_lus\" : la liste des chemins que tu as ouverts, ticket compris."

# (2026-10-29, O88) Chaque relecture repartait de zero : sur T-010 (23/10), le second passage a
# tire deux constats nouveaux sur des lignes inchangees ; la mesure du 29/10 sur le meme texte a
# donne 2 doutes et 3 conformes. Le second passage recoit ses constats precedents, pour verifier
# qu'ils sont leves au lieu de tout rouvrir. Seul un doute rendu par le relecteur compte : un
# constat ecrit par le socle (relecture illisible ou inachevee) n'en est pas un. Tests CO17, CO18.
constats_de_la_relecture_precedente() {  # <verdict precedent> : une ligne par constat du relecteur, rien sinon
  jq -r 'select(.verdict == "doute") | .constats[]
         | select((.prescription // "") | startswith("(relecture") | not)
         | "- " + (.prescription // "?") + " — amendement demandé : " + (.amendement // "aucun")' "$1" 2>/dev/null || true
}
CONSTATS_PRECEDENTS="$(constats_de_la_relecture_precedente "$SORTIE")"
if [[ -n "$CONSTATS_PRECEDENTS" ]]; then
  PROMPT="$PROMPT

RELECTURE PRÉCÉDENTE de cette tâche — tes constats, avant que le ticket soit amendé :
$CONSTATS_PRECEDENTS
Pour chacun, vérifie dans le ticket actuel qu'il est levé ; un constat non levé reste un constat.
N'en ajoute un nouveau que pour un risque concret des catégories 1 à 3 ci-dessus.
Réponds toujours UNIQUEMENT par l'objet JSON décrit plus haut."
fi

# AVANT : set +e
# AVANT : ( cd "$ROOT" && claude -p "$PROMPT" \
# AVANT :     --model "$MODELE" \
# AVANT :     --permission-mode plan \
# AVANT :     --max-turns 12 \
# AVANT :     --output-format json \
# AVANT :     --allowed-tools "Read,Grep,Glob" ) >"$BRUT" 2>"$BRUT.err"
# AVANT : RC=$?
# AVANT : set -e
# AVANT : journaliser_cout "$TASK_ID" conception "$BRUT"
#   (2026-10-26, O87, decision de l'operateur) Un relecteur coupe par son plafond de tours
#   n'a pas fini de lire : ce n'est ni une panne ni un avis. Il est relance une fois, tout
#   de suite, avec trois fois plus de tours, « quitte a ce que ca consomme ». La relance
#   part MEME si le plafond de depense du jour est atteint entre-temps : le plafond n'est
#   controle qu'avant la premiere relecture (pipeline.sh), et l'operateur a choisi de ne pas
#   le recontroler ici (26/10). Encore coupe : doute qui le dit. Tests CO13, CO15.
TOURS_DE_LA_RELECTURE=12
TOURS_DE_LA_RELANCE=$(( TOURS_DE_LA_RELECTURE * 3 ))

# (2026-10-30, O91) Le 30/10, 2 relectures sur 8 ont rendu un JSON casse (guillemets droits, accolade
# en trop) : la relecture etait payee et ses constats perdus pour l'humain. Le schema impose le format
# a Claude Code, qui rend alors la reponse dans « structured_output ». On ne relance pas sur un JSON
# casse : le verdict varie d'un tirage a l'autre, une relance pourrait effacer un risque bien vu.
# « fichiers_lus » est obligatoire ici, la garde d'O90 reste le controle de son contenu. Test CO26.
SCHEMA_DU_VERDICT='{
  "type": "object",
  "required": ["verdict", "constats", "fichiers_lus"],
  "additionalProperties": false,
  "properties": {
    "verdict": {"enum": ["conforme", "doute"]},
    "constats": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["prescription", "risque", "amendement"],
        "additionalProperties": false,
        "properties": {
          "prescription": {"type": "string"},
          "risque": {"type": "string"},
          "amendement": {"type": "string"}
        }
      }
    },
    "fichiers_lus": {"type": "array", "items": {"type": "string"}}
  }
}'

lancer_le_relecteur() {  # lancer_le_relecteur <plafond de tours> : ecrit $BRUT et $BRUT.err, rend le code de claude
  local plafond_de_tours="$1" code_de_claude
  set +e
  ( cd "$ROOT" && claude -p "$PROMPT" \
      --model "$MODELE" \
      --permission-mode plan \
      --max-turns "$plafond_de_tours" \
      --output-format json \
      --json-schema "$SCHEMA_DU_VERDICT" \
      --allowed-tools "Read,Grep,Glob" ) >"$BRUT" 2>"$BRUT.err"
  code_de_claude=$?
  set -e
  journaliser_cout "$TASK_ID" conception "$BRUT"
  return "$code_de_claude"
}

relecteur_coupe_par_ses_tours() {  # relecteur_coupe_par_ses_tours <sortie brute>
  jq -e '.subtype == "error_max_turns"' "$1" >/dev/null 2>&1
}

RC=0
lancer_le_relecteur "$TOURS_DE_LA_RELECTURE" || RC=$?
if relecteur_coupe_par_ses_tours "$BRUT"; then
  log "$TASK_ID : relecteur de conception coupe a $TOURS_DE_LA_RELECTURE tours, relance a $TOURS_DE_LA_RELANCE tours"
  RC=0
  lancer_le_relecteur "$TOURS_DE_LA_RELANCE" || RC=$?
fi
if relecteur_coupe_par_ses_tours "$BRUT"; then
  jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" --arg n "$TOURS_DE_LA_RELANCE" \
    '{tache:$t, verdict:"doute", empreinte:$e,
      constats:[{prescription:"(relecture inachevee)", risque:("relecteur coupe a " + $n + " tours avant la fin de sa relecture : rien ne dit encore que le ticket est sur"), amendement:"approuver relance la relecture, ou modifier pour passer outre"}]}' >"$SORTIE"
  log "$TASK_ID : relecteur de conception encore coupe a $TOURS_DE_LA_RELANCE tours — relecture inachevee"
  exit 20
fi

# (2026-10-26, O87) Claude Code rend une ERREUR, pas un avis : « is_error » vrai dans sa
# sortie (panne d'authentification du 23/10 sur T-010 : « Failed to authenticate: OAuth
# session expired », 0 token, 0 $). Le relecteur n'a rien relu, le ticket n'est pas en
# cause. Avant, cette sortie tombait dans le fail-safe ci-dessous : « relecture illisible »,
# escalade P15, et l'humain cherchait un defaut dans son ticket. Code 21, que pipeline.sh
# escalade en panne (P10) avec le geste. Test CO11.
relecteur_en_panne() {  # relecteur_en_panne <sortie brute> : vrai si Claude Code a rendu une erreur
  # Un plafond atteint (error_max_turns, error_max_budget_usd) porte aussi « is_error » :
  # ce n'est pas une panne du service (revue du 26/10). Test CO13.
  jq -e '.is_error == true and ((.subtype // "") | startswith("error_max") | not)' "$1" >/dev/null 2>&1
}
# Une panne s'ecrit en un seul endroit : message de Claude Code lu sur l'entree standard
# (jamais en argument : c'est un texte que le socle ne maitrise pas), coupe en caracteres,
# et sa cause, qui choisit le geste dit a l'humain (pipeline.sh) : se reconnecter seulement
# si Claude Code parle d'authentification. Tests CO11, CO12, CO14.
ecrire_la_panne() {  # ecrire_la_panne < message de Claude Code : ecrit $SORTIE (verdict panne, cause)
  jq -Rsc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
    '.[0:400] as $message
     | {tache:$t, verdict:"panne", empreinte:$e, message:$message,
        cause:(if ($message | test("authenticat|/login|OAuth"; "i")) then "authentification" else "autre" end)}' >"$SORTIE"
}
panne_avec_message() {  # panne_avec_message <sortie brute> : vrai si la sortie porte un message (.result non vide)
  jq -e '(.result // "") | tostring | length > 0' "$1" >/dev/null 2>&1
}
if relecteur_en_panne "$BRUT"; then
  if panne_avec_message "$BRUT"; then
    jq -j '(.result // "") | tostring' "$BRUT" | ecrire_la_panne
  else
    # Panne sans .result (ex. error_during_execution) : le message est sur stderr. Test CO16.
    ecrire_la_panne <"$BRUT.err"
  fi
  log "$TASK_ID : relecteur de conception en PANNE (cause : $(jq -r .cause "$SORTIE"))"
  exit 21
fi
# (2026-10-26, O87, revue) Panne sans JSON du tout : claude sort en erreur (code non nul)
# sans rien de lisible sur sa sortie standard, le message est sur stderr. Meme panne, meme
# code 21 ; le message est lu dans stderr, coupe en caracteres (lecon d'O43). Test CO14.
sortie_json_lisible() {  # sortie_json_lisible <sortie brute> : vrai si c'est un objet JSON
  jq -e 'type == "object"' "$1" >/dev/null 2>&1
}
relecteur_sans_reponse() {  # relecteur_sans_reponse <code de claude> <sortie brute>
  local code_de_claude="$1" sortie_brute="$2"
  (( code_de_claude != 0 )) && ! sortie_json_lisible "$sortie_brute"
}
if relecteur_sans_reponse "$RC" "$BRUT"; then
  ecrire_la_panne <"$BRUT.err"
  log "$TASK_ID : relecteur de conception en PANNE, sans reponse lisible (code $RC, cause : $(jq -r .cause "$SORTIE"))"
  exit 21
fi

# AVANT : if (( RC == 0 )) && jq -e '.result | fromjson | (.verdict == "conforme" or .verdict == "doute") and (.constats | type == "array")' \
# AVANT :      "$BRUT" >/dev/null 2>&1; then
# AVANT :   jq -c --arg e "$EMPREINTE" --arg t "$TASK_ID" '.result | fromjson | {tache:$t, verdict, constats, empreinte:$e}' "$BRUT" >"$SORTIE"
#   (2026-09-27, O43) Lecture par json_du_modele (lib.sh) : un JSON entre balises
#   Markdown ou entoure de texte se lit ; rien de lisible => fail-safe, comme
#   avant. Tests CO7, CO8 (CO5 : sans JSON, toujours doute).
# AVANT : JSON_CO="$(json_du_modele "$BRUT" || true)"
#   (2026-10-30, O91) La reponse structuree passe d'abord ; le texte de « result » reste lu en
#   second si elle manque. Une version de Claude Code sans --json-schema n'arrive pas jusqu'ici :
#   elle sort en erreur, c'est une panne P10 avec son message (version requise : spec § 3.1). Test CO26.
reponse_structuree_presente() {  # reponse_structuree_presente <sortie brute>
  jq -e '.structured_output | type == "object"' "$1" >/dev/null 2>&1
}
verdict_du_relecteur() {  # verdict_du_relecteur <sortie brute> : l'objet JSON du verdict, code non nul si illisible
  local sortie_brute="$1"
  if reponse_structuree_presente "$sortie_brute"; then
    jq -c '.structured_output' "$sortie_brute"
  else
    json_du_modele "$sortie_brute"
  fi
}
# Une sortie sans texte existe : quand Claude Code renonce au format, ses erreurs sont dans d'autres
# champs. La sortie brute est alors gardee entiere : jamais un fichier vide. Tests CO27, CO28.
garder_le_texte_illisible() {  # garder_le_texte_illisible <sortie brute> <fichier a ecrire>
  local sortie_brute="$1" fichier_a_ecrire="$2" texte_du_relecteur
  texte_du_relecteur="$(jq -r '.result // ""' "$sortie_brute" 2>/dev/null || true)"
  if [[ -n "$texte_du_relecteur" ]]; then
    printf '%s\n' "$texte_du_relecteur" >"$fichier_a_ecrire"
  else
    cp "$sortie_brute" "$fichier_a_ecrire"
  fi
}
JSON_CO="$(verdict_du_relecteur "$BRUT" || true)"
if (( RC == 0 )) && [[ -n "$JSON_CO" ]] \
   && jq -e '(.verdict == "conforme" or .verdict == "doute") and (.constats | type == "array")' <<<"$JSON_CO" >/dev/null 2>&1; then
  # AVANT :   jq -c --arg e "$EMPREINTE" --arg t "$TASK_ID" '{tache:$t, verdict, constats, empreinte:$e}' <<<"$JSON_CO" >"$SORTIE"
  #   (2026-10-30, O90) Le verdict garde les fichiers declares lus (liste vide s'il n'y en a pas). Test CO21.
  #   Il passe par un fichier provisoire : script tue ou reecriture en echec avant la garde, $SORTIE ne
  #   contient jamais un conforme sans code lu, que « approuver » laisserait partir. Test CO24.
  VERDICT_PROVISOIRE="$SORTIE.provisoire"
  jq -c --arg e "$EMPREINTE" --arg t "$TASK_ID" '{tache:$t, verdict, constats, fichiers_lus:(.fichiers_lus // []), empreinte:$e}' <<<"$JSON_CO" >"$VERDICT_PROVISOIRE"
  if conforme_sans_code_lu "$VERDICT_PROVISOIRE"; then
    log "$TASK_ID : conforme sans fichier de code lu, change en doute"
    changer_en_doute_sans_code_lu "$VERDICT_PROVISOIRE"
  fi
  mv "$VERDICT_PROVISOIRE" "$SORTIE"
else
  # Fail-safe : une relecture illisible ne laisse jamais partir la tache.
  # AVANT :   jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
  # AVANT :     --arg brut "$(jq -r '.result // empty' "$BRUT" 2>/dev/null | head -c 800 || true)" \
  #   (2026-09-27, O43) « head -c » coupait en OCTETS : l'alerte finissait au
  #   milieu d'un caractere accentue (« pi� »). Coupe en caracteres par jq. Test CO9.
  # AVANT :       constats:[{prescription:"(relecture illisible)", risque:("sortie du relecteur de conception non conforme : " + $brut), amendement:"relancer la relecture (approuver) ou trancher (modifier)"}]}' >"$SORTIE"
  #   (2026-10-30, O91) L'extrait de 800 caracteres ne suffit pas (800 sur 9 934 le 30/10) : le texte
  #   entier est garde a part, car $BRUT est ecrase par la relecture suivante, et l'alerte donne son
  #   chemin. L'humain tranche sur ce qui a ete relu, sans relancer a l'aveugle. Test CO27.
  FICHIER_TEXTE_ILLISIBLE="$STATE_DIR/$TASK_ID.conception-illisible.txt"
  garder_le_texte_illisible "$BRUT" "$FICHIER_TEXTE_ILLISIBLE"
  jq -nc --arg e "$EMPREINTE" --arg t "$TASK_ID" \
    --arg chemin_texte_entier "$FICHIER_TEXTE_ILLISIBLE" \
    --arg brut "$(jq -r '(.result // "") | .[0:800]' "$BRUT" 2>/dev/null || true)" \
    '{tache:$t, verdict:"doute", empreinte:$e,
      constats:[{prescription:"(relecture illisible)", risque:("sortie du relecteur de conception non conforme (texte entier : " + $chemin_texte_entier + ") : " + $brut), amendement:"relancer la relecture (approuver) ou trancher (modifier)"}]}' >"$SORTIE"
fi

if [[ "$(jq -r .verdict "$SORTIE")" == conforme ]]; then
  log "$TASK_ID : conception conforme"
  exit 0
fi
log "$TASK_ID : conception en DOUTE ($(jq '.constats | length' "$SORTIE") constat(s))"
exit 20
