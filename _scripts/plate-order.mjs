import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

export function plateOrder(root, progress = () => {}) {
  const git = args => execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  if (git(['rev-parse', '--is-shallow-repository']).trim() !== 'false') {
    throw new Error('Full Git history is required to date plate additions.');
  }
  const paths = git(['ls-files', '-z', '--', 'plates/images'])
    .split('\0').filter(path => /\.(jpe?g|png|webp)$/i.test(path));
  const photos = paths.map((path, index) => {
    // Edits do not make an old photo new. A removed/re-added path is a new addition.
    const added = Number(git(['log', '--no-renames', '--diff-filter=A', '-1', '--format=%ct', '--', path]).trim());
    if (!added) throw new Error('Commit the new photo before building its publication order: ' + path);
    progress(index + 1, paths.length);
    return { path: '/' + path, added };
  });
  photos.sort((a, b) => b.added - a.added || (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return photos.map(photo => photo.path);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = process.cwd();
  let lastStep = -1;
  const photos = plateOrder(root, (done, total) => {
    const step = Math.floor(done / total * 20);
    if (step === lastStep) return;
    lastStep = step;
    process.stdout.write('\r[' + '#'.repeat(step) + '-'.repeat(20 - step) + '] Dating photos');
  });
  const destination = resolve(root, '_data/plates_order.json');
  mkdirSync(dirname(destination), { recursive: true });
  writeFileSync(destination, JSON.stringify(photos, null, 2) + '\n');
  process.stdout.write('\nNewest-first order ready for ' + photos.length + ' photos.\n');
}
