// Tests de src/prix.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { montantTTC, formaterEuros } from '../src/prix.js';

test('montantTTC applique le taux et arrondit au centime', () => {
  assert.equal(montantTTC(1000, 20), 1200);
  assert.equal(montantTTC(1999, 20), 2399); // 2398,8 arrondi
});

test('montantTTC refuse un montant non entier', () => {
  assert.throws(() => montantTTC(10.5, 20), TypeError);
});

test('formaterEuros separe les milliers par une espace', () => {
  assert.equal(formaterEuros(123450), '1 234,50 €');
});

test('formaterEuros pad les centimes sur deux chiffres', () => {
  assert.equal(formaterEuros(5), '0,05 €');
});

test('formaterEuros gere les montants negatifs', () => {
  assert.equal(formaterEuros(-250), '-2,50 €');
});

test('formaterEuros refuse un montant non entier', () => {
  assert.throws(() => formaterEuros(10.5), TypeError);
});
