#!/usr/bin/env bash
# guard-ecriture.sh — PreToolUse Edit|Write|MultiEdit|NotebookEdit (ADR 0002, verrou 2).
# Refuse, AVANT l'ecriture, tout fichier critique ou hors du perimetre de la tache,
# et dit a l'agent de soumettre une demande d'ecriture. Code 2 : Claude Code bloque
# l'outil et transmet le motif a l'agent (mesure en headless le 2026-09-24).
# Ne vise que les agents : run-task.sh pose ORCH_AGENT_TACHE ; une session humaine
# ou de maintenance du socle n'est pas concernee. run-task.sh passe ce hook par
# --settings depuis le DEPOT PRINCIPAL : la copie du worktree ne compte pas.
set -uo pipefail
[[ -n "${ORCH_AGENT_TACHE:-}" ]] || exit 0

refus() { printf '%s\n' "$1" >&2; exit 2; }

ENTREE="$(cat)"
CHEMIN="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$ENTREE" 2>/dev/null || true)"
[[ -n "$CHEMIN" ]] || refus "Ecriture refusee : chemin illisible (ADR 0002)."
[[ -n "${ORCH_SOCLE:-}" && -n "${ORCH_WT:-}" ]] || refus "Ecriture refusee : contexte du socle absent (ORCH_SOCLE, ORCH_WT)."
# shellcheck source=/dev/null
source "$ORCH_SOCLE/orchestrator/critiques.sh" 2>/dev/null \
  || refus "Ecriture refusee : liste des fichiers critiques illisible (ADR 0002)."
export ORCH_CRITIQUES="${ORCH_CRITIQUES:-$ORCH_SOCLE/orchestrator/fichiers-critiques.json}"
[[ -r "$ORCH_CRITIQUES" ]] || refus "Ecriture refusee : liste des fichiers critiques absente ($ORCH_CRITIQUES) — un humain doit l'installer (ADR 0002)."

case "$CHEMIN" in /*) ;; *) CHEMIN="$PWD/$CHEMIN" ;; esac
ABS="$(realpath -m -- "$CHEMIN")"
WTR="$(realpath -m -- "$ORCH_WT")"
[[ "$ABS" == "$WTR"/* ]] || refus "Ecriture refusee : $CHEMIN est hors de ton dossier de travail."
REL="${ABS#"$WTR"/}"

[[ "$REL" == "$COMPTE_RENDU_AGENT" ]] && exit 0

if est_critique "$REL"; then
  refus "Fichier critique ($REL) : un agent ne l'ecrit jamais (ADR 0002). S'il le faut vraiment, soumets une demande d'ecriture dans $COMPTE_RENDU_AGENT (demandes_ecriture : fichier, besoin, justification, diff exact) et poursuis sans ; un humain decidera."
fi
if ! dans_perimetre "${ORCH_PERIMETRE:-}" "$REL"; then
  refus "Hors perimetre ($REL ; perimetre : ${ORCH_PERIMETRE}) : ecriture refusee (ADR 0002). S'il le faut vraiment, soumets une demande d'ecriture dans $COMPTE_RENDU_AGENT et poursuis sans."
fi
exit 0
