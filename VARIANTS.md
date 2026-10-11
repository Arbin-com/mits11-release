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
| Pointers | `stable`, `alpha`, `nightly` | `<variant>/stable`, `<variant>/alpha`, `<variant>/nightly` |
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

GitHub "Latest" is only ever set on default-variant releases.

## Fields in `variants.json`

| Field | Meaning |
|---|---|
| `name` | The variant key: tag marker, folder name and `--variant` value. Lowercase letters, digits and `-`. |
| `description` | Human name, used in release titles and on the page. |
| `deviceTreeCompatiblePrefix` | Optional. When `install.sh` runs without `--variant` on a device whose device tree compatible string starts with this, it stops and asks for `--variant <name>`, so the device never gets the default variant's build by mistake. |

## Add a variant

1. Add an entry to [`variants.json`](variants.json).
2. Add a tab for it in [`index.html`](index.html): its install commands, plus
   where to get anything that comes before them (for `mp257`, the golden image).
3. In MITS11, on the variant's branches, set `releaseVariant` in
   `.cicd/build-mits11-package.yml` to the variant's name. The pipeline refuses
   a tag whose variant doesn't match the branch's, and a variant not listed in
   `variants.json`.
4. Tag with the variant marker (see the table above).

Nothing else changes: `install.sh` and the retention workflows read
`variants.json`, and the first release of the variant creates its
`<variant>/` folder here.
