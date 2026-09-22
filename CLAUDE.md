# CLAUDE.md — essai-orchestrateur

Projet d'essai **jetable** du socle d'orchestration (`zinside69/orchestrateur-claude-code`) :
éprouver la publication — push de la branche d'agent, PR vers `integration`, fusion
automatique après contrôles requis. Aucun code réel, aucune donnée.

## Le projet

- Node ≥ 22, **aucune dépendance**. Tests : `npm run test` (`node --test`), fichiers `tests/*.test.js`.
- Montants en **centimes entiers**, jamais de flottants.
- Commentaires en français, JSDoc sur chaque fonction exportée.

## Règles pour un agent

- Tu travailles dans `src/**` et `tests/**` uniquement.
- Écris le test d'abord et vois-le échouer, puis le code.
- Ne commite pas et ne pousse pas : le harnais s'en charge.
- Ne modifie ni `.claude/**`, ni `.githooks/**`, ni `orchestrator/**`, ni `.github/**`.

_Version 1.0 — 2026-09-22 — création du projet d'essai_
