import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync, utimesSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { plateOrder } from './plate-order.mjs';

test('new additions lead regardless of filename or filesystem dates; edits keep their place', () => {
  const root = mkdtempSync(join(tmpdir(), 'plates-order-'));
  const git = (args, env = {}) => execFileSync('git', args, {
    cwd: root, encoding: 'utf8', env: { ...process.env, ...env }
  });
  git(['init', '-q']);
  git(['config', 'user.name', 'Plates test']);
  git(['config', 'user.email', 'plates-test@example.invalid']);
  mkdirSync(join(root, 'plates/images'), { recursive: true });
  const add = name => writeFileSync(join(root, 'plates/images', name), 'fixture');
  const commit = date => {
    git(['add', '.']);
    git(['commit', '-qm', 'Test image batch'], { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date });
  };
  add('z-old.JPG');
  add('ignored.txt');
  commit('2026-01-01T12:00:00Z');
  add('b-new.webp');
  add('a-new.png');
  commit('2026-02-01T12:00:00Z');
  writeFileSync(join(root, 'plates/images/z-old.JPG'), 'edited');
  commit('2026-03-01T12:00:00Z');
  utimesSync(join(root, 'plates/images/z-old.JPG'), new Date(), new Date());
  assert.deepEqual(plateOrder(root), [
    '/plates/images/a-new.png', '/plates/images/b-new.webp', '/plates/images/z-old.JPG'
  ]);
  add('000-latest.jpeg');
  commit('2026-04-01T12:00:00Z');
  assert.equal(plateOrder(root)[0], '/plates/images/000-latest.jpeg');
});
