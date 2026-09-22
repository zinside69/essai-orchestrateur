#!/usr/bin/env bash
# verify-evidence.sh — contrôle bloquant de l'evidence pack d'une tâche (Phase 5 / P1-d).
# Sortie : 0 = pack complet, 20 = evidence manquante (escalade), 1 = erreur d'usage.
#
# Principe (conf. Nisi, WorkOS) : aucune revue sans preuve non-code. Les artefacts
# requis sont déclarés dans matrice.json (.evidence.types) selon le type de tâche
# (champ type_tache du fichier .env, défaut configurable via .evidence.defaut).
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: verify-evidence.sh T-NNN}"
M="$ROOT/orchestrator/matrice.json"
F="$ORCH_DIR/etat/taches/$TASK_ID.env"
EV_DIR="$STATE_DIR/$TASK_ID.evidence"
RAISON_FILE="$STATE_DIR/$TASK_ID.evidence.raison"

require jq

# Rétrocompatibilité : evidence non obligatoire => passage libre.
if [[ "$(jq -r '.evidence.obligatoire // false' "$M")" != "true" ]]; then
  log "evidence pack non obligatoire — passage libre"
  exit 0
fi

TYPE_TACHE=""
[[ -f "$F" ]] && TYPE_TACHE="$(sed -n 's/^type_tache=//p' "$F" | head -1)"
[[ -n "$TYPE_TACHE" ]] || TYPE_TACHE="$(jq -r '.evidence.defaut // "code"' "$M")"

mapfile -t REQUIS < <(jq -r --arg t "$TYPE_TACHE" \
  '(.evidence.types[$t] // .evidence.types[.evidence.defaut] // [])[]' "$M")

MANQUANTS=()
for art in "${REQUIS[@]+"${REQUIS[@]}"}"; do
  [[ -z "$art" ]] && continue
  if ! compgen -G "$EV_DIR/$art.*" >/dev/null; then
    MANQUANTS+=("$art")
  else
    # Artefact présent mais vide = absent.
    vide=1
    for f in "$EV_DIR/$art".*; do
      [[ -s "$f" ]] && { vide=0; break; }
    done
    (( vide == 1 )) && MANQUANTS+=("$art")
  fi
done

if (( ${#MANQUANTS[@]} > 0 )); then
  RAISON="P8:evidence-manquante($(IFS=,; printf '%s' "${MANQUANTS[*]}"))"
  printf '%s\n' "$RAISON" >"$RAISON_FILE"
  log "$TASK_ID : $RAISON"
  exit 20
fi

rm -f "$RAISON_FILE"
log "$TASK_ID : evidence pack complet (type=$TYPE_TACHE)"
exit 0
