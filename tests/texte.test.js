// Tests de src/texte.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { majuscules } from '../src/texte.js';

test('majuscules met en capitales une chaîne simple', () => {
  assert.equal(majuscules('abc'), 'ABC');
});

test('majuscules laisse une chaîne vide inchangée', () => {
  assert.equal(majuscules(''), '');
});

test('majuscules refuse une valeur qui n\'est pas une chaîne', () => {
  assert.throws(() => majuscules(12.34), { name: 'TypeError' });
});
