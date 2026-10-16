-- tests/model_extra_test.lua
-- Black-box adversarial tests for the NEW pure functions of lib/model.luau
-- (round 2, supplementary spec):
--   M.SEP, M.snapshotCommand, M.splitSnapshot, M.describeWorkspace,
--   M.buildDispatchArgs, M.statusKey.
-- Written STRICTLY from the specification. The implementation is never read,
-- only executed as a black box via dofile().

-- Resolve paths relative to this script so the suite runs from any directory.
local function repoRoot()
  local src = (arg and arg[0]) or "."
  local dir = string.match(src, "^(.*)[/\\][^/\\]*$") or "."
  return dir .. "/.."
end

local MODULE_PATH = repoRoot() .. "/workspace-dnd/lib/model.luau"

local DOT = "\194\183" -- U+00B7 MIDDLE DOT, as used by the spec suffix "  ·"
local SUFFIX_PREFIX = "  " .. DOT

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

local function expectError(name, value, err, expectedErr)
  local ok = value == nil and type(err) == "string" and #err > 0
  if expectedErr ~= nil then ok = ok and err == expectedErr end
  local want = expectedErr and ("nil + \"" .. expectedErr .. "\"") or "nil + non-empty error string"
  check(name, ok, want, { value = value, err = err })
end

local function contains(haystack, needle)
  return type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil
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
-- M.SEP
-- ---------------------------------------------------------------------------
expectEqual("M.SEP is exactly __WSDND__", M.SEP, "__WSDND__")
check("M.SEP is a string", type(M.SEP) == "string", "string", type(M.SEP))

-- ---------------------------------------------------------------------------
-- M.snapshotCommand()
-- ---------------------------------------------------------------------------
do
  local cmd = M.snapshotCommand()
  check("snapshotCommand returns a string", type(cmd) == "string", "string", type(cmd))
  check("snapshotCommand is non-empty", type(cmd) == "string" and #cmd > 0, "non-empty", cmd)
  check("snapshotCommand contains 'hyprctl -j monitors'", contains(cmd, "hyprctl -j monitors"),
    "contains 'hyprctl -j monitors'", cmd)
  check("snapshotCommand contains 'hyprctl -j workspaces'", contains(cmd, "hyprctl -j workspaces"),
    "contains 'hyprctl -j workspaces'", cmd)
  check("snapshotCommand contains the SEP token", contains(cmd, M.SEP),
    "contains " .. ser(M.SEP), cmd)
end

-- ---------------------------------------------------------------------------
-- M.splitSnapshot — bad inputs
-- ---------------------------------------------------------------------------
expectError("splitSnapshot(nil) -> no-separator", M.splitSnapshot(nil), "no-separator")
expectError("splitSnapshot(5) -> no-separator", M.splitSnapshot(5), "no-separator")
expectError("splitSnapshot(true) -> no-separator", M.splitSnapshot(true), "no-separator")
expectError("splitSnapshot({}) -> no-separator", M.splitSnapshot({}), "no-separator")
expectError("splitSnapshot('no separator at all') -> no-separator",
  M.splitSnapshot("no separator at all"), "no-separator")
expectError("splitSnapshot(SEP without newlines) -> no-separator",
  M.splitSnapshot("A" .. M.SEP .. "B"), "no-separator")
expectError("splitSnapshot(SEP followed by newline only) -> no-separator",
  M.splitSnapshot(M.SEP .. "\nB"), "no-separator")
expectError("splitSnapshot(SEP preceded by newline only) -> no-separator",
  M.splitSnapshot("A\n" .. M.SEP), "no-separator")

-- ---------------------------------------------------------------------------
-- M.splitSnapshot — happy path
-- ---------------------------------------------------------------------------
do
  local a, b = M.splitSnapshot("AAA\n" .. M.SEP .. "\nBBB")
  expectEqual("splitSnapshot basic first half", a, "AAA")
  expectEqual("splitSnapshot basic second half", b, "BBB")
end

do
  -- first half excludes the separator line; second half is everything after it.
  local mon = "line1\nline2"
  local wks = "rest1\nrest2"
  local a, b = M.splitSnapshot(mon .. "\n" .. M.SEP .. "\n" .. wks)
  expectEqual("splitSnapshot keeps multi-line first half", a, mon)
  expectEqual("splitSnapshot keeps multi-line second half", b, wks)
end

do
  -- only the FIRST occurrence matters.
  local a, b = M.splitSnapshot("A\n" .. M.SEP .. "\nB\n" .. M.SEP .. "\nC")
  expectEqual("splitSnapshot splits on first occurrence (first)", a, "A")
  expectEqual("splitSnapshot splits on first occurrence (rest)", b, "B\n" .. M.SEP .. "\nC")
end

do
  local a, b = M.splitSnapshot("\n" .. M.SEP .. "\nB")
  expectEqual("splitSnapshot empty first half allowed", a, "")
  expectEqual("splitSnapshot second half after empty first", b, "B")
end

do
  local a, b = M.splitSnapshot("A\n" .. M.SEP .. "\n")
  expectEqual("splitSnapshot first half before empty second", a, "A")
  expectEqual("splitSnapshot empty second half allowed", b, "")
end

do
  local a, b = M.splitSnapshot("\n" .. M.SEP .. "\n")
  expectEqual("splitSnapshot both halves empty (first)", a, "")
  expectEqual("splitSnapshot both halves empty (second)", b, "")
end

-- round-trip with the command's promised shape
do
  local mon = '{"m":1}'
  local wks = '{"w":2}'
  local a, b = M.splitSnapshot(mon .. "\n" .. M.SEP .. "\n" .. wks)
  expectEqual("splitSnapshot round-trips monitors json", a, mon)
  expectEqual("splitSnapshot round-trips workspaces json", b, wks)
end

-- ---------------------------------------------------------------------------
-- M.describeWorkspace
-- ---------------------------------------------------------------------------
expectEqual("describeWorkspace counts shown when truthy and windows>0",
  M.describeWorkspace({ id = 6, windows = 2 }, true), "#6" .. SUFFIX_PREFIX .. "2")
expectEqual("describeWorkspace counts shown with windows = 1",
  M.describeWorkspace({ id = 7, windows = 1 }, true), "#7" .. SUFFIX_PREFIX .. "1")
expectEqual("describeWorkspace counts shown with large count",
  M.describeWorkspace({ id = 3, windows = 12 }, true), "#3" .. SUFFIX_PREFIX .. "12")
expectEqual("describeWorkspace no suffix when showCounts = false",
  M.describeWorkspace({ id = 6, windows = 2 }, false), "#6")
expectEqual("describeWorkspace no suffix when showCounts = nil",
  M.describeWorkspace({ id = 6, windows = 2 }, nil), "#6")
expectEqual("describeWorkspace no suffix when windows = 0",
  M.describeWorkspace({ id = 6, windows = 0 }, true), "#6")
expectEqual("describeWorkspace no suffix when windows missing",
  M.describeWorkspace({ id = 6 }, true), "#6")
expectEqual("describeWorkspace no suffix when windows is a string",
  M.describeWorkspace({ id = 6, windows = "3" }, true), "#6")
expectEqual("describeWorkspace no suffix when windows negative",
  M.describeWorkspace({ id = 6, windows = -1 }, true), "#6")
expectEqual("describeWorkspace showCounts numeric 0 is truthy in Lua -> shows",
  M.describeWorkspace({ id = 6, windows = 2 }, 0), "#6" .. SUFFIX_PREFIX .. "2")
expectEqual("describeWorkspace showCounts truthy non-boolean (1) still shows",
  M.describeWorkspace({ id = 6, windows = 2 }, 1), "#6" .. SUFFIX_PREFIX .. "2")
expectEqual("describeWorkspace base uses tostring(id) for numeric-string id",
  M.describeWorkspace({ id = "7", windows = 0 }, true), "#7")
expectEqual("describeWorkspace negative id base",
  M.describeWorkspace({ id = -3, windows = 0 }, true), "#-3")

-- ---------------------------------------------------------------------------
-- M.escapeLuaString  (new)
-- ---------------------------------------------------------------------------
local BS = "\\"  -- a single backslash character
local QT = '"'
local NL = "\n"
local CR = "\r"

do
  expectEqual("escapeLuaString plain passes through", M.escapeLuaString("abc"), "abc")
  expectEqual("escapeLuaString empty string", M.escapeLuaString(""), "")

  expectEqual("escapeLuaString escapes a double quote",
    M.escapeLuaString("a" .. QT .. "b"), "a" .. BS .. QT .. "b")
  expectEqual("escapeLuaString escapes a backslash",
    M.escapeLuaString("a" .. BS .. "b"), "a" .. BS .. BS .. "b")
  expectEqual("escapeLuaString escapes LF to \\n",
    M.escapeLuaString("a" .. NL .. "b"), "a" .. BS .. "nb")
  expectEqual("escapeLuaString escapes CR to \\r",
    M.escapeLuaString("a" .. CR .. "b"), "a" .. BS .. "rb")

  -- order matters: escape the backslash BEFORE the quote, so an input
  -- backslash+quote becomes three backslashes + quote (\\\")
  expectEqual("escapeLuaString backslashes before quoting (\\ then \")",
    M.escapeLuaString(BS .. QT), BS .. BS .. BS .. QT)

  -- non-string inputs are tostring()ed first
  expectEqual("escapeLuaString(5) -> '5'", M.escapeLuaString(5), "5")
  expectEqual("escapeLuaString(true) -> 'true'", M.escapeLuaString(true), "true")
  expectEqual("escapeLuaString(nil) -> 'nil'", M.escapeLuaString(nil), "nil")
  check("escapeLuaString always returns a string",
    type(M.escapeLuaString(5)) == "string" and type(M.escapeLuaString(nil)) == "string",
    "string", { type(M.escapeLuaString(5)), type(M.escapeLuaString(nil)) })
  check("escapeLuaString(table) returns a string",
    type(M.escapeLuaString({})) == "string", "string", type(M.escapeLuaString({})))

  -- the result must be safe to embed inside a Lua double-quoted string literal:
  -- no raw LF/CR, and re-parsing the literal yields the original value.
  local samples = {
    "plain",
    "q" .. QT .. "uote",
    BS .. "back",
    "line" .. NL .. "break",
    "car" .. CR .. "return",
    "mix" .. BS .. NL .. " " .. QT .. CR,
    "trailing" .. BS,
    NL,
    "",
  }
  for i, s in ipairs(samples) do
    local esc = M.escapeLuaString(s)
    check("escapeLuaString sample " .. i .. " has no raw LF",
      not string.find(esc, NL, 1, true), "no LF", esc)
    check("escapeLuaString sample " .. i .. " has no raw CR",
      not string.find(esc, CR, 1, true), "no CR", esc)
    local chunk = loadstring('return "' .. esc .. '"')
    local back = chunk and chunk()
    check("escapeLuaString sample " .. i .. " round-trips through a Lua literal",
      back == s, s, back)
  end
end

-- ---------------------------------------------------------------------------
-- M.buildDispatchArgs  (3-element Lua-dispatcher expression contract)
-- ---------------------------------------------------------------------------
local function dispatchExpr(id, escapedMonitor)
  return 'hl.dsp.workspace.move({ workspace = ' .. tostring(id) ..
    ', monitor = "' .. escapedMonitor .. '" })'
end

do
  local argv = M.buildDispatchArgs({ workspace = 6, monitor = "DP-2" })
  expectEqual("buildDispatchArgs exact 3-element array",
    argv, { "hyprctl", "dispatch", dispatchExpr(6, "DP-2") })
  check("buildDispatchArgs returns a table (never a shell string)",
    type(argv) == "table", "table", type(argv))
  check("buildDispatchArgs has exactly 3 elements",
    type(argv) == "table" and #argv == 3, 3, type(argv) == "table" and #argv or "n/a")
  if type(argv) == "table" then
    local allStrings = true
    for i = 1, #argv do
      if type(argv[i]) ~= "string" then allStrings = false end
    end
    check("buildDispatchArgs elements are all strings", allStrings, "all strings", argv)
  end
end

do
  local argv = M.buildDispatchArgs({ workspace = 0, monitor = "M" })
  expectEqual("buildDispatchArgs workspace 0",
    argv, { "hyprctl", "dispatch", dispatchExpr(0, "M") })
end

do
  local argv = M.buildDispatchArgs({ workspace = "7", monitor = "DP-1" })
  expectEqual("buildDispatchArgs renders the numeric form of a numeric-string workspace",
    argv, { "hyprctl", "dispatch", dispatchExpr(7, "DP-1") })
end

do
  local argv = M.buildDispatchArgs({ workspace = 12, monitor = "HDMI-A-1", name = "ignored" })
  expectEqual("buildDispatchArgs ignores extra plan fields",
    argv, { "hyprctl", "dispatch", dispatchExpr(12, "HDMI-A-1") })
end

-- monitor is escaped inside the expression
do
  local argv = M.buildDispatchArgs({ workspace = 2, monitor = 'a"b' })
  expectEqual("buildDispatchArgs escapes a quote in the monitor",
    argv, { "hyprctl", "dispatch", dispatchExpr(2, "a" .. BS .. QT .. "b") })
end
do
  local argv = M.buildDispatchArgs({ workspace = 2, monitor = "a" .. BS .. "b" })
  expectEqual("buildDispatchArgs escapes a backslash in the monitor",
    argv, { "hyprctl", "dispatch", dispatchExpr(2, "a" .. BS .. BS .. "b") })
end
do
  local argv = M.buildDispatchArgs({ workspace = 2, monitor = "a" .. NL .. "b" })
  expectEqual("buildDispatchArgs escapes LF in the monitor",
    argv, { "hyprctl", "dispatch", dispatchExpr(2, "a" .. BS .. "nb") })
end
do
  local argv = M.buildDispatchArgs({ workspace = 2, monitor = "a" .. CR .. "b" })
  expectEqual("buildDispatchArgs escapes CR in the monitor",
    argv, { "hyprctl", "dispatch", dispatchExpr(2, "a" .. BS .. "rb") })
end

expectEqual("buildDispatchArgs(nil) -> nil", M.buildDispatchArgs(nil), nil)
expectEqual("buildDispatchArgs(5) non-table -> nil", M.buildDispatchArgs(5), nil)
expectEqual("buildDispatchArgs('x') non-table -> nil", M.buildDispatchArgs("x"), nil)
expectEqual("buildDispatchArgs(true) non-table -> nil", M.buildDispatchArgs(true), nil)
expectEqual("buildDispatchArgs with nil workspace -> nil",
  M.buildDispatchArgs({ monitor = "DP-1" }), nil)
expectEqual("buildDispatchArgs with non-numeric workspace -> nil",
  M.buildDispatchArgs({ workspace = "abc", monitor = "DP-1" }), nil)
expectEqual("buildDispatchArgs with boolean workspace -> nil",
  M.buildDispatchArgs({ workspace = false, monitor = "DP-1" }), nil)
expectEqual("buildDispatchArgs with table workspace -> nil",
  M.buildDispatchArgs({ workspace = {}, monitor = "DP-1" }), nil)
expectEqual("buildDispatchArgs with nil monitor -> nil",
  M.buildDispatchArgs({ workspace = 6 }), nil)
expectEqual("buildDispatchArgs with empty monitor -> nil",
  M.buildDispatchArgs({ workspace = 6, monitor = "" }), nil)
expectEqual("buildDispatchArgs with non-string monitor -> nil",
  M.buildDispatchArgs({ workspace = 6, monitor = 5 }), nil)
expectEqual("buildDispatchArgs with table monitor -> nil",
  M.buildDispatchArgs({ workspace = 6, monitor = {} }), nil)
expectEqual("buildDispatchArgs with boolean monitor -> nil",
  M.buildDispatchArgs({ workspace = 6, monitor = false }), nil)
expectEqual("buildDispatchArgs({}) empty -> nil", M.buildDispatchArgs({}), nil)

-- ---------------------------------------------------------------------------
-- M.dispatchFailure  (new)
-- ---------------------------------------------------------------------------
expectEqual("dispatchFailure(nil) -> 'no result'", M.dispatchFailure(nil), "no result")

-- success paths -> nil
expectEqual("dispatchFailure exit 0 empty output -> nil",
  M.dispatchFailure({ exitCode = 0, stdout = "", stderr = "" }), nil)
expectEqual("dispatchFailure exit 0 clean output -> nil",
  M.dispatchFailure({ exitCode = 0, stdout = "Workspaces:\n 1 2 3\n", stderr = "" }), nil)
expectEqual("dispatchFailure exit 0 missing fields -> nil",
  M.dispatchFailure({ exitCode = 0 }), nil)
expectEqual("dispatchFailure exitCode '0' string -> nil",
  M.dispatchFailure({ exitCode = "0", stdout = "ok" }), nil)
expectEqual("dispatchFailure non-numeric exitCode -> nil",
  M.dispatchFailure({ exitCode = "abc", stdout = "clean" }), nil)
expectEqual("dispatchFailure nil exitCode -> nil",
  M.dispatchFailure({ exitCode = nil, stdout = "clean" }), nil)
expectEqual("dispatchFailure boolean exitCode -> nil",
  M.dispatchFailure({ exitCode = true, stdout = "clean" }), nil)
expectEqual("dispatchFailure empty result table -> nil", M.dispatchFailure({}), nil)

-- warning:/error detection (even when exit code is 0)
expectEqual("dispatchFailure 'warning:' on stdout (exit 0) -> out",
  M.dispatchFailure({ exitCode = 0, stdout = "warning: nope" }), "warning: nope")
expectEqual("dispatchFailure WARNING is case-insensitive",
  M.dispatchFailure({ exitCode = 0, stdout = "WARNING: bad" }), "WARNING: bad")
expectEqual("dispatchFailure 'error' substring -> out",
  M.dispatchFailure({ exitCode = 0, stdout = "some error here" }), "some error here")
expectEqual("dispatchFailure 'error' needs no colon",
  M.dispatchFailure({ exitCode = 0, stdout = "errors happened" }), "errors happened")
expectEqual("dispatchFailure 'Error' case-insensitive",
  M.dispatchFailure({ exitCode = 0, stdout = "Error: boom" }), "Error: boom")
expectEqual("dispatchFailure warning beats the exit-code branch",
  M.dispatchFailure({ exitCode = 1, stdout = "warning: x" }), "warning: x")
expectEqual("dispatchFailure error beats the exit-code branch",
  M.dispatchFailure({ exitCode = 7, stdout = "an error" }), "an error")

-- out = stdout .. stderr, non-string fields count as empty
expectEqual("dispatchFailure concatenates stdout then stderr",
  M.dispatchFailure({ exitCode = 0, stdout = "a", stderr = "an error" }), "aan error")
expectEqual("dispatchFailure non-string stdout counts as empty",
  M.dispatchFailure({ exitCode = 0, stdout = 123, stderr = "an error" }), "an error")
expectEqual("dispatchFailure non-string stderr counts as empty",
  M.dispatchFailure({ exitCode = 0, stdout = "an error", stderr = 456 }), "an error")
expectEqual("dispatchFailure missing stderr counts as empty",
  M.dispatchFailure({ exitCode = 0, stdout = "an error" }), "an error")

-- non-zero exit code branch
expectEqual("dispatchFailure non-zero exit with output -> out",
  M.dispatchFailure({ exitCode = 1, stdout = "boom" }), "boom")
expectEqual("dispatchFailure non-zero exit no output -> 'exit code 1'",
  M.dispatchFailure({ exitCode = 1 }), "exit code 1")
expectEqual("dispatchFailure non-zero exitCode string -> 'exit code 3'",
  M.dispatchFailure({ exitCode = "3" }), "exit code 3")
expectEqual("dispatchFailure non-zero exit, nil fields -> exit code",
  M.dispatchFailure({ exitCode = 2, stdout = nil, stderr = nil }), "exit code 2")

-- ---------------------------------------------------------------------------
-- M.statusKey
-- ---------------------------------------------------------------------------
expectEqual("statusKey('same-monitor') -> status.same_monitor",
  M.statusKey("same-monitor"), "status.same_monitor")
expectEqual("statusKey(nil) -> status.no_target", M.statusKey(nil), "status.no_target")
expectEqual("statusKey('invalid-drop') -> status.no_target",
  M.statusKey("invalid-drop"), "status.no_target")
expectEqual("statusKey('unknown-workspace') -> status.no_target",
  M.statusKey("unknown-workspace"), "status.no_target")
expectEqual("statusKey('unknown-monitor') -> status.no_target",
  M.statusKey("unknown-monitor"), "status.no_target")
expectEqual("statusKey('') -> status.no_target", M.statusKey(""), "status.no_target")
expectEqual("statusKey(5) -> status.no_target", M.statusKey(5), "status.no_target")
expectEqual("statusKey({}) -> status.no_target", M.statusKey({}), "status.no_target")
expectEqual("statusKey('same_monitor') (underscore) -> status.no_target",
  M.statusKey("same_monitor"), "status.no_target")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("TOTAL %d PASSED %d FAILED %d", total, passed, failed))
os.exit(failed == 0 and 0 or 1)
