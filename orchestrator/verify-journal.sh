#!/usr/bin/env bash
# verify-journal.sh — vérifie la chaîne d'intégrité et l'absence de rature.
set -Eeuo pipefail
JOURNAL="${1:-.orchestrator/journal/decisions.jsonl}"

PREV="0000000000000000000000000000000000000000000000000000000000000000"
N=0; RC=0

while IFS= read -r ligne; do
  N=$((N + 1))
  STOCKED_PREV="$(jq -r '.prev_hash' <<<"$ligne")"
  STOCKED_HASH="$(jq -r '.hash'    <<<"$ligne")"
  RECALC="$(printf '%s' "$(jq -c 'del(.hash)' <<<"$ligne")" | sha256sum | awk '{print $1}')"

  [[ "$STOCKED_PREV" == "$PREV" ]] || {
    echo "RUPTURE ligne $N : prev_hash ne correspond pas"; RC=1; }
  [[ "$STOCKED_HASH" == "$RECALC" ]] || {
    echo "ALTÉRATION ligne $N : hash invalide"; RC=1; }

  PREV="$STOCKED_HASH"
done <"$JOURNAL"

if [[ $RC -eq 0 ]]; then
  echo "OK — $N ligne(s), chaîne intègre"
fi
exit $RC
