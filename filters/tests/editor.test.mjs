import test from 'node:test';
import assert from 'node:assert/strict';
import { emptyFilter, parseXml, toXml, buildQuery } from '../filter-model.js';
import {
  parseSenderAdditions, addSenderTerms, cloneForEditing, applyCriteriaEdit,
  getSenderTarget, extendFilterSenders, getGmailFieldValues,
} from '../filter-editor.js';

const filter = (criteria = {}, actions = { label: 'Jira', archive: true }) => emptyFilter({
  source: 'xml', key: 'baseline-jira', position: 4, criteria, actions,
});
const xml = properties => `<feed xmlns="http://www.w3.org/2005/Atom" xmlns:apps="http://schemas.google.com/apps/2006"><entry>${properties.map(([name, value]) => `<apps:property name="${name}" value="${value}"/>`).join('')}</entry></feed>`;

test('quick-add accepts explicit addresses and domains, deduplicating case without broadening subdomains', () => {
  assert.deepEqual(parseSenderAdditions('Jira.Example.com, jira.example.com\nnotice+updates@jira.example.com; @updates.jira.example.com'), [
    'jira.example.com', 'notice+updates@jira.example.com', '@updates.jira.example.com',
  ]);
  assert.equal(addSenderTerms('', 'jira.example.com\nconfluence.example.net'), 'jira.example.com OR confluence.example.net');
  assert.equal(addSenderTerms('jira.example.com', 'updates.jira.example.com'), 'jira.example.com OR updates.jira.example.com');
  assert.equal(addSenderTerms('jira.example.com', '@jira.example.com'), 'jira.example.com OR @jira.example.com');
});

test('quick-add rejects search operators, URLs, wildcards, display names and malformed entries atomically', () => {
  for (const value of [
    'jira.example.com OR confluence.example.com', 'from:jira.example.com', '-jira.example.com',
    'https://jira.example.com', '*.jira.example.com', 'Jira <notice@jira.example.com>',
    'notice@example.com@evil.example', 'jira..example.com', 'notice..updates@example.com',
    '+orders@example.com', 'example.com/path', 'jira.example.com\nsubject:urgent',
    'a\u0000@example.com', '{jira.example.com}', 'plainword',
  ]) assert.throws(() => parseSenderAdditions(value), /plain sender addresses or domains/);
  assert.throws(() => parseSenderAdditions(['jira.example.com']), /plain sender/);
});

test('adding a duplicate or nothing leaves the original From expression byte-for-byte unchanged', () => {
  const base = '  (JIRA.EXAMPLE.COM OR ("notice@updates.example.net"))  ';
  assert.equal(addSenderTerms(base, 'jira.example.com\nnotice@updates.example.net'), base);
  assert.equal(addSenderTerms(base, ' \n,;'), base);
  assert.equal(addSenderTerms('unbalanced(', ''), 'unbalanced(');
  assert.equal(addSenderTerms('{jira.example.com confluence.example.com}', 'jira.example.com'), '{jira.example.com confluence.example.com}');
});

test('OR additions preserve a complete original AND/exclusion group instead of narrowing it', () => {
  assert.equal(addSenderTerms('jira.example.com AND -robot@example.com', 'new.jira.example.com'),
    '(jira.example.com AND -robot@example.com) OR new.jira.example.com');
  assert.equal(addSenderTerms('(jira.example.com AND -robot@example.com) OR confluence.example.com', 'new.jira.example.com'),
    '(jira.example.com AND -robot@example.com) OR confluence.example.com OR new.jira.example.com');
  assert.equal(addSenderTerms('{jira.example.com confluence.example.com}', 'new.jira.example.com'),
    '{jira.example.com confluence.example.com} OR new.jira.example.com');
  // A sender inside an AND group is not already an independent alternative.
  assert.equal(addSenderTerms('jira.example.com AND -robot@example.com', 'jira.example.com'),
    '(jira.example.com AND -robot@example.com) OR jira.example.com');
  assert.equal(addSenderTerms('-jira.example.com', 'jira.example.com'), '(-jira.example.com) OR jira.example.com');
});

test('existing phrases and nested groups remain intact; malformed punctuation blocks a new addition', () => {
  assert.equal(addSenderTerms('("Jira (Cloud)" AND jira.example.com) OR old.example.com', 'new.example.com'),
    '("Jira (Cloud)" AND jira.example.com) OR old.example.com OR new.example.com');
  assert.equal(addSenderTerms('"Jira OR Confluence"', 'new.example.com'), '("Jira OR Confluence") OR new.example.com');
  for (const value of ['jira.example.com)', '(jira.example.com', '"jira.example.com', '{jira.example.com)', 'jira.example.com\\']) {
    assert.throws(() => addSenderTerms(value, 'new.example.com'), /unmatched brackets or quotes/);
  }
});

test('criteria edits and sender additions preserve actions, source identity and unknown settings independently', () => {
  const original = filter({ from: 'jira.example.com', to: 'team@example.com', subject: 'Task', hasAttachment: true });
  original.criteria.futureCriterion = { keep: ['raw'] };
  original.actions.futureAction = { keep: ['also raw'] };
  original.preservation = { xmlProperties: [{ name: 'futureOption', value: 'keep-me' }], blockers: [], nested: { value: 1 } };
  const before = structuredClone(original);
  const cloned = cloneForEditing(original);
  cloned.preservation.nested.value = 2;
  assert.equal(original.preservation.nested.value, 1);
  const edited = applyCriteriaEdit(original, { from: addSenderTerms(original.criteria.from, 'new.jira.example.com'), subject: 'Issue' });
  assert.equal(edited.source, original.source);
  assert.equal(edited.key, original.key);
  assert.equal(edited.position, original.position);
  assert.deepEqual(edited.actions, original.actions);
  assert.deepEqual(edited.preservation, original.preservation);
  assert.deepEqual(edited.criteria.futureCriterion, original.criteria.futureCriterion);
  assert.equal(edited.criteria.to, 'team@example.com');
  assert.equal(edited.criteria.hasAttachment, true);
  edited.actions.futureAction.keep.push('separate');
  assert.deepEqual(original, before);
  assert.throws(() => applyCriteriaEdit(original, { unknown: 'discard?' }), /Only the matching fields/);
});

test('blank and optional matching fields can be edited without dropping existing actions or XML size metadata', () => {
  const original = parseXml(xml([
    ['from', 'jira.example.com'], ['label', 'Jira'], ['shouldArchive', 'true'],
    ['subject', 'Old subject'], ['hasAttachment', 'true'], ['excludeChats', 'true'],
    ['size', '2'], ['sizeOperator', 's_ss'], ['sizeUnit', 's_smb'],
  ]))[0];
  const edited = applyCriteriaEdit(original, { subject: '', to: 'team@example.com', doesNotHaveTheWord: 'internal', hasAttachment: false });
  assert.equal(edited.criteria.excludeChats, true);
  assert.deepEqual(edited.preservation, original.preservation);
  const roundtrip = parseXml(toXml([edited]))[0];
  assert.deepEqual(roundtrip.criteria, edited.criteria);
  assert.deepEqual(roundtrip.actions, original.actions);
  assert.match(buildQuery(edited), /smaller:2M$/);
  assert.equal(applyCriteriaEdit(edited, { size: null }).criteria.sizeComparison, '');
  assert.equal(applyCriteriaEdit(filter(), { size: 1000 }).criteria.sizeComparison, 'larger');
  for (const patch of [{ size: -1 }, { size: 1.5 }, { size: NaN }, { size: '1000' }, { from: null }, { hasAttachment: 'true' }, { sizeComparison: 'approximate' }]) {
    assert.throws(() => applyCriteriaEdit(original, patch));
  }
});

test('quick-add routes a standalone sender search in Has words without introducing an ANDed From field', () => {
  for (const words of ['from:(jira.example.com OR old.example.com)', 'from:jira.example.com', '  FROM: (jira.example.com)  ']) {
    const original = filter({ hasTheWord: words });
    assert.equal(getSenderTarget(original).field, 'hasTheWord');
    const edited = extendFilterSenders(original, 'new.jira.example.com');
    assert.equal(edited.criteria.from, '');
    assert.match(edited.criteria.hasTheWord, /jira\.example\.com.* OR new\.jira\.example\.com/);
    assert.deepEqual(edited.actions, original.actions);
    assert.equal(original.criteria.hasTheWord, words);
  }
  const braces = extendFilterSenders(filter({ hasTheWord: 'from:{jira.example.com confluence.example.com}' }), 'new.example.com');
  assert.equal(braces.criteria.hasTheWord, 'from:({jira.example.com confluence.example.com} OR new.example.com)');
  assert.equal(braces.criteria.from, '');
  const noChange = filter({ hasTheWord: ' FROM:jira.example.com  ' });
  assert.deepEqual(extendFilterSenders(noChange, 'JIRA.EXAMPLE.COM'), noChange);
});

test('mixed sender clauses block quick-add but standard matching fields remain directly editable', () => {
  const originals = [
    filter({ from: 'jira.example.com', hasTheWord: 'from:old.example.com' }),
    filter({ hasTheWord: 'from:(jira.example.com) subject:urgent' }),
    filter({ hasTheWord: '(from:(jira.example.com) subject:urgent) OR (from:old.example.com)' }),
    filter({ from: 'jira.example.com', doesNotHaveTheWord: 'from:robot@example.com' }),
    filter({ hasTheWord: 'from:(jira.example.com) OR subject:urgent' }),
    filter({ hasTheWord: '-from:jira.example.com' }),
  ];
  for (const original of originals) {
    assert.equal(getSenderTarget(original).field, null);
    assert.match(getSenderTarget(original).reason, /Edit those matching fields directly/);
    assert.throws(() => extendFilterSenders(original, 'new.example.com'), /extra restriction/);
    assert.equal(applyCriteriaEdit(original, { subject: 'Changed directly' }).criteria.subject, 'Changed directly');
  }
  const ordinary = filter({ hasTheWord: 'subject:urgent "from:literal"', doesNotHaveTheWord: '"From: a quoted phrase"' });
  assert.equal(getSenderTarget(ordinary).field, 'from');
  assert.equal(extendFilterSenders(ordinary, 'jira.example.com').criteria.from, 'jira.example.com');
});

test('Gmail field values retain the standard criteria and complete search without mixing actions into matching syntax', () => {
  const original = filter({ from: 'jira.example.com OR new.jira.example.com', to: 'team@example.com', subject: 'Task', hasTheWord: 'project:EXAMPLE', doesNotHaveTheWord: 'internal', hasAttachment: true, excludeChats: true, size: 1500, sizeComparison: 'larger' },
    { label: 'Jira', archive: true, star: true, neverSpam: true });
  const fields = getGmailFieldValues(original);
  for (const key of ['from', 'to', 'subject', 'hasTheWord', 'doesNotHaveTheWord', 'hasAttachment', 'excludeChats', 'size', 'sizeComparison']) assert.equal(fields[key], original.criteria[key]);
  assert.equal(fields.sizeUnit, 'bytes');
  assert.equal(fields.queryAvailable, true);
  assert.equal(fields.query, buildQuery(original));
  assert.doesNotMatch(fields.query, /label:|archive|star|spam/);
  assert.deepEqual(fields.warnings, []);
});

test('unknown export properties, blockers and unknown criteria never produce a falsely complete search', () => {
  const extra = parseXml(xml([['from', 'jira.example.com'], ['label', 'Jira'], ['futureOption', 'preserve']]))[0];
  const blocked = parseXml(xml([['from', 'jira.example.com'], ['size', '1'], ['sizeUnit', 'unknown-unit']]))[0];
  const unknown = filter({ from: 'jira.example.com', futureCriterion: 'preserve' });
  for (const original of [extra, blocked, unknown]) {
    const fields = getGmailFieldValues(original);
    assert.equal(fields.from, 'jira.example.com');
    assert.equal(fields.queryAvailable, false);
    assert.equal(fields.query, '');
    assert.ok(fields.warnings.length);
    const edited = extendFilterSenders(original, 'new.jira.example.com');
    assert.deepEqual(edited.preservation, original.preservation);
    assert.deepEqual(edited.actions, original.actions);
  }
  assert.equal(getGmailFieldValues(filter()).queryAvailable, false);
  assert.equal(getGmailFieldValues(filter({ from: '(broken' })).queryAvailable, false);
});
