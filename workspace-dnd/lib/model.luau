--!nonstrict
-- Pure data/logic for the Workspace DnD plugin.
--
-- Deliberately written in a Lua-5.1-compatible subset (no Luau-only syntax) so a
-- plain Lua interpreter can exercise it in tests. It performs no I/O and touches
-- no Noctalia globals.
--
-- See ../../SPEC.md for the contract.

local M = {}

-- Literal separator the panel puts between the two hyprctl snapshots.
M.SEP = "__WSDND__"

local function toNumber(v)
  if type(v) == "number" then
    return v
  end
  if type(v) == "string" then
    return tonumber(v)
  end
  return nil
end

local function isSpecial(ws)
  if type(ws) ~= "table" then
    return true
  end
  local id = toNumber(ws.id)
  if id == nil or id <= 0 then
    return true
  end
  local name = ws.name
  if type(name) == "string" and string.sub(name, 1, 8) == "special:" then
    return true
  end
  return false
end

-- Builds the renderable model from decoded hyprctl snapshots.
function M.buildModel(monitors, workspaces)
  if type(monitors) ~= "table" then
    return nil, "monitors: expected a list"
  end
  if type(workspaces) ~= "table" then
    return nil, "workspaces: expected a list"
  end

  local model = { monitors = {} }
  local byName = {}

  for _, raw in ipairs(monitors) do
    if type(raw) == "table" and type(raw.name) == "string" and raw.name ~= "" then
      local activeWorkspace = raw.activeWorkspace
      local activeId = nil
      if type(activeWorkspace) == "table" then
        activeId = toNumber(activeWorkspace.id)
      end
      local mon = {
        name = raw.name,
        width = toNumber(raw.width) or 0,
        height = toNumber(raw.height) or 0,
        x = toNumber(raw.x) or 0,
        y = toNumber(raw.y) or 0,
        focused = raw.focused == true,
        activeId = activeId,
        workspaces = {},
      }
      table.insert(model.monitors, mon)
      byName[mon.name] = mon
    end
  end

  table.sort(model.monitors, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.name < b.name
  end)

  for _, raw in ipairs(workspaces) do
    if not isSpecial(raw) then
      local monName = raw.monitor
      local mon = nil
      if type(monName) == "string" then
        mon = byName[monName]
      end
      if mon ~= nil then
        local id = toNumber(raw.id)
        local displayName = raw.name
        if type(displayName) ~= "string" then
          displayName = tostring(id)
        end
        table.insert(mon.workspaces, {
          id = id,
          name = displayName,
          windows = toNumber(raw.windows) or 0,
          active = mon.activeId ~= nil and id == mon.activeId,
        })
      end
    end
  end

  for _, mon in ipairs(model.monitors) do
    table.sort(mon.workspaces, function(a, b)
      return a.id < b.id
    end)
  end

  return model
end

function M.dropValue(monitorName)
  return "mon:" .. tostring(monitorName)
end

function M.parseDropValue(value)
  if type(value) ~= "string" then
    return nil
  end
  if string.sub(value, 1, 4) ~= "mon:" then
    return nil
  end
  local name = string.sub(value, 5)
  if name == "" then
    return nil
  end
  return name
end

function M.wsPayload(wsId)
  return "ws:" .. tostring(wsId)
end

function M.parseWsPayload(payload)
  if type(payload) ~= "string" then
    return nil
  end
  if string.sub(payload, 1, 3) ~= "ws:" then
    return nil
  end
  return tonumber(string.sub(payload, 4))
end

-- Locates a workspace in the model. Returns the monitor table, the workspace
-- table, or nil.
local function locate(model, wsId)
  if type(model) ~= "table" or type(model.monitors) ~= "table" then
    return nil, nil
  end
  for _, mon in ipairs(model.monitors) do
    for _, ws in ipairs(mon.workspaces) do
      if ws.id == wsId then
        return mon, ws
      end
    end
  end
  return nil, nil
end

local function findMonitor(model, name)
  if type(model) ~= "table" or type(model.monitors) ~= "table" then
    return nil
  end
  for _, mon in ipairs(model.monitors) do
    if mon.name == name then
      return mon
    end
  end
  return nil
end

function M.planMove(model, payload, value)
  local wsId = M.parseWsPayload(payload)
  local monName = M.parseDropValue(value)
  if wsId == nil or monName == nil then
    return nil, "invalid-drop"
  end

  local target = findMonitor(model, monName)
  if target == nil then
    return nil, "unknown-monitor"
  end

  local current, ws = locate(model, wsId)
  if current == nil then
    return nil, "unknown-workspace"
  end

  if current.name == monName then
    return nil, "same-monitor"
  end

  return {
    workspace = wsId,
    monitor = monName,
    name = ws.name,
  }
end

-- Single shell round-trip that snapshots both hyprctl outputs, separated by a
-- line containing exactly M.SEP.
function M.snapshotCommand()
  return "printf '%s\\n" .. M.SEP .. "\\n%s\\n' \"$(hyprctl -j monitors)\" \"$(hyprctl -j workspaces)\""
end

-- Splits snapshotCommand()'s stdout into (monitorsJson, workspacesJson).
function M.splitSnapshot(stdout)
  if type(stdout) ~= "string" then
    return nil, "no-separator"
  end
  local needle = "\n" .. M.SEP .. "\n"
  local at, stop = string.find(stdout, needle, 1, true)
  if at == nil then
    return nil, "no-separator"
  end
  return string.sub(stdout, 1, at - 1), string.sub(stdout, stop + 1)
end

-- Human label for a workspace row, e.g. "#2  ·5".
function M.describeWorkspace(ws, showCounts)
  if type(ws) ~= "table" then
    return ""
  end
  local label = "#" .. tostring(ws.id)
  local windows = ws.windows
  if showCounts and type(windows) == "number" and windows > 0 then
    label = label .. "  ·" .. tostring(windows)
  end
  return label
end

-- Escapes the inside of a double-quoted Lua string literal.
function M.escapeLuaString(value)
  local s = tostring(value)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  s = string.gsub(s, "\r", "\\r")
  return s
end

-- Argument-array form for the move. This Hyprland build runs a Lua config, so
-- legacy dispatchers are dead: `hyprctl dispatch moveworkspacetomonitor ...` is
-- rewritten to `return hl.dispatch(moveworkspacetomonitor ...)` and fails to
-- parse. The Lua dispatcher form is the only one that works:
--   hl.dsp.workspace.move({ workspace = 2, monitor = "DP-2" })
function M.buildDispatchArgs(plan)
  if type(plan) ~= "table" then
    return nil
  end
  local ws = toNumber(plan.workspace)
  if ws == nil then
    return nil
  end
  if type(plan.monitor) ~= "string" or plan.monitor == "" then
    return nil
  end
  local expr = "hl.dsp.workspace.move({ workspace = " .. tostring(ws) .. ", monitor = \"" .. M.escapeLuaString(plan.monitor) .. "\" })"
  return { "hyprctl", "dispatch", expr }
end

-- `hyprctl` reports dispatch failures on stdout as "warning: ..." and still
-- exits 0, so the exit code alone is not enough. Returns a detail string when
-- the move failed, or nil on success.
function M.dispatchFailure(result)
  if result == nil then
    return "no result"
  end
  local out = ""
  if type(result.stdout) == "string" then
    out = out .. result.stdout
  end
  if type(result.stderr) == "string" then
    out = out .. result.stderr
  end
  local lower = string.lower(out)
  if string.find(lower, "warning:", 1, true) ~= nil or string.find(lower, "error", 1, true) ~= nil then
    return out
  end
  if toNumber(result.exitCode) ~= nil and toNumber(result.exitCode) ~= 0 then
    if out ~= "" then
      return out
    end
    return "exit code " .. tostring(result.exitCode)
  end
  return nil
end

-- Translation key for a planMove error code.
function M.statusKey(err)
  if err == "same-monitor" then
    return "status.same_monitor"
  end
  return "status.no_target"
end

return M
