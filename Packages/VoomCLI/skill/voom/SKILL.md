---
name: voom
description: Record the macOS screen from the command line with Voom. Use when asked to capture a screen recording, record a repro or demo, or list/inspect Voom recordings.
---

# Voom screen recording

Use the `voom` CLI to record the screen and manage recordings. Every command
accepts `--json` for machine-readable output on stdout.

**Always run `voom guide --json` first** to get the authoritative, always-current
command contract — don't hardcode flags from this file, which may lag the binary.

## Common tasks

- Record until stopped: `voom record --json` (stops on Ctrl-C / SIGINT).
- Fixed-length record: `voom record --duration 30 --json`.
- Pick a display: `voom targets --json` to list displays, then
  `voom record --display <id> --json`.
- Include audio: add `--mic` and/or `--system-audio`.
- List recordings: `voom list --json`.

Recordings are written to the user's Voom library (`~/Movies/Voom`); the `record`
result JSON includes the new recording's `id`, `title`, and `path`.

## Permissions

Screen recording requires macOS Screen Recording permission for the terminal (or
the `voom` binary): System Settings → Privacy & Security → Screen Recording. If a
command returns a permission error, tell the user to grant it there.
