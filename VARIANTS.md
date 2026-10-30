# Release variants

A variant is a MITS11 release line built for one kind of target. It has its
own tags, index and pointers, but shares the release repos and the installer.
The host build is the default variant; every other variant is listed in
[`variants.json`](variants.json).

A variant is not a platform. A future linux-arm64 laptop build is a platform
of the default variant; the MP257 board is the `mp257` variant, which happens
to be linux-arm64 too.

| Variant | Target | MITS11 branches |
|---|---|---|
| default | Host machines (win-x64, linux-x64, osx-x64, osx-arm64) | `develop`, `stable/*` |
| `mp257` | MP257 board (linux-arm64) | `mp257/*` |

## How a variant is released

| Piece | Default variant | Named variant (`mp257`) |
|---|---|---|
| GA tag | `9.0.0` | `9.0.0+mp257` |
| Prerelease tag | `9.0.0-alpha+build.<stamp>`, `9.0.0-dev.<branch>+build.<stamp>` | `9.0.0-alpha+mp257.build.<stamp>`, `9.0.0-dev.<branch>+mp257.build.<stamp>` |
| GitHub release | `MITS11-stable` (GA), `MITS11-develop` (prerelease) | same repos, title ends with `(<description>)` |
| Release record | `<maj>/<min>/<tag>.md` | `<variant>/<maj>/<min>/<tag>.md` |
| Pointers | `stable`, `alpha`, `alpha-<line>`, `alpha-lines`, `nightly` | `<variant>/stable`, `<variant>/alpha`, `<variant>/alpha-<line>`, `<variant>/alpha-lines`, `<variant>/nightly` |
| Manifest | `<tag>/manifest.json` | `<variant>/<tag>/manifest.json` |
| Install | `install.sh` | `install.sh --variant <variant>` |
| Retention groups | `alpha`, `dev:<branch>`, `9.0` | `<variant>:alpha`, `<variant>:dev:<branch>`, `<variant>:9.0` |

The variant is always the first build identifier of the tag (after `+`). Git
tags are shared by every branch of the MITS11 repo, so the marker is what lets
`9.0.0` and `9.0.0+mp257` exist side by side. Semver ignores build metadata,
so the version stamped into DAS stays `9.0.0`; the full tag is kept as its
informational version.

Version numbers: a variant uses the major.minor of the `develop` it was last
synced from, with its own patch counter. `9.0.3+mp257` is not the same code as
`9.0.3`.

## Release channels

Each variant has three release channels, by who installs them. Each is a
pointer file holding the newest version in it:

| Channel | What it holds | Written by |
|---|---|---|
| `stable` | The release QA approved, for customer service and production to install for customers. What `install.sh`/`install.ps1` install by default (`latest` is an alias). | Promotion only |
| `alpha` | What QA verifies: the newest release (GA), alpha, beta, rc, pre or preview build. | The MITS11 pipeline |
| `nightly` | Developers' own builds: any tag with another suffix (`-dev.<branch>`). | The pipeline |

`alpha` is the newest build of any release line, so it moves back and forth
when two lines (8.1 rc, 9.0 alpha) build in turn. The pipeline also writes
`alpha-<major>.<minor>` (e.g. `alpha-8.1`), the newest alpha-channel build of
one line, and `alpha-lines`, the lines that have such a pointer, one per row.
`install.sh alpha-8.1` installs it, and the page shows one alpha card per
line (newest three).

`candidate` was a fourth channel, the newest GA build waiting for QA. It is
folded into `alpha`. For one release the pipeline still writes `candidate` as
a copy of `alpha`, so old install commands keep working; after that it is
deleted.

Each version's `manifest.json` records `channel` (where the pipeline
published it) and `published` (when, UTC). Promotion adds `promoted`
(`at`, `by`, `run`, and `note` when given) and never changes `channel`.

## Promotion

When a release (GA) build on `alpha` passes its QA smoke test, run the **Promote to stable**
workflow (Actions tab, `promote-stable.yml`) with the variant (`default` or
a name from `variants.json`), the version, and a note saying which QA
result approved it (shown on the page). In MITS11, the `release-promote`
agent skill does this for you, with checks first. Only people with write
access to this repo can run it. It:

1. checks the version is a published release build of that variant;
2. takes its GitHub release in `MITS11-stable` off prerelease, and for the
   default variant also marks it Latest;
3. moves `<variant>/stable` (or `stable`) to it and adds `promoted` to its
   manifest.

Promoting an older version rolls stable back; the run summary says so.

GitHub "Latest" is only ever set on default-variant releases, so a named
variant's promoted release is a full release without being Latest. When
editing a release by hand, keep it that way: untick "Set as the latest
release" (`make_latest=false` through the API) on a named variant's
release, or it replaces the host release as Latest in the repo.

## Fields in `variants.json`

| Field | Meaning |
|---|---|
| `name` | The variant key: tag marker, folder name and `--variant` value. Lowercase letters, digits and `-`, starting with a letter or digit. `default` (the host build) and `build` (host prerelease tags use `+build.<stamp>`) are reserved. |
| `description` | Human name, used in release titles and on the page. |
| `deviceTreeCompatiblePrefix` | Optional. When `install.sh` runs without `--variant` on a device whose device tree compatible string starts with this, it stops and asks for `--variant <name>`, so the device never gets the default variant's build by mistake. |
| `installNote` | Optional. One sentence shown at the top of the variant's tab on the page: what to do before installing. |
| `installNoteUrl` | Optional, needs `installNote`. An `https://` link shown after the note. |

Every field is a string: `install.sh` reads this file without `jq`, so an
entry must not contain nested objects or arrays. The `Validate variants`
workflow enforces that.

## Add a variant

1. Add an entry to [`variants.json`](variants.json), with an `installNote`
   if something comes before installing (for `mp257`, the golden image). The
   `Validate variants` workflow checks the file on every PR that touches it.
   The page builds the variant's tab from this entry.
2. In MITS11, on the variant's branches, set `releaseVariant` in
   `.cicd/build-mits11-package.yml` to the variant's name. The pipeline refuses
   a tag whose variant doesn't match the branch's, and a variant not listed in
   `variants.json`.
3. Tag with the variant marker (see the table above).
4. After QA passes the variant's first release build, promote it (see
   Promotion). Until then its `stable` channel is empty.

Nothing else changes: the page, `install.sh`, the promote workflow and the
retention workflows read `variants.json`, and the first release of the
variant creates its `<variant>/` folder here.
