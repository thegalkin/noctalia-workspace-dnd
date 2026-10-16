# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-10-16

First release.

### Added
- `open` bar widget — a button that toggles the drag & drop panel.
- `panel` entry — one drop zone per monitor, each holding a draggable row per
  workspace (number, window count, active marker).
- Drag a workspace onto another monitor's column to move it there.
- `show_counts` plugin setting (bool, default `true`).
- English and Russian translations.

### Notes
- The move is dispatched with the **Lua dispatcher form**
  `hl.dsp.workspace.move({ workspace = <id>, monitor = "<name>" })`. This is
  required on Hyprland builds that run a Lua config, where legacy dispatchers
  (`hyprctl dispatch moveworkspacetomonitor …`) are rewritten into Lua and fail
  to parse.
- Workspace numbers are always rendered unquoted and monitor names are escaped,
  so neither can break out of the generated dispatcher expression.
- The panel intentionally has **no periodic refresh**: the host owns pointer
  capture during a drag, and re-rendering mid-gesture could cancel it. It
  refreshes on open, on the refresh button, and after every drop.
