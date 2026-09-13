# Release retention policy (stable)

Scope: `Arbin-com/MITS11-stable` GitHub Releases only — shipped, customer-facing
GA versions (tags `x.y.z`, `x.y.z-release`, `x.y.z-patch`). See
[`RETENTION.md`](RETENTION.md) for the separate, differently-shaped policy
covering `Arbin-com/MITS11-develop` (dev/nightly/alpha prerelease builds).

## Why

Same underlying problem as `MITS11-develop`: as of 2026-09, `MITS11-stable`
has 264 releases and ~677GB of assets, none ever pruned. But the shape of
the fix is different — these are versions real customers may still be
running on real hardware, not disposable prerelease builds, and there's no
documented EOL/support-window policy anywhere in this org to key off of
(checked: no such policy exists as of this writing). So this policy is
deliberately conservative relative to `MITS11-develop`'s: age alone never
deletes anything here, only a per-line release-count floor does.

## Classification

Releases are grouped by major.minor line (`7.0.35` → line `7.0`). Only GA
tags are considered — `x.y.z`, `x.y.z-release`, `x.y.z-patch` (the same
three shapes `setup.yml`'s `is_ga_tag()` treats as GA). Anything else is
left untouched by this policy.

## Keep rule (per-line floor, no age ceiling)

Each major.minor line keeps its newest releases down to a floor; everything
past the floor is a delete candidate, regardless of age:

| Line status | Floor |
|---|---|
| Current line (highest major.minor) **or** shipped a release within the last 180 days | 20 |
| Every other line | 5 |

A line doesn't need to be the newest to get the larger floor — it only
needs to still be receiving patches. This matters because major lines
overlap in practice: `4.0.x` kept shipping patches into 2026-01-20, after
`5.0.x` had already started in 2025-12-31. Gating on version number alone
would have treated `4.0.x` as dead while it was still actively maintained.

There's deliberately no separate age ceiling like `MITS11-develop` has — a
5-year-old release still inside its line's floor is kept, full stop. The
floor number is where "how much history does this line's status warrant"
gets decided; layering an age check on top would only add complexity
without protecting anything the floor doesn't already protect.

**Hard exception:** a release is never deleted if its version is the
current value of `stable`, `alpha`, or `nightly` in this repo, regardless
of floor position.

## Manifest lockstep

Same as `MITS11-develop`'s policy: every version has a `<version>/manifest.json`
folder in this repo, and deletion always happens release-first:

1. Delete the GitHub release + all assets in `MITS11-stable`.
2. Only once that succeeds, delete the `<version>/` folder here and commit.

If step 1 fails, step 2 is skipped — never delete a manifest for a release
that's still live.

Old-version reinstall via `install.ps1`/`install.sh <version>` is expected
to stop working once a version falls past its line's floor and gets
pruned. The one documented support case referencing old versions
(`docs/customer-service/2026-07-28-venture-malaysia-2.0.9-to-7.0.6-upgrade-failure.md`
in the MITS11 repo) turned out to depend on git tag history in the source
repo, not on GitHub Release binary assets — so this isn't expected to break
that kind of recovery.

## Enforcement

`.github/workflows/retention-stable.yml`, scheduled weekly (offset an hour
from the develop retention run). Runs against `MITS11-stable` via a
fine-grained PAT (`STABLE_REPO_TOKEN` secret, scoped to `contents: write` on
that repo only — separate from `DEVELOP_REPO_TOKEN`, which is scoped to
`MITS11-develop` only).

First scheduled runs are **dry-run**: logs exactly what it would delete
(tag, line, floor position, size) without deleting anything or touching
this repo. Flip `DRY_RUN` to `false` in the workflow once a cycle's output
has been reviewed.

Actual deletions are capped at `MAX_DELETIONS_PER_RUN` (50) per run, same
reasoning as `MITS11-develop`'s policy — spreads the first cleanup's
backlog over several runs instead of deleting everything at once. Anything
past the cap is logged as `SKIP (cap reached)` and picked up on the next
run.
