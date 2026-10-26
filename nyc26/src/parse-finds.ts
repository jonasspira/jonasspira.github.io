// Turning whatever an AI tool hands back into candidate places.
//
// Three formats are accepted, tried in this order:
//
//   1. JSON — an array of objects, or an object with a `candidates` array.
//      Useful when a tool is asked for structured output.
//   2. Pipe-delimited lines — `Section | Name | Neighborhood | Why | Address`.
//      This is the format documented in RESEARCH.md, because every tool can
//      produce it reliably and it survives copy and paste.
//   3. Anything else — Markdown headings set the current section and each
//      remaining line becomes a name, so a plain answer is never rejected
//      outright. Expect to tidy those up by hand.
//
// Parsing never throws. Rubbish in gives few or no candidates, not an error.

import { SECTIONS, type Find, type Section } from './trip.ts';

const DEFAULT_SECTION: Section = 'Shopping';

/** Match a section name loosely: "food and drink", "Food & Drink", "FOOD". */
function matchSection(text: string): Section | null {
  const cleaned = text.toLowerCase().replace(/&/g, 'and').replace(/[^a-z ]/g, ' ').trim();
  if (!cleaned) return null;
  for (const section of SECTIONS) {
    const target = section.toLowerCase().replace(/&/g, 'and');
    if (cleaned === target || cleaned.startsWith(target)) return section;
  }
  if (/\bfood\b|\bdrink\b|\beat\b|\brestaurant/.test(cleaned)) return 'Food & Drink';
  if (/\bshop|\bstore|\bretail/.test(cleaned)) return 'Shopping';
  if (/\bexperience|\bthings to do|\bmuseum|\bcomedy/.test(cleaned)) return 'Experiences';
  return null;
}

const clean = (value: unknown, max = 600): string =>
  typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, max) : '';

/**
 * Pull a place's own website out of a line. Handles a Markdown link, a bare
 * http(s) address, and a bare host like "narkaranyc.com". The Worker checks it
 * again before storing, so this only has to find a candidate.
 */
function websiteIn(text: string): string {
  const markdown = text.match(/\]\((https?:\/\/[^)\s]+)\)/i);
  if (markdown) return markdown[1].slice(0, 300);
  const full = text.match(/\bhttps?:\/\/[^\s)<>\]]+/i);
  if (full) return full[0].replace(/[.,;:]+$/, '').slice(0, 300);
  const host = text.match(/\b((?:[a-z0-9-]+\.)+(?:com|org|net|nyc|co|io|shop|store|cafe|restaurant))\b(\/[^\s)]*)?/i);
  if (host) return 'https://' + (host[0]).replace(/[.,;:]+$/, '').slice(0, 290);
  return '';
}

/** Remove a URL or Markdown link from prose, so the reason reads cleanly. */
function withoutLinks(text: string): string {
  return text
    .replace(/\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)/gi, '$1')
    .replace(/\bhttps?:\/\/[^\s)<>\]]+/gi, '')
    .replace(/\s{2,}/g, ' ')
    .replace(/\s+([.,;:])/g, '$1')
    .trim();
}

/** Strip Markdown emphasis, list bullets and leading numbering from a line. */
function strip(line: string): string {
  return line
    .replace(/^\s*(?:[-*+•]|\d+[.)])\s*/, '')
    .replace(/\*\*(.*?)\*\*/g, '$1')
    .replace(/\*(.*?)\*/g, '$1')
    .replace(/`/g, '')
    .replace(/^\[(.*?)\]\(.*?\)/, '$1')
    .trim();
}

function make(partial: Partial<Find> & { name: string }, source: string): Find {
  return {
    id: 'find-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4),
    name: clean(partial.name, 200),
    section: partial.section ?? DEFAULT_SECTION,
    neighborhood: clean(partial.neighborhood),
    why: clean(partial.why),
    address: clean(partial.address),
    website: clean(partial.website, 300),
    source: clean(source, 600),
    verdict: 'new',
    onMap: false,
  };
}

function fromJson(text: string, source: string): Find[] | null {
  // Tools often wrap JSON in prose or a code fence, so take everything from the
  // first bracket to the last matching one rather than the whole paste.
  const start = text.search(/[[{]/);
  if (start < 0) return null;
  const end = Math.max(text.lastIndexOf(']'), text.lastIndexOf('}'));
  if (end <= start) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
  const rows = Array.isArray(parsed)
    ? parsed
    : parsed && typeof parsed === 'object' && Array.isArray((parsed as { candidates?: unknown[] }).candidates)
      ? (parsed as { candidates: unknown[] }).candidates
      : null;
  if (!rows) return null;

  const finds: Find[] = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const r = row as Record<string, unknown>;
    const name = clean(r.name ?? r.place ?? r.title, 200);
    if (!name) continue;
    finds.push(
      make(
        {
          name,
          section: matchSection(clean(r.section ?? r.category)) ?? DEFAULT_SECTION,
          neighborhood: clean(r.neighborhood ?? r.area ?? r.hood),
          why: clean(r.why ?? r.note ?? r.reason ?? r.description),
          address: clean(r.address),
          website: clean(r.website ?? r.url ?? r.site ?? r.link, 300),
        },
        source,
      ),
    );
  }
  return finds.length ? finds : null;
}

function fromPipes(text: string, source: string): Find[] | null {
  const finds: Find[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = strip(raw);
    if (!line.includes('|')) continue;
    const cells = line.split('|').map((cell) => cell.trim());
    // Skip Markdown table rules and header rows.
    if (cells.every((cell) => /^:?-{2,}:?$/.test(cell) || !cell)) continue;
    const filled = cells.filter(Boolean);
    if (filled.length < 2) continue;
    if (/^section$/i.test(filled[0]) && /^(name|place)$/i.test(filled[1] ?? '')) continue;

    const section = matchSection(filled[0]);
    const rest = section ? filled.slice(1) : filled;
    const name = clean(rest[0], 200);
    if (!name) continue;
    finds.push(
      make(
        {
          name,
          section: section ?? DEFAULT_SECTION,
          neighborhood: rest[1] ?? '',
          why: withoutLinks(rest[2] ?? ''),
          address: rest[3] ?? '',
          website: rest[4] ? websiteIn(rest[4]) || websiteIn(line) : websiteIn(line),
        },
        source,
      ),
    );
  }
  return finds.length ? finds : null;
}

function fromLoose(text: string, source: string): Find[] {
  const finds: Find[] = [];
  let section: Section = DEFAULT_SECTION;

  for (const raw of text.split(/\r?\n/)) {
    const trimmed = raw.trim();
    if (!trimmed) continue;

    // A heading, or a short bold line on its own, switches section.
    const heading = trimmed.replace(/^#+\s*/, '').replace(/[:*_]/g, '').trim();
    const looksLikeHeading = /^#+\s/.test(trimmed) || /^\*\*.*\*\*:?$/.test(trimmed);
    if (looksLikeHeading) {
      const found = matchSection(heading);
      if (found) section = found;
      continue;
    }

    const line = strip(trimmed);
    if (!line || line.length < 2) continue;
    if (matchSection(line) && line.length < 24) {
      section = matchSection(line)!;
      continue;
    }

    // "Name — why" or "Name: why", keeping the first part as the name.
    const split = line.match(/^(.{2,120}?)\s*(?:[—–-]{1,2}|:)\s+(.*)$/);
    const name = split ? split[1] : line;
    const why = split ? split[2] : '';
    const hood = why.match(/\(([^)]{2,40})\)\s*$/);
    const reason = hood ? why.replace(/\s*\([^)]*\)\s*$/, '') : why;
    finds.push(
      make(
        {
          name: withoutLinks(name),
          section,
          why: withoutLinks(reason),
          neighborhood: hood ? hood[1] : '',
          website: websiteIn(trimmed),
        },
        source,
      ),
    );
  }
  return finds;
}

/** Parse pasted text into candidate finds. `source` records which tool it came from. */
export function parseFinds(text: string, source: string): Find[] {
  const body = text.trim();
  if (!body) return [];
  return fromJson(body, source) ?? fromPipes(body, source) ?? fromLoose(body, source);
}

/**
 * Case- and punctuation-insensitive key, for spotting the same place twice.
 * Ampersands become "and" so that one tool's "Russ & Daughters" and another's
 * "Russ and Daughters" are recognised as the same place rather than duplicated.
 */
export function sameName(name: string): string {
  return name
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/\b(the|a|an)\b/g, '')
    .replace(/[^a-z0-9]/g, '');
}
