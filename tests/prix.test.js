// Tests de src/prix.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { montantTTC, montantHT, formaterEuros, recapitulatif, recapitulatifDepuisTTC } from '../src/prix.js';

test('montantTTC applique le taux et arrondit au centime', () => {
  assert.equal(montantTTC(1000, 20), 1200);
  assert.equal(montantTTC(1999, 20), 2399); // 2398,8 arrondi
});

test('montantTTC refuse un montant non entier', () => {
  assert.throws(() => montantTTC(10.5, 20), TypeError);
});

test('montantHT retire le taux du montant TTC', () => {
  assert.equal(montantHT(12000, 20), 10000);
});

test('montantHT arrondit au centime le plus proche', () => {
  assert.equal(montantHT(1199, 20), 999); // 999,17 arrondi
});

test('montantHT gere un taux decimal', () => {
  assert.equal(montantHT(1, 5.5), 1); // 0,95 arrondi
});

test('montantHT refuse un montant non entier', () => {
  assert.throws(() => montantHT(10.5, 20), TypeError);
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

test('recapitulatif formate le montant hors taxes', () => {
  const { ht } = recapitulatif(1000, 20);
  assert.equal(ht, '10,00 €');
});

test('recapitulatif formate le montant ttc', () => {
  const { ttc } = recapitulatif(1000, 20);
  assert.equal(ttc, '12,00 €');
});

test('recapitulatif formate le montant de tva', () => {
  const { tva } = recapitulatif(1000, 20);
  assert.equal(tva, '2,00 €');
});

test('recapitulatifDepuisTTC formate le montant hors taxes', () => {
  const { ht } = recapitulatifDepuisTTC(12000, 20);
  assert.equal(ht, '100,00 €');
});

test('recapitulatifDepuisTTC formate le montant de tva', () => {
  const { tva } = recapitulatifDepuisTTC(12000, 20);
  assert.equal(tva, '20,00 €');
});

test('recapitulatifDepuisTTC formate le montant ttc', () => {
  const { ttc } = recapitulatifDepuisTTC(12000, 20);
  assert.equal(ttc, '120,00 €');
});

test('recapitulatifDepuisTTC deduit la tva du ht arrondi', () => {
  // 1199 TTC a 20 % : ht = 999 (999,17 arrondi), tva = 1199 - 999 = 200
  assert.deepEqual(recapitulatifDepuisTTC(1199, 20), {
    ht: '9,99 €',
    tva: '2,00 €',
    ttc: '11,99 €',
  });
});
