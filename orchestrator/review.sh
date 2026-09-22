#!/usr/bin/env bash
# review.sh — lance le reviewer indépendant et applique les 5 contrôles d'isolation.
# Sortie : state/T-NNN.revue.json  |  code 0 = revue valide, 20 = isolation invalide
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

TASK_ID="${1:?usage: review.sh T-NNN}"
WT="${2:?chemin du worktree}"
BASE="${3:-$INTEGRATION_BRANCH}"
MODELE_AUTEUR="${MODELE_AUTEUR:-sonnet}"

M="$ROOT/orchestrator/matrice.json"
STATE="$STATE_DIR/$TASK_ID"
DIFF="$STATE.diff"
REVUE="$STATE.revue.json"

MODELE_REVIEWER="$(jq -r '.revue.modele_reviewer' "$M")"
AGENT_FILE="$WT/.claude/agents/reviewer-diff.md"

isolation_invalide() {
  jq -n --arg t "$TASK_ID" --arg r "$1" --arg m "$MODELE_REVIEWER" \
    '{schema_version:"2.0", verdict:"desaccord", confiance:1.0,
      modele_reviewer:$m, nature:"mutative",
      rejets:[{code:"V", gravite:"critique", constat:$r}],
      resume:("Revue invalidée : " + $r)}' >"$REVUE"
  log "ISOLATION INVALIDE — $1"
  exit 20
}

# --- V1 : le modèle du reviewer doit différer de celui de l'auteur ---------
[[ "$MODELE_REVIEWER" != "$MODELE_AUTEUR" ]] \
  || isolation_invalide "V1 — reviewer et auteur sur le même modèle ($MODELE_AUTEUR)"

# --- V5 : le subagent ne doit pas être un fork ----------------------------
[[ -f "$AGENT_FILE" ]] || isolation_invalide "V5 — définition du reviewer absente"
grep -qE '^[[:space:]]*fork:[[:space:]]*true' "$AGENT_FILE" \
  && isolation_invalide "V5 — le reviewer est déclaré en mode fork (héritage de conversation)"

# --- V3 : le subagent ne doit pas déclarer d'outil de lecture de session ---
grep -qE 'transcript_path|run-\$?\{?TASK_ID|\.jsonl' "$AGENT_FILE" \
  && isolation_invalide "V3 — la définition du reviewer référence une source de session"

# --- V4 : l'entrée est un fichier de diff, jamais du contenu de session ---
git -C "$WT" diff "$BASE"...HEAD --unified=40 >"$DIFF"
[[ -s "$DIFF" ]] || isolation_invalide "V4 — diff vide, aucune entrée à relire"

# --- Prompt : diff + déclaration de tâche + invariants. Rien d'autre -------
mapfile -t T < <(parse_task "$TASK_ID")

PROMPT="$(cat <<EOF
Relis le diff ci-dessous contre la déclaration de tâche, puis produis ton jugement JSON.

FICHIER DE DIFF : $DIFF
INVARIANTS OPPOSABLES : $WT/.claude/reviewer-invariants.md

DÉCLARATION DE TÂCHE
$(
  for kv in "${T[@]}"; do printf '%s = %s\n' "${kv%%=*}" "${kv#*=}"; done
)

RAPPEL : tu ne connais pas la session qui a produit ce diff et tu ne dois pas chercher
à la reconstituer. Juge uniquement le contenu du diff contre ce qui précède.
Réponds par un objet JSON unique, sans aucun texte autour.
EOF
)"

# (2026-09-21, essai 5 du bac a sable) Le diff est DANS le prompt. La politique
# .claude/settings.json interdit Read(./.orchestrator/state/*.diff) — pour que
# l'agent AUTEUR ne lise ni diffs ni revues — et cette meme politique s'applique
# au relecteur : il ne pouvait pas lire le fichier nomme ci-dessus, et concluait
# « desaccord » faute d'entree. Une seule politique pour deux agents : le diff
# passe donc par le prompt, borne par le quota de gate.sh (MAX_LINES). Le
# fichier reste ecrit : trace, et controle V4 (diff non vide).
PROMPT="$PROMPT

CONTENU INTEGRAL DU DIFF (le fichier nomme plus haut ne t'est pas lisible : le voici)
\`\`\`diff
$(cat "$DIFF")
\`\`\`"

# --- Skill de revue (2026-09-21) --------------------------------------------
# Designe par orchestrator/skills.json. L'outil Skill est autorise pour CE skill
# seulement : sans l'ajout, --allowed-tools le refuserait. Le skill apporte une
# methode de relecture, pas un format : le prompt exige toujours l'objet JSON du
# schema 2.0, et P4 met toute autre sortie en PARK.
OUTILS_REVUE="Read,Grep,Glob"
SKILL_REVUE="$(skill_pour revue "$TASK_ID")"
if [[ -n "$SKILL_REVUE" ]]; then
  OUTILS_REVUE="$OUTILS_REVUE,Skill($SKILL_REVUE)"
  PROMPT="/$SKILL_REVUE $PROMPT"
  log "Skill de revue : $SKILL_REVUE"
fi

# --- V2 : aucun --continue, aucun --resume, aucun transcript ---------------
# (2026-09-21, dd99b98) Outils du relecteur dans OUTILS_REVUE, pour y ajouter le
# skill de revue designe. Ligne d'origine citee ici : un commentaire ne peut pas
# s'inserer entre les lignes continuees (\) de la commande ci-dessous.
# AVANT :   --allowed-tools "Read,Grep,Glob" \
set +e
claude -p "$PROMPT" \
  --agent reviewer-diff \
  --model "$MODELE_REVIEWER" \
  --permission-mode plan \
  --max-turns 12 \
  --output-format json \
  --allowed-tools "$OUTILS_REVUE" \
  >"$STATE.reviewer.json" 2>"$STATE.reviewer.err"
RC=$?
set -e

[[ $RC -eq 0 ]] || isolation_invalide "reviewer en échec (code $RC)"

# --- P4 : validation stricte de la sortie ---------------------------------
jq -e '.result | fromjson | .verdict as $v | (.confiance|type=="number") and
       ($v=="accord" or $v=="reserve" or $v=="desaccord")' \
   "$STATE.reviewer.json" >/dev/null 2>&1 || {
  jq -n --arg t "$TASK_ID" \
    '{schema_version:"2.0", verdict:"desaccord", confiance:0.0, nature:"mutative",
      rejets:[{code:"R0", gravite:"critique",
               constat:"Sortie du reviewer non conforme au schéma 2.0"}],
      resume:"JSON invalide — fail-safe PARK"}' >"$REVUE"
  log "P4 — sortie reviewer non conforme, fail-safe PARK"
  exit 20
}

jq -c '.result | fromjson' "$STATE.reviewer.json" >"$REVUE"

# --- V1 recroisée : le reviewer déclare-t-il bien le modèle attendu ? -----
DECLARE="$(jq -r '.modele_reviewer // "inconnu"' "$REVUE")"
# (2026-09-21, essai 5) La MESURE du harnais fait foi, pas l'affirmation du
# modele sur lui-meme. Le relecteur (reellement Opus : modelUsage = claude-opus-5)
# n'avait pas ecrit « modele_reviewer » : revue invalidee a tort. On lit donc le
# modele reellement utilise dans la sortie de claude (modelUsage) : il doit
# contenir le modele attendu et ne jamais contenir celui de l'auteur. La
# declaration devient facultative ; presente, elle doit concorder.
# AVANT : [[ "$DECLARE" == "$MODELE_REVIEWER" ]] \
# AVANT :   || isolation_invalide "V1 — modèle déclaré ($DECLARE) ≠ modèle attendu ($MODELE_REVIEWER)"
MESURE="$(jq -r '(.modelUsage // {}) | keys | join(",")' "$STATE.reviewer.json")"
[[ -n "$MESURE" && "$MESURE" == *"$MODELE_REVIEWER"* ]] \
  || isolation_invalide "V1 — modèle mesuré (${MESURE:-aucun}) ≠ modèle attendu ($MODELE_REVIEWER)"
[[ "$MESURE" != *"$MODELE_AUTEUR"* ]] \
  || isolation_invalide "V1 — le modèle de l'auteur ($MODELE_AUTEUR) a servi à la revue ($MESURE)"
[[ "$DECLARE" == "inconnu" || "$DECLARE" == "$MODELE_REVIEWER" ]] \
  || isolation_invalide "V1 — modèle déclaré ($DECLARE) ≠ modèle attendu ($MODELE_REVIEWER)"
# La mesure est gardee dans la revue : c'est elle que la trace doit montrer.
jq --arg m "$MESURE" '. + {modele_mesure: $m}' "$REVUE" >"$REVUE.tmp" && mv "$REVUE.tmp" "$REVUE"

log "Revue valide : $(jq -r '.verdict' "$REVUE") (confiance $(jq -r '.confiance' "$REVUE"))"
exit 0
