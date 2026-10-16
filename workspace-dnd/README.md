# Workspace DnD

Drag a Hyprland workspace **from one monitor to another**, from a Noctalia panel.

- `plugin.toml` — manifest (bar widget + panel + one shared setting).
- `lib/model.luau` — pure model/logic; no I/O, Lua-5.1-compatible subset, unit-tested.
- `panel.luau` — the drag & drop surface.
- `widget.luau` — the bar button that opens the panel.
- `translations/` — `en`, `ru`.

## Open the panel

```sh
noctalia msg panel-toggle thegalkin/workspace-dnd:panel
```

or add the plugin's `open` bar widget (glyph `layout-grid`) to a bar.

## How it works

1. One round-trip reads `hyprctl -j monitors` and `hyprctl -j workspaces`.
2. Each monitor becomes a drop zone; each workspace on it is a draggable row.
3. Dropping a workspace onto another monitor's column dispatches

   ```
   hl.dsp.workspace.move({ workspace = <id>, monitor = "<name>" })
   ```

   and the panel refreshes. (Legacy `moveworkspacetomonitor` is dead on Hyprland
   builds with a Lua config, which is why the Lua dispatcher form is used.)

Full documentation, install instructions and the project layout live in the
[repository README](../README.md). The implementation contract is [`SPEC.md`](../SPEC.md).
