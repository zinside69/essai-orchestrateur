#!/usr/bin/env bash
# prune-contexte.sh — prune documentaire pilotée par mesure (Phase 5 / P3-b).
# Usage : prune-contexte.sh [--doc F] [--sortie F.md] [--dry-run]
#
# Principe (conf. Nisi, WorkOS) : mesurer au lieu d'assumer. Pour chaque
# document injecté dans le contexte des agents, on mesure le score des suites
# de non-régression (run-manifeste + run-replay) AVEC puis SANS le document
# (neutralisé puis restauré). delta = avec - sans :
#   POSITIVE (delta > 0) : le document est conservé ;
#   NEUTRE   (delta = 0) : candidat à la prune (n'améliore aucune métrique) ;
#   NEGATIVE (delta < 0) : quarantaine (dégrade les métriques).
# Journal : .orchestrator/journal/prune-docs.jsonl — exploité par M16.
# (2026-09-26, O18) La neutralisation se fait dans un CLONE JETABLE du dépôt : le document du
# dépôt réel n'est jamais renommé, même pendant les minutes que dure la mesure.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

DRY_RUN=0
SORTIE=""
DOC_CIBLE=""

show_help() {
  cat <<'EOF'
Usage:
  prune-contexte.sh [--doc F] [--sortie F.md] [--dry-run]

Options:
  --doc F      évalue uniquement le document F (chemin relatif à la racine)
  --sortie F   rapport markdown (defaut: .orchestrator/logs/prune-rapport.md)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --doc) DOC_CIBLE="${2:?valeur manquante}"; shift 2 ;;
    --sortie) SORTIE="${2:?valeur manquante}"; shift 2 ;;
    *) die "argument inattendu : $1" ;;
  esac
done

# AVANT : require jq awk grep
require jq awk grep git   # (2026-09-26, O18) git : clone jetable de mesure
# (2026-09-26, O18) Garde-fou : ce script lance des suites dans un clone jetable et exporte
# ORCH_PRUNE_CLONE ; s'il est relance depuis cet environnement, il refuse plutot que de cloner
# sans fin. Aujourd'hui aucune suite ne le rappelle : c'est une protection contre l'avenir. Test J4.
if [[ -n "${ORCH_PRUNE_CLONE:-}" ]]; then
  die "prune-contexte : recursion refusee (lance depuis le clone jetable d'une mesure en cours)"
fi
PRUNE_LOG="$ORCH_DIR/journal/prune-docs.jsonl"
QUAR_DOCS="$ORCH_DIR/etat/quarantaine-docs.tsv"
SORTIE="${SORTIE:-$LOG_DIR/prune-rapport.md}"
mkdir -p "$(dirname "$PRUNE_LOG")" "$(dirname "$QUAR_DOCS")" "$(dirname "$SORTIE")"

# Documents réellement injectés dans le contexte des agents (les PDF/HTML de
# phases sont des artefacts de livraison, hors périmètre par construction).
if [[ -n "$DOC_CIBLE" ]]; then
  DOCS=("$DOC_CIBLE")
else
  DOCS=(CLAUDE.md .claude/reviewer-invariants.md .claude/agents/reviewer-diff.md)
fi

# (2026-09-22, defaut 45) La « restauration garantie » annoncee plus bas n'etait
# garantie par rien : un run interrompu entre les deux « mv » laissait le
# document renomme en .pruned — constate sur le CLAUDE.md du socle lui-meme.
# Reprise d'abord (y compris en --dry-run) : un .pruned sans son original est un
# reste d'interruption, meme par SIGKILL, qu'aucun trap n'intercepte. Test J3.
for doc in "${DOCS[@]}"; do
  if [[ -f "$ROOT/$doc.pruned" && ! -e "$ROOT/$doc" ]]; then
    mv "$ROOT/$doc.pruned" "$ROOT/$doc"
    log "document restaure (reste d'une mesure interrompue) : $doc"
  fi
done

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN prune] docs=%s\n' "${DOCS[*]}"
  printf '[DRY-RUN prune] journal=%s rapport=%s\n' "$PRUNE_LOG" "$SORTIE"
  exit 0
fi

# (2026-09-26, O18) Clone jetable : la mesure y neutralise le document, jamais dans $ROOT.
# Les documents évalués sont recopiés depuis le dossier de travail (on mesure ce qui est
# sur le disque, modifications non commitées comprises) ; le reste vient de HEAD.
# Journal, quarantaine et rapport restent écrits dans l'état réel ($ORCH_DIR).
CLONE_DIR="$(mktemp -d)"
DEPOT="$CLONE_DIR/depot"
# shellcheck disable=SC2329  # appelee par les trap plus bas
nettoyer_clone() {
  if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR" ]]; then rm -rf "$CLONE_DIR"; fi
}
trap nettoyer_clone EXIT
git -c safe.directory='*' clone -q "$ROOT" "$DEPOT" || die "clone jetable impossible : $ROOT"
for doc in "${DOCS[@]}"; do
  [[ -f "$ROOT/$doc" ]] || continue
  mkdir -p "$(dirname "$DEPOT/$doc")"
  cp "$ROOT/$doc" "$DEPOT/$doc"
done

# Score combiné : taux de cas manifeste + taux de succès du replay (moyenne).
# (2026-09-26, O18 + défaut 79) mesure <racine> : les suites sont celles de la racine donnée (le
# clone jetable), avec ROOT explicite et sans ORCH_STATE (elles écrivent dans le clone) ; le
# nombre total de cas du manifeste est lu dans sa sortie (« 14/14 cas ») au lieu d'un 13 en dur.
mesure() {
  # AVANT : local mani replay_out
  local mani mani_ligne mani_tot replay_out base="${1:-$ROOT}"
  # AVANT : mani="$("$ROOT/tests/run-manifeste.sh" 2>/dev/null | grep -oE '[0-9]+/[0-9]+ cas' | head -1 | cut -d/ -f1)"
  mani_ligne="$(ROOT="$base" ORCH_PRUNE_CLONE=1 env -u ORCH_STATE "$base/tests/run-manifeste.sh" 2>/dev/null \
    | grep -oE '[0-9]+/[0-9]+ cas' | head -1)"
  mani="${mani_ligne%%/*}"
  mani_tot="${mani_ligne#*/}"
  mani_tot="${mani_tot% cas}"
  # AVANT : replay_out="$("$ROOT/tests/run-replay.sh" --seuil-deja-tranchees 1 --seuil-couvertes 0 2>/dev/null \
  replay_out="$(ROOT="$base" ORCH_PRUNE_CLONE=1 env -u ORCH_STATE "$base/tests/run-replay.sh" \
    --seuil-deja-tranchees 1 --seuil-couvertes 0 2>/dev/null \
    | grep 'success_rate' | grep -oE '[0-9.]+$')"
  # AVANT : awk -v m="${mani:-0}" -v r="${replay_out:-0}" 'BEGIN{printf "%.3f", (m/13 + r)/2}'
  awk -v m="${mani:-0}" -v t="${mani_tot:-13}" -v r="${replay_out:-0}" \
    'BEGIN{printf "%.3f", ((t > 0 ? m/t : 0) + r)/2}'
}

TS="$(date -u +%FT%TZ)"
# AVANT : BASELINE="$(mesure)"
BASELINE="$(mesure "$DEPOT")"
log "prune-contexte : baseline=$BASELINE"

RAPPORT_TMP="$(mktemp)"
{
  printf '%s\n' "# Rapport de prune documentaire — $TS"
  printf '\n%s\n' "Baseline (tous documents présents) : $BASELINE"
  printf '\n%s\n' '| Document | Avec | Sans | Delta | Contribution | Décision |'
  printf '%s\n' '|---|---:|---:|---:|---|---|'
} >"$RAPPORT_TMP"

# (2026-09-22, defaut 45) Et pendant la mesure : remise en place sur toute
# sortie, Ctrl+C, TERM, fermeture du terminal ou erreur. (Bash execute le trap
# une fois la commande en cours terminee.) SIGKILL reste couvert par la reprise
# au demarrage, ci-dessus.
DOC_NEUTRALISE=""
# shellcheck disable=SC2329  # appelee par les trap ci-dessous
restaurer_doc() {
  if [[ -n "$DOC_NEUTRALISE" && -f "$DOC_NEUTRALISE.pruned" ]]; then
    mv "$DOC_NEUTRALISE.pruned" "$DOC_NEUTRALISE"
    log "document restaure apres interruption : $DOC_NEUTRALISE"
  fi
}
# AVANT : trap restaurer_doc EXIT
# (2026-09-26, O18) restaurer_doc ne sert plus qu'aux restes d'anciennes versions ; le clone
# jetable est supprimé à toute sortie (le trap EXIT posé plus haut serait sinon remplacé).
trap 'restaurer_doc; nettoyer_clone' EXIT
# AVANT : trap 'restaurer_doc; exit 130' INT TERM HUP
trap 'restaurer_doc; nettoyer_clone; exit 130' INT TERM HUP

for doc in "${DOCS[@]}"; do
  F="$ROOT/$doc"
  if [[ ! -f "$F" ]]; then
    log "document absent, ignoré : $doc"
    continue
  fi
  # (2026-09-26, O18) Neutralisation dans le CLONE jetable : $F (dépôt réel) n'est jamais
  # renommé, plus de sauvegarde ni de restauration à garantir. Le clone reprend son document
  # entre deux mesures, et disparaît de toute façon à la sortie.
  # AVANT : BAK="$(mktemp)"
  # AVANT : cp "$F" "$BAK"
  # AVANT : # Neutralise le document (restauration garantie même en cas d'échec)
  # AVANT : mv "$F" "$F.pruned"
  # AVANT : DOC_NEUTRALISE="$F"
  # AVANT : SANS="$(mesure)"
  # AVANT : mv "$F.pruned" "$F"
  # AVANT : DOC_NEUTRALISE=""
  # AVANT : cmp -s "$BAK" "$F" || cp "$BAK" "$F"
  # AVANT : rm -f "$BAK"
  mv "$DEPOT/$doc" "$DEPOT/$doc.pruned"
  SANS="$(mesure "$DEPOT")"
  mv "$DEPOT/$doc.pruned" "$DEPOT/$doc"
  DELTA="$(awk -v a="$BASELINE" -v s="$SANS" 'BEGIN{printf "%+.3f", a-s}')"
  CONTRIB="$(awk -v d="$DELTA" 'BEGIN{ if (d+0 > 0) print "POSITIVE"; else if (d+0 < 0) print "NEGATIVE"; else print "NEUTRE" }')"
  case "$CONTRIB" in
    POSITIVE) DECISION_TXT="conserver" ;;
    NEUTRE)   DECISION_TXT="candidat prune" ;;
    NEGATIVE) DECISION_TXT="quarantaine" ;;
  esac
  printf '| %s | %s | %s | %s | %s | %s |\n' "$doc" "$BASELINE" "$SANS" "$DELTA" "$CONTRIB" "$DECISION_TXT" >>"$RAPPORT_TMP"
  jq -nc --arg ts "$TS" --arg d "$doc" --argjson avec "$BASELINE" --argjson sans "$SANS" \
    --arg delta "$DELTA" --arg c "$CONTRIB" \
    '{ts_utc:$ts,doc:$d,score_avec:$avec,score_sans:$sans,delta:($delta|tonumber),contribution:$c}' \
    >>"$PRUNE_LOG"
  if [[ "$CONTRIB" == "NEGATIVE" ]]; then
    grep -qF "$doc" "$QUAR_DOCS" 2>/dev/null || printf '%s\t%s\t%s\n' "$doc" "$TS" "delta_negatif" >>"$QUAR_DOCS"
    log "quarantaine documentaire : $doc (delta=$DELTA)"
  fi
done

{
  printf '\n%s\n' '## Règle de décision'
  printf '%s\n' 'Seuls les documents à contribution POSITIVE mesurée sont conservés sans réserve.'
  printf '%s\n' 'NEUTRE = candidat à la prune ; NEGATIVE = quarantaine immédiate (jamais de prune sur intuition).'
} >>"$RAPPORT_TMP"
cp "$RAPPORT_TMP" "$SORTIE"
rm -f "$RAPPORT_TMP"
printf 'prune_baseline=%s docs=%s rapport=%s\n' "$BASELINE" "${#DOCS[@]}" "$SORTIE"
exit 0
