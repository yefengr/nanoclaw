import { build } from 'esbuild';

await build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  platform: 'node',
  target: 'es2022',
  format: 'esm',
  outfile: 'dist/index.js',
  external: [
    'better-sqlite3', // native .node addon — must be resolved at runtime
    'pino',           // worker_threads transport incompatible with bundling
    'pino-pretty',
  ],
  banner: {
    // ESM bundles lack require(); better-sqlite3's native binding loader needs it
    js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);",
  },
  sourcemap: true,
});
