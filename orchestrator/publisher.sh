#!/usr/bin/env bash
# publisher.sh — pousse la branche et ouvre/merge la PR. Exécuté par le harnais uniquement.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
# (2026-09-24, ADR 0002) Doctrine d'ecriture : fichiers critiques et perimetre.
# shellcheck disable=SC1091
source "$(dirname "$0")/critiques.sh"

TASK_ID="${1:?usage: publisher.sh T-NNN}"
WT="${2:?chemin du worktree}"
DECISION="$STATE_DIR/$TASK_ID.decision.json"
BRANCH="$AGENT_BRANCH_PREFIX/$TASK_ID"

# (2026-09-24, ADR 0002, verrou 3) Jamais publiable : une branche qui touche un
# fichier critique ou hors perimetre, sans demande approuvee par un humain, ne
# part pas — pas meme sur un verdict humain (PUBLICATION_VERDICT_HUMAIN). Controle
# fait AVANT tout le reste, independamment de la decision : dernier verrou si un
# autre chemin avait laisse passer la violation. Test EC4.
FAUTIFS_PUB="$(cd "$WT" && fichiers_fautifs "$WT" "$(git merge-base "$INTEGRATION_BRANCH" HEAD)" HEAD \
  "$(parse_task "$TASK_ID" | sed -n 's/^perimetre=//p')" "$STATE_DIR/$TASK_ID.demandes-appliquees")"
[[ -z "$FAUTIFS_PUB" ]] || die "publication refusee (ADR 0002) : fichier critique ou hors perimetre sans demande approuvee — $(tr '\n' ' ' <<<"$FAUTIFS_PUB")"

require git gh jq

# AVANT : VERDICT="$(jq -r '.verdict' "$DECISION")"
#   (2026-09-23, O22) Une escalade approuvee par un humain alors que le travail
#   est pret se publie en PR A RELIRE (decision de l'operateur : jamais de fusion
#   automatique sur approbation). repondre.sh pose PUBLICATION_VERDICT_HUMAIN ;
#   seule la valeur PR_READY est admise, toute autre arrete la publication.
if [[ -n "${PUBLICATION_VERDICT_HUMAIN:-}" ]]; then
  [[ "$PUBLICATION_VERDICT_HUMAIN" == PR_READY ]] \
    || die "verdict humain refuse : $PUBLICATION_VERDICT_HUMAIN (seul PR_READY est admis)"
  VERDICT="$PUBLICATION_VERDICT_HUMAIN"
else
  VERDICT="$(jq -r '.verdict' "$DECISION")"
fi
REVUE="$(jq -r  '.axe_d_revue.verdict'  "$DECISION")"
RISQUE="$(jq -r '.axe_c_risque'         "$DECISION")"
CONF="$(jq -r   '.axe_d_revue.confiance' "$DECISION")"
RAISONS="$(jq -r '.raisons | join(" · ")' "$DECISION")"

[[ "$VERDICT" == "PARK" ]] && {
  log "PARK — aucune publication. Décision : $DECISION"
  "$ROOT/.claude/hooks/notify-escalade.sh" <<<"$(jq -n \
    --arg s "$TASK_ID" --arg c "$WT" \
    --arg m "PARK sur $TASK_ID : $RAISONS" \
    '{session_id:$s, cwd:$c, message:$m}')"
  exit 20
}

# (2026-09-28, titre de PR vide, PR #7 d'iziGSM) Le titre etait construit sur les
# raisons de la decision : vides pour une PR propre, il donnait « T-002: ». Titre =
# premier titre « # » du fichier de ticket cite par le critere de done, sinon le
# critere lui-meme ; coupe a 80 CARACTERES par jq (jamais « cut -c », qui compte
# des octets : lecon d'O43). Les raisons restent dans le corps de la PR. Test PT1.
CRITERE="$(parse_task "$TASK_ID" | sed -n 's/^critere=//p')"
FICHIER_TICKET="$(grep -oE '[^ ]+\.md' <<<"$CRITERE" | head -1 || true)"
TITRE=""
[[ -n "$FICHIER_TICKET" && -f "$WT/$FICHIER_TICKET" ]] \
  && TITRE="$(sed -n 's/^# //p' "$WT/$FICHIER_TICKET" | head -1)"
[[ -n "$TITRE" ]] || TITRE="${CRITERE:-sans critere}"
TITRE_PR="$TASK_ID: $(jq -rn --arg t "$TITRE" '$t[0:80]')"

# --- Corps de PR : la traçabilité complète de la décision -----------------
BODY="$(mktemp)"
{
  printf '## Tâche %s\n\n' "$TASK_ID"
  printf 'Décision automatique : **%s**\n\n' "$VERDICT"
  printf '| Axe | Valeur |\n|---|---|\n'
  printf '| A — Gates | %s |\n'  "$(jq -r '.axe_a_gates' "$DECISION")"
  printf '| B — Volume | %s fichiers / %s lignes |\n' \
    "$(jq -r '.axe_b_volume.fichiers' "$DECISION")" "$(jq -r '.axe_b_volume.lignes' "$DECISION")"
  printf '| C — Risque | %s |\n' "$RISQUE"
  printf '| D — Revue | %s (confiance %s) |\n' "$REVUE" "$CONF"
  printf '| E — Nature | %s |\n\n' "$(jq -r '.axe_e_nature' "$DECISION")"
  printf '**Règles appliquées** : %s\n\n' "$RAISONS"
  printf '%s\n\n' '---'
  jq -r 'if (.rejets | length) > 0 then
           "### Rejets signalés\n\n" +
           ([.rejets[] | "- `\(.code)` (\(.gravite)) \(.fichier // "—"):\(.ligne // 0) — \(.constat)"] | join("\n"))
         else "Aucun rejet signalé par la revue." end' "$STATE_DIR/$TASK_ID.revue.json"
  printf '\n\n> Revue produite par un modèle distinct (%s) sur un contexte neuf.\n' \
    "$(jq -r '.modele_reviewer' "$STATE_DIR/$TASK_ID.revue.json")"
} >"$BODY"

# --- Push de la branche d'agent (harnais uniquement) ---------------------
cd "$ROOT"
# (2026-09-27, O15) Le push se signale au hook pre-push du projet, qui refuse
# sinon toute branche agent/* des que core.hooksPath est pose. Test HK1.
# AVANT : git push -u origin "$BRANCH"
ORCH_PUBLICATION_HARNAIS=1 git push -u origin "$BRANCH"

# (2026-09-27, O46, premier vrai ticket iziGSM) Les etiquettes des PR (agent,
# auto-merge, draft, revue-humaine) n'etaient creees par personne : sur un depot
# neuf, « gh pr create --label » echouait apres le push (« 'revue-humaine' not
# found »), P9 (T-002, debloque a la main). Le socle cree ses etiquettes
# (« --force » : sans effet si elles existent), comme celles des escalades (O3).
# Un echec se nomme : le plus souvent, le jeton gh n'a pas l'ecriture sur le
# depot. Test PB1.
while IFS='|' read -r nom couleur description; do
  gh label create "$nom" --force --color "$couleur" --description "$description" >/dev/null 2>&1 \
    || die "etiquette de PR « $nom » impossible a creer (droits du jeton gh sur le depot ?)"
done <<'ETIQUETTES'
agent|5319E7|Travail d'un agent du socle d'orchestration
auto-merge|0E8A16|PR fusionnee automatiquement apres les controles requis
draft|BFD4F2|PR en brouillon ouverte par le socle
revue-humaine|FBCA04|PR a relire par un humain avant fusion
ETIQUETTES

# (2026-09-27, O47, premier vrai ticket iziGSM) Une PR deja ouverte pour la
# branche (publication precedente, « republier ») : le push vient de la mettre a
# jour, et « gh pr create » echouait (« a pull request already exists ») =>
# fausse P9. On s'arrete la, publication reussie. La PR existante garde son
# mode : jamais de fusion automatique activee apres coup sur une PR qu'un
# humain relit peut-etre. Test PR1.
if [[ "$(gh pr view "$BRANCH" --json state --jq .state 2>/dev/null || true)" == OPEN ]]; then
  log "PR deja ouverte pour $BRANCH : mise a jour par le push, aucune nouvelle PR"
  rm -f "$BODY"
  exit 0
fi

case "$VERDICT" in
  AUTO_MERGE)
    # AVANT :       --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
    #   (2026-09-28) titre du ticket, voir TITRE_PR plus haut. Test PT1.
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" \
      --title "$TITRE_PR" --body-file "$BODY" \
      --label "agent,auto-merge" >/dev/null
    # La fusion attend les gates requis — jamais un merge immédiat
    gh pr merge "$BRANCH" --squash --auto --delete-branch
    log "PR ouverte vers $INTEGRATION_BRANCH avec auto-merge activé (attente des checks requis)"
    ;;
  PR_DRAFT)
    # AVANT :       --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
    #   (2026-09-28) titre du ticket, voir TITRE_PR plus haut. Test PT1.
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" --draft \
      --title "$TITRE_PR" --body-file "$BODY" \
      --label "agent,draft" >/dev/null
    log "PR en brouillon ouverte vers $INTEGRATION_BRANCH"
    ;;
  PR_READY)
    # AVANT :       --title "$TASK_ID: $RAISONS" --body-file "$BODY" \
    #   (2026-09-28) titre du ticket, voir TITRE_PR plus haut. Test PT1.
    gh pr create --base "$INTEGRATION_BRANCH" --head "$BRANCH" \
      --title "$TITRE_PR" --body-file "$BODY" \
      --label "agent,revue-humaine" >/dev/null
    log "PR prête pour revue humaine — notification requise"
    ;;
esac

rm -f "$BODY"
