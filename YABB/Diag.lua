local ADDON, ns = ...
ns.Diag = ns.Diag or {}
local Diag = ns.Diag

-- ============================================================
-- log ring buffer (cap ~200, oldest -> newest)
-- ============================================================

local LOG_CAP = 200
local buffer = {}

function Diag.log(msg)
  buffer[#buffer + 1] = msg
  while #buffer > LOG_CAP do
    table.remove(buffer, 1)
  end
end

function Diag.getLog()
  local copy = {}
  for i = 1, #buffer do copy[i] = buffer[i] end
  return copy
end

function Diag.clearLog()
  buffer = {}
end

-- ============================================================
-- trace(line, meta) -> string
-- Classifies `line` and formats either the decision or the reject
-- reason. No WoW global involved -- pure classification + formatting.
-- ============================================================

local function joinRoles(roles)
  local parts = {}
  for role in pairs(roles or {}) do
    parts[#parts + 1] = role
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function joinNeedCounts(needCounts)
  local parts = {}
  for role, count in pairs(needCounts or {}) do
    parts[#parts + 1] = role .. ":" .. tostring(count)
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- formatReject/formatListing are split out of trace() so Ingest.lua's
-- verbose-mode hook (every ingest decision streams to the Diag ring
-- buffer) can reuse the exact same line format without re-running
-- Classifier.classify a second time -- it already has the
-- listing/reason from its own real classify call.
function Diag.formatReject(reason)
  return "REJECT reason=" .. tostring(reason)
end

function Diag.formatListing(listing)
  return table.concat({
    "category=" .. tostring(listing.category or "-"),
    "target=" .. tostring(listing.target or "-"),
    "tier=" .. tostring(listing.tier or "-"),
    "intent=" .. tostring(listing.intent or "-"),
    "roles=" .. joinRoles(listing.roles),
    "need=" .. joinNeedCounts(listing.needCounts),
    "level=" .. tostring(listing.levelFilter or "-"),
  }, " ")
end

function Diag.trace(line, meta)
  meta = meta or { poster = "you", channelName = "parse" }
  local listing, reason = ns.Classifier.classify(line, meta, ns.C)

  if not listing then
    return Diag.formatReject(reason)
  end

  return Diag.formatListing(listing)
end

-- ============================================================
-- slash commands -- guarded so this file still loads under the
-- plain Lua 5.1 test stub, where SlashCmdList is absent.
-- ============================================================

if SlashCmdList then
  local function printLine(msg)
    if DEFAULT_CHAT_FRAME then
      DEFAULT_CHAT_FRAME:AddMessage(tostring(msg))
    end
  end

  local function handleParse(rest)
    printLine(Diag.trace(rest))
  end

  -- captureStatusLine defined here (ahead of handleDiag) since handleDiag
  -- also surfaces it -- Lua locals are only visible to code appearing
  -- after their declaration.
  local function captureStatusLine()
    local on = ns.Capture.isOn(YABB_DB)
    return "capture: " .. (on and "on" or "off") .. ", " .. tostring(ns.Capture.count(YABB_DB)) .. " entries"
  end

  local function handleLog(rest)
    local arg = (rest or ""):lower()
    if arg == "on" then
      Diag.verbose = true
      printLine("YABB log: on")
    elseif arg == "off" then
      Diag.verbose = false
      printLine("YABB log: off")
    else
      printLine("YABB log: usage /yabb log on|off (currently " .. (Diag.verbose and "on" or "off") .. ")")
    end
  end

  -- /yabb diag: version + log count, then one line per subsystem init
  -- block, via ns.Diag.getInitStatus (Init.lua). Guarded on getInitStatus
  -- existing so this command still degrades cleanly (just the version/
  -- log-count line) rather than erroring if Init.lua ever failed to
  -- load at all.
  local function handleDiag()
    printLine(("YABB %s -- log entries: %d"):format(tostring(ns.VERSION), #Diag.getLog()))
    if Diag.getInitStatus then
      local ok, rows = pcall(Diag.getInitStatus)
      if ok and rows then
        for i = 1, #rows do
          local r = rows[i]
          printLine(("  init.%s: %s (%s)"):format(tostring(r.name), r.ok and "ok" or "FAIL", tostring(r.detail)))
        end
      end
    end
    -- Capture stays quiet once left on -- a player has no reason to
    -- think to run /yabb capture status -- so surface it here, but only
    -- while it's actually on, so this stays silent for the common (off)
    -- case.
    if ns.Capture and YABB_DB and ns.Capture.isOn(YABB_DB) then
      printLine("YABB: message capture is on (" .. tostring(ns.Capture.count(YABB_DB)) .. " saved). Run /yabb capture off to stop.")
    end
  end

  -- /yabb dump: build the full multi-section text (ns.Dump.build()) and
  -- open it in a scrollable select-all copy window (ns.Dump.showWindow,
  -- which reuses FiltersUI's existing copy window rather than
  -- duplicating it). Both the build and the window are pcall-guarded
  -- independently, and a window failure falls back to printing the dump
  -- straight to chat -- this command must never be the thing that
  -- errors, since it exists specifically to debug everything else.
  local function handleDump()
    if not (ns.Dump and ns.Dump.build) then
      printLine("YABB: dump is unavailable, the addon did not load fully. Try /yabb diag.")
      return
    end
    local ok, text = pcall(ns.Dump.build)
    if not ok or type(text) ~= "string" then
      printLine("YABB: dump failed -- " .. tostring(text))
      return
    end
    local opened = ns.Dump.showWindow and ns.Dump.showWindow(text)
    if not opened then
      printLine("YABB: could not open the copy window. Printing the dump to chat instead.")
      printLine(text)
    end
  end

  -- /yabb capture on|off|clear|dump|status: tuning-capture control (see
  -- ns.Capture). Bare `/yabb capture` behaves like `status`. Every branch
  -- is guarded on `ns.Capture and YABB_DB` so a missing Capture.lua load
  -- or a not-yet-populated SavedVariables table degrades to a message
  -- instead of erroring.
  local function handleCapture(rest)
    if not (ns.Capture and YABB_DB) then
      printLine("YABB: capture is unavailable. Try /yabb diag.")
      return
    end
    local arg = (rest or ""):lower()
    if arg == "" or arg == "status" then
      printLine(captureStatusLine())
    elseif arg == "on" then
      ns.Capture.setOn(YABB_DB, true)
      printLine("YABB: capture on -- this stores raw chat lines and poster names in your SavedVariables (capped at 3000). Run /yabb capture off to stop.")
    elseif arg == "off" then
      ns.Capture.setOn(YABB_DB, false)
      printLine("YABB capture: off")
    elseif arg == "clear" then
      ns.Capture.clear(YABB_DB)
      printLine("YABB capture: cleared")
    elseif arg == "dump" then
      if ns.FiltersUI and ns.FiltersUI.showCopyWindow then
        ns.FiltersUI.showCopyWindow("YABB Captures", ns.Capture.exportText(YABB_DB))
      else
        printLine("YABB: could not open the copy window.")
      end
    else
      printLine("YABB capture: usage /yabb capture on|off|clear|dump|status")
    end
  end

  -- /yabb cache: there is no persistent player cache -- class is resolved
  -- on demand and level lives only in a transient, session-only map
  -- (Players.lua). This just reports that map's current size.
  local function cacheStatusLine()
    local n = 0
    if ns.Players.levelCount then
      local ok, v = pcall(ns.Players.levelCount)
      if ok and type(v) == "number" then n = v end
    end
    return "YABB: " .. tostring(n) .. " player levels known this session, from your guild, friends, party and targets. Resets on reload."
  end

  local function handleCache(rest)
    if not ns.Players then
      printLine("YABB: player info is unavailable. Try /yabb diag.")
      return
    end
    local arg = (rest or ""):lower()
    if arg == "" or arg == "status" then
      printLine(cacheStatusLine())
    else
      printLine("YABB: /yabb cache shows how many player levels are known this session.")
    end
  end

  -- /yabb reset: the only in-game recovery from a corrupted SavedVariables
  -- field (the rules editor's own reset only rewrites categories/pipeline).
  -- Two-step, same discipline as the editor's destructive reset: the bare
  -- command explains what it does, `confirm` actually does it.
  --
  -- This must list every top-level YABB_DB key the addon ever writes.
  -- YABB_DB.players is the one deliberate exception: Players.init() nils
  -- it unconditionally on every load already, independent of this list.
  local RESET_KEYS = {
    "channels", "display", "hiddenCategories", "intentFilter", "userConfig",
    "captures", "captureOn", "window", "introShown", "expiry", "minimap",
  }

  local function handleReset(rest)
    local arg = (rest or ""):lower()
    if arg == "confirm" then
      if type(YABB_DB) == "table" then
        for i = 1, #RESET_KEYS do
          YABB_DB[RESET_KEYS[i]] = nil
        end
      end
      printLine("YABB: settings reset to defaults. Type /reload to finish.")
    else
      printLine("YABB: this clears your channel mute settings, hidden categories, LFG/LFM filter, custom categories & rules, listing expiry, display options, window position, minimap button position, captured tuning data and first-run state. Type /yabb reset confirm to proceed.")
    end
  end

  -- Bare `/yabb` toggles the board window. Guarded on ns.UI existing/
  -- loading cleanly: a UI init failure must not break the other slash
  -- subcommands.
  local function handleToggle()
    if ns.UI and ns.UI.Toggle then
      ns.UI.Toggle()
    else
      printLine("YABB: the board window failed to load. Try /yabb diag.")
    end
  end

  SLASH_YABB1 = "/yabb"
  SlashCmdList["YABB"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
      handleToggle()
    elseif cmd == "parse" then
      handleParse(rest)
    elseif cmd == "log" then
      handleLog(rest)
    elseif cmd == "diag" then
      handleDiag()
    elseif cmd == "dump" then
      handleDump()
    elseif cmd == "capture" then
      handleCapture(rest)
    elseif cmd == "cache" then
      handleCache(rest)
    elseif cmd == "reset" then
      handleReset(rest)
    else
      printLine("YABB: unknown command '" .. cmd .. "'. Try /yabb to open the board, or diag, dump, capture, cache, log, parse.")
    end
  end
end

return Diag
