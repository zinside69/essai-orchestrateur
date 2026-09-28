#!/usr/bin/env bash
# pipeline.sh — enchaine les etapes Phase 1, 2 et 3 pour une tache, avec transitions d'etat.
# Usage : pipeline.sh [--dry-run] T-NNN
#         pipeline.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"
DRY_RUN=0
TASK_ID=""

show_help() {
  cat <<'EOF'
Usage:
  pipeline.sh [--dry-run] T-NNN
  pipeline.sh --help

Enchaîne : run-task -> verify-evidence -> review -> decide -> publisher/journal/escalade.
En mode --dry-run, vérifie les dépendances de fichiers et affiche le flux sans exécuter Claude ni GitHub.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      [[ -z "$TASK_ID" ]] || die "argument inattendu : $1"
      TASK_ID="$1"
      shift ;;
  esac
done

[[ -n "$TASK_ID" ]] || die "usage: pipeline.sh [--dry-run] T-NNN"
F="$ETAT_DIR/taches/$TASK_ID.env"
D="$ROOT/orchestrator"
WT="$WORKTREE_ROOT/$TASK_ID"
DECISION="$STATE_DIR/$TASK_ID.decision.json"
REVUE="$STATE_DIR/$TASK_ID.revue.json"
GATE_V="$STATE_DIR/$TASK_ID.verdict.json"

[[ -f "$F" ]] || die "etat absent pour $TASK_ID (lancer scheduler.sh)"

# Transition d'etat gardee par la machine a etats (Phase 5 / P3-a).
transition() {
  local next="$1"
  if ! transition_etat "$F" "$next" pipeline; then
    log "transition refusee par la machine a etats : -> $next (tache $TASK_ID)"
  fi
}

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN pipeline] task=%s\n' "$TASK_ID"
  for f in "$D/run-task.sh" "$D/verify-evidence.sh" "$D/review.sh" "$D/decide.sh" "$D/publisher.sh" "$D/journal.sh" "$D/escalade.sh"; do
    [[ -f "$f" ]] || die "script manquant : $f"
    printf '[DRY-RUN pipeline] found %s\n' "$f"
  done
  printf '[DRY-RUN pipeline] state=%s\n' "$F"
  printf '[DRY-RUN pipeline] flow=run-task -> verify-evidence -> review -> decide -> publisher/journal/escalade\n'
  exit 0
fi

# (2026-09-28, O49) Chaque passage juge ses propres appels : les ecarts de
# modele d'un passage precedent (deja escalades) ne comptent plus. Test MD2.
rm -f "$STATE_DIR/$TASK_ID.modele-ecart"

# 0 moins. Racine du projet sur la branche d'integration (2026-09-27, O44,
# premier vrai ticket iziGSM) : « git fetch origin integration:integration »
# (run-task.sh) est refuse par git quand cette branche est extraite dans la
# racine (« refusing to fetch into branch checked out ») : la tache echouait en
# 1 s, P10, message git obscur. Decision de l'operateur : detecter et refuser,
# jamais toucher le dossier du projet (le socle n'y ecrit pas, les agents
# travaillent dans des worktrees). Controle fait AVANT tout appel paye, y
# compris la relecture de conception. Test RI1.
BRANCHE_RACINE="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [[ "$BRANCHE_RACINE" == "$INTEGRATION_BRANCH" ]]; then
  transition FAILED
  ESC_RACINE="$STATE_DIR/$TASK_ID.escalade-racine.json"
  jq -nc --arg b "$INTEGRATION_BRANCH" --arg r "$ROOT" \
    '{raisons: ["P10:racine-sur-integration"],
      detail: ("Le dossier du projet (" + $r + ") est sur la branche " + $b + " : le socle ne peut pas la mettre a jour depuis GitHub. Geste : dans ce dossier, git switch -c poste-orchestrateur (meme commit, rien ne change dans les fichiers), puis repondre approuver.")}' >"$ESC_RACINE"
  "$D/escalade.sh" "$TASK_ID" "$ESC_RACINE" || true
  log "$TASK_ID : racine du projet sur $INTEGRATION_BRANCH — tache refusee avant tout appel (O44)"
  exit 32
fi

# 0. Relecture de conception (2026-09-25, ADR 0003 R1, O39) — si le projet l'a
# activee ("conception": true dans gates.json). Un doute (ou une relecture en
# panne, ou illisible) ne laisse jamais partir l'agent : escalade P15 (L3) avec
# la prescription, le risque et l'amendement propose. L'humain amende le ticket
# puis « approuver » (relecture refaite), ou passe outre par « modifier » (sa
# consigne va a l'agent). Tests CO1 a CO6.
set +e
"$D/conception.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
rcc=$?
set -e
if (( rcc != 0 )); then
  transition PARKED
  ESC_CO="$STATE_DIR/$TASK_ID.escalade-conception.json"
  jq -c '{raisons: ["P15:conception(\(.constats | length))"],
          detail: (.constats | map("- prescription : \(.prescription // "")\n  risque : \(.risque // "")\n  amendement propose : \(.amendement // "")") | join("\n"))}' \
    "$STATE_DIR/$TASK_ID.conception.json" >"$ESC_CO" 2>/dev/null \
    || jq -nc --arg rc "$rcc" '{raisons: ["P15:conception(panne)"], detail: ("relecture de conception en panne (code " + $rc + ")")}' >"$ESC_CO"
  "$D/escalade.sh" "$TASK_ID" "$ESC_CO" || true
  log "$TASK_ID : conception en doute — agent non lance (P15)"
  exit 20
fi

# 1. Execution de l'auteur (Phase 1)
# AVANT : if ! "$D/run-task.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1; then
# AVANT :   rcg=$?
# AVANT :   if (( rcg == 10 )); then
# AVANT :     transition RED
# AVANT :   else
# AVANT :     transition FAILED
# AVANT :   fi
# AVANT :   exit "$rcg"
# AVANT : fi
#   (2026-09-22, essai de publication, defauts 10 et 2) Dans « if ! cmd », $?
#   est celui de la negation : rcg valait TOUJOURS 0. Des controles rouges
#   devenaient FAILED au lieu de RED et le pipeline sortait en 0. Et une vraie
#   panne passait FAILED sans prevenir personne (meme esprit que le defaut 30).
#   Trois issues distinctes desormais. Tests Y3 et Y4.
# (2026-09-24, ADR 0002) Reprise SANS agent : apres « nettoyer » ou une reponse a
# une demande d'ecriture, repondre.sh pose « reprise=controles » dans la fiche.
# Le travail est deja sur la branche : on relance les controles (gate.sh, meme
# code de sortie que run-task.sh, qui finit par lui) et la suite normale, sans
# payer ni relancer l'agent. La marque ne sert qu'une fois. Test EC6.
# Ligne d'origine, desormais dans la branche « else » :
# AVANT : "$D/run-task.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
set +e
if grep -qx 'reprise=controles' "$F"; then
  sed -i '/^reprise=/d' "$F"
  log "$TASK_ID : reprise sans agent — controles relances sur la branche existante"
  ( cd "$WT" && "$D/gate.sh" "$TASK_ID" "$INTEGRATION_BRANCH" "$WT" ) >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
else
  "$D/run-task.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
fi
rcg=$?
set -e
# (2026-09-24, T-002 iziGSM, defaut 68) Un agent qui s'ARRETE sans rien ecrire —
# decision requise, blocage explique — sortait en « P11 : controles rouges
# (diff:vide) » : faux motif, et l'alerte ne gardait que les 600 DERNIERS
# caracteres de sa conclusion, ou le blocage (en tete) disparaissait. Raison
# distincte P14 (L3, humain), conclusion prise par le DEBUT. Test EC11.
if (( rcg == 10 )) && jq -e '(.raisons // []) == ["diff:vide"]' "$GATE_V" >/dev/null 2>&1; then
  transition PARKED
  ESC_ARRET="$STATE_DIR/$TASK_ID.escalade-arret.json"
  CONCLUSION="$(jq -Rrs '[split("\n")[] | fromjson? | select(.type == "result")] | last | .result // empty' \
    "$LOG_DIR/run-$TASK_ID.jsonl" 2>/dev/null | head -c 1500 | iconv -c -f UTF-8 -t UTF-8 || true)"
  # (2026-09-25, ADR 0003 R2) Un arret motive par la conception (conclusion qui
  # commence par « conception: ») est distingue : raison P14:arret-conception,
  # libelle propre dans l'alerte. Test CR1. Filtre d'origine :
  # AVANT :   jq -nc --arg d "${CONCLUSION:-aucune conclusion}" \
  # AVANT :     '{raisons: ["P14:arret-sans-code"], detail: $d}' >"$ESC_ARRET"
  MOTIF_ARRET="arret-sans-code"
  [[ "$(printf '%s' "$CONCLUSION" | sed -e 's/^[[:space:]]*//' | head -c 11 | tr '[:upper:]' '[:lower:]')" == "conception:" ]] \
    && MOTIF_ARRET="arret-conception"
  jq -nc --arg d "${CONCLUSION:-aucune conclusion}" --arg m "P14:$MOTIF_ARRET" \
    '{raisons: [$m], detail: $d}' >"$ESC_ARRET"
  "$D/escalade.sh" "$TASK_ID" "$ESC_ARRET" || true
  log "$TASK_ID : l'agent s'est arrete sans ecrire de code (P14) — decision humaine attendue"
  exit 20
fi
if (( rcg != 0 )); then
  case "$rcg" in
    10)
      # Controles rouges : le cas normal d'un nouvel essai (RED -> RUNNING).
      #   (2026-09-22, T-002 sur GitHub, defaut 12) Faux : le graphe ne relance
      #   que PENDING/READY, une tache RED restait figee sans prevenir personne —
      #   alors que l'agent de T-002 avait ecrit quoi faire. RED escalade (P11,
      #   non derive : L3 par defaut, les canaux de L2 visent une PR qui n'existe
      #   pas), avec la conclusion de l'agent dans le texte de l'alerte. Test Y4.
      # AVANT :       transition RED ;;
      transition RED
      ESC_RED="$STATE_DIR/$TASK_ID.escalade-rouge.json"
      RAISONS_GATE="$(jq -r '(.raisons // []) | join(",")' "$GATE_V" 2>/dev/null || true)"
      DETAIL_AGENT="$(jq -Rr 'fromjson? | select(.type == "result") | .result // empty' \
        "$LOG_DIR/run-$TASK_ID.jsonl" 2>/dev/null | tail -c 600 || true)"
      jq -nc --arg r "$RAISONS_GATE" --arg d "$DETAIL_AGENT" \
        '{raisons: ["P11:controles-rouges(" + $r + ")"], detail: $d}' >"$ESC_RED"
      "$D/escalade.sh" "$TASK_ID" "$ESC_RED" || true ;;
    20)
      # gate.sh demande un humain (risque, perimetre) : ses raisons font l'escalade.
      transition PARKED
      # (2026-09-24, ADR 0002, verrou 3) Violation de la doctrine d'ecriture (P13) :
      # la branche FAUTIVE est mise en quarantaine des la detection — trace
      # intacte, jamais publiee. Le travail, lui, reste recuperable (« nettoyer »,
      # « relancer »). Une quarantaine deja posee n'est jamais ecrasee. Test EC4.
      if jq -e '[.raisons[]? | select(startswith("P13:"))] | length > 0' "$GATE_V" >/dev/null 2>&1; then
        QUAR="quarantine/$TASK_ID"
        git -C "$ROOT" rev-parse -q --verify "refs/heads/$QUAR" >/dev/null && QUAR="quarantine/$TASK_ID-$(date -u +%Y%m%dT%H%M%S)"
        git -C "$ROOT" branch "$QUAR" "$AGENT_BRANCH_PREFIX/$TASK_ID" \
          && log "$TASK_ID : branche fautive mise en quarantaine ($QUAR)"
      fi
      "$D/escalade.sh" "$TASK_ID" "$GATE_V" || true ;;
    33)
      # (2026-09-27, O45) Agent coupe par son plafond de tours : ni panne (P10), ni
      # controles rouges (P11) — ils n'ont pas tourne. Raison propre, dans l'alerte :
      # combien de tours, ce qui reste, les trois gestes possibles. Tests MT1, MT2.
      transition PARKED
      ESC_TOURS="$STATE_DIR/$TASK_ID.escalade-tours.json"
      jq -nc --arg n "$(sed -n 's/^tours=//p' "$STATE_DIR/$TASK_ID.state" 2>/dev/null | head -1)" \
        '{raisons: ["P14:max-turns"],
          detail: ("Agent coupe a " + $n + " tours, avant la fin : travail partiel garde sur sa branche, controles non lances. approuver = reprendre sa session (meme plafond) ; plafond plus haut = max_tours=N dans la fiche de la tache, puis approuver ; ticket trop gros = le decouper.")}' >"$ESC_TOURS"
      "$D/escalade.sh" "$TASK_ID" "$ESC_TOURS" || true ;;
    31)
      # (2026-09-24, O1) Depot non approuve dans Claude Code : rien n'a tourne,
      # rien n'a coute. Meme escalade P10 qu'une panne, mais l'alerte dit le geste
      # a faire ; « approuver » (bouton « Relancer ») relance ensuite la tache.
      transition FAILED
      ESC_RUN="$STATE_DIR/$TASK_ID.escalade-run-task.json"
      jq -nc --arg rc "$rcg" --arg d "Depot non approuve dans Claude Code ($ROOT) : lancer une fois « claude » dans ce dossier, accepter la confiance, puis repondre approuver." \
        '{raisons: ["P10:run-task-echoue(rc=" + $rc + ")"], detail: $d}' >"$ESC_RUN"
      "$D/escalade.sh" "$TASK_ID" "$ESC_RUN" || true ;;
    *)
      # Panne : worktree, preparation, agent. Quelqu'un doit le savoir. P10 n'est
      # derive nulle part dans escalade.json : L3 par defaut (ntfy prioritaire, e-mail).
      transition FAILED
      ESC_RUN="$STATE_DIR/$TASK_ID.escalade-run-task.json"
      jq -nc --arg rc "$rcg" '{raisons: ["P10:run-task-echoue(rc=" + $rc + ")"]}' >"$ESC_RUN"
      "$D/escalade.sh" "$TASK_ID" "$ESC_RUN" || true ;;
  esac
  exit "$rcg"
fi

# 1 quater. Demandes d'ecriture (ADR 0002, verrou 4) — deposees par l'agent dans
# son compte rendu, ou generees par « nettoyer ». Tant qu'un humain ne les a pas
# tranchees, rien n'avance : escalade P12 (L3), jamais le clone seul. Approuvees,
# repondre.sh applique le texte mot pour mot ; refusees, la tache poursuit sans.
DEMANDES="$STATE_DIR/$TASK_ID.demandes.json"
if [[ -s "$DEMANDES" && ! -f "$STATE_DIR/$TASK_ID.demandes.decision" ]] \
   && (( $(jq 'length' "$DEMANDES" 2>/dev/null || echo 0) > 0 )); then
  transition PARKED
  ESC_DEM="$STATE_DIR/$TASK_ID.escalade-demandes.json"
  # (2026-09-25, O34) Filtre d'origine, sans le diff des demandes, cite ici :
  # AVANT :   jq -c '{raisons: ["P12:demande-ecriture(\(length))"],
  # AVANT :           detail: (map("- \(.fichier) : \(.besoin // "") — justification : \(.justification // "aucune")") | join("\n"))}' \
  # AVANT :     "$DEMANDES" >"$ESC_DEM"
  escalade_demandes_ecriture "$DEMANDES" >"$ESC_DEM"
  "$D/escalade.sh" "$TASK_ID" "$ESC_DEM" || true
  log "$TASK_ID : $(jq length "$DEMANDES") demande(s) d'ecriture en attente d'une decision humaine (P12)"
  exit 20
fi

# 1bis. Evidence pack obligatoire (Phase 5 / P1-d)
# Aucune revue sans preuve non-code : absence d'artefact = escalade (P8).
set +e
"$D/verify-evidence.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
EV_RC=$?
set -e
if (( EV_RC != 0 )); then
  transition PARKED
  RAISON_EV="$(cat "$STATE_DIR/$TASK_ID.evidence.raison" 2>/dev/null || printf 'P8:evidence-manquante')"
  tmp="$STATE_DIR/$TASK_ID.escalade-evidence.json"
  jq -n --arg r "$RAISON_EV" '{raisons:[$r]}' >"$tmp"
  "$D/escalade.sh" "$TASK_ID" "$tmp" || true
  exit 20
fi

# Evidence pack complet : la tache est verifiee (Phase 5 / P3-a)
transition VERIFIED

# 1ter. Preuve « test vu rouge » mesuree (2026-09-22) : les tests de l'agent
# rejoues sur l'integration, sans son code. Le resultat (state/T.test-rouge.json)
# nourrit la regle Q3 de decide.sh ; la mesure n'interrompt jamais le pipeline.
"$D/test-rouge.sh" "$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 || true
# (2026-09-25, ADR 0003 R3, O41) Mutations demandees par l'agent (fichier
# critique) : jouees par le harnais sur une copie jetable, avant la revue et la
# decision. Rouge vu = preuve soldee ; sinon P16. Tests MU1 a MU3.
"$D/mutation.sh" "$TASK_ID" "$WT" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 || true

# 2. Revue croisee a contexte neuf (Phase 2)
if ! "$D/review.sh" "$TASK_ID" "$WT" "$INTEGRATION_BRANCH" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1; then
  transition PARKED
  tmp="$STATE_DIR/$TASK_ID.escalade-fallback.json"
  # (2026-09-25, O30) Tout echec de la revue devenait P5 (L4), y compris le
  # rejet P4 d'une sortie non conforme (rejet R0 ecrit par review.sh) : sur T-001
  # (iziGSM, 24/09) le relecteur avait rendu un verdict utile en JSON mal
  # echappe, et l'alerte parlait d'isolation. La raison vient maintenant de
  # revue.json ; pour P4 (L3), le debut de la sortie brute du relecteur va dans
  # l'alerte. Sans rejet R0 (isolation V, ou revue absente) : P5, comme avant.
  # Tests RV1, RV2. Ligne d'origine :
  # AVANT :   jq -n '{raisons:["P5:invariant-contexte-neuf"]}' >"$tmp"
  if jq -e '[.rejets[]? | select(.code == "R0")] | length > 0' "$REVUE" >/dev/null 2>&1; then
    # AVANT :     jq -n --arg brut "$(jq -r '.result // empty' "$STATE_DIR/$TASK_ID.reviewer.json" 2>/dev/null | head -c 1500 || true)" \
    #   (2026-09-27, O43) Extrait coupe en caracteres, plus en octets (« � »).
    jq -n --arg brut "$(jq -r '(.result // "") | .[0:1500]' "$STATE_DIR/$TASK_ID.reviewer.json" 2>/dev/null || true)" \
      '{raisons:["P4:revue-non-conforme"], detail:("sortie du relecteur non conforme au schema 2.0 — debut de la sortie brute : " + $brut)}' >"$tmp"
  else
    jq -n '{raisons:["P5:invariant-contexte-neuf"]}' >"$tmp"
  fi
  "$D/escalade.sh" "$TASK_ID" "$tmp" || true
  exit 20
fi

# 3. Matrice de decision (Phase 2)
set +e
"$D/decide.sh" "$TASK_ID" "$GATE_V" "$REVUE" "$WT" "$INTEGRATION_BRANCH" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1
DEC_RC=$?
set -e
if (( DEC_RC != 0 )); then
  # Preuve de gates invalide (P7) ou décision bloquante : escalade + journal.
  transition PARKED
  "$D/escalade.sh" "$TASK_ID" "$DECISION" || true
  "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
  exit 20
fi
VERDICT="$(jq -r '.verdict' "$DECISION")"
transition REVIEWED
# 3 bis. Boucle de correction (2026-09-27, O48) — doctrine de depart : un
# desaccord du relecteur renvoie l'agent corriger, avec les rejets en consigne,
# au plus « revue.corrections_max » fois (matrice.json, 2 par defaut) ; ensuite
# seulement, PR a relire pour l'humain. Un arret dur ou un risque eleve n'entre
# jamais dans la boucle (correction_eligible, lib.sh). La decision est
# journalisee avant la relance (I8). La relance reprend la session de l'agent
# (run-task.sh, --resume) sur sa branche ; la relecture de conception, deja
# conforme pour la meme declaration, ne coute rien. Tests BC1 a BC3.
CORR_MAX="$(jq -r '.revue.corrections_max // 2' "$D/matrice.json" 2>/dev/null || echo 2)"
CORR_FAITES="$(sed -n 's/^corrections=//p' "$F" | head -1)"
CORR_FAITES="${CORR_FAITES:-0}"
if correction_eligible "$DECISION" "$REVUE"; then
  if (( CORR_FAITES < CORR_MAX )); then
    CORR_N=$(( CORR_FAITES + 1 ))
    jq --arg r "C1:correction-agent($CORR_N/$CORR_MAX)" '.raisons += [$r]' "$DECISION" >"$DECISION.tmp" \
      && mv "$DECISION.tmp" "$DECISION"
    "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
    consigne_correction "$REVUE" "$CORR_N" "$CORR_MAX" >"$STATE_DIR/$TASK_ID.corrections.md"
    if grep -q '^corrections=' "$F"; then
      sed -i "s/^corrections=.*/corrections=$CORR_N/" "$F"
    else
      printf 'corrections=%s\n' "$CORR_N" >>"$F"
    fi
    transition RUNNING
    log "$TASK_ID : desaccord du relecteur — l'agent corrige (correction $CORR_N/$CORR_MAX)"
    exec "$D/pipeline.sh" "$TASK_ID"
  fi
  jq --arg r "M3:desaccord-apres-corrections($CORR_FAITES)" '.raisons += [$r]' "$DECISION" >"$DECISION.tmp" \
    && mv "$DECISION.tmp" "$DECISION"
  log "$TASK_ID : desaccord persistant apres $CORR_FAITES correction(s) — la main passe a l'humain"
fi
# (2026-09-25, ADR 0003 R3) Preuve a fournir (P16) : le detail des demandes va
# dans la decision, donc dans l'alerte (specs, attendu, pourquoi). Test PV2.
if jq -e '.raisons | map(select(startswith("P16:"))) | length > 0' "$DECISION" >/dev/null 2>&1; then
  jq --slurpfile p "$STATE_DIR/$TASK_ID.preuves.json" \
    '. + {detail: ($p[0] | map(select(.statut == "a_fournir")
        | "- \(.id) \(.type) : \((.specs // []) | join(", "))\(.fichier // "") — attendu : \(.attendu // "?") — pourquoi : \(.pourquoi // "?")") | join("\n"))}' \
    "$DECISION" >"$DECISION.tmp" && mv "$DECISION.tmp" "$DECISION"
fi

# 4. Escalade ou publication selon le verdict
if [[ "$VERDICT" == "PARK" ]]; then
  transition PARKED
  "$D/escalade.sh" "$TASK_ID" "$DECISION" || true
  "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
  exit 20
fi

# (2026-09-21, essai 6 du bac a sable) La decision est journalisee AVANT la
# tentative de publication. Elle ne l'etait qu'APRES une publication reussie :
# l'essai 6 a decide AUTO_MERGE, la publication a echoue, et le journal ne
# contenait aucune decision — invariant I8 (toute decision est journalisee)
# viole. Une decision existe des qu'elle est prise, qu'elle aboutisse ou non.
"$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true

"$D/publisher.sh" "$TASK_ID" "$WT" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 || {
  transition PARKED
  # (2026-09-21, essai 6) Un echec de publication n'etait signale a personne :
  # tache mise en pause en silence, alors qu'une decision de fusion venait
  # d'etre prise (esprit de M1). Escalade dediee ; la raison P9 n'etant derivee
  # nulle part dans escalade.json, escalade.sh retombe sur L3 par defaut
  # (ntfy prioritaire, e-mail).
  ESC_PUB="$STATE_DIR/$TASK_ID.escalade-publication.json"
  jq -nc --arg v "$VERDICT" '{raisons: ["P9:publication-echouee(" + $v + ")"]}' >"$ESC_PUB"
  "$D/escalade.sh" "$TASK_ID" "$ESC_PUB" || true
  exit 20
}

transition PUBLISHED
# AVANT : "$D/journal.sh" "$TASK_ID" "$DECISION" "$REVUE" || true
#   (2026-09-21) Deplacee avant la publication, ci-dessus : sinon une decision
#   dont la publication echoue n'etait jamais journalisee.
"$D/escalade.sh" "$TASK_ID" "$DECISION" || true
log "$TASK_ID : pipeline termine en $VERDICT"
