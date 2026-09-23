// Tests de src/saisie.js — lancés par `npm run test` (node --test).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { centimesDepuisTexte } from '../src/saisie.js';

test('centimesDepuisTexte convertit un montant avec virgule décimale', () => {
  assert.equal(centimesDepuisTexte('12,34'), 1234);
});

test('centimesDepuisTexte convertit un montant entier sans virgule', () => {
  assert.equal(centimesDepuisTexte('7'), 700);
});

test('centimesDepuisTexte gère un montant négatif avec un seul chiffre décimal', () => {
  assert.equal(centimesDepuisTexte('-2,5'), -250);
});

test('centimesDepuisTexte accepte l\'espace comme séparateur de milliers', () => {
  assert.equal(centimesDepuisTexte('1 234,50'), 123450);
});

test('centimesDepuisTexte refuse un texte qui n\'est pas un montant', () => {
  for (const texte of ['abc', '', '1,234']) {
    assert.throws(() => centimesDepuisTexte(texte), {
      name: 'TypeError',
      message: /montant/,
    });
  }
});

test('centimesDepuisTexte refuse une valeur qui n\'est pas une chaîne', () => {
  assert.throws(() => centimesDepuisTexte(12.34), { name: 'TypeError', message: /montant/ });
});
