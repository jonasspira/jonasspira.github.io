import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';

for (const page of ['', 'breaker-map/', 'filters/', 'groton-inventory/', 'plates/', 'tinfoil/', 'toronto26/']) {
  assert(existsSync('_site/' + page + 'index.html'), 'Missing built page: ' + page);
}
const html = readFileSync('_site/plates/index.html', 'utf8');
const match = html.match(/window\.PLATES\s*=\s*(\[[\s\S]*?\]);/);
assert(match, 'Jekyll must generate the plate list');
const actual = JSON.parse(match[1]);
const expected = JSON.parse(readFileSync('_data/plates_order.json', 'utf8'));
assert.deepEqual(actual, expected, 'Published photos must retain newest-first order');
assert(actual.length > 0, 'Gallery cannot be empty');
assert.equal(new Set(actual).size, actual.length, 'Photos must not be duplicated');
assert(!/id=["'](?:intro|begin)["']/.test(html), 'The gallery must open without an intro');
const hashes = new Set();
for (const path of actual) {
  assert(existsSync('_site' + path), 'Missing image: ' + path);
  const hash = createHash('sha256').update(readFileSync('_site' + path)).digest('hex');
  assert(!hashes.has(hash), 'Duplicate photo content: ' + path);
  hashes.add(hash);
}
for (const asset of ['dome.js', 'dome.css']) {
  assert(existsSync('_site/plates/assets/' + asset), 'Missing gallery asset: ' + asset);
}
console.log('[####################] Site checked: all tool pages and ' + actual.length + ' ordered photos.');
