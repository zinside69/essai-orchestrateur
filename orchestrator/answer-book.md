# Answer-book — reponses canoniques aux escalades

# Format :
# R-### | quand:<raison> | niveau_max:L<n> | decision:<valeur> | portee:<glob|-> | expire_le:<AAAA-MM-JJ> | remplace:<R-###|- >
#
# Regles actives Phase 4 :
# - le clone applique une doctrine ecrite ;
# - aucune regle de niveau L4 n'est autorisee ;
# - les regles expirees sont ignorees ;
# - la premiere regle qui matche gagne.

# --- Depassements bornes, sans secret ni changement de politique ------------
R-001 | quand:P1:plafond-depasse(6f/320l) | niveau_max:L3 | decision:approuver | portee:src/domain/** | expire_le:2026-12-31 | remplace:-
R-002 | quand:P1:plafond-depasse(7f/360l) | niveau_max:L3 | decision:approuver | portee:tests/** | expire_le:2026-12-31 | remplace:-

# --- Desaccords de revue sur un perimetre borne -----------------------------
R-010 | quand:M3:desaccord-reviewer | niveau_max:L3 | decision:modifier | portee:src/api/** | expire_le:2026-10-31 | remplace:-
R-011 | quand:M2:volume-moyen-accord-ou-reserve | niveau_max:L2 | decision:approuver | portee:- | expire_le:2026-12-31 | remplace:-

# --- Rappels de refus structurel -------------------------------------------
# Aucune regle P3 (motif-secret), aucune regle P5 (invariant-contexte-neuf),
# aucune regle sur .claude/** ou .githooks/**. Ces cas restent hors clone.
