# VoomCLI

A standalone `voom` command-line tool for Voom screen recording, built purely
with SwiftPM (not part of the Xcode app). It reuses `VoomCore` + `VoomApp`, so
recordings land in the same `~/Movies/Voom` library as the app.

## Build

```sh
cd Packages/VoomCLI
swift build -c release
# binary at .build/release/voom
```

Install onto your PATH, e.g.:

```sh
cp .build/release/voom /usr/local/bin/voom
```

## Usage

```sh
voom guide --json                 # authoritative command contract (machine-readable)
voom targets --json               # list capturable displays + windows
voom record --json                # record until Ctrl-C
voom record --duration 30 --json  # fixed-length record
voom record --display <id> --mic --system-audio --json
voom list --json                  # recordings in ~/Movies/Voom
```

Screen recording needs macOS Screen Recording permission for the terminal/binary
(System Settings → Privacy & Security → Screen Recording).

## Claude Code / agent skill

A thin skill lives at [`skill/voom/SKILL.md`](./skill/voom/SKILL.md). Install it so
agents reach for Voom (e.g. "record a repro of this bug"):

```sh
cp -r skill/voom ~/.claude/skills/voom
```

It delegates to `voom guide --json`, so it never drifts from the binary.
