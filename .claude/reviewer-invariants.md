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

<!-- (2026-09-25, O37) Ajout : sur T-002 (iziGSM), le relecteur a rejeté en R6 et R1 la migration et CLAUDE.md appliquées par le harnais sur décision humaine, faute d'exception écrite ici. Test Z5. -->
## Seule exception : les modifications appliquées par le harnais

Ta consigne peut contenir une section « MODIFICATIONS APPLIQUEES PAR LE HARNAIS SUR DECISION
HUMAINE ». Les fichiers qu'elle nomme n'ont pas été écrits par l'auteur : il a soumis une
demande d'écriture, un humain l'a approuvée, le harnais a appliqué le texte approuvé tel quel
et a vérifié par empreinte que personne ne l'a retouché depuis (ADR 0002).

- Sur ces fichiers seulement, les invariants I3, I4, I5 et I9 ne fondent **aucun** rejet : ni
  R4, ni R6, ni R7, ni R1. La décision humaine les a déjà tranchés.
- **I1 reste opposable partout** : un secret dans ces fichiers est un rejet **R5**, même
  approuvé.
- Ces fichiers comptent dans la preuve du critère de done comme le reste du diff.
- Un fichier modifié par l'auteur **et** absent de cette liste se juge normalement.

## Définition de « prouvé par le diff »

Le critère de done est prouvé si le diff contient soit l'implémentation **et** un test qui
l'exerce, soit une modification dont l'effet est directement observable dans le diff
(contrat d'API, signature, contenu de fichier de configuration).

Un commentaire qui affirme que le travail est fait ne prouve rien. Un test qui ne peut pas
échouer ne prouve rien. Une suppression ne prouve pas une implémentation.

<!-- (2026-09-25, ADR 0003 R3, O41) Ajout. Test Z5. -->
Un critère de **sûreté des données** (atomicité, reprise après échec partiel, double comptage,
écrasement, course) n'est prouvé que si son test a été vu **rouge par mutation** : le compte rendu
de l'auteur cite la mutation, le test et le rouge vu, ou une preuve `mutation` du harnais est
soldée. Sans cette preuve, c'est un rejet **R2**.
