#!/usr/bin/env bash
# Porte de vérification. Sortie : JSON sur stdout, code 0 = vert, 10 = rouge, 20 = escalade.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
# (2026-09-24, ADR 0002) Doctrine d'ecriture : fichiers critiques et perimetre.
# shellcheck disable=SC1091
source "$(dirname "$0")/critiques.sh"

TASK_ID="${1:?usage: gate.sh T-NNN [branche-base]}"
BASE="${2:-$INTEGRATION_BRANCH}"
WT="${3:-$ROOT}"

require git jq sha256sum

VERDICT="green"
RAISONS=()
RISK="low"
GATES_PROOF=()
DEBUT_TS="$(date +%s)"

cd "$WT"

# --- 1. Gates techniques (preuve d'exécution, Phase 5 / P1-a) -------------
# Chaque gate laisse une sortie brute horodatée dont le SHA-256 est scellé
# dans le verdict : decide.sh revérifie hash + fraîcheur avant toute décision.
# (2026-09-24, premiere marche reelle sur iziGSM) Horodatage en millisecondes.
# Sous Ubuntu 26.04, date est celui de uutils : « %3N » n'y est pas compris et
# « date +%s%3N » rendait 18 chiffres sans rapport (1 127 968 187 « ms » pour un
# tsc d'une seconde). « %s%N » rend 19 chiffres chez GNU comme chez uutils : on en
# garde les 13 premiers. Sinon (date BSD, %N non gere) : secondes x 1000. Test DU1.
maintenant_ms() {
  local n
  n="$(date +%s%N 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]{19}$ ]]; then
    printf '%s\n' "${n:0:13}"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

run_gate() {
  local nom="$1"; shift
  local logf="$LOG_DIR/gate-$TASK_ID-$nom.log"
  local t0 t1 dur rc sha
  # AVANT :   t0="$(date +%s%3N 2>/dev/null || date +%s)"
  t0="$(maintenant_ms)"
  if "$@" >"$logf" 2>&1; then
    rc=0
    log "gate OK  : $nom"
  else
    rc=$?
    log "gate FAIL: $nom"
    VERDICT="red"
    RAISONS+=("gate:$nom")
  fi
  # AVANT :   t1="$(date +%s%3N 2>/dev/null || date +%s)"
  t1="$(maintenant_ms)"
  dur=$(( t1 - t0 ))
  sha="$(sha256sum "$logf" | awk '{print $1}')"
  GATES_PROOF+=("$(jq -nc --arg n "$nom" --arg s "$sha" --argjson d "$dur" --argjson rc "$rc" \
    '{nom:$n, sha256:$s, duration_ms:$d, rc:$rc}')")
}

# (2026-09-21) Controles declares par le projet. Sans gates.json, ce bloc lance
# TOUJOURS lint, typecheck, test et build par npm, en ignorant le champ gates de
# la tache : un projet sans script « lint » est rouge d'office (constate sur
# iziGSM). Avec orchestrator/gates.json, chaque controle a sa commande (code 0 =
# reussi ; les tolerances du projet vivent dans ses commandes), et seuls ceux
# que la tache declare sont lances — tous, si elle n'en declare aucun. Un
# controle declare mais sans commande rend ROUGE : ignore en silence, il
# passerait pour reussi. Le fichier est lu dans ROOT, jamais dans le worktree de
# l'agent : sa copie a lui ne compte pas (et la modifier classe le diff en
# risque haut, section 3).
# (1fc34cb) Le bloc d'origine est conserve a l'identique dans la branche « else »
# ci-dessous, seulement indente de deux espaces. Tel qu'il etait :
# AVANT : [[ -f package.json ]] && {
# AVANT :   run_gate lint      npm run lint      --silent
# AVANT :   run_gate typecheck npm run typecheck --silent
# AVANT :   run_gate test      npm run test      --silent
# AVANT :   run_gate build     npm run build     --silent
# AVANT : }
GATES_CFG="$ROOT/orchestrator/gates.json"
if [[ -f "$GATES_CFG" ]]; then
  GATES_TACHE="$(parse_task "$TASK_ID" | sed -n 's/^gates=//p')"
  [[ -n "$GATES_TACHE" ]] || GATES_TACHE="$(jq -r '.gates | keys_unsorted | join(",")' "$GATES_CFG")"
  IFS=',' read -r -a GATES_DEMANDES <<<"$GATES_TACHE"
  for g in "${GATES_DEMANDES[@]}"; do
    g="${g//[[:space:]]/}"
    [[ -z "$g" ]] && continue
    cmd="$(jq -r --arg g "$g" '.gates[$g] // empty' "$GATES_CFG")"
    if [[ -z "$cmd" ]]; then
      log "gate FAIL: $g (aucune commande dans gates.json)"
      VERDICT="red"
      RAISONS+=("gate:non-configure:$g")
      continue
    fi
    run_gate "$g" bash -c "$cmd"
  done
else
  [[ -f package.json ]] && {
    run_gate lint      npm run lint      --silent
    run_gate typecheck npm run typecheck --silent
    run_gate test      npm run test      --silent
    run_gate build     npm run build     --silent
  }
fi

# Diff sale ou espaces en fin de ligne
git diff --check "$BASE"...HEAD >/dev/null 2>&1 || {
  VERDICT="red"; RAISONS+=("diff:dirty")
}

# --- 2. Quota de diff ----------------------------------------------------
FILES=$(git diff --name-only "$BASE"...HEAD | wc -l | tr -d ' ')
LINES=$(git diff --numstat "$BASE"...HEAD | awk '{a += $1 + $2} END {print a + 0}')

MAX_FILES="${MAX_FILES:-25}"
MAX_LINES="${MAX_LINES:-800}"

if (( FILES == 0 )); then
  VERDICT="red"; RAISONS+=("diff:vide")
fi
VERDICT_AVANT_QUOTA="$VERDICT"
if (( FILES > MAX_FILES || LINES > MAX_LINES )); then
  VERDICT="escalate"
  RAISONS+=("quota:depasse(${FILES}f/${LINES}l)")
fi
# (2026-09-24, O29) Depassement accepte par un humain (« repondre.sh approuver »
# sur une escalade des controles) : honore pour CE travail — run-task.sh retire
# l'acceptation a toute nouvelle session de l'agent — et trace dans le verdict.
# Jamais pour une violation de la doctrine d'ecriture (P13, plus bas). Test EC14.
DEPASSEMENTS_ACCEPTES="$STATE_DIR/$TASK_ID.depassements-acceptes"
if [[ -f "$DEPASSEMENTS_ACCEPTES" ]] && grep -qx quota "$DEPASSEMENTS_ACCEPTES" \
   && (( FILES > MAX_FILES || LINES > MAX_LINES )); then
  RAISONS_SANS_QUOTA=()
  for r in "${RAISONS[@]}"; do [[ "$r" == quota:depasse* ]] || RAISONS_SANS_QUOTA+=("$r"); done
  RAISONS=("${RAISONS_SANS_QUOTA[@]+"${RAISONS_SANS_QUOTA[@]}"}" "quota:accepte-humain")
  VERDICT="$VERDICT_AVANT_QUOTA"
  log "Quota depasse (${FILES}f/${LINES}l) accepte par un humain pour ce travail"
fi

# --- 3. Classification de risque ------------------------------------------
while read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    .env*|*/.env*|*secrets/*|*credentials*|*service-account*) RISK="high"; RAISONS+=("risque:secret:$f") ;;
    */migrations/*|*/migration/*|*schema.prisma|*alembic*)     RISK="high"; RAISONS+=("risque:migration:$f") ;;
    */auth/*|*/acl/*|*/permissions/*|*/security/*)              RISK="high"; RAISONS+=("risque:securite:$f") ;;
    *Dockerfile*|*docker-compose*|.github/*|*infra/*|*terraform/*) RISK="high"; RAISONS+=("risque:infra:$f") ;;
    *package.json|*package-lock.json|*pnpm-lock.yaml|*yarn.lock|*requirements.txt|*poetry.lock|*go.mod|*Cargo.toml) \
      RISK="high"; RAISONS+=("risque:dependance:$f") ;;
    */architecture/*|*/adr/*)                                   RISK="high"; RAISONS+=("risque:architecture:$f") ;;
    # (2026-09-21) Le socle lui-meme : un agent qui modifie gates.json ou
    # skills.json redefinit ses propres controles. Decision humaine.
    orchestrator/*|.claude/*|.githooks/*)                       RISK="high"; RAISONS+=("risque:socle:$f") ;;
  esac
done < <(git diff --name-only "$BASE"...HEAD)

# --- 3 ter. Doctrine d'ecriture (ADR 0002, verrou 3 : detecter apres) --------
# Un fichier critique ou hors perimetre touche malgre le hook (contournement par
# le shell) : P13, derive en L4 — branche fautive en quarantaine (pipeline.sh),
# jamais publiable (publisher.sh), le clone ne repond pas (J2). L'emporte sur des
# controles rouges : une violation n'est pas un simple nouvel essai (P11). Un
# fichier dont une demande a ete approuvee par un humain, et que rien n'a
# retouche depuis, est autorise (empreinte ecrite par repondre.sh). Avant ce
# controle, le perimetre n'etait qu'une phrase de la consigne de l'agent.
PERIMETRE_TACHE="$(parse_task "$TASK_ID" | sed -n 's/^perimetre=//p')"
MERGE_BASE="$(git merge-base "$BASE" HEAD)"
FAUTIFS=()
while IFS= read -r faute; do
  [[ -n "$faute" ]] && FAUTIFS+=("$faute")
done < <(fichiers_fautifs "$WT" "$MERGE_BASE" HEAD "$PERIMETRE_TACHE" "$STATE_DIR/$TASK_ID.demandes-appliquees")
if (( ${#FAUTIFS[@]} > 0 )); then
  VERDICT="escalate"
  RISK="high"
  for faute in "${FAUTIFS[@]}"; do RAISONS+=("P13:$faute"); done
  log "VIOLATION de la doctrine d'ecriture : ${FAUTIFS[*]}"
fi

# Catégories Q3 → escalade systématique
if [[ "$RISK" == "high" && "$VERDICT" == "green" ]]; then
  VERDICT="escalate"
  RAISONS+=("politique:decision-humaine-Q3")
fi
# (2026-09-24, O29) Risque Q3 accepte par un humain pour ce travail : reprise
# vers la revue. Une violation P13 a deja fait escalader plus haut : elle n'est
# jamais couverte (le verdict n'est alors pas vert, la ligne ci-dessus ne joue pas).
if [[ -f "$DEPASSEMENTS_ACCEPTES" ]] && grep -qx risque "$DEPASSEMENTS_ACCEPTES" \
   && [[ "${RAISONS[*]:-}" == *politique:decision-humaine-Q3* ]] && (( ${#FAUTIFS[@]} == 0 )); then
  RAISONS_SANS_Q3=()
  for r in "${RAISONS[@]}"; do [[ "$r" == politique:decision-humaine-Q3 ]] || RAISONS_SANS_Q3+=("$r"); done
  RAISONS=("${RAISONS_SANS_Q3[@]+"${RAISONS_SANS_Q3[@]}"}" "politique:Q3-acceptee-humain")
  VERDICT="green"
  log "Risque Q3 accepte par un humain pour ce travail"
fi

# --- 3 bis. Preuve des tests pour verify-evidence (2026-09-21) ------------
# matrice.json rend l'artefact « tests-hashes » OBLIGATOIRE pour toute tache de
# code, mais aucun script ne l'ecrivait : seul le test F3 le fabriquait a la
# main. Tel que livre, le socle escaladait donc CHAQUE tache de code en
# P8:evidence-manquante, sans jamais atteindre la revue (constate sur le bac a
# sable iziGSM). Le producteur naturel est ici : chaque controle laisse deja une
# sortie brute dont l'empreinte est calculee (run_gate). On publie les preuves
# des controles de TEST seulement (nom commencant par « test ») : un typecheck
# vert ne prouve pas que des tests ont tourne. Aucun controle de test lance =
# aucun fichier, et verify-evidence escalade, comme il se doit.
EV_TESTS="$(printf '%s\n' "${GATES_PROOF[@]+"${GATES_PROOF[@]}"}" \
  | jq -sc 'map(select(.nom | test("^test")))')"
if [[ "$EV_TESTS" != "[]" ]]; then
  mkdir -p "$STATE_DIR/$TASK_ID.evidence"
  printf '%s\n' "$EV_TESTS" >"$STATE_DIR/$TASK_ID.evidence/tests-hashes.json"
fi

# --- 4. Verdict -----------------------------------------------------------
case "$VERDICT" in
  green)    CODE=0 ;;
  red)      CODE=10 ;;
  escalate) CODE=20 ;;
esac

PREUVE_JSON="$(printf '%s\n' "${GATES_PROOF[@]+"${GATES_PROOF[@]}"}" \
  | jq -Rcs --argjson debut "$DEBUT_TS" \
      '{debut_ts:$debut, gates:(split("\n") | map(select(length>0) | fromjson))}')"

jq -n \
  --arg tache "$TASK_ID" \
  --arg verdict "$VERDICT" \
  --arg risque "$RISK" \
  --argjson fichiers "$FILES" \
  --argjson lignes "$LINES" \
  --arg base "$BASE" \
  --argjson preuve "$PREUVE_JSON" \
  --args '{tache:$tache, verdict:$verdict, risque:$risque, fichiers:$fichiers,
           lignes:$lignes, base:$base, raisons:$ARGS.positional, preuve:$preuve}' \
  "${RAISONS[@]+"${RAISONS[@]}"}" >"$ORCH_DIR/state/$TASK_ID.verdict.json"

cat "$ORCH_DIR/state/$TASK_ID.verdict.json"
exit "$CODE"
