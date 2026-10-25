// Bring an authorised export from the old ChatGPT Site into this hub's database.
//
//   node worker/import-trip.mjs <export.json>            # check only, writes nothing
//   node worker/import-trip.mjs <export.json> --write    # back up, then import
//
// The export file is private trip data. Keep it outside this repository: the
// repository is public. Anywhere under ~/Documents is fine.
//
// What it does, in order:
//   1. reads the export and finds the trip document inside it
//   2. validates it against the Worker's own rules, the same ones a save uses
//   3. saves the database's current contents to a backup file next to the export
//   4. writes the trip in, advancing the revision by one
//   5. reads it back and compares, field by field
//
// Nothing is written without --write, and nothing is written if validation
// fails. The old Site is never contacted; this only reads a file you exported.

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateTrip } from './worker.js';

const run = promisify(execFile);
const here = fileURLToPath(new URL('..', import.meta.url));
const bar = '[' + '#'.repeat(20) + ']';

const [file, ...flags] = process.argv.slice(2);
const write = flags.includes('--write');

if (!file) {
  console.error('Usage: node worker/import-trip.mjs <export.json> [--write]');
  process.exit(1);
}

/** Runs one SQL statement against the real database and returns its rows. */
async function sql(command) {
  const { stdout } = await run(
    'npx',
    ['wrangler', 'd1', 'execute', 'nyc26', '--remote', '--config', 'worker/wrangler.toml',
     '--command', command, '--json', '-y'],
    { cwd: here, maxBuffer: 64 * 1024 * 1024 },
  );
  // Wrangler's JSON shape has moved around between versions, so find the rows
  // rather than assuming where they sit.
  const find = (node) => {
    if (Array.isArray(node)) {
      for (const item of node) {
        const found = find(item);
        if (found) return found;
      }
    } else if (node && typeof node === 'object') {
      if (Array.isArray(node.results)) return node.results;
      for (const value of Object.values(node)) {
        const found = find(value);
        if (found) return found;
      }
    }
    return null;
  };
  return find(JSON.parse(stdout.slice(stdout.indexOf('[')))) ?? [];
}

/**
 * The export may be the trip itself, or the API's `{trip, revision}` envelope,
 * or a row with the document in a `data` string. Accept any of those.
 */
function extractTrip(raw) {
  let value = raw;
  if (typeof value === 'string') value = JSON.parse(value);
  if (value && typeof value === 'object') {
    if (value.trip) return extractTrip(value.trip);
    if (typeof value.data === 'string') return extractTrip(value.data);
    if (Array.isArray(value.results) && value.results.length) return extractTrip(value.results[0]);
  }
  return value;
}

const exportPath = resolve(file);
const incoming = extractTrip(JSON.parse(await readFile(exportPath, 'utf8')));

const checked = validateTrip(incoming);
if (checked.error) {
  console.error('This export was refused: ' + checked.error);
  console.error('Nothing was written. The export file is unchanged.');
  process.exit(1);
}
const trip = checked.trip;

// A short, non-identifying summary. Deliberately prints no addresses, no notes
// and no flight details, so running this does not spill the trip into a log.
const filled = (value) => value !== 'TO BE FILLED IN' && value !== 'TO BE VERIFIED' && value !== '';
console.log('The export is valid.');
console.log('  places:    ' + trip.places.length + ' (' + trip.places.filter((p) => p.location).length + ' pinned)');
console.log('  thoughts:  ' + trip.thoughts.length);
console.log('  flights:   ' + (filled(trip.essentials.outbound) || filled(trip.essentials.inbound) ? 'filled in' : 'still blank'));
console.log('  hotel:     ' + (filled(trip.essentials.hotelAddress) ? 'filled in' : 'still blank'));
console.log('  evenings:  ' + trip.evenings.filter((n) => filled(n.cluster) || filled(n.stops)).length + ' of 3 started');
console.log('  practical: ' + Object.values(trip.practical).filter(filled).length + ' of 4 filled in');

const [current] = await sql("SELECT revision, data FROM trips WHERE id = 'trip'");
if (!current) {
  console.error('No trip row found. Run the steps in SETUP.md first.');
  process.exit(1);
}
const before = JSON.parse(current.data);
console.log('\nThe database currently holds ' + before.places.length + ' places at revision ' + current.revision + '.');

if (!write) {
  console.log('\nCheck only. Nothing was written. Add --write to import it.');
  process.exit(0);
}

// Back up what is about to be replaced, next to the export file so the two
// stay together and both stay out of the repository.
const backupPath = exportPath.replace(/\.json$/, '') + '.replaced-' + new Date().toISOString().replace(/[:.]/g, '-') + '.json';
await writeFile(backupPath, JSON.stringify({ revision: current.revision, trip: before }, null, 2));
console.log('Backed up the current contents to:\n  ' + backupPath);

const next = current.revision + 1;
await sql(
  'UPDATE trips SET data = ' + quote(JSON.stringify(trip)) + ', revision = ' + next + " WHERE id = 'trip' AND revision = " + current.revision,
);

const [after] = await sql("SELECT revision, data FROM trips WHERE id = 'trip'");
const saved = JSON.parse(after.data);
const same = JSON.stringify(saved) === JSON.stringify(trip);
console.log('\n' + bar + ' Imported at revision ' + after.revision + '.');
console.log('  read back identical: ' + (same ? 'yes' : 'NO — check before trusting it'));
console.log('  places now:          ' + saved.places.length);
console.log('  thoughts now:        ' + saved.thoughts.length);
if (!same) process.exit(1);

/** SQLite string literal: single quotes are escaped by doubling them. */
function quote(value) {
  return "'" + value.replace(/'/g, "''") + "'";
}
