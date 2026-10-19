import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  emptyFilter, parseXml, fromGmail, toXml, buildQuery, checkFilters, mergeFilters,
  validateProposal, describeActions, getReplacementPlan, CRITERIA_DEFAULTS, ACTION_DEFAULTS,
} from '../filter-model.js';

const fixture = await readFile(new URL('./fixtures/example.xml', import.meta.url), 'utf8');
const semantic = filters => filters.map(({ criteria, actions }) => ({ criteria, actions }));
const make = (position, criteria = {}, actions = {}) => emptyFilter({ position, criteria, actions });
const proposal = (kind, replacesPositions, criteria, actions) => ({ kind, replacesPositions, criteria, actions, exampleEmailIndexes: [], why: 'Synthetic test' });
const xmlWith = properties => `<?xml version='1.0'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:apps='http://schemas.google.com/apps/2006'><entry>${properties}</entry></feed>`;
const property = (name, value) => `<apps:property name='${name}' value='${value}'/>`;

test('Gmail XML round trip keeps all normalized filter criteria and actions', () => {
  const first = parseXml(fixture), second = parseXml(toXml(first));
  assert.equal(first.length, 7);
  assert.deepEqual(semantic(second), semantic(first));
  assert.equal(first[0].criteria.subject, '"Terms & Conditions"');
  assert.equal(first[6].criteria.doesNotHaveTheWord, '"O\'Brien" <internal>');
  assert.equal(first[6].criteria.sizeComparison, 'smaller');
  assert.match(buildQuery(first[6]), /smaller:2M$/);
});

test('new filter XML escapes all five special characters and accepts numeric entities', () => {
  const first = make(1, { from: 'a@example.com', subject: '"A & B" <C> O\'Brien' }, { label: 'One & "two"' });
  const xml = toXml([first]);
  for (const entity of ['&amp;', '&apos;', '&quot;', '&lt;', '&gt;']) assert.ok(xml.includes(entity));
  assert.deepEqual(semantic(parseXml(xml)), semantic([first]));
  assert.equal(parseXml(xmlWith(property('from', '&#97;&#x40;example.com')))[0].criteria.from, 'a@example.com');
});

test('XML reader rejects malformed, truncated, entity-bearing, or non-Gmail input', () => {
  for (const invalid of [
    '', '<feed/>', fixture.replace('</feed>', ''), fixture.replace('</entry>', '</wrong>'),
    fixture.replace('billing@example.com', '&unknown;'),
    fixture.replace('billing@example.com', '&#0;'),
    '<!DOCTYPE feed [<!ENTITY example SYSTEM "file:///private/data">]>' + fixture,
    fixture + '<feed/>', xmlWith(property('from', 'one@example.com') + property('from', 'two@example.com')),
    xmlWith('<apps:property name="from"/>'), xmlWith(property('hasAttachment', 'yes')),
  ]) assert.throws(() => parseXml(invalid), /Invalid Gmail XML/);
});

test('an empty Gmail feed is a valid zero-filter starting point', () => {
  assert.deepEqual(parseXml(toXml([])), []);
  assert.throws(() => toXml([emptyFilter({ actions: { trash: true } })]), /empty criteria/);
});

test('XML output rejects invalid characters and unknown model fields without dropping them', () => {
  for (const value of ['bad\u0000text', 'bad\u000Btext', '\uD800', '\uFFFE']) assert.throws(() => toXml([make(1, { from: 'x@example.com' }, { label: value })]), /XML cannot represent/);
  assert.doesNotThrow(() => toXml([make(1, { from: 'x@example.com' }, { label: 'Supplementary \u{1D400}' })]));
  assert.throws(() => toXml([make(1, { from: 'x@example.com', unknownCriterion: 'keep' })]), /unsupported criterion or action/);
  assert.throws(() => toXml([make(1, { from: 'x@example.com' }, { unknownAction: true })]), /unsupported criterion or action/);
});

test('unknown XML properties survive round trip and block unsafe merges', () => {
  const original = parseXml(xmlWith(property('from', 'x@example.com') + property('futureOption', 'keep-me')));
  const roundTrip = parseXml(toXml(original));
  assert.deepEqual(roundTrip[0].preservation.xmlProperties, [{ name: 'futureOption', value: 'keep-me' }]);
  assert.ok(original[0].warnings[0].includes('preserved'));
  assert.throws(() => mergeFilters([original[0], make(2, { from: 'y@example.com' })]), /unsupported settings/);
});

test('unknown XML elements and size formats block downloads instead of dropping data', () => {
  const element = parseXml(xmlWith(property('from', 'x@example.com') + '<unknownAction/>'));
  assert.throws(() => toXml(element), /Unsupported XML element/);
  const size = parseXml(xmlWith(property('from', 'x@example.com') + property('size', '2') + property('sizeUnit', 'unknown-unit')));
  assert.throws(() => toXml(size), /Unknown XML size unit/);
});

test('API labels map to names and every supported system action maps correctly', () => {
  const filters = fromGmail([{ id: 'abc', criteria: { from: 'x@example.com', query: 'invoice', negatedQuery: 'draft', hasAttachment: true, excludeChats: true, size: 2000, sizeComparison: 'larger' }, action: { addLabelIds: ['Label_1', 'STARRED', 'TRASH', 'IMPORTANT'], removeLabelIds: ['INBOX', 'UNREAD', 'IMPORTANT', 'SPAM'], forward: 'archive@example.org' } }], [{ id: 'Label_1', name: 'Bills', type: 'user' }]);
  const filter = filters[0];
  assert.equal(filter.key, 'abc'); assert.equal(filter.source, 'live');
  assert.equal(filter.actions.label, 'Bills');
  for (const key of ['archive', 'markRead', 'star', 'trash', 'neverSpam', 'alwaysImportant', 'neverImportant']) assert.equal(filter.actions[key], true, key);
  assert.equal(filter.actions.forwardTo, 'archive@example.org');
  assert.equal(filter.criteria.hasTheWord, 'invoice');
  assert.equal(filter.criteria.doesNotHaveTheWord, 'draft');
  assert.equal(filter.criteria.size, 2000);
  const reparsed = parseXml(toXml(filters));
  assert.match(reparsed[0].criteria.hasTheWord, /larger:2000/);
  assert.equal(reparsed[0].criteria.size, null);
});

test('API size export uses a documented byte search without guessing XML units', () => {
  const filter = fromGmail([{ criteria: { size: 1537, sizeComparison: 'smaller' }, action: {} }])[0];
  assert.equal(buildQuery(filter), 'smaller:1537');
  assert.equal(parseXml(toXml([filter]))[0].criteria.hasTheWord, 'smaller:1537');
});

test('API categories convert to Gmail export category names and unknown categories block export', () => {
  for (const [category, exported] of [
    ['CATEGORY_PERSONAL', '^smartlabel_personal'], ['CATEGORY_SOCIAL', '^smartlabel_social'],
    ['CATEGORY_UPDATES', '^smartlabel_notification'], ['CATEGORY_FORUMS', '^smartlabel_group'], ['CATEGORY_PROMOTIONS', '^smartlabel_promo'],
  ]) {
    const filter = fromGmail([{ criteria: { from: 'x@example.com' }, action: { addLabelIds: [category] } }])[0];
    const xml = toXml([filter]);
    assert.ok(xml.includes(exported));
    assert.equal(parseXml(xml)[0].actions.category, category);
  }
  const unknown = fromGmail([{ criteria: { from: 'x@example.com' }, action: { addLabelIds: ['CATEGORY_FUTURE'] } }]);
  assert.throws(() => toXml(unknown), /no known Gmail import representation/);
});

test('multiple labels, unresolved labels, unknown API fields, and unsupported removals cannot lose data', () => {
  const labels = [{ id: 'Label_1', name: 'One', type: 'user' }, { id: 'Label_2', name: 'Two', type: 'user' }];
  for (const raw of [
    { action: { addLabelIds: ['Label_1', 'Label_2'] } },
    { action: { addLabelIds: ['Label_unknown'] } },
    { action: { removeLabelIds: ['Label_1'] } },
    { action: { unsupportedAction: true } },
    { criteria: { unsupportedCriterion: 'value' } },
  ]) {
    const filter = fromGmail([{ criteria: { from: 'x@example.com' }, ...raw }], labels)[0];
    assert.ok(filter.warnings.length);
    assert.throws(() => toXml([filter]), /Filter 1:/);
    assert.deepEqual(filter.preservation.rawApi, { criteria: { from: 'x@example.com' }, ...raw });
  }
});

test('query builder scopes ORs and includes exclusions, attachments, and size', () => {
  assert.equal(buildQuery(make(1, {
    from: 'a@example.com OR b@example.com', to: 'team@example.org', subject: 'invoice OR receipt',
    hasTheWord: 'one OR two', doesNotHaveTheWord: 'draft OR sample', hasAttachment: true,
    excludeChats: true, size: 1000, sizeComparison: 'larger',
  })), 'from:(a@example.com OR b@example.com) (to:(team@example.org) OR cc:(team@example.org) OR bcc:(team@example.org)) subject:(invoice OR receipt) (one OR two) -(draft OR sample) has:attachment -in:chats larger:1000');
});

test('merging retains each original whole AND group', () => {
  const filters = [make(1, { from: 'a@x.com', subject: 'invoice' }, { label: 'Bills', star: true }), make(2, { from: 'b@y.com', doesNotHaveTheWord: 'draft' }, { label: 'Bills', star: true })];
  const merged = mergeFilters(filters);
  assert.equal(merged.criteria.hasTheWord, '(from:(a@x.com) subject:(invoice)) OR (from:(b@y.com) -(draft))');
  assert.deepEqual(merged.actions, filters[0].actions);
  assert.deepEqual(semantic(parseXml(toXml([merged]))), semantic([merged]));
});

test('merging rejects action differences, unsupported settings, empty criteria, and oversized queries', () => {
  const one = make(1, { from: 'a@example.com' }, { label: 'Bills' });
  assert.throws(() => mergeFilters([one]), /at least two/);
  assert.throws(() => mergeFilters([one, make(2, { from: 'b@example.com' }, { label: 'Bills', trash: true })]), /identical actions/);
  assert.throws(() => mergeFilters([one, make(2, {}, { label: 'Bills' })]), /empty criteria/);
  assert.throws(() => mergeFilters([one, make(2, { hasTheWord: 'x'.repeat(1500) }, { label: 'Bills' })]), /1500-character/);
  assert.throws(() => mergeFilters([one, make(2, { subject: '"unfinished' }, { label: 'Bills' })]), /unbalanced filter punctuation/);
});

test('rule checks find planted duplicate, label/delete conflict, quoted space, overlap, and merge candidates', () => {
  const findings = checkFilters(parseXml(fixture));
  for (const type of ['duplicate', 'conflict', 'quoted-space', 'sender-overlap', 'merge-candidate', 'sender-drift']) assert.ok(findings.some(finding => finding.type === type), type);
  assert.deepEqual(findings.find(finding => finding.type === 'duplicate').positions, [1, 2]);
  assert.ok(findings.every(finding => finding.id && finding.title && finding.detail && finding.severity && finding.positions.length));
});

test('large shared-domain sets produce bounded grouped observations covering every filter', () => {
  const filters = Array.from({ length: 350 }, (_, i) => make(i + 1, { from: `sender${i}@example.com`, subject: `Topic ${i}` }, { label: 'Shared', archive: true }));
  const findings = checkFilters(filters);
  assert.ok(findings.length < 2000, `${findings.length} findings should be coalesced`);
  const merge = findings.filter(finding => finding.type === 'merge-candidate');
  assert.equal(merge.length, 1);
  assert.deepEqual(merge[0].positions, filters.map(filter => filter.position));
  const overlap = findings.filter(finding => finding.type === 'sender-overlap');
  assert.ok(overlap.some(finding => finding.positions.length === 350));
  assert.equal(new Set(findings.flatMap(finding => finding.positions)).size, 350);
  assert.ok(findings.filter(finding => finding.type === 'sender-drift').length <= 350);
});

test('large exact-duplicate sets produce one duplicate group with all positions', () => {
  const filters = Array.from({ length: 350 }, (_, i) => make(i + 1, { from: 'same@example.com' }, { label: 'Shared' }));
  const findings = checkFilters(filters), duplicates = findings.filter(finding => finding.type === 'duplicate');
  assert.equal(duplicates.length, 1);
  assert.equal(duplicates[0].positions.length, 350);
  assert.ok(findings.length < 10);
});

test('grouped merge suggestions require every action to match, not just the label', () => {
  const findings = checkFilters([
    make(1, { from: 'a@example.com' }, { label: 'Bills', archive: true }),
    make(2, { from: 'b@example.com' }, { label: 'Bills', archive: true }),
    make(3, { from: 'c@example.com' }, { label: 'Bills' }),
    make(4, { from: 'd@example.com' }, { label: 'Bills', archive: true, star: true }),
    make(5, { from: 'e@example.com' }, { label: 'Bills', archive: true, forwardTo: 'archive@example.org' }),
    make(6, { from: 'f@example.com' }, { label: 'Other', archive: true }),
  ]);
  assert.deepEqual(findings.filter(finding => finding.type === 'merge-candidate').map(finding => finding.positions), [[1, 2]]);
});

test('conflict groups cover explicit domain rules without accusing different addresses on the same domain', () => {
  const separate = checkFilters([make(1, { from: 'billing@example.com' }, { label: 'Bills' }), make(2, { from: 'offers@example.com' }, { trash: true })]);
  assert.equal(separate.filter(finding => finding.type === 'conflict').length, 0);
  const filters = [make(1, { from: '@example.com' }, { label: 'Bills' }), ...Array.from({ length: 349 }, (_, i) => make(i + 2, { from: `offers${i}@example.com` }, { trash: true }))];
  const conflicts = checkFilters(filters).filter(finding => finding.type === 'conflict');
  assert.equal(conflicts.length, 1);
  assert.equal(conflicts[0].positions.length, 350);
});

test('different preserved unknown XML values cannot be described as exact duplicates', () => {
  const filters = parseXml(xmlWith(property('from', 'x@example.com') + property('futureAction', 'one')).replace('</feed>', `<entry>${property('from', 'x@example.com')}${property('futureAction', 'two')}</entry></feed>`));
  assert.equal(checkFilters(filters).filter(finding => finding.type === 'duplicate').length, 0);
});

test('sender drift catches the documented GEICO and ATT patterns without asserting they are mistakes', () => {
  const checks = checkFilters([
    make(1, { from: 'geico@et.geico.com' }), make(2, { from: 'geico@e.geico.com' }),
    make(3, { from: 'update@emaildl.att-mail.com' }), make(4, { from: 'update@emailff.att-mail.com' }),
  ]).filter(finding => finding.type === 'sender-drift');
  assert.equal(checks.length, 2);
  assert.ok(checks.every(finding => finding.detail.includes('Confirm with a real message')));
});

test('punctuation checks ignore brackets inside quoted phrases and catch mismatches', () => {
  assert.equal(checkFilters([make(1, { subject: '"[text"' })]).filter(finding => finding.type === 'syntax').length, 0);
  for (const subject of ['"unfinished', '(one OR two', '[one}', 'one)']) assert.ok(checkFilters([make(1, { subject })]).some(finding => finding.type === 'syntax'));
  assert.equal(checkFilters([make(1, { from: '"unfinished', subject: 'also unfinished"' })]).filter(finding => finding.type === 'syntax').length, 2);
});

test('valid replacement is accepted and retained actions cannot silently disappear', () => {
  const filters = [make(1, { from: 'old@example.com' }, { label: 'Bills', archive: true, star: true, forwardTo: 'archive@example.org' })];
  const good = proposal('fix', [1], { from: 'new@example.com' }, filters[0].actions);
  assert.deepEqual(validateProposal(good, filters), []);
  const bad = { ...good, actions: { label: 'Bills' } };
  const warnings = validateProposal(bad, filters);
  for (const key of ['archive', 'star', 'forwardTo']) assert.ok(warnings.some(warning => warning.includes(key)));
});

test('proposal validation rejects invented numbers, missing replacements, empty criteria, types, and punctuation', () => {
  const filters = [make(1, { from: 'x@example.com' })];
  assert.ok(validateProposal(proposal('fix', [99], { from: 'y@example.com' }, {}), filters).some(warning => warning.includes('does not exist')));
  assert.ok(validateProposal({ criteria: {}, actions: {} }, filters).some(warning => warning.includes('replacesPositions')));
  assert.ok(validateProposal(proposal('new', [], {}, {}), filters).some(warning => warning.includes('empty criteria')));
  assert.ok(validateProposal(proposal('new', [], { subject: '"bad' }, { archive: 'true' }), filters).some(warning => warning.includes('quotation')));
  assert.ok(validateProposal(proposal('new', [], { size: -1, sizeComparison: 'any' }, {}), filters).some(warning => warning.includes('Size')));
  assert.ok(validateProposal(proposal('new', [1], { from: 'x@example.com' }, {}), filters).some(warning => warning.includes('cannot replace')));
});

test('list criteria require List-Id in the cited messages', () => {
  const value = { ...proposal('new', [], { hasTheWord: 'list:example.org' }, {}), exampleEmailIndexes: [0] };
  assert.ok(validateProposal(value, [], [{ from: 'list@example.org' }]).some(warning => warning.includes('List-Id')));
  assert.deepEqual(validateProposal(value, [], [{ headers: [{ name: 'List-Id', value: '<example.org>' }] }]), []);
  assert.ok(validateProposal({ ...value, exampleEmailIndexes: [8] }, [], []).some(warning => warning.includes('email number')));
  assert.ok(validateProposal({ ...value, exampleEmailIndexes: [] }, [], []).some(warning => warning.includes('cited email')));
  assert.ok(validateProposal({ ...value, exampleEmailIndexes: '0' }, [], []).some(warning => warning.includes('cited email')));
  assert.doesNotThrow(() => validateProposal(value, [], [{ headers: [null, { name: 5 }] }]));
});

test('AI merge validation blocks the old broad-OR bug and accepts the generated AND groups', () => {
  const filters = [make(1, { from: 'a@example.com', subject: 'invoice' }, { label: 'Bills' }), make(2, { from: 'b@example.com' }, { label: 'Bills' })];
  const unsafe = proposal('merge', [1, 2], { hasTheWord: 'from:(a@example.com OR b@example.com) OR subject:(invoice)' }, filters[0].actions);
  assert.ok(validateProposal(unsafe, filters).some(warning => warning.includes('complete AND group')));
  const safe = { ...unsafe, criteria: mergeFilters(filters).criteria };
  assert.deepEqual(validateProposal(safe, filters), []);
});

test('replacement plan contains unchanged filters plus replacements and the precise deletion list', () => {
  const filters = [make(1, { from: 'one@example.com' }), make(2, { from: 'two@example.com' }), make(3, { from: 'three@example.com' })];
  const value = proposal('extend', [2], { from: 'two@example.com OR four@example.com' }, { label: 'Bills' });
  const plan = getReplacementPlan(filters, [value]);
  assert.deepEqual(plan.replaced, [filters[1]]);
  assert.deepEqual(plan.filters.map(filter => filter.criteria.from), ['one@example.com', 'three@example.com', 'two@example.com OR four@example.com']);
  assert.deepEqual(plan.filters.map(filter => filter.position), [1, 2, 3]);
  assert.throws(() => getReplacementPlan(filters, [value, value]), /Two selected proposals/);
  assert.throws(() => getReplacementPlan(filters, [{ ...value, replacesPositions: [9] }]), /unknown filter/);
  assert.deepEqual(filters.map(filter => filter.position), [1, 2, 3]);
});

test('replacement plan keeps XML size units in changed-only and complete exports', () => {
  const original = parseXml(xmlWith(property('from', 'old@example.com') + property('size', '2') + property('sizeOperator', 's_ss') + property('sizeUnit', 's_smb')));
  const value = proposal('fix', [1], { ...original[0].criteria, from: 'new@example.com' }, original[0].actions);
  const plan = getReplacementPlan(original, [value]);
  for (const output of [plan.changed, plan.filters]) {
    const xml = toXml(output);
    assert.match(xml, /name='size' value='2'/);
    assert.match(xml, /name='sizeUnit' value='s_smb'/);
    assert.equal(buildQuery(parseXml(xml)[0]), 'from:(new@example.com) smaller:2M');
  }
});

test('replacement plan blocks loss of unsupported original properties', () => {
  const original = parseXml(xmlWith(property('from', 'old@example.com') + property('futureAction', 'true')));
  assert.throws(() => getReplacementPlan(original, [proposal('fix', [1], { from: 'new@example.com' }, {})]), /unsupported setting/);
});

test('malformed JSON values in proposals produce warnings instead of throwing', () => {
  for (const value of [
    { kind: 'new', replacesPositions: [], criteria: { from: { toString: 1 } }, actions: {}, exampleEmailIndexes: [] },
    { kind: 'new', replacesPositions: [], criteria: { from: 'x@example.com', size: { toString: null } }, actions: {}, exampleEmailIndexes: [] },
    { kind: 'new', replacesPositions: [], criteria: { from: 'x@example.com' }, actions: { label: { toString: 1 } }, exampleEmailIndexes: [] },
  ]) {
    assert.doesNotThrow(() => validateProposal(value, []));
    assert.ok(validateProposal(value, []).length);
  }
  assert.doesNotThrow(() => emptyFilter({ warnings: 42 }));
});

test('normalization is independent and action descriptions are readable', () => {
  const one = emptyFilter(), two = emptyFilter(); one.actions.label = 'Changed';
  assert.equal(two.actions.label, '');
  assert.deepEqual(two.criteria, CRITERIA_DEFAULTS); assert.deepEqual(two.actions, ACTION_DEFAULTS);
  assert.equal(describeActions(two), 'No actions');
  assert.equal(describeActions(make(1, {}, { label: 'Bills', archive: true, markRead: true })), 'Label: Bills · Archive · Mark read');
});
