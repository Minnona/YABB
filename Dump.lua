local ADDON, ns = ...
ns.Dump = ns.Dump or {}
local Dump = ns.Dump

-- ============================================================
-- Visual frame-tree introspection ("/yabb dump") + a section assembler
-- pulling every other subsystem's live state into one pasteable block.
-- Ascension hides Lua errors, and this addon isn't tested against a
-- mock client -- this file IS the remote-debug surface that closes
-- that gap: one dump a player pastes back stands in for a live
-- debugger.
--
-- Two clearly separated halves:
--   1. Pure section builders (sectionBoard/sectionClassifier/
--      sectionChannels/sectionEnv/sectionCompat/sectionInit/
--      sectionPlayers) -- take already-computed data, return a labeled
--      text block, touch no WoW global, TDD'd under lua5.1
--      (tests/dump_spec.lua).
--   2. WoW-touching glue (walkFrame, the probe/gather helpers inside
--      build(), showWindow) -- only ever called from a live client
--      (via the /yabb dump slash in Diag.lua), guarded + pcall-wrapped
--      throughout so a single missing API/odd frame shape degrades a
--      section instead of aborting the whole dump.
--
-- No WoW global is touched at module (file) scope (see Loader.lua for
-- the load-scope convention).
-- ============================================================

-- ============================================================
-- copy window: reuse, not duplicate. FiltersUI.lua already ports the
-- era-standard "no OS clipboard on 3.3.5" copy trick (SetText ->
-- HighlightText() -> SetFocus() select-all) as a fully generic
-- FiltersUI.showCopyWindow(titleText, bodyText) -- calling into it is
-- one popup instance, two callers, single source of truth for the
-- widget. Guarded/pcall-wrapped so a missing or broken FiltersUI
-- degrades this to `false` (handleDump in Diag.lua falls back to
-- printing the dump to chat) instead of erroring.
-- ============================================================

function Dump.showWindow(text)
  if not (ns.FiltersUI and ns.FiltersUI.showCopyWindow) then
    return false
  end
  local ok = pcall(ns.FiltersUI.showCopyWindow, "YABB Dump", text)
  return ok and true or false
end

-- ============================================================
-- PURE section builders -- each returns one "=== NAME ===" labeled text
-- block from injected data only. No frame, no live global, nothing
-- WoW-specific: safe to call from tests/dump_spec.lua under lua5.1.
-- ============================================================

-- list: array of {index=, name=} (ns.Compat.parseChannelList /
-- ns.Ingest.channels shape).
function Dump.sectionChannels(list)
  local out = { "=== CHANNELS ===" }
  list = list or {}
  if #list == 0 then
    out[#out + 1] = "(no channels joined)"
  else
    for i = 1, #list do
      local ch = list[i]
      out[#out + 1] = "[" .. tostring(ch.index) .. "] " .. tostring(ch.name)
    end
  end
  return table.concat(out, "\n")
end

-- board: anything exposing the same colon-call contract ns.board (a
-- real Board.new() instance) does -- countsByCategory()/all() -- so a
-- plain stub table works here exactly like it does in
-- tests/ingest_spec.lua's own stubBoard(), no Board.lua dependency
-- needed to test this function.
function Dump.sectionBoard(board)
  local out = { "=== BOARD ===" }
  if not board then
    out[#out + 1] = "(no board)"
    return table.concat(out, "\n")
  end

  local counts = (board.countsByCategory and board:countsByCategory()) or {}
  local catNames = {}
  for cat in pairs(counts) do catNames[#catNames + 1] = cat end
  table.sort(catNames)
  if #catNames == 0 then
    out[#out + 1] = "counts: (empty)"
  else
    local parts = {}
    for _, cat in ipairs(catNames) do
      parts[#parts + 1] = cat .. "=" .. tostring(counts[cat])
    end
    out[#out + 1] = "counts: " .. table.concat(parts, ", ")
  end

  local entries = (board.all and board:all()) or {}
  out[#out + 1] = "entries: " .. #entries
  for i = 1, #entries do
    local e = entries[i]
    out[#out + 1] = ("  [%d] %s poster=%s target=%s tier=%s intent=%s lastSeen=%s"):format(
      i, tostring(e.category or "-"), tostring(e.poster or "-"), tostring(e.target or "-"),
      tostring(e.tier or "-"), tostring(e.intent or "-"), tostring(e.lastSeen or "-"))
  end
  return table.concat(out, "\n")
end

-- traces: array of already-formatted strings (Diag.formatListing/
-- formatReject output -- the same ring-buffer entries Diag.log
-- accumulates once verbose mode is on, or a plain /yabb parse trace).
function Dump.sectionClassifier(traces)
  local out = { "=== CLASSIFIER ===" }
  traces = traces or {}
  if #traces == 0 then
    out[#out + 1] = "(no traces -- /yabb log on to capture ingest decisions)"
  else
    for i = 1, #traces do
      out[#out + 1] = i .. ". " .. tostring(traces[i])
    end
  end
  return table.concat(out, "\n")
end

-- probe: name -> boolean (global/API presence) or any other value
-- (derived Compat.* results, e.g. call counts) -- booleans render as
-- yes/no, anything else via tostring. Sorted by key for a stable diff
-- between two dumps.
function Dump.sectionCompat(probe)
  local out = { "=== COMPAT ===" }
  probe = probe or {}
  local keys = {}
  for k in pairs(probe) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then
    out[#out + 1] = "(no probe data)"
  else
    for _, k in ipairs(keys) do
      local v = probe[k]
      local vtext
      if type(v) == "boolean" then
        vtext = v and "yes" or "no"
      else
        vtext = tostring(v)
      end
      out[#out + 1] = "  " .. k .. ": " .. vtext
    end
    -- Ascension defines BackdropTemplateMixin (see Compat.lua's
    -- applyBackdrop), so the common retail-safe ternary
    -- (`BackdropTemplateMixin and "BackdropTemplate" or nil`) silently
    -- resolves truthy here and routes SetBackdrop into a broken Lua
    -- NineSlice backport. Surface it loudly if it's ever probed true.
    if probe.BackdropTemplateMixin then
      out[#out + 1] = "  NOTE: BackdropTemplateMixin present -- never pass as a CreateFrame template (patch-B trap, see Compat.lua)"
    end
  end
  return table.concat(out, "\n")
end

-- rows: array of {name=, ok=boolean, detail=string}. Uses
-- ns.Diag.getInitStatus when Init.lua has recorded real pcall outcomes;
-- falls back to a best-effort presence probe (did the module's own
-- bootstrap leave the observable field it's supposed to?) otherwise --
-- see probeInit() below.
function Dump.sectionInit(rows)
  local out = { "=== INIT ===" }
  rows = rows or {}
  if #rows == 0 then
    out[#out + 1] = "(no data)"
  else
    for i = 1, #rows do
      local r = rows[i]
      out[#out + 1] = "  " .. tostring(r.name) .. ": " .. (r.ok and "ok" or "not ready") ..
        " (" .. tostring(r.detail or "") .. ")"
    end
  end
  return table.concat(out, "\n")
end

-- Players.lua keeps no persistent player cache -- class is resolved on
-- demand per row and level lives only in a transient, session-only map
-- (see Players.lua's header). Report each pipeline stage separately --
-- module loaded, init ran, top-up driver running -- so a broken stage
-- is nameable from this section alone, without reading code or
-- cross-referencing the INIT section.
-- info: {loaded=boolean, initRan=boolean, driverRunning=boolean,
-- levelCount=, bySource=, probe=table}.
function Dump.sectionPlayers(info)
  local out = { "=== PLAYERS ===" }
  info = info or {}
  if info.loaded then
    out[#out + 1] = "module: loaded"
  else
    out[#out + 1] = "module: NOT LOADED -- Players.lua failed to load (check Logs\\FrameXML.log; a filename added to the addon folder after the client process already started needs a full client restart, not /reload)"
  end
  out[#out + 1] = "init: " .. (info.initRan and "ran" or "did not run")
  out[#out + 1] = "top-up driver: " .. (info.driverRunning and "running" or "not running")
  out[#out + 1] = "class: resolved on-demand per row (GetPlayerInfoByGUID off the listing's guid) -- never cached"
  out[#out + 1] = "level: transient session-only -- " .. tostring(info.levelCount or 0) ..
    " entries tracked (no persistent cache -- YABB_DB.players is not used)"

  -- which free/passive sources are actually contributing tracked levels
  -- (guild/friend/party/unit).
  local bySource = info.bySource or {}
  local srcNames = {}
  for k in pairs(bySource) do srcNames[#srcNames + 1] = k end
  table.sort(srcNames)
  if #srcNames == 0 then
    out[#out + 1] = "levels by source: (none yet)"
  else
    local srcParts = {}
    for i = 1, #srcNames do
      srcParts[#srcParts + 1] = srcNames[i] .. "=" .. tostring(bySource[srcNames[i]])
    end
    out[#out + 1] = "levels by source: " .. table.concat(srcParts, " ")
  end

  -- /who is dead on Ascension -- Players.lua touches none of SetWhoToUI/
  -- SendWho/GetNumWhoResults/GetWhoInfo/FriendsFrame/LibStub, so none of
  -- them are probed here; only the free-source APIs this file actually
  -- calls.
  local probe = info.probe or {}
  local probeNames = {
    "GetGuildRosterInfo", "GetNumGuildMembers", "GetFriendInfo", "GetNumFriends",
    "GetNumPartyMembers", "GetNumRaidMembers", "UnitLevel", "GetPlayerInfoByGUID",
  }
  local parts = {}
  for i = 1, #probeNames do
    local n = probeNames[i]
    parts[#parts + 1] = n .. "=" .. (probe[n] and "yes" or "no")
  end
  out[#out + 1] = "api: " .. table.concat(parts, " ")

  return table.concat(out, "\n")
end

-- info: {version=, build=, realm=, level=}.
function Dump.sectionEnv(info)
  info = info or {}
  local out = { "=== ENV ===" }
  out[#out + 1] = "version: " .. tostring(info.version or "?")
  out[#out + 1] = "build: " .. tostring(info.build or "?")
  out[#out + 1] = "realm: " .. tostring(info.realm or "?")
  out[#out + 1] = "level: " .. tostring(info.level or "?")
  return table.concat(out, "\n")
end

-- ============================================================
-- VISUAL: recursive frame-tree walk. In-game only -- CreateFrame-family
-- objects only exist in the live client, so this is confirmed solely by
-- the in-game checklist, never by a harness. Every WoW method call goes
-- through `pget`/`plist` below, which pcall-guards the call and treats
-- a missing method or a raised error identically (degrade to nil/empty
-- rather than abort the walk) -- one odd frame/region shape can never
-- take down the rest of the tree.
-- ============================================================

local MAX_WALK_DEPTH = 16 -- safety net only; this tree is nowhere near this deep

-- single WoW getter, fixed small arity (GetPoint/GetTexCoord/etc. all
-- return at most a handful of values) -- returns nil (no error) if the
-- method is absent or raises.
local function pget(obj, method, ...)
  if not obj then return nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d, e, f, g, h = pcall(fn, obj, ...)
  if not ok then return nil end
  return a, b, c, d, e, f, g, h
end

-- multi-return WoW getter (GetRegions()/GetChildren() -- an unbounded
-- number of objects, never nils in the middle on a real client) --
-- returns a plain array, empty on any failure.
local function plist(obj, method)
  if not obj then return {} end
  local fn = obj[method]
  if type(fn) ~= "function" then return {} end
  local results = { pcall(fn, obj) }
  local ok = table.remove(results, 1)
  if not ok then return {} end
  return results
end

local function indent(depth)
  return string.rep("  ", depth)
end

local function describePoints(region, depth, out)
  local n = pget(region, "GetNumPoints") or 0
  if n == 0 then
    -- GetNumPoints itself may be absent on some region type on this
    -- client; fall back to a single GetPoint(1) probe so the common
    -- single-anchor case still surfaces even then.
    local point, relativeTo, relativePoint, x, y = pget(region, "GetPoint", 1)
    if point then
      local relName = pget(relativeTo, "GetName") or (relativeTo and "?" or "-")
      out[#out + 1] = indent(depth) .. "point: " .. tostring(point) .. " -> " ..
        tostring(relName) .. "." .. tostring(relativePoint or "-") ..
        " (" .. tostring(x or 0) .. ", " .. tostring(y or 0) .. ")"
    end
    return
  end
  for i = 1, n do
    local point, relativeTo, relativePoint, x, y = pget(region, "GetPoint", i)
    if point then
      local relName = pget(relativeTo, "GetName") or (relativeTo and "?" or "-")
      out[#out + 1] = indent(depth) .. "point[" .. i .. "]: " .. tostring(point) .. " -> " ..
        tostring(relName) .. "." .. tostring(relativePoint or "-") ..
        " (" .. tostring(x or 0) .. ", " .. tostring(y or 0) .. ")"
    end
  end
end

-- one frame/region's own line(s): type, name, shown, size, every
-- anchor point, strata, level, alpha; textures additionally get
-- GetTexture/texcoords/vertex color/draw layer; fontstrings get their
-- text. pcall-wrapped as a whole so a single bad region can only ever
-- cost its own line(s), never the rest of the tree.
local function describeNode(region, depth, out)
  local ok, err = pcall(function()
    local objType = pget(region, "GetObjectType") or "?"
    local name = pget(region, "GetName")
    local shown = pget(region, "IsShown")
    local w, h = pget(region, "GetWidth"), pget(region, "GetHeight")
    local strata = pget(region, "GetFrameStrata")
    local level = pget(region, "GetFrameLevel")
    local alpha = pget(region, "GetAlpha")

    out[#out + 1] = indent(depth) .. tostring(objType) .. "  " .. tostring(name or "(unnamed)") ..
      "  shown=" .. tostring(shown) ..
      "  " .. tostring(w or "?") .. "x" .. tostring(h or "?") ..
      (strata and ("  strata=" .. tostring(strata)) or "") ..
      (level and ("  level=" .. tostring(level)) or "") ..
      (alpha and ("  alpha=" .. tostring(alpha)) or "")

    describePoints(region, depth + 1, out)

    if objType == "Texture" then
      local tex = pget(region, "GetTexture")
      local layer, sublevel = pget(region, "GetDrawLayer")
      out[#out + 1] = indent(depth + 1) .. "texture=" .. tostring(tex or "-") ..
        "  layer=" .. tostring(layer or "-") .. (sublevel and ("/" .. tostring(sublevel)) or "")

      local ulx, uly, llx, lly, urx, ury, lrx, lry = pget(region, "GetTexCoord")
      if ulx then
        out[#out + 1] = indent(depth + 1) .. "texcoord=" ..
          table.concat({ ulx, uly, llx, lly, urx, ury, lrx, lry }, ",")
      end

      local r, g, b, a = pget(region, "GetVertexColor")
      if r then
        out[#out + 1] = indent(depth + 1) .. "vertexColor=" .. tostring(r) .. "," .. tostring(g) ..
          "," .. tostring(b) .. "," .. tostring(a)
      end
    elseif objType == "FontString" then
      local text = pget(region, "GetText")
      out[#out + 1] = indent(depth + 1) .. "text=" .. tostring(text or "-")
    end
  end)
  if not ok then
    out[#out + 1] = indent(depth) .. "(walk error: " .. tostring(err) .. ")"
  end
end

function Dump.walkFrame(frame, depth)
  depth = depth or 0
  local out = {}
  if not frame then
    out[#out + 1] = indent(depth) .. "(nil frame)"
    return table.concat(out, "\n")
  end
  if depth > MAX_WALK_DEPTH then
    out[#out + 1] = indent(depth) .. "(max depth reached)"
    return table.concat(out, "\n")
  end

  describeNode(frame, depth, out)

  local regions = plist(frame, "GetRegions")
  for i = 1, #regions do
    describeNode(regions[i], depth + 1, out)
  end

  local children = plist(frame, "GetChildren")
  for i = 1, #children do
    out[#out + 1] = Dump.walkFrame(children[i], depth + 1)
  end

  return table.concat(out, "\n")
end

-- ============================================================
-- build() -- gathers live data from every subsystem and hands it to the
-- pure section builders above. Each section is wrapped in its own
-- pcall (safeSection) so one broken piece (a bad frame shape, a missing
-- API) degrades only that section's block instead of losing the whole
-- dump -- the entire point of an instrument-first remote-debug tool is
-- that it must never itself be the thing that errors.
-- ============================================================

local MAX_CLASSIFIER_TRACES = 50

local function safeSection(name, fn)
  local ok, text = pcall(fn)
  if ok and type(text) == "string" then return text end
  return "=== " .. name .. " ===\n(section failed: " .. tostring(text) .. ")"
end

local function safePlayerLevel()
  if UnitLevel then
    local ok, lvl = pcall(UnitLevel, "player")
    if ok then return lvl end
  end
  return nil
end

local function recentTraces()
  local traces = {}
  if ns.Diag and ns.Diag.getLog then
    local full = ns.Diag.getLog()
    local from = #full - MAX_CLASSIFIER_TRACES + 1
    if from < 1 then from = 1 end
    for i = from, #full do
      traces[#traces + 1] = full[i]
    end
  end
  return traces
end

-- raw global/API presence, plus a couple of live ns.Compat-derived
-- values.
local COMPAT_PROBE_NAMES = {
  "CreateFrame", "GetChannelList", "GetPlayerInfoByGUID", "UnitLevel",
  "GetNumPartyMembers", "GetNumRaidMembers", "GetRealmName", "GetBuildInfo",
  "C_Timer", "BackdropTemplateMixin", "UISpecialFrames", "EasyMenu",
  "GetMinimapShape", "ChatFrame_OpenChat", "SendWho", "InviteUnit",
}

local function probeCompat()
  local probe = {}
  for i = 1, #COMPAT_PROBE_NAMES do
    local key = COMPAT_PROBE_NAMES[i]
    probe[key] = _G ~= nil and _G[key] ~= nil
  end
  if ns.Compat then
    if ns.Compat.isInGroup then
      local ok, v = pcall(ns.Compat.isInGroup)
      probe["Compat.isInGroup()"] = ok and v or "error"
    end
    if ns.Compat.getJoinedChannels then
      local ok, list = pcall(ns.Compat.getJoinedChannels)
      probe["Compat.getJoinedChannels()#"] = ok and #list or "error"
    end
  end
  return probe
end

-- best-effort presence probe (see Dump.sectionInit's own comment) --
-- prefers the real Diag INIT buffer the moment one exists. The fallback
-- list below must name every subsystem, Players included: if Diag.lua
-- itself is the file that fails to load, the real INIT buffer
-- (ns.Diag.getInitStatus) never exists at all, so any subsystem missing
-- from this fallback would go unreported for the exact same reason.
local function probeInit()
  if ns.Diag and ns.Diag.getInitStatus then
    local ok, rows = pcall(ns.Diag.getInitStatus)
    if ok and rows then return rows end
  end
  local rows = {}
  local function push(name, ok, detail)
    rows[#rows + 1] = { name = name, ok = ok and true or false, detail = detail }
  end
  push("Players", ns.Players and ns.Players.frame ~= nil, (ns.Players and ns.Players.frame) and "top-up driver running" or "not started")
  push("UI", ns.UI and ns.UI.frame ~= nil, (ns.UI and ns.UI.frame) and "frame ready" or "not initialized")
  push("Ingest", ns.Ingest and ns.Ingest.frame ~= nil, (ns.Ingest and ns.Ingest.frame) and "event frame registered" or "not started")
  push("FiltersUI", ns.FiltersUI and ns.FiltersUI.panel ~= nil, (ns.FiltersUI and ns.FiltersUI.panel) and "rules editor panel built" or "not opened yet")
  push("MinimapButton", ns.MinimapButton and ns.MinimapButton.button ~= nil, (ns.MinimapButton and ns.MinimapButton.button) and "button placed" or "not initialized")
  return rows
end

-- gathers ns.Players' live diagnostic state for Dump.sectionPlayers.
-- Every accessor call guarded (ns.Players may not be loaded, or may be a
-- partial stub in a test) so a missing getter just degrades that one
-- field to its section-builder default rather than erroring the whole
-- PLAYERS block. /who is dead on Ascension -- SetWhoToUI/SendWho/
-- GetNumWhoResults/GetWhoInfo/FriendsFrame/LibStub are never probed;
-- Players.lua touches none of them.
local PLAYERS_API_PROBE_NAMES = {
  "GetGuildRosterInfo", "GetNumGuildMembers", "GetFriendInfo", "GetNumFriends",
  "GetNumPartyMembers", "GetNumRaidMembers", "UnitLevel", "GetPlayerInfoByGUID",
}

-- Makes an empty/never-initialized module state unmistakable in the
-- PLAYERS section itself, without needing to cross-reference the INIT
-- section or read code. `loaded` answers "did Players.lua's file even
-- run" (ns.Players existing at all). `initRan` answers "given the file
-- loaded, did Init.lua's orchestrator actually reach and invoke
-- Players.init()". `driverRunning` answers "is the free-top-up OnEvent
-- driver frame alive" (Players.frame, set only by Players.start()).
local function gatherPlayersInfo()
  local info = {}
  local P = ns.Players
  info.loaded = P ~= nil
  if P then
    if P.levelCount then local ok, v = pcall(P.levelCount); if ok then info.levelCount = v end end
    if P.initRan then local ok, v = pcall(P.initRan); if ok then info.initRan = v end end
    if P.levelsBySource then local ok, v = pcall(P.levelsBySource); if ok then info.bySource = v end end
    local ok, running = pcall(function() return P.frame ~= nil end)
    info.driverRunning = ok and running or false
  end
  local probe = {}
  for i = 1, #PLAYERS_API_PROBE_NAMES do
    local key = PLAYERS_API_PROBE_NAMES[i]
    probe[key] = _G ~= nil and _G[key] ~= nil
  end
  info.probe = probe
  return info
end

local function envInfo()
  local build
  if GetBuildInfo then
    local ok, version, buildNum, date, tocversion = pcall(GetBuildInfo)
    if ok then
      build = tostring(version) .. " build " .. tostring(buildNum) .. " (" .. tostring(date) ..
        ", toc " .. tostring(tocversion) .. ")"
    end
  end
  local realm
  if GetRealmName then
    local ok, r = pcall(GetRealmName)
    if ok then realm = r end
  end
  return {
    version = ns.VERSION,
    build = build,
    realm = realm,
    level = safePlayerLevel(),
  }
end

function Dump.build()
  local parts = {}

  parts[#parts + 1] = safeSection("VISUAL", function()
    if ns.UI and ns.UI.frame then
      return "=== VISUAL ===\n" .. Dump.walkFrame(ns.UI.frame, 0)
    end
    return "=== VISUAL ===\n(ns.UI.frame not available -- open the board with /yabb first)"
  end)

  parts[#parts + 1] = safeSection("CHANNELS", function()
    return Dump.sectionChannels(ns.Ingest and ns.Ingest.channels)
  end)

  parts[#parts + 1] = safeSection("BOARD", function()
    return Dump.sectionBoard(ns.board)
  end)

  parts[#parts + 1] = safeSection("CLASSIFIER", function()
    return Dump.sectionClassifier(recentTraces())
  end)

  parts[#parts + 1] = safeSection("PLAYERS", function()
    return Dump.sectionPlayers(gatherPlayersInfo())
  end)

  parts[#parts + 1] = safeSection("COMPAT", function()
    return Dump.sectionCompat(probeCompat())
  end)

  parts[#parts + 1] = safeSection("INIT", function()
    return Dump.sectionInit(probeInit())
  end)

  parts[#parts + 1] = safeSection("ENV", function()
    return Dump.sectionEnv(envInfo())
  end)

  return table.concat(parts, "\n\n")
end

return Dump
