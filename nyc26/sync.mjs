// Copies the built page out of dist/ and into nyc26/, which is what GitHub
// Pages actually serves. Stale asset files are removed first, so an old
// bundle can never linger next to a new index.html.
//
// Run it through `npm run build`; there is no reason to run it on its own.
import { cp, mkdir, readdir, rm } from 'node:fs/promises';

const published = ['index.html', 'favicon.svg'];
const pages = ['research'];

await rm('assets', { recursive: true, force: true });
await mkdir('assets', { recursive: true });
await cp('dist/assets', 'assets', { recursive: true });
for (const name of published) await cp('dist/' + name, name);

for (const page of pages) {
  await mkdir(page, { recursive: true });
  await cp('dist/' + page + '/index.html', page + '/index.html');
}

const assets = await readdir('assets');
const bar = '[' + '#'.repeat(20) + ']';
console.log(
  `${bar} nyc26 built: index.html, ${pages.length} sub-page, favicon.svg and ${assets.length} asset files.`,
);
