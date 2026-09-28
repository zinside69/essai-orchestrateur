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
# AVANT : WORKTREE_ROOT="${WORKTREE_ROOT:-$(dirname "$ROOT")/wt}"
#   (2026-09-22, essai de publication, defaut 1) Deux projets ranges dans le meme
#   dossier se disputaient wt/T-001 — tout projet a une T-001 : le projet d'essai
#   a bute sur le worktree du bac a sable iziGSM. Un sous-dossier par projet.
#   Les worktrees deja crees a l'ancien endroit n'y sont pas deplaces. Test P4.
WORKTREE_ROOT="${WORKTREE_ROOT:-$(dirname "$ROOT")/wt/$(basename "$ROOT")}"

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

# journaliser_cout <T-NNN> <auteur|relecteur> <sortie de claude>
# (2026-09-22, essai de publication, defaut 7) Une ligne par appel a claude dans
# journal/couts.jsonl, ecrite juste apres l'appel, que la suite reussisse ou non :
# une tache ratee avant toute decision a quand meme depense. Lit la derniere ligne
# « result » (stream-json de l'auteur ou json du relecteur) ; les lignes qui ne
# sont pas du JSON (stderr melange au flux) sont ignorees. Sans ligne result
# (agent coupe) : « mesure absente », cout 0 — un trou visible, pas un oubli.
# Le cout est celui calcule par Claude Code (base « list » = tarif public, ce
# n'est pas ce qui est facture sous abonnement). Tests N1 a N3.
journaliser_cout() {
  local tache="$1" role="$2" src="$3" ligne=""
  mkdir -p "$ORCH_DIR/journal"
  if [[ -f "$src" ]]; then
    ligne="$(jq -cRn --arg t "$tache" --arg r "$role" --arg ts "$(date -u +%FT%TZ)" '
      ([inputs | fromjson? | objects | select(.type == "result")] | last) as $res
      | if $res == null then
          {ts:$ts, tache:$t, role:$r, mesure:"absente", cout_usd:0}
        else
          {ts:$ts, tache:$t, role:$r, mesure:"ok",
           cout_usd: ($res.total_cost_usd // 0),
           tours: ($res.num_turns // 0),
           duree_ms: ($res.duration_ms // 0),
           tokens: {entree: ($res.usage.input_tokens // 0),
                    cache_lu: ($res.usage.cache_read_input_tokens // 0),
                    cache_ecrit: ($res.usage.cache_creation_input_tokens // 0),
                    sortie: ($res.usage.output_tokens // 0),
                    reflexion: ($res.usage.output_tokens_details.thinking_tokens // 0)},
           modeles: (($res.modelUsage // {}) | keys),
           base: ([($res.modelUsage // {})[] | .costBasis? // empty] | unique | join(","))}
        end' "$src" 2>/dev/null)" || ligne=""
  fi
  [[ -n "$ligne" ]] || ligne="$(jq -cn --arg t "$tache" --arg r "$role" --arg ts "$(date -u +%FT%TZ)" \
    '{ts:$ts, tache:$t, role:$r, mesure:"absente", cout_usd:0}')"
  printf '%s\n' "$ligne" >>"$ORCH_DIR/journal/couts.jsonl"
}

# actions_ntfy <T-NNN> <jeton> <sujet de reponse> <reponse>...
# (2026-09-22, reponse depuis le telephone) En-tete « Actions » de ntfy : un
# bouton par reponse. Appuyer publie « T-NNN <reponse> <jeton> » sur le sujet de
# REPONSE, que lit ecouteur.sh. Pas de virgule ni de point-virgule dans le
# corps : ce sont les separateurs de l'en-tete. Test K7.
# (2026-09-23, O22) Une reponse peut porter son libelle : « approuver:Relancer »
# affiche « Relancer » et envoie « approuver ». Sans « : », libelle = reponse
# capitalisee (comportement d'avant). Tests K7, K13.
actions_ntfy() {
  # AVANT :   local tache="$1" jeton="$2" sujet="$3" r sortie="" sep=""
  local tache="$1" jeton="$2" sujet="$3" r rep lib sortie="" sep=""
  shift 3
  for r in "$@"; do
    rep="${r%%:*}"
    lib="${r#*:}"
    [[ "$r" == *:* ]] || lib="${rep^}"
    # AVANT :     sortie+="${sep}http, ${r^}, https://ntfy.sh/${sujet}, method=POST, body=${tache} ${r} ${jeton}, clear=true"
    sortie+="${sep}http, ${lib}, https://ntfy.sh/${sujet}, method=POST, body=${tache} ${rep} ${jeton}, clear=true"
    sep="; "
  done
  printf '%s' "$sortie"
}

# escalade_demandes_ecriture <demandes.json>
# (2026-09-25, O34) Decision P12 remise a escalade.sh pour les demandes
# d'ecriture en attente : raison, et en detail chaque demande AVEC SON DIFF
# EXACT — le texte que le harnais ecrira mot pour mot si l'humain approuve
# (ADR 0002 : ce que l'humain a lu est ce qui est ecrit). Avant, le detail
# s'arretait a la justification. Tests EP1 a EP3.
escalade_demandes_ecriture() {
  jq -c '{raisons: ["P12:demande-ecriture(\(length))"],
          detail: (map("- \(.fichier) : \(.besoin // "") — justification : \(.justification // "aucune")\n  Diff exact (ecrit tel quel si approuve) :\n\(.diff // "(aucun)")") | join("\n"))}' \
    "$1"
}

# curl_prive <url> [en-tete secret ...] -- [option curl ...]
# (2026-09-23, defaut 46) Les arguments d'un processus se lisent dans `ps` par
# tout processus du meme utilisateur — les agents lances par le socle compris.
# Or l'URL ntfy porte le NOM du sujet, qui est le secret (sujet d'alerte : il
# transporte les jetons des boutons ; sujet de reponse), et l'en-tete Actions
# porte le jeton. URL et en-tetes secrets passent donc par un fichier de
# configuration curl en 600, efface apres l'appel — meme regle que la cle Brevo
# (escalade.sh, envoyer_email). Les options apres « -- » restent en argument :
# elles ne doivent rien contenir de secret. Rend le code de curl. Tests K9, B6.
curl_prive() {
  local cfg rc=0
  cfg="$(mktemp)"
  chmod 600 "$cfg"
  {
    printf 'url = "%s"\n' "$(echapper_config_curl "$1")"
    shift
    while [[ $# -gt 0 && "$1" != -- ]]; do
      printf 'header = "%s"\n' "$(echapper_config_curl "$1")"
      shift
    done
  } >"$cfg"
  [[ "${1:-}" == -- ]] && shift
  curl -K "$cfg" "$@" || rc=$?
  rm -f "$cfg"
  return "$rc"
}

# sous_verrou_depot <commande...>
# (2026-09-23, essai de bout en bout, defaut 50) Deux taches lancees dans la meme
# seconde ecrivent dans les fichiers PARTAGES du depot (.git/config, FETCH_HEAD,
# references distantes) : git les protege par un verrou qui ECHOUE au lieu
# d'attendre (« could not lock config file ») — T-003 est tombee ainsi. Ici les
# ecritures partagees du harnais passent une par une, sous un verrou commun a
# tous les worktrees (git-common-dir). mkdir est atomique et portable : ni
# flock (absent de macOS), ni dependance nouvelle. Attente bornee a 120 s, puis
# echec explicite (code 75) plutot qu'une attente sans fin sur un verrou
# abandonne. Rend le code de la commande. Tests P6, P7.
sous_verrou_depot() {
  local verrou i=0 rc=0
  verrou="$(git rev-parse --git-common-dir)/orchestrateur.verrou"
  until mkdir "$verrou" 2>/dev/null; do
    if (( i >= 1200 )); then
      log "verrou du depot occupe depuis 120 s : $verrou (le supprimer s'il est abandonne)"
      return 75
    fi
    i=$((i + 1))
    sleep 0.1
  done
  "$@" || rc=$?
  rmdir "$verrou" 2>/dev/null || true
  return "$rc"
}

# Valeur entre guillemets d'un fichier de configuration curl : \ et " echappes.
# Caracteres nommes plutot qu'ecrits echappes : lisible, et sans piege de citation.
echapper_config_curl() {
  # shellcheck disable=SC1003  # '\' est bien une barre oblique inverse seule, pas un guillemet echappe
  local bs='\' dq='"' v
  v="${1//"$bs"/"$bs$bs"}"
  printf '%s' "${v//"$dq"/"$bs$dq"}"
}
