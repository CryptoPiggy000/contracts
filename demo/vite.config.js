import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Local-only demo: serve on the same port the README/anvil flow expects.
export default defineConfig({
  plugins: [svelte()],
  server: { port: 5173, strictPort: false },
});
