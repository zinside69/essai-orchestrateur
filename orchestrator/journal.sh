#!/usr/bin/env bash
# journal.sh — ajoute une décision au journal append-only, avec chaîne d'intégrité.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: journal.sh T-NNN}"
DECISION="${2:?chemin vers state/T-NNN.decision.json}"
REVUE="${3:?chemin vers state/T-NNN.revue.json}"

JOURNAL_DIR="$ORCH_DIR/journal"
JOURNAL="$JOURNAL_DIR/decisions.jsonl"
M="$ROOT/orchestrator/matrice.json"
mkdir -p "$JOURNAL_DIR"

require jq sha256sum

# --- Chaînage : hash de la ligne précédente, ou genesis -------------------
if [[ -f "$JOURNAL" ]]; then
  PREV="$(tail -1 "$JOURNAL" | jq -r '.hash')"
  ID=$(printf 'd-%06d' $(( $(grep -c '' "$JOURNAL") + 1 )) )
else
  PREV="0000000000000000000000000000000000000000000000000000000000000000"
  ID="d-000001"
fi

# --- Empreinte de la matrice : détecte un changement de seuils ------------
MATRICE_SHA="$(sha256sum "$M" | awk '{print $1}')"
SHA_BASE="$(git -C "$ROOT" rev-parse --short "$INTEGRATION_BRANCH")"
SHA_HEAD="$(git -C "$ROOT" rev-parse --short "agent/$TASK_ID")"

# --- Preuve d'exécution des gates (Phase 5 / P1-c) ---------------------------
# Les hashes des sorties de gates sont scellés dans la ligne chaînée : la
# chaîne SHA-256 devient une preuve d'exécution bout-en-bout.
PREUVE_JSON="null"
if [[ -f "$STATE_DIR/$TASK_ID.verdict.json" ]]; then
  PREUVE_JSON="$(jq -c '.preuve // null' "$STATE_DIR/$TASK_ID.verdict.json")"
fi

# --- Contenu de la ligne, hors hash ---------------------------------------
CHEMINS_JSON="$(git -C "$ROOT" diff --name-only "${INTEGRATION_BRANCH}...agent/$TASK_ID" | jq -R . | jq -cs .)"
CORPS="$(jq -c -n \
  --arg id "$ID" \
  --arg ts "$(date -u +%FT%TZ)" \
  --arg tache "$TASK_ID" \
  --argjson decision "$(cat "$DECISION")" \
  --argjson revue "$(cat "$REVUE")" \
  --argjson seuils "$(jq -c '[.volumes, .seuils_revue] | add' "$M")" \
  --arg sha_m "$MATRICE_SHA" \
  --arg sha_b "$SHA_BASE" \
  --arg sha_h "$SHA_HEAD" \
  --arg prev "$PREV" \
  --argjson chemins "$CHEMINS_JSON" \
  --argjson cout '{"auteur":0,"reviewer":0,"total":0}' \
  --argjson preuve "$PREUVE_JSON" \
  '{
     schema_version: "2.0",
     id_decision: $id,
     ts_utc: $ts,
     tache: $tache,
     verdict: $decision.verdict,
     axe_a_gates: $decision.axe_a_gates,
     axe_b_volume: $decision.axe_b_volume,
     axe_c_risque: $decision.axe_c_risque,
     axe_d_revue: {verdict: $revue.verdict, confiance: $revue.confiance, modele: $revue.modele_reviewer},
     axe_e_nature: $decision.axe_e_nature,
     chemins_modifies: $chemins,
     raisons: $decision.raisons,
     seuils_appliques: $seuils,
     matrice_sha256: $sha_m,
     sha_base: $sha_b,
     sha_head: $sha_h,
     cout_usd: $cout,
     preuve_gates: $preuve,
     prev_hash: $prev
   }')"

# --- Hash de la ligne = SHA-256 du corps sans le champ hash ---------------
HASH="$(printf '%s' "$CORPS" | sha256sum | awk '{print $1}')"
LIGNE="$(jq -c --arg h "$HASH" '. + {hash: $h}' <<<"$CORPS")"

printf '%s\n' "$LIGNE" >>"$JOURNAL"
log "Journal : $ID — $TASK_ID → $(jq -r '.verdict' <<<"$LIGNE")"
