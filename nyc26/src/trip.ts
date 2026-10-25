// Shared constants and types for the browser.
//
// Validation lives in worker/worker.js, not here: the Worker is the only
// authority on what may be saved, and keeping one copy of the rules means the
// two can never drift apart. Nothing private belongs in this file. It ships to
// anyone who opens the page, signed in or not.

export const EMPTY = 'TO BE FILLED IN';
export const VERIFY = 'TO BE VERIFIED';
export const CATEGORIES = ['Hotel', 'Office', 'Food', 'Shops', 'Other'] as const;
export type Category = (typeof CATEGORIES)[number];
export const CATEGORY_COLORS: Record<Category, string> = {
  Hotel: '#2f644b',
  Office: '#285a9f',
  Food: '#a74a24',
  Shops: '#794c98',
  Other: '#56616b',
};

export type Location = { lat: number; lon: number; address: string; source: string };
export type Place = {
  id: string;
  number: number;
  name: string;
  category: Category;
  note: string;
  location: Location | null;
};
export type Thought = { id: string; text: string };
export type Trip = {
  dataVersion: number;
  essentials: { outbound: string; inbound: string; confirmation: string; hotelAddress: string };
  evenings: { cluster: string; stops: string; awareness: string }[];
  places: Place[];
  thoughts: Thought[];
  practical: { airport: string; subway: string; weather: string; bites: string };
};
export type Candidate = { id: string; name: string; location: Location };

export function filterSaved(trip: Trip, q: string) {
  const s = q.toLocaleLowerCase().trim();
  return {
    places: trip.places.filter((p) =>
      [p.name, p.note, p.location?.address].join(' ').toLocaleLowerCase().includes(s),
    ),
    thoughts: trip.thoughts.filter((t) => t.text.toLocaleLowerCase().includes(s)),
  };
}

/** The three sections of the travel framework. */
export const SECTIONS = ['Shopping', 'Food & Drink', 'Experiences'] as const;
export type Section = (typeof SECTIONS)[number];
export type Verdict = 'new' | 'keep' | 'skip';

export type Find = {
  id: string;
  name: string;
  section: Section;
  neighborhood: string;
  why: string;
  source: string;
  address: string;
  verdict: Verdict;
  onMap: boolean;
};
export type Research = { dataVersion: number; candidates: Find[] };
