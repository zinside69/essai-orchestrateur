#!/usr/bin/env bash
# corriger-couts.sh — ramene au cout de chaque passage les couts cumules ecrits avant O50 (sessions reprises).
# Usage : orchestrator/corriger-couts.sh <dossier-du-projet> [--appliquer]
#         orchestrator/corriger-couts.sh --help
#
# (2026-09-29, O50) Avant O50, journaliser_cout ecrivait total_cost_usd, que Claude
# Code CUMULE sur la session ; l'auteur repris par --resume voyait donc ses passages
# precedents comptes a nouveau (T-004 d'iziGSM : session de 18,19 $, comptee 48,40 $).
# Ce script corrige une fois l'historique d'un projet :
#   - une ligne « auteur » ecrite avant O50 (sans champ session) est un passage
#     repris si son cout depasse celui de la ligne precedente de la meme tache et du
#     meme role, et si la difference correspond, a ecart_prix_max pres, au cout de
#     ses propres tokens au tarif de reference (matrice.json du projet) ;
#   - elle est alors ramenee a cette difference ; l'ancienne valeur est gardee dans
#     cout_cumule_usd, et la ligne porte correction_o50 ;
#   - une ligne deja corrigee, ou ecrite depuis O50, n'est jamais retouchee.
# Sans --appliquer : apercu, rien n'est ecrit. Avec : l'ancien journal est garde
# dans couts.jsonl.avant-o50 (jamais ecrase), puis le journal est reecrit.
# Codes : 0 = apercu ou correction faite ; 1 = erreur ; 2 = refus (tache en cours).
set -Eeuo pipefail
export LC_NUMERIC=C

die()   { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }
refus() { printf '[REFUS] %s\n' "$*" >&2; exit 2; }

APPLIQUER=0
PROJ=""
for arg in "$@"; do
  case "$arg" in
    --appliquer) APPLIQUER=1 ;;
    -h|--help)   sed -n '2,/^set -E/p' "$0" | sed '$d' | sed -E 's/^# ?//'; exit 0 ;;
    -*)          die "option inconnue : $arg" ;;
    *)           [[ -z "$PROJ" ]] || die "un seul dossier de projet"; PROJ="$arg" ;;
  esac
done
[[ -n "$PROJ" && -d "$PROJ" ]] || die "usage : $0 <dossier-du-projet> [--appliquer]"
command -v python3 >/dev/null 2>&1 || die "dependance manquante : python3"
JOURNAL="$PROJ/.orchestrator/journal/couts.jsonl"
MATRICE="$PROJ/orchestrator/matrice.json"
[[ -f "$JOURNAL" ]] || { printf 'Aucun journal de couts : rien a corriger.\n'; exit 0; }
[[ -f "$MATRICE" ]] || die "matrice.json absente : $MATRICE"

# Un pipeline en cours ecrit dans ce journal : ne pas le reecrire sous ses pieds.
en_vol=""
for f in "$PROJ"/.orchestrator/etat/taches/*.env; do
  [[ -f "$f" ]] || continue
  case "$(sed -n 's/^etat=//p' "$f" | head -1)" in
    RUNNING|VERIFIED|REVIEWED) en_vol+=" $(basename "$f" .env)" ;;
  esac
done
[[ -z "$en_vol" ]] || refus "tache(s) en cours :$en_vol — attendre leur fin"

python3 - "$JOURNAL" "$MATRICE" "$APPLIQUER" <<'PY'
import json, os, sys
journal, matrice, appliquer = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
bloc = json.load(open(matrice, encoding='utf-8')).get('couts', {})
prix = bloc.get('prix_reference', {}) or {}
ecart_max = float(bloc.get('ecart_prix_max', 0.15))

def nombre(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0

lignes = [json.loads(l) for l in open(journal, encoding='utf-8') if l.strip()]
cumul, repris = {}, []
avant = sum(nombre(l.get('cout_usd')) for l in lignes)
for l in lignes:
    if l.get('mesure') != 'ok' or l.get('role') != 'auteur' or 'session' in l:
        continue
    cle = (l.get('tache'), l.get('role'))
    if 'cout_cumule_usd' in l:              # deja corrigee : son cumul continue la chaine
        cumul[cle] = nombre(l['cout_cumule_usd'])
        continue
    c, prec, m = nombre(l.get('cout_usd')), cumul.get(cle), l.get('modeles') or []
    if prec is not None and c > prec and len(m) == 1 and m[0] in prix:
        tk = l.get('tokens') or {}
        attendu = sum(nombre(tk.get(k)) * nombre(prix[m[0]].get(k))
                      for k in ('entree', 'cache_lu', 'cache_ecrit', 'sortie')) / 1e6
        diff = c - prec
        if attendu > 0 and abs(diff - attendu) / attendu <= ecart_max:
            repris.append((l.get('tache'), c, diff, attendu))
            l['cout_cumule_usd'] = c
            l['cout_usd'] = round(diff, 6)
            l['correction_o50'] = 'cout cumule de la session ramene au cout du passage'
    cumul[cle] = c

for t, c, d, a in repris:
    print('  %s auteur : %.2f $ -> %.2f $ (tarif de reference : %.2f $)' % (t, c, d, a))
apres = sum(nombre(l.get('cout_usd')) for l in lignes)
print('%d passage(s) repris ; total du journal : %.2f $ -> %.2f $' % (len(repris), avant, apres))
if not appliquer:
    print("Apercu seulement : rien n'est ecrit. Relancer avec --appliquer pour corriger.")
    sys.exit(0)
if not repris:
    sys.exit(0)
garde = journal + '.avant-o50'
if not os.path.exists(garde):
    with open(journal, 'rb') as src, open(garde, 'wb') as dst:
        dst.write(src.read())
tmp = journal + '.tmp'
with open(tmp, 'w', encoding='utf-8', newline='\n') as f:
    for l in lignes:
        f.write(json.dumps(l, ensure_ascii=False, separators=(',', ':')) + '\n')
os.replace(tmp, journal)
print('Journal corrige ; ancien journal garde dans %s' % garde)
PY
