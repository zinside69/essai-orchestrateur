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
#
# (2026-09-29, O50) total_cost_usd et modelUsage sont CUMULES sur la session, et
# run-task.sh reprend la session de l'auteur (--resume) ; « usage » ne compte que le
# passage. Chaque ligne garde donc le cumul de sa session (cumul_session) et compte
# la difference avec la ligne precedente de la meme session : cout_usd = cout du
# passage, par_modele = tokens et cout de chaque modele pour ce passage. Additionner
# les cumuls comptait les passages precedents plusieurs fois (auteur de T-004 d'iziGSM,
# 27/09 : session de 18,19 $, comptee 48,40 $). Premier passage d'une session : difference
# avec zero, comme avant. Test CS1.
journaliser_cout() {
  # AVANT :   local tache="$1" role="$2" src="$3" ligne=""
  local tache="$1" role="$2" src="$3" ligne="" session="" precedent="null"
  mkdir -p "$ORCH_DIR/journal"
  if [[ -f "$src" ]]; then
    session="$(jq -rRn '[inputs | fromjson? | objects | select(.type == "result")] | last | .session_id // empty' "$src" 2>/dev/null || true)"
    if [[ -n "$session" && -f "$ORCH_DIR/journal/couts.jsonl" ]]; then
      precedent="$(jq -c --arg s "$session" 'select(.session == $s) | .cumul_session // empty' \
        "$ORCH_DIR/journal/couts.jsonl" 2>/dev/null | tail -1)"
      [[ -n "$precedent" ]] || precedent="null"
    fi
    # AVANT :     ligne="$(jq -cRn --arg t "$tache" --arg r "$role" --arg ts "$(date -u +%FT%TZ)" '
    ligne="$(jq -cRn --arg t "$tache" --arg r "$role" --arg ts "$(date -u +%FT%TZ)" --argjson prec "$precedent" '
      ([inputs | fromjson? | objects | select(.type == "result")] | last) as $res
      | if $res == null then
          {ts:$ts, tache:$t, role:$r, mesure:"absente", cout_usd:0}
        else
          (($res.modelUsage // {}) | with_entries(.value |= {entree: (.inputTokens // 0), cache_lu: (.cacheReadInputTokens // 0),
            cache_ecrit: (.cacheCreationInputTokens // 0), sortie: (.outputTokens // 0), cout_usd: (.costUSD // 0)})) as $cum
          | (($prec // {}).par_modele // {}) as $pm
          | ($cum | with_entries(.key as $m | .value |= with_entries(.key as $k | .value -= ((($pm[$m] // {})[$k]) // 0)))
                  | with_entries(select([.value[]] | any(. > 0)))) as $delta
          # AVANT :           {ts:$ts, tache:$t, role:$r, mesure:"ok",
          | {ts:$ts, tache:$t, role:$r, mesure:"ok",
           # AVANT : cout_usd: ($res.total_cost_usd // 0),
           cout_usd: (($res.total_cost_usd // 0) - (($prec // {}).cout_usd // 0)),
           cout_cumule_usd: ($res.total_cost_usd // 0),
           session: ($res.session_id // ""),
           tours: ($res.num_turns // 0),
           duree_ms: ($res.duration_ms // 0),
           tokens: {entree: ($res.usage.input_tokens // 0),
                    cache_lu: ($res.usage.cache_read_input_tokens // 0),
                    cache_ecrit: ($res.usage.cache_creation_input_tokens // 0),
                    sortie: ($res.usage.output_tokens // 0),
                    reflexion: ($res.usage.output_tokens_details.thinking_tokens // 0)},
           # AVANT : modeles: (($res.modelUsage // {}) | keys),
           # (O50) Modeles de CE passage ; sans aucun chiffre par modele (faux claude
           # des tests), tous ceux declares, comme avant.
           modeles: (if ($delta | length) > 0 then ($delta | keys) else ($cum | keys) end),
           par_modele: $delta,
           cumul_session: {cout_usd: ($res.total_cost_usd // 0), par_modele: $cum},
           base: ([($res.modelUsage // {})[] | .costBasis? // empty] | unique | join(","))}
        end' "$src" 2>/dev/null)" || ligne=""
  fi
  [[ -n "$ligne" ]] || ligne="$(jq -cn --arg t "$tache" --arg r "$role" --arg ts "$(date -u +%FT%TZ)" \
    '{ts:$ts, tache:$t, role:$r, mesure:"absente", cout_usd:0}')"
  printf '%s\n' "$ligne" >>"$ORCH_DIR/journal/couts.jsonl"
  # (2026-09-28, O49) Modele servi compare au modele attendu pour le role
  # (matrice.json : auteur => modele_auteur ; conception et relecteur =>
  # modele_reviewer). Un ecart est note dans l'etat de la tache ; decide.sh en
  # fait un arret dur P17. Une mesure absente, ou sans modele declare, ne prouve
  # rien : pas d'ecart. Tests MD1, MD2.
  local attendu servis
  attendu="$(jq -r --arg r "$role" 'if $r == "auteur" then .revue.modele_auteur else .revue.modele_reviewer end // empty' \
    "$ROOT/orchestrator/matrice.json" 2>/dev/null || true)"
  servis="$(jq -r '(.modeles // []) | join(",")' <<<"$ligne" 2>/dev/null || true)"
  if [[ -n "$attendu" && -n "$servis" && ",$servis," != *",$attendu,"* ]]; then
    mkdir -p "$STATE_DIR"
    printf '%s\t%s\t%s\n' "$role" "$attendu" "$servis" >>"$STATE_DIR/$tache.modele-ecart"
    log "[ALERTE] $tache : modele servi au role $role = $servis, attendu $attendu"
  fi
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

# empreinte_tache <T-NNN>
# (2026-09-25, ADR 0003 R1) Empreinte de la declaration d'une tache (ligne du
# manifeste : perimetre, critere, controles). Un verdict de conception, ou une
# decision humaine de passer outre, ne vaut que pour CETTE declaration : la
# modifier fait relire la conception. Tests CO1, CO4.
# installation_incomplete — (2026-09-29, ADR 0004 D4) si "installation": true dans
# gates.json : rend « installation-incomplete » quand docs/agents/issue-tracker.md
# manque (exige par le skill code-review, ecrit une fois par projet par un humain
# avec setup-matt-pocock-skills), rien sinon ou si le controle n'est pas active.
# Lu sur la branche d'integration (ce que l'agent verra), sinon sur le disque.
# Tests IN1 a IN3.
installation_incomplete() {
  local g="$ROOT/orchestrator/gates.json" f="docs/agents/issue-tracker.md"
  { [[ -f "$g" ]] && jq -e '.installation == true' "$g" >/dev/null 2>&1; } || return 0
  git -C "$ROOT" cat-file -e "$INTEGRATION_BRANCH:$f" 2>/dev/null && return 0
  [[ -s "$ROOT/$f" ]] && return 0
  printf 'installation-incomplete\n'
}

# coutures_manquantes <T-NNN> — (2026-09-29, ADR 0004 D3) si "coutures": true dans
# gates.json : rend « ticket-absent » ou « section-absente », rien si tout va bien
# ou si le controle n'est pas active (decision de l'operateur : active par projet).
# Ticket = premier *.md du critere (meme regle que publisher.sh), lu sur la branche
# d'integration (ce que l'agent verra), sinon sur le disque. Section = titre
# « Coutures a tester » (casse et accent libres) suivi d'au moins une ligne non
# vide avant le titre suivant. Tests CT1 a CT4.
coutures_manquantes() {
  local g="$ROOT/orchestrator/gates.json" critere fichier contenu
  { [[ -f "$g" ]] && jq -e '.coutures == true' "$g" >/dev/null 2>&1; } || return 0
  critere="$(parse_task "$1" | sed -n 's/^critere=//p' | head -1)"
  fichier="$(grep -oE '[^ ]+\.md' <<<"$critere" | head -1 || true)"
  [[ -n "$fichier" ]] || { printf 'ticket-absent\n'; return 0; }
  contenu="$(git -C "$ROOT" show "$INTEGRATION_BRANCH:$fichier" 2>/dev/null || cat "$ROOT/$fichier" 2>/dev/null || true)"
  [[ -n "$contenu" ]] || { printf 'ticket-absent\n'; return 0; }
  awk '/^#+[ \t]/ { t = tolower($0); dans = (t ~ /^#+[ \t]*coutures (a|à|À) tester[ \t]*$/); next }
       dans && /[^ \t]/ { ok = 1 }
       END { exit ok ? 0 : 1 }' <<<"$contenu" || printf 'section-absente\n'
}

empreinte_tache() {
  parse_task "$1" | sha256sum | awk '{print substr($1, 1, 16)}'
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

# issue_de_tache <T-NNN> <dossier des escalades> — URL de la derniere issue GitHub
# ouverte pour cette tache (issues.tsv, ecrit par escalade.sh), vide sinon.
# (2026-09-27, O3 partie 2)
issue_de_tache() {
  local f="$2/issues.tsv"
  [[ -f "$f" ]] || return 0
  awk -F'\t' -v t="$1" '$1 == t { u = $2 } END { if (u != "") print u }' "$f"
}

# fermer_issue_escalade <T-NNN> <statut> <dossier des escalades> — ferme l'issue
# GitHub de l'escalade qui vient de se terminer (resolue, expiree, archivee, sans
# objet). Un echec est journalise sur stderr, jamais fatal : l'escalade est deja
# tranchee, l'issue restee ouverte se referme a la main. (2026-09-27, O3 partie 2 :
# l'issue n° 4 du projet d'essai etait restee ouverte.) Tests GI2, GI3.
fermer_issue_escalade() {
  local url
  url="$(issue_de_tache "$1" "$3")"
  [[ -n "$url" ]] || return 0
  gh issue close "$url" --comment "Escalade $2 le $(date -u +%FT%TZ) ; fermee par le socle d'orchestration." >/dev/null 2>&1 \
    || log "[NOTIF] fermeture de l'issue $url en echec (escalade $2 de $1)"
  return 0
}

# json_du_modele <sortie de claude> — (2026-09-27, O43, premier vrai ticket
# iziGSM) Objet JSON rendu par un relecteur dans le champ « result » : tel quel,
# sinon entre balises Markdown (```json … ```), sinon du premier « { » au
# dernier « } » d'un texte. Sur T-002, 3 relectures de conception sur 4 etaient
# lisibles a la main mais pas par le socle (JSON entre balises) : chacune a
# coute une decision humaine. Rien ne se lit (JSON invalide, guillemets non
# echappes) : code non nul, l'appelant reste en fail-safe. Tests CO7, CO8, RV3.
json_du_modele() {
  jq -ce '(.result // "") as $t
    | [ ($t | fromjson?),
        ($t | capture("```(?:json)?\\s*(?<j>[\\s\\S]*?)```") | .j | fromjson?),
        ($t | capture("(?<j>\\{[\\s\\S]*\\})") | .j | fromjson?) ]
    | map(objects) | if length > 0 then .[0] else error("illisible") end' "$1" 2>/dev/null
}

# --- Boucle de correction (2026-09-27, O48) ----------------------------------
# Doctrine de depart (rappel de l'operateur) : l'agent code, le relecteur verifie
# le diff ; s'il n'est pas d'accord, il RENVOIE l'agent corriger, et l'humain
# n'est alerte qu'ensuite. Jusqu'a la v3.57, un desaccord sur un diff aux
# controles verts partait directement en PR a relire (M3:desaccord-reviewer) :
# les quatre passages de T-004 (iziGSM, 27/09) ont ete relances a la main.
#
# correction_eligible <decision.json> <revue.json> — vrai si le desaccord du
# relecteur peut renvoyer l'agent corriger. Decisions de l'operateur : seul le
# « desaccord » declenche (une « reserve » part en PR avec ses remarques) ; un
# arret dur (raison P*, dont P16 preuve a fournir) ou un risque eleve va a
# l'humain directement, jamais en boucle. Test BC3.
correction_eligible() {
  local dec="$1" rev="$2"
  [[ "$(jq -r '.verdict // ""' "$rev" 2>/dev/null)" == desaccord ]] || return 1
  [[ "$(jq -r '.verdict // ""' "$dec" 2>/dev/null)" != PARK ]] || return 1
  jq -e '(.raisons // []) | map(select(startswith("P") or startswith("M3:risque-high"))) | length == 0' \
    "$dec" >/dev/null 2>&1
}

# consigne_correction <revue.json> <n> <max> — texte remis a l'agent : les rejets
# du relecteur, un par ligne, et son resume. Lu par run-task.sh. Test BC1.
consigne_correction() {
  jq -r --arg n "$2" --arg m "$3" '
    "Correction \($n)/\($m) demandee par le relecteur, en desaccord avec ton diff :\n"
    + ((.rejets // []) | map("- \(.code // "?") (\(.gravite // "?")) \(.fichier // "—"):\(.ligne // 0) — \(.constat // "")") | join("\n"))
    + "\nResume du relecteur : \(.resume // "aucun")\n"
    + "Corrige ces points dans ton perimetre. Un rejet que tu juges infonde : ne le contourne pas, explique-le dans ecarts de ton compte rendu."' \
    "$1"
}
