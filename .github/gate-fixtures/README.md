# Gate fixtures

Matched RED/GREEN pair for the parse probe in `.github/workflows/build-boot-gate.yml`.

- `708-red.dockerfile.fixture` — the real pre-fix `infra/watchdog/Dockerfile`. Its `FROM` line
  carries a trailing `# node:20-alpine`. Dockerfiles have no inline comments, so Docker
  parses that as extra arguments: `FROM requires either one or three arguments`.
- `708-green.dockerfile.fixture` — the same line with only that token removed, so a RED result is
  attributable to the inline comment and nothing else.

The gate's step 0 asserts the probe rejects `-red` and accepts `-green` **before** trusting
any of its own GREEN results. A gate never observed failing is indistinguishable from a
gate that cannot fail.

Both files are excluded from Dockerfile discovery in steps 1 and 2. Do not "fix" the RED
fixture.

## Why the odd filenames

They deliberately do **not** match `Dockerfile` or `Dockerfile.*`. `scripts/test-dependabot-groups.sh`
derives the required Dependabot surface set by walking the tree, and it has no exclusion
mechanism on purpose — "someone remembered to extend a literal set" is the failure it was
written to prevent. A fixture named `Dockerfile.708-red` registers as a real docker surface
and fails that gate (observed on the first push of this branch).

So the fixtures avoid creating a phantom manifest rather than carving an exception into a
gate built specifically to refuse exceptions. The build/boot gate reads both by explicit
path, so the names cost nothing.
