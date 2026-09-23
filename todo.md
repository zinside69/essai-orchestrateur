# Manifeste d'exécution — essai-orchestrateur

Format :
- `- [ ] <id> | <priorité> | <périmètre> | <critère de done> | <gates> | deps:<liste> | conflit:<liste>`
- `deps:` contient les identifiants qui doivent être `DONE` avant exécution.
- `conflit:` contient les identifiants incompatibles en parallèle.

## Tâches

- [ ] T-001 | P1 | src/**,tests/** | formaterEuros(centimes) exportée par src/prix.js : 123450 donne "1 234,50 €", 5 donne "0,05 €", -250 donne "-2,50 €" (espace simple entre milliers, virgule décimale) ; un non-entier lève TypeError ; chaque cas couvert par un test vu rouge avant le code | test | deps: | conflit:
- [ ] T-002 | P2 | src/**,tests/** | recapitulatif(htCentimes, tauxPourcent) exportée par src/prix.js renvoie { ht, tva, ttc } formatés par formaterEuros, avec ttc = montantTTC(ht, taux) et tva = ttc - ht ; chaque champ couvert par un test | test | deps:T-001 | conflit:
- [ ] T-003 | P1 | src/prix.js,tests/prix.test.js | montantHT(ttcCentimes, tauxPourcent) exportée par src/prix.js, inverse de montantTTC : Math.round(ttc * 100 / (100 + taux)) ; 12000 à 20 donne 10000, 1199 à 20 donne 999, 1 à 5.5 donne 1 ; un ttcCentimes non entier lève TypeError ; chaque cas couvert par un test vu rouge avant le code | test | deps: | conflit:
- [ ] T-004 | P2 | src/prix.js,tests/prix.test.js | recapitulatifDepuisTTC(ttcCentimes, tauxPourcent) exportée par src/prix.js renvoie { ht, tva, ttc } formatés par formaterEuros, avec ht = montantHT(ttc, taux) et tva = ttc - ht ; 12000 à 20 donne { ht: "100,00 €", tva: "20,00 €", ttc: "120,00 €" } ; chaque champ couvert par un test | test | deps:T-003 | conflit:
- [ ] T-005 | P1 | src/arrondi.js,tests/arrondi.test.js | arrondiBancaire(valeur) exportée par un nouveau module src/arrondi.js : arrondit à l'entier le plus proche, les demis vers l'entier pair ; 2.5 donne 2, 3.5 donne 4, -2.5 donne -2, 2.4 donne 2, 2.6 donne 3 ; une valeur qui n'est pas un nombre fini lève TypeError ; chaque cas couvert par un test vu rouge avant le code | test | deps: | conflit:T-006
- [ ] T-006 | P2 | src/arrondi.js,tests/arrondi.test.js | formaterPourcent(tauxPourcent) exportée par src/arrondi.js : 20 donne "20 %", 5.5 donne "5,5 %", 0 donne "0 %" (virgule décimale, espace simple avant %) ; une valeur qui n'est pas un nombre fini lève TypeError ; chaque cas couvert par un test | test | deps: | conflit:T-005
