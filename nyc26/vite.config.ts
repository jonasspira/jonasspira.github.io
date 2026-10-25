import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The page is served by GitHub Pages at www.spiiira.com/nyc26/, so every asset
// path has to start there. The build writes into dist/; `npm run build` then
// copies index.html, assets/ and favicon.svg up into nyc26/ itself, because
// GitHub Pages serves the repository tree directly. Same idea as plates/.
export default defineConfig({
  root: 'src',
  base: '/nyc26/',
  plugins: [react()],
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    assetsDir: 'assets',
    sourcemap: false,
  },
  server: { port: 5173 },
});
