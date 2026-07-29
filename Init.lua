local ADDON, ns = ...
ns.Init = ns.Init or {}
local Init = ns.Init

-- ============================================================
-- Fail-soft init orchestration. Loads last in the TOC and is the only
-- place a subsystem's init/start is invoked, so init runs exactly once,
-- in one order, decided in one file.
--
-- Order: Players (roster listeners; independent) -> Ingest (event
-- wiring, before any chat line can arrive) -> UI (builds the frame
-- UI.xml declared) -> FiltersUI (attaches its entry button to
-- ns.UI.frame, so UI must already have run) -> MinimapButton
-- (independent).
--
-- Ingest.start() is NOT idempotent -- it creates and registers a fresh
-- event frame per call -- so it must never be invoked from anywhere else.
-- ============================================================

-- Each block carries `key`, the ns.<key> table its module is supposed to
-- create at load. runAll() checks ns[key] before calling fn: a module
-- whose file never loaded at all (Ascension's silent "Error loading",
-- e.g. a file added to the addon folder after the client process
-- already started) is recorded as a distinct failure, not folded into
-- the same generic "did not start" text a module that loaded fine but
-- declined to start also produces -- ns.Players being nil should read
-- differently from Players.init() returning false.
local BLOCKS = {
  { name = "Players", key = "Players", fn = function() return ns.Players and ns.Players.init and ns.Players.init() end },
  { name = "Ingest", key = "Ingest", fn = function() return ns.Ingest and ns.Ingest.start and ns.Ingest.start() end },
  { name = "UI", key = "UI", fn = function() return ns.UI and ns.UI.init and ns.UI.init() end },
  { name = "FiltersUI", key = "FiltersUI", fn = function() return ns.FiltersUI and ns.FiltersUI.init and ns.FiltersUI.init() end },
  { name = "MinimapButton", key = "MinimapButton", fn = function() return ns.MinimapButton and ns.MinimapButton.init and ns.MinimapButton.init() end },
}

-- status: array of {name=, ok=, detail=}, one row per block, in the
-- order first recorded. Local to this file (not exposed directly) --
-- Init.getStatus() below always hands back a defensive copy so a
-- caller mutating the returned table can never corrupt the recorded
-- state.
local status = {}

local function findRow(name)
  for i = 1, #status do
    if status[i].name == name then return i end
  end
  return nil
end

-- printFail(row) -- emits one player-facing chat line for a block that
-- recorded ok=false, so a dead subsystem is never silent. Points at
-- /yabb diag rather than the raw detail text, which stays in the Diag
-- ring buffer and the dump INIT section for actual debugging. Same
-- guarded DEFAULT_CHAT_FRAME:AddMessage convention Diag.lua's own
-- printLine uses. AddMessage itself is pcall-wrapped: a broken or
-- replaced chat frame could otherwise raise here and abort whatever
-- subsystem init call was still unwinding through recordRow/runBlock's
-- caller, taking every later block down with it.
local function printFail(row)
  if DEFAULT_CHAT_FRAME then
    pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME,
      "YABB: " .. tostring(row.name) .. " did not start. Run /yabb diag for details.")
  end
end

-- recordRow(row) -- shared by runBlock and runAll's missing-module
-- short-circuit below: stores/replaces the row (same idempotent-by-name
-- rule runBlock always had), mirrors it to the Diag ring buffer, and
-- prints one chat line whenever ok is false, whichever path produced
-- the row.
local function recordRow(row)
  local idx = findRow(row.name)
  if idx then
    status[idx] = row
  else
    status[#status + 1] = row
  end

  if ns.Diag and ns.Diag.log then
    ns.Diag.log(("INIT[%s] %s%s"):format(row.name, row.ok and "ok" or "FAIL ", row.ok and "" or row.detail))
  end

  if not row.ok then
    printFail(row)
  end

  return row
end

-- ============================================================
-- runBlock(name, fn) -- pcall-wraps fn(), records one {name, ok,
-- detail} row (replacing any existing row for the same name rather
-- than appending a duplicate, so re-running a block, e.g. from a test,
-- stays idempotent on the STATUS table even though the underlying
-- subsystem calls above are each only ever made once by runAll()).
--
-- Two distinct "not ok" cases, both surfaced as ok=false so a reader of
-- /yabb diag or the Dump INIT section sees every problem the same way:
--   1. fn() raises -- pcall itself returns false; `detail` is the
--      caught error text. This is the case Ascension's error-hiding
--      makes otherwise invisible -- the whole reason this file exists.
--   2. fn() returns falsy without raising -- every subsystem init/start
--      above already degrades this way on purpose (e.g. no CreateFrame
--      global under the test stub, or a genuinely missing WoW API on a
--      live client); `detail` says so explicitly rather than claiming
--      "ok" for a subsystem that quietly never started.
-- fn() returning any truthy value (a frame, or plain `true`) is the
-- only "ok" outcome.
--
-- Pure aside from the pcall itself -- fn is an injected callback, so
-- this is fully unit-testable with fake pass/fail/falsy functions and
-- no WoW global at all (tests/init_spec.lua).
-- ============================================================

function Init.runBlock(name, fn)
  local ok, result = pcall(fn)

  local row
  if not ok then
    row = { name = name, ok = false, detail = tostring(result) }
  elseif not result then
    row = { name = name, ok = false, detail = "did not start (subsystem returned false/nil, no error raised)" }
  else
    row = { name = name, ok = true, detail = "ok" }
  end

  return recordRow(row)
end

-- getStatus() -- defensive copy, array order = first-recorded order
-- (the order BLOCKS lists them). Shape matches what Dump.sectionInit/
-- probeInit expect: array of {name=, ok=boolean, detail=string}.
function Init.getStatus()
  local copy = {}
  for i = 1, #status do
    copy[i] = { name = status[i].name, ok = status[i].ok, detail = status[i].detail }
  end
  return copy
end

-- runAll() -- the deterministic-order pass over every registered block.
-- Called exactly once, below, at the bottom of this file (this file's
-- own self-bootstrap -- it is the last file the TOC loads specifically
-- so every subsystem's init/start function already exists by the time
-- this runs).
--
-- Before calling runBlock, checks ns[b.key]: if that table is nil, the
-- module's own file never ran at all (a load failure -- e.g. Ascension's
-- "Error loading" for a filename its stale in-memory listing can't open
-- -- rather than the module loading fine and its init/start simply
-- declining). That case is recorded directly, bypassing runBlock/fn
-- entirely (fn would just no-op via its own `ns.X and ns.X.init and ...`
-- guard, producing the indistinguishable generic "did not start" text),
-- with a detail string that names the exact file and points at the log.
function Init.runAll()
  for i = 1, #BLOCKS do
    local b = BLOCKS[i]
    if b.key and ns[b.key] == nil then
      recordRow({
        name = b.name,
        ok = false,
        detail = "module not loaded -- YABB/" .. b.key .. ".lua failed to load (see Logs\\FrameXML.log)",
      })
    else
      Init.runBlock(b.name, b.fn)
    end
  end
  return Init.getStatus()
end

-- ns.Diag.getInitStatus() -- the seam Dump.lua's probeInit() prefers
-- the moment it exists. Attached here rather than inside Diag.lua
-- itself since this file owns the recorded data; it only needs the
-- ns.Diag table to already exist, which it does -- Diag.lua loads
-- earlier in the TOC. Guarded so this file still loads clean (just
-- without wiring the seam) in the unlikely event Diag.lua is missing.
if ns.Diag then
  ns.Diag.getInitStatus = Init.getStatus
end

-- ============================================================
-- Defer runAll() to PLAYER_LOGIN: 3.3.5 does not guarantee SavedVariables
-- (YABB_DB) are populated before file load, so calling Init.runAll()
-- synchronously at file load risks persisted settings silently failing
-- to re-register and a saved value (e.g. the minimap angle) resetting
-- every session. PLAYER_LOGIN fires exactly once, after every
-- SavedVariables table is loaded and every frame from the TOC's XML
-- files already exists, so runAll() reading YABB_DB or a TOC-declared
-- frame there is always safe.
--
-- Guarded on CreateFrame so this degrades to the old synchronous
-- behavior wherever the frame API doesn't exist (e.g. tests/ns_stub.lua):
-- Init.lua loads under the pure-Lua stub too, and those specs need
-- runAll() to have actually executed by the time this file returns,
-- with no event loop available to fire PLAYER_LOGIN for them.
--
-- ns.refreshVersion() (Loader.lua) is called here, not at Loader.lua's
-- own module scope, for the same PLAYER_LOGIN-gated reason as runAll()
-- above, and folded into this existing handler rather than a second
-- event frame. Guarded on ns.refreshVersion existing so a Loader.lua
-- load failure can't take Init.lua down with it.
-- ============================================================

-- One-time first-run hint: the success path is otherwise completely
-- silent, and a minimap button that loaded but got hidden by another
-- addon's button collector announces nothing either. Gated on a flag in
-- YABB_DB so it prints exactly once per install, ever -- never repeats,
-- never nags. Runs after YABB_DB is guaranteed populated (PLAYER_LOGIN),
-- same as runAll() above.
local function announceFirstRun()
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  if YABB_DB.introShown then return end
  YABB_DB.introShown = true
  if DEFAULT_CHAT_FRAME then
    pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME,
      ("YABB %s loaded. Type /yabb to open the board, or click the note icon on your minimap."):format(tostring(ns.VERSION)))
  end
end

if CreateFrame then
  local loginFrame = CreateFrame("Frame")
  loginFrame:RegisterEvent("PLAYER_LOGIN")
  loginFrame:SetScript("OnEvent", function()
    if ns.refreshVersion then ns.refreshVersion() end
    Init.runAll()
    announceFirstRun()
  end)
else
  if ns.refreshVersion then ns.refreshVersion() end
  Init.runAll()
  announceFirstRun()
end

return Init
