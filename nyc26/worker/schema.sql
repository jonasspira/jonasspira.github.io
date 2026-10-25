-- The whole trip is one row: one document, shared by every device that has the
-- PIN. `revision` goes up by one on every accepted save, which is what lets a
-- stale browser tab be refused instead of silently overwriting newer edits.
CREATE TABLE IF NOT EXISTS trips (
  id       TEXT PRIMARY KEY,
  data     TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0
);

-- Wrong PIN attempts, counted per address so a short PIN cannot be guessed by
-- brute force. Rows are deleted as soon as the right PIN is entered.
CREATE TABLE IF NOT EXISTS pin_attempts (
  ip           TEXT PRIMARY KEY,
  fails        INTEGER NOT NULL DEFAULT 0,
  window_start INTEGER NOT NULL DEFAULT 0
);
