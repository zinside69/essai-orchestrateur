# Invariants opposables au reviewer

Ces règles sont opposables. Une ligne ajoutée qui en enfreint une se traduit
obligatoirement par un code de rejet.

| # | Invariant | Code de rejet |
|---|---|---|
| I1 | Aucun secret, clé ou token en clair | R5 |
| I2 | Aucun test neutralisé (skip, only, xfail, @Ignore) | R3 |
| I3 | Aucune dépendance ajoutée sans ADR dans docs/adr/ | R4 |
| I4 | Aucune migration ni modification de schéma | R6 |
| I5 | Aucune modification de .claude/** ni .githooks/** | R7 |
| I6 | Aucune suppression de fichier non déclarée | R8 |
| I7 | Aucun code de debug laissé en place | R9 |
| I8 | Aucune gestion d'erreur supprimée ni catch vide | R10 |
| I9 | Le diff reste dans le périmètre déclaré | R1 |
| I10 | Le critère de done est prouvé par le diff | R2 |

## Définition de « prouvé par le diff »

Le critère de done est prouvé si le diff contient soit l'implémentation **et** un test qui
l'exerce, soit une modification dont l'effet est directement observable dans le diff
(contrat d'API, signature, contenu de fichier de configuration).

Un commentaire qui affirme que le travail est fait ne prouve rien. Un test qui ne peut pas
échouer ne prouve rien. Une suppression ne prouve pas une implémentation.
