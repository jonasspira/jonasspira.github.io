// Gmail filter conversions and checks. This module intentionally has no DOM or network access.
export const CRITERIA_DEFAULTS = Object.freeze({
  from: '', to: '', subject: '', hasTheWord: '', doesNotHaveTheWord: '',
  hasAttachment: false, size: null, sizeComparison: '', excludeChats: false,
});
export const ACTION_DEFAULTS = Object.freeze({
  label: '', archive: false, markRead: false, star: false, trash: false,
  neverSpam: false, alwaysImportant: false, neverImportant: false, forwardTo: '', category: '',
});
const ACTION_XML = {
  label: 'label', archive: 'shouldArchive', markRead: 'shouldMarkAsRead', star: 'shouldStar',
  trash: 'shouldTrash', neverSpam: 'shouldNeverSpam', alwaysImportant: 'shouldAlwaysMarkAsImportant',
  neverImportant: 'shouldNeverMarkAsImportant', forwardTo: 'forwardTo', category: 'smartLabelToApply',
};
const TEXT_CRITERIA = ['from', 'to', 'subject', 'hasTheWord', 'doesNotHaveTheWord'];
const BOOL_CRITERIA = ['hasAttachment', 'excludeChats'];
const KNOWN_XML = new Set([...TEXT_CRITERIA, ...BOOL_CRITERIA, 'size', 'sizeOperator', 'sizeUnit', ...Object.values(ACTION_XML)]);
const UNITS = { s_sb: { factor: 1, suffix: '' }, s_skb: { factor: 1000, suffix: 'K' }, s_smb: { factor: 1000000, suffix: 'M' } };
const CATEGORY_XML = { CATEGORY_PERSONAL: '^smartlabel_personal', CATEGORY_SOCIAL: '^smartlabel_social', CATEGORY_UPDATES: '^smartlabel_notification', CATEGORY_FORUMS: '^smartlabel_group', CATEGORY_PROMOTIONS: '^smartlabel_promo' };
const MAX_QUERY = 1500; // Conservative product limit; Gmail does not publish a stable filter-query limit.
const copy = value => JSON.parse(JSON.stringify(value));
// Invalid JSON field types must be warnable, rather than throwing during a preview.
const string = value => value == null || typeof value === 'object' ? '' : String(value);
const active = value => value !== '' && value !== false && value != null;

export function emptyFilter(overrides = {}) {
  const criteria = { ...CRITERIA_DEFAULTS, ...(overrides.criteria || {}) };
  const actions = { ...ACTION_DEFAULTS, ...(overrides.actions || {}) };
  for (const key of TEXT_CRITERIA) criteria[key] = string(criteria[key]);
  for (const key of BOOL_CRITERIA) criteria[key] = criteria[key] === true;
  criteria.size = criteria.size === '' || criteria.size == null ? null : typeof criteria.size === 'number' || typeof criteria.size === 'string' ? Number(criteria.size) : NaN;
  criteria.sizeComparison = string(criteria.sizeComparison);
  for (const [key, fallback] of Object.entries(ACTION_DEFAULTS)) actions[key] = typeof fallback === 'boolean' ? actions[key] === true : string(actions[key]);
  const position = Number.isInteger(overrides.position) && overrides.position > 0 ? overrides.position : 1;
  const source = ['live', 'xml', 'new'].includes(overrides.source) ? overrides.source : 'new';
  return { key: overrides.key || `${source}-${position}`, position, source, criteria, actions,
    warnings: Array.isArray(overrides.warnings) ? overrides.warnings.map(string) : [], ...(overrides.preservation && typeof overrides.preservation === 'object' ? { preservation: copy(overrides.preservation) } : {}) };
}

function xmlError(message) { throw new Error(`Invalid Gmail XML: ${message}`); }
function decode(value) {
  if (/&(?!amp;|lt;|gt;|quot;|apos;|#\d+;|#x[\da-fA-F]+;)/.test(value)) xmlError('unknown or incomplete entity.');
  return value.replace(/&(#x[\da-fA-F]+|#\d+|amp|lt|gt|quot|apos);/g, (_, entity) => {
    if (entity[0] === '#') {
      const point = entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      if (!(point === 9 || point === 10 || point === 13 || (point >= 32 && point <= 0xD7FF) || (point >= 0xE000 && point <= 0xFFFD) || (point >= 0x10000 && point <= 0x10FFFF))) xmlError('invalid character entity.');
      return String.fromCodePoint(point);
    }
    return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[entity.toLowerCase()];
  });
}
function escapeXml(value) {
  const text = string(value);
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/.test(text) || /[\uD800-\uDFFF]/u.test(text)) throw new Error('A filter contains a character that XML cannot represent. Remove the invalid character before downloading.');
  return text.replace(/[&'"<>]/g, char => ({ '&': '&amp;', "'": '&apos;', '"': '&quot;', '<': '&lt;', '>': '&gt;' }[char]));
}

// A small, strict XML reader, rather than a regex that silently accepts truncated exports.
// DTDs and custom entities are rejected; no external resources can be loaded.
function readXml(xml) {
  if (typeof xml !== 'string' || !xml.trim()) xmlError('choose or paste a filter export.');
  if (xml.length > 5000000) xmlError('file exceeds the 5 MB limit.');
  if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(xml)) xmlError('invalid control character.');
  const document = { name: '#document', attrs: {}, children: [], text: '' }, stack = [document];
  let offset = xml.charCodeAt(0) === 0xFEFF ? 1 : 0;
  while (offset < xml.length) {
    if (xml[offset] !== '<') {
      const end = xml.indexOf('<', offset), text = xml.slice(offset, end < 0 ? xml.length : end);
      if (text.includes(']]>')) xmlError('unexpected CDATA ending.');
      stack.at(-1).text += decode(text); offset = end < 0 ? xml.length : end; continue;
    }
    if (xml.startsWith('<!--', offset)) {
      const end = xml.indexOf('-->', offset + 4);
      if (end < 0 || xml.slice(offset + 4, end).includes('--')) xmlError('unfinished comment.');
      offset = end + 3; continue;
    }
    if (xml.startsWith('<?', offset)) {
      const end = xml.indexOf('?>', offset + 2);
      if (end < 0) xmlError('unfinished XML declaration.');
      offset = end + 2; continue;
    }
    if (xml.startsWith('<![CDATA[', offset)) {
      const end = xml.indexOf(']]>', offset + 9);
      if (end < 0 || stack.length === 1) xmlError('invalid CDATA.');
      stack.at(-1).text += xml.slice(offset + 9, end); offset = end + 3; continue;
    }
    if (xml.startsWith('<!', offset)) xmlError('document types and custom entities are not supported.');
    let end = offset + 1, quote = '';
    for (; end < xml.length; end++) {
      const char = xml[end];
      if (quote) { if (char === quote) quote = ''; }
      else if (char === '"' || char === "'") quote = char;
      else if (char === '>') break;
      else if (char === '<') xmlError('unexpected opening bracket.');
    }
    if (end === xml.length) xmlError('unfinished tag.');
    const tag = xml.slice(offset + 1, end); offset = end + 1;
    if (tag.startsWith('/')) {
      const match = /^\/([A-Za-z_][\w.:-]*)\s*$/.exec(tag);
      if (!match || stack.length === 1 || stack.at(-1).name !== match[1]) xmlError('mismatched closing tag.');
      stack.pop(); continue;
    }
    const selfClosing = /\/\s*$/.test(tag), body = selfClosing ? tag.replace(/\/\s*$/, '') : tag;
    const head = /^([A-Za-z_][\w.:-]*)([\s\S]*)$/.exec(body);
    if (!head) xmlError('invalid tag.');
    const attrs = Object.create(null); let rest = head[2];
    while (rest.trim()) {
      const attribute = /^\s+([A-Za-z_][\w.:-]*)\s*=\s*(['"])([\s\S]*?)\2/.exec(rest);
      if (!attribute || Object.hasOwn(attrs, attribute[1]) || attribute[3].includes('<')) xmlError('invalid or repeated attribute.');
      attrs[attribute[1]] = decode(attribute[3]); rest = rest.slice(attribute[0].length);
    }
    const node = { name: head[1], attrs, children: [], text: '' };
    stack.at(-1).children.push(node);
    if (!selfClosing) stack.push(node);
    if (stack.length > 30) xmlError('too many nested tags.');
  }
  if (stack.length !== 1 || document.children.length !== 1 || document.text.trim()) xmlError('incomplete or multiple root elements.');
  const root = document.children[0];
  if (root.name !== 'feed' || root.attrs.xmlns !== 'http://www.w3.org/2005/Atom') xmlError('expected a Gmail Atom feed.');
  return root;
}

function boolProperty(value, name) {
  if (value !== 'true' && value !== 'false') xmlError(`${name} must be true or false.`);
  return value === 'true';
}
export function parseXml(xml) {
  const root = readXml(xml);
  if (root.children.some(node => !['entry', 'title', 'id', 'updated', 'author'].includes(node.name))) xmlError('unexpected element in the feed.');
  const propertyPrefixes = new Set(Object.entries(root.attrs).filter(([name, value]) => name.startsWith('xmlns:') && value === 'http://schemas.google.com/apps/2006').map(([name]) => `${name.slice(6)}:property`));
  return root.children.filter(node => node.name === 'entry').map((entry, index) => {
    const properties = {}, extras = [], warnings = [], blockers = [];
    for (const node of entry.children) {
      if (!propertyPrefixes.has(node.name)) {
        if (!['category', 'title', 'id', 'updated', 'author', 'content'].includes(node.name)) blockers.push(`Unsupported XML element ${node.name}.`);
        continue;
      }
      if (!Object.hasOwn(node.attrs, 'name') || !Object.hasOwn(node.attrs, 'value') || node.children.length || node.text.trim()) xmlError('filter property is missing its name or value.');
      const { name, value } = node.attrs;
      if (!KNOWN_XML.has(name)) { extras.push({ name, value }); warnings.push(`Unrecognized property “${name}” is preserved in downloads.`); }
      else {
        if (Object.hasOwn(properties, name)) xmlError(`repeated filter property ${name}.`);
        properties[name] = value;
      }
    }
    if (!Object.keys(properties).length && !extras.length) xmlError(`entry ${index + 1} has no filter properties.`);
    const filter = emptyFilter({ source: 'xml', position: index + 1, warnings });
    for (const name of TEXT_CRITERIA) if (Object.hasOwn(properties, name)) filter.criteria[name] = properties[name];
    for (const name of BOOL_CRITERIA) if (Object.hasOwn(properties, name)) filter.criteria[name] = boolProperty(properties[name], name);
    for (const [key, name] of Object.entries(ACTION_XML)) if (Object.hasOwn(properties, name)) filter.actions[key] = typeof ACTION_DEFAULTS[key] === 'boolean' ? boolProperty(properties[name], name) : properties[name];
    const category = Object.entries(CATEGORY_XML).find(([, value]) => value === filter.actions.category);
    if (category) filter.actions.category = category[0];
    const size = { value: properties.size ?? '', operator: properties.sizeOperator ?? 's_sl', unit: properties.sizeUnit ?? 's_smb' };
    if (size.value !== '') {
      if (!/^\d+(?:\.\d+)?$/.test(size.value)) xmlError('size must be a positive number.');
      if (!UNITS[size.unit] || !['s_sl', 's_ss'].includes(size.operator)) {
        blockers.push('Unknown XML size unit or comparison; download the original export instead.');
        warnings.push(blockers.at(-1));
      } else {
        filter.criteria.size = Number(size.value) * UNITS[size.unit].factor;
        filter.criteria.sizeComparison = size.operator === 's_ss' ? 'smaller' : 'larger';
      }
    }
    filter.preservation = { xmlProperties: extras, xmlSize: size, sizeBaseline: { size: filter.criteria.size, sizeComparison: filter.criteria.sizeComparison }, blockers };
    filter.warnings = [...new Set([...warnings, ...blockers])];
    return filter;
  });
}

export function fromGmail(filters, labels = []) {
  const labelMap = new Map((Array.isArray(labels) ? labels : labels.labels || []).map(label => [label.id, label]));
  const list = Array.isArray(filters) ? filters : filters.filter || [];
  if (!Array.isArray(list)) throw new Error('Gmail returned an invalid filter list.');
  return list.map((raw, index) => {
    const criteria = raw.criteria || {}, action = raw.action || {}, blockers = [], warnings = [];
    const filter = emptyFilter({ key: raw.id || `live-${index + 1}`, source: 'live', position: index + 1,
      criteria: { ...criteria, hasTheWord: criteria.query || '', doesNotHaveTheWord: criteria.negatedQuery || '' },
      actions: { forwardTo: action.forward || '' } });
    delete filter.criteria.query; delete filter.criteria.negatedQuery;
    const userLabels = [];
    for (const id of action.addLabelIds || []) {
      if (id === 'STARRED') filter.actions.star = true;
      else if (id === 'TRASH') filter.actions.trash = true;
      else if (id === 'IMPORTANT') filter.actions.alwaysImportant = true;
      else if (/^CATEGORY_/.test(id)) {
        if (filter.actions.category) blockers.push('Several category actions cannot be represented in one Gmail import filter.');
        filter.actions.category = id;
        if (!CATEGORY_XML[id]) blockers.push(`Category ${id} has no known Gmail import representation.`);
      } else if (labelMap.get(id)?.type === 'user' || (/^Label_/.test(id) && labelMap.has(id))) userLabels.push(labelMap.get(id).name);
      else blockers.push(`Unrecognized added label ${id}; its action cannot be exported safely.`);
    }
    for (const id of action.removeLabelIds || []) {
      if (id === 'INBOX') filter.actions.archive = true;
      else if (id === 'UNREAD') filter.actions.markRead = true;
      else if (id === 'IMPORTANT') filter.actions.neverImportant = true;
      else if (id === 'SPAM') filter.actions.neverSpam = true;
      else blockers.push(`Removing label ${id} cannot be represented in a Gmail import file.`);
    }
    filter.actions.label = userLabels[0] || '';
    if (userLabels.length > 1) blockers.push(`This filter applies ${userLabels.length} user labels (${userLabels.join(', ')}). Gmail import supports one; export is blocked to preserve every label.`);
    const knownCriteria = new Set(['from', 'to', 'subject', 'query', 'negatedQuery', 'hasAttachment', 'excludeChats', 'size', 'sizeComparison']);
    const unknownCriteria = Object.keys(criteria).filter(key => !knownCriteria.has(key));
    const unknownActions = Object.keys(action).filter(key => !['addLabelIds', 'removeLabelIds', 'forward'].includes(key));
    if (unknownCriteria.length) blockers.push(`Unrecognized API criteria: ${unknownCriteria.join(', ')}.`);
    if (unknownActions.length) blockers.push(`Unrecognized API actions: ${unknownActions.join(', ')}.`);
    if (filter.criteria.size != null && (!Number.isSafeInteger(filter.criteria.size) || filter.criteria.size < 0 || !['larger', 'smaller'].includes(filter.criteria.sizeComparison))) blockers.push('Unsupported API size comparison.');
    filter.warnings = [...warnings, ...blockers];
    filter.preservation = { blockers, userLabels, rawApi: copy(raw) };
    return filter;
  });
}

function sizeQuery(filter) {
  const { size, sizeComparison } = filter.criteria;
  if (size == null) return '';
  const original = filter.preservation?.xmlSize, baseline = filter.preservation?.sizeBaseline;
  if (original?.value !== '' && baseline?.size === size && baseline?.sizeComparison === sizeComparison && UNITS[original?.unit]) return `${sizeComparison}:${original.value}${UNITS[original.unit].suffix}`;
  return `${sizeComparison}:${size}`;
}
export function buildQuery(input) {
  const filter = emptyFilter(input), c = filter.criteria, parts = [];
  if (c.from.trim()) parts.push(`from:(${c.from.trim()})`);
  // Gmail's filter `to` criterion includes To, Cc, and Bcc recipients (API reference).
  if (c.to.trim()) parts.push(`(to:(${c.to.trim()}) OR cc:(${c.to.trim()}) OR bcc:(${c.to.trim()}))`);
  if (c.subject.trim()) parts.push(`subject:(${c.subject.trim()})`);
  if (c.hasTheWord.trim()) parts.push(`(${c.hasTheWord.trim()})`);
  if (c.doesNotHaveTheWord.trim()) parts.push(`-(${c.doesNotHaveTheWord.trim()})`);
  if (c.hasAttachment) parts.push('has:attachment');
  if (c.excludeChats) parts.push('-in:chats');
  if (c.size != null) parts.push(sizeQuery(filter));
  return parts.join(' ');
}

export function toXml(filters) {
  if (!Array.isArray(filters)) throw new Error('Choose a list of filters to download.');
  const entries = filters.map((input, index) => {
    const filter = emptyFilter(input), blockers = filter.preservation?.blockers || [];
    if (blockers.length) throw new Error(`Filter ${filter.position}: ${blockers.join(' ')}`);
    if (!buildQuery(filter)) throw new Error(`Filter ${filter.position}: empty criteria cannot be downloaded.`);
    if (Object.keys(filter.criteria).some(key => !Object.hasOwn(CRITERIA_DEFAULTS, key)) || Object.keys(filter.actions).some(key => !Object.hasOwn(ACTION_DEFAULTS, key))) throw new Error(`Filter ${filter.position}: an unsupported criterion or action cannot be exported safely.`);
    const props = [];
    for (const name of TEXT_CRITERIA) if (filter.criteria[name] !== '') props.push([name, filter.criteria[name]]);
    for (const name of BOOL_CRITERIA) if (filter.criteria[name]) props.push([name, 'true']);
    for (const [key, name] of Object.entries(ACTION_XML)) if (active(filter.actions[key])) {
      if (key === 'category' && !CATEGORY_XML[filter.actions[key]] && filter.source !== 'xml') throw new Error(`Filter ${filter.position}: unknown category action.`);
      props.push([name, key === 'category' ? CATEGORY_XML[filter.actions[key]] || filter.actions[key] : filter.actions[key]]);
    }
    const original = filter.preservation?.xmlSize, baseline = filter.preservation?.sizeBaseline;
    const unchanged = original && baseline?.size === filter.criteria.size && baseline?.sizeComparison === filter.criteria.sizeComparison;
    if (unchanged) {
      if (original.value !== '') props.push(['size', original.value]);
      props.push(['sizeOperator', original.operator], ['sizeUnit', original.unit]);
    } else if (filter.criteria.size != null) {
      if (!Number.isSafeInteger(filter.criteria.size) || filter.criteria.size < 0 || !['larger', 'smaller'].includes(filter.criteria.sizeComparison)) throw new Error(`Filter ${filter.position}: invalid size constraint.`);
      // The API documents bytes. Encode new constraints with Gmail's documented search
      // operators rather than guessing at undocumented export-unit conversion behavior.
      const query = sizeQuery(filter), previous = props.find(prop => prop[0] === 'hasTheWord');
      if (previous) previous[1] = `(${previous[1]}) ${query}`;
      else props.push(['hasTheWord', query]);
      props.push(['sizeOperator', 's_sl'], ['sizeUnit', 's_smb']);
    } else props.push(['sizeOperator', 's_sl'], ['sizeUnit', 's_smb']);
    for (const extra of filter.preservation?.xmlProperties || []) props.push([extra.name, extra.value]);
    return `  <entry>\n    <category term='filter'/>\n    <title>Mail Filter</title>\n    <id>tag:mail.google.com,2008:filter:filters-rev11-${index + 1}</id>\n    <updated>2000-01-01T00:00:00Z</updated>\n    <content/>\n${props.map(([name, value]) => `    <apps:property name='${escapeXml(name)}' value='${escapeXml(value)}'/>`).join('\n')}\n  </entry>`;
  });
  return `<?xml version='1.0' encoding='UTF-8'?>\n<feed xmlns='http://www.w3.org/2005/Atom' xmlns:apps='http://schemas.google.com/apps/2006'>\n  <title>Mail Filters</title>\n${entries.join('\n')}\n</feed>\n`;
}

function syntaxWarnings(text) {
  const warnings = [], stack = []; let quoted = false, escaped = false;
  for (const char of text) {
    if (escaped) { escaped = false; continue; }
    if (char === '\\') { escaped = true; continue; }
    if (char === '"') { quoted = !quoted; continue; }
    if (quoted) continue;
    if ('({['.includes(char)) stack.push(char);
    if (')}]'.includes(char) && stack.pop() !== { ')': '(', '}': '{', ']': '[' }[char]) warnings.push('Unbalanced parentheses, brackets, or braces.');
  }
  if (quoted) warnings.push('Unbalanced quotation marks.');
  if (stack.length) warnings.push('Unbalanced parentheses, brackets, or braces.');
  return [...new Set(warnings)];
}
function signature(filter, part) {
  const model = emptyFilter(filter);
  const values = part === 'actions' ? model.actions : model.criteria;
  return JSON.stringify(Object.fromEntries(Object.keys(part === 'actions' ? ACTION_DEFAULTS : CRITERIA_DEFAULTS).map(key => [key, typeof values[key] === 'string' ? values[key].trim() : values[key]])));
}
function senders(filter) {
  const from = string(filter.criteria?.from).toLowerCase();
  const emails = [...from.matchAll(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}/g)].map(match => match[0]);
  const domains = [...from.matchAll(/(?:^|[\s({|])@?((?:[a-z0-9-]+\.)+[a-z]{2,})(?=$|[\s)}|])/g)].map(match => match[1]);
  return { emails: [...new Set(emails)], domains: [...new Set(domains)], allDomains: [...new Set([...domains, ...emails.map(email => email.split('@')[1])])] };
}
function distanceAtMostTwo(a, b) {
  if (Math.abs(a.length - b.length) > 2) return 3;
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const row = [i];
    for (let j = 1; j <= b.length; j++) row[j] = Math.min(row[j - 1] + 1, previous[j] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    if (Math.min(...row) > 2) return 3;
    previous = row;
  }
  return previous[b.length];
}
export function checkFilters(filters) {
  const findings = [], add = (type, severity, title, detail, positions) => findings.push({ id: `${type}-${findings.length}`, type, severity, title, detail, positions });
  // Index once. A large label/domain should produce one review group, not n² cards.
  const rows = filters.map(input => {
    const filter = emptyFilter(input);
    return { filter, senders: senders(filter), actionKey: signature(filter, 'actions'), criteriaKey: signature(filter, 'criteria') };
  });
  const duplicates = new Map(), mergeGroups = new Map(), emails = new Map(), domains = new Map();
  const index = (map, key, row) => {
    if (!map.has(key)) map.set(key, new Set());
    map.get(key).add(row);
  };
  const positionsOf = members => [...new Set([...members].map(row => row.filter.position))].sort((a, b) => a - b);
  for (const row of rows) {
    const { filter } = row;
    const extras = filter.preservation?.xmlProperties || [];
    const unsupportedApi = filter.preservation?.blockers?.length ? filter.preservation.rawApi || null : null;
    const unsupportedKey = JSON.stringify({ extras, criteria: unsupportedApi?.criteria, action: unsupportedApi?.action });
    index(duplicates, `${row.actionKey}\n${row.criteriaKey}\n${unsupportedKey}`, row);
    if (filter.actions.label && !filter.preservation?.blockers?.length && !filter.preservation?.xmlProperties?.length) index(mergeGroups, row.actionKey, row);
    for (const email of row.senders.emails) index(emails, email, row);
    for (const domain of row.senders.allDomains) index(domains, domain, row);
    const text = TEXT_CRITERIA.map(key => filter.criteria[key]).join(' ');
    for (const key of TEXT_CRITERIA) for (const detail of syntaxWarnings(filter.criteria[key])) add('syntax', 'warning', 'Check filter punctuation', `${key}: ${detail}`, [filter.position]);
    if (/"\s+[^"\s][^"]*"|"[^"\s][^"]*\s+"/.test(text)) add('quoted-space', 'warning', 'Space inside a quoted phrase', 'A leading or trailing space inside quotes may stop this filter from matching.', [filter.position]);
    for (const detail of filter.warnings || []) add('unsupported', 'warning', 'Review a preserved or unsupported setting', detail, [filter.position]);
  }
  for (const members of duplicates.values()) if (members.size > 1) add('duplicate', 'warning', 'Exact duplicate filters', 'These filters have the same criteria and actions.', positionsOf(members));
  for (const members of mergeGroups.values()) if (members.size > 1) add('merge-candidate', 'info', 'Same label and actions', `${members.size} filters use “${members.values().next().value.filter.actions.label}” with the same actions. A merge must retain each complete set of criteria.`, positionsOf(members));

  const overlaps = new Map(), conflicts = new Map();
  const coalesce = (map, members, token) => {
    const positions = positionsOf(members);
    if (positions.length < 2) return;
    const key = positions.join(',');
    if (!map.has(key)) map.set(key, { positions, tokens: [] });
    map.get(key).tokens.push(token);
  };
  const opposite = (candidates, row) => candidates.some(other => other !== row);
  for (const [email, members] of emails) {
    coalesce(overlaps, members, email);
    const labeled = [...members].filter(row => row.filter.actions.label), deleted = [...members].filter(row => row.filter.actions.trash);
    const involved = [...members].filter(row => (row.filter.actions.label && opposite(deleted, row)) || (row.filter.actions.trash && opposite(labeled, row)));
    coalesce(conflicts, involved, email);
  }
  for (const [domain, members] of domains) {
    coalesce(overlaps, members, domain);
    const labeled = [...members].filter(row => row.filter.actions.label), deleted = [...members].filter(row => row.filter.actions.trash);
    const explicitLabels = labeled.filter(row => row.senders.domains.includes(domain)), explicitDeletes = deleted.filter(row => row.senders.domains.includes(domain));
    const involved = [...members].filter(row =>
      (row.filter.actions.label && (opposite(explicitDeletes, row) || (row.senders.domains.includes(domain) && opposite(deleted, row)))) ||
      (row.filter.actions.trash && (opposite(explicitLabels, row) || (row.senders.domains.includes(domain) && opposite(labeled, row)))));
    coalesce(conflicts, involved, domain);
  }
  const tokenSummary = tokens => `${tokens.slice(0, 4).join(', ')}${tokens.length > 4 ? ` (and ${tokens.length - 4} more shared values)` : ''}`;
  for (const group of overlaps.values()) add('sender-overlap', 'info', 'Sender or domain appears more than once', `Shared sender/domain: ${tokenSummary(group.tokens)}.`, group.positions);
  for (const group of conflicts.values()) add('conflict', 'warning', 'A labeled sender is also deleted', `Shared sender/domain: ${tokenSummary(group.tokens)}. Other criteria may narrow the overlap; review these filters together.`, group.positions);

  // Similar-address findings are connected groups, retaining every affected position.
  // Keep a few explanatory examples instead of storing every pair in a large domain.
  const nodes = [...emails].map(([email, members], index) => {
    const [local, domain] = email.split('@');
    return { email, members, local, domain, base: domain.split('.').slice(-2).join('.'), parent: index, examples: [], pairs: 0 };
  });
  const root = index => {
    while (nodes[index].parent !== index) { nodes[index].parent = nodes[nodes[index].parent].parent; index = nodes[index].parent; }
    return index;
  };
  const join = (a, b) => {
    const ra = root(a), rb = root(b), first = nodes[ra], second = nodes[rb];
    if (ra !== rb) { second.parent = ra; first.members = new Set([...first.members, ...second.members]); first.examples = [...first.examples, ...second.examples].slice(0, 3); first.pairs += second.pairs; }
    first.pairs++;
    if (first.examples.length < 3) first.examples.push(`${nodes[a].email} / ${nodes[b].email}`);
  };
  const localBuckets = new Map(), domainBuckets = new Map();
  nodes.forEach((node, i) => { index(localBuckets, `${node.base}\n${node.local}`, i); index(domainBuckets, node.domain, i); });
  for (const [buckets, domainChange] of [[localBuckets, true], [domainBuckets, false]]) for (const members of buckets.values()) {
    const indexes = [...members];
    for (let i = 0; i < indexes.length; i++) for (let j = i + 1; j < indexes.length; j++) {
      const a = nodes[indexes[i]], b = nodes[indexes[j]];
      const distance = distanceAtMostTwo(domainChange ? a.domain : a.local, domainChange ? b.domain : b.local);
      if (domainChange ? distance <= 2 : distance === 1) join(indexes[i], indexes[j]);
    }
  }
  nodes.forEach((node, index) => {
    if (root(index) !== index || !node.pairs) return;
    const positions = positionsOf(node.members);
    if (positions.length < 2) return;
    add('sender-drift', 'warning', 'Similar sender addresses', `Possible address change or typo: ${node.examples.join('; ')}${node.pairs > node.examples.length ? ` (${node.pairs} similar pairs in this group)` : ''}. Confirm with a real message before changing a filter.`, positions);
  });
  return findings;
}

export function mergeFilters(filters) {
  if (!Array.isArray(filters) || filters.length < 2) throw new Error('Choose at least two filters to merge.');
  const normalized = filters.map(emptyFilter), first = normalized[0];
  if (normalized.some(filter => signature(filter, 'actions') !== signature(first, 'actions'))) throw new Error('Only filters with identical actions can be merged.');
  if (normalized.some(filter => filter.preservation?.blockers?.length || filter.preservation?.xmlProperties?.length)) throw new Error('A filter has unsupported settings; merge is blocked to prevent data loss.');
  if (normalized.some(filter => TEXT_CRITERIA.some(key => syntaxWarnings(filter.criteria[key]).length))) throw new Error('Fix unbalanced filter punctuation before merging.');
  const groups = normalized.map(filter => buildQuery(filter));
  if (groups.some(query => !query.trim())) throw new Error('Cannot merge a filter with empty criteria.');
  const query = groups.map(group => `(${group})`).join(' OR ');
  if (query.length > MAX_QUERY) throw new Error(`The merged query exceeds the conservative ${MAX_QUERY}-character limit. Keep separate filters.`);
  return emptyFilter({ source: 'new', position: first.position, key: `merge-${normalized.map(filter => filter.key).join('-')}`, criteria: { hasTheWord: query }, actions: first.actions });
}

export function validateProposal(proposal, filters, emails = []) {
  const warnings = [];
  if (!proposal || typeof proposal !== 'object') return ['The AI did not return a filter object.'];
  if (!['fix', 'extend', 'merge', 'new'].includes(proposal.kind)) warnings.push('Unknown proposal kind.');
  const positions = proposal.replacesPositions;
  if (!Array.isArray(positions)) warnings.push('Missing replacesPositions list.');
  else {
    if (positions.some(position => !Number.isInteger(position) || !filters.some(filter => filter.position === position))) warnings.push('A replacement refers to a filter number that does not exist.');
    if (new Set(positions).size !== positions.length) warnings.push('The replacement lists the same filter more than once.');
    if (proposal.kind === 'new' && positions.length) warnings.push('A new filter cannot replace an existing filter.');
    if (['fix', 'extend'].includes(proposal.kind) && positions.length !== 1) warnings.push('A fix or extension must replace exactly one filter.');
    if (proposal.kind === 'merge' && positions.length < 2) warnings.push('A merge must replace at least two filters.');
  }
  for (const [name, defaults] of [['criteria', CRITERIA_DEFAULTS], ['actions', ACTION_DEFAULTS]]) {
    const value = proposal[name];
    if (!value || typeof value !== 'object' || Array.isArray(value)) { warnings.push(`Missing ${name}.`); continue; }
    for (const key of Object.keys(value)) {
      if (!Object.hasOwn(defaults, key)) warnings.push(`Unknown ${name} field: ${key}.`);
      else if (key === 'size') { if (value[key] != null && (!Number.isSafeInteger(value[key]) || value[key] < 0)) warnings.push('Size must be a nonnegative whole number of bytes.'); }
      else if (typeof defaults[key] === 'boolean' ? typeof value[key] !== 'boolean' : value[key] != null && typeof value[key] !== 'string') warnings.push(`Invalid value for ${name}.${key}.`);
    }
  }
  const model = emptyFilter({ criteria: proposal.criteria, actions: proposal.actions });
  const query = buildQuery(model);
  if (!query) warnings.push('The filter has empty criteria.');
  for (const name of TEXT_CRITERIA) warnings.push(...syntaxWarnings(model.criteria[name]));
  if (query.length > MAX_QUERY) warnings.push(`The query exceeds the conservative ${MAX_QUERY}-character limit.`);
  if (model.criteria.size != null && !['larger', 'smaller'].includes(model.criteria.sizeComparison)) warnings.push('Choose larger or smaller for the size comparison.');
  if (model.actions.alwaysImportant && model.actions.neverImportant) warnings.push('A filter cannot mark messages both important and never important.');
  if (Array.isArray(positions)) for (const position of positions) {
    const original = filters.find(filter => filter.position === position);
    if (!original) continue;
    if (original.preservation?.blockers?.length || original.preservation?.xmlProperties?.length) warnings.push(`Filter ${position} contains settings that this replacement could lose.`);
    if (['fix', 'extend'].includes(proposal.kind)) for (const [key, value] of Object.entries(emptyFilter(original).actions)) {
      if (active(value) && model.actions[key] !== value) warnings.push(`Keep the existing ${key} action from filter ${position}.`);
    }
    if (proposal.kind === 'merge' && signature(original, 'actions') !== signature(model, 'actions')) warnings.push(`The merge changes the actions of filter ${position}.`);
  }
  if (proposal.kind === 'merge' && Array.isArray(positions) && positions.length >= 2) {
    const originals = positions.map(position => filters.find(filter => filter.position === position));
    if (originals.every(Boolean)) {
      try {
        const expected = mergeFilters(originals);
        if (query !== buildQuery(expected)) warnings.push('The merge must preserve each original filter as a complete AND group. Use the tool-generated merge query.');
      } catch (error) { warnings.push(error.message); }
    }
  }
  const exampleIndexes = Array.isArray(proposal.exampleEmailIndexes) ? proposal.exampleEmailIndexes : [];
  if (Array.isArray(proposal.exampleEmailIndexes)) {
    if (exampleIndexes.some(index => !Number.isInteger(index) || index < 0 || index >= emails.length)) warnings.push('An example refers to an email number that does not exist.');
    if (/\blist\s*:/.test(query) && exampleIndexes.length && exampleIndexes.some(index => {
      const email = emails[index] || {}, headers = email.headers || email.payload?.headers || [];
      return !(email.listId || email.list_id || (Array.isArray(headers) ? headers.some(header => typeof header?.name === 'string' && header.name.toLowerCase() === 'list-id' && header.value) : headers['List-Id'] || headers['list-id']));
    })) warnings.push('A list: criterion needs a List-Id header on every cited example.');
  } else warnings.push('Missing exampleEmailIndexes list.');
  if (/\blist\s*:/.test(query) && !exampleIndexes.length) warnings.push('A list: criterion needs a cited email with a List-Id header.');
  if (typeof proposal.gmailSearchQuery === 'string' && proposal.gmailSearchQuery.trim() !== query.trim()) warnings.push('The supplied preview differs from the generated filter query; the tool uses the generated query.');
  return [...new Set(warnings)];
}

export function describeActions(filter) {
  const a = emptyFilter(filter).actions, descriptions = [];
  if (a.label) descriptions.push(`Label: ${a.label}`);
  const names = { archive: 'Archive', markRead: 'Mark read', star: 'Star', trash: 'Delete', neverSpam: 'Never spam', alwaysImportant: 'Always important', neverImportant: 'Never important' };
  for (const [key, label] of Object.entries(names)) if (a[key]) descriptions.push(label);
  if (a.forwardTo) descriptions.push(`Forward to ${a.forwardTo}`);
  if (a.category) descriptions.push(`Category: ${a.category}`);
  return descriptions.join(' · ') || 'No actions';
}

export function getReplacementPlan(filters, proposals) {
  const replacedPositions = new Set();
  for (const proposal of proposals) {
    if (!proposal || !Array.isArray(proposal.replacesPositions) || proposal.replacesPositions.some(position => !Number.isInteger(position) || !filters.some(filter => filter.position === position))) throw new Error('A proposal refers to an unknown filter number.');
    for (const position of proposal.replacesPositions) {
      if (replacedPositions.has(position)) throw new Error(`Two selected proposals replace filter ${position}. Choose one.`);
      const original = filters.find(filter => filter.position === position);
      if (original.preservation?.blockers?.length || original.preservation?.xmlProperties?.length) throw new Error(`Filter ${position} contains an unsupported setting; replacing it could lose data.`);
      replacedPositions.add(position);
    }
  }
  const replaced = filters.filter(filter => replacedPositions.has(filter.position));
  const changed = proposals.map((proposal, index) => {
    const filter = emptyFilter({ source: 'new', position: index + 1, key: `proposal-${index + 1}`, criteria: proposal.criteria, actions: proposal.actions });
    if (['fix', 'extend'].includes(proposal.kind) && proposal.replacesPositions.length === 1) {
      const original = filters.find(item => item.position === proposal.replacesPositions[0]);
      if (original.preservation?.xmlSize && filter.criteria.size === original.criteria.size && filter.criteria.sizeComparison === original.criteria.sizeComparison) filter.preservation = copy(original.preservation);
    }
    return filter;
  });
  const combined = [...filters.filter(filter => !replacedPositions.has(filter.position)), ...changed];
  return { filters: combined.map((filter, index) => ({ ...filter, position: index + 1 })), replaced, changed };
}
