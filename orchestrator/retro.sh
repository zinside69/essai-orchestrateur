#!/usr/bin/env bash
# retro.sh — agent rétrospectif déterministe (Phase 5 / P2-b).
# Usage : retro.sh [--dry-run] [--seuil-reouvertures N] [--seuil-recidive N]
#
# Principe (conf. Nisi, WorkOS) : chaque échec est un bug du harnais. Ce script
# analyse les JSONL chaînés et les logs, détecte les récurrences par règles
# déterministes, et écrit/met à jour une mémoire par motif dans
# orchestrator/memory/<motif>.md — réinjectée au run suivant par scheduler.sh.
# 100 % déterministe : aucun appel LLM.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

DRY_RUN=0
SEUIL_REOUVERTURES=2   # escalades réouvertes plus de N fois pour le même motif
SEUIL_RECIDIVE=2       # verdicts red répétés sur le même motif

show_help() {
  cat <<'EOF'
Usage:
  retro.sh [--dry-run] [--seuil-reouvertures N] [--seuil-recidive N]

Détections (toutes déterministes) :
  - escalades réouvertes > seuil pour le même motif ;
  - verdicts red répétés sur le même motif ;
  - tâches réexécutées (même TASK_ID, runs multiples dans decisions.jsonl).
Écrit orchestrator/memory/<motif>.md et met à jour la métrique M15.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --seuil-reouvertures) SEUIL_REOUVERTURES="${2:?valeur manquante}"; shift 2 ;;
    --seuil-recidive) SEUIL_RECIDIVE="${2:?valeur manquante}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq awk sha256sum
MEMORY_DIR="$ROOT/orchestrator/memory"
DEC="$ORCH_DIR/journal/decisions.jsonl"
ESC="$ORCH_DIR/etat/escalades/escalades.jsonl"
M15="$ORCH_DIR/etat/m15.json"
mkdir -p "$MEMORY_DIR"

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN retro] decisions=%s\n' "$DEC"
  printf '[DRY-RUN retro] escalades=%s\n' "$ESC"
  printf '[DRY-RUN retro] memory_dir=%s\n' "$MEMORY_DIR"
  exit 0
fi

TS="$(date -u +%FT%TZ)"
MOTIFS_MEMORISES=0
RECIDIVES_EVITEES=0
declare -A MOTIF_COUNT

# Slug déterministe pour nom de fichier mémoire
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-60
}

write_memory() {
  local motif="$1" categorie="$2" detail="$3" occurrences="$4"
  local s f
  s="$(slug "$motif")"
  f="$MEMORY_DIR/$s.md"
  local debut=0
  [[ -f "$f" ]] && debut=1
  {
    printf '%s\n\n' "# Mémoire rétro — $motif"
    printf '%s\n' "- **Catégorie** : $categorie"
    printf '%s\n' "- **Dernière détection** : $TS"
    printf '%s\n' "- **Occurrences cumulées** : $occurrences"
    printf '\n%s\n\n%s\n' "## Détail" "$detail"
    printf '\n%s\n\n' "## Recommandation harnais"
    printf '%s\n' "Corriger le harnais, pas la sortie de l'agent. Ce motif a déjà été détecté $occurrences fois."
  } >"$f"
  sha256sum "$f" | awk '{print $1}' >"$f.sha256"
  (( debut == 0 )) && MOTIFS_MEMORISES=$((MOTIFS_MEMORISES + 1)) || RECIDIVES_EVITEES=$((RECIDIVES_EVITEES + 1))
  log "mémoire %s : %s (%s occurrence(s))" "$([ "$debut" -eq 0 ] && echo 'créée' || echo 'mise à jour')" "$s" "$occurrences"
}

# --- Détection 1 : escalades réouvertes > seuil pour le même motif ----------
if [[ -f "$ESC" ]]; then
  while IFS=$'\t' read -r motif n; do
    [[ -z "$motif" ]] && continue
    if (( n > SEUIL_REOUVERTURES )); then
      MOTIF_COUNT["$motif"]="$n"
      write_memory "$motif" "escalade-reouverture" \
        "L'escalade sur le motif \`$motif\` a été réouverte $n fois (> seuil $SEUIL_REOUVERTURES)." "$n"
    fi
  done < <(jq -r '.raisons // empty' "$ESC" 2>/dev/null | sort | uniq -c | awk '{n=$1; $1=""; sub(/^ +/,""); printf "%s\t%s\n", $0, n}')
fi

# --- Détection 2 : verdicts red répétés sur le même motif -------------------
if [[ -f "$DEC" ]]; then
  while IFS=$'\t' read -r motif n; do
    [[ -z "$motif" ]] && continue
    if (( n >= SEUIL_RECIDIVE )); then
      MOTIF_COUNT["$motif"]="$n"
      write_memory "$motif" "verdict-red-recurrent" \
        "Le motif \`$motif\` a produit $n verdicts/decisions red ou PARK (>= seuil $SEUIL_RECIDIVE)." "$n"
    fi
  done < <(jq -r 'select(.verdict=="PARK") | .raisons[]? // empty' "$DEC" 2>/dev/null \
             | sed 's/:.*//' | sort | uniq -c | awk '{n=$1; $1=""; sub(/^ +/,""); printf "%s\t%s\n", $0, n}')

  # --- Détection 3 : tâches réexécutées (même TASK_ID, runs multiples) ------
  while IFS=$'\t' read -r tache n; do
    [[ -z "$tache" ]] && continue
    if (( n > 1 )); then
      write_memory "reexecution:$tache" "tache-reexecutee" \
        "La tâche \`$tache\` apparaît $n fois dans le journal de décisions (réexécution)." "$n"
    fi
  done < <(jq -r '.tache // empty' "$DEC" 2>/dev/null | sort | uniq -c | awk '{printf "%s\t%s\n", $2, $1}')
fi

# --- Métrique M15 ------------------------------------------------------------
TOTAL_MOTIFS="${#MOTIF_COUNT[@]}"
jq -nc --arg ts "$TS" --argjson motifs "$TOTAL_MOTIFS" \
  --argjson crees "$MOTIFS_MEMORISES" --argjson recidives "$RECIDIVES_EVITEES" \
  '{ts_utc:$ts, motifs_memorises:$motifs, memoires_creees:$crees, recidives_evitees:$recidives}' \
  >"$M15"
printf 'retro_motifs=%s memoires_creees=%s recidives_evitees=%s\n' \
  "$TOTAL_MOTIFS" "$MOTIFS_MEMORISES" "$RECIDIVES_EVITEES"
exit 0
