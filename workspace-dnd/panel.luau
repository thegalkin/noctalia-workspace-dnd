--!nonstrict
-- Workspace DnD — panel.
--
-- Noctalia only allows drag sources inside panels, so this is where the
-- interaction lives: drag a workspace's number onto another monitor's column,
-- and the drop runs
--     hyprctl dispatch moveworkspacetomonitor <workspace> <monitor>
--
-- Open with: noctalia msg panel-toggle thegalkin/workspace-dnd:panel

local model = require("./lib/model.luau")

local DRAG_TYPE = "ws"

local built = nil
local status = ""
local statusIsError = false
local inFlight = false
local opened = false
local showCounts = true

local function tr(key, subst)
  return noctalia.tr(key, subst)
end

local function setStatus(text, isError)
  status = text
  statusIsError = isError == true
end

-- ── data ───────────────────────────────────────────────────────────────────

local render

local function apply(monitors, workspaces)
  local nextModel, err = model.buildModel(monitors, workspaces)
  if nextModel == nil then
    built = nil
    setStatus(tr("status.parse_failed", { error = tostring(err) }), true)
  else
    built = nextModel
  end
  if opened then
    render()
  end
end

local function failFetch()
  built = nil
  setStatus(tr("status.query_failed"), true)
  if opened then
    render()
  end
end

local function fetch()
  if inFlight then
    return
  end
  inFlight = true

  local accepted = noctalia.runAsync(model.snapshotCommand(), function(result)
    inFlight = false
    if result == nil or result.exitCode ~= 0 then
      failFetch()
      return
    end
    local monitorsJson, workspacesJson = model.splitSnapshot(result.stdout)
    if monitorsJson == nil then
      failFetch()
      return
    end
    apply(noctalia.json.decode(monitorsJson), noctalia.json.decode(workspacesJson))
  end)

  if not accepted then
    inFlight = false
    failFetch()
  end
end

-- ── callbacks ──────────────────────────────────────────────────────────────

function onDrop(payload, value)
  if built == nil then
    return
  end

  local plan, err = model.planMove(built, payload, value)
  if plan == nil then
    setStatus(tr(model.statusKey(err)), false)
    render()
    return
  end

  local target = plan.monitor
  local id = plan.workspace
  setStatus(tr("status.moving", { workspace = tostring(id), monitor = target }), false)
  render()

  local accepted = noctalia.runAsync(model.buildDispatchArgs(plan), function(result)
    local detail = model.dispatchFailure(result)
    if detail == nil then
      setStatus(tr("status.moved", { workspace = tostring(id), monitor = target }), false)
    else
      noctalia.log("workspace-dnd: move failed: " .. tostring(detail))
      setStatus(tr("status.failed", { detail = tostring(detail) }), true)
    end
    fetch()
  end)

  if not accepted then
    noctalia.log("workspace-dnd: dispatch rejected by host")
    setStatus(tr("status.failed", { detail = "rejected by host" }), true)
    render()
  end
end

function onRefreshClicked()
  fetch()
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  opened = true
  showCounts = noctalia.getConfig("show_counts") ~= false
  fetch()
  render()
end

function onClose()
  opened = false
end

-- Deliberately no per-second tick: the host owns pointer capture during a drag,
-- and a re-render mid-gesture could drop it. The panel refreshes on open, on the
-- refresh button, and after every drop instead.

-- ── rendering ──────────────────────────────────────────────────────────────

local function fg(active)
  if active then
    return "primary"
  end
  return nil
end

local function workspaceRow(mon, ws)
  local label = model.describeWorkspace(ws, showCounts)

  local children = {
    ui.dragSource({
      key = "grip-" .. mon.name .. "-" .. tostring(ws.id),
      dragType = DRAG_TYPE,
      payload = model.wsPayload(ws.id),
      previewAncestor = 1,
      liftFromLayout = true,
      width = 26,
      height = 26,
      align = "center",
      justify = "center",
      tooltip = tr("drag.tooltip"),
    }, {
      ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
    }),
    ui.label({
      text = label,
      flexGrow = 1,
      fontWeight = ws.active and "bold" or nil,
      color = fg(ws.active),
    }),
  }

  if ws.name ~= tostring(ws.id) then
    table.insert(children, ui.label({
      text = ws.name,
      fontSize = 12,
      color = "on_surface_variant",
      maxWidth = 160,
      maxLines = 1,
    }))
  end

  return ui.row({
    key = "ws-" .. mon.name .. "-" .. tostring(ws.id),
    gap = 8,
    align = "center",
    padding = 6,
    radius = 10,
    fill = ws.active and "primary/0.18" or "surface_variant/0.4",
  }, children)
end

local function monitorColumn(mon)
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = mon.name, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({
        text = string.format("%d×%d", mon.width, mon.height),
        fontSize = 12,
        color = "on_surface_variant",
      }),
    }),
  }

  if #mon.workspaces == 0 then
    table.insert(children, ui.label({
      text = tr("empty"),
      fontSize = 12,
      color = "on_surface_variant",
    }))
  else
    for _, ws in ipairs(mon.workspaces) do
      table.insert(children, workspaceRow(mon, ws))
    end
  end

  return ui.dropZone({
    key = "mon-" .. mon.name,
    accepts = { DRAG_TYPE },
    value = model.dropValue(mon.name),
    onDrop = "onDrop",
    gap = 6,
    padding = 8,
    radius = 12,
    fill = "surface_variant/0.15",
    border = mon.focused and "primary/0.7" or "outline/0.3",
    borderWidth = mon.focused and 2 or 1,
    flexGrow = 1,
  }, children)
end

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
    ui.button({ glyph = "refresh", tooltip = tr("refresh"), onClick = "onRefreshClicked" }),
    ui.button({ glyph = "close", tooltip = tr("close"), onClick = "onCloseClicked" }),
  })
end

function render()
  local body
  if built == nil or #built.monitors == 0 then
    body = ui.label({ text = tr("empty"), fontSize = 13, color = "on_surface_variant" })
  else
    local columns = {}
    for _, mon in ipairs(built.monitors) do
      table.insert(columns, monitorColumn(mon))
    end
    body = ui.row({ gap = 12, align = "stretch", flexGrow = 1 }, columns)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    header(),
    body,
    ui.label({
      text = status,
      fontSize = 12,
      color = statusIsError and "error" or "on_surface_variant",
    }),
  }))
end
