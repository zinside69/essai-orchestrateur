// saisie.js — lecture des montants saisis par un utilisateur.
// Le résultat est toujours en centimes entiers, jamais en flottant.

// Signe optionnel, partie entière (avec ou sans espaces entre milliers),
// puis au plus deux chiffres après la virgule.
const MONTANT = /^(-?)(\d+|\d{1,3}(?: \d{3})+)(?:,(\d{1,2}))?$/;

/**
 * Convertit un montant saisi en centimes entiers.
 * @param {string} texte montant saisi, ex. "12,34", "1 234,50" ou "-2,5"
 * @returns {number} montant en centimes
 * @throws {TypeError} si texte n'est pas une chaîne représentant un montant
 */
export function centimesDepuisTexte(texte) {
  const lu = typeof texte === 'string' ? MONTANT.exec(texte) : null;
  if (lu === null) {
    throw new TypeError('texte doit etre un montant, ex. "12,34"');
  }
  const [, signe, euros, decimales = ''] = lu;
  const centimes = Number(euros.replaceAll(' ', '')) * 100 + Number(decimales.padEnd(2, '0'));
  return signe ? -centimes : centimes;
}
