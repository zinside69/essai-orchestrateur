#!/usr/bin/env bash
# Lance une tâche de todo.md : snapshot -> worktree isolé -> Claude headless -> porte -> commit.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
# (2026-09-24, ADR 0002) Doctrine d'ecriture : fichiers critiques et perimetre.
# shellcheck disable=SC1091
source "$(dirname "$0")/critiques.sh"

TASK_ID="${1:?usage: run-task.sh T-NNN}"
MAX_TURNS="${MAX_TURNS:-60}"
# AVANT : MODEL="${MODEL:-sonnet}"
#   (2026-09-28, O49) Une seule source : matrice.json (identifiant exact).
MODEL="${MODEL:-$(jq -r '.revue.modele_auteur' "$ROOT/orchestrator/matrice.json")}"

require git jq claude

# (2026-09-24, O1) Le depot doit etre approuve dans Claude Code (« trust dialog »)
# AVANT tout : sans cette approbation, Claude Code ignore les autorisations du
# projet — l'agent tourne sans pouvoir lancer les tests, et seule une ligne du
# journal le disait (bac a sable, 21/09). L'approbation vaut pour un dossier et ses
# descendants ; les worktrees d'agent (hors du depot) heritent de celle du depot
# principal. On cherche donc ROOT ou l'un de ses parents, chemin logique et chemin
# physique (macOS : /var -> /private/var). Arret en 31 avant tout worktree ou
# appel paye ; pipeline.sh en fait une P10 qui dit quoi faire. Tests AP1, AP2.
depot_approuve() {
  local conf="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" c
  [[ -f "$conf" ]] || return 1
  for c in "$ROOT" "$(cd "$ROOT" && pwd -P)"; do
    while :; do
      jq -e --arg p "$c" '.projects[$p].hasTrustDialogAccepted == true' "$conf" >/dev/null 2>&1 && return 0
      [[ "$c" == "/" || -z "$c" ]] && break
      c="$(dirname "$c")"
    done
  done
  return 1
}
if ! depot_approuve; then
  printf '[ERREUR] depot non approuve dans Claude Code : %s — lancer une fois « claude » dans ce dossier et accepter la confiance, puis relancer la tache\n' "$ROOT" >&2
  exit 31
fi

mapfile -t T < <(parse_task "$TASK_ID")
[[ ${#T[@]} -gt 0 ]] || die "tâche $TASK_ID absente de todo.md"

declare -A TACHE
for kv in "${T[@]}"; do TACHE["${kv%%=*}"]="${kv#*=}"; done

# (2026-09-27, O45, decision de l'operateur) Plafond de tours propre a une
# tache : cle « max_tours=N » de sa fiche d'etat, posee par un humain (ticket
# dense) ; sinon MAX_TURNS (60 par defaut). Test MT3.
MAX_TOURS_FICHE="$(sed -n 's/^max_tours=//p' "$ORCH_DIR/etat/taches/$TASK_ID.env" 2>/dev/null | head -1 || true)"
[[ "$MAX_TOURS_FICHE" =~ ^[0-9]+$ ]] && MAX_TURNS="$MAX_TOURS_FICHE"

WT="$WORKTREE_ROOT/$TASK_ID"
BRANCH="$AGENT_BRANCH_PREFIX/$TASK_ID"
TAG="pre-task/$TASK_ID"
LOG="$LOG_DIR/run-$TASK_ID.jsonl"
STATE="$STATE_DIR/$TASK_ID.state"

# --- 0. Reprise possible ? ------------------------------------------------
if [[ -f "$STATE" ]] && grep -q '^session_id=' "$STATE"; then
  SESSION_ID="$(sed -n 's/^session_id=//p' "$STATE")"
  log "Reprise de la session $SESSION_ID"
  REPRISE=(--resume "$SESSION_ID")
else
  REPRISE=()
fi

# --- 1. Snapshot : rollback en une commande -------------------------------
cd "$ROOT"
git rev-parse --verify "$INTEGRATION_BRANCH" >/dev/null 2>&1 || {
  git switch -c "$INTEGRATION_BRANCH" main && git switch -
}
# (2026-09-22, T-002 sur GitHub, defaut 11) Les PR sont fusionnees SUR GitHub :
# sans fetch, l'integration locale restait a son ancien etat — T-002 est partie
# sans le code de T-001, dont elle depend, et son agent s'est arrete. Mise a
# jour en avance rapide seulement : si l'integration locale a diverge, git
# refuse, la tache s'arrete (P10) et un humain regarde. Test Y6.
if git remote get-url origin >/dev/null 2>&1 \
   && git ls-remote --exit-code --heads origin "$INTEGRATION_BRANCH" >/dev/null 2>&1; then
  # AVANT :   git fetch -q origin "$INTEGRATION_BRANCH:$INTEGRATION_BRANCH" \
  #   (2026-09-23, defaut 50) deux taches parties ensemble faisaient ce fetch dans
  #   la meme seconde (T-003 et T-005) : FETCH_HEAD et les references sont
  #   partages. Sous le verrou du depot, un seul a la fois. Test P7.
  sous_verrou_depot git fetch -q origin "$INTEGRATION_BRANCH:$INTEGRATION_BRANCH" \
    || die "integration locale divergente d'origin/$INTEGRATION_BRANCH : mise a jour refusee"
  log "Integration a jour depuis origin : $(git rev-parse --short "$INTEGRATION_BRANCH")"
fi
git tag -f "$TAG" "$INTEGRATION_BRANCH" >/dev/null
log "Snapshot posé : $TAG -> rollback = git reset --hard $TAG"

# --- 2. Worktree isolé ----------------------------------------------------
if git worktree list --porcelain | grep -q "$WT"; then
  git worktree remove "$WT" --force || true
fi
# AVANT : git worktree add -b "$BRANCH" "$WT" "$INTEGRATION_BRANCH"
#   (2026-09-22, essai de publication, defaut 4) « -b » cree la branche AVANT
#   d'echouer sur le dossier : la branche restait, et toute relance FAILED ->
#   RUNNING echouait ensuite (« a branch named ... already exists »). Une
#   branche existante est reprise telle quelle, sans rien effacer : le travail
#   d'un essai precedent y reste, comme la session reprise par --resume. Test P5.
if git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
  # (2026-09-22, defaut 4 bis) Une branche SANS commit propre (essai arrete
  # avant tout travail) est realignee sur l'integration a jour : reprise telle
  # quelle, elle figeait l'ancienne base. Rien n'est perdu, elle n'a rien en
  # propre. Une branche AVEC du travail est reprise sans y toucher. Test Y6.
  if [[ "$(git rev-list --count "$INTEGRATION_BRANCH..$BRANCH")" == 0 ]]; then
    git branch -f "$BRANCH" "$INTEGRATION_BRANCH"
    log "Branche $BRANCH vide realignee sur $INTEGRATION_BRANCH"
  fi
  git worktree add "$WT" "$BRANCH"
  log "Branche $BRANCH existante reprise (essai precedent)"
else
  git worktree add -b "$BRANCH" "$WT" "$INTEGRATION_BRANCH"
fi
log "Worktree créé : $WT (branche $BRANCH)"
preparer_worktree "$WT"

# --- 3. Neutralisation push (couche 4) -----------------------------------
cd "$WT"
if git remote get-url origin >/dev/null 2>&1; then
  # AVANT : git config remote.origin.pushurl "no-push://interdit"
  #   (2026-09-22, essai de publication GitHub, defaut 5) Un worktree partage le
  #   .git/config du depot principal : cette ligne neutralisait le push du DEPOT
  #   ENTIER, harnais compris — publisher.sh ne pouvait plus jamais pousser.
  #   Invisible tant que le projet orchestre n'avait pas de remote. La
  #   neutralisation va desormais dans la configuration PROPRE au worktree
  #   (config.worktree), que le depot principal ne lit pas. Test Y2.
  # AVANT :   git config extensions.worktreeConfig true
  #   (2026-09-23, essai de bout en bout, defaut 50) Cette ecriture dans le
  #   .git/config PARTAGE avait lieu a chaque lancement : T-003 et T-005, parties
  #   dans la meme seconde, se sont disputees son verrou et T-003 a perdu
  #   (rc 255, P10). La valeur ne change jamais une fois posee : on ne l'ecrit que
  #   si elle manque, et sous le verrou du depot. config.worktree, lui, est propre
  #   au worktree : pas de concurrence. Test P6.
  if [[ "$(git config --get extensions.worktreeConfig || true)" != true ]]; then
    sous_verrou_depot git config extensions.worktreeConfig true
  fi
  git config --worktree remote.origin.pushurl "no-push://interdit"
  log "pushurl neutralisée dans le worktree"
fi

# --- 4. Contexte de tâche -------------------------------------------------
# (2026-09-24, T-002 iziGSM, defaut 70) La consigne humaine (« repondre.sh
# modifier » ou « relancer ») etait ecrite dans la fiche et lue par PERSONNE :
# l'agent relance repartait sans elle. Elle entre desormais dans la fiche de
# tache et dans le prompt, prioritaire, puis est consommee apres la session. Test EC13.
FICHE_TACHE="$ORCH_DIR/etat/taches/$TASK_ID.env"
CONSIGNE_H="$(sed -n 's/^consigne_humaine=//p' "$FICHE_TACHE" 2>/dev/null | head -1 || true)"
# (2026-09-27, O48) Corrections demandees par le relecteur (boucle de
# correction, pipeline.sh) : ecrites dans l'etat, remises a l'agent comme la
# consigne humaine, consommees apres la session. Test BC1.
CORRECTIONS_F="$STATE_DIR/$TASK_ID.corrections.md"
CORRECTIONS=""
[[ -f "$CORRECTIONS_F" ]] && CORRECTIONS="$(cat "$CORRECTIONS_F")"
cat >"$WT/.claude-task.md" <<EOF
# Tâche en cours — $TASK_ID

Périmètre autorisé : ${TACHE[perimetre]:-non spécifié}
Critère de done    : ${TACHE[critere]:-non spécifié}
Gates à passer     : ${TACHE[gates]:-lint,typecheck,test}

## Invariants (non négociables)
- Aucun secret en dur, aucune clé dans le code ou les commits.
- Aucun push. Aucun \`git checkout main\`. Aucune commande infra.
- Toute nouvelle dépendance exige un ADR dans docs/adr/ avant l'installation.
- Toute migration de base ou modification de schéma = arrêt et escalade.
- Ne touche QUE les fichiers du périmètre ci-dessus. Si tu dois en sortir, arrête-toi.
- Aucun commit : le harnais commite ton travail sous l'identité de l'agent (O7).
- Ignore l'étape Commit de tout skill (implement compris) : git en lecture seule
  (status, diff, log, show…) ; toute autre commande git est refusée (ADR 0004).
- Tu n'écris AUCUN fichier critique (constitution, socle, configuration, secrets :
  orchestrator/fichiers-critiques.json) ni hors du périmètre (ADR 0002). Si tu en as
  besoin, soumets une demande d'écriture dans $COMPTE_RENDU_AGENT et poursuis sans.
- Tu rends compte : avant de conclure, écris $COMPTE_RENDU_AGENT (JSON) —
  criteres [{critere, statut: fait|partiel|non_fait, preuve}], ecarts [texte],
  tests {joues: [], non_joues: []}, demandes_ecriture [{fichier, besoin,
  justification, diff}] (diff unifié exact, appliqué tel quel si un humain l'approuve).
  Ce compte rendu est remis au relecteur, qui le vérifie contre ton diff.
- Conception (ADR 0003) : si une prescription du ticket (critère ou test prescrit)
  validerait un défaut de sûreté des données (opération non atomique, course,
  reprise après échec partiel, écrasement, double comptage) ou contredirait un
  invariant du projet, ARRÊTE-TOI sans coder : ta conclusion commence par
  « conception: », cite la prescription, le scénario qui casse et la variante sûre.
  Ne code ni la prescription ni ta variante sans décision humaine — sauf si la
  variante ne change aucun critère ni aucun test prescrit : code-la et signale-la.
- Preuve (ADR 0003) : ce que tu ne peux pas jouer (E2E hors de portée,
  préproduction, production) se DEMANDE dans ton compte rendu : demandes_action
  [{type: "e2e", specs: [...], attendu, pourquoi}] ; la mutation d'un fichier
  critique : [{type: "mutation", fichier, diff (mutation exacte), controle, pourquoi}].
  N'écris jamais « vérifié » pour ce qui n'a pas tourné.
- Chaque test nouveau d'un critère de sûreté : rouge prouvé par mutation — un
  mutant à la fois, restauré, consigné dans ta conclusion (mutation, test, rouge
  vu). Fichier critique : ne le mute pas, demande la mutation (ci-dessus).
EOF
# (2026-09-29, ADR 0004 D2.1) La consigne ne disait que les interdits : sur T-004,
# 25 skills disponibles et aucun appele. Elle dit desormais comment travailler, avec
# les commandes EXACTES des controles de la tache (gates.json du depot principal,
# celles que gate.sh jouera), et l'architecture du CLAUDE.md du projet, que le
# relecteur peut opposer (R11). Test DC1.
COMMANDES_GATES=""
IFS=',' read -r -a GATES_TACHE <<<"${TACHE[gates]:-lint,typecheck,test}"
for GATE_N in "${GATES_TACHE[@]}"; do
  GATE_N="${GATE_N//[[:space:]]/}"
  [[ -n "$GATE_N" ]] || continue
  GATE_C=""
  [[ -f "$ROOT/orchestrator/gates.json" ]] \
    && GATE_C="$(jq -r --arg g "$GATE_N" '.gates[$g] // empty' "$ROOT/orchestrator/gates.json" 2>/dev/null || true)"
  COMMANDES_GATES+="  - $GATE_N : ${GATE_C:-commande non déclarée dans gates.json}"$'\n'
done
cat >>"$WT/.claude-task.md" <<EOF

## Méthode (ADR 0004)
- Une tranche verticale à la fois : un comportement de bout en bout, testé, avant le suivant.
- Les contrôles que le harnais jouera après toi, commandes exactes :
${COMMANDES_GATES}  Lance le typecheck souvent, la suite complète avant de conclure.
- Tests aux coutures du ticket, par l'interface publique : jamais tautologiques (un test
  qui ne peut pas échouer), jamais liés à l'implémentation (détails internes simulés).
- Architecture : respecte l'architecture et les conventions écrites dans le
  CLAUDE.md du projet, et les motifs du code voisin (structure, nommage, gestion
  d'erreur, commentaires). Toute nouvelle abstraction se justifie dans « ecarts » de ton compte
  rendu. Le relecteur rejette un écart à l'architecture déclarée (R11).
EOF
if [[ -n "$CONSIGNE_H" ]]; then
  printf '\n## CONSIGNE DE L'"'"'HUMAIN (prioritaire)\n%s\n' "$CONSIGNE_H" >>"$WT/.claude-task.md"
fi
if [[ -n "$CORRECTIONS" ]]; then
  printf '\n## CORRECTIONS DEMANDÉES PAR LE RELECTEUR\n%s\n' "$CORRECTIONS" >>"$WT/.claude-task.md"
fi

# (2026-09-21) La fiche de tache n'appartient pas au code du projet. Sans cette
# exclusion, le « git add -A » de l'etape 7 l'embarquait dans la branche de
# l'agent (constate sur le bac a sable : commit reduit a .claude-task.md), d'ou
# elle aurait ete fusionnee — et elle masquait le controle « diff:vide » de
# gate.sh quand l'agent n'avait rien ecrit. Exclusion locale au depot
# (info/exclude, partage par les worktrees) : le .gitignore du projet reste intact.
exclure_localement "$WT" .claude-task.md
# (2026-09-24, ADR 0002) Meme regle pour le compte rendu de l'agent : le harnais le
# lit apres la session, il n'appartient pas au code. Un compte rendu d'un essai
# precedent est retire : il ne doit pas passer pour celui de cette session.
exclure_localement "$WT" "$COMPTE_RENDU_AGENT"
rm -f "$WT/$COMPTE_RENDU_AGENT"
# (2026-09-24, O29) Un depassement accepte par l'humain (quota, risque) valait
# pour le travail qu'il a vu : une nouvelle session de l'agent produit un autre
# code, qui repasse sous les controles. Test EC15.
rm -f "$STATE_DIR/$TASK_ID.depassements-acceptes"

# --- 5. Lancement headless ------------------------------------------------
# (2026-09-24, O7) Le prompt ORDONNAIT « Commit sur la branche courante » : l'agent
# commitait lui-meme, sous l'identite configuree dans le depot — celle de
# l'operateur (essai de publication, 22/09). Il ne commite plus : l'etape 7 le fait
# sous « agent-T-NNN <agent@local> ». Ligne d'origine (continuee) :
# AVANT : Vérifie que les gates passent avant de conclure. Commit sur la branche courante.
# AVANT : PROMPT="Lis .claude-task.md et CLAUDE.md, puis implémente la tâche $TASK_ID.
# AVANT : destructive est nécessaire, n'agis pas : explique le blocage et arrête-toi."
#   (2026-09-24, ADR 0002) Deux lignes ajoutees en fin de prompt : la doctrine
#   d'ecriture et le compte rendu. Sur T-001 (iziGSM), l'agent a redefini dans
#   CLAUDE.md l'exigence qu'il ne satisfaisait pas, au lieu de s'arreter.
#   (2026-09-29, ADR 0004 D1.1) Une ligne ajoutee apres « Ne commite pas » : le
#   skill implement finit par « Commit your work ». Test GG2.
PROMPT="Lis .claude-task.md et CLAUDE.md, puis implémente la tâche $TASK_ID.
Vérifie que les gates passent avant de conclure. Ne commite pas : le harnais s'en charge.
Ignore l'étape Commit de tout skill : git en lecture seule (ADR 0004).
Si une décision d'architecture, une dépendance, un secret ou une action
destructive est nécessaire, n'agis pas : explique le blocage et arrête-toi.
Tu exécutes ; tu n'écris aucun fichier critique ni hors périmètre : si tu en as besoin, mets une
demande motivée dans demandes_ecriture de $COMPTE_RENDU_AGENT. Ne redéfinis jamais une exigence.
Termine par ce compte rendu (format dans .claude-task.md) : le relecteur le confronte à ton diff."
if [[ -n "$CONSIGNE_H" ]]; then
  PROMPT="$PROMPT
CONSIGNE DE L'HUMAIN (prioritaire sur tout le reste) : $CONSIGNE_H"
  log "Consigne humaine transmise a l'agent"
fi
if [[ -n "$CORRECTIONS" ]]; then
  PROMPT="$PROMPT
$CORRECTIONS"
  log "Corrections du relecteur transmises a l'agent"
fi

# Skill de l'etape (2026-09-21) : designe par orchestrator/skills.json. Le prompt
# commence par « /<skill> » : Claude Code charge le skill AVANT que l'agent ne
# commence, au lieu de compter sur lui pour y penser. Le reste du prompt devient
# les arguments du skill. Vide = comportement d'avant, sans skill.
SKILL_IMPL="$(skill_pour implementation "$TASK_ID")"
if [[ -n "$SKILL_IMPL" ]]; then
  PROMPT="/$SKILL_IMPL $PROMPT"
  log "Skill d'implémentation : $SKILL_IMPL"
fi

# (2026-09-24, ADR 0002, verrou 2 — O33) Empecher AVANT l'ecriture. Mesure sur
# T-001 (iziGSM) : lance en acceptEdits, l'agent a ecrit public/ et CLAUDE.md alors
# que settings.json n'autorisait que src/ et tests/ — ce mode accepte toute
# ecriture non interdite. Mesure en headless le meme jour : en mode default, une
# ecriture hors --allowedTools est REFUSEE (pas demandee) ; un hook PreToolUse
# passe par --settings refuse meme une ecriture autorisee. Deux couches :
#   - autorisations d'ecriture = perimetre de la tache (+ le compte rendu) ;
#   - hook guard-ecriture.sh du DEPOT PRINCIPAL (la copie du worktree ne compte
#     pas) : refuse tout fichier critique, et tout chemin hors perimetre.
# Un contournement par le shell reste possible : gate.sh le rattrape (verrou 3).
# Ligne d'origine de la commande ci-dessous (continuee) :
# AVANT :   --permission-mode acceptEdits \
AUTORISATIONS="Edit(./$COMPTE_RENDU_AGENT),Write(./$COMPTE_RENDU_AGENT)"
IFS=',' read -r -a MOTIFS_PERIMETRE <<<"${TACHE[perimetre]:-}"
for m in "${MOTIFS_PERIMETRE[@]}"; do
  m="${m//[[:space:]]/}"
  [[ -n "$m" ]] && AUTORISATIONS+=",Edit(./$m),Write(./$m)"
done
# AVANT : REGLAGES_AGENT="$(jq -nc --arg h "'$ROOT/.claude/hooks/guard-ecriture.sh'" \
# AVANT :   '{hooks:{PreToolUse:[{matcher:"Edit|Write|MultiEdit|NotebookEdit",hooks:[{type:"command",command:$h,timeout:10}]}]}}')"
#   (2026-09-29, ADR 0004 D1.2) Second matcher Bash : guard-git.sh du depot
#   principal, git en lecture seule pour l'agent (liste blanche). Test GG2.
REGLAGES_AGENT="$(jq -nc --arg h "'$ROOT/.claude/hooks/guard-ecriture.sh'" --arg g "'$ROOT/.claude/hooks/guard-git.sh'" \
  '{hooks:{PreToolUse:[{matcher:"Edit|Write|MultiEdit|NotebookEdit",hooks:[{type:"command",command:$h,timeout:10}]},
                       {matcher:"Bash",hooks:[{type:"command",command:$g,timeout:10}]}]}}')"

# (2026-09-29, ADR 0004 D1.3) Tete de la branche notee juste avant l'agent,
# comparee juste apres (avant l'etape 7) : un commit de l'agent se DETECTE, quelle
# que soit la forme qui a echappe au hook. Test GG3.
TETE_AVANT="$(git -C "$WT" rev-parse HEAD)"

set +e
# (2026-09-24, O7) Filet si l'agent commite malgre tout (autre forme de commande
# que « git commit », skill qui commite) : l'identite git de son environnement est
# celle de l'agent. Ces variables l'emportent sur user.name / user.email du depot.
# (2026-09-24, ADR 0002) ORCH_* : contexte du hook guard-ecriture (tache,
# perimetre, socle et liste des fichiers critiques du depot principal, worktree).
GIT_AUTHOR_NAME="agent-$TASK_ID" GIT_AUTHOR_EMAIL="agent@local" \
GIT_COMMITTER_NAME="agent-$TASK_ID" GIT_COMMITTER_EMAIL="agent@local" \
ORCH_AGENT_TACHE="$TASK_ID" ORCH_PERIMETRE="${TACHE[perimetre]:-}" ORCH_SOCLE="$ROOT" ORCH_WT="$WT" \
ORCH_CRITIQUES="$ROOT/orchestrator/fichiers-critiques.json" \
claude -p "$PROMPT" "${REPRISE[@]}" \
  --model "$MODEL" \
  --output-format stream-json --verbose \
  --max-turns "$MAX_TURNS" \
  --permission-mode default \
  --allowedTools "$AUTORISATIONS" \
  --settings "$REGLAGES_AGENT" \
  >"$LOG" 2>&1
CLAUDE_RC=$?
set -e
# Consigne consommee : elle ne sera pas redonnee a la relance suivante (EC13).
[[ -z "$CONSIGNE_H" ]] || sed -i 's/^consigne_humaine=.*/consigne_humaine=/' "$FICHE_TACHE"
# (2026-09-27, O48) Corrections consommees de meme. Une consigne humaine ouvre un
# nouveau cycle : le compteur de la boucle de correction repart de zero. Test BC2.
rm -f "$CORRECTIONS_F"
[[ -z "$CONSIGNE_H" ]] || sed -i '/^corrections=/d' "$FICHE_TACHE"

# (2026-09-24, ADR 0002, verrous 4 et 5) Compte rendu de l'agent : lu par le
# harnais, conserve dans l'etat (remis au relecteur par review.sh), jamais
# committe. Ses demandes d'ecriture partent a l'humain (pipeline.sh, P12) ; une
# nouvelle serie annule la decision prise sur la precedente.
CR_ETAT="$STATE_DIR/$TASK_ID.compte-rendu.json"
if [[ -f "$WT/$COMPTE_RENDU_AGENT" ]]; then
  if jq -e 'type == "object"' "$WT/$COMPTE_RENDU_AGENT" >/dev/null 2>&1; then
    jq . "$WT/$COMPTE_RENDU_AGENT" >"$CR_ETAT"
    # AVANT :     jq '[(.demandes_ecriture // [])[] | . + {origine: "agent"}]' "$CR_ETAT" >"$STATE_DIR/$TASK_ID.demandes.json"
    #   (2026-09-24, T-002 iziGSM, defaut 69) Une demande SANS diff (« plus tard »)
    #   etait retenue et escaladee : son approbation n'aurait rien pu appliquer.
    #   Seule une demande qui porte un fichier et un diff unifie est retenue ; les
    #   autres restent lisibles dans le compte rendu remis au relecteur. Test EC12.
    jq '[(.demandes_ecriture // [])[] | select((.fichier // "") != "" and ((.diff // "") | test("@@")))
         | . + {origine: "agent"}]' "$CR_ETAT" >"$STATE_DIR/$TASK_ID.demandes.json"
    DEM_ECARTEES="$(jq '[(.demandes_ecriture // [])[]] | length' "$CR_ETAT")"
    DEM_ECARTEES=$(( DEM_ECARTEES - $(jq length "$STATE_DIR/$TASK_ID.demandes.json") ))
    (( DEM_ECARTEES == 0 )) || log "Demande(s) d'ecriture ecartee(s) faute de diff : $DEM_ECARTEES"
    rm -f "$STATE_DIR/$TASK_ID.demandes.decision"
    log "Compte rendu de l'agent conserve ($(jq length "$STATE_DIR/$TASK_ID.demandes.json") demande(s) d'ecriture)"
    # (2026-09-25, ADR 0003 R3, O40) Demandes d'ACTION : la preuve que l'agent ne
    # peut pas produire (E2E hors de portee, mutation d'un fichier critique). Une
    # demande e2e sans specs, ou mutation sans fichier ni diff, est ecartee. Elles
    # interdisent la fusion automatique et DONE tant qu'elles ne sont pas soldees
    # (decide.sh, reconcile.sh). Tests PV1, PV2.
    jq '[(.demandes_action // [])[]
         | select((.type == "e2e" and ((.specs // []) | length > 0))
                  or (.type == "mutation" and (.fichier // "") != "" and ((.diff // "") | test("@@"))))]
        | to_entries | map(.value + {id: ("P16-" + ((.key + 1) | tostring)), statut: "a_fournir"})' \
      "$CR_ETAT" >"$STATE_DIR/$TASK_ID.preuves.json"
    log "Preuve(s) demandee(s) par l'agent : $(jq length "$STATE_DIR/$TASK_ID.preuves.json")"
  else
    jq -n --rawfile b "$WT/$COMPTE_RENDU_AGENT" '{invalide: true, brut: $b}' >"$CR_ETAT"
    log "Compte rendu de l'agent illisible (JSON invalide) : transmis tel quel au relecteur"
  fi
  rm -f "$WT/$COMPTE_RENDU_AGENT"
else
  rm -f "$CR_ETAT"
  log "Aucun compte rendu de l'agent"
fi
# (2026-09-22, defaut 7) Cout, tokens, tours et duree de l'auteur au journal des
# couts, AVANT la porte : une tache rouge ou en panne a quand meme depense.
journaliser_cout "$TASK_ID" auteur "$LOG"

# --- 6. Capture de session et coût ---------------------------------------
SESSION_ID="$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$LOG" 2>/dev/null | head -1 || true)"
COUT="$(jq -r 'select(.type=="result") | .total_cost_usd // empty' "$LOG" 2>/dev/null | tail -1 || true)"
TOURS="$(jq -r 'select(.type=="result") | .num_turns // empty' "$LOG" 2>/dev/null | tail -1 || true)"

{
  printf 'session_id=%s\n' "${SESSION_ID:-}"
  printf 'claude_rc=%s\n' "$CLAUDE_RC"
  printf 'cout_usd=%s\n' "${COUT:-0}"
  printf 'tours=%s\n' "${TOURS:-0}"
  printf 'skill_demande=%s\n' "${SKILL_IMPL:-}"
  # (2026-09-29, ADR 0004 D5, O5) Skills REELLEMENT appeles : chaque tool_use
  # « Skill » du journal, sans doublon, dans l'ordre. Vide = aucun appel (0 sur
  # les 6 journaux reels des bacs a sable au 29/09). Tests SK1, SK2.
  printf 'skills_invoques=%s\n' "$(jq -r 'select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use" and .name=="Skill") | .input.skill // empty' "$LOG" 2>/dev/null \
    | awk '!vu[$0]++' | paste -sd, - || true)"
} >"$STATE"

log "Session ${SESSION_ID:-inconnue} | coût ${COUT:-0} USD | $TOURS tours"

# (2026-09-29, ADR 0004 D1.3) L'agent a commite lui-meme : le harnais ne commite
# rien par-dessus (il signerait un historique qu'il n'a pas ecrit) et sort en 34 ;
# pipeline.sh met la branche en quarantaine et escalade P13:commit-agent (L4).
# Compte rendu et cout sont deja journalises ci-dessus. Tests GG3, GG4.
TETE_APRES="$(git -C "$WT" rev-parse HEAD)"
if [[ "$TETE_APRES" != "$TETE_AVANT" ]]; then
  printf 'commit_agent=%s..%s\n' "$TETE_AVANT" "$TETE_APRES" >>"$STATE"
  log "L'agent a commite lui-meme ($TETE_AVANT..$TETE_APRES) : aucun commit du harnais, P13:commit-agent (ADR 0004)"
  cd "$ROOT"
  exit 34
fi

# --- 7. Commit automatique (agent) ---------------------------------------
cd "$WT"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git -c user.name="agent-$TASK_ID" -c user.email="agent@local" \
      commit -q -m "$TASK_ID: implémentation automatique (session ${SESSION_ID:-n/a})"
  log "Commit agent créé sur $BRANCH"
fi

# (2026-09-27, O45, premier vrai ticket iziGSM) Agent coupe par son plafond de
# tours (T-001 : 60 tours, avant tests et ecran) : le socle lancait quand meme
# les controles et ne disait jamais « agent coupe ». Travail partiel garde sur la
# branche (commit ci-dessus, reprise possible), controles NON lances, code 33 :
# pipeline.sh en fait P14:max-turns. Test MT1.
if [[ "$(jq -r 'select(.type == "result") | .subtype // empty' "$LOG" 2>/dev/null | tail -1 || true)" == error_max_turns ]]; then
  log "Agent coupe a ${TOURS:-?} tours (plafond $MAX_TURNS) : travail partiel sur $BRANCH, controles non lances"
  cd "$ROOT"
  exit 33
fi

# --- 8. Porte -------------------------------------------------------------
set +e
"$(dirname "$0")/gate.sh" "$TASK_ID" "$INTEGRATION_BRANCH" "$WT" >/dev/null
GATE_RC=$?
set -e

case "$GATE_RC" in
  0)
    log "VERDICT vert — tâche $TASK_ID prête pour revue (branche $BRANCH, non poussée)"
    ;;
  10)
    log "VERDICT rouge — gates échouées. Logs : $LOG_DIR/gate-$TASK_ID-*.log"
    ;;
  20)
    log "VERDICT escalade — décision humaine requise."
    # AVANT :     "$ROOT/.claude/hooks/notify-escalade.sh" <<<"$(jq -n \
    # AVANT :       '{session_id:$s, cwd:$c, message:$m}')"
    #   (2026-09-24, premiere marche reelle sur iziGSM, T-001) Appele depuis le
    #   worktree (cd "$WT" plus haut), le hook ecrivait « ./.orchestrator/
    #   escalations.tsv », absent du worktree ; sous set -e, run-task sortait en 1
    #   au lieu de 20. Le pipeline ouvrait P10 « panne » : raisons des controles
    #   perdues, et « approuver » relancait l'agent. Le hook recoit la racine du
    #   projet, et son echec ne masque plus jamais le code 20. Test ES1.
    CLAUDE_PROJECT_DIR="$ROOT" "$ROOT/.claude/hooks/notify-escalade.sh" <<<"$(jq -n \
      --arg s "${SESSION_ID:-inconnue}" \
      --arg c "$WT" \
      --arg m "Tâche $TASK_ID : escalade (voir $STATE_DIR/$TASK_ID.verdict.json)" \
      '{session_id:$s, cwd:$c, message:$m}')" \
      || log "[ALERTE] notification locale de l'escalade $TASK_ID en echec — l'escalade suit son cours"
    ;;
esac

cd "$ROOT"
exit $GATE_RC
