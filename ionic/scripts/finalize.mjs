// Stamps a "type" field into each build output directory.
//
// Without this, Node reads the nearest package.json — the root one, which has
// no "type" and therefore means CommonJS — and refuses to run dist/esm/*.js as
// ES modules ("Cannot use import statement outside a module"). Bundlers read
// the "module" field and never notice; plain `node --input-type=module` does.
//
// Written by hand rather than by a bundler so this package keeps zero
// third-party dependencies, build tooling included.
import { writeFileSync, existsSync } from 'node:fs';

for (const [dir, type] of [['dist/esm', 'module'], ['dist/cjs', 'commonjs']]) {
  if (!existsSync(dir)) {
    console.error(`[finalize] ${dir} is missing — did tsc run?`);
    process.exit(1);
  }
  writeFileSync(`${dir}/package.json`, JSON.stringify({ type }) + '\n');
}
