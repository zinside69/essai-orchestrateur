#!/usr/bin/env bash
# repondre.sh — applique une reponse humaine a une escalade, avant ou apres expiration.
# AVANT : # Usage : repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]
# Usage : repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter|republier> [message]
#         repondre.sh --help
#
# (2026-09-22, O11) « republier » : apres une publication ratee (P9), relance
# publisher.sh SEUL, sur la decision deja prise — ni l'agent ni la revue ne
# repartent. Au premier essai GitHub, aucune reponse ne convenait : « approuver »
# relancait l'agent entier (et son cout). Test Y7.
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
# (2026-09-24, ADR 0002) Doctrine d'ecriture : fichiers critiques et perimetre.
# shellcheck disable=SC1091
source "$(dirname "$0")/critiques.sh"

ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"   # comme scheduler.sh et reconcile.sh (decision de la tache)
JOURNAL_ESC_T="$ETAT_DIR/escalades/escalades.jsonl"
DRY_RUN=0
TASK_ID=""
DECISION_H=""
MESSAGE=""
ORIGINE="${RESPONSE_ORIGINE:-humain}"
REGLE="${RESPONSE_REGLE:-}"

show_help() {
  cat <<'EOF'
Usage:
  repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]
  repondre.sh [--dry-run] T-NNN republier
  repondre.sh --help

Applique une decision a une tache PARKED ou BLOCKED et ferme l'escalade ouverte.
« republier » : apres une publication ratee (P9) seulement ; relance la
publication seule, puis PUBLISHED.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
      elif [[ -z "$DECISION_H" ]]; then
        DECISION_H="$1"
      elif [[ -z "$MESSAGE" ]]; then
        MESSAGE="$1"
      else
        MESSAGE+=" $1"
      fi
      shift ;;
  esac
done

# AVANT : [[ -n "$TASK_ID" && -n "$DECISION_H" ]] || die "usage: repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter> [message]"
# AVANT : [[ -n "$TASK_ID" && -n "$DECISION_H" ]] || die "usage: repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter|republier> [message]"
#   (2026-09-24, ADR 0002) nettoyer et relancer : reponses a une violation (P13).
[[ -n "$TASK_ID" && -n "$DECISION_H" ]] || die "usage: repondre.sh [--dry-run] T-NNN <approuver|refuser|modifier|reporter|republier|nettoyer|relancer> [message]"
ENVF="$ETAT_DIR/taches/$TASK_ID.env"
[[ -f "$ENVF" ]] || die "tache inconnue : $TASK_ID"

ETAT_ACTUEL="$(sed -n 's/^etat=//p' "$ENVF" | head -1)"
[[ "$ETAT_ACTUEL" == "PARKED" || "$ETAT_ACTUEL" == "BLOCKED" ]] || die "tache $TASK_ID en etat $ETAT_ACTUEL — aucune escalade ouverte"

# Etat cible selon la decision humaine (transition gardee, Phase 5 / P3-a)
case "$DECISION_H" in
  # AVANT :   approuver) CIBLE="RUNNING" ;;
  #   (2026-09-23, O22) Rien ne reprenait jamais une tache RUNNING apres une
  #   reponse : le planificateur ne lance que READY. Chaque approbation creait une
  #   tache fantome qui occupait une place de parallelisme. Affine plus bas selon
  #   le contexte (relance READY, ou publication PUBLISHED). Test Y9.
  approuver) CIBLE="READY" ;;
  refuser)   CIBLE="FAILED" ;;
  modifier)  CIBLE="READY" ;;
  reporter)  CIBLE="PARKED" ;;
  republier) CIBLE="PUBLISHED" ;;
  nettoyer)  CIBLE="READY" ;;
  relancer)  CIBLE="READY" ;;
  *) die "decision inconnue : $DECISION_H" ;;
esac

# (2026-09-24, ADR 0002) Reponses selon l'escalade ouverte :
#   - violation (P13 : fichier critique ou hors perimetre ecrit malgre tout) :
#     nettoyer | relancer | refuser | reporter — « approuver » est refuse : la
#     branche fautive n'est jamais publiable, pas meme sur decision humaine ;
#   - demande d'ecriture (P12) : approuver = le harnais applique le texte approuve
#     MOT POUR MOT puis reprend sans agent ; refuser = la tache poursuit SANS la
#     modification (et non FAILED). Tests EC4 a EC10.
RAISONS_OUV="$(jq -r --arg t "$TASK_ID" 'select(.tache == $t and .statut == "ouverte") | .raisons' \
  "$JOURNAL_ESC_T" 2>/dev/null | tail -1 || true)"
VIOLATION=0; [[ "$RAISONS_OUV" == *P13:* ]] && VIOLATION=1
DEMANDE_OUV=0; [[ "$RAISONS_OUV" == *P12:* ]] && DEMANDE_OUV=1
if [[ "$DECISION_H" == nettoyer || "$DECISION_H" == relancer ]] && (( VIOLATION == 0 )); then
  die "$DECISION_H : aucune violation de la doctrine d'ecriture (P13) ouverte pour $TASK_ID"
fi
if [[ "$DECISION_H" == approuver ]] && (( VIOLATION == 1 )); then
  die "approuver refuse sur une violation de la doctrine d'ecriture (P13, ADR 0002) : repondre nettoyer, relancer ou refuser"
fi
if [[ "$DECISION_H" == refuser ]] && (( DEMANDE_OUV == 1 )); then
  CIBLE="READY"
fi

# (2026-09-22, O11) « republier » n'a de sens qu'apres une publication ratee :
# l'escalade ouverte de la tache doit porter P9, et la decision prise doit etre
# publiable. Sinon refus, rien ne change.
if [[ "$DECISION_H" == "republier" ]]; then
  jq -e --arg t "$TASK_ID" 'select(.tache == $t and .statut == "ouverte") | select(.raisons | test("P9:"))' \
    "$JOURNAL_ESC_T" >/dev/null 2>&1 \
    || die "republier : aucune publication ratee (P9) ouverte pour $TASK_ID"
  DECISION_F="$STATE_DIR/$TASK_ID.decision.json"
  VERDICT_PRIS="$(jq -r '.verdict // empty' "$DECISION_F" 2>/dev/null || true)"
  [[ "$VERDICT_PRIS" =~ ^(AUTO_MERGE|PR_DRAFT|PR_READY)$ ]] \
    || die "republier : decision publiable introuvable pour $TASK_ID (verdict : ${VERDICT_PRIS:-aucun})"
fi

# (2026-09-23, O22, decision de l'operateur) « approuver » selon le contexte :
#   - escalade SANS travail pret — panne de run-task (P10), controles rouges
#     (P11), preuve manquante (P8) — : la tache est RELANCEE (READY), le
#     planificateur la reprend a sa prochaine passe ;
#   - travail PRET — branche d'agent qui porte des commits, worktree present,
#     escalade prise a la decision (plafond P1, desaccord ou risque M3, ...) — :
#     il est PUBLIE en PR a relire (PR_READY, jamais de fusion automatique),
#     sans relancer l'agent ; echec de publication = escalade maintenue ;
#   - sinon : relance.
MODE_APPROUVER=""
WT_T="$WORKTREE_ROOT/$TASK_ID"
if [[ "$DECISION_H" == "approuver" ]]; then
  RAISONS_OUVERTES="$(jq -r --arg t "$TASK_ID" 'select(.tache == $t and .statut == "ouverte") | .raisons' \
    "$JOURNAL_ESC_T" 2>/dev/null | tail -1 || true)"
  COMMITS_AGENT="$(git -C "$ROOT" rev-list "$INTEGRATION_BRANCH..$AGENT_BRANCH_PREFIX/$TASK_ID" 2>/dev/null || true)"
  # AVANT :   if [[ "$RAISONS_OUVERTES" =~ (^|[^A-Z0-9])P(8|10|11): ]]; then
  #   (2026-09-27, O45) P14 (agent arrete ou coupe) relance aussi : un agent
  #   coupe par max_turns laisse un travail PARTIEL commite, qu'« approuver »
  #   aurait publie sans controles ni revue. Test MT2.
  if [[ "$RAISONS_OUVERTES" =~ (^|[^A-Z0-9])P(8|10|11|14): ]]; then
    MODE_APPROUVER="relancer"
  elif [[ -d "$WT_T" && -n "$COMMITS_AGENT" ]]; then
    MODE_APPROUVER="publier"
    CIBLE="PUBLISHED"
  else
    MODE_APPROUVER="relancer"
  fi
fi

# (2026-09-24, ADR 0002) Une demande d'ecriture ouverte l'emporte sur les autres
# lectures de « approuver » : ni relance de l'agent, ni publication.
if [[ "$DECISION_H" == approuver ]] && (( DEMANDE_OUV == 1 )); then
  MODE_APPROUVER="demande"
  CIBLE="READY"
fi
# (2026-09-24, O29) Escalade prise AUX CONTROLES (quota depasse, risque Q3), sans
# violation ni demande ouverte : « approuver » publiait le travail sans preuve ni
# revue, et sans montrer les demandes d'ecriture en attente (T-002, iziGSM). Il
# accepte desormais le depassement, trace, pour ce travail, et reprend la suite
# normale sans agent : demandes (P12), preuve, revue, decision. Test EC14.
if [[ "$DECISION_H" == approuver ]] && (( VIOLATION == 0 && DEMANDE_OUV == 0 )) \
   && [[ "$RAISONS_OUV" == *quota:depasse* || "$RAISONS_OUV" == *politique:decision-humaine-Q3* ]]; then
  MODE_APPROUVER="controles"
  CIBLE="READY"
fi

# (2026-09-25, ADR 0003 R1) Conception en doute (P15) : aucun travail d'agent
# n'existe encore. « approuver » = l'humain a amende le ticket : relance, et la
# relecture de conception REPASSE (conception.sh ne garde jamais un doute).
# « modifier "consigne" » = l'humain passe outre : marque liee a l'empreinte de
# la declaration (plus bas), la consigne part a l'agent. Tests CO3, CO4.
CONCEPTION_OUV=0; [[ "$RAISONS_OUV" == *P15:* ]] && CONCEPTION_OUV=1
if [[ "$DECISION_H" == approuver ]] && (( CONCEPTION_OUV == 1 )); then
  MODE_APPROUVER="relancer"
  CIBLE="READY"
fi
# (2026-09-25, ADR 0003 R3, O40) Preuve a fournir (P16) : la tache est publiee,
# mise en pause par l'escalade de sa decision. « approuver "vert : ..." » solde
# les preuves avec ce compte rendu et la ramene PUBLISHED, SANS republier ;
# « refuser "sortie" » marque la preuve rouge et rouvre la tache (READY), la
# sortie etant transmise a l'agent comme consigne. Tests PV3, PV4.
PREUVE_OUV=0; [[ "$RAISONS_OUV" == *P16:* ]] && PREUVE_OUV=1
PREUVES_F="$STATE_DIR/$TASK_ID.preuves.json"
if (( PREUVE_OUV == 1 )) && [[ "$DECISION_H" == approuver || "$DECISION_H" == refuser ]]; then
  [[ -n "$MESSAGE" ]] || die "$DECISION_H d'une preuve a fournir (P16) : donner le compte rendu (vert : ..., ou la sortie rouge)"
  if [[ "$DECISION_H" == approuver ]]; then MODE_APPROUVER="preuve"; CIBLE="PUBLISHED"; else CIBLE="READY"; fi
fi

if (( DRY_RUN == 1 )); then
  printf '[DRY-RUN repondre] task=%s decision=%s message=%s etat_avant=%s origine=%s regle=%s\n' \
    "$TASK_ID" "$DECISION_H" "$MESSAGE" "$ETAT_ACTUEL" "$ORIGINE" "$REGLE"
  [[ -z "$MODE_APPROUVER" ]] || printf '[DRY-RUN repondre] approuver => %s (etat cible %s)\n' "$MODE_APPROUVER" "$CIBLE"
  exit 0
fi

if [[ "$MODE_APPROUVER" == "publier" ]]; then
  PUBLICATION_VERDICT_HUMAIN=PR_READY "$ROOT/orchestrator/publisher.sh" "$TASK_ID" "$WT_T" \
    >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 \
    || die "approuver : publication en echec (voir $LOG_DIR/pipeline-$TASK_ID.log) — escalade maintenue"
  log "Travail approuve publie en PR a relire : $TASK_ID"
elif [[ "$MODE_APPROUVER" == "relancer" ]]; then
  log "Approuve sans travail pret : $TASK_ID relancee (READY)"
fi

# --- ADR 0002 : violation (P13) et demande d'ecriture (P12) --------------------
# Le harnais connait exactement les fichiers fautifs : il separe sans modele.
# retirer_fautifs <avec_demandes 0|1> — branche propre = diff de l'agent MOINS
# les fichiers fautifs (remis a leur etat de base) ; la branche fautive reste en
# quarantaine (posee par pipeline.sh). Avec demandes : chaque partie retiree
# devient une demande d'ecriture (diff exact, justification du compte rendu si
# l'agent en avait donne une), que l'humain tranchera (verrou 4).
retirer_fautifs() {
  local avec_demandes="$1" base perim patch f d j tmp
  local -a fautifs excl
  [[ -d "$WT_T" ]] || die "$DECISION_H : worktree $WT_T absent"
  git -C "$ROOT" rev-parse -q --verify "refs/heads/quarantine/$TASK_ID" >/dev/null \
    || git -C "$ROOT" branch "quarantine/$TASK_ID" "$AGENT_BRANCH_PREFIX/$TASK_ID"
  base="$(git -C "$WT_T" merge-base "$INTEGRATION_BRANCH" HEAD)"
  perim="$(parse_task "$TASK_ID" | sed -n 's/^perimetre=//p')"
  mapfile -t fautifs < <(cd "$WT_T" && fichiers_fautifs "$WT_T" "$base" HEAD "$perim" \
    "$STATE_DIR/$TASK_ID.demandes-appliquees" | cut -d: -f2-)
  (( ${#fautifs[@]} > 0 )) || die "$DECISION_H : aucun fichier fautif sur la branche de $TASK_ID"
  if [[ "$avec_demandes" == 1 ]]; then
    tmp="$(mktemp)"; printf '[]\n' >"$tmp"
    for f in "${fautifs[@]}"; do
      d="$(git -C "$WT_T" diff "$base" HEAD -- "$f")"
      j="$(jq -r --arg f "$f" '[(.demandes_ecriture // [])[] | select(.fichier == $f) | .justification] | first // empty' \
        "$STATE_DIR/$TASK_ID.compte-rendu.json" 2>/dev/null || true)"
      jq --arg f "$f" --arg d "$d" --arg j "${j:-aucune : ecrit sans demande, retire par nettoyage}" \
        '. + [{fichier:$f, besoin:"retire par nettoyage (P13)", justification:$j, diff:$d, origine:"nettoyage"}]' \
        "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"
    done
    # Demandes deja deposees par l'agent pour d'autres fichiers : conservees.
    if [[ -s "$STATE_DIR/$TASK_ID.demandes.json" ]]; then
      jq -s '(.[0] | map(.fichier)) as $n | (.[1] | map(select(.fichier as $x | $n | index($x) | not))) + .[0]' \
        "$tmp" "$STATE_DIR/$TASK_ID.demandes.json" >"$tmp.n" && mv "$tmp.n" "$tmp"
    fi
    mv "$tmp" "$STATE_DIR/$TASK_ID.demandes.json"
    rm -f "$STATE_DIR/$TASK_ID.demandes.decision"
  fi
  for f in "${fautifs[@]}"; do excl+=(":(exclude,literal)$f"); done
  patch="$(mktemp)"
  git -C "$WT_T" diff --binary "$base" HEAD -- . "${excl[@]}" >"$patch"
  git -C "$WT_T" reset -q --hard "$base"
  if [[ -s "$patch" ]]; then
    git -C "$WT_T" apply --index "$patch"
    GIT_COMMITTER_NAME=harnais-orchestrateur GIT_COMMITTER_EMAIL=harnais@local \
      git -C "$WT_T" -c user.name="agent-$TASK_ID" -c user.email=agent@local \
      commit -q -m "$TASK_ID: travail de l'agent, fichiers fautifs retires par le harnais (P13, decision humaine)"
  fi
  rm -f "$patch"
  FAUTIFS_RETIRES="${fautifs[*]}"
  log "$TASK_ID : fichiers fautifs retires de la branche (${FAUTIFS_RETIRES}) ; trace en quarantine/$TASK_ID"
}

# appliquer_demandes — texte approuve applique MOT POUR MOT (git apply), sous
# l'identite du harnais ; l'empreinte du diff obtenu est enregistree : gate.sh et
# publisher.sh reconnaissent la modification autorisee tant que rien ne la retouche.
appliquer_demandes() {
  local dem="$STATE_DIR/$TASK_ID.demandes.json" p base f
  local -a fichiers
  [[ -d "$WT_T" ]] || die "approuver : worktree $WT_T absent — escalade maintenue"
  p="$(mktemp)"
  jq -r '.[].diff' "$dem" >"$p"
  git -C "$WT_T" apply --check "$p" 2>>"$LOG_DIR/pipeline-$TASK_ID.log" \
    || die "approuver : une demande ne s'applique pas telle quelle — escalade maintenue ($dem)"
  git -C "$WT_T" apply --index "$p"
  rm -f "$p"
  mapfile -t fichiers < <(jq -r '.[].fichier' "$dem")
  git -C "$WT_T" -c user.name=harnais-orchestrateur -c user.email=harnais@local \
    commit -q -m "$TASK_ID: demande(s) d'ecriture approuvee(s) par un humain, appliquee(s) telle(s) quelle(s) — ${fichiers[*]}"
  base="$(git -C "$WT_T" merge-base "$INTEGRATION_BRANCH" HEAD)"
  for f in "${fichiers[@]}"; do
    printf '%s\t%s\n' "$f" "$(empreinte_diff_fichier "$WT_T" "$base" HEAD "$f")" >>"$STATE_DIR/$TASK_ID.demandes-appliquees"
  done
  printf 'approuvee\n' >"$STATE_DIR/$TASK_ID.demandes.decision"
  log "$TASK_ID : demande(s) approuvee(s) appliquee(s) par le harnais — ${fichiers[*]}"
}

REPRISE_SANS_AGENT=0
FAUTIFS_RETIRES=""
case "$DECISION_H" in
  nettoyer)
    retirer_fautifs 1
    REPRISE_SANS_AGENT=1 ;;
  relancer)
    retirer_fautifs 0
    MESSAGE="Le harnais a retire tes modifications de fichiers interdits (${FAUTIFS_RETIRES}) : fichiers critiques ou hors perimetre (ADR 0002). Refais la tache sans les toucher ; s'il faut vraiment les modifier, soumets une demande d'ecriture motivee (fichier, besoin, justification, diff exact) dans $COMPTE_RENDU_AGENT et poursuis sans. ${MESSAGE}" ;;
  approuver)
    if [[ "$MODE_APPROUVER" == demande ]]; then appliquer_demandes; REPRISE_SANS_AGENT=1; fi ;;
  refuser)
    if (( DEMANDE_OUV == 1 )); then
      printf 'refusee\n' >"$STATE_DIR/$TASK_ID.demandes.decision"
      log "$TASK_ID : demande(s) d'ecriture refusee(s) — la tache poursuit sans"
      REPRISE_SANS_AGENT=1
    fi ;;
esac
if [[ "$MODE_APPROUVER" == controles ]]; then
  {
    [[ "$RAISONS_OUV" == *quota:depasse* ]] && echo quota
    [[ "$RAISONS_OUV" == *politique:decision-humaine-Q3* ]] && echo risque
    true
  } >>"$STATE_DIR/$TASK_ID.depassements-acceptes"
  sort -u -o "$STATE_DIR/$TASK_ID.depassements-acceptes" "$STATE_DIR/$TASK_ID.depassements-acceptes"
  log "$TASK_ID : depassement accepte par l'humain ($(tr '\n' ' ' <"$STATE_DIR/$TASK_ID.depassements-acceptes")) — reprise sans agent vers la revue"
  REPRISE_SANS_AGENT=1
fi

# Publication relancee seule, depuis le worktree de la tache. Nouvel echec :
# la tache reste PARKED et l'escalade ouverte — rien n'est journalise comme resolu.
if [[ "$DECISION_H" == "republier" ]]; then
  "$ROOT/orchestrator/publisher.sh" "$TASK_ID" "$WORKTREE_ROOT/$TASK_ID" >>"$LOG_DIR/pipeline-$TASK_ID.log" 2>&1 \
    || die "republier : publication de nouveau en echec (voir $LOG_DIR/pipeline-$TASK_ID.log) — escalade maintenue"
  log "Publication relancee : $TASK_ID ($VERDICT_PRIS)"
fi

python3 - "$ENVF" "$DECISION_H" "$MESSAGE" <<'PY'
import sys
p, decision, message = sys.argv[1:4]
rows=[]
for line in open(p, encoding='utf-8'):
    if '=' not in line:
        rows.append(line)
        continue
    k, v = line.rstrip('\n').split('=', 1)
    if k == 'etat' or k == 'maj_le':
        rows.append(line)
    elif k == 'blocage':
        rows.append('blocage=none\n' if decision == 'approuver' else line)
    elif k == 'consigne_humaine':
        # AVANT :         if decision == 'modifier':
        #   (2026-09-24, ADR 0002) « relancer » transmet aussi sa consigne a l'agent.
        if decision in ('modifier', 'relancer'):
            rows.append('consigne_humaine=' + message + '\n')
        elif decision == 'reporter' and message:
            rows.append('consigne_humaine=' + message + '\n')
        else:
            rows.append(line)
    else:
        rows.append(line)
open(p,'w',encoding='utf-8').writelines(rows)
PY

# Transition gardee : rc 30 si la machine a etats refuse (Phase 5 / P3-a)
transition_etat "$ENVF" "$CIBLE" repondre

# (2026-09-24, ADR 0002) Le travail est deja sur la branche : pipeline.sh reprend
# aux controles, sans relancer ni payer l'agent (marque a usage unique).
if (( REPRISE_SANS_AGENT == 1 )); then
  grep -qx 'reprise=controles' "$ENVF" || printf 'reprise=controles\n' >>"$ENVF"
fi

# (2026-09-25, ADR 0003 R1) « modifier » sur une conception en doute : l'humain
# passe outre, pour CETTE declaration de tache seulement. Test CO4.
if [[ "$DECISION_H" == modifier ]] && (( CONCEPTION_OUV == 1 )); then
  mkdir -p "$STATE_DIR"
  empreinte_tache "$TASK_ID" >"$STATE_DIR/$TASK_ID.conception-outre"
  log "$TASK_ID : conception en doute — l'humain passe outre (consigne transmise a l'agent)"
fi

# (2026-09-25, ADR 0003 R3) Preuve soldee ou rouge : trace dans preuves.json ; la
# sortie rouge devient la consigne de l'agent. Tests PV3, PV4.
if (( PREUVE_OUV == 1 )) && [[ "$DECISION_H" == approuver || "$DECISION_H" == refuser ]] && [[ -f "$PREUVES_F" ]]; then
  STATUT_PREUVE="soldee"; [[ "$DECISION_H" == refuser ]] && STATUT_PREUVE="rouge"
  jq --arg s "$STATUT_PREUVE" --arg m "$MESSAGE" --arg o "$ORIGINE" --arg ts "$(date -u +%FT%TZ)" \
    'map(if .statut == "a_fournir" then . + {statut:$s, compte_rendu:$m, origine:$o, le:$ts} else . end)' \
    "$PREUVES_F" >"$PREUVES_F.tmp" && mv "$PREUVES_F.tmp" "$PREUVES_F"
  if [[ "$DECISION_H" == refuser ]]; then
    python3 - "$ENVF" "Preuve rouge (compte rendu humain) : $MESSAGE" <<'PY'
import sys
p, consigne = sys.argv[1:3]
rows = [('consigne_humaine=' + consigne + '\n') if l.startswith('consigne_humaine=') else l for l in open(p, encoding='utf-8')]
open(p, 'w', encoding='utf-8').writelines(rows)
PY
  fi
  log "$TASK_ID : preuve(s) $STATUT_PREUVE — $MESSAGE"
fi

# (2026-09-22, Y7) Filtre d'origine cite ici (lignes continuees ci-dessous) :
# AVANT :   '{tache:$t, decision:$d, message:$m, ts:$ts, etat_avant:$av, origine:$origine, regle:($regle|select(length>0))}' \
#   Regle vide (toute reponse HUMAINE) : « select » ne produit rien, et un objet
#   dont une valeur ne produit rien disparait en entier — aucune reponse humaine
#   n'etait journalisee, M07 ne les comptait pas. La cle n'est ajoutee que remplie.
jq -c -n --arg t "$TASK_ID" --arg d "$DECISION_H" --arg m "$MESSAGE" \
  --arg ts "$(date -u +%FT%TZ)" --arg av "$ETAT_ACTUEL" --arg origine "$ORIGINE" --arg regle "$REGLE" \
  '{tache:$t, decision:$d, message:$m, ts:$ts, etat_avant:$av, origine:$origine}
   + (if $regle == "" then {} else {regle:$regle} end)' \
  >>"$ORCH_DIR/journal/reponses.jsonl"

python3 - "$JOURNAL_ESC_T" "$TASK_ID" <<'PY' 2>/dev/null || true
import json, os, sys
p, task = sys.argv[1:3]
if not os.path.exists(p):
    sys.exit(0)
rows = [json.loads(l) for l in open(p, encoding='utf-8') if l.strip()]
for row in reversed(rows):
    if row.get('tache') == task and row.get('statut') == 'ouverte':
        row['statut'] = 'resolue'
        break
with open(p, 'w', encoding='utf-8') as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')
PY
# (2026-09-27, O3 partie 2) L'escalade resolue ferme son issue GitHub. Test GI3.
fermer_issue_escalade "$TASK_ID" resolue "$ETAT_DIR/escalades"

log "Reponse enregistree : $TASK_ID -> $DECISION_H ($ORIGINE)"
