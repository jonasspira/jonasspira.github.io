import { useEffect, useRef, useState } from 'react';
import {
  SignedOutError,
  loadResearch,
  loadTrip,
  saveResearch,
  saveTrip,
  searchPlaces,
  signOut,
} from './api';
import { parseFinds, sameName } from './parse-finds';
import { SECTIONS, type Find, type Research, type Verdict } from './trip';

const FILTERS = ['New', 'Keep', 'Skip', 'On map', 'All'] as const;
type Filter = (typeof FILTERS)[number];

function matches(find: Find, filter: Filter): boolean {
  if (filter === 'All') return true;
  if (filter === 'On map') return find.onMap;
  if (filter === 'New') return find.verdict === 'new' && !find.onMap;
  if (filter === 'Keep') return find.verdict === 'keep';
  return find.verdict === 'skip';
}

export default function ResearchApp({ onSignedOut }: { onSignedOut: (notice: string) => void }) {
  const [research, setResearch] = useState<Research | null>(null);
  const [revision, setRevision] = useState(0);
  const [loadError, setLoadError] = useState('');
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const [paste, setPaste] = useState('');
  const [source, setSource] = useState('');
  const [filter, setFilter] = useState<Filter>('New');
  const pasteRef = useRef<HTMLTextAreaElement>(null);

  async function load() {
    setLoadError('');
    try {
      const data = await loadResearch();
      setResearch(data.research);
      setRevision(data.revision);
    } catch (e) {
      if (e instanceof SignedOutError) return onSignedOut(e.message);
      setLoadError(e instanceof Error ? e.message : 'Could not load your finds.');
    }
  }
  useEffect(() => {
    void load();
  }, []);

  async function save(next: Research): Promise<boolean> {
    if (busy) return false;
    setBusy(true);
    setError('');
    setStatus('Saving…');
    try {
      const data = await saveResearch(next, revision);
      setResearch(data.research);
      setRevision(data.revision);
      setStatus('Saved');
      return true;
    } catch (e) {
      if (e instanceof SignedOutError) {
        onSignedOut(e.message);
        return false;
      }
      setError(e instanceof Error ? e.message : 'Could not save. Please try again.');
      setStatus('Not saved');
      return false;
    } finally {
      setBusy(false);
    }
  }

  if (!research) {
    return (
      <main className="shell">
        <header className="masthead">
          <h1>
            Research<span className="period">.</span>
          </h1>
          <div className="subtitle">
            <span>Places to consider</span>
          </div>
        </header>
        <p role="status">{loadError || 'Opening your finds…'}</p>
        {loadError && (
          <p className="gate-actions">
            <button onClick={() => void load()}>Try again</button>
          </p>
        )}
      </main>
    );
  }

  const all = research.candidates;
  const visible = all.filter((f) => matches(f, filter));
  const counts = {
    New: all.filter((f) => matches(f, 'New')).length,
    Keep: all.filter((f) => matches(f, 'Keep')).length,
    Skip: all.filter((f) => matches(f, 'Skip')).length,
    'On map': all.filter((f) => f.onMap).length,
    All: all.length,
  };

  /** Add whatever is in the paste box, skipping names already on the list. */
  async function addPasted() {
    const parsed = parseFinds(paste, source.trim() || 'Unnamed tool');
    if (!parsed.length) {
      setError('Nothing recognisable in that paste. Check the format in RESEARCH.md.');
      return;
    }
    const known = new Set(all.map((f) => sameName(f.name)));
    const fresh: Find[] = [];
    let duplicates = 0;
    for (const find of parsed) {
      const key = sameName(find.name);
      if (!key) continue;
      if (known.has(key)) {
        duplicates++;
        continue;
      }
      known.add(key);
      fresh.push(find);
    }
    if (!fresh.length) {
      setError('All ' + duplicates + ' of those are already on the list.');
      return;
    }
    if (await save({ ...research!, candidates: [...all, ...fresh] })) {
      setPaste('');
      setStatus(
        'Added ' + fresh.length + (duplicates ? ', skipped ' + duplicates + ' already here' : ''),
      );
      pasteRef.current?.focus();
    }
  }

  const update = (id: string, change: Partial<Find>) =>
    save({ ...research!, candidates: all.map((f) => (f.id === id ? { ...f, ...change } : f)) });

  const remove = (id: string) =>
    save({ ...research!, candidates: all.filter((f) => f.id !== id) });

  /**
   * Put a find onto the trip map. Looks the name up first; if a real NYC match
   * comes back it is pinned, and if not it is saved by name with no location,
   * which is what the trip page does too. Never invents a coordinate.
   */
  async function addToMap(find: Find) {
    if (busy) return;
    setBusy(true);
    setError('');
    setStatus('Adding to the map…');
    try {
      const query = [find.name, find.address].filter(Boolean).join(' ').slice(0, 160);
      let located = null;
      try {
        const results = await searchPlaces(query.length < 2 ? find.name : query);
        const exact = results.find((r) => sameName(r.name) === sameName(find.name));
        located = exact ?? results[0] ?? null;
      } catch {
        located = null; // Search is optional; the place can go on by name.
      }

      const { trip, revision: tripRevision } = await loadTrip();
      if (trip.places.some((p) => sameName(p.name) === sameName(find.name))) {
        await update(find.id, { onMap: true });
        setStatus('That one was already on the map');
        return;
      }

      const category = find.section === 'Food & Drink' ? 'Food' : find.section === 'Shopping' ? 'Shops' : 'Other';
      const next = {
        ...trip,
        places: [
          ...trip.places,
          {
            id: crypto.randomUUID(),
            number: Math.max(0, ...trip.places.map((p) => p.number)) + 1,
            name: located ? located.name : find.name,
            category: category as 'Food' | 'Shops' | 'Other',
            note: [find.why, find.neighborhood].filter(Boolean).join(' · ').slice(0, 4000),
            location: located ? located.location : null,
          },
        ],
      };
      await saveTrip(next, tripRevision);
      await update(find.id, { onMap: true, verdict: 'keep' });
      setStatus(located ? 'Added to the map with a pin' : 'Added by name, no pin found');
    } catch (e) {
      if (e instanceof SignedOutError) {
        onSignedOut(e.message);
        return;
      }
      setError(e instanceof Error ? e.message : 'Could not add that to the map.');
      setStatus('Not added');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="shell">
      <header className="masthead">
        <h1>
          Research<span className="period">.</span>
        </h1>
        <div className="subtitle">
          <span>
            <a href="/nyc26/">Back to the trip</a>
          </span>
          <button
            className="quiet"
            onClick={() => {
              signOut();
              onSignedOut('Closed on this device.');
            }}
          >
            Close
          </button>
        </div>
      </header>

      <section aria-labelledby="paste-title">
        <div className="section-head">
          <h2 id="paste-title">Paste what a tool found</h2>
        </div>
        <div className="scratchpad">
          <div className="search-form">
            <label className="field" htmlFor="tool">
              Which tool found these?
              <input
                id="tool"
                value={source}
                maxLength={60}
                placeholder="Claude, Muse, ChatGPT…"
                onChange={(e) => setSource(e.target.value)}
              />
            </label>
            <label className="field" htmlFor="paste">
              Its answer
              <textarea
                id="paste"
                ref={pasteRef}
                rows={7}
                value={paste}
                maxLength={60000}
                placeholder={'Shopping | Idlewild Books | West Village | Travel bookshop | 170 7th Ave S'}
                onChange={(e) => setPaste(e.target.value)}
              />
            </label>
            <p className="hint">
              Best results come from the pipe format: Section | Name | Neighborhood | Why | Address.
              JSON works too, and a plain answer is accepted but needs tidying. Names already on the
              list are skipped.
            </p>
            <div className="add-actions">
              <button disabled={busy || !paste.trim()} onClick={() => void addPasted()}>
                {busy ? 'Working…' : 'Add these finds'}
              </button>
              <button className="secondary" disabled={busy || !paste.trim()} onClick={() => setPaste('')}>
                Clear
              </button>
            </div>
          </div>
        </div>
      </section>

      <section aria-labelledby="finds-title">
        <div className="section-head">
          <h2 id="finds-title">The finds</h2>
          <span className="section-aside">{counts.All} in all</span>
        </div>
        <div className="scratchpad">
          <div className="category-tabs" role="tablist" aria-label="Which finds to show">
            {FILTERS.map((name) => (
              <button
                key={name}
                id={'tab-' + name}
                role="tab"
                aria-selected={filter === name}
                aria-controls="find-list"
                tabIndex={filter === name ? 0 : -1}
                onClick={() => setFilter(name)}
                onKeyDown={(e) => {
                  const i = FILTERS.indexOf(name);
                  let next: number | undefined;
                  if (e.key === 'ArrowRight') next = (i + 1) % FILTERS.length;
                  if (e.key === 'ArrowLeft') next = (i + FILTERS.length - 1) % FILTERS.length;
                  if (e.key === 'Home') next = 0;
                  if (e.key === 'End') next = FILTERS.length - 1;
                  if (next !== undefined) {
                    e.preventDefault();
                    setFilter(FILTERS[next]);
                    document.getElementById('tab-' + FILTERS[next])?.focus();
                  }
                }}
              >
                {name}
                <span>{counts[name]}</span>
              </button>
            ))}
          </div>

          <div className="place-list" id="find-list" role="tabpanel" aria-labelledby={'tab-' + filter}>
            {SECTIONS.filter((section) => visible.some((f) => f.section === section)).map((section) => (
              <div key={section}>
                <div className="saved-heading">
                  <span>{section}</span>
                </div>
                {visible
                  .filter((f) => f.section === section)
                  .map((find) => (
                    <article className="place" key={find.id}>
                      <span className={'place-number ' + (find.onMap ? 'pinned' : '')}>
                        {find.onMap ? '✓' : '·'}
                      </span>
                      <div className="place-copy">
                        <h3>{find.name}</h3>
                        <span className="category-label">
                          {[find.neighborhood, find.source].filter(Boolean).join(' · ')}
                        </span>
                        {find.why && <p className="place-note">{find.why}</p>}
                        {find.address && <p className="address">{find.address}</p>}
                        <div className="place-actions">
                          {(['keep', 'skip'] as Verdict[]).map((verdict) => (
                            <button
                              key={verdict}
                              className="quiet"
                              disabled={busy || find.verdict === verdict}
                              onClick={() => void update(find.id, { verdict })}
                            >
                              {verdict === 'keep' ? 'Keep' : 'Skip'}
                            </button>
                          ))}
                          {!find.onMap && (
                            <button className="quiet" disabled={busy} onClick={() => void addToMap(find)}>
                              Add to map
                            </button>
                          )}
                          <button className="quiet" disabled={busy} onClick={() => void remove(find.id)}>
                            Delete
                          </button>
                        </div>
                      </div>
                    </article>
                  ))}
              </div>
            ))}
            {!visible.length && (
              <p className="empty">
                {all.length
                  ? 'Nothing in ' + filter.toLowerCase() + '.'
                  : 'No finds yet. Run the framework in a tool and paste its answer above.'}
              </p>
            )}
          </div>
        </div>
      </section>

      <span className="sr-only" role="status" aria-live="polite">
        {status}
      </span>
      {error && (
        <div className="save-error" role="alert">
          {error}
          <button className="quiet" onClick={() => setError('')}>
            Dismiss
          </button>
        </div>
      )}
    </main>
  );
}
