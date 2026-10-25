// What the research page makes of whatever a tool pastes in.
//
// The parser is deliberately forgiving, so these checks are mostly about it
// not inventing things and not dropping obvious finds. Node strips the types
// from the .ts import on its own.

import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFinds, sameName } from '../src/parse-finds.ts';

test('the documented pipe format is read exactly', () => {
  const finds = parseFinds(
    [
      'Shopping | Idlewild Books | West Village | Travel bookshop | 170 7th Ave S',
      'Food & Drink | Russ & Daughters | Lower East Side | Appetising shop since 1914 | 179 E Houston St',
      'Experiences | UCB | Chelsea | Long-form improv |',
    ].join('\n'),
    'Claude',
  );
  assert.equal(finds.length, 3);
  assert.equal(finds[0].name, 'Idlewild Books');
  assert.equal(finds[0].section, 'Shopping');
  assert.equal(finds[0].neighborhood, 'West Village');
  assert.equal(finds[0].address, '170 7th Ave S');
  assert.equal(finds[1].section, 'Food & Drink');
  assert.equal(finds[2].section, 'Experiences');
  for (const find of finds) {
    assert.equal(find.source, 'Claude');
    assert.equal(find.verdict, 'new');
    assert.equal(find.onMap, false);
    assert.ok(find.id.length > 4);
  }
});

test('a Markdown table is read, and its header and rule rows are skipped', () => {
  const finds = parseFinds(
    [
      '| Section | Name | Neighborhood | Why | Address |',
      '| --- | --- | --- | --- | --- |',
      '| Shopping | McNally Jackson | Nolita | Independent bookshop | 134 Prince St |',
    ].join('\n'),
    'ChatGPT',
  );
  assert.equal(finds.length, 1);
  assert.equal(finds[0].name, 'McNally Jackson');
  assert.equal(finds[0].neighborhood, 'Nolita');
});

test('JSON is accepted, as an array or under a candidates key', () => {
  const asArray = parseFinds(
    JSON.stringify([{ name: 'Kinokuniya', section: 'Shopping', neighborhood: 'Midtown', why: 'Stationery' }]),
    'Muse',
  );
  assert.equal(asArray.length, 1);
  assert.equal(asArray[0].name, 'Kinokuniya');
  assert.equal(asArray[0].why, 'Stationery');

  const wrapped = parseFinds(
    JSON.stringify({ candidates: [{ place: 'Argosy Book Store', category: 'shopping' }] }),
    'Muse',
  );
  assert.equal(wrapped.length, 1);
  assert.equal(wrapped[0].name, 'Argosy Book Store');
  assert.equal(wrapped[0].section, 'Shopping');

  // A tool that wraps JSON in prose or a fence still parses.
  const fenced = parseFinds('Here you go:\n```json\n[{"name":"Casey Rubber Stamps"}]\n```', 'Muse');
  assert.equal(fenced.length, 1);
  assert.equal(fenced[0].name, 'Casey Rubber Stamps');
});

test('a plain Markdown answer still yields finds, under the right sections', () => {
  const finds = parseFinds(
    [
      '## Shopping',
      '- **Idlewild Books** — travel bookshop (West Village)',
      '- Casey Rubber Stamps: custom stamps',
      '',
      '## Food & Drink',
      '1. Russ & Daughters — appetising shop',
      '',
      '## Experiences',
      '* The Mmuseumm — tiny museum in a lift shaft',
    ].join('\n'),
    'ChatGPT',
  );
  const byName = Object.fromEntries(finds.map((f) => [f.name, f]));
  assert.ok(byName['Idlewild Books'], 'bold name with an em dash');
  assert.equal(byName['Idlewild Books'].section, 'Shopping');
  assert.equal(byName['Idlewild Books'].neighborhood, 'West Village');
  assert.equal(byName['Casey Rubber Stamps'].section, 'Shopping');
  assert.equal(byName['Russ & Daughters'].section, 'Food & Drink');
  assert.equal(byName['The Mmuseumm'].section, 'Experiences');
});

test('section headings are recognised however they are written', () => {
  for (const heading of ['## Food & Drink', '## Food and Drink', '**Food & Drink:**', '### FOOD & DRINK']) {
    const finds = parseFinds(heading + '\n- Katz Delicatessen', 'tool');
    assert.equal(finds.length, 1, heading);
    assert.equal(finds[0].section, 'Food & Drink', heading);
  }
});

test('nothing is invented from nothing', () => {
  assert.deepEqual(parseFinds('', 'tool'), []);
  assert.deepEqual(parseFinds('   \n\n  ', 'tool'), []);
  assert.deepEqual(parseFinds('## Shopping\n## Food & Drink', 'tool'), []);
});

test('fields are trimmed to the lengths the Worker will accept', () => {
  const [find] = parseFinds('Shopping | ' + 'x'.repeat(400) + ' | ' + 'y'.repeat(900), 'tool');
  assert.ok(find.name.length <= 200);
  assert.ok(find.neighborhood.length <= 600);
});

test('the same place written differently collapses to one key', () => {
  // Two tools will write the same shop differently; these must all collide, or
  // the research list fills up with duplicates.
  assert.equal(sameName('The Strand'), sameName('strand'));
  assert.equal(sameName('Russ & Daughters'), sameName('Russ and Daughters'));
  assert.equal(sameName("McNally Jackson"), sameName('mcnally-jackson'));
  assert.equal(sameName('A Casa Do Porco'), sameName('Casa do Porco'));

  // And genuinely different places must not collide.
  assert.notEqual(sameName('Idlewild Books'), sameName('Idlewild Wines'));
  assert.notEqual(sameName("Pete's Tavern"), sameName("Pete's Candy Store"));
});
