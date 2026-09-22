// prix.js — calculs de prix en centimes entiers.
// Un montant d'argent n'est jamais un flottant : 0,1 + 0,2 ≠ 0,3.

/**
 * Montant TTC en centimes, arrondi au centime le plus proche.
 * @param {number} htCentimes   montant hors taxes, entier de centimes
 * @param {number} tauxPourcent taux de TVA en pourcent (20 pour 20 %)
 * @returns {number} montant TTC en centimes
 * @throws {TypeError} si htCentimes n'est pas un entier
 */
export function montantTTC(htCentimes, tauxPourcent) {
  if (!Number.isInteger(htCentimes)) {
    throw new TypeError('htCentimes doit etre un entier de centimes');
  }
  return Math.round((htCentimes * (100 + tauxPourcent)) / 100);
}
