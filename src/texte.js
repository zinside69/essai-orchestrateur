// texte.js — utilitaires de transformation de texte.

/**
 * Convertit une chaîne en majuscules.
 * @param {string} texte chaîne à transformer
 * @returns {string} texte en majuscules
 * @throws {TypeError} si texte n'est pas une chaîne
 */
export function majuscules(texte) {
  if (typeof texte !== 'string') {
    throw new TypeError('texte doit etre une chaine');
  }
  return texte.toUpperCase();
}
