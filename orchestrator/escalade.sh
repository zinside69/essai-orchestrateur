#!/usr/bin/env bash
# escalade.sh — derive le niveau depuis les raisons de decision, notifie, gere l'expiration.
# Usage : escalade.sh [--dry-run] T-NNN <decision.json>
#         escalade.sh [--dry-run] --verifier-expirations
#         escalade.sh --help
set -Eeuo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

# (2026-09-23, O24) Chemin surchargeable : un test pose sa politique dans un dossier
# jetable au lieu de reecrire le vrai escalade.json le temps du test.
# AVANT : E="$ROOT/orchestrator/escalade.json"
E="${ORCH_ESCALADE:-$ROOT/orchestrator/escalade.json}"
ETAT_DIR="$ORCH_DIR/etat"
STATE_DIR="${STATE_DIR:-$ORCH_DIR/state}"
ESC_DIR="$ETAT_DIR/escalades"
JOURNAL_ESC_T="$ESC_DIR/escalades.jsonl"
DRY_RUN=0
MODE="ouvrir"
TASK_ID=""
DECISION=""

show_help() {
  cat <<'EOF'
Usage:
  escalade.sh [--dry-run] T-NNN <decision.json>
  escalade.sh [--dry-run] --verifier-expirations
  escalade.sh --help

Fonctions:
  - dérive un niveau L1..L4 depuis les raisons d'une décision ;
  - journalise l'escalade et notifie les canaux associés ;
  - vérifie les relances et les expirations ;
  - active le disjoncteur global si le seuil L4 est dépassé.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verifier-expirations) MODE="verifier"; shift ;;
    *)
      if [[ -z "$TASK_ID" ]]; then
        TASK_ID="$1"
      elif [[ -z "$DECISION" ]]; then
        DECISION="$1"
      else
        die "argument inattendu : $1"
      fi
      shift ;;
  esac
done

mkdir -p "$ESC_DIR" "$ORCH_DIR/journal" "$STATE_DIR" "$ETAT_DIR/taches"
require jq python3
[[ -f "$E" ]] || die "politique d'escalade absente : $E"

update_escalade_status() {
  local task="$1" nouveau="$2"
  python3 - "$JOURNAL_ESC_T" "$task" "$nouveau" <<'PY'
import json, os, sys
p, task, new_status = sys.argv[1:4]
if not os.path.exists(p):
    sys.exit(0)
rows = [json.loads(l) for l in open(p, encoding='utf-8') if l.strip()]
for row in reversed(rows):
    if row.get('tache') == task and row.get('statut') == 'ouverte':
        row['statut'] = new_status
        break
with open(p, 'w', encoding='utf-8') as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + '\n')
PY
  # (2026-09-27, O3 partie 2) Escalade terminee (expiree, archivee, sans objet) :
  # son issue GitHub se ferme. Test GI2.
  fermer_issue_escalade "$task" "$nouveau" "$ESC_DIR"
}

# notifier_issue <niveau> <T-NNN> <message> — canal github_issue (2026-09-27, O3
# partie 2), generique pour tout projet orchestre. L'issue n'aboutissait jamais :
# l'etiquette escalade-Ln n'existait pas dans le depot. Le socle cree ses deux
# etiquettes (« --force » : sans effet si elles existent), cree l'issue a
# l'OUVERTURE seulement et memorise son URL dans issues.tsv ; une relance ou
# l'avis d'expiration la COMMENTENT (avant : une nouvelle issue a chaque relance).
# gh deduit le depot du dossier courant : il est lance depuis ROOT, le projet.
# Codes : 70 = URL illisible dans la reponse de gh, 71 = aucune issue connue
# pour cette tache (rien a commenter). Tests GI1, GI2.
NOTIF_OUVERTURE=0
notifier_issue() {
  local niveau="$1" tache="$2" message="$3" url
  if [[ "$NOTIF_OUVERTURE" == 1 ]]; then
    ( cd "$ROOT" && gh label create "escalade-$niveau" --force --color B60205 \
        --description "Escalade du socle d'orchestration, niveau $niveau" ) >/dev/null 2>&1 || return $?
    ( cd "$ROOT" && gh label create agent --force --color 5319E7 \
        --description "Travail d'un agent du socle d'orchestration" ) >/dev/null 2>&1 || return $?
    url="$( cd "$ROOT" && gh issue create --title "[$niveau] $tache — decision requise" \
        --body "$message" --label "agent,escalade-$niveau" 2>/dev/null )" || return $?
    url="$(printf '%s\n' "$url" | grep -Eo 'https://[^[:space:]]+/issues/[0-9]+' | tail -1 || true)"
    [[ -n "$url" ]] || return 70
    printf '%s\t%s\n' "$tache" "$url" >>"$ESC_DIR/issues.tsv"
    return 0
  fi
  url="$(issue_de_tache "$tache" "$ESC_DIR")"
  [[ -n "$url" ]] || return 71
  gh issue comment "$url" --body "$message" >/dev/null 2>&1
}

# --- Configuration hors depot (2026-09-20) -----------------------------------
# Une seule source pour ce dont les canaux ont besoin : BREVO_API_KEY,
# ESCALADE_EMAIL, NTFY_TOPIC. Le fichier vit dans ~/, JAMAIS dans un dossier de
# projet, et son nom finit par .env donc les .gitignore l'excluent deja.
#
# Pourquoi un fichier plutot que ~/.bashrc : cron, les timers systemd et
# « wsl -e bash -c » ne chargent aucun profil. Une variable posee dans .bashrc
# serait absente la nuit, au moment ou une escalade L4 s'ouvre sans personne
# devant l'ecran -- c'est-a-dire quand elle compte le plus.
#
# L'environnement garde la priorite : une surcharge ponctuelle reste possible.
ORCHESTRATEUR_ENV="${ORCHESTRATEUR_ENV:-$HOME/.orchestrateur.env}"

lire_var_env() {
  local nom="$1" valeur ligne
  valeur="${!nom:-}"
  if [[ -n "$valeur" ]]; then
    printf '%s' "$valeur"
    return 0
  fi
  [[ -r "$ORCHESTRATEUR_ENV" ]] || return 1
  ligne="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${nom}[[:space:]]*=" "$ORCHESTRATEUR_ENV" 2>/dev/null)" || return 1
  valeur="${ligne#*=}"
  valeur="${valeur#\"}"; valeur="${valeur%\"}"
  valeur="${valeur#\'}"; valeur="${valeur%\'}"
  valeur="$(printf '%s' "$valeur" | tr -d '[:space:]')"
  [[ -n "$valeur" ]] || return 1
  printf '%s' "$valeur"
}

# --- Heure lisible par un humain (2026-09-21) ---------------------------------
# Les journaux restent en UTC. Seul le texte destine a un humain donne l'heure
# locale : un « 12:35Z » recu a 12:35 a Paris se lit comme l'heure de Paris,
# alors que l'escalade expirait a 14:35 (constate sur l'essai du 2026-09-21).
# Fuseau : ESCALADE_TZ (environnement ou ORCHESTRATEUR_ENV), Europe/Paris par
# defaut. Un fuseau inconnu retombe sur UTC et le dit : GNU date prendrait sinon
# UTC en silence, sous le libelle du fuseau demande.
# Les jours sont nommes ici plutot que par %A : aucune locale fr_FR n'est
# garantie, ni sous WSL ni sur le Mac.
heure_humaine() {
  local iso="$1" tz libelle idx
  local -a jours=(lundi mardi mercredi jeudi vendredi samedi dimanche)
  tz="$(lire_var_env ESCALADE_TZ || printf %s Europe/Paris)"
  if [[ "$tz" != "UTC" && ! -f "/usr/share/zoneinfo/$tz" ]]; then
    log "[NOTIF] fuseau inconnu : $tz — heure donnee en UTC"
    tz="UTC"
  fi
  case "$tz" in
    Europe/Paris) libelle="heure de Paris" ;;
    *)            libelle="heure $tz" ;;
  esac
  idx="$(TZ="$tz" date -d "$iso" +%u 2>/dev/null)" || { printf '%s' "$iso"; return 0; }
  printf '%s %s à %s (%s)' "${jours[idx - 1]}" \
    "$(TZ="$tz" date -d "$iso" +%d/%m)" "$(TZ="$tz" date -d "$iso" +%H:%M)" "$libelle"
}

# --- Canal email : envoi reel via l'API Brevo v3 (2026-09-20) -----------------
# Trois regles tenues ici :
#   - la cle ne figure JAMAIS dans le depot : elle vient de l'environnement ou
#     de ORCHESTRATEUR_ENV ;
#   - elle ne passe pas par la ligne de commande, ou « ps » la lirait : elle
#     transite par un fichier de configuration curl en 600, efface aussitot ;
#   - le destinataire vient de ESCALADE_EMAIL. Une adresse personnelle n'a pas
#     sa place dans un depot destine a etre deploye ailleurs.
# Le WAF de Brevo renvoie 403 (Cloudflare 1010) sur un agent utilisateur non
# reconnu : d'ou le -A explicite, constate le 2026-09-20.
BREVO_EXPEDITEUR_EMAIL="${BREVO_EXPEDITEUR_EMAIL:-contact@soteli.fr}"
BREVO_EXPEDITEUR_NOM="${BREVO_EXPEDITEUR_NOM:-SOTELI}"

envoyer_email() {
  local niveau="$1" tache="$2" message="$3"
  local dest cle corps cfg code
  dest="$(lire_var_env ESCALADE_EMAIL)" || dest=""
  if [[ -z "$dest" ]]; then
    log "[NOTIF] email : ESCALADE_EMAIL non defini, aucun destinataire"
    return 65
  fi
  cle="$(lire_var_env BREVO_API_KEY)" || cle=""
  if [[ -z "$cle" ]]; then
    log "[NOTIF] email : cle Brevo introuvable (BREVO_API_KEY ou $ORCHESTRATEUR_ENV)"
    return 66
  fi

  corps="$(jq -nc --arg se "$BREVO_EXPEDITEUR_EMAIL" --arg sn "$BREVO_EXPEDITEUR_NOM" \
    --arg to "$dest" --arg suj "[$niveau] $tache — decision requise" --arg txt "$message" \
    '{sender:{email:$se,name:$sn},to:[{email:$to}],subject:$suj,textContent:$txt}')"

  cfg="$(mktemp)"
  chmod 600 "$cfg"
  printf 'header = "api-key: %s"\n' "$cle" >"$cfg"
  code="$(printf '%s' "$corps" | curl -sS -o /dev/null -w '%{http_code}' \
    -X POST 'https://api.brevo.com/v3/smtp/email' \
    -A 'orchestrateur-socle/1.0' \
    -K "$cfg" \
    -H 'content-type: application/json' -H 'accept: application/json' \
    --data-binary @- 2>/dev/null)" || { rm -f "$cfg"; log "[NOTIF] email : appel curl en echec"; return 67; }
  rm -f "$cfg"

  case "$code" in
    2*) return 0 ;;
    *)  log "[NOTIF] email : Brevo a repondu HTTP ${code:-aucun}"; return 68 ;;
  esac
}
notifier() {
  local niveau="$1" tache="$2" message="$3"
  local c rc statut prio
  local tentes=0 reussis=0
  local JN="$ORCH_DIR/journal/notifications.jsonl"

  while read -r c; do
    [[ -z "$c" ]] && continue
    if (( DRY_RUN == 1 )); then
      printf '[DRY-RUN notify:%s] [%s] %s\n%s\n' "$c" "$niveau" "$tache" "$message"
      continue
    fi
    # (2026-09-27, O3 partie 2) Projet sans remote : github_issue n'a nulle part ou
    # aller. Ni tentative ni echec (M17 ne le compte pas) : une ligne « ignore ».
    # Un projet sans remote est un cas voulu (bac a sable, O4). Test GI4.
    if [[ "$c" == github_issue ]] && ! git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
      log "[NOTIF] github_issue : pas de remote origin dans $ROOT, canal ignore"
      jq -nc --arg ts "$(date -u +%FT%TZ)" --arg t "$tache" --arg n "$niveau" \
        '{ts:$ts,tache:$t,niveau:$n,canal:"github_issue",statut:"ignore",code:0}' >>"$JN"
      continue
    fi

    # (2026-09-20) Les branches finissaient en « || true » avec la sortie supprimee :
    # un gh non authentifie et un gh reussi etaient indistinguables, et une escalade
    # L4 qui n'avait prevenu personne se journalisait comme une qui avait prevenu.
    # Le « || true » est remplace par une capture dans rc, journalisee ensuite.
    # Une notification en echec ne doit toujours PAS faire echouer l'escalade.
    tentes=$((tentes + 1))
    rc=0
    case "$c" in
      digest)
        printf '%s\t%s\t%s\tDIGEST\t%s\n' "$(date -u +%FT%TZ)" "$niveau" "$tache" "$message" \
          >>"$ORCH_DIR/journal/digest.tsv" || rc=$? ;;
      push|push_prioritaire)
        prio="default"
        [[ "$c" == "push_prioritaire" ]] && prio="high"
        # (2026-09-22) Boutons de reponse (ACTIONS_NTFY, pose par ouvrir_escalade)
        # quand il y en a. Ligne d'origine, avant l'en-tete « Actions » :
        # AVANT :         curl -sS -H "Title: [$niveau] $tache" -H "Priority: $prio" -H "Tags: robot" \
        # AVANT :         local boutons=()
        # AVANT :         [[ -n "${ACTIONS_NTFY:-}" ]] && boutons=(-H "Actions: $ACTIONS_NTFY")
        # AVANT :         curl -sS -H "Title: [$niveau] $tache" -H "Priority: $prio" -H "Tags: robot" "${boutons[@]}" \
        # AVANT :           -d "$message" "https://ntfy.sh/$(lire_var_env NTFY_TOPIC || printf %s mon-projet-agents)" >/dev/null 2>&1 || rc=$? ;;
        #   (2026-09-23, defaut 46) le sujet d'alerte (URL) et le jeton (en-tete
        #   Actions) se lisaient dans `ps` le temps de l'appel : tous deux passent
        #   par curl_prive (fichier -K en 600). Le message reste en argument : il ne
        #   contient ni sujet ni jeton. Test K9.
        local boutons=()
        [[ -n "${ACTIONS_NTFY:-}" ]] && boutons=("Actions: $ACTIONS_NTFY")
        # AVANT :         curl_prive "https://ntfy.sh/$(lire_var_env NTFY_TOPIC || printf %s mon-projet-agents)" "${boutons[@]}" -- \
        # AVANT :           -sS -H "Title: [$niveau] $tache" -H "Priority: $prio" -H "Tags: robot" -d "$message" >/dev/null 2>&1 || rc=$? ;;
        #   (2026-09-23, O19) sans NTFY_TOPIC, repli sur « mon-projet-agents » : un
        #   sujet public au nom generique, ou toute alerte partait, lisible par qui
        #   s'y abonne. Plus de repli : le canal echoue (68), journalise et compte
        #   par M17, sans aucun appel reseau. Test K11.
        local sujet_alerte
        sujet_alerte="$(lire_var_env NTFY_TOPIC)" || sujet_alerte=""
        if [[ -z "$sujet_alerte" ]]; then
          log "[NOTIF] $c : NTFY_TOPIC non configure ($ORCHESTRATEUR_ENV), rien envoye"
          rc=68
        else
          curl_prive "https://ntfy.sh/$sujet_alerte" "${boutons[@]}" -- \
            -sS -H "Title: [$niveau] $tache" -H "Priority: $prio" -H "Tags: robot" -d "$message" >/dev/null 2>&1 || rc=$?
        fi ;;
      github_issue)
        # (2026-09-27, O3 partie 2) AVANT :
        # gh issue create --title "[$niveau] $tache — decision requise" \
        #   --body "$message" --label "agent,escalade-$niveau" >/dev/null 2>&1 || rc=$? ;;
        notifier_issue "$niveau" "$tache" "$message" || rc=$? ;;
      github_ready)
        gh pr ready "$tache" >/dev/null 2>&1 || rc=$? ;;
      commentaire_pr)
        gh pr comment "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo integration)" \
          --body "$message" >/dev/null 2>&1 || rc=$? ;;
      email)
        envoyer_email "$niveau" "$tache" "$message" || rc=$? ;;
      journal_email)
        printf '%s\t%s\t%s\n' "$niveau" "$tache" "$message" \
          >>"$ORCH_DIR/journal/emails.tsv" || rc=$? ;;
      *)
        # Canal declare dans escalade.json mais sans implementation : un silence
        # serait pris pour un succes. On le compte comme un echec explicite.
        rc=64 ;;
    esac

    if (( rc == 0 )); then
      statut="ok"
      reussis=$((reussis + 1))
    else
      statut="echec"
      log "[NOTIF] canal $c en echec (code $rc) pour $tache"
    fi
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg t "$tache" --arg n "$niveau" \
      --arg c "$c" --arg s "$statut" --argjson code "$rc" \
      '{ts:$ts,tache:$t,niveau:$n,canal:$c,statut:$s,code:$code}' >>"$JN"
  done < <(jq -r --arg n "$niveau" '.niveaux[$n].canaux[]' "$E")

  # Invariant : une escalade dont AUCUN canal n'a abouti ne doit pas passer
  # inapercue. On ne fait pas echouer le script pour autant : une escalade doit
  # survivre a une panne de notification, mais elle ne doit pas la taire.
  if (( DRY_RUN == 0 && tentes > 0 && reussis == 0 )); then
    log "[ALERTE] $tache ($niveau) : AUCUN canal n'a abouti sur $tentes tente(s) — personne n'a ete prevenu"
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg t "$tache" --arg n "$niveau" --argjson k "$tentes" \
      '{ts:$ts,tache:$t,niveau:$n,canal:"-",statut:"aucun_canal_abouti",code:$k}' >>"$JN"
  fi
}

derive_niveau() {
  local raisons="$1" n motif
  for n in L4 L3 L2 L1; do
    while read -r motif; do
      [[ -z "$motif" ]] && continue
      if grep -qF "${motif%\*}" <<<"$raisons"; then
        printf '%s\n' "$n"
        return 0
      fi
    done < <(jq -r --arg n "$n" '.derivation[$n][]' "$E")
  done
  printf 'L3\n'
}

ouvrir_escalade() {
  [[ -n "$TASK_ID" && -n "$DECISION" ]] || die "usage: escalade.sh [--dry-run] T-NNN <decision.json>"
  [[ -f "$DECISION" ]] || die "decision absente : $DECISION"

  local raisons niveau delai defaut expiration message relances
  raisons="$(jq -r '.raisons | join(" ")' "$DECISION")"
  niveau="$(derive_niveau "$raisons")"
  delai="$(jq -r --arg n "$niveau" '.niveaux[$n].delai_heures' "$E")"
  defaut="$(jq -r --arg n "$niveau" '.niveaux[$n].defaut' "$E")"
  expiration="$(date -u -d "+${delai} hours" +%FT%TZ)"
  relances="$(jq -c --arg n "$niveau" '.niveaux[$n].relances' "$E")"

  # (2026-09-21, 58b3d20) Echeance a l'heure locale PUIS en UTC : « 12:35Z »
  # recu a 12:35 se lisait heure de Paris alors que l'escalade expirait a 14:35.
  # La ligne d'origine est citee ici : un commentaire place DANS la chaine
  # ci-dessous s'afficherait dans le message envoye.
  # AVANT : Expiration : $expiration"
  message="Tache $TASK_ID — niveau $niveau
Raisons : $raisons
Defaut si pas de reponse : $defaut
Expiration : $(heure_humaine "$expiration")
             $expiration"
  # (2026-09-22, defaut 12) Detail facultatif de la decision : la conclusion de
  # l'agent pour une tache RED (« fusionner T-001 dans integration »). Sans elle,
  # l'humain recevait un code (P11) sans savoir quoi faire.
  local detail
  detail="$(jq -r '.detail // empty' "$DECISION" 2>/dev/null || true)"
  # (2026-09-25, O35) Libelle selon la raison : les demandes d'ecriture (P12) et
  # la violation (P13) n'etaient pas la conclusion de l'agent. Ligne d'origine :
  # AVANT : Conclusion de l'agent : $detail"
  local libelle_detail="Conclusion de l'agent"
  [[ "$raisons" == *"P12:"* ]] && libelle_detail="Demandes d'ecriture"
  [[ "$raisons" == *"P13:"* ]] && libelle_detail="Violation de la doctrine d'ecriture"
  [[ "$raisons" == *"P4:"* ]] && libelle_detail="Revue croisee"   # (2026-09-25, O30) sortie du relecteur, pas de l'agent
  [[ "$raisons" == *"P14:arret-conception"* ]] && libelle_detail="Conception mise en cause par l agent (amender le ticket puis approuver, ou modifier \"ta decision\")"   # (2026-09-25, ADR 0003 R2)
  [[ "$raisons" == *"P16:"* ]] && libelle_detail="Preuve a fournir (jouer puis : approuver \"vert : ...\" ou refuser \"sortie rouge\")"   # (2026-09-25, ADR 0003 R3)
  [[ "$raisons" == *"P15:"* ]] && libelle_detail="Conception en doute (amender le ticket puis approuver, ou modifier \"consigne\" pour passer outre)"   # (2026-09-25, ADR 0003 R1)
  if [[ -n "$detail" ]]; then
    message="$message
$libelle_detail : $detail"
  fi
  # (2026-09-22, demande de l'operateur : « quelle action dois-je faire ? ») La
  # ligne a copier, avec le numero de la tache et la reponse adaptee : republier
  # apres une publication ratee (P9), le choix des quatre reponses sinon. Rien
  # pour L1 : une information n'attend pas de reponse. Test K6.
  if [[ "$niveau" != "L1" ]]; then
    local reponse="<approuver|refuser|modifier|reporter>"
    [[ "$raisons" == *"P9:"* ]] && reponse="republier"
    message="$message
Repondre : cd $ROOT && ./orchestrator/repondre.sh $TASK_ID $reponse"
  fi
  # (2026-09-23, O25, decision de l'operateur) Le clone decisionnel SUGGERE, il ne
  # repond pas : si une regle de l'answer-book couvre ces raisons, l'alerte le dit
  # et l'escalade garde la suggestion (a comparer plus tard a la reponse humaine).
  # L'humain decide toujours. Rien pour L1 ni L4 (answer.sh refuse L4). Tests K17, K18.
  local suggestion="" sugg_regle="" sugg_decision=""
  if [[ "$niveau" != "L1" ]]; then
    suggestion="$("$ROOT/orchestrator/answer.sh" --suggerer "$TASK_ID" "$raisons" "$niveau" 2>/dev/null || true)"
    read -r sugg_regle sugg_decision <<<"$suggestion" || true
    if [[ -n "$sugg_regle" && -n "$sugg_decision" ]]; then
      message="$message
Suggestion du clone : $sugg_decision (regle $sugg_regle) — a confirmer, rien n'est applique"
    fi
  fi
  # (2026-09-25, O34) Demande d'ecriture (P12) : « Approuver » fait ecrire le
  # diff mot pour mot, il n'est donc propose a distance que si la notification
  # montre TOUT le message. Au-dela de la limite ntfy (4 096 octets, marge
  # gardee), seul « Refuser » reste : on approuve depuis le PC, apres lecture du
  # fichier des demandes (l'e-mail L3 porte aussi le message entier). Test EP3.
  local p12_illisible=0
  if [[ "$raisons" == *"P12:"* ]] && (( $(printf '%s' "$message" | wc -c) > 4000 )); then
    p12_illisible=1
    message="$message
Diff trop long pour une notification : lire $STATE_DIR/$TASK_ID.demandes.json sur le PC avant d'approuver (repondre.sh). Refuser reste possible d'ici."
  fi
  # (2026-09-22, reponse depuis le telephone) Boutons ntfy, seulement si le sujet
  # de REPONSE est configure (NTFY_TOPIC_REPONSE, opt-in) et hors L1. Jeton de
  # 128 bits a usage unique, range avec l'escalade : ecouteur.sh n'execute un
  # bouton que s'il porte le jeton d'une escalade ouverte et non expiree de cette
  # tache. Qui lit la notification peut appuyer : le secret est le nom du sujet.
  # Les relances n'ont pas de boutons. Tests K7, K8, B1 a B5.
  local jeton="" sujet_rep=""
  ACTIONS_NTFY=""
  if [[ "$niveau" != "L1" ]] && sujet_rep="$(lire_var_env NTFY_TOPIC_REPONSE)"; then
    jeton="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if [[ "$raisons" == *"P9:"* ]]; then
      ACTIONS_NTFY="$(actions_ntfy "$TASK_ID" "$jeton" "$sujet_rep" republier reporter)"
    # (2026-09-23, O22, decision de l'operateur) Sans travail pret — panne P10,
    # controles rouges P11, preuve manquante P8 — « approuver » relance la tache :
    # le bouton le dit. Test K13.
    elif [[ "$raisons" =~ (^|[^A-Z0-9])P(8|10|11): ]]; then
      ACTIONS_NTFY="$(actions_ntfy "$TASK_ID" "$jeton" "$sujet_rep" approuver:Relancer refuser)"
    # (2026-09-25, ADR 0003 R1) Conception en doute : « approuver » fait relire
    # le ticket (amende par l'humain), le bouton le dit. Passer outre exige un
    # texte (« modifier ») : pas de bouton. Test CO2.
    elif [[ "$raisons" == *"P15:"* ]]; then
      ACTIONS_NTFY="$(actions_ntfy "$TASK_ID" "$jeton" "$sujet_rep" approuver:Relire refuser)"
    # (2026-09-25, ADR 0003 R3) Preuve a fournir : elle se solde avec un compte
    # rendu ecrit (vert, ou la sortie rouge) — aucun bouton, repondre depuis le PC.
    elif [[ "$raisons" == *"P16:"* ]]; then
      ACTIONS_NTFY=""
    # (2026-09-25, O34) Diff des demandes non montrable en entier : pas
    # d'approbation a distance d'un texte non lu. Test EP3.
    elif (( p12_illisible == 1 )); then
      ACTIONS_NTFY="$(actions_ntfy "$TASK_ID" "$jeton" "$sujet_rep" refuser)"
    else
      ACTIONS_NTFY="$(actions_ntfy "$TASK_ID" "$jeton" "$sujet_rep" approuver refuser)"
    fi
  fi
  # AVANT : notifier "$niveau" "$TASK_ID" "$message"
  # (2026-09-27, O3 partie 2) Seule l'ouverture cree une issue GitHub.
  NOTIF_OUVERTURE=1
  notifier "$niveau" "$TASK_ID" "$message"
  NOTIF_OUVERTURE=0

  # (2026-09-22) Filtre d'origine cite ici (lignes continuees ci-dessous), avant
  # l'ajout du jeton :
  # AVANT :     '{tache:$t, niveau:$n, ouvert_le:$ts, expire_le:$exp, relances_prevues:$rel,
  # AVANT :       relances_envoyees:0, defaut:$d, raisons:$r, statut:"ouverte"}' >>"$JOURNAL_ESC_T"
  # (2026-09-23, O25) Filtre avant la suggestion du clone, cite ici :
  # AVANT :   jq -c -n --arg t "$TASK_ID" --arg n "$niveau" --arg ts "$(date -u +%FT%TZ)" \
  # AVANT :     --arg exp "$expiration" --arg d "$defaut" --arg r "$raisons" --argjson rel "$relances" \
  # AVANT :     --arg j "$jeton" \
  # AVANT :      + (if $j == "" then {} else {jeton:$j} end)' >>"$JOURNAL_ESC_T"
  # (2026-09-25, O34) Filtre avant l'interdiction d'approuver a distance, cite ici :
  # AVANT :     --arg j "$jeton" --arg sr "$sugg_regle" --arg sd "$sugg_decision" \
  # AVANT :      + (if $sr == "" then {} else {suggestion:{regle:$sr, decision:$sd}} end)' >>"$JOURNAL_ESC_T"
  jq -c -n --arg t "$TASK_ID" --arg n "$niveau" --arg ts "$(date -u +%FT%TZ)" \
    --arg exp "$expiration" --arg d "$defaut" --arg r "$raisons" --argjson rel "$relances" \
    --arg j "$jeton" --arg sr "$sugg_regle" --arg sd "$sugg_decision" --arg il "$p12_illisible" \
    '{tache:$t, niveau:$n, ouvert_le:$ts, expire_le:$exp, relances_prevues:$rel,
      relances_envoyees:0, defaut:$d, raisons:$r, statut:"ouverte"}
     + (if $j == "" then {} else {jeton:$j} end)
     + (if $sr == "" then {} else {suggestion:{regle:$sr, decision:$sd}} end)
     + (if $il == "1" then {approbation_distante:false} else {} end)' >>"$JOURNAL_ESC_T"

  # AVANT : if [[ -f "$ETAT_DIR/taches/$TASK_ID.env" && $DRY_RUN -eq 0 ]]; then
  #   (2026-09-22, essai de publication GitHub, defaut 8) Toute escalade ouverte
  #   mettait la tache en PARKED — y compris L1, simple information qui suit un
  #   AUTO_MERGE reussi (defaut « archiver »). Une tache publiee finissait donc
  #   PARKED au lieu de PUBLISHED : reconcile.sh ne la passait jamais DONE et ses
  #   dependantes ne partaient jamais. L1 n'attend aucune reponse : elle ne
  #   suspend rien. Test Y2.
  if [[ -f "$ETAT_DIR/taches/$TASK_ID.env" && $DRY_RUN -eq 0 && "$niveau" != "L1" ]]; then
    python3 - "$ETAT_DIR/taches/$TASK_ID.env" <<'PY'
import sys
p=sys.argv[1]
rows=[]
for line in open(p, encoding='utf-8'):
    if line.startswith('etat='):
        rows.append('etat=PARKED\n')
    else:
        rows.append(line)
open(p,'w',encoding='utf-8').writelines(rows)
PY
  fi
  log "Escalade $niveau ouverte sur $TASK_ID — expiration $expiration (defaut: $defaut)"
}

verifier_expirations() {
  local maintenant max_l4 fenetre n_l4
  maintenant="$(date -u +%s)"
  [[ -f "$JOURNAL_ESC_T" ]] || { log "Aucune escalade ouverte"; return 0; }
  # (2026-09-23) La boucle lit un INSTANTANE : update_escalade_status reecrit
  # escalades.jsonl en cours de lecture, et la lecture suivante tombait au milieu
  # du nouveau contenu (jq en erreur, sortie rc=5 sous set -e). Des la premiere
  # escalade modifiee, les suivantes n'etaient jamais traitees et le disjoncteur
  # L4, en fin de fonction, jamais evalue.
  local instantane
  instantane="$(mktemp)"
  cp "$JOURNAL_ESC_T" "$instantane"

  while IFS= read -r ligne; do
    local statut tache niveau expire ouvert ts_exp ts_ouv ecoule_h defaut quarantaine
    statut="$(jq -r '.statut' <<<"$ligne")"
    [[ "$statut" == "ouverte" ]] || continue
    tache="$(jq -r '.tache' <<<"$ligne")"
    niveau="$(jq -r '.niveau' <<<"$ligne")"
    expire="$(jq -r '.expire_le' <<<"$ligne")"
    ouvert="$(jq -r '.ouvert_le' <<<"$ligne")"

    # (2026-09-23, O20) Une tache terminee (DONE) ou publiee (PUBLISHED) ne se
    # touche plus : l'escalade restee ouverte passe « sans_objet », sans relance,
    # sans BLOCKED, sans quarantaine ni alerte L4. Avant, l'expiration forcait
    # etat=BLOCKED quel que soit l'etat : T-001 du projet d'essai serait passee de
    # DONE a BLOCKED, sa branche renommee en quarantine/.
    local etat_tache=""
    [[ -f "$ETAT_DIR/taches/$tache.env" ]] && \
      etat_tache="$(sed -n 's/^etat=//p' "$ETAT_DIR/taches/$tache.env" | head -1)"
    if [[ "$etat_tache" == "DONE" || "$etat_tache" == "PUBLISHED" ]]; then
      # Trace = le statut dans escalades.jsonl ; rien dans refus.jsonl, qui
      # alimente M08 (taux de refus) : une escalade sans objet n'est pas un refus.
      (( DRY_RUN == 1 )) || update_escalade_status "$tache" "sans_objet"
      log "$niveau $tache : escalade sans objet (tache $etat_tache), ni relance ni expiration"
      continue
    fi

    ts_exp="$(date -u -d "$expire" +%s 2>/dev/null || echo 0)"
    ts_ouv="$(date -u -d "$ouvert" +%s 2>/dev/null || echo 0)"
    ecoule_h="$(awk -v a="$maintenant" -v b="$ts_ouv" 'BEGIN{print (a-b)/3600}')"

    while read -r h; do
      [[ -z "$h" ]] && continue
      local marqueur="$ESC_DIR/relance-$tache-$h"
      if awk -v e="$ecoule_h" -v h="$h" 'BEGIN{exit !(e >= h)}'; then
        if [[ ! -f "$marqueur" ]]; then
          # (2026-09-21, 58b3d20) La relance ne donnait aucune echeance : elle
          # dit desormais quand l'escalade expire, a l'heure locale.
          # AVANT : notifier "$niveau" "$tache" "[RELANCE] Tache $tache — niveau $niveau en attente"
          notifier "$niveau" "$tache" "[RELANCE] Tache $tache — niveau $niveau en attente, expire $(heure_humaine "$expire")"
          (( DRY_RUN == 1 )) || : >"$marqueur"
        fi
      fi
    done < <(jq -r --arg n "$niveau" '.niveaux[$n].relances[]?' "$E")

    if (( ts_exp > 0 && maintenant >= ts_exp )); then
      defaut="$(jq -r '.defaut' <<<"$ligne")"
      quarantaine="$(jq -r --arg n "$niveau" '.niveaux[$n].quarantaine // false' "$E")"
      case "$defaut" in
        archiver)
          (( DRY_RUN == 1 )) || update_escalade_status "$tache" "archivee"
          log "L1 $tache : archivee sans action (defaut information)" ;;
        geler|geler_renforce|refus_enregistre)
          (( DRY_RUN == 1 )) || update_escalade_status "$tache" "expiree"
          if [[ -f "$ETAT_DIR/taches/$tache.env" && $DRY_RUN -eq 0 ]]; then
            python3 - "$ETAT_DIR/taches/$tache.env" <<'PY'
import sys
p=sys.argv[1]
rows=[]
for line in open(p, encoding='utf-8'):
    if line.startswith('etat='):
        rows.append('etat=BLOCKED\n')
    else:
        rows.append(line)
open(p,'w',encoding='utf-8').writelines(rows)
PY
          fi
          (( DRY_RUN == 1 )) || jq -c -n --arg t "$tache" --arg n "$niveau" --arg d "$defaut" \
            --arg ts "$(date -u +%FT%TZ)" \
            '{tache:$t, niveau:$n, defaut:$d, ts:$ts, issue:"block_default_deny"}' \
            >>"$ORCH_DIR/journal/refus.jsonl"
          if [[ "$quarantaine" == "true" ]]; then
            if (( DRY_RUN == 1 )); then
              printf '[DRY-RUN quarantine] agent/%s -> quarantine/%s\n' "$tache" "$tache"
            else
              git -C "$ROOT" branch -m "agent/$tache" "quarantine/$tache" 2>/dev/null || true
            fi
          fi
          notifier "L4" "$tache" "[EXPIRATION] $tache : silence converti en refus ($defaut)"
          log "$niveau $tache : EXPIRATION — $defaut. Etat BLOCKED." ;;
      esac
    fi
  # AVANT :   done <"$JOURNAL_ESC_T"
  done <"$instantane"
  rm -f "$instantane"

  max_l4="$(jq -r '.disjoncteur.max_l4_non_resolues' "$E")"
  fenetre="$(jq -r '.disjoncteur.fenetre_l4_heures' "$E")"
  n_l4="$(jq -s --arg iso "$(date -u -d "-${fenetre} hours" +%FT%TZ)" \
    '[.[] | select(.niveau=="L4" and .statut=="ouverte" and .ouvert_le > $iso)] | length' \
    "$JOURNAL_ESC_T" 2>/dev/null || echo 0)"
  if (( n_l4 >= max_l4 )); then
    if (( DRY_RUN == 1 )); then
      printf '[DRY-RUN circuit-breaker] PAUSE\n'
    else
      printf 'PAUSE\n' >"$STATE_DIR/planificateur"
    fi
    notifier "L4" "-" "DISJONCTEUR DECLENCHE — $n_l4 escalades critiques non resolues. Pipeline en PAUSE."
    log "DISJONCTEUR : $n_l4 escalades L4 non resolues — planificateur en PAUSE"
  fi
  log "Verification d'expiration terminee."
}

case "$MODE" in
  ouvrir) ouvrir_escalade ;;
  verifier) verifier_expirations ;;
  *) die "mode inconnu : $MODE" ;;
esac
