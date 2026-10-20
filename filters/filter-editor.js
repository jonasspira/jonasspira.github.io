// Local editing helpers: no browser storage, Gmail access, or AI calls.
import { CRITERIA_DEFAULTS, buildQuery } from './filter-model.js';

const TEXT_FIELDS = ['from', 'to', 'subject', 'hasTheWord', 'doesNotHaveTheWord'];
const BOOL_FIELDS = ['hasAttachment', 'excludeChats'];
const QUICK_ADD_ERROR = 'Enter plain sender addresses or domains, separated by commas or new lines. Use the matching fields below for a Gmail search expression.';
const MIXED_SENDER_ERROR = 'This filter combines sender rules in Has words or Does not have. Edit those matching fields directly so adding a sender does not create an extra restriction.';

function validDomain(value) {
  if (value.length > 253 || !value.includes('.')) return false;
  return value.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
}

function validSender(value) {
  if (value.startsWith('@')) return validDomain(value.slice(1));
  const at = value.indexOf('@');
  if (at < 0) return validDomain(value);
  if (at !== value.lastIndexOf('@')) return false;
  const local = value.slice(0, at);
  return local.length <= 64 && !local.includes('..') &&
    /^[a-z0-9_](?:[a-z0-9._%+-]*[a-z0-9_%+-])?$/i.test(local) && validDomain(value.slice(at + 1));
}

export function parseSenderAdditions(text) {
  if (typeof text !== 'string') throw new Error(QUICK_ADD_ERROR);
  const result = [], seen = new Set();
  for (const item of text.split(/[,;\r\n]+/)) {
    const value = item.trim();
    if (!value) continue;
    if (!validSender(value)) throw new Error(QUICK_ADD_ERROR);
    const key = value.toLowerCase();
    if (!seen.has(key)) { seen.add(key); result.push(key); }
  }
  return result;
}

// Record whole groups and validate only punctuation, without interpreting Gmail's
// remaining search language. Apostrophes are literal; Gmail phrases use double quotes.
function groups(text) {
  const stack = [], pairs = new Map(); let quoted = false, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (escaped) { escaped = false; continue; }
    if (char === '\\') { escaped = true; continue; }
    if (char === '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if ('({['.includes(char)) stack.push([char, i]);
    if (')}]'.includes(char)) {
      const open = stack.pop();
      if (!open || open[0] !== { ')': '(', '}': '{', ']': '[' }[char]) throw new Error('Fix unmatched brackets or quotes in the existing sender expression before adding senders.');
      pairs.set(open[1], i);
    }
  }
  if (quoted || escaped || stack.length) throw new Error('Fix unmatched brackets or quotes in the existing sender expression before adding senders.');
  return pairs;
}

function wholeGroup(text, open = '(') {
  return text[0] === open && groups(text).get(0) === text.length - 1;
}

function splitOutsideGroups(text, whitespace = false) {
  const pairs = groups(text), result = []; let start = 0, quoted = false, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (escaped) { escaped = false; continue; }
    if (char === '\\') { escaped = true; continue; }
    if (char === '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if (pairs.has(i)) { i = pairs.get(i); continue; }
    const separator = whitespace ? /\s/.test(char) : text.slice(i, i + 2) === 'OR' &&
      (i === 0 || /\s/.test(text[i - 1])) && (i + 2 === text.length || /\s/.test(text[i + 2]));
    if (separator) {
      const item = text.slice(start, i).trim(); if (item) result.push(item);
      if (!whitespace) i++;
      start = i + 1;
    }
  }
  const last = text.slice(start).trim(); if (last) result.push(last);
  return result;
}

function literalKey(text) {
  let value = text.trim();
  while (wholeGroup(value)) value = value.slice(1, -1).trim();
  if (value.startsWith('"') && value.endsWith('"') && value.slice(1, -1).indexOf('"') < 0) value = value.slice(1, -1);
  return validSender(value) ? value.toLowerCase() : '';
}

// Only independent positive OR branches count as existing alternatives. A sender
// hidden in an AND group or exclusion must not suppress a genuinely new alternative.
function knownAlternatives(text, depth = 0) {
  if (depth > 32) return [];
  let value = text.trim();
  while (wholeGroup(value)) value = value.slice(1, -1).trim();
  if (wholeGroup(value, '{')) return splitOutsideGroups(value.slice(1, -1), true).flatMap(part => knownAlternatives(part, depth + 1));
  const branches = splitOutsideGroups(value);
  if (branches.length > 1) return branches.flatMap(part => knownAlternatives(part, depth + 1));
  const key = literalKey(value);
  return key ? [key] : [];
}

export function addSenderTerms(baseFrom, addedText) {
  if (typeof baseFrom !== 'string') throw new Error('The existing sender rule must be text.');
  const additions = parseSenderAdditions(addedText);
  if (!additions.length) return baseFrom;
  const base = baseFrom.trim();
  if (!base) return additions.join(' OR ');
  groups(base);
  const existing = new Set(knownAlternatives(base));
  const fresh = additions.filter(value => !existing.has(value));
  if (!fresh.length) return baseFrom;
  const operand = literalKey(base) || wholeGroup(base) || wholeGroup(base, '{') || splitOutsideGroups(base).length > 1 ? base : `(${base})`;
  return `${operand} OR ${fresh.join(' OR ')}`;
}

export function cloneForEditing(filter) {
  if (!filter || typeof filter !== 'object' || Array.isArray(filter) ||
    !filter.criteria || typeof filter.criteria !== 'object' || Array.isArray(filter.criteria) ||
    !filter.actions || typeof filter.actions !== 'object' || Array.isArray(filter.actions)) {
    throw new Error('Choose an existing filter to edit.');
  }
  return structuredClone(filter);
}

export function applyCriteriaEdit(filter, patch) {
  const result = cloneForEditing(filter);
  if (!patch || typeof patch !== 'object' || Array.isArray(patch) || Object.keys(patch).some(key => !Object.hasOwn(CRITERIA_DEFAULTS, key))) {
    throw new Error('Only the matching fields shown here can be edited.');
  }
  for (const [key, value] of Object.entries(patch)) {
    if (TEXT_FIELDS.includes(key) && (typeof value !== 'string' || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/.test(value))) throw new Error('Matching fields must contain valid text.');
    if (BOOL_FIELDS.includes(key) && typeof value !== 'boolean') throw new Error('Attachment and chat options must be checked or unchecked.');
    if (key === 'size' && value !== null && (!Number.isSafeInteger(value) || value < 0)) throw new Error('Enter a whole message size in bytes, or leave it empty.');
    if (key === 'sizeComparison' && !['', 'larger', 'smaller'].includes(value)) throw new Error('Choose larger or smaller for the message size.');
    result.criteria[key] = value;
  }
  if (Object.hasOwn(patch, 'size') && result.criteria.size === null) result.criteria.sizeComparison = '';
  if (Object.hasOwn(patch, 'size') && result.criteria.size != null && !result.criteria.sizeComparison) result.criteria.sizeComparison = 'larger';
  return result;
}

function unquotedText(text) {
  let result = '', quoted = false, escaped = false;
  for (const char of text) {
    if (escaped) { result += ' '; escaped = false; continue; }
    if (char === '\\') { escaped = true; result += ' '; continue; }
    if (char === '"') { quoted = !quoted; result += ' '; continue; }
    result += quoted ? ' ' : char;
  }
  return result;
}
function containsFrom(text) { return /(?:^|[\s({])-?from\s*:/i.test(unquotedText(text)); }

function standaloneFrom(text) {
  const head = /^\s*from:\s*/i.exec(text);
  if (!head) return null;
  const rest = text.slice(head[0].length).trimEnd(), trailing = text.slice(head[0].length + rest.length);
  try {
    if (wholeGroup(rest)) {
      return { value: rest.slice(1, -1), prefix: head[0] + rest[0], suffix: rest.at(-1) + trailing };
    }
    if (wholeGroup(rest, '{')) return { value: rest, prefix: head[0] + '(', suffix: ')' + trailing };
    if (literalKey(rest)) return { value: rest, prefix: head[0] + '(', suffix: ')' + trailing };
  } catch { /* Complex or malformed criteria need direct field editing. */ }
  return null;
}

export function getSenderTarget(filter) {
  const criteria = filter?.criteria || {};
  const from = typeof criteria.from === 'string' ? criteria.from : '';
  const words = typeof criteria.hasTheWord === 'string' ? criteria.hasTheWord : '';
  const excluded = typeof criteria.doesNotHaveTheWord === 'string' ? criteria.doesNotHaveTheWord : '';
  const blocked = () => ({ field: null, value: '', prefix: '', suffix: '', reason: MIXED_SENDER_ERROR });
  if (containsFrom(excluded)) return blocked();
  if (containsFrom(words)) {
    if (from.trim()) return blocked();
    const standalone = standaloneFrom(words);
    return standalone ? { field: 'hasTheWord', ...standalone, reason: '' } : blocked();
  }
  return { field: 'from', value: from, prefix: '', suffix: '', reason: '' };
}

export function extendFilterSenders(filter, addedText) {
  const target = getSenderTarget(filter);
  if (!target.field) throw new Error(target.reason);
  const value = addSenderTerms(target.value, addedText);
  const result = cloneForEditing(filter);
  if (value !== target.value) result.criteria[target.field] = target.prefix + value + target.suffix;
  return result;
}

export function getGmailFieldValues(filter) {
  const source = cloneForEditing(filter), criteria = source.criteria;
  const fields = {};
  const warnings = [...(Array.isArray(source.warnings) ? source.warnings.filter(value => typeof value === 'string') : [])];
  let complete = true;
  for (const key of TEXT_FIELDS) {
    fields[key] = typeof criteria[key] === 'string' ? criteria[key] : '';
    if (criteria[key] != null && typeof criteria[key] !== 'string') { complete = false; warnings.push('A matching field has an unsupported value.'); }
    try { groups(fields[key]); } catch { complete = false; warnings.push(`Check unmatched brackets or quotes in ${key}.`); }
  }
  for (const key of BOOL_FIELDS) {
    fields[key] = criteria[key] === true;
    if (criteria[key] != null && typeof criteria[key] !== 'boolean') { complete = false; warnings.push('A matching option has an unsupported value.'); }
  }
  fields.size = criteria.size == null ? null : criteria.size;
  fields.sizeComparison = typeof criteria.sizeComparison === 'string' ? criteria.sizeComparison : '';
  fields.sizeUnit = 'bytes';
  if (fields.size != null && (!Number.isSafeInteger(fields.size) || fields.size < 0 || !['larger', 'smaller'].includes(fields.sizeComparison))) {
    complete = false; warnings.push('The message-size rule cannot be represented safely.');
  }
  if (Object.keys(criteria).some(key => !Object.hasOwn(CRITERIA_DEFAULTS, key))) {
    complete = false; warnings.push('This filter has an additional matching rule. Keep it unchanged in Gmail.');
  }
  if (source.preservation?.xmlProperties?.length) {
    complete = false; warnings.push('This export includes additional settings that are not shown here. Keep them unchanged in Gmail.');
  }
  if (source.preservation?.blockers?.length) {
    complete = false; warnings.push(...source.preservation.blockers);
  }
  fields.query = complete ? buildQuery(source) : '';
  fields.queryAvailable = complete && Boolean(fields.query);
  fields.warnings = [...new Set(warnings)];
  return fields;
}
