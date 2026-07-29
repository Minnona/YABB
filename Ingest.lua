local ADDON, ns = ...
ns.Ingest = ns.Ingest or {}
local Ingest = ns.Ingest

-- ============================================================
-- Live chat ingestion: CHAT_MSG_CHANNEL/GUILD/OFFICER -> Classifier
-- -> Board, plus per-channel opt-out and joined-channel enumeration.
-- The arg-extraction + opt-out logic below is pure Lua (no WoW global
-- touched directly by onChannelMsg/onGuildMsg/onOfficerMsg/
-- isChannelEnabled/setChannelEnabled) and is TDD'd under lua5.1 via
-- injected fake event args (tests/ingest_spec.lua). Only Ingest.start()
-- and Ingest.now() reference WoW globals, and only inside guarded
-- function bodies (see Loader.lua for the load-scope convention).
-- ============================================================

-- ============================================================
-- now() -- guarded time source for board timestamps. GetTime doesn't
-- exist under the test stub; falls back to 0 there instead of
-- erroring. Never called at module load -- only from inside
-- onChannelMsg/onGuildMsg/onOfficerMsg's own call, so tests can also
-- override Ingest.now directly to inject a deterministic fake clock.
-- ============================================================

function Ingest.now()
  if GetTime then
    return GetTime()
  end
  return 0
end

-- ============================================================
-- ns.board -- the single board instance this module reads/writes.
-- Board.new() is pure Lua (no WoW global), so creating it here at
-- module load is safe under the stub. Tests swap ns.board for a stub
-- table exposing an add(self, listing, now) method so onChannelMsg/
-- onGuildMsg/onOfficerMsg can be asserted on without depending on
-- Board.lua's real dedupe/TTL behavior.
-- ============================================================

ns.board = ns.board or ns.Board.new()

-- ============================================================
-- per-channel opt-out, persisted to YABB_DB.channels[name]. Default
-- is enabled: a channel absent from the table (never configured, or
-- never explicitly disabled) reads as enabled. Only an explicit
-- `false` disables it. YABB_DB is a plain SavedVariables global --
-- referencing/assigning it is never an error even when WoW hasn't
-- populated it yet (or under the stub, where it's simply nil), unlike
-- calling a missing C function.
--
-- Type-guarded rather than a bare `or {}`: this runs from
-- isChannelEnabled, called on every CHAT_MSG_CHANNEL/GUILD/OFFICER
-- event, so a hand-corrupted or hostile-imported YABB_DB.channels
-- (not a table) would otherwise error on every chat line the player
-- sees. A non-table value is replaced with a fresh table instead.
-- ============================================================

local function db()
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  if type(YABB_DB.channels) ~= "table" then YABB_DB.channels = {} end
  return YABB_DB
end

function Ingest.isChannelEnabled(name)
  if not name then return true end
  local v = db().channels[name]
  if v == nil then return true end
  return v ~= false
end

function Ingest.setChannelEnabled(name, enabled)
  if not name then return end
  db().channels[name] = enabled and true or false
end

-- ============================================================
-- classifyAndAdd(channelName, msg, sender, guid) -- shared core of
-- onChannelMsg/onGuildMsg/onOfficerMsg: skip if the channel is
-- opted-out, classify, skip again if the line is rejected, otherwise
-- add to the board and return whatever board:add returns (the
-- listing that ended up on the board), or nil on either skip.
--
-- Verbose hook (/yabb log on|off): when ns.Diag.verbose is set, every
-- decision (accept OR reject) is also pushed to the Diag ring buffer
-- via ns.Diag.formatListing/formatReject -- the same formatters
-- /yabb parse uses -- so /yabb dump's CLASSIFIER section reflects
-- real live traffic, not just manual /yabb parse probes. Guarded on
-- ns.Diag existing at all so this is a no-op, never an error,
-- whenever Diag.lua isn't loaded (e.g. a narrower test module load).
-- ============================================================

local function classifyAndAdd(channelName, msg, sender, guid)
  if not Ingest.isChannelEnabled(channelName) then
    return nil
  end
  local listing, reason = ns.Classifier.classify(msg, { poster = sender, channelName = channelName, guid = guid }, ns.C)
  if not listing then
    if ns.Diag and ns.Diag.verbose and ns.Diag.log and ns.Diag.formatReject then
      ns.Diag.log("INGEST[" .. tostring(channelName) .. "] " .. ns.Diag.formatReject(reason))
    end
    -- Tuning capture (additive, guarded): only "nearmiss" rejects are
    -- worth logging (real review candidates) -- spam/tooShort/gibberish/
    -- notLFG are deliberately NOT recorded, keeping the log high-signal.
    if ns.Capture and YABB_DB and reason == "nearmiss" then
      ns.Capture.record(YABB_DB, { c = channelName, p = sender, v = "nearmiss", t = "nearmiss", r = msg })
    end
    return nil
  end
  local entry = ns.board:add(listing, Ingest.now())
  if ns.Diag and ns.Diag.verbose and ns.Diag.log and ns.Diag.formatListing then
    ns.Diag.log("INGEST[" .. tostring(channelName) .. "] poster=" .. tostring(sender) .. " " ..
      ns.Diag.formatListing(listing))
  end
  -- Tuning capture (additive, guarded): mirrors the reject-side hook
  -- above -- never changes the return value or board:add above it.
  if ns.Capture and YABB_DB then
    if listing.category == "Other" then
      ns.Capture.record(YABB_DB, { c = channelName, p = sender, v = "other", t = "Other", r = msg })
    else
      ns.Capture.record(YABB_DB, {
        c = channelName, p = sender, v = "accept",
        t = listing.category .. (listing.target and (" / " .. listing.target) or ""),
        r = msg,
      })
    end
  end
  return entry
end

-- ============================================================
-- onChannelMsg(...) -- CHAT_MSG_CHANNEL is 12 args on this client.
-- arg2=sender, arg9=channelName (KEY ON THIS -- not arg8's numeric
-- channelIndex or arg4's decorated "1. Trade - Orgrimmar" string),
-- arg12=guid (byte-confirmed against ChannelDocumentation.lua and
-- GroupBulletinBoard's live destructure). Pure-testable: takes the
-- raw event args and returns the listing added to the board, or nil
-- if skipped (opted-out channel or rejected line).
-- ============================================================

function Ingest.onChannelMsg(msg, sender, _3, _4, _5, _6, _7, _channelIndex, channelName, _10, _11, guid)
  return classifyAndAdd(channelName, msg, sender, guid)
end

-- ============================================================
-- onGuildMsg/onOfficerMsg -- CHAT_MSG_GUILD/CHAT_MSG_OFFICER are 11
-- args, sender at arg2, no guid. Synthetic channelName ("Guild"/
-- "Officer") stands in for the real per-channel name so the same
-- opt-out + board pipeline covers guild/officer chat.
-- ============================================================

function Ingest.onGuildMsg(msg, sender)
  return classifyAndAdd("Guild", msg, sender, nil)
end

function Ingest.onOfficerMsg(msg, sender)
  return classifyAndAdd("Officer", msg, sender, nil)
end

-- ============================================================
-- start() -- registers the live event frame. Guarded on CreateFrame
-- so this is a no-op under the stub (and on anything else missing
-- the WoW frame API) instead of erroring; the call site pcall-wraps
-- it too as a second line of defense. Refreshes the joined-channel
-- list (ns.Compat.getJoinedChannels()) on CHANNEL_UI_UPDATE and
-- PLAYER_ENTERING_WORLD.
-- ============================================================

Ingest.channels = Ingest.channels or {}

local function refreshChannels()
  Ingest.channels = ns.Compat.getJoinedChannels()
end

-- ============================================================
-- Periodic board sweep: UI.lua's Refresh() sweeps the board on its own
-- throttled tick, but that only runs while the board window is actually
-- shown -- OnUpdate never fires on a hidden frame. This is the companion
-- path so a closed board still prunes: an accumulator on this module's
-- own event frame's OnUpdate (that frame is always shown/ticking once
-- Ingest.start() has created it, independent of the UI window),
-- throttled to a ~30s cadence rather than sweeping on every chat line
-- (the TTL is measured in minutes, so anything finer than tens of
-- seconds is wasted work).
-- ============================================================
local SWEEP_INTERVAL = 30
local sweepAccum = 0

local function tickSweep(elapsed)
  sweepAccum = sweepAccum + (elapsed or 0)
  if sweepAccum < SWEEP_INTERVAL then return end
  sweepAccum = 0
  if ns.board and ns.board.sweep then
    ns.board:sweep(Ingest.now())
  end
end

function Ingest.start()
  if not CreateFrame then
    return
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent("CHAT_MSG_CHANNEL")
  frame:RegisterEvent("CHAT_MSG_GUILD")
  frame:RegisterEvent("CHAT_MSG_OFFICER")
  frame:RegisterEvent("CHANNEL_UI_UPDATE")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")

  frame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_CHANNEL" then
      Ingest.onChannelMsg(...)
    elseif event == "CHAT_MSG_GUILD" then
      Ingest.onGuildMsg(...)
    elseif event == "CHAT_MSG_OFFICER" then
      Ingest.onOfficerMsg(...)
    elseif event == "CHANNEL_UI_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
      refreshChannels()
    end
  end)

  frame:SetScript("OnUpdate", function(_, elapsed)
    tickSweep(elapsed)
  end)

  Ingest.frame = frame
  return frame
end

-- Ingest.start() is invoked exactly once by Init.lua's central
-- orchestrator, which loads last in the TOC after every subsystem
-- exists. It is NOT idempotent -- it unconditionally creates and
-- registers a brand new event frame every call -- so it must never be
-- invoked from anywhere else; see Init.lua's header for ordering.

return Ingest
