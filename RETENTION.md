# Release retention policy

Scope: `Arbin-com/MITS11-develop` GitHub Releases only. `Arbin-com/MITS11-stable`
(and its manifests here) are shipped customer-facing versions and are kept
indefinitely — out of scope for this policy.

## Why

`MITS11-develop` accumulates a release per tag pushed by the
`Build MITS11 package` pipeline (dev/nightly/alpha builds, roughly daily,
some days multiple). As of 2026-09, that's 600+ releases and ~1.3TB of
assets, none ever pruned, most no longer reachable by anyone.

## Classification

Every tag in `MITS11-develop` falls into one of two classes:

- **`dev.*`** — `<version>-dev.<branch>+build.<stamp>` — ephemeral per-branch
  experimental builds.
- **`alpha`** — `<version>-alpha+build.<stamp>` — nightly integration builds.

Anything not matching one of these two patterns is left untouched by this
policy (e.g. stable/release/patch tags don't live in `MITS11-develop` in the
first place, per `build-mits11-package.yml`'s tag routing).

## Keep rule (floor + ceiling)

A release is only deleted once it's past **both** its class's floor and
ceiling:

| Class | Floor (always kept, any age) | Ceiling (delete once past floor) |
|---|---|---|
| `dev.*`, per branch name | last 3 builds | older than 7 days |
| `alpha` | last 14 builds | older than 60 days |

The floor stops a quiet week from deleting the only build for a branch; the
ceiling stops a burst day from blowing past the floor and still piling up
history.

**Hard exception:** a release is never deleted if its version is the current
value of `stable`, `alpha`, or `nightly` in this repo, regardless of age or
count.

## Manifest lockstep

Every version released also has a `<version>/manifest.json` folder in this
repo. Deleting a release without deleting its manifest leaves a manifest
that 404s at install time (`install.ps1`/`install.sh <version>`) instead of
just not existing — worse than doing nothing.

So deletion always happens in this order, per version:

1. Delete the GitHub release + all assets in `MITS11-develop`.
2. Only once that succeeds, delete the `<version>/` folder here and commit.

If step 1 fails, step 2 is skipped for that version — never delete the
manifest for a release that's still live.

Old-version reinstall via `install.ps1`/`install.sh <version>` is expected to
stop working once a version is pruned — that's accepted; it isn't a real
support path in practice.

## Enforcement

`.github/workflows/retention.yml`, scheduled weekly. Runs against
`MITS11-develop` via a fine-grained PAT (`DEVELOP_REPO_TOKEN` secret, scoped
to `contents: write` on that repo only — this repo's own `GITHUB_TOKEN`
can't reach across repos).

First scheduled runs are **dry-run**: logs exactly what it would delete
(tag, class, age, size) without deleting anything or touching this repo.
Flip `DRY_RUN` to `false` in the workflow once a cycle's output has been
reviewed.

Actual deletions are capped at `MAX_DELETIONS_PER_RUN` (50) per run. The
first live run has a large backlog (everything past its ceiling since this
policy didn't exist before) — the cap spreads that cleanup over several
runs instead of deleting hundreds of releases at once. Anything past the
cap is logged as `SKIP (cap reached)` and picked up on the next run.
