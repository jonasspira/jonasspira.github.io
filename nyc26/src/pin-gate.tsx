import { useState } from 'react';
import { signIn } from './api';

// The PIN is checked by the Worker, never here. This screen only collects it
// and hands it over; if it is right the Worker returns a token that keeps this
// browser open for 90 days, so the PIN is typed roughly once per device.
export default function PinGate({ notice, onOpen }: { notice: string; onOpen: () => void }) {
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (busy || !pin.trim()) return;
    setBusy(true);
    setError('');
    try {
      await signIn(pin.trim());
      onOpen();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'That PIN was not accepted.');
      setPin('');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="shell">
      <header className="masthead">
        <h1>
          New York<span className="period">.</span>
        </h1>
        <div className="subtitle">
          <span>October 26&ndash;29, 2026</span>
        </div>
      </header>
      <section className="gate" aria-labelledby="gate-title">
        <h2 id="gate-title">Enter your PIN</h2>
        <form onSubmit={submit}>
          <label className="field" htmlFor="pin">
            PIN
            <input
              id="pin"
              type="password"
              inputMode="numeric"
              autoComplete="current-password"
              enterKeyHint="go"
              value={pin}
              maxLength={32}
              onChange={(e) => setPin(e.target.value)}
              disabled={busy}
            />
          </label>
          {(error || notice) && (
            <p className="inline-error" role="alert">
              {error || notice}
            </p>
          )}
          <button disabled={busy || !pin.trim()}>{busy ? 'Opening…' : 'Open the trip'}</button>
        </form>
        <p className="hint">This device stays open for 90 days.</p>
      </section>
    </main>
  );
}
