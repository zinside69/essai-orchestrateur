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
  # (2026-10-23, O80) La preparation tourne dans le sandbox des controles. Essai temoin du
  # 23/10 : a la reprise d'une tache, le worktree porte le travail commite de l'agent ; un
  # .npmrc de sa main (script-shell) faisait lancer son programme par le « npm run » de la
  # preparation, hors sandbox, avec les droits de l'operateur. Dans le sandbox, la vraie
  # preparation d'iziGSM rend les memes fichiers. ROOT y est transmis
  # (VARIABLES_PERMISES_AU_SANDBOX) ; le worktree est le seul dossier ouvert en ecriture.
  # Test SB32.
  # Sans sandbox utilisable (bwrap absent, comme sur le Mac, ou incapable de demarrer), la
  # preparation est refusee, jamais lancee hors sandbox (decision de l'utilisateur du 23/10),
  # et le message d'arret dit pourquoi : lancer_dans_le_sandbox ne le dirait que dans le
  # journal. Test SB33.
  if ! sandbox_disponible; then
    die "preparation du worktree refusee : bwrap (bubblewrap) introuvable ou incapable de demarrer, elle ne tourne jamais hors sandbox ($wt)"
  fi
  # AVANT :   ( cd "$wt" && ROOT="$ROOT" bash "$script" ) >"$journal" 2>&1 \
  # AVANT :     || die "preparation du worktree en echec : $wt (voir $journal)"
  lancer_dans_le_sandbox "$wt" bash "$script" >"$journal" 2>&1 \
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
  # (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
  # AVANT : exclude="$(git -C "$depot" rev-parse --git-path info/exclude)"
  exclude="$(git_du_worktree "$depot" rev-parse --git-path info/exclude)"
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
  # (2026-10-03, defaut 109, O70) Filtre precedent, sans l'etat de verification de
  # chaque demande (verifier_demandes_ecriture) :
  # AVANT :   jq -c '{raisons: ["P12:demande-ecriture(\(length))"],
  # AVANT :           detail: (map("- \(.fichier) : \(.besoin // "") — justification : \(.justification // "aucune")\n  Diff exact (ecrit tel quel si approuve) :\n\(.diff // "(aucun)")") | join("\n"))}' \
  # AVANT :     "$1"
  # Sous chaque demande, une ligne dit si son en-tete a ete recompte ou si elle ne
  # s'applique pas. Les textes passent par --arg : ils contiennent une apostrophe.
  jq -c \
    --arg texte_recompte "  En-tête de hunk faux, recompté par le harnais : contenu inchangé." \
    --arg texte_inapplicable "  NE S'APPLIQUE PAS : refuser, ou relancer en demandant un diff corrigé. Raison (git) : " \
    'def etat_de_verification:
       if .applicable == false then $texte_inapplicable + (.raison_git // "inconnue") + "\n"
       elif .en_tete_recompte == true then $texte_recompte + "\n"
       else "" end;
     {raisons: ["P12:demande-ecriture(\(length))"],
      detail: (map("- \(.fichier) : \(.besoin // "") — justification : \(.justification // "aucune")\n"
                   + etat_de_verification
                   + "  Diff exact (ecrit tel quel si approuve) :\n\(.diff // "(aucun)")") | join("\n"))}' \
    "$1"
}

# verifier_demandes_ecriture <worktree> <demandes.json>
# (2026-10-03, defaut 109, O70) Une demande d'ecriture se verifie a la reception :
# sur T-009 (iziGSM), un en-tete « +1,17 » pour 14 lignes n'a ete vu qu'a
# l'approbation (« ne s'applique pas telle quelle »). Une demande qui ne passe que
# par --recount (compteurs de l'en-tete faux, contenu juste) est marquee
# en_tete_recompte ; une demande qui ne passe pas du tout est marquee
# applicable: false, avec la raison donnee par git. Tests DA1, DA2.
verifier_demandes_ecriture() {
  local worktree="$1" demandes="$2"
  local nombre_de_demandes index fichier_du_diff raison_donnee_par_git
  nombre_de_demandes="$(jq length "$demandes")"
  fichier_du_diff="$(mktemp)"
  for (( index = 0; index < nombre_de_demandes; index++ )); do
    # Exactement un saut de ligne final : « jq -r » en ajoute un apres le diff, et
    # la ligne vide obtenue serait lue par --recount comme une ligne de contexte.
    jq -j --argjson i "$index" \
      '.[$i].diff | if endswith("\n") then . else . + "\n" end' "$demandes" >"$fichier_du_diff"
    # (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
    # AVANT : if git -C "$worktree" apply --check "$fichier_du_diff" >/dev/null 2>&1; then
    if git_du_worktree "$worktree" apply --check "$fichier_du_diff" >/dev/null 2>&1; then
      continue    # la demande s'applique telle quelle
    fi
    # (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
    # AVANT : if git -C "$worktree" apply --check --recount "$fichier_du_diff" >/dev/null 2>&1; then
    if git_du_worktree "$worktree" apply --check --recount "$fichier_du_diff" >/dev/null 2>&1; then
      jq --argjson i "$index" '.[$i].en_tete_recompte = true' "$demandes" >"$demandes.tmp"
    else
      # (2026-10-22, defaut 130, O80) via git_du_worktree (lib.sh), jamais par le .git de l'agent. Test SB26.
      # AVANT : raison_donnee_par_git="$(git -C "$worktree" apply --check --recount "$fichier_du_diff" 2>&1 | head -3 || true)"
      raison_donnee_par_git="$(git_du_worktree "$worktree" apply --check --recount "$fichier_du_diff" 2>&1 | head -3 || true)"
      jq --argjson i "$index" --arg raison "$raison_donnee_par_git" \
        '.[$i].applicable = false | .[$i].raison_git = $raison' "$demandes" >"$demandes.tmp"
    fi
    mv "$demandes.tmp" "$demandes"
  done
  rm -f "$fichier_du_diff"
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
  # AVANT :   jq -e '(.raisons // []) | map(select(startswith("P") or startswith("M3:risque-high"))) | length == 0' \
  # AVANT :     "$dec" >/dev/null 2>&1
  #   (2026-10-04, defaut 111, O61, decision de l'operateur, qui revient sur celle du
  #   27/09 pour P16) Une preuve a fournir (P16) n'est pas un arret : decide.sh ramene
  #   seulement AUTO_MERGE a PR_READY. Sur T-007 (iziGSM), desaccord + P16 a publie la
  #   PR avec 3 rejets majeurs, sans correction. Bloquent la boucle : toute autre raison
  #   P, et le risque eleve. La preuve reste a fournir apres la correction. Tests BC3, BC5.
  jq -e '(.raisons // [])
         | map(select(startswith("P16:") | not))
         | map(select(startswith("P") or startswith("M3:risque-high")))
         | length == 0' \
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

# ════ Plafond de depense par jour (2026-10-05, defaut 114, O65 partie 1) ════
# Decision de l'operateur : plafond GLOBAL (tous les projets declares), 60 $ par
# jour, jour de Paris. Reglage ORCH_PLAFOND_JOUR_USD dans ~/.orchestrateur.env
# (60 par defaut). La depense se lit dans journal/couts.jsonl de chaque projet,
# une ligne par appel payant (journaliser_cout). Avant, rien ne s'arretait sur
# le cout (O16). Tests PJ1 a PJ5.

# lire_reglage_orchestrateur <NOM> — valeur de la variable d'environnement si elle
# est posee, sinon celle de ~/.orchestrateur.env (meme lecture qu'escalade.sh).
# Rend 1 si la variable n'existe nulle part.
lire_reglage_orchestrateur() {
  local nom="$1" valeur ligne fichier_reglages
  valeur="${!nom:-}"
  if [[ -n "$valeur" ]]; then
    printf '%s' "$valeur"
    return 0
  fi
  fichier_reglages="${ORCHESTRATEUR_ENV:-$HOME/.orchestrateur.env}"
  [[ -r "$fichier_reglages" ]] || return 1
  ligne="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${nom}[[:space:]]*=" "$fichier_reglages" 2>/dev/null)" || return 1
  valeur="${ligne#*=}"
  valeur="${valeur#\"}"; valeur="${valeur%\"}"
  valeur="${valeur#\'}"; valeur="${valeur%\'}"
  valeur="$(printf '%s' "$valeur" | tr -d '[:space:]')"
  [[ -n "$valeur" ]] || return 1
  printf '%s' "$valeur"
}

# bornes_du_jour_de_paris — imprime « debut fin » du jour de Paris, en UTC au
# format des lignes de couts.jsonl (ex. « 2026-09-17T22:00:00Z 2026-09-18T22:00:00Z »).
# ORCH_AUJOURDHUI (AAAA-MM-JJ), pose par les tests, remplace la date du jour.
bornes_du_jour_de_paris() {
  python3 - "${ORCH_AUJOURDHUI:-}" <<'PY'
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

paris = ZoneInfo("Europe/Paris")
jour_demande = sys.argv[1]
if jour_demande:
    jour = date.fromisoformat(jour_demande)
else:
    jour = datetime.now(paris).date()
debut_a_paris = datetime.combine(jour, time(0, 0), paris)
fin_a_paris = datetime.combine(jour + timedelta(days=1), time(0, 0), paris)
format_des_journaux = "%Y-%m-%dT%H:%M:%SZ"
print(debut_a_paris.astimezone(timezone.utc).strftime(format_des_journaux),
      fin_a_paris.astimezone(timezone.utc).strftime(format_des_journaux))
PY
}

# journaux_de_couts_des_projets — un chemin par ligne : le journal des couts du
# projet courant, puis celui de chaque projet declare dans ORCH_PROJETS.
journaux_de_couts_des_projets() {
  local projets_declares projet
  local -a liste_des_projets=()
  printf '%s\n' "$ORCH_DIR/journal/couts.jsonl"
  projets_declares="$(lire_reglage_orchestrateur ORCH_PROJETS || true)"
  IFS=':' read -r -a liste_des_projets <<<"$projets_declares"
  for projet in "${liste_des_projets[@]}"; do
    if [[ -n "$projet" ]]; then
      printf '%s\n' "$projet/.orchestrator/journal/couts.jsonl"
    fi
  done
}

# depense_du_jour_usd — somme des couts du jour de Paris, sur tous les projets.
# Un projet declare deux fois (courant et dans ORCH_PROJETS) compte une fois :
# les journaux sont dedoublonnes par leur chemin reel.
depense_du_jour_usd() {
  local debut_du_jour fin_du_jour journal
  local -a journaux_existants=()
  read -r debut_du_jour fin_du_jour < <(bornes_du_jour_de_paris)
  while read -r journal; do
    journaux_existants+=("$journal")
  done < <(journaux_de_couts_des_projets | while read -r chemin; do
             if [[ -f "$chemin" ]]; then
               realpath "$chemin"
             fi
           done | sort -u)
  if (( ${#journaux_existants[@]} == 0 )); then
    printf '0\n'
    return 0
  fi
  jq -Rn --arg debut "$debut_du_jour" --arg fin "$fin_du_jour" '
    [ inputs | fromjson? | objects
      | select((.ts // "") >= $debut and (.ts // "") < $fin)
      | (.cout_usd // 0) ]
    | add // 0' "${journaux_existants[@]}"
}

# plafond_jour_usd — plafond du jour en dollars (60 par defaut).
plafond_jour_usd() {
  local plafond
  plafond="$(lire_reglage_orchestrateur ORCH_PLAFOND_JOUR_USD || true)"
  printf '%s\n' "${plafond:-60}"
}

# plafond_jour_atteint — vrai (code 0) si la depense du jour atteint le plafond.
plafond_jour_atteint() {
  awk -v depense="$(depense_du_jour_usd)" -v plafond="$(plafond_jour_usd)" \
    'BEGIN { if (depense >= plafond) exit 0; else exit 1 }'
}

# reste_du_jour_usd — ce qui reste a depenser aujourd'hui, deux decimales, jamais
# negatif : passe a claude par --max-budget-usd.
reste_du_jour_usd() {
  awk -v depense="$(depense_du_jour_usd)" -v plafond="$(plafond_jour_usd)" \
    'BEGIN { reste = plafond - depense; if (reste < 0) reste = 0; printf "%.2f\n", reste }'
}

# ════ Commande d'approbation d'un dossier (2026-10-11, defaut 117, O76) ════
# Un dossier non approuve dans Claude Code arrete l'agent en code 31. L'alerte
# disait « lancer une fois claude dans ce dossier » : le 08/10 (T-008), la commande
# a ete lancee dans la distribution WSL par defaut de ce poste (docker-desktop),
# qui n'est pas celle du socle, et l'agent n'a rien vu. L'alerte donne desormais
# la commande exacte, distribution nommee. Tests AP1 et AP3.

# nom_distribution_wsl — nom de la distribution WSL du socle, ou rien hors WSL.
# WSL_DISTRO_NAME n'existe que dans un terminal : un pipeline lance par l'ecouteur
# (service systemd) ne l'a pas, on lit alors le nom du systeme dans os-release.
# ORCH_PROC_VERSION et ORCH_OS_RELEASE ne servent qu'aux tests (AP3).
nom_distribution_wsl() {
  local fichier_version="${ORCH_PROC_VERSION:-/proc/version}"
  local fichier_systeme="${ORCH_OS_RELEASE:-/etc/os-release}"
  # Lance depuis un terminal WSL : la variable donne le nom exact
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    printf '%s' "$WSL_DISTRO_NAME"
    return 0
  fi
  # Sous WSL, le noyau se declare « microsoft » ; hors WSL (Mac), on ne rend rien
  if grep -qi microsoft "$fichier_version" 2>/dev/null; then
    sed -n 's/^NAME=//p' "$fichier_systeme" 2>/dev/null | tr -d '"' | head -1
  fi
}

# commande_approbation_dossier <dossier> — phrase a copier telle quelle qui
# approuve le dossier dans Claude Code : sous WSL, depuis PowerShell avec la
# distribution nommee ; ailleurs, depuis un terminal.
commande_approbation_dossier() {
  local dossier="$1" distribution
  distribution="$(nom_distribution_wsl)"
  if [[ -n "$distribution" ]]; then
    printf 'depuis PowerShell : wsl -d %s --cd %s -e bash -lc claude' "$distribution" "$dossier"
  else
    printf 'dans un terminal : cd %s && claude' "$dossier"
  fi
}

# ════ Quota accepte d'une session de l'agent a l'autre (2026-10-12, O68) ════
# Une acceptation de quota (O29) ne valait que pour le passage de l'agent vu par
# l'humain : chaque relance la redemandait (T-009 : 5 demandes, de 14f/1309l a
# 17f/1537l). repondre.sh note desormais la taille acceptee ; elle reste valable
# tant que le diff ne la depasse pas de plus de QUOTA_MARGE_POURCENT, fichiers et
# lignes compares separement. Le risque Q3 n'est pas concerne. Tests EC16, DQ4, DQ5.
QUOTA_MARGE_POURCENT=10

# quota_couvert_par_acceptation <fichier quota-accepte> <fichiers du diff> <lignes du diff>
# Rend 0 si le diff tient dans la taille acceptee plus la marge, 1 sinon (fichier
# absent ou illisible compris).
quota_couvert_par_acceptation() {
  local fichier_acceptation="$1" fichiers_du_diff="$2" lignes_du_diff="$3"
  local fichiers_acceptes lignes_acceptees
  [[ -f "$fichier_acceptation" ]] || return 1
  fichiers_acceptes="$(sed -n 's/^fichiers=//p' "$fichier_acceptation")"
  lignes_acceptees="$(sed -n 's/^lignes=//p' "$fichier_acceptation")"
  # Une valeur absente ou non numerique ne couvre rien
  [[ "$fichiers_acceptes" =~ ^[0-9]+$ ]] || return 1
  [[ "$lignes_acceptees" =~ ^[0-9]+$ ]] || return 1
  # Comparaison en centiemes pour rester en entiers : diff x 100 <= accepte x (100 + marge)
  local plafond_fichiers_centiemes=$(( fichiers_acceptes * (100 + QUOTA_MARGE_POURCENT) ))
  local plafond_lignes_centiemes=$(( lignes_acceptees * (100 + QUOTA_MARGE_POURCENT) ))
  local fichiers_dans_la_marge=0 lignes_dans_la_marge=0
  (( fichiers_du_diff * 100 <= plafond_fichiers_centiemes )) && fichiers_dans_la_marge=1
  (( lignes_du_diff * 100 <= plafond_lignes_centiemes )) && lignes_dans_la_marge=1
  (( fichiers_dans_la_marge == 1 && lignes_dans_la_marge == 1 ))
}

# (2026-10-16, defaut 124, O80) Reglages du sandbox de Claude Code pour l'agent.
# Mesure du 15/10 : l'agent tourne avec les droits de l'operateur ; un test qu'il
# ecrit puis lance (npx vitest, npm test) peut lire les secrets de ~ et de /mnt/c
# et les envoyer par fetch() de Node. Aucun hook ne le ferme : les hooks ne voient
# que la commande, pas ce que fait le programme lance.
# Essai du 16/10 (Haiku, Claude Code 2.1.281, 6 passages, 1,37 $) : sans sandbox,
# node lisait ~/temoin-o80.txt et listait /mnt/c/Users/Said, fetch() sortait (200) ;
# avec ce bloc : EACCES, /mnt/c masque, fetch en echec (EAI_AGAIN), node demarre.
# Interdire tout ~ puis rouvrir ~/.nvm ne marche pas (l'interdiction l'emporte,
# node devient introuvable) : d'ou une liste de chemins interdits. Regle qui en
# decoule : tout secret de l'operateur se range dans ~/.config ou ~/.orchestrateur.env*.
# Le sandbox couvre Bash et ses processus enfants ; l'outil Read passe hors sandbox,
# d'ou les memes chemins en permissions.deny. Tests SB1 a SB3.
reglages_sandbox_agent() {
  jq -nc '{
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      autoAllowBashIfSandboxed: false,
      filesystem: {
        denyRead: [
          "~/.orchestrateur.env*",
          "~/.ssh",
          "~/.config",
          "~/.claude",
          "~/.claude.json",
          "~/.bash_history",
          "~/consignes",
          "~/bac-a-sable/sauvegardes",
          "~/bac-a-sable/archives",
          "/mnt/c"
        ]
      },
      network: { allowedDomains: [] }
    },
    permissions: {
      deny: [
        "Read(~/.orchestrateur.env*)",
        "Read(~/.ssh/**)",
        "Read(~/.config/**)",
        "Read(~/.claude/**)",
        "Read(~/.claude.json)",
        "Read(~/.bash_history)",
        "Read(//mnt/c/**)"
      ]
    }
  }'
}
# Ce que veut dire chaque reglage du bloc ci-dessus :
#   failIfUnavailable          sandbox impossible a demarrer => l'agent ne demarre pas
#   allowUnsandboxedCommands   false : l'agent ne peut pas relancer une commande hors sandbox
#   autoAllowBashIfSandboxed   false : la liste d'autorisations du projet continue de decider
#                              (sinon toute commande Bash sandboxee passerait d'office)
#   allowedDomains             vide : aucun reseau pour les commandes ; claude lui-meme,
#                              qui parle a l'API, tourne hors sandbox

# (2026-10-16, defaut 125, O80) Caches de vite ouverts en ecriture a l'agent.
# Passage reel T-009 du 16/10 : le node_modules d'un worktree est un lien vers celui
# du depot principal, hors de la zone d'ecriture du sandbox ; vitest s'arretait avant
# tout test (EROFS sur node_modules/.vite-temp). Essai temoin : rouge EROFS, vert
# « 6 passed » avec ces deux dossiers seulement. Le reste du node_modules partage
# reste en lecture seule : un agent ne peut pas modifier une dependance que les
# controles, lances hors sandbox, utiliseraient ensuite. Tests SB4 et SB5.
# ouvrir_caches_partages_agent <reglages json> <worktree>
ouvrir_caches_partages_agent() {
  local reglages="$1" worktree="$2" node_modules_partage
  # node_modules propre au worktree, ou absent : deja inscriptible, ou rien a ouvrir
  if [[ ! -L "$worktree/node_modules" ]]; then
    printf '%s' "$reglages"
    return 0
  fi
  # (2026-10-18, defaut 127) Le chemin ne se lit plus dans le worktree, que l'agent tient :
  # seul le node_modules du depot principal est reconnu (node_modules_partage_verifie).
  # AVANT :   node_modules_partage="$(readlink -f "$worktree/node_modules")"
  # AVANT :   # Les dossiers doivent exister pour que le sandbox puisse les monter en ecriture
  # AVANT :   mkdir -p "$node_modules_partage/.vite-temp" "$node_modules_partage/.vite"
  if ! node_modules_partage="$(node_modules_partage_verifie "$worktree")"; then
    printf '%s' "$reglages"
    return 0
  fi
  jq -c --arg fichiers_temporaires "$node_modules_partage/.vite-temp" \
        --arg cache "$node_modules_partage/.vite" \
    '.sandbox.filesystem.allowWrite = [$fichiers_temporaires, $cache]' <<<"$reglages"
}

# (2026-10-18, defaut 127, O80) node_modules partage, verifie du cote du harnais. Revue de
# securite de f7f293b : le chemin des caches se lisait dans le worktree, que l'agent tient.
# Un node_modules (ou un .vite) remplace par un lien vers ~ aurait ouvert ~ en ecriture dans
# le sandbox (~/.bashrc, execute ensuite hors sandbox). Reconnu seulement si :
#   - le node_modules du worktree est un lien ;
#   - le node_modules du depot principal (ROOT) est un vrai dossier ;
#   - le lien du worktree mene exactement a lui ;
#   - ses caches .vite-temp et .vite sont de vrais dossiers (crees s'ils manquent).
# Rend le chemin du node_modules du depot principal, ou echoue (rien n'est ouvert ni vide).
# Tests SB4, SB9, SB10, SB11.
# (2026-10-22, defaut 129) Vrai si le depot principal (ROOT) a un node_modules qui est un
# vrai dossier, et non un lien vers un autre dossier.
depot_principal_a_un_vrai_node_modules() {
  [[ -d "$ROOT/node_modules" && ! -L "$ROOT/node_modules" ]]
}

# node_modules_partage_verifie <worktree>
node_modules_partage_verifie() {
  local worktree="$1" attendu obtenu cache
  # Pas de lien : node_modules propre au worktree (deja inscriptible) ou absent
  [[ -L "$worktree/node_modules" ]] || return 1
  # Le depot principal doit avoir un vrai node_modules
  # (2026-10-22, defaut 129) Condition nommee, partagee avec vider_caches_partages_agent.
  # AVANT :   if [[ ! -d "$ROOT/node_modules" || -L "$ROOT/node_modules" ]]; then
  if ! depot_principal_a_un_vrai_node_modules; then
    return 1
  fi
  attendu="$(readlink -f "$ROOT/node_modules")"
  obtenu="$(readlink -f "$worktree/node_modules")"
  if [[ "$obtenu" != "$attendu" ]]; then
    printf '[ATTENTION] node_modules du worktree %s : il ne mene pas au depot principal, caches de vite non ouverts\n' "$worktree" >&2
    return 1
  fi
  for cache in "$attendu/.vite-temp" "$attendu/.vite"; do
    # Un cache remplace par un lien designerait un autre dossier : refus
    if [[ -L "$cache" ]]; then
      printf '[ATTENTION] %s est un lien : caches de vite non ouverts\n' "$cache" >&2
      return 1
    fi
    mkdir -p "$cache"
  done
  printf '%s\n' "$attendu"
}

# (2026-10-18, defaut 126, O80) Les caches de vite partages sont vides apres la session
# de l'agent (revue de securite du commit 3451e62) : l'agent y ecrit, et une commande
# lancee hors sandbox a la racine du projet (npm test de l'operateur) chargerait un
# cache qu'il aurait prepare. Seul le contenu des deux caches part, pas les dependances.
# Test SB9.
# vider_caches_partages_agent <worktree>
# (2026-10-22, defaut 129) Le worktree (argument) n'est plus consulte : le vidage se faisait
# apres le code de l'agent, qui pouvait remplacer le lien node_modules par un vrai dossier
# (ou le supprimer) et ainsi empecher le vidage. Seul compte le depot principal (ROOT) ;
# un cache qui est lui-meme un lien n'est jamais vide (il designerait un autre dossier).
# L'argument reste pour les quatre appelants (run-task, gate, test-rouge, mutation). Test SB17.
# AVANT : vider_caches_partages_agent() {
# AVANT :   local worktree="$1" node_modules_partage cache
vider_caches_partages_agent() {
  local node_modules_du_depot="$ROOT/node_modules" cache
  # (2026-10-18, defaut 127) Seul le node_modules du depot principal est vide : un lien
  # pose par l'agent ne designe jamais ce qui est efface.
  # AVANT :   # node_modules propre au worktree, ou absent : rien de partage a vider
  # AVANT :   [[ -L "$worktree/node_modules" ]] || return 0
  # AVANT :   node_modules_partage="$(readlink -f "$worktree/node_modules")"
  # AVANT :   node_modules_partage="$(node_modules_partage_verifie "$worktree")" || return 0
  # Le depot principal doit avoir un vrai node_modules
  if ! depot_principal_a_un_vrai_node_modules; then
    return 0
  fi
  # AVANT :   for cache in "$node_modules_partage/.vite-temp" "$node_modules_partage/.vite"; do
  for cache in "$node_modules_du_depot/.vite-temp" "$node_modules_du_depot/.vite"; do
    # Un cache remplace par un lien n'est pas vide : il designerait un autre dossier
    if [[ -L "$cache" ]]; then
      printf '[ATTENTION] %s est un lien : non vide\n' "$cache" >&2
      continue
    fi
    [[ -d "$cache" ]] || continue
    # AVANT :     find "$cache" -mindepth 1 -delete
    find "$cache" -xdev -mindepth 1 -delete
  done
}

# (2026-10-18, defaut 126, O80) Chemins secrets a masquer dans le sandbox des controles,
# tires de la liste denyRead de reglages_sandbox_agent : une seule liste pour l'agent et
# pour les controles. « ~ » devient le dossier personnel ; un motif (« .orchestrateur.env* »)
# rend chaque fichier qui existe. Un chemin absent n'est pas rendu : rien a masquer.
chemins_secrets_a_masquer() {
  local motif chemin
  while IFS= read -r motif; do
    motif="${motif/#\~/$HOME}"
    for chemin in $motif; do
      [[ -e "$chemin" ]] && printf '%s\n' "$chemin"
    done
  done < <(reglages_sandbox_agent | jq -r '.sandbox.filesystem.denyRead[]')
}

# (2026-10-18, defaut 128, O80) Le sandbox des controles peut-il demarrer ? A demander
# AVANT une mesure dont l'echec est le bon resultat (test-rouge.sh, mutation.sh) : sans
# bubblewrap, lancer_dans_le_sandbox refuse et rend 125, un echec qui se lirait sinon
# comme « tests vus rouges » ou « mutation vue rouge ». Tests SB14 et SB16.
# Present ne suffit pas (code-review du defaut 128) : bwrap installe mais incapable de
# demarrer (espaces de noms utilisateur refuses, AppArmor) sort en 1. D'ou un vrai essai,
# avec la meme isolation reseau que les controles.
# (2026-10-22, defaut 129) L'essai emploie les options fixes du vrai lancement : un bwrap
# trop ancien, ou des espaces de noms de processus refuses, faisaient echouer le vrai
# lancement (rc 1, lu « rouge ») alors que l'essai simple passait. Test SB21.
sandbox_disponible() {
  command -v bwrap >/dev/null 2>&1 || return 1
  # AVANT :   bwrap --ro-bind / / --unshare-net true >/dev/null 2>&1
  bwrap "${OPTIONS_FIXES_DU_SANDBOX[@]}" /bin/sh -c : >/dev/null 2>&1
}

# (2026-10-22, defaut 129, O80) Options du sandbox des controles qui ne dependent pas de la
# commande lancee ; une seule liste, pour l'essai de disponibilite et le vrai lancement :
#   --ro-bind / /, --dev, --proc, --tmpfs /tmp  tout en lecture seule, /tmp prive
#   --unshare-net                               aucun reseau
#   --die-with-parent                           le sandbox meurt si le harnais meurt
#   --unshare-pid                               ses processus meurent avec lui (un processus
#                                               detache survivait et reecrivait les caches
#                                               apres leur vidage ; test SB18) et /proc ne
#                                               montre plus ceux de l'operateur
#   --new-session                               pas d'injection de touches dans le terminal
#                                               qui a lance le controle (TIOCSTI ; non teste,
#                                               faute de terminal reel dans la batterie)
#   --clearenv                                  environnement vide ; les seules variables
#                                               permises sont reposees ensuite (test SB19)
OPTIONS_FIXES_DU_SANDBOX=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-net --die-with-parent
                          --unshare-pid --new-session --clearenv)

# (2026-10-22, defaut 129, O80) Variables d'environnement transmises au sandbox des
# controles ; toutes les autres sont effacees (le code de l'agent voyait GH_TOKEN, les cles
# d'API exportees...). Releve du 22/10 sur les trois bacs a sable : les controles lisent
# PATH et HOME (node, npx), ROOT et ORCH_E2E_BASE (controle e2e), ORCH_RAPPORTS (rapports).
# Ajouter une variable ici = la montrer au code de l'agent. Test SB19.
VARIABLES_PERMISES_AU_SANDBOX=(PATH HOME USER LOGNAME LANG LC_ALL LC_NUMERIC TERM TZ ROOT ORCH_RAPPORTS ORCH_E2E_BASE)

# (2026-10-18, defaut 126, O80) Lance une commande dans bubblewrap, avec les memes
# interdits que l'agent. Essai temoin du 18/10 : gate.sh lancait par « bash -c », hors
# sandbox, les tests ecrits par l'agent ; un test piege lisait ~/temoin-o80.txt et
# sortait sur le reseau (fetch 200). Dans ce sandbox : EACCES, EAI_AGAIN, et tsc, vitest
# et toute la suite d'iziGSM rendent le meme resultat qu'hors sandbox. Tests SB6 a SB8.
# lancer_dans_le_sandbox <worktree> <commande> [arguments...]
lancer_dans_le_sandbox() {
  local worktree="$1"; shift
  local options=() chemin node_modules_partage cache
  # Sans bubblewrap, rien ne part hors sandbox : la commande est refusee (controle rouge)
  # (2026-10-22, defaut 128) Un seul test de disponibilite, qui essaie vraiment de demarrer.
  # AVANT :   if ! command -v bwrap >/dev/null 2>&1; then
  # AVANT :     printf '[ERREUR] bwrap (bubblewrap) introuvable : commande refusee, elle ne tourne jamais hors sandbox\n' >&2
  if ! sandbox_disponible; then
    printf '[ERREUR] bwrap (bubblewrap) introuvable ou incapable de demarrer : commande refusee, elle ne tourne jamais hors sandbox\n' >&2
    return 125
  fi
  # Tout le disque en lecture seule, /tmp prive, aucun reseau
  # (2026-10-22, defaut 129) Options fixes dans OPTIONS_FIXES_DU_SANDBOX (processus propres,
  # nouvelle session, environnement vide en plus), partagees avec sandbox_disponible.
  # AVANT :   options+=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --unshare-net --die-with-parent)
  options+=("${OPTIONS_FIXES_DU_SANDBOX[@]}")
  # (2026-10-22, defaut 129) Les seules variables permises qui ont une valeur ici sont
  # reposees dans l'environnement vide. « ${!variable} » lit la variable dont le nom est dans
  # « variable » ; « ${!variable+existe} » vaut « existe » si cette variable est definie,
  # meme vide, et rien sinon. Test SB19.
  local variable
  for variable in "${VARIABLES_PERMISES_AU_SANDBOX[@]}"; do
    if [[ -n "${!variable+existe}" ]]; then
      options+=(--setenv "$variable" "${!variable}")
    fi
  done
  # Secrets masques AVANT les montages en ecriture : bubblewrap applique les options dans
  # l'ordre, et le masque de /mnt/c cacherait sinon un worktree range sous /mnt/c.
  # Un dossier est remplace par un dossier vide, un fichier par un fichier vide.
  while IFS= read -r chemin; do
    if [[ -d "$chemin" ]]; then
      options+=(--tmpfs "$chemin")
    else
      options+=(--ro-bind /dev/null "$chemin")
    fi
  done < <(chemins_secrets_a_masquer)
  # En ecriture : le worktree, les rapports des controles, les caches de vite partages
  options+=(--bind "$worktree" "$worktree")
  if [[ -n "${ORCH_RAPPORTS:-}" && -d "$ORCH_RAPPORTS" ]]; then
    options+=(--bind "$ORCH_RAPPORTS" "$ORCH_RAPPORTS")
  fi
  # (2026-10-18, defaut 127) Caches pris du depot principal, jamais du lien de l'agent.
  # AVANT :   if [[ -L "$worktree/node_modules" ]]; then
  # AVANT :     node_modules_partage="$(readlink -f "$worktree/node_modules")"
  # AVANT :     for cache in "$node_modules_partage/.vite-temp" "$node_modules_partage/.vite"; do
  # AVANT :       mkdir -p "$cache"
  # AVANT :       options+=(--bind "$cache" "$cache")
  # AVANT :     done
  # AVANT :   fi
  if node_modules_partage="$(node_modules_partage_verifie "$worktree")"; then
    for cache in "$node_modules_partage/.vite-temp" "$node_modules_partage/.vite"; do
      options+=(--bind "$cache" "$cache")
    done
  fi
  bwrap "${options[@]}" --chdir "$worktree" "$@"
}

# (2026-10-22, defaut 130, O80) Dossier git d'un worktree, lu dans le depot principal (ROOT),
# jamais dans le worktree. Le depot principal tient une fiche par worktree
# (.git/worktrees/<nom>/gitdir) qui contient le chemin du fichier .git du worktree ; on cherche
# celle qui le designe. Rend le dossier de cette fiche, ou echoue si le worktree est inconnu du
# depot principal. Chemins absolus seulement (worktree.useRelativePaths, git 2.48, non pris en
# charge : ouvert O80). Test SB22.
dossier_git_du_worktree() {
  local worktree dossier_commun fiche
  worktree="$(realpath -e "$1")" || return 1
  dossier_commun="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)" || return 1
  for fiche in "$dossier_commun"/worktrees/*/gitdir; do
    [[ -f "$fiche" ]] || continue
    if [[ "$(cat "$fiche")" == "$worktree/.git" ]]; then
      dirname "$fiche"
      return 0
    fi
  done
  return 1
}

# (2026-10-22, defaut 130, O80) Le fichier .git du worktree designe-t-il toujours le dossier
# attendu ? C'est un fichier du worktree, donc de l'agent : un lien, un dossier, ou un fichier
# qui pointe ailleurs est un detournement.
# fichier_git_intact <worktree> <dossier git attendu> ; rend 0 si intact. Tests SB22 a SB25.
fichier_git_intact() {
  local worktree="$1" dossier_git_attendu="$2" premiere_ligne cible
  [[ -f "$worktree/.git" && ! -L "$worktree/.git" ]] || return 1
  IFS= read -r premiere_ligne <"$worktree/.git" || return 1
  [[ "$premiere_ligne" == "gitdir: "* ]] || return 1
  cible="${premiere_ligne#gitdir: }"
  [[ "$(realpath -e "$cible" 2>/dev/null)" == "$(realpath -e "$dossier_git_attendu")" ]]
}

# (2026-10-22, defaut 131, O80) Le worktree contient-il un depot imbrique (un .git, fichier ou
# dossier, sous sa racine) ? Un tel depot a sa propre config, donc celle de l'agent : un git du
# socle sur le worktree y lance un git enfant (« cd src/x; git status --porcelain=2 ») qui la
# lit, et un filtre « clean » qu'elle declare tourne hors sandbox (essai temoin du 22/10,
# git 2.53 : status, diff et add -A). Les liens ne sont pas suivis (find sans -L), comme git.
# depot_imbrique_dans <worktree> : nomme le premier trouve et rend 0 ; rend 1 s'il n'y en a
# aucun. Une recherche incomplete (dossier illisible) ne prouve pas qu'il n'y en a aucun :
# elle rend 0 aussi, en le disant (code-review du 22/10). Tests SB30, SB31.
depot_imbrique_dans() {
  local worktree="$1" premier_depot_imbrique recherche_complete=true
  # -iname : sur un systeme de fichiers insensible a la casse (APFS du Mac), git ouvre .GIT
  # comme .git (code-review du 22/10). Test SB30.
  premier_depot_imbrique="$(find "$worktree" -mindepth 2 -iname .git -print -quit 2>/dev/null)" \
    || recherche_complete=false
  if [[ -n "$premier_depot_imbrique" ]]; then
    printf '%s\n' "$premier_depot_imbrique"
    return 0
  fi
  if [[ "$recherche_complete" == false ]]; then
    printf 'impossible a exclure : dossier illisible sous %s\n' "$worktree"
    return 0
  fi
  return 1
}

# (2026-10-22, defaut 130, O80) git du socle sur le worktree d'un agent. Essai temoin du 22/10
# (git 2.53) : un .git reecrit vers un faux depot, ou remplace par un dossier, dont
# core.fsmonitor nomme un programme de l'agent ; un simple « git -C worktree status » du socle
# lancait ce programme hors sandbox, avec les droits de l'operateur. Ici le dossier git vient
# du depot principal, un .git modifie est refuse, et aucun programme nomme par une config n'est
# lance (hooks, fsmonitor) : un core.hooksPath relatif (.githooks) se lisait dans le worktree de
# l'agent. Les hooks du projet ne tournent donc pas pour les commandes du socle sur un
# worktree ; le push de publisher.sh, lance depuis ROOT, garde ceux de l'operateur.
# Sert aussi le depot principal lui-meme (decide.sh et review.sh le recoivent sans worktree),
# toujours sans hook ni fsmonitor. Seul chemin du socle vers git sur un worktree. Tests SB22, SB26.
# git_du_worktree <worktree ou ROOT> <arguments de git...>
git_du_worktree() {
  local worktree="$1"; shift
  local dossier_git
  # Le depot principal lui-meme (decide.sh et review.sh le recoivent sans worktree) : son .git
  # appartient a l'operateur, pas a un agent ; meme refus des hooks et du fsmonitor
  if [[ "$(realpath -e "$worktree" 2>/dev/null)" == "$(realpath -e "$ROOT")" ]]; then
    git -C "$ROOT" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
    return
  fi
  if ! dossier_git="$(dossier_git_du_worktree "$worktree")"; then
    printf '[ERREUR] %s : worktree inconnu du depot principal (%s), git refuse\n' "$worktree" "$ROOT" >&2
    return 1
  fi
  if ! fichier_git_intact "$worktree" "$dossier_git"; then
    printf '[ERREUR] %s/.git modifie (attendu : gitdir: %s) : detournement possible par l agent, git refuse\n' \
      "$worktree" "$dossier_git" >&2
    return 1
  fi
  # (2026-10-22, defaut 131) Un depot imbrique ferait lire sa config, celle de l'agent, par un
  # git enfant lance hors sandbox : refuse, comme un .git modifie. Tests SB30, SB31.
  local depot_imbrique
  if depot_imbrique="$(depot_imbrique_dans "$worktree")"; then
    printf '[ERREUR] %s : depot imbrique (%s), sa config est celle de l agent, git refuse\n' \
      "$worktree" "$depot_imbrique" >&2
    return 1
  fi
  git -C "$worktree" --git-dir="$dossier_git" --work-tree="$worktree" \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# (2026-10-22, defaut 130, O80) Garde d'entree des scripts qui lancent git sur le worktree d'un
# agent (gate.sh, decide.sh, review.sh, publisher.sh, repondre.sh, mutation.sh).
# exiger_un_worktree_intact <worktree> <ce qui allait se faire>
# Rend la main si le .git du worktree est intact, ou si le « worktree » est le depot principal
# lui-meme. Sinon, dit ce qui est refuse et arrete le script (code 1), avant toute commande git
# et tout controle. Pourquoi a l'entree : un refus de git_du_worktree lu par « $( ) » ou par
# « < <( ) » restait muet — liste vide, diff lu comme vide — et publisher.sh aurait publie sans
# voir de fichier fautif. run-task.sh ne l'emploie pas : apres l'agent, il sort en 36 pour que
# pipeline.sh escalade (P13:git-detourne). Tests SB24, SB25, SB27 a SB29.
exiger_un_worktree_intact() {
  local worktree="$1" ce_qui_allait_se_faire="$2"
  # git_du_worktree dit sur stderr la cause exacte (.git modifie, ou worktree inconnu du depot
  # principal) : elle reste visible, juste avant le refus qui nomme ce qui ne se fera pas
  if git_du_worktree "$worktree" rev-parse --git-dir >/dev/null; then
    return 0
  fi
  # (2026-10-22, defaut 131) Troisieme cause, depuis le defaut 131 : un depot imbrique dans le
  # worktree, ou un dossier illisible qui empeche de l'exclure (git_du_worktree). Le debut du
  # message est garde (SB25, SB27 a SB29 le cherchent). Tests SB30, SB31.
  # AVANT :   die "worktree au .git detourne ou inconnu du depot principal ($worktree) : $ce_qui_allait_se_faire refuse"
  die "worktree au .git detourne, inconnu du depot principal ou contenant un depot imbrique ($worktree) : $ce_qui_allait_se_faire refuse"
}
