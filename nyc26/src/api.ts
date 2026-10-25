// Talking to the Worker.
//
// The page is served by GitHub Pages and the data lives in a Cloudflare Worker,
// so every request below crosses origins. That is deliberate: nothing is sent
// automatically by the browser, so a forged write from another site is not
// possible. The session token is attached by hand, on each request.
//
// The PIN itself is never stored. It is exchanged once for a signed token that
// the Worker issues and can verify; only that token is kept in this browser.

import type { Candidate, Trip } from './trip';

// VITE_API_BASE lets a test build point at a Worker running on this machine.
// Without it, `npm run dev` uses the local Worker and a real build uses the
// deployed one.
const API_BASE =
  import.meta.env.VITE_API_BASE ||
  (import.meta.env.DEV ? 'http://127.0.0.1:8787' : 'https://nyc26-api.jonas-spira.workers.dev');

const TOKEN_KEY = 'nyc26.token';

/** Thrown when the Worker says the token is missing, expired or not valid. */
export class SignedOutError extends Error {
  constructor(message = 'Enter your PIN to open the trip.') {
    super(message);
    this.name = 'SignedOutError';
  }
}

function readToken(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null; // Private browsing with storage blocked.
  }
}

export function hasToken(): boolean {
  return Boolean(readToken());
}

export function signOut(): void {
  try {
    localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* Nothing to clear. */
  }
}

async function readBody(response: Response): Promise<Record<string, unknown>> {
  try {
    return (await response.json()) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function messageFrom(body: Record<string, unknown>, fallback: string): string {
  return typeof body.error === 'string' && body.error ? body.error : fallback;
}

async function request(
  path: string,
  init: RequestInit,
  fallback: string,
): Promise<Record<string, unknown>> {
  const token = readToken();
  if (!token) throw new SignedOutError();

  let response: Response;
  try {
    response = await fetch(API_BASE + path, {
      ...init,
      headers: { ...init.headers, Authorization: 'Bearer ' + token },
    });
  } catch {
    throw new Error('No connection. Your edits are still here; try again.');
  }

  const body = await readBody(response);
  if (response.status === 401) {
    signOut();
    throw new SignedOutError(messageFrom(body, 'Your session expired. Enter your PIN again.'));
  }
  if (!response.ok) throw new Error(messageFrom(body, fallback));
  return body;
}

/** Exchange the PIN for a session token. Returns the number of minutes locked out, if any. */
export async function signIn(pin: string): Promise<void> {
  let response: Response;
  try {
    response = await fetch(API_BASE + '/session', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin }),
    });
  } catch {
    throw new Error('No connection. Check your signal and try again.');
  }

  const body = await readBody(response);
  if (!response.ok) throw new Error(messageFrom(body, 'That PIN was not accepted.'));
  if (typeof body.token !== 'string') throw new Error('That PIN was not accepted.');

  try {
    localStorage.setItem(TOKEN_KEY, body.token);
  } catch {
    throw new Error('This browser is blocking storage, so the trip cannot stay open.');
  }
}

export async function loadTrip(): Promise<{ trip: Trip; revision: number }> {
  const body = await request('/trip', { cache: 'no-store' }, 'Your saved trip could not be loaded.');
  return { trip: body.trip as Trip, revision: body.revision as number };
}

export async function saveTrip(
  trip: Trip,
  revision: number,
): Promise<{ trip: Trip; revision: number }> {
  const body = await request(
    '/trip',
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ trip, revision }),
    },
    'Could not save. Your edits are still here; please try again.',
  );
  return { trip: body.trip as Trip, revision: body.revision as number };
}

export async function searchPlaces(q: string): Promise<Candidate[]> {
  const body = await request(
    '/places?q=' + encodeURIComponent(q),
    {},
    'Place search is unavailable right now.',
  );
  return body.results as Candidate[];
}
