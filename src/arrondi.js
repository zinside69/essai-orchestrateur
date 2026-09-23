// arrondi.js — arrondi bancaire (round half to even) sur des nombres finis.

/**
 * Arrondit un nombre a l'entier le plus proche ; les demis sont arrondis
 * vers l'entier pair le plus proche (arrondi bancaire).
 * @param {number} valeur nombre fini a arrondir
 * @returns {number} entier le plus proche
 * @throws {TypeError} si valeur n'est pas un nombre fini
 */
export function arrondiBancaire(valeur) {
  if (!Number.isFinite(valeur)) {
    throw new TypeError('valeur doit etre un nombre fini');
  }
  const plancher = Math.floor(valeur);
  const reste = valeur - plancher;
  if (reste === 0.5) {
    return plancher % 2 === 0 ? plancher : plancher + 1;
  }
  return Math.round(valeur);
}
