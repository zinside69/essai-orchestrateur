// arrondi.js — formatage de taux en pourcentage.

/**
 * Formate un taux en pourcentage lisible (virgule decimale, espace avant %).
 * @param {number} tauxPourcent taux en pourcent (20 pour 20 %)
 * @returns {string} taux formate, ex. "5,5 %"
 * @throws {TypeError} si tauxPourcent n'est pas un nombre fini
 */
export function formaterPourcent(tauxPourcent) {
  if (!Number.isFinite(tauxPourcent)) {
    throw new TypeError('tauxPourcent doit etre un nombre fini');
  }
  return `${String(tauxPourcent).replace('.', ',')} %`;
}
