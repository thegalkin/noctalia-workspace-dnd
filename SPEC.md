# Spec — Noctalia plugin `thegalkin/workspace-dnd`

## Goal
Move a Hyprland **workspace from one monitor to another by drag and drop**, from a
Noctalia surface. The draggable item is the workspace's number ("циферка").

## Environment facts (hard constraints)
- Noctalia v5.3.0, plugin API range supported by the host: 3..34. Plugin declares `plugin_api = 26`.
- Noctalia drag & drop is **panels only**. `ui.dragSource` / `ui.dropZone` are rejected on bar
  widgets with a log message; a drag never leaves one panel; there is no OS/Wayland DnD.
- Therefore the interactive surface is a **panel**. The bar gets a button that opens it.
- The move itself is the **Lua dispatcher form**, because this Hyprland build runs a Lua
  config where legacy dispatchers are dead (`hyprctl dispatch moveworkspacetomonitor 2 DP-2`
  is rewritten to `return hl.dispatch(moveworkspacetomonitor 2 DP-2)` and fails to parse):
  `hyprctl dispatch 'hl.dsp.workspace.move({ workspace = <id>, monitor = "<monitor>" })'`
  Verified against the live compositor: a bad workspace yields
  `warning: Workspace not found` **on stdout** with **exit code 0**, so the exit code alone
  cannot be used to detect failure. A *successful* dispatch prints exactly `ok` on stdout
  with exit code 0 (verified live with a same-monitor no-op move, which leaves the layout
  untouched).
- Plugin files live at `<source-root>/workspace-dnd/` (id part after `/` must match the dir).

## Entries
1. `[[widget]] id = "open"`, entry `widget.luau`
   - Left click: toggle panel `thegalkin/workspace-dnd:panel`.
   - Static glyph (no polling).
2. `[[panel]] id = "panel"`, entry `panel.luau`
   - Declarative `ui.*` tree. Panel size is host-owned (declared in the manifest).

## Pure logic module — `lib/model.luau`
Requirements for the module:
- It **must not** perform I/O, spawn processes, or touch any Noctalia global
  (`noctalia`, `ui`, `panel`, `barWidget`). It is a pure data/transform module.
- It returns exactly one table `M` with the functions below.
- It is written in a Lua-5.1-compatible subset so a plain Lua interpreter can load it.

### Input shapes (already JSON-decoded by the caller)
`monitors` — array of:
```
{ name = "DP-2", width = 2560, height = 1440, x = 1440, y = 0,
  focused = false, activeWorkspace = { id = 6, name = "6" } }
```
`workspaces` — array of:
```
{ id = 6, name = "6", monitor = "DP-2", monitorID = 0, windows = 2 }
```
Fields may be missing. `id` may arrive as a number or a numeric string.

### `M.buildModel(monitors, workspaces) -> model | nil, err`
Builds:
```
model = {
  monitors = {
    { name, width, height, x, y, focused, activeId,
      workspaces = { { id, name, windows, active } } },
    ...
  }
}
```
Rules:
1. `monitors` and `workspaces` must both be tables (arrays), otherwise return `nil` plus a
   non-empty error string.
2. A monitor entry is kept only if `name` is a non-empty string. Missing numeric geometry
   fields default to `0`. `focused` defaults to `false`. `activeId` comes from
   `activeWorkspace.id` when present, else `nil`.
3. Monitors are ordered left-to-right: by `x` ascending, ties broken by `name` ascending.
4. A workspace is **excluded** when it is a "special" workspace, defined as: `id <= 0`, or
   `name` starts with `special:`, or `id` is not numeric after conversion.
5. A workspace is attached to the monitor whose `name` equals the workspace's `monitor`.
   Workspaces whose `monitor` names no kept monitor are dropped (not an error).
6. Within a monitor, workspaces are ordered by `id` ascending.
7. Workspace fields: `id` (number), `name` (string; `tostring(id)` when missing),
   `windows` (number, default `0`), `active` = `(id == that monitor's activeId)`.
8. The result must always be a valid model even when both inputs are empty lists
   (`model.monitors = {}`), never `nil`.

### `M.dropValue(monitorName) -> string`
Returns the drop-zone value encoding a monitor, `"mon:<monitorName>"`.

### `M.parseDropValue(value) -> string | nil`
Inverse of `M.dropValue`. Returns the monitor name, or `nil` for anything that is not a
`"mon:"`-prefixed string. An empty monitor name is invalid → `nil`.

### `M.wsPayload(wsId) -> string`
Returns the drag payload encoding a workspace, `"ws:<id>"`.

### `M.parseWsPayload(payload) -> number | nil`
Inverse of `M.wsPayload`. Returns the numeric id, or `nil` when the payload is not a
`"ws:"`-prefixed string or the remainder is not numeric.

### `M.planMove(model, payload, value) -> plan | nil, err`
Decides what to do for a completed drop. Returns a plan
`{ workspace = <number>, monitor = <string>, name = <string> }` where `name` is the
workspace's display name from the model, or returns `nil` plus one of these error codes:

| condition | result |
|---|---|
| `payload` or `value` malformed | `nil, "invalid-drop"` |
| workspace id not present in the model | `nil, "unknown-workspace"` |
| target monitor not present in the model | `nil, "unknown-monitor"` |
| workspace already on the target monitor | `nil, "same-monitor"` |

`planMove` must be side-effect free and must not mutate `model`.

### `M.SEP` (string)
The literal separator token, exactly `"__WSDND__"`.

### `M.snapshotCommand() -> string`
Returns the single shell command the panel runs to snapshot the compositor. It must be a
non-empty string that contains both `hyprctl -j monitors` and `hyprctl -j workspaces`, and
print the two outputs separated by a line whose content is exactly `M.SEP`.

### `M.splitSnapshot(stdout) -> monitorsJson, workspacesJson | nil, err`
Splits a `snapshotCommand` stdout into its two halves on the first occurrence of
`"\n" .. M.SEP .. "\n"`.
- Not a string, or the separator is missing → `nil, "no-separator"`.
- Otherwise returns the two halves as strings (first half excludes the separator line,
  second half is everything after it).

### `M.describeWorkspace(ws, showCounts) -> string`
Human label for a workspace row:
- Base is `"#"` followed by `tostring(ws.id)`.
- When `showCounts` is truthy **and** `ws.windows` is a number `> 0`, append `"  ·"` followed
  by `tostring(ws.windows)`.
- Otherwise no suffix.

### `M.escapeLuaString(value) -> string`
Escapes a value for insertion inside a double-quoted Lua string literal. `tostring`s the
value, then escapes backslash → `\\`, double quote → `\"`, LF → `\n`, CR → `\r`. The result
never contains a raw `"`, `\`, LF or CR.

### `M.buildDispatchArgs(plan) -> { string } | nil`
Returns exactly a 3-element array `{ "hyprctl", "dispatch", <expr> }` whose `<expr>` is
`hl.dsp.workspace.move({ workspace = <id>, monitor = "<escaped monitor>" })`, with `<id>`
rendered unquoted from the numeric `plan.workspace` and the monitor escaped via
`M.escapeLuaString`. Returns `nil` when `plan` is not a table, when `plan.workspace` is not
convertible to a number, or when `plan.monitor` is not a non-empty string.

### `M.dispatchFailure(result) -> string | nil`
Decides whether a `hyprctl` dispatch result failed.
- `result == nil` → `"no result"`.
- Otherwise concatenate `result.stdout` and `result.stderr` (non-string fields count as empty)
  into `out`. If the lower-cased `out` contains `warning:` or `error` → return `out`.
- Else if `result.exitCode` converts to a number `~= 0` → return `out` when non-empty,
  otherwise `"exit code <exitCode>"`.
- Otherwise → `nil` (success).

### `M.statusKey(err) -> string`
Maps a `planMove` error to a translation key:
- `"same-monitor"` → `"status.same_monitor"`
- anything else, including `nil` → `"status.no_target"`

## Panel behavior (`panel.luau`)
- Open (`onOpen`): read the plugin setting `show_counts` via `noctalia.getConfig`
  (default `true` when the read returns `nil`), run exactly one
  `noctalia.runAsync(M.snapshotCommand(), cb)`, and render.
- **Refresh policy — no periodic tick.** Refresh happens on open, on the refresh button, and
  after every drop. Rationale: the host owns pointer capture during a drag, so a re-render
  mid-gesture could cancel it. (This supersedes any "keep fresh while open" idea: the panel
  must NOT call `panel.setWantsSecondTicks(true)`.)
- Fetch callback: split with `M.splitSnapshot`, decode both halves with `noctalia.json.decode`,
  build with `M.buildModel`; on a split/decode/build failure show an error status instead of
  rendering a model.
- Render: header (title + refresh + close), one **drop zone per monitor**
  (`value = M.dropValue(name)`, `accepts = { "ws" }`, `onDrop = "onDrop"`), each containing one
  draggable row per workspace (`dragType = "ws"`, `payload = M.wsPayload(id)`,
  `previewAncestor = 1`, `liftFromLayout = true`). The row's text comes from
  `M.describeWorkspace(ws, showCounts)`.
- Drop (`onDrop(payload, value)`): call `M.planMove`.
  - plan is `nil` → set the status from `M.statusKey(err)` and re-render, running nothing.
  - plan exists → run `noctalia.runAsync(M.buildDispatchArgs(plan), cb)` (argument-array form,
    never a shell string). In `cb`, decide success/failure with `M.dispatchFailure(result)`:
    `nil` → success status; a detail string → error status plus a `noctalia.log(...)` line.
    Then refresh. If `runAsync` returns false, set an error status and re-render.
- Plugin setting `show_counts` (bool, default `true`) toggles the window-count suffix.

## Testability contract
`panel.luau` and `widget.luau` must stay loadable and drivable by a plain Lua interpreter
(Lua 5.1 subset, no Luau-only syntax) when the harness provides stubbed globals
(`noctalia`, `ui`, `panel`, `barWidget`) and a stubbed `require`. Their orchestration
(fetch→parse→render, drop→dispatch) must therefore be observable through those stubs.

Host APIs the entries may call (harness must stub exactly these):
- `require("<path>.luau")` — resolves a sibling module; in a harness any `require` may be
  mapped to `dofile("workspace-dnd/lib/model.luau")`.
- `noctalia.tr(key, subst?)`, `noctalia.getConfig(key)`, `noctalia.json.decode(text)`,
  `noctalia.runAsync(cmdOrArgv, callback) -> boolean`, `noctalia.togglePanel(id)`,
  `noctalia.log(msg)` (the panel logs a line when a drop fails).
- `ui.*` constructors return an opaque node; the harness may return a table that records
  the props/children it was given.
- `panel.render(node)`, `panel.close()`.
- `barWidget.setGlyph(name)`, `barWidget.setTooltip(text)`.

Entry globals the host calls (harness drives these by name):
- `panel.luau`: `onOpen(context)`, `onClose()`, `onDrop(payload, value)`,
  `onRefreshClicked()`, `onCloseClicked()`, and a local `render()` used internally.
- `widget.luau`: `onClick()`.

