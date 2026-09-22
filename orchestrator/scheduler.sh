#!/usr/bin/env bash
# scheduler.sh — selectionne et lance les taches eligibles, respecte le graphe et le disjoncteur.
# Usage : scheduler.sh [--parallele N] [--inventaire] [--boucle] [--dry-run]
#         scheduler.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
E="$ROOT/orchestrator/escalade.json"
PARALLELE="${PARALLELE:-2}"
INVENTAIRE=0
BOUCLE=0
DRY_RUN=0

show_help() {
  cat <<'EOF'
Usage:
  scheduler.sh [--parallele N] [--inventaire] [--boucle] [--dry-run]
  scheduler.sh --help

Fonctions:
  - vérifie la fraîcheur du graphe ;
  - respecte les dépendances et exclusions ;
  - limite le parallélisme ;
  - déclenche pipeline.sh pour les tâches retenues ;
  - peut fonctionner en diagnostic pur (--inventaire, --dry-run).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --inventaire) INVENTAIRE=1; shift ;;
    --boucle) BOUCLE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --parallele)
      shift
      PARALLELE="${1:?valeur manquante pour --parallele}"
      shift ;;
    *) die "argument inattendu : $1" ;;
  esac
done

require jq git sha256sum
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"
MEMORY_DIR="$ROOT/orchestrator/memory"
mkdir -p "$ETAT_DIR/taches" "$LOG_DIR" "$STATE_DIR"
[[ -f "$E" ]] || die "politique d'escalade absente : $E"

# --- Mémoire rétro (Phase 5 / P2-b) ----------------------------------------
# Injecte dans le contexte de la tâche les mémoires pertinentes écrites par
# retro.sh (équivalent des fichiers mémoire par stack de Case).
inject_memoire() {
  local t="$1" envf="$ETAT_DIR/taches/$1.env"
  [[ -d "$MEMORY_DIR" ]] || return 0
  local memoires=()
  # Mémoire ciblée par tâche (réexécution)
  [[ -f "$MEMORY_DIR/reexecution-$t.md" ]] && memoires+=("$MEMORY_DIR/reexecution-$t.md")
  # Mémoires de motifs liées au périmètre de la tâche
  local perim
  perim="$(sed -n 's/^perimetre=//p' "$envf" 2>/dev/null | head -1 | tr ',' ' ')"
  local p f
  for p in $perim; do
    [[ -z "$p" ]] && continue
    for f in "$MEMORY_DIR"/*.md; do
      [[ -f "$f" ]] || continue
      grep -qiF -- "$p" "$f" 2>/dev/null && memoires+=("$f")
    done
  done
  # Déduplique
  if (( ${#memoires[@]} > 0 )); then
    mapfile -t memoires < <(printf '%s\n' "${memoires[@]}" | sort -u)
    {
      printf '\n## Mémoire rétro (Phase 5) — %s\n' "$t"
      for f in "${memoires[@]}"; do
        printf '\n### %s\n\n' "$(basename "$f")"
        cat "$f"
      done
    } >"$ETAT_DIR/taches/$t.memoire.md"
    log "mémoire rétro injectée pour $t (${#memoires[@]} source(s))"
  fi
}

inventaire() {
  local G="$ETAT_DIR/graphe.json"
  [[ -f "$G" ]] || die "graphe absent — lancer graphe.sh"
  jq -r '"graphe compile : \(.compile_le)",
         "eligibles      : \(if (.eligibles|length)==0 then "aucune" else (.eligibles|join(", ")) end)",
         "suspendues     : \(if (.suspendues|length)==0 then "aucune" else (.suspendues|join(", ")) end)",
         "cycles         : \(if (.cycles | length) == 0 then "aucun" else (.cycles | join(", ")) end)"' "$G"
  printf 'disjoncteur    : %s\n' "$(cat "$STATE_DIR/planificateur" 2>/dev/null || echo RUN)"
  printf 'escalades actives : %s\n' "$(jq -s '[.[] | select(.statut=="ouverte")] | length' \
    "$ETAT_DIR/escalades/escalades.jsonl" 2>/dev/null || echo 0)"
}

ensure_env_file() {
  local t="$1" envf="$ETAT_DIR/taches/$1.env"
  [[ -f "$envf" ]] && return 0
  jq -r --arg t "$t" '
    .noeuds[$t] as $n
    | "id=\($t)\netat=READY\npriorite=\($n.priorite)\nperimetre=\($n.perimetre|join(","))\ncritere=\($n.critere)\ngates=\($n.gates)\ndeps=\($n.deps|join(","))\nconflit=\($n.conflits|join(","))\nbranche=agent/\($t)\nrun=\nsession_auteur=\ntentatives=\($n.tentatives)\nblocage=none\nconsigne_humaine=\nmaj_le='"$(date -u +%FT%TZ)"'"' \
    "$ETAT_DIR/graphe.json" >"$envf"
}

count_running() {
  local n=0 f etat
  for f in "$ETAT_DIR"/taches/*.env; do
    [[ -f "$f" ]] || continue
    etat="$(sed -n 's/^etat=//p' "$f" | head -1)"
    [[ "$etat" == "RUNNING" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

run_once() {
  local G="$ETAT_DIR/graphe.json" MANIFESTE_SHA GRAPHE_SHA EN_COURS PLACES

  if [[ -f "$STATE_DIR/planificateur" ]] && grep -q '^PAUSE' "$STATE_DIR/planificateur"; then
    log "DISJONCTEUR ACTIF — planificateur en PAUSE. Aucune nouvelle tache lancee."
    return 0
  fi

  MANIFESTE_SHA="$(sha256sum "$ROOT/todo.md" | awk '{print $1}')"
  GRAPHE_SHA="$(jq -r '.manifeste_sha256' "$G" 2>/dev/null || echo absent)"
  if [[ "$MANIFESTE_SHA" != "$GRAPHE_SHA" ]]; then
    log "Graphe perime (manifeste modifie) — recompilation"
    "$ROOT/orchestrator/graphe.sh" "$ROOT/todo.md" >/dev/null || die "recompilation impossible"
  fi

  if (( $(jq -r '.cycles | length' "$G") > 0 )); then
    die "CYCLE dans le manifeste — arret. Corriger todo.md avant de relancer."
  fi

  EN_COURS="$(count_running)"
  PLACES=$(( PARALLELE - EN_COURS ))
  if (( PLACES <= 0 )); then
    log "Parallelisme sature ($EN_COURS/$PARALLELE) — rien a lancer"
    return 0
  fi

  mapfile -t CANDIDATES < <(
    jq -r '.eligibles[] as $t | "\(.noeuds[$t].priorite // "P9")\t\($t)"' "$G" \
    | sort -k1,1 -k2,2 | cut -f2 | head -n "$PLACES"
  )
  [[ ${#CANDIDATES[@]} -gt 0 ]] || { log "Aucune tache eligible"; return 0; }

  RETENUES=()
  for t in "${CANDIDATES[@]}"; do
    [[ -z "$t" ]] && continue
    conflit=0
    for r in "${RETENUES[@]:-}"; do
      [[ -z "$r" ]] && continue
      if jq -e --arg t "$t" --arg r "$r" '(.noeuds[$t].conflits // []) | index($r)' "$G" >/dev/null; then
        conflit=1
      fi
      if jq -e --arg t "$t" --arg r "$r" '(.noeuds[$r].conflits // []) | index($t)' "$G" >/dev/null; then
        conflit=1
      fi
    done
    (( conflit == 0 )) && RETENUES+=("$t")
  done

  for t in "${RETENUES[@]:-}"; do
    [[ -z "$t" ]] && continue
    ensure_env_file "$t"
    inject_memoire "$t"
    # Transition gardee READY -> RUNNING (Phase 5 / P3-a)
    if ! transition_etat "$ETAT_DIR/taches/$t.env" RUNNING scheduler; then
      log "transition refusee pour $t — tache ignoree"
      continue
    fi
    if (( DRY_RUN == 1 )); then
      printf '[DRY-RUN scheduler] pipeline.sh %s\n' "$t"
    else
      # (2026-09-21) Session a part. nohup seul ne suffisait pas : sur le bac a
      # sable iziGSM, l'agent « claude -p » est mort de SIGHUP (rc 129) quand la
      # session qui avait lance le planificateur s'est fermee — claude retablit
      # son propre traitement du signal. Un humain qui ferme son terminal aurait
      # tue ses agents. setsid detache le pipeline de tout terminal ; il n'existe
      # pas sur macOS : la ligne d'origine, intacte, reste le repli.
      if command -v setsid >/dev/null 2>&1; then
        # (2026-09-21, essai 3) « setsid … & » laissait une COURSE : si le
        # planificateur se terminait avant que le processus d'arriere-plan ait
        # execute setsid, la session l'emportait — pipeline mort sans ecrire une
        # ligne, tache figee en RUNNING. Mesure : meme lancement + « sleep 1 »
        # survit, sans lui meurt. « setsid -f » cree lui-meme le processus
        # detache avant de rendre la main : plus de course, plus d'attente.
        # AVANT : setsid nohup "$ROOT/orchestrator/pipeline.sh" "$t" >>"$LOG_DIR/scheduler-$t.log" 2>&1 </dev/null &
        setsid -f nohup "$ROOT/orchestrator/pipeline.sh" "$t" >>"$LOG_DIR/scheduler-$t.log" 2>&1 </dev/null
      else
      nohup "$ROOT/orchestrator/pipeline.sh" "$t" >>"$LOG_DIR/scheduler-$t.log" 2>&1 &
      fi
    fi
  done
  log "${#RETENUES[@]} tache(s) retenue(s) : ${RETENUES[*]:-aucune}"
}

if (( INVENTAIRE == 1 )); then
  inventaire
  exit 0
fi

if (( BOUCLE == 1 )); then
  while true; do
    run_once
    sleep 60
  done
else
  run_once
fi
