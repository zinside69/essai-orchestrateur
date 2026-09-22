#!/usr/bin/env bash
# Utilitaires partages Phase 1.
set -Eeuo pipefail

# awk BSD (macOS) suit la locale pour les nombres : en fr_FR il ecrit « 1,000 »
# et compare mal « 1,000 » a 0.95 (run-replay sortait en rc=1, D6 tombait).
# Le socle ecrit et relit des nombres a point : on fixe la locale numerique.
export LC_NUMERIC=C

ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# (2026-09-21, essai 4 du bac a sable) ROOT est EXPORTE : un script enfant en
# herite au lieu de le recalculer depuis son dossier courant. run-task.sh se
# place dans le worktree de l'agent puis lance gate.sh : sans l'export, gate.sh
# prenait le worktree pour la racine — verdict et preuve des tests ecrits dans
# le .orchestrator de l'agent (escalade P8 a tort), et gates.json lu dans SA
# copie, ce qui laissait l'agent definir ses propres controles. Test R1.
export ROOT
ORCH_DIR="${ORCH_STATE:-$ROOT/.orchestrator}"
LOG_DIR="$ORCH_DIR/logs"
STATE_DIR="$ORCH_DIR/state"
INTEGRATION_BRANCH="${INTEGRATION_BRANCH:-integration}"
# shellcheck disable=SC2034
AGENT_BRANCH_PREFIX="agent"
WORKTREE_ROOT="${WORKTREE_ROOT:-$(dirname "$ROOT")/wt}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

log()  { printf '[%s] %s\n' "$(date -u +%T)" "$*" >&2; }
die()  { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || die "dependance manquante : $bin"
  done
}

# Extrait une tache de todo.md : id, priorite, perimetre, critere, gates
parse_task() {
  local task_id="$1" manifest="${2:-$ROOT/todo.md}"
  awk -v id="$task_id" '
    $0 ~ "^- \\[[ x]\\] " id " " {
      n = split($0, part, "|")
      gsub(/^- \[[ x]\] /, "", part[1]); gsub(/^ +| +$/, "", part[1])
      for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", part[i]) }
      printf "id=%s\npriorite=%s\nperimetre=%s\ncritere=%s\ngates=%s\n", \
             part[1], part[2], part[3], part[4], part[5]
      exit
    }
  ' "$manifest"
}

# --- Skill designe par etape (2026-09-21) -------------------------------------
# Rend le skill a utiliser pour une etape (implementation, revue) d'une tache :
# par_tache d'abord, puis etapes. Chaine vide = aucun skill. Un skills.json
# absent n'est pas une erreur : le socle fonctionne sans skill, comme avant.
# La valeur est validee (nom de skill, eventuellement prefixe par un plugin) :
# elle est ensuite ecrite dans un prompt et dans une regle de permission.
skill_pour() {
  local etape="$1" task_id="$2" fichier="${3:-$ROOT/orchestrator/skills.json}" nom
  [[ -f "$fichier" ]] || return 0
  nom="$(jq -r --arg e "$etape" --arg t "$task_id" \
    '(.par_tache[$t][$e]) // (.etapes[$e]) // ""' "$fichier")" \
    || die "skills.json illisible : $fichier"
  [[ -z "$nom" || "$nom" =~ ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$ ]] \
    || die "nom de skill invalide pour $etape/$task_id : $nom"
  printf '%s' "$nom"
}

# --- Preparation du worktree par le projet (2026-09-21) -----------------------
# Un worktree neuf n'a rien de ce que git ignore : ni node_modules, ni fichiers
# generes (les types Wrangler d'iziGSM : 495 erreurs tsc sans eux, 32 avec).
# L'agent ne pourrait ni lancer ses tests, ni passer les controles. Si le projet
# fournit orchestrator/preparer-worktree.sh — lu dans ROOT, jamais dans le
# worktree de l'agent —, il est lance DANS le worktree. Son echec arrete la
# tache avant l'agent : un agent dans un worktree inutilisable brulerait ses
# tours pour rien. Sans ce script, rien ne change.
preparer_worktree() {
  local wt="$1" script="$ROOT/orchestrator/preparer-worktree.sh" journal
  [[ -f "$script" ]] || return 0
  journal="$LOG_DIR/preparation-$(basename "$wt").log"
  ( cd "$wt" && ROOT="$ROOT" bash "$script" ) >"$journal" 2>&1 \
    || die "preparation du worktree en echec : $wt (voir $journal)"
  log "Worktree prepare par le projet : $wt"
}

# --- Exclusion locale d'un fichier du depot (2026-09-21) ----------------------
# Ajoute un motif a info/exclude (une seule fois) : git l'ignore dans ce depot et
# tous ses worktrees, sans toucher au .gitignore versionne du projet. Sert aux
# fichiers que le socle depose dans un worktree et qui ne doivent jamais etre
# committes (fiche de tache .claude-task.md).
exclure_localement() {
  local depot="$1" motif="$2" exclude
  exclude="$(git -C "$depot" rev-parse --git-path info/exclude)"
  [[ "$exclude" == /* ]] || exclude="$depot/$exclude"
  mkdir -p "$(dirname "$exclude")"
  grep -qxF -- "$motif" "$exclude" 2>/dev/null || printf '%s\n' "$motif" >>"$exclude"
}

# --- Machine a etats formelle (Phase 5 / P3-a) -------------------------------
# Point d'entree unique pour toute ecriture d'etat. Si graphe.json porte une
# matrice machine_etats, les transitions sont gardees (refus : rc 30) ; sinon
# le mode permissif avec avertissement preserve la retrocompatibilite Phase 4.
transition_etat() {
  local envf="$1" cible="$2" appelant="${3:-inconnu}"
  [[ -f "$envf" ]] || die "transition_etat : fichier etat absent : $envf"
  local courant tache mode="strict"
  courant="$(sed -n 's/^etat=//p' "$envf" | head -1)"
  tache="$(basename "$envf" .env)"
  [[ "$courant" == "$cible" ]] && return 0
  local G="$ORCH_DIR/etat/graphe.json"
  if [[ -f "$G" ]] && jq -e '.machine_etats' "$G" >/dev/null 2>&1; then
    if ! jq -e --arg c "$cible" '.machine_etats.etats | index($c)' "$G" >/dev/null; then
      printf '[ERREUR] transition interdite : %s -> %s (etat cible inconnu, tache %s)\n' "$courant" "$cible" "$tache" >&2
      return 30
    fi
    if ! jq -e --arg d "$courant" --arg c "$cible" \
      '(.machine_etats.transitions[$d] // []) | index($c)' "$G" >/dev/null; then
      printf '[ERREUR] transition interdite : %s -> %s (tache %s)\n' "$courant" "$cible" "$tache" >&2
      return 30
    fi
  else
    mode="permissif"
    printf '[WARN] machine_etats absente — transition %s -> %s en mode permissif (tache %s)\n' "$courant" "$cible" "$tache" >&2
  fi
  sed -i "s/^etat=.*/etat=$cible/" "$envf"
  sed -i "s/^maj_le=.*/maj_le=$(date -u +%FT%TZ)/" "$envf"
  mkdir -p "$ORCH_DIR/journal"
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg t "$tache" --arg de "$courant" \
    --arg vers "$cible" --arg a "$appelant" --arg m "$mode" \
    '{ts_utc:$ts,tache:$t,de:$de,vers:$vers,appelant:$a,mode:$m}' \
    >>"$ORCH_DIR/journal/transitions.jsonl"
  return 0
}
