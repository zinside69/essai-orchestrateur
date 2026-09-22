# Manifeste d'exécution — essai-orchestrateur

Format :
- `- [ ] <id> | <priorité> | <périmètre> | <critère de done> | <gates> | deps:<liste> | conflit:<liste>`
- `deps:` contient les identifiants qui doivent être `DONE` avant exécution.
- `conflit:` contient les identifiants incompatibles en parallèle.

## Tâches

- [ ] T-001 | P1 | src/**,tests/** | formaterEuros(centimes) exportée par src/prix.js : 123450 donne "1 234,50 €", 5 donne "0,05 €", -250 donne "-2,50 €" (espace simple entre milliers, virgule décimale) ; un non-entier lève TypeError ; chaque cas couvert par un test vu rouge avant le code | test | deps: | conflit:
- [ ] T-002 | P2 | src/**,tests/** | recapitulatif(htCentimes, tauxPourcent) exportée par src/prix.js renvoie { ht, tva, ttc } formatés par formaterEuros, avec ttc = montantTTC(ht, taux) et tva = ttc - ht ; chaque champ couvert par un test | test | deps:T-001 | conflit:
