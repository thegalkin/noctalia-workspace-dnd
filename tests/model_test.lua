-- tests/model_test.lua
-- Black-box adversarial test suite for the pure module lib/model.luau.
-- Written STRICTLY from the specification. The implementation is never read,
-- only loaded/executed as a black box via dofile().

-- Resolve paths relative to this script so the suite runs from any directory.
local function repoRoot()
  local src = (arg and arg[0]) or "."
  local dir = string.match(src, "^(.*)[/\\][^/\\]*$") or "."
  return dir .. "/.."
end

local MODULE_PATH = repoRoot() .. "/workspace-dnd/lib/model.luau"

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

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = deepCopy(val) end
  return t
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

-- Expects a (nil, non-empty-string) error return.
local function expectError(name, value, err)
  local ok = value == nil and type(err) == "string" and #err > 0
  check(name, ok, "nil + non-empty error string", { value = value, err = err })
end

local function monitorNames(model)
  local names = {}
  for _, m in ipairs(model.monitors) do names[#names + 1] = m.name end
  return names
end

local function wsIds(monitor)
  local ids = {}
  for _, w in ipairs(monitor.workspaces) do ids[#ids + 1] = w.id end
  return ids
end

-- ---------------------------------------------------------------------------
-- Load the module as a black box.
-- ---------------------------------------------------------------------------
local loadOk, M = pcall(dofile, MODULE_PATH)
check("module loads and returns a table", loadOk and type(M) == "table",
  "table", loadOk and type(M) or M)

if not (loadOk and type(M) == "table") then
  print(string.format("TOTAL %d PASSED %d FAILED %d", total, passed, failed))
  os.exit(1)
end

-- ---------------------------------------------------------------------------
-- buildModel: non-table inputs -> nil, err
-- ---------------------------------------------------------------------------
expectError("buildModel(nil, {}) returns nil+err", M.buildModel(nil, {}))
expectError("buildModel({}, nil) returns nil+err", M.buildModel({}, nil))
expectError("buildModel(nil, nil) returns nil+err", M.buildModel(nil, nil))
expectError("buildModel('x', {}) returns nil+err", M.buildModel("x", {}))
expectError("buildModel({}, 5) returns nil+err", M.buildModel({}, 5))
expectError("buildModel(true, false) returns nil+err", M.buildModel(true, false))

-- ---------------------------------------------------------------------------
-- buildModel: empty inputs -> empty-but-valid model
-- ---------------------------------------------------------------------------
do
  local model, err = M.buildModel({}, {})
  check("empty inputs return a model (not nil)",
    model ~= nil and err == nil,
    "non-nil model, nil err", { model = model, err = err })
  check("empty inputs -> model.monitors is a table",
    type(model) == "table" and type(model.monitors) == "table",
    "table", type(model) == "table" and type(model.monitors) or type(model))
  check("empty inputs -> model.monitors is empty",
    model ~= nil and model.monitors ~= nil and #model.monitors == 0,
    "length 0", model ~= nil and model.monitors ~= nil and #model.monitors or "nil")
end

-- ---------------------------------------------------------------------------
-- buildModel: happy path (geometry, ordering, attach, active, sorting, drop)
-- ---------------------------------------------------------------------------
do
  local monitors = {
    { name = "DP-2", width = 2560, height = 1440, x = 1440, y = 0, focused = true, activeWorkspace = { id = 6, name = "6" } },
    { name = "DP-1", width = 1920, height = 1080, x = 0, y = 0, focused = false, activeWorkspace = { id = 1, name = "1" } },
  }
  local workspaces = {
    { id = 6, name = "6", monitor = "DP-2", monitorID = 0, windows = 2 },
    { id = 1, name = "1", monitor = "DP-1", monitorID = 0, windows = 1 },
    { id = 9, name = "Ghost", monitor = "NOPE", windows = 4 },
  }
  local expected = {
    monitors = {
      { name = "DP-1", width = 1920, height = 1080, x = 0, y = 0, focused = false, activeId = 1,
        workspaces = { { id = 1, name = "1", windows = 1, active = true } } },
      { name = "DP-2", width = 2560, height = 1440, x = 1440, y = 0, focused = true, activeId = 6,
        workspaces = { { id = 6, name = "6", windows = 2, active = true } } },
    },
  }
  local model, err = M.buildModel(monitors, workspaces)
  expectEqual("buildModel happy path produces full model", model, expected)
  check("buildModel happy path returns nil err", err == nil, "nil", err)
end

-- ---------------------------------------------------------------------------
-- buildModel: monitor ordering by x ascending, ties by name ascending
-- ---------------------------------------------------------------------------
do
  local monitors = {
    { name = "C", x = 100 },
    { name = "B", x = 0 },
    { name = "A", x = 0 },
  }
  local model = M.buildModel(monitors, {})
  expectEqual("monitors ordered by x asc then name asc", monitorNames(model), { "A", "B", "C" })
end

-- ---------------------------------------------------------------------------
-- buildModel: special workspace exclusion (id<=0, "special:" prefix, non-numeric)
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local workspaces = {
    { id = 0, name = "zero", monitor = "M" },
    { id = -3, name = "neg", monitor = "M" },
    { id = 4, name = "special:scratch", monitor = "M" },
    { id = "special:x", name = "special:x", monitor = "M" },
    { id = "abc", name = "notnumeric", monitor = "M" },
    { id = "", name = "emptystr", monitor = "M" },
    { name = "noid", monitor = "M" },
    { id = 2, name = "ok", monitor = "M" },
  }
  local model = M.buildModel(monitors, workspaces)
  expectEqual("special workspaces (id<=0, special:, non-numeric) excluded",
    wsIds(model.monitors[1]), { 2 })
end

-- ---------------------------------------------------------------------------
-- buildModel: numeric-string id handling (converted to number)
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M", activeWorkspace = { id = 6 } } }
  local workspaces = { { id = "6", monitor = "M", windows = 0 } }
  local model = M.buildModel(monitors, workspaces)
  local ws = model.monitors[1].workspaces[1]
  check("numeric-string id is converted to a number",
    ws ~= nil and type(ws.id) == "number",
    "number", ws ~= nil and type(ws.id) or "no workspace")
  expectEqual("numeric-string id keeps numeric value",
    ws ~= nil and ws.id or nil, 6)
  check("numeric-string id matches activeId",
    ws ~= nil and ws.active == true,
    "true", ws ~= nil and ws.active or "no workspace")
end

-- ---------------------------------------------------------------------------
-- buildModel: missing numeric geometry fields default to 0
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local model = M.buildModel(monitors, {})
  local m = model.monitors[1]
  expectEqual("missing geometry fields default to 0",
    m and { width = m.width, height = m.height, x = m.x, y = m.y },
    { width = 0, height = 0, x = 0, y = 0 })
end

-- ---------------------------------------------------------------------------
-- buildModel: focused defaults to false; explicit value preserved
-- ---------------------------------------------------------------------------
do
  local model = M.buildModel({ { name = "M" } }, {})
  check("focused defaults to false",
    model.monitors[1].focused == false,
    "false", model.monitors[1].focused)
end
do
  local model = M.buildModel({ { name = "M", focused = true } }, {})
  check("explicit focused = true preserved",
    model.monitors[1].focused == true,
    "true", model.monitors[1].focused)
end

-- ---------------------------------------------------------------------------
-- buildModel: activeId from activeWorkspace.id, else nil
-- ---------------------------------------------------------------------------
do
  local model = M.buildModel({ { name = "M", activeWorkspace = { id = 42 } } }, {})
  expectEqual("activeId taken from activeWorkspace.id", model.monitors[1].activeId, 42)
end
do
  local model = M.buildModel({ { name = "M" } }, {})
  expectEqual("activeId is nil when activeWorkspace absent", model.monitors[1].activeId, nil)
end
do
  local model = M.buildModel({ { name = "M", activeWorkspace = {} } }, {})
  expectEqual("activeId is nil when activeWorkspace has no id", model.monitors[1].activeId, nil)
end

-- ---------------------------------------------------------------------------
-- buildModel: workspaces sorted by id ascending within a monitor
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local workspaces = {
    { id = 5, name = "5", monitor = "M" },
    { id = 1, name = "1", monitor = "M" },
    { id = 3, name = "3", monitor = "M" },
  }
  local model = M.buildModel(monitors, workspaces)
  expectEqual("workspaces sorted by id ascending", wsIds(model.monitors[1]), { 1, 3, 5 })
end

-- ---------------------------------------------------------------------------
-- buildModel: workspace with unknown monitor (or none) dropped, not an error
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local workspaces = {
    { id = 1, name = "1", monitor = "GHOST" },
    { id = 2, name = "2" },
    { id = 3, name = "3", monitor = "M" },
  }
  local model, err = M.buildModel(monitors, workspaces)
  check("unknown-monitor workspace dropped without error",
    err == nil, "nil err", err)
  expectEqual("only matching-monitor workspace attached", wsIds(model.monitors[1]), { 3 })
end

-- ---------------------------------------------------------------------------
-- buildModel: name defaults to tostring(id)
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local workspaces = { { id = 7, monitor = "M" } }
  local model = M.buildModel(monitors, workspaces)
  expectEqual("workspace name defaults to tostring(id)", model.monitors[1].workspaces[1].name, "7")
end

-- ---------------------------------------------------------------------------
-- buildModel: windows defaults to 0
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M" } }
  local workspaces = { { id = 2, name = "2", monitor = "M" } }
  local model = M.buildModel(monitors, workspaces)
  expectEqual("windows defaults to 0", model.monitors[1].workspaces[1].windows, 0)
end

-- ---------------------------------------------------------------------------
-- buildModel: active flag = (id == monitor.activeId)
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M", activeWorkspace = { id = 6 } } }
  local workspaces = {
    { id = 6, name = "6", monitor = "M" },
    { id = 7, name = "7", monitor = "M" },
  }
  local model = M.buildModel(monitors, workspaces)
  local byId = {}
  for _, w in ipairs(model.monitors[1].workspaces) do byId[w.id] = w.active end
  check("active workspace flagged true", byId[6] == true, "true", byId[6])
  check("non-active workspace flagged false", byId[7] == false, "false", byId[7])
end

-- ---------------------------------------------------------------------------
-- buildModel: monitor kept only if name is non-empty string
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "" }, { name = 123 }, {}, { name = "Ok" } }
  local model = M.buildModel(monitors, {})
  expectEqual("monitors without non-empty string name dropped",
    monitorNames(model), { "Ok" })
end

-- ---------------------------------------------------------------------------
-- buildModel: does not mutate its inputs (pure transform)
-- ---------------------------------------------------------------------------
do
  local monitors = { { name = "M", activeWorkspace = { id = 1 } } }
  local workspaces = { { id = 1, name = "1", monitor = "M" } }
  local mc, wc = deepCopy(monitors), deepCopy(workspaces)
  M.buildModel(monitors, workspaces)
  check("buildModel does not mutate monitors input", deepEqual(monitors, mc), mc, monitors)
  check("buildModel does not mutate workspaces input", deepEqual(workspaces, wc), wc, workspaces)
end

-- ---------------------------------------------------------------------------
-- dropValue / parseDropValue
-- ---------------------------------------------------------------------------
expectEqual("dropValue formats mon:<name>", M.dropValue("DP-2"), "mon:DP-2")
expectEqual("dropValue of simple name", M.dropValue("M"), "mon:M")
expectEqual("parseDropValue round-trips dropValue", M.parseDropValue(M.dropValue("Some Monitor")), "Some Monitor")
expectEqual("parseDropValue('ws:5') rejected", M.parseDropValue("ws:5"), nil)
expectEqual("parseDropValue('DP-2') rejected", M.parseDropValue("DP-2"), nil)
expectEqual("parseDropValue('mon:') empty name rejected", M.parseDropValue("mon:"), nil)
expectEqual("parseDropValue('mon') no-colon rejected", M.parseDropValue("mon"), nil)
expectEqual("parseDropValue(5) non-string rejected", M.parseDropValue(5), nil)
expectEqual("parseDropValue(nil) rejected", M.parseDropValue(nil), nil)

-- ---------------------------------------------------------------------------
-- wsPayload / parseWsPayload
-- ---------------------------------------------------------------------------
expectEqual("wsPayload formats ws:<id>", M.wsPayload(6), "ws:6")
expectEqual("wsPayload large id", M.wsPayload(1234), "ws:1234")
expectEqual("parseWsPayload round-trips wsPayload", M.parseWsPayload(M.wsPayload(42)), 42)
expectEqual("parseWsPayload('ws:6') -> 6", M.parseWsPayload("ws:6"), 6)
expectEqual("parseWsPayload('mon:6') rejected", M.parseWsPayload("mon:6"), nil)
expectEqual("parseWsPayload('ws:abc') non-numeric rejected", M.parseWsPayload("ws:abc"), nil)
expectEqual("parseWsPayload('ws:') empty remainder rejected", M.parseWsPayload("ws:"), nil)
expectEqual("parseWsPayload('6') no-prefix rejected", M.parseWsPayload("6"), nil)
expectEqual("parseWsPayload(6) non-string rejected", M.parseWsPayload(6), nil)
expectEqual("parseWsPayload(nil) rejected", M.parseWsPayload(nil), nil)

-- ---------------------------------------------------------------------------
-- planMove: hand-crafted model (isolates planMove from buildModel)
-- ---------------------------------------------------------------------------
local pModel = {
  monitors = {
    { name = "DP-1", width = 1920, height = 1080, x = 0, y = 0, focused = true, activeId = 1,
      workspaces = {
        { id = 1, name = "1", windows = 0, active = true },
        { id = 7, name = "Code", windows = 3, active = false },
      } },
    { name = "DP-2", width = 2560, height = 1440, x = 1440, y = 0, focused = false, activeId = 6,
      workspaces = {
        { id = 6, name = "6", windows = 2, active = true },
      } },
  },
}

-- happy path: move workspace 7 from DP-1 to DP-2
do
  local plan, err = M.planMove(pModel, M.wsPayload(7), M.dropValue("DP-2"))
  expectEqual("planMove happy path returns plan with display name",
    plan, { workspace = 7, monitor = "DP-2", name = "Code" })
  check("planMove happy path returns nil err", err == nil, "nil", err)
end

-- happy path: move workspace 6 from DP-2 to DP-1
do
  local plan, err = M.planMove(pModel, M.wsPayload(6), M.dropValue("DP-1"))
  expectEqual("planMove happy path (second direction)",
    plan, { workspace = 6, monitor = "DP-1", name = "6" })
  check("planMove second direction nil err", err == nil, "nil", err)
end

-- error: malformed payload / value
expectError("planMove malformed payload -> invalid-drop",
  M.planMove(pModel, "garbage", M.dropValue("DP-1")))
expectError("planMove malformed value -> invalid-drop",
  M.planMove(pModel, M.wsPayload(7), "garbage"))
expectError("planMove non-'ws:' payload -> invalid-drop",
  M.planMove(pModel, M.dropValue("DP-1"), M.dropValue("DP-1")))
expectError("planMove non-'mon:' value -> invalid-drop",
  M.planMove(pModel, M.wsPayload(7), M.wsPayload(7)))
expectError("planMove nil payload -> invalid-drop",
  M.planMove(pModel, nil, M.dropValue("DP-1")))
expectError("planMove nil value -> invalid-drop",
  M.planMove(pModel, M.wsPayload(7), nil))

-- error: unknown workspace
expectError("planMove unknown workspace -> unknown-workspace",
  M.planMove(pModel, M.wsPayload(999), M.dropValue("DP-1")))

-- error: unknown monitor
expectError("planMove unknown monitor -> unknown-monitor",
  M.planMove(pModel, M.wsPayload(7), M.dropValue("GHOST")))

-- error: already on target monitor
expectError("planMove same monitor -> same-monitor",
  M.planMove(pModel, M.wsPayload(6), M.dropValue("DP-2")))

-- distinct error strings (not all the same)
do
  local _, e1 = M.planMove(pModel, "bad", M.dropValue("DP-1"))
  local _, e2 = M.planMove(pModel, M.wsPayload(999), M.dropValue("DP-1"))
  local _, e3 = M.planMove(pModel, M.wsPayload(7), M.dropValue("GHOST"))
  local _, e4 = M.planMove(pModel, M.wsPayload(6), M.dropValue("DP-2"))
  check("planMove uses distinct error codes",
    e1 == "invalid-drop" and e2 == "unknown-workspace" and e3 == "unknown-monitor" and e4 == "same-monitor",
    '"invalid-drop","unknown-workspace","unknown-monitor","same-monitor"',
    { e1, e2, e3, e4 })
end

-- side-effect free: does not mutate model (success + each error path)
do
  local before = deepCopy(pModel)
  M.planMove(pModel, M.wsPayload(7), M.dropValue("DP-2"))
  check("planMove (success) does not mutate model", deepEqual(pModel, before), before, pModel)
end
do
  local before = deepCopy(pModel)
  M.planMove(pModel, M.wsPayload(6), M.dropValue("DP-2")) -- same-monitor
  check("planMove (same-monitor) does not mutate model", deepEqual(pModel, before), before, pModel)
end
do
  local before = deepCopy(pModel)
  M.planMove(pModel, "bad", "bad") -- invalid-drop
  check("planMove (invalid-drop) does not mutate model", deepEqual(pModel, before), before, pModel)
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("TOTAL %d PASSED %d FAILED %d", total, passed, failed))
os.exit(failed == 0 and 0 or 1)
