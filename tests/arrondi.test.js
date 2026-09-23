// Tests de src/arrondi.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { arrondiBancaire } from '../src/arrondi.js';

test('arrondiBancaire arrondit vers le bas sous le demi', () => {
  assert.equal(arrondiBancaire(2.4), 2);
});

test('arrondiBancaire arrondit vers le haut au-dessus du demi', () => {
  assert.equal(arrondiBancaire(2.6), 3);
});

test('arrondiBancaire arrondit un demi vers l\'entier pair inferieur', () => {
  assert.equal(arrondiBancaire(2.5), 2);
});

test('arrondiBancaire arrondit un demi vers l\'entier pair superieur', () => {
  assert.equal(arrondiBancaire(3.5), 4);
});

test('arrondiBancaire arrondit un demi negatif vers l\'entier pair', () => {
  assert.equal(arrondiBancaire(-2.5), -2);
});

test('arrondiBancaire refuse une valeur qui n\'est pas un nombre fini', () => {
  assert.throws(() => arrondiBancaire(NaN), TypeError);
  assert.throws(() => arrondiBancaire(Infinity), TypeError);
  assert.throws(() => arrondiBancaire('2.5'), TypeError);
});
