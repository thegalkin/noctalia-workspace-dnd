-- tests/entries_test.lua
-- Black-box orchestration tests for panel.luau / widget.luau, driven with stub
-- globals. Written STRICTLY from the specification. The entry sources are never
-- read, only loaded/executed via dofile() with stubbed host APIs.

-- Resolve paths relative to this script so the suite runs from any directory.
local function repoRoot()
  local src = (arg and arg[0]) or "."
  local dir = string.match(src, "^(.*)[/\\][^/\\]*$") or "."
  return dir .. "/.."
end

local ROOT = repoRoot()
local PANEL_PATH = ROOT .. "/workspace-dnd/panel.luau"
local WIDGET_PATH = ROOT .. "/workspace-dnd/widget.luau"
local MODULE_PATH = ROOT .. "/workspace-dnd/lib/model.luau"

local total, passed, failed = 0, 0, 0

local function ser(v)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return tostring(v)
end

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function check(name, cond, expected, actual)
  total = total + 1
  if cond then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. ser(expected) .. " != " .. ser(actual))
  end
end

local function expectEqual(name, actual, expected)
  check(name, deepEqual(actual, expected), expected, actual)
end

local function containsStr(haystack, needle)
  return type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Load the pure module (used by the entries through the stubbed require).
-- ---------------------------------------------------------------------------
local loadOk, M = pcall(dofile, MODULE_PATH)
check("model module loads (dependency for entries)", loadOk and type(M) == "table",
  "table", loadOk and type(M) or M)
if not (loadOk and type(M) == "table") then
  print(string.format("TOTAL %d PASSED %d FAILED %d", total, passed, failed))
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Stub UI node model: ui.* constructors return a node recording props/children.
-- The documented calling convention is ui.name(props[, children]); we accept a
-- little more (children as an array or as varargs, props optional) so we can
-- assert on the tree without reading the panel source.
-- ---------------------------------------------------------------------------
local NODE_MT = {}

local function isNode(v)
  return type(v) == "table" and getmetatable(v) == NODE_MT
end

local function makeNode(name)
  return setmetatable({ name = name, props = {}, children = {}, raw = {} }, NODE_MT)
end

local function addChild(node, v)
  if v == nil then return end
  if isNode(v) then
    node.children[#node.children + 1] = v
  elseif type(v) == "table" then
    for _, c in ipairs(v) do addChild(node, c) end
  elseif type(v) == "string" then
    node.raw[#node.raw + 1] = v
  end
end

local function makeCtor(name)
  return function(...)
    local node = makeNode(name)
    local n = select("#", ...)
    local startChild = 1
    if n >= 1 then
      local first = (select(1, ...))
      if type(first) == "table" and not isNode(first) then
        local looksLikeChildList = #first > 0
        if looksLikeChildList then
          for i = 1, #first do
            if not isNode(first[i]) then looksLikeChildList = false; break end
          end
        end
        if not looksLikeChildList then
          node.props = first
          startChild = 2
        end
      end
    end
    for i = startChild, n do addChild(node, (select(i, ...))) end
    return node
  end
end

-- ---------------------------------------------------------------------------
-- Stub state + host globals.
-- ---------------------------------------------------------------------------
local state

local function newState(cfg)
  return {
    cfg = cfg or {},
    runcalls = {},       -- { cmd = ..., cb = ... }
    renders = {},        -- panel.render nodes (latest = last)
    closed = 0,
    secondTicks = 0,
    secondTicksValue = nil,
    trcalls = {},        -- { key = ..., subst = ... }
    getConfigKeys = {},
    toggles = {},
    glyphs = {},
    tooltips = {},
    decodeMap = {},
    logs = {},           -- noctalia.log(msg)
    runAsyncResult = true,
  }
end

state = newState({})

_G.ui = setmetatable({}, {
  __index = function(t, k)
    if type(k) ~= "string" then return nil end
    local f = makeCtor(k)
    rawset(t, k, f)
    return f
  end,
})

_G.noctalia = {
  tr = function(key, subst)
    state.trcalls[#state.trcalls + 1] = { key = key, subst = subst }
    return "TR:" .. tostring(key)
  end,
  getConfig = function(key)
    state.getConfigKeys[#state.getConfigKeys + 1] = key
    return state.cfg[key]
  end,
  json = {
    decode = function(text)
      return state.decodeMap[text]
    end,
  },
  runAsync = function(cmd, cb)
    state.runcalls[#state.runcalls + 1] = { cmd = cmd, cb = cb }
    return state.runAsyncResult ~= false
  end,
  togglePanel = function(id)
    state.toggles[#state.toggles + 1] = id
  end,
  log = function(msg)
    state.logs[#state.logs + 1] = msg
  end,
}

_G.panel = {
  render = function(node)
    state.renders[#state.renders + 1] = node
  end,
  close = function()
    state.closed = state.closed + 1
  end,
  setWantsSecondTicks = function(v)
    state.secondTicks = state.secondTicks + 1
    state.secondTicksValue = v
  end,
}

_G.barWidget = {
  setGlyph = function(name) state.glyphs[#state.glyphs + 1] = name end,
  setTooltip = function(text) state.tooltips[#state.tooltips + 1] = text end,
}

-- ---------------------------------------------------------------------------
-- Tree helpers.
-- ---------------------------------------------------------------------------
local function walk(node, fn)
  fn(node)
  for _, c in ipairs(node.children) do walk(c, fn) end
end

local function collectAll(root)
  local out = {}
  walk(root, function(n) out[#out + 1] = n end)
  return out
end

local function acceptsType(node, t)
  local a = node.props and node.props.accepts
  if type(a) == "table" then
    for _, v in ipairs(a) do if v == t then return true end end
  end
  return false
end

local function findDropZones(root)
  local out = {}
  for _, n in ipairs(collectAll(root)) do
    if acceptsType(n, "ws") then out[#out + 1] = n end
  end
  return out
end

local function findDragSources(root)
  local out = {}
  for _, n in ipairs(collectAll(root)) do
    if type(n.props) == "table" and n.props.dragType == "ws" then out[#out + 1] = n end
  end
  return out
end

local function collectTexts(node, out)
  out = out or {}
  local function rec(v)
    if type(v) == "string" then
      out[#out + 1] = v
    elseif type(v) == "table" then
      if isNode(v) then
        collectTexts(v, out)
      else
        for _, x in pairs(v) do rec(x) end
      end
    end
  end
  rec(node.props)
  for _, s in ipairs(node.raw) do rec(s) end
  for _, c in ipairs(node.children) do collectTexts(c, out) end
  return out
end

local function textsInclude(node, s)
  for _, v in ipairs(collectTexts(node)) do if v == s then return true end end
  return false
end

local function parentMap(root)
  local p = {}
  local function rec(n, par)
    p[n] = par
    for _, c in ipairs(n.children) do rec(c, n) end
  end
  rec(root, nil)
  return p
end

local function ancestors(node, pm)
  local out = {}
  local cur = pm[node]
  while cur do out[#out + 1] = cur; cur = pm[cur] end
  return out
end

local function trKeySet()
  local s = {}
  for _, t in ipairs(state.trcalls) do s[t.key] = true end
  return s
end

local function trKeyPresent(key)
  for _, t in ipairs(state.trcalls) do if t.key == key then return true end end
  return false
end

local function findAll(root, pred)
  local out = {}
  if root == nil then return out end
  for _, n in ipairs(collectAll(root)) do
    if pred(n) then out[#out + 1] = n end
  end
  return out
end

local function latestCb()
  local call = state.runcalls[#state.runcalls]
  return call and call.cb or nil
end

-- ---------------------------------------------------------------------------
-- Panel data + driving helpers.
-- ---------------------------------------------------------------------------
local MONITORS = {
  { name = "DP-1", width = 1920, height = 1080, x = 0, y = 0, focused = false, activeWorkspace = { id = 1, name = "1" } },
  { name = "DP-2", width = 2560, height = 1440, x = 1920, y = 0, focused = true, activeWorkspace = { id = 6, name = "6" } },
}
local WORKSPACES = {
  { id = 1, name = "1", monitor = "DP-1", windows = 0 },
  { id = 7, name = "Code", monitor = "DP-1", windows = 1 },
  { id = 4, name = "4", monitor = "DP-2", windows = 3 },
  { id = 6, name = "6", monitor = "DP-2", windows = 2 },
}
local MON_JSON = '{"payload":"monitors"}'
local WS_JSON = '{"payload":"workspaces"}'
local GOOD_STDOUT = MON_JSON .. "\n" .. M.SEP .. "\n" .. WS_JSON

local function loadPanel(cfg)
  state = newState(cfg)
  state.decodeMap[MON_JSON] = MONITORS
  state.decodeMap[WS_JSON] = WORKSPACES
  _G.require = function() return M end
  local ok, err = pcall(dofile, PANEL_PATH)
  return ok, err
end

local function openPanel(cfg)
  local ok, err = loadPanel(cfg)
  check("panel loads without error", ok, "loads", ok and "ok" or err)
  if ok and type(_G.onOpen) == "function" then
    local ok2, err2 = pcall(_G.onOpen, { id = "panel" })
    check("panel.onOpen runs without error", ok2, "no error", ok2 and "ok" or err2)
  end
  return ok
end

local function lastRoot()
  return state.renders[#state.renders]
end

local function driveSnapshot(stdout)
  local call = state.runcalls[1]
  if call and type(call.cb) == "function" then
    return pcall(call.cb, { exitCode = 0, stdout = stdout })
  end
  return false, "no snapshot callback recorded"
end

-- ---------------------------------------------------------------------------
-- Panel: onOpen reads show_counts and issues exactly one snapshot runAsync.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })

  local sawKey = false
  for _, k in ipairs(state.getConfigKeys) do if k == "show_counts" then sawKey = true end end
  check("panel onOpen reads show_counts via getConfig", sawKey,
    "getConfig('show_counts')", state.getConfigKeys)

  check("panel onOpen issues exactly one runAsync", #state.runcalls == 1, 1, #state.runcalls)

  local cmd = state.runcalls[1] and state.runcalls[1].cmd
  check("panel snapshot command is a shell string",
    type(cmd) == "string", "string", type(cmd))
  check("panel snapshot command equals M.snapshotCommand()",
    cmd == M.snapshotCommand(), M.snapshotCommand(), cmd)
  check("panel snapshot command contains 'hyprctl -j monitors'",
    containsStr(cmd, "hyprctl -j monitors"), "contains 'hyprctl -j monitors'", cmd)
  check("panel snapshot command contains 'hyprctl -j workspaces'",
    containsStr(cmd, "hyprctl -j workspaces"), "contains 'hyprctl -j workspaces'", cmd)
  check("panel onOpen renders a tree", #state.renders >= 1, ">= 1 render", #state.renders)
  check("panel onOpen passes a function callback",
    state.runcalls[1] ~= nil and type(state.runcalls[1].cb) == "function",
    "function", state.runcalls[1] and type(state.runcalls[1].cb) or "n/a")
end

-- ---------------------------------------------------------------------------
-- Panel: fetch callback builds the model and renders drop zones / drag rows.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  local ok = driveSnapshot(GOOD_STDOUT)
  check("panel fetch callback runs without error", ok, "no error", ok)

  local root = lastRoot()
  check("panel rendered a tree after the fetch callback", root ~= nil, "tree", root)

  if root then
    local dz = findDropZones(root)
    check("panel renders exactly one drop zone per monitor", #dz == #MONITORS, #MONITORS, #dz)

    local dzByValue = {}
    for _, z in ipairs(dz) do dzByValue[z.props.value] = z end
    for _, mon in ipairs(MONITORS) do
      local z = dzByValue[M.dropValue(mon.name)]
      check("drop zone value is M.dropValue(" .. mon.name .. ")", z ~= nil,
        M.dropValue(mon.name), z and z.props.value or "no zone")
      if z then
        check("drop zone " .. mon.name .. " accepts 'ws'", acceptsType(z, "ws"),
          'accepts includes "ws"', z.props.accepts)
        check("drop zone " .. mon.name .. " onDrop == 'onDrop'", z.props.onDrop == "onDrop",
          "onDrop", z.props.onDrop)
      end
    end

    local ds = findDragSources(root)
    check("panel renders one drag source per workspace", #ds == #WORKSPACES,
      #WORKSPACES, #ds)

    local dsByPayload = {}
    for _, d in ipairs(ds) do dsByPayload[d.props.payload] = d end
    local pm = parentMap(root)

    for _, ws in ipairs(WORKSPACES) do
      local d = dsByPayload[M.wsPayload(ws.id)]
      check("drag source payload is M.wsPayload(" .. ws.id .. ")", d ~= nil,
        M.wsPayload(ws.id), d and d.props.payload or "no drag source")
      if d then
        check("ws " .. ws.id .. " dragType == 'ws'", d.props.dragType == "ws", "ws", d.props.dragType)
        check("ws " .. ws.id .. " previewAncestor == 1", d.props.previewAncestor == 1,
          1, d.props.previewAncestor)
        check("ws " .. ws.id .. " liftFromLayout == true", d.props.liftFromLayout == true,
          true, d.props.liftFromLayout)

        -- scope = the row: highest ancestor below the enclosing drop zone.
        local scope = d
        local zone = nil
        for _, anc in ipairs(ancestors(d, pm)) do
          if acceptsType(anc, "ws") then zone = anc; break end
          scope = anc
        end
        local label = M.describeWorkspace(ws, true)
        local found = textsInclude(scope, label)
        if not found and zone then found = textsInclude(zone, label) end
        check("ws " .. ws.id .. " row label is describeWorkspace(ws, true) = " .. label,
          found, label, collectTexts(scope))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Panel: show_counts default (absent -> counts shown) and explicit false.
-- ---------------------------------------------------------------------------
do
  openPanel({}) -- getConfig returns nil
  driveSnapshot(GOOD_STDOUT)
  local root = lastRoot()
  check("panel shows counts when show_counts is absent (default true)",
    root ~= nil and textsInclude(root, M.describeWorkspace({ id = 6, windows = 2 }, true)),
    M.describeWorkspace({ id = 6, windows = 2 }, true),
    root and collectTexts(root) or "no tree")
end

do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local root = lastRoot()
  check("panel hides counts when show_counts is false",
    root ~= nil and textsInclude(root, "#6") and not textsInclude(root, M.describeWorkspace({ id = 6, windows = 2 }, true)),
    "#6 (no suffix)", root and collectTexts(root) or "no tree")
end

-- ---------------------------------------------------------------------------
-- Panel: onDrop same-monitor -> status, no dispatch.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)

  local runsBefore = #state.runcalls
  local rendersBefore = #state.renders
  local ok = pcall(_G.onDrop, M.wsPayload(6), M.dropValue("DP-2")) -- ws 6 already on DP-2
  check("panel onDrop same-monitor runs without error", ok, "no error", ok)
  check("panel onDrop same-monitor runs no command", #state.runcalls == runsBefore,
    runsBefore, #state.runcalls)

  local sawSame = false
  for _, t in ipairs(state.trcalls) do
    if t.key == "status.same_monitor" then sawSame = true end
  end
  check("panel onDrop same-monitor sets status.same_monitor", sawSame,
    "tr('status.same_monitor')", state.trcalls)

  check("panel onDrop same-monitor re-renders", #state.renders > rendersBefore,
    "> " .. rendersBefore, #state.renders)
end

-- ---------------------------------------------------------------------------
-- Panel: onDrop cross-monitor -> argv dispatch, then refresh on success.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)

  local runsBefore = #state.runcalls
  local ok = pcall(_G.onDrop, M.wsPayload(7), M.dropValue("DP-2")) -- ws 7 (DP-1) -> DP-2
  check("panel onDrop cross-monitor runs without error", ok, "no error", ok)

  local dispatch = state.runcalls[runsBefore + 1]
  check("panel onDrop cross-monitor issues one dispatch runAsync", dispatch ~= nil,
    runsBefore + 1, #state.runcalls)

  if dispatch then
    check("panel dispatch uses argv form (a table, not a shell string)",
      type(dispatch.cmd) == "table", "table", type(dispatch.cmd))
    expectEqual("panel dispatch argv equals buildDispatchArgs(plan)",
      dispatch.cmd,
      { "hyprctl", "dispatch", 'hl.dsp.workspace.move({ workspace = 7, monitor = "DP-2" })' })
    check("panel dispatch argv has exactly 3 elements",
      type(dispatch.cmd) == "table" and #dispatch.cmd == 3, 3,
      type(dispatch.cmd) == "table" and #dispatch.cmd or "n/a")

    local runsAfterDispatch = #state.runcalls
    if type(dispatch.cb) == "function" then
      pcall(dispatch.cb, { exitCode = 0 })
    end
    check("panel successful dispatch triggers a further refresh runAsync",
      #state.runcalls > runsAfterDispatch, "> " .. runsAfterDispatch, #state.runcalls)
    local refresh = state.runcalls[#state.runcalls]
    check("panel refresh after dispatch uses the snapshot command",
      refresh ~= nil and refresh.cmd == M.snapshotCommand(),
      M.snapshotCommand(), refresh and refresh.cmd or "no refresh")
  end
end

-- ---------------------------------------------------------------------------
-- Panel: fetch whose halves decode to non-tables -> status.parse_failed, no model
-- (and no stale zones left over from a previous successful fetch).
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  check("precondition: good fetch renders one drop zone per monitor",
    lastRoot() ~= nil and #findDropZones(lastRoot()) == #MONITORS, #MONITORS,
    lastRoot() and #findDropZones(lastRoot()) or "no tree")

  -- "null" / "5" decode to non-table values, so M.buildModel must refuse them
  -- (spec rule 1: both inputs must be tables).
  state.decodeMap["null"] = "null"
  state.decodeMap["5"] = 5
  local built = M.buildModel(state.decodeMap["null"], state.decodeMap["5"])
  check("precondition: non-table halves cannot build a model", built == nil,
    "nil", built)

  if type(_G.onRefreshClicked) == "function" then pcall(_G.onRefreshClicked) end
  local cb = latestCb()
  local ok = pcall(cb, { exitCode = 0, stdout = "null" .. "\n" .. M.SEP .. "\n" .. "5" })
  check("panel build-failure fetch callback runs without error", ok, "no error", ok)

  local root = lastRoot()
  check("panel build failure renders no drop zones (no stale model)",
    root ~= nil and #findDropZones(root) == 0, 0,
    root and #findDropZones(root) or "no tree")
  check("panel build failure sets status.parse_failed",
    trKeyPresent("status.parse_failed"), "tr('status.parse_failed')", state.trcalls)
end

-- ---------------------------------------------------------------------------
-- Panel: cross-monitor drop FAILURE reporting (stdout warning / non-zero exit).
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local runsBefore = #state.runcalls
  local logsBefore = #state.logs
  local ok = pcall(_G.onDrop, M.wsPayload(7), M.dropValue("DP-2"))
  check("panel drop-failure (stdout warning) drop runs without error", ok, "no error", ok)

  local dispatch = state.runcalls[runsBefore + 1]
  check("panel drop-failure (stdout warning) issues a dispatch runAsync", dispatch ~= nil,
    runsBefore + 1, #state.runcalls)
  if dispatch and type(dispatch.cb) == "function" then
    local runsAtCb = #state.runcalls
    local ok2 = pcall(dispatch.cb, { exitCode = 0, stdout = "warning: Workspace not found", stderr = "" })
    check("panel drop failure (stdout warning) callback runs without error", ok2, "no error", ok2)
    check("panel drop failure (stdout warning) sets status.failed",
      trKeyPresent("status.failed"), "tr('status.failed')", state.trcalls)
    check("panel drop failure (stdout warning) calls noctalia.log",
      #state.logs > logsBefore, "> " .. logsBefore, #state.logs)
    check("panel drop failure (stdout warning) still triggers a refresh",
      #state.runcalls > runsAtCb, "> " .. runsAtCb, #state.runcalls)
  end
end

do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local runsBefore = #state.runcalls
  local logsBefore = #state.logs
  pcall(_G.onDrop, M.wsPayload(7), M.dropValue("DP-2"))
  local dispatch = state.runcalls[runsBefore + 1]
  check("panel drop-failure (exit 7) issues a dispatch runAsync", dispatch ~= nil,
    runsBefore + 1, #state.runcalls)
  if dispatch and type(dispatch.cb) == "function" then
    local ok2 = pcall(dispatch.cb, { exitCode = 7, stdout = "", stderr = "" })
    check("panel drop failure (exit 7) callback runs without error", ok2, "no error", ok2)
    check("panel drop failure (exit 7) sets status.failed",
      trKeyPresent("status.failed"), "tr('status.failed')", state.trcalls)
    check("panel drop failure (exit 7) calls noctalia.log",
      #state.logs > logsBefore, "> " .. logsBefore, #state.logs)
  end
end

-- ---------------------------------------------------------------------------
-- Panel: cross-monitor drop SUCCESS reporting (empty result -> status.moved).
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local runsBefore = #state.runcalls
  pcall(_G.onDrop, M.wsPayload(7), M.dropValue("DP-2"))
  local dispatch = state.runcalls[runsBefore + 1]
  check("panel drop-success issues a dispatch runAsync", dispatch ~= nil,
    runsBefore + 1, #state.runcalls)
  if dispatch and type(dispatch.cb) == "function" then
    local runsAtCb = #state.runcalls
    local ok2 = pcall(dispatch.cb, { exitCode = 0, stdout = "", stderr = "" })
    check("panel successful drop callback runs without error", ok2, "no error", ok2)
    check("panel successful drop sets status.moved",
      trKeyPresent("status.moved"), "tr('status.moved')", state.trcalls)
    check("panel successful drop does not set status.failed",
      not trKeyPresent("status.failed"), "no tr('status.failed')", state.trcalls)
    check("panel successful drop triggers a further refresh",
      #state.runcalls > runsAtCb, "> " .. runsAtCb, #state.runcalls)
  end
end

-- ---------------------------------------------------------------------------
-- Panel: header buttons and onCloseClicked -> panel.close() exactly once.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  local root = lastRoot() -- capture the rendered tree before closing

  check("panel defines onCloseClicked", type(_G.onCloseClicked) == "function",
    "function", type(_G.onCloseClicked))
  local closedBefore = state.closed
  if type(_G.onCloseClicked) == "function" then
    local ok = pcall(_G.onCloseClicked)
    check("panel onCloseClicked runs without error", ok, "no error", ok)
  end
  check("panel onCloseClicked calls panel.close exactly once",
    state.closed - closedBefore == 1, 1, state.closed - closedBefore)

  check("panel rendered a tree for header inspection", root ~= nil, "tree", root)
  if root then
    local buttons = findAll(root, function(n) return n.name == "button" end)
    local hasClose, hasRefresh = false, false
    for _, b in ipairs(buttons) do
      if b.props.onClick == "onCloseClicked" then hasClose = true end
      if b.props.onClick == "onRefreshClicked" then hasRefresh = true end
    end
    check("panel header has a button whose onClick == 'onCloseClicked'", hasClose,
      "onCloseClicked", #buttons .. " button node(s)")
    check("panel header has a button whose onClick == 'onRefreshClicked'", hasRefresh,
      "onRefreshClicked", #buttons .. " button node(s)")
    check("panel header contains the title label", textsInclude(root, "TR:title"),
      "TR:title", collectTexts(root))
  end
end

-- ---------------------------------------------------------------------------
-- Panel: runAsync returning false -> error status + re-render.
-- ---------------------------------------------------------------------------
do
  loadPanel({ show_counts = true })
  state.runAsyncResult = false
  local ok = pcall(_G.onOpen, { id = "panel" })
  check("panel onOpen with runAsync=false runs without error", ok, "no error", ok)
  check("panel fetch runAsync=false sets status.query_failed",
    trKeyPresent("status.query_failed"), "tr('status.query_failed')", state.trcalls)
  check("panel fetch runAsync=false still re-renders",
    #state.renders >= 1, ">= 1 render", #state.renders)
end

do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local rendersBefore = #state.renders
  state.runAsyncResult = false
  local ok = pcall(_G.onDrop, M.wsPayload(7), M.dropValue("DP-2"))
  check("panel dispatch with runAsync=false runs without error", ok, "no error", ok)
  check("panel dispatch runAsync=false sets status.failed",
    trKeyPresent("status.failed"), "tr('status.failed')", state.trcalls)
  check("panel dispatch runAsync=false re-renders",
    #state.renders > rendersBefore, "> " .. rendersBefore, #state.renders)
end

-- ---------------------------------------------------------------------------
-- Panel: fetch query_failed path (non-zero exit / nil result) -> no model.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  local cb = state.runcalls[1].cb
  local ok = pcall(cb, { exitCode = 1 })
  check("panel fetch exitCode=1 callback runs without error", ok, "no error", ok)
  check("panel fetch exitCode=1 sets status.query_failed",
    trKeyPresent("status.query_failed"), "tr('status.query_failed')", state.trcalls)
  check("panel fetch exitCode=1 renders no model",
    lastRoot() ~= nil and #findDropZones(lastRoot()) == 0, 0,
    lastRoot() and #findDropZones(lastRoot()) or "no tree")
end

do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  local cb = state.runcalls[1].cb
  local ok = pcall(cb, nil)
  check("panel fetch nil result callback runs without error", ok, "no error", ok)
  check("panel fetch nil result sets status.query_failed",
    trKeyPresent("status.query_failed"), "tr('status.query_failed')", state.trcalls)
  check("panel fetch nil result renders no model",
    lastRoot() ~= nil and #findDropZones(lastRoot()) == 0, 0,
    lastRoot() and #findDropZones(lastRoot()) or "no tree")
end

-- ---------------------------------------------------------------------------
-- Panel: onDrop with a planMove error that is not same-monitor -> status.no_target.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = false })
  driveSnapshot(GOOD_STDOUT)
  local model = M.buildModel(MONITORS, WORKSPACES)
  local plan, err = M.planMove(model, "bogus", M.dropValue("DP-2"))
  check("precondition: malformed payload yields 'invalid-drop'",
    plan == nil and err == "invalid-drop", "nil, 'invalid-drop'",
    tostring(plan) .. ", " .. tostring(err))
  check("precondition: M.statusKey('invalid-drop') == 'status.no_target'",
    M.statusKey(err) == "status.no_target", "status.no_target", M.statusKey(err))

  local runsBefore = #state.runcalls
  local rendersBefore = #state.renders
  local ok = pcall(_G.onDrop, "bogus", M.dropValue("DP-2"))
  check("panel invalid-drop runs without error", ok, "no error", ok)
  check("panel invalid-drop runs no command", #state.runcalls == runsBefore,
    runsBefore, #state.runcalls)
  check("panel invalid-drop sets status from M.statusKey(err) (= status.no_target)",
    trKeyPresent("status.no_target"), "tr('status.no_target')", state.trcalls)
  check("panel invalid-drop re-renders", #state.renders > rendersBefore,
    "> " .. rendersBefore, #state.renders)
end

-- ---------------------------------------------------------------------------
-- Panel: onClose suppresses renders from in-flight fetch callbacks.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  local cb = state.runcalls[1].cb
  local ok = pcall(_G.onClose)
  check("panel onClose runs without error", ok, "no error", ok)
  local rendersBefore = #state.renders
  local ok2 = pcall(cb, { exitCode = 0, stdout = GOOD_STDOUT })
  check("panel fetch callback after onClose runs without error", ok2, "no error", ok2)
  check("panel fetch callback after onClose does not render",
    #state.renders == rendersBefore, rendersBefore, #state.renders)
end

-- ---------------------------------------------------------------------------
-- Panel: stdout without the separator -> error status, no model / no drop zones.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  local beforeKeys = trKeySet() -- keys from the initial (pre-fetch) render

  local ok = driveSnapshot("this stdout has no separator token")
  check("panel bad stdout callback runs without error", ok, "no error", ok)

  local root = lastRoot()
  check("panel bad stdout does not build a model (no drop zones)",
    root ~= nil and #findDropZones(root) == 0, 0,
    root and #findDropZones(root) or "no tree")

  local newKey = nil
  local afterKeys = trKeySet()
  for k in pairs(afterKeys) do if not beforeKeys[k] then newKey = k end end
  check("panel bad stdout shows an error status (new tr key)", newKey ~= nil,
    "a status tr(...) key", newKey or "none")
end

-- A refresh whose fetch output lacks the separator must not keep a stale model.
do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  check("panel good fetch precondition renders one drop zone per monitor",
    lastRoot() ~= nil and #findDropZones(lastRoot()) == #MONITORS, #MONITORS,
    lastRoot() and #findDropZones(lastRoot()) or "no tree")

  if type(_G.onRefreshClicked) == "function" then pcall(_G.onRefreshClicked) end
  local refreshCall = state.runcalls[#state.runcalls]
  check("panel refresh issues a fetch runAsync",
    refreshCall ~= nil and type(refreshCall.cb) == "function",
    "runAsync with a callback", refreshCall and type(refreshCall.cb) or "none")
  if refreshCall and type(refreshCall.cb) == "function" then
    pcall(refreshCall.cb, { exitCode = 0, stdout = "no separator on refresh" })
    local root = lastRoot()
    check("panel failed refresh does not leave stale drop zones",
      root ~= nil and #findDropZones(root) == 0, 0,
      root and #findDropZones(root) or "no tree")
  end
end

-- ---------------------------------------------------------------------------
-- Panel: no periodic tick, and refresh button refreshes.
-- ---------------------------------------------------------------------------
do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  pcall(_G.onDrop, M.wsPayload(6), M.dropValue("DP-2"))
  if type(_G.onRefreshClicked) == "function" then pcall(_G.onRefreshClicked) end
  check("panel NEVER calls panel.setWantsSecondTicks", state.secondTicks == 0,
    0, state.secondTicks)
end

do
  openPanel({ show_counts = true })
  driveSnapshot(GOOD_STDOUT)
  check("panel defines onRefreshClicked", type(_G.onRefreshClicked) == "function",
    "function", type(_G.onRefreshClicked))
  if type(_G.onRefreshClicked) == "function" then
    local n = #state.runcalls
    local ok = pcall(_G.onRefreshClicked)
    check("panel onRefreshClicked runs without error", ok, "no error", ok)
    check("panel onRefreshClicked issues exactly one runAsync", #state.runcalls == n + 1,
      n + 1, #state.runcalls)
    local call = state.runcalls[#state.runcalls]
    check("panel refresh uses the snapshot command",
      call ~= nil and call.cmd == M.snapshotCommand(), M.snapshotCommand(),
      call and call.cmd or "none")
  end
end

-- ---------------------------------------------------------------------------
-- Widget: static glyph on load; onClick toggles the panel.
-- ---------------------------------------------------------------------------
do
  state = newState({})
  _G.require = function() return M end
  local ok, err = pcall(dofile, WIDGET_PATH)
  check("widget loads without error", ok, "loads", ok and "ok" or err)

  check("widget loading sets a glyph via barWidget.setGlyph", #state.glyphs >= 1,
    ">= 1 setGlyph", state.glyphs)
  check("widget glyph is a non-empty string",
    type(state.glyphs[1]) == "string" and #state.glyphs[1] > 0,
    "non-empty string", state.glyphs[1])

  check("widget defines onClick", type(_G.onClick) == "function", "function", type(_G.onClick))
  if type(_G.onClick) == "function" then
    local ok2, err2 = pcall(_G.onClick)
    check("widget onClick runs without error", ok2, "no error", ok2 and "ok" or err2)
  end
  check("widget onClick toggles exactly one panel", #state.toggles == 1, 1, #state.toggles)
  check("widget onClick toggles 'thegalkin/workspace-dnd:panel'",
    state.toggles[1] == "thegalkin/workspace-dnd:panel",
    "thegalkin/workspace-dnd:panel", state.toggles[1])
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("TOTAL %d PASSED %d FAILED %d", total, passed, failed))
os.exit(failed == 0 and 0 or 1)
