#!/usr/bin/env node
// build.mjs — esbuild JS API wrapper with a .cjs-to-.js/.ts inline plugin.
//
// Usage (called by esbuild-backend.sh):
//   node build.mjs <infile> <outfile> [--external:pkg ...] [--resolve-extensions=.ts,.js,.json]
//
// The cjsInline plugin intercepts any import path ending in .cjs, strips the
// extension, resolves to the .js or .ts source file in the same directory
// tree, and returns the absolute path so esbuild bundles it inline.
//
// Effect: dist/server.cjs becomes fully self-contained — no runtime *.cjs
// shim files need to exist beside the bundle.

import { existsSync } from 'fs';
import { resolve, join } from 'path';
import { createRequire } from 'module';

// Resolve esbuild from the *cwd's* node_modules, not this script's location.
// esbuild-backend.sh runs us from /app/backend (where esbuild is installed),
// but this file is copied to /tmp — ESM bare-import resolution walks up from
// the module file's dir (/tmp, no node_modules) and ignores cwd/NODE_PATH.
// createRequire anchored at cwd makes `require('esbuild')` resolve correctly.
const require = createRequire(join(process.cwd(), 'noop.cjs'));
const esbuild = require('esbuild');

const args = process.argv.slice(2);
const infile = args.shift();
const outfile = args.shift();

if (!infile || !outfile) {
  process.stderr.write('Usage: node build.mjs <infile> <outfile> [--external:pkg ...]\n');
  process.exit(1);
}

const external = [];
let resolveExtensions = ['.ts', '.js', '.json'];

for (const arg of args) {
  if (arg.startsWith('--external:')) {
    external.push(arg.slice(11));
  } else if (arg.startsWith('--resolve-extensions=')) {
    resolveExtensions = arg.slice(21).split(',');
  }
}

// Plugin: for any import ending in .cjs, strip .cjs and resolve to the
// .js or .ts source so esbuild bundles it inline instead of externalizing.
const cjsInline = {
  name: 'cjs-inline',
  setup(build) {
    build.onResolve({ filter: /\.cjs$/ }, (args) => {
      const base = args.path.replace(/\.cjs$/, '');
      // Try sibling .js/.ts source first (the common case: a generated .cjs
      // whose hand-written source is a .js/.ts of the same basename).
      for (const ext of ['.js', '.ts']) {
        const candidate = resolve(args.resolveDir, base + ext);
        if (existsSync(candidate)) {
          return { path: candidate };
        }
      }
      // If the literal .cjs file exists, resolve to it explicitly so esbuild
      // BUNDLES it inline (some modules, e.g. shared/core4-url.cjs, ship only
      // a .cjs with no .js/.ts peer). Returning null here would also work for
      // static imports, but being explicit guarantees inlining for require()
      // calls too and keeps the post-build guard's invariant true.
      const literalCjs = resolve(args.resolveDir, args.path);
      if (existsSync(literalCjs)) {
        return { path: literalCjs };
      }
      // Genuinely missing — return null so esbuild raises a loud
      // "Could not resolve" error (the shell retry loop refuses to externalize
      // relative paths, so the build fails fast instead of shipping a crash).
      return null;
    });
  },
};

const banner =
  'var __import_meta_url = typeof __filename !== "undefined" ? require("url").pathToFileURL(__filename).href : undefined;';

try {
  await esbuild.build({
    entryPoints: [infile],
    outfile,
    bundle: true,
    platform: 'node',
    target: 'node20',
    format: 'cjs',
    plugins: [cjsInline],
    external,
    resolveExtensions,
    sourcemap: true,
    logLimit: 0,
    banner: { js: banner },
    define: { 'import.meta.url': '__import_meta_url' },
  });
} catch {
  // esbuild already printed errors to stderr; exit non-zero for the shell retry loop.
  process.exit(1);
}
