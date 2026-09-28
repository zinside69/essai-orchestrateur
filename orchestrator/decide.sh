#!/usr/bin/env bash
# decide.sh — applique la matrice de décision Phase 2.
# Sortie : state/T-NNN.decision.json | code 0 = décision prise
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: decide.sh T-NNN}"
VERDICT_GATE="${2:?chemin vers state/T-NNN.verdict.json}"
REVUE="${3:?chemin vers state/T-NNN.revue.json}"
WT="${4:-$ROOT}"
BASE="${5:-$INTEGRATION_BRANCH}"

M="$ROOT/orchestrator/matrice.json"
require git jq sha256sum

# --- Lecture des seuils : source de vérité unique -------------------------
V_AUTO_F=$(jq -r '.volumes.auto_merge_max_fichiers'    "$M")
V_AUTO_L=$(jq -r '.volumes.auto_merge_max_lignes'      "$M")
V_DRFT_F=$(jq -r '.volumes.draft_max_fichiers'         "$M")
V_DRFT_L=$(jq -r '.volumes.draft_max_lignes'           "$M")
V_PLAF_F=$(jq -r '.volumes.plafond_fichiers'            "$M")
V_PLAF_L=$(jq -r '.volumes.plafond_lignes'              "$M")
C_MIN=$(jq -r    '.seuils_revue.confiance_min_accord'   "$M")

GATES="$(jq -r '.verdict' "$VERDICT_GATE")"      # green | red | escalate
RISQUE="$(jq -r '.risque' "$VERDICT_GATE")"      # low | high
FILES="$(jq -r  '.fichiers' "$VERDICT_GATE")"
LINES="$(jq -r  '.lignes' "$VERDICT_GATE")"

REV_VERDICT="$(jq -r '.verdict'   "$REVUE")"     # accord | reserve | desaccord
REV_CONF="$(jq -r    '.confiance' "$REVUE")"
REV_NATURE="$(jq -r  '.nature'    "$REVUE")"     # additive | mutative

RAISONS=()
VERDICT=""

# --- P0 — preuve d'exécution des gates (Phase 5 / P1-b) --------------------
# Un verdict sans preuve vérifiable (hash SHA-256 des sorties + fraîcheur
# anti-réutilisation) est rejeté avant toute règle de la matrice.
verify_preuve_gates() {
  jq -e '.preuve' "$VERDICT_GATE" >/dev/null 2>&1 || { printf 'P7:preuve-absente'; return 1; }
  local debut g nom sha logf mt
  debut="$(jq -r '.preuve.debut_ts // empty' "$VERDICT_GATE")"
  [[ -n "$debut" ]] || { printf 'P7:preuve-absente'; return 1; }
  while read -r g; do
    [[ -z "$g" ]] && continue
    nom="$(jq -r '.nom' <<<"$g")"
    sha="$(jq -r '.sha256' <<<"$g")"
    logf="$ORCH_DIR/logs/gate-$TASK_ID-$nom.log"
    [[ -f "$logf" ]] || { printf 'P7:preuve-gates-invalide(%s)' "$nom"; return 1; }
    [[ "$(sha256sum "$logf" | awk '{print $1}')" == "$sha" ]] || { printf 'P7:preuve-gates-invalide(%s)' "$nom"; return 1; }
    mt="$(stat -c %Y "$logf")"
    (( mt >= debut - 2 )) || { printf 'P7:preuve-gates-perimee(%s)' "$nom"; return 1; }
  done < <(jq -c '.preuve.gates[]?' "$VERDICT_GATE")
  return 0
}

PREUVE_RC=0
if ! P7_RAISON="$(verify_preuve_gates)"; then
  VERDICT="PARK"
  RAISONS+=("$P7_RAISON")
  PREUVE_RC=20
fi

# --- Motifs de correspondance de chemins ---------------------------------
match_glob() {
  local path="$1" pattern="$2"
  # shellcheck disable=SC2053
  [[ "$path" == $pattern ]]
}

touche_motif() {
  local motif_set="$1" f
  while read -r f; do
    [[ -z "$f" ]] && continue
    while read -r pat; do
      match_glob "$f" "$pat" && { printf '%s\n' "$f"; return 0; }
    done < <(jq -r --arg k "$motif_set" '.[$k][]' "$M")
  done < <(git -C "$WT" diff --name-only "$BASE"...HEAD)
  return 1
}

# --- Règles d'arrêt : évaluées en premier --------------------------------
# P1 — plafond de volume
VERDICT_AVANT_P1="$VERDICT"
if (( FILES > V_PLAF_F || LINES > V_PLAF_L )); then
  VERDICT="PARK"; RAISONS+=("P1:plafond-depasse(${FILES}f/${LINES}l)")
fi
# (2026-09-25, O38) Quota accepte par un humain aux controles (O29, ecrit par
# « repondre.sh approuver », honore par gate.sh) : le plafond P1 porte sur le
# meme depassement — ne pas le faire accepter une seconde fois. Seule
# l'acceptation « quota » leve P1 (« risque » non). La suite de la matrice
# s'applique : au-dela du volume de brouillon, jamais de fusion automatique.
# Tests DQ1 a DQ3.
if [[ "$VERDICT" == "PARK" && -f "$STATE_DIR/$TASK_ID.depassements-acceptes" ]] \
   && grep -qx quota "$STATE_DIR/$TASK_ID.depassements-acceptes" \
   && (( FILES > V_PLAF_F || LINES > V_PLAF_L )); then
  RAISONS_SANS_P1=()
  for r in "${RAISONS[@]}"; do [[ "$r" == P1:plafond-depasse* ]] || RAISONS_SANS_P1+=("$r"); done
  RAISONS=("${RAISONS_SANS_P1[@]+"${RAISONS_SANS_P1[@]}"}" "P1:plafond-accepte-humain(${FILES}f/${LINES}l)")
  VERDICT="$VERDICT_AVANT_P1"
  log "Plafond depasse (${FILES}f/${LINES}l) accepte par un humain pour ce travail"
fi

# P2 — chemin absolu (garde-fous)
if [[ -z "$VERDICT" ]] && HIT="$(touche_motif chemins_absolus)"; then
  VERDICT="PARK"; RAISONS+=("P2:chemin-absolu:$HIT")
fi

# P3 — motif de secret dans le contenu du diff
if [[ -z "$VERDICT" ]]; then
  while read -r re; do
    [[ -z "$re" ]] && continue
    if git -C "$WT" diff "$BASE"...HEAD -U0 | grep -E "^\+" | grep -Eq -- "$re"; then
      VERDICT="PARK"; RAISONS+=("P3:motif-secret")
      break
    fi
  done < <(jq -r '.motifs_secret[]' "$M")
fi

# P4 — sortie reviewer non conforme (déjà normalisée en desaccord/0.0 par review.sh)
if [[ -z "$VERDICT" ]] && [[ "$REV_CONF" == "0" && "$REV_VERDICT" == "desaccord" ]]; then
  VERDICT="PARK"; RAISONS+=("P4:revue-non-conforme")
fi

# P5 — invariant de contexte neuf violé (remonté par review.sh en sortie V)
if [[ -z "$VERDICT" ]] && jq -e '.rejets[]? | select(.code=="V")' "$REVUE" >/dev/null 2>&1; then
  VERDICT="PARK"; RAISONS+=("P5:invariant-contexte-neuf")
fi

# P6 — échecs de gate consécutifs
if [[ -z "$VERDICT" ]]; then
  MAX=$(jq -r '.persistance.max_echecs_gate_consecutifs' "$M")
  N=$(cat "$STATE_DIR/$TASK_ID.echecs" 2>/dev/null || echo 0)
  if (( N >= MAX )); then
    VERDICT="PARK"; RAISONS+=("P6:echecs-consecutifs($N)")
  fi
fi

# P17 — modele servi ≠ modele attendu (2026-09-28, O49) : un role (auteur,
# conception, relecteur) a ete servi par un autre modele que celui de la matrice
# (alias qui bouge, bascule de quota). Arret dur : ni boucle de correction ni
# publication, l'humain decide. Test MD1.
if [[ -s "$STATE_DIR/$TASK_ID.modele-ecart" ]]; then
  VERDICT="PARK"
  RAISONS+=("P17:modele-servi($(awk -F'\t' '{printf "%s%s=%s(attendu %s)", (NR > 1 ? ";" : ""), $1, $3, $2}' "$STATE_DIR/$TASK_ID.modele-ecart"))")
fi

# --- Règles de progression -----------------------------------------------
if [[ -z "$VERDICT" ]]; then
  CHEMINS_SURS=1
  if ! touche_motif chemins_automerge >/dev/null; then CHEMINS_SURS=0; fi
  # tout chemin doit être dans chemins_automerge (liste blanche)
  while read -r f; do
    [[ -z "$f" ]] && continue
    IN=0
    while read -r pat; do
      match_glob "$f" "$pat" && { IN=1; break; }
    done < <(jq -r '.chemins_automerge[]' "$M")
    (( IN == 1 )) || CHEMINS_SURS=0
  done < <(git -C "$WT" diff --name-only "$BASE"...HEAD)

  SUPPS=$(git -C "$WT" diff --name-only --diff-filter=D "$BASE"...HEAD | wc -l | tr -d ' ')
  DEPS=0
  touche_motif fichiers_dependances >/dev/null && DEPS=1

  # M1 — auto-merge borné
  if [[ "$GATES" == "green" && "$RISQUE" == "low" && "$REV_VERDICT" == "accord" ]] \
     && awk -v c="$REV_CONF" -v m="$C_MIN" 'BEGIN{exit !(c+0 >= m+0)}' \
     && (( FILES <= V_AUTO_F && LINES <= V_AUTO_L )) \
     && [[ "$REV_NATURE" == "additive" && "$CHEMINS_SURS" == "1" && "$SUPPS" == "0" && "$DEPS" == "0" ]]; then
    VERDICT="AUTO_MERGE"
    RAISONS+=("M1:petit-additif-accord-chemins-sûrs")

  # M2 — brouillon
  elif [[ "$GATES" == "green" && "$RISQUE" == "low" ]] \
       && [[ "$REV_VERDICT" == "accord" || "$REV_VERDICT" == "reserve" ]] \
       && (( FILES <= V_DRFT_F && LINES <= V_DRFT_L )); then
    VERDICT="PR_DRAFT"
    RAISONS+=("M2:volume-moyen-accord-ou-reserve")

  # M3 — prêt pour revue humaine
  elif [[ "$GATES" == "green" ]]; then
    VERDICT="PR_READY"
    if [[ "$RISQUE" == "high" ]]; then RAISONS+=("M3:risque-high"); fi
    if [[ "$REV_VERDICT" == "desaccord" ]]; then RAISONS+=("M3:desaccord-reviewer"); fi
  fi
fi

# --- Q1 — critère de done non prouvé : jamais de fusion automatique ------
# (2026-09-21, essai 6 du bac à sable iziGSM) Le relecteur a codé trois rejets
# R2 — « critère de done non prouvé par le diff », invariant I10 : un critère
# d'acceptation du ticket non testé, des tests qui passeraient sans le correctif
# — mais les a classés « mineure », avec « accord » à 0,8 : la matrice a conclu
# AUTO_MERGE. La gravité est un jugement du modèle ; le CODE du rejet est un
# fait. Décision de l'opérateur : un critère non prouvé bloque la fusion
# automatique. AUTO_MERGE est ramené à PR_READY (relecture humaine), quelle que
# soit la gravité annoncée. Les autres verdicts ne changent pas.
if [[ "$VERDICT" == "AUTO_MERGE" ]] \
   && jq -e '[.rejets[]? | select(.code == "R2")] | length > 0' "$REVUE" >/dev/null 2>&1; then
  VERDICT="PR_READY"
  RAISONS+=("Q1:critere-non-prouve(R2)-fusion-automatique-refusee")
fi

# --- Q3 — tests jamais vus rouges : jamais de fusion automatique ---------
# (2026-09-22) Meme esprit que Q1, mais sur une MESURE du harnais et non sur un
# jugement du relecteur : test-rouge.sh a rejoue les tests de l'agent sur
# l'integration, sans son code. S'ils y passent aussi, ou s'il n'y en a pas, ou
# si la mesure a echoue, rien ne prouve le correctif : AUTO_MERGE est ramene a
# PR_READY. Non configure (pas de test_rouge dans gates.json) : rien ne change.
# Tests A1 a A4.
TEST_ROUGE="$(jq -r '.statut // empty' "$STATE_DIR/$TASK_ID.test-rouge.json" 2>/dev/null || true)"
if [[ "$VERDICT" == "AUTO_MERGE" ]]; then
  case "$TEST_ROUGE" in
    jamais-rouge) VERDICT="PR_READY"; RAISONS+=("Q3:test-jamais-vu-rouge-fusion-automatique-refusee") ;;
    aucun-test)   VERDICT="PR_READY"; RAISONS+=("Q3:aucun-test-fusion-automatique-refusee") ;;
    erreur)       VERDICT="PR_READY"; RAISONS+=("Q3:preuve-rouge-impossible-fusion-automatique-refusee") ;;
  esac
fi

# --- Q4 — tache corrigee apres un desaccord : jamais de fusion automatique
# (2026-09-27, O48, decision de l'operateur : option B) Le relecteur a d'abord
# ete en desaccord ; l'agent a corrige (boucle de correction, pipeline.sh) et un
# relecteur neuf est d'accord. Rien ne garantit que l'agent a corrige plutot
# qu'ecrit pour satisfaire le relecteur, et le second relecteur ignore le
# desaccord. Un desaccord est un signal : AUTO_MERGE est ramene a PR_READY, la
# fusion revient a l'humain. Les autres verdicts ne changent pas. Suite possible
# (option C) : faire confirmer par le relecteur que chaque rejet est solde.
# Test BC4.
CORRECTIONS_FAITES="$(sed -n 's/^corrections=//p' "$ORCH_DIR/etat/taches/$TASK_ID.env" 2>/dev/null | head -1 || true)"
if [[ "$VERDICT" == "AUTO_MERGE" ]] && (( ${CORRECTIONS_FAITES:-0} > 0 )); then
  VERDICT="PR_READY"
  RAISONS+=("Q4:corrige-apres-desaccord(${CORRECTIONS_FAITES})-fusion-automatique-refusee")
fi

# --- P16 — preuve a fournir : jamais de fusion automatique ---------------
# (2026-09-25, ADR 0003 R3, O40) L'agent a demande une preuve qu'il ne pouvait
# pas produire (E2E hors de portee, mutation d'un fichier critique) : tant
# qu'elle n'est pas soldee, AUTO_MERGE est ramene a PR_READY, et la raison P16
# (L3) demande a l'humain de la fournir. Reconcile refuse DONE d'ici la. PV1.
PREUVES_A_FOURNIR="$(jq '[.[]? | select(.statut == "a_fournir")] | length' "$STATE_DIR/$TASK_ID.preuves.json" 2>/dev/null || echo 0)"
if (( PREUVES_A_FOURNIR > 0 )) && [[ "$VERDICT" != "PARK" ]]; then
  [[ "$VERDICT" == "AUTO_MERGE" ]] && VERDICT="PR_READY"
  RAISONS+=("P16:preuve-a-fournir($PREUVES_A_FOURNIR)")
fi

# --- M4 / défaut : fail-safe --------------------------------------------
if [[ -z "$VERDICT" ]]; then
  VERDICT="$(jq -r '.defaut' "$M")"
  RAISONS+=("M4:defaut-fail-safe")
fi

# --- Sortie structurée ---------------------------------------------------
jq -n \
  --arg tache "$TASK_ID" \
  --arg verdict "$VERDICT" \
  --arg gates "$GATES" \
  --arg risque "$RISQUE" \
  --arg revue "$REV_VERDICT" \
  --argjson confiance "$REV_CONF" \
  --arg nature "$REV_NATURE" \
  --argjson fichiers "$FILES" \
  --argjson lignes "$LINES" \
  --argjson seuils "$(jq -c '[.volumes, .seuils_revue] | add' "$M")" \
  --args '{
    schema_version: "2.0",
    tache: $tache,
    verdict: $verdict,
    axe_a_gates: $gates,
    axe_b_volume: {fichiers: $fichiers, lignes: $lignes, seuils: $seuils},
    axe_c_risque: $risque,
    axe_d_revue: {verdict: $revue, confiance: $confiance},
    axe_e_nature: $nature,
    raisons: $ARGS.positional
  }' "${RAISONS[@]}" >"$STATE_DIR/$TASK_ID.decision.json"

cat "$STATE_DIR/$TASK_ID.decision.json"
log "Décision $TASK_ID : $VERDICT (${RAISONS[*]})"
exit "$PREUVE_RC"
