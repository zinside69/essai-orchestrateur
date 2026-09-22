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

/**
 * Formate un montant en centimes en euros lisibles (espace pour les milliers,
 * virgule pour les decimales, symbole € final).
 * @param {number} centimes montant entier de centimes (peut etre negatif)
 * @returns {string} montant formate, ex. "1 234,50 €"
 * @throws {TypeError} si centimes n'est pas un entier
 */
export function formaterEuros(centimes) {
  if (!Number.isInteger(centimes)) {
    throw new TypeError('centimes doit etre un entier');
  }
  const signe = centimes < 0 ? '-' : '';
  const absCentimes = Math.abs(centimes);
  const euros = Math.floor(absCentimes / 100);
  const eurosStr = String(euros).replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  const centsStr = String(absCentimes % 100).padStart(2, '0');
  return `${signe}${eurosStr},${centsStr} €`;
}

/**
 * Recapitulatif d'un montant hors taxes : HT, TVA et TTC, formates en euros.
 * @param {number} htCentimes   montant hors taxes, entier de centimes
 * @param {number} tauxPourcent taux de TVA en pourcent (20 pour 20 %)
 * @returns {{ht: string, tva: string, ttc: string}} montants formates
 */
export function recapitulatif(htCentimes, tauxPourcent) {
  const ttcCentimes = montantTTC(htCentimes, tauxPourcent);
  const tvaCentimes = ttcCentimes - htCentimes;
  return {
    ht: formaterEuros(htCentimes),
    tva: formaterEuros(tvaCentimes),
    ttc: formaterEuros(ttcCentimes),
  };
}
