// Tests de src/arrondi.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formaterPourcent } from '../src/arrondi.js';

test('formaterPourcent formate un taux entier', () => {
  assert.equal(formaterPourcent(20), '20 %');
});

test('formaterPourcent formate un taux decimal avec une virgule', () => {
  assert.equal(formaterPourcent(5.5), '5,5 %');
});

test('formaterPourcent formate un taux nul', () => {
  assert.equal(formaterPourcent(0), '0 %');
});

test('formaterPourcent refuse une valeur non finie', () => {
  assert.throws(() => formaterPourcent(NaN), TypeError);
  assert.throws(() => formaterPourcent(Infinity), TypeError);
});
