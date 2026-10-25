// What the Worker will and will not accept into the database.
//
// Run with: npm test  (from nyc26/)
//
// These cover the rules only — they need no network, no database and no
// Cloudflare account. The live checks that need a running Worker are in
// tests/api.test.mjs.

import test from 'node:test';
import assert from 'node:assert/strict';
import { initialTrip, validateTrip } from '../worker/worker.js';

const ok = (trip) => {
  const result = validateTrip(trip);
  assert.equal(result.error, undefined, 'expected this to be accepted: ' + result.error);
  return result.trip;
};
const refused = (trip) => {
  const result = validateTrip(trip);
  assert.ok(result.error, 'expected this to be refused');
  return result.error;
};

/** A fresh, valid document to mutate in each test. */
const draft = () => JSON.parse(JSON.stringify(initialTrip()));

test('the starting document is valid and carries only disposable test data', () => {
  const trip = ok(initialTrip());
  assert.equal(trip.dataVersion, 2);
  assert.equal(trip.evenings.length, 3);
  assert.ok(trip.places.length > 0);
  for (const place of trip.places) {
    assert.ok(place.name.startsWith('TEST —'), 'seed places must be marked as test data');
  }
  // Nothing about the real trip may ship in a public repository. Checked by
  // what the seed IS, not by listing what it must not be — a list of the real
  // places would itself be the leak.
  assert.equal(trip.essentials.outbound, 'TO BE FILLED IN');
  assert.equal(trip.essentials.inbound, 'TO BE FILLED IN');
  assert.equal(trip.essentials.confirmation, 'TO BE FILLED IN');
  assert.equal(trip.essentials.hotelAddress, 'TO BE FILLED IN');
  assert.equal(trip.thoughts.length, 0);
  for (const night of trip.evenings) {
    assert.equal(night.cluster, 'TO BE FILLED IN');
    assert.equal(night.stops, 'TO BE FILLED IN');
    assert.equal(night.awareness, '');
  }
  for (const place of trip.places) {
    assert.equal(place.note, 'Disposable test data.');
  }
  for (const value of Object.values(trip.practical)) {
    assert.equal(value, 'TO BE FILLED IN');
  }
});

test('the four sections and their fields are required', () => {
  refused(null);
  refused({});
  for (const section of ['essentials', 'evenings', 'places', 'thoughts', 'practical']) {
    const trip = draft();
    delete trip[section];
    refused(trip);
  }
  const missingField = draft();
  delete missingField.essentials.confirmation;
  refused(missingField);
});

test('there are always exactly three evenings', () => {
  const two = draft();
  two.evenings = two.evenings.slice(0, 2);
  refused(two);

  const four = draft();
  four.evenings = [...four.evenings, { cluster: '', stops: '', awareness: '' }];
  refused(four);
});

test('only the five categories are allowed', () => {
  for (const category of ['Hotel', 'Office', 'Food', 'Shops', 'Other']) {
    const trip = draft();
    trip.places[0].category = category;
    assert.equal(ok(trip).places[0].category, category);
  }
  for (const category of ['Bar', '', null, 'hotel']) {
    const trip = draft();
    trip.places[0].category = category;
    refused(trip);
  }
});

test('pins must sit inside New York', () => {
  const inside = draft();
  inside.places[0].location.lat = 40.733418;
  inside.places[0].location.lon = -73.990226;
  ok(inside);

  for (const [lat, lon] of [
    [51.5074, -0.1278], // London
    [40.0, -73.99], // south of the box
    [40.75, -75.0], // west of the box
  ]) {
    const trip = draft();
    trip.places[0].location.lat = lat;
    trip.places[0].location.lon = lon;
    refused(trip);
  }
});

test('a pin must cite OpenStreetMap or NYC GeoSearch over https', () => {
  const geosearch = draft();
  geosearch.places[0].location.source = 'https://geosearch.planninglabs.nyc/v2/search';
  ok(geosearch);

  for (const source of [
    'http://www.openstreetmap.org/node/1', // not https
    'https://evil.example/node/1', // wrong host
    'https://www.openstreetmap.org/profile/1', // wrong path
    'https://user:pass@www.openstreetmap.org/node/1', // credentials
    'not a url',
  ]) {
    const trip = draft();
    trip.places[0].location.source = source;
    refused(trip);
  }
});

test('a place may be saved by name with no pin at all', () => {
  const trip = draft();
  trip.places[0].location = null;
  assert.equal(ok(trip).places[0].location, null);
});

test('place identifiers and numbers stay unique', () => {
  const sameId = draft();
  sameId.places[1].id = sameId.places[0].id;
  refused(sameId);

  const sameNumber = draft();
  sameNumber.places[1].number = sameNumber.places[0].number;
  refused(sameNumber);
});

test('oversized content is refused rather than truncated', () => {
  const longNote = draft();
  longNote.places[0].note = 'x'.repeat(4001);
  refused(longNote);

  const longThought = draft();
  longThought.thoughts = [{ id: 'a', text: 'x'.repeat(2001) }];
  refused(longThought);

  const fine = draft();
  fine.thoughts = [{ id: 'a', text: 'x'.repeat(2000) }];
  ok(fine);

  const tooMany = draft();
  tooMany.places = Array.from({ length: 201 }, (_, i) => ({
    id: 'p' + i,
    number: i + 1,
    name: 'Place',
    category: 'Other',
    note: '',
    location: null,
  }));
  refused(tooMany);
});

test('an older browser cannot save over the current shape', () => {
  const old = draft();
  old.dataVersion = 1;
  assert.match(refused(old), /older version/);
});

test('unknown extra fields are dropped rather than stored', () => {
  const trip = draft();
  trip.somethingElse = 'should not survive';
  trip.places[0].sneaky = true;
  const saved = ok(trip);
  assert.equal(saved.somethingElse, undefined);
  assert.equal(saved.places[0].sneaky, undefined);
});

test('a valid document round-trips unchanged', () => {
  const trip = draft();
  trip.essentials.outbound = 'Some flight';
  trip.thoughts = [{ id: 't1', text: 'Keep this' }];
  assert.deepEqual(ok(ok(trip)), ok(trip));
});
