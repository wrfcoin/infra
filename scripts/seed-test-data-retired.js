#!/usr/bin/env node
// Preserve the old entry point with an honest refusal: it cannot generate a
// usable offline deployment after the legacy stack's build inputs disappeared.
throw new Error(
  'Legacy offline tooling is archived; see infra/docker/attic/README.md. ' +
  'The historical generator is retained as seed-test-data.js.txt.'
);
