# Contributing to RawTouch

Issues and pull requests are welcome. This file covers building and
testing, the checks a change has to pass, and how releases are made.

## Before you start

```sh
swift build
swift test
swift run scroll-bench --offline
```

**Never grant an Accessibility prompt raised by a test run or a build
directory binary.** Test hosts run from `.build` and DerivedData copies;
granting one binds the approval to a throwaway path and can lock the
installed app out. Grant Accessibility only to the app you assembled with
`scripts/make-app.sh` and launched from `~/Applications`.

If you granted the wrong copy, remove that entry in **System Settings →
Privacy & Security → Accessibility** (or run
`tccutil reset Accessibility io.github.kalakris.RawTouch`), then relaunch
the installed app and grant it.

## Building the app

`swift build` needs Swift 5.9 or later; `scripts/make-app.sh` needs full
Xcode, because it builds a universal (Apple silicon and Intel) app through
Xcode's build system. It builds, signs and installs
`~/Applications/RawTouch.app` without launching it; pass a path to
install elsewhere:

```sh
./scripts/make-app.sh /path/to/RawTouch.app
```

The script signs with a Developer ID Application identity if your
keychain has one, then an Apple Development identity, then ad-hoc. Pick
one explicitly with:

```sh
RAWTOUCH_SIGN_ID="Apple Development: you@example.com (TEAMID)" ./scripts/make-app.sh
```

A stable signing identity keeps the Accessibility grant across rebuilds;
with ad-hoc signing, expect to grant it again after each rebuild. Local
builds are not notarized.

## Code layout

| Target | Responsibility |
|---|---|
| `RawTouchCore` | HID discovery and reports, host leases, configuration, scroll synthesis, and the service lifecycle |
| `RawTouchAppCore` | Testable menu bar app state, settings, and login-item handling |
| `RawTouchApp` | SwiftUI interface |
| `RawTouchTestSupport` | Test and benchmark helpers |
| `scroll-bench` | Offline and live scroll benchmarks |

[docs/how-it-works.md](docs/how-it-works.md) describes the pipeline.

## What CI checks

Every push to `main` and every pull request runs
`.github/workflows/ci.yml` on macOS: formatting, build, the unit tests,
the offline scroll benchmark, an ad-hoc-signed app bundle, and a check that the
binary references no event-tap API it should not.

## Releases and versions

Releases are cut by the maintainer by pushing a version tag
(`vMAJOR.MINOR.PATCH`, optionally with a `-PRERELEASE` suffix). The
`Release` workflow first checks the tag's form and that
`docs/release-notes/<tag>.md` exists, requires CI to pass, then builds, signs with Developer ID, notarizes, and attaches a
DMG and a zip to a GitHub release, with a build-provenance attestation.
Once the release is published, the maintainer moves the `stable` tag to
it by hand (`git tag -f stable vX.Y.Z && git push -f origin stable`).

Versions are `0.y.z`, taken from the tag: the minor number moves for new
features or a touch-protocol change, the patch number for fixes. 1.0
waits until the protocol is frozen. The app and the firmware module are
versioned independently; the protocol number is what they must agree on.
The About panel shows the version and, in parentheses, the commit count
at the tag, so two builds of one version can be told apart. Local builds
report `0.0.0-dev` and the commit count at `HEAD`; set `RAWTOUCH_VERSION`
to stamp a version, as the release workflow does.

## Reporting a problem

The README's [Reporting a problem](README.md#reporting-a-problem) lists
what to include in an issue and how to collect the app's log.

## Rules for changes

- **Scroll synthesis changes are validated offline first.** Run
  `scroll-bench --offline` before and after, and say what moved. Replays
  of the captures in `bench/captures/` are the evidence for feel changes;
  a feel judgement on hardware comes second.
- **Configuration keys are documented.** A new key goes in
  [docs/configuration.md](docs/configuration.md) with its range and default, and
  `config.example.json` stays consistent with the documented defaults.
  Unknown keys are logged, so a typo in a config file is visible.
- **Protocol changes are coordinated with the firmware.** The firmware
  module's [wire format](https://github.com/kalakris/zmk-raw-touch/blob/main/docs/protocol.md)
  is authoritative; the protocol integer is the only
  compatibility contract.
- Scroll events are posted at the session event tap, never the HID tap,
  so RawTouch composes with other mouse tools.
- Add tests next to the code you change. The suite uses injected clocks,
  display ticks, and event sinks; nothing in it needs keyboard hardware.

## Style

Swift is formatted with `swift format`, which ships with Xcode, using the
repository's `.swift-format` (4-space indent, 120 columns, otherwise the
defaults). Format before committing:

```sh
swift format format -i --parallel --recursive Package.swift Sources Tests
```

CI runs the same tool as `swift format lint --strict`. CI and the release
build both select one Xcode (27.2, on GitHub's macOS 27 image), because
formatter output can change between toolchain releases and because the
published app should come from the toolchain it was tested with. Use the
same Xcode locally when you can.

Match the surrounding code. Files derived from LinearMouse keep their
"Derived from LinearMouse" header and are listed in `LICENSE`; do not add
to that list without saying so in the pull request.
