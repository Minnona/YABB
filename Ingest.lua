local ADDON, ns = ...
ns.Ingest = ns.Ingest or {}
local Ingest = ns.Ingest

function Ingest.now()
  if GetTime then return GetTime() end
  return 0
end

ns.board = ns.board or ns.Board.new()

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

local function captureEnabled()
  return ns.Capture and ns.Capture.isOn and type(YABB_DB) == "table"
    and ns.Capture.isOn(YABB_DB)
end

local function classifyAndAdd(channelName, msg, sender, guid)
  if not Ingest.isChannelEnabled(channelName) then return nil end

  local listing, reason = ns.Classifier.classify(msg,
    { poster = sender, channelName = channelName, guid = guid }, ns.C)

  if not listing then
    if ns.Diag and ns.Diag.verbose and ns.Diag.log and ns.Diag.formatReject then
      ns.Diag.log("INGEST[" .. tostring(channelName) .. "] " .. ns.Diag.formatReject(reason))
    end
    -- Check the feature flag before constructing a capture record. Capture is
    -- disabled by default, so the normal chat path now allocates nothing here.
    if reason == "nearmiss" and captureEnabled() then
      ns.Capture.record(YABB_DB, {
        c = channelName, p = sender, v = "nearmiss", t = "nearmiss", r = msg,
      })
    end
    return nil
  end

  local entry = ns.board:add(listing, Ingest.now())
  if ns.Diag and ns.Diag.verbose and ns.Diag.log and ns.Diag.formatListing then
    ns.Diag.log("INGEST[" .. tostring(channelName) .. "] poster=" .. tostring(sender) .. " " ..
      ns.Diag.formatListing(listing))
  end

  if captureEnabled() then
    if listing.category == "Other" then
      ns.Capture.record(YABB_DB, {
        c = channelName, p = sender, v = "other", t = "Other", r = msg,
      })
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

function Ingest.onChannelMsg(msg, sender, _3, _4, _5, _6, _7, _channelIndex, channelName, _10, _11, guid)
  return classifyAndAdd(channelName, msg, sender, guid)
end

function Ingest.onGuildMsg(msg, sender)
  return classifyAndAdd("Guild", msg, sender, nil)
end

function Ingest.onOfficerMsg(msg, sender)
  return classifyAndAdd("Officer", msg, sender, nil)
end

Ingest.channels = Ingest.channels or {}

local function refreshChannels()
  Ingest.channels = ns.Compat.getJoinedChannels()
end

local SWEEP_INTERVAL = 30
local sweepAccum = 0

local function tickSweep(elapsed)
  sweepAccum = sweepAccum + (elapsed or 0)
  if sweepAccum < SWEEP_INTERVAL then return end
  -- Preserve overshoot instead of resetting to zero, so a long frame does not
  -- gradually drift the sweep cadence.
  sweepAccum = sweepAccum - SWEEP_INTERVAL
  if ns.board and ns.board.sweep then ns.board:sweep(Ingest.now()) end
end

function Ingest.start()
  if not CreateFrame then return end
  if Ingest.frame then return Ingest.frame end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent("CHAT_MSG_CHANNEL")
  frame:RegisterEvent("CHAT_MSG_GUILD")
  frame:RegisterEvent("CHAT_MSG_OFFICER")
  frame:RegisterEvent("CHANNEL_UI_UPDATE")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")

  frame:SetScript("OnEvent", function(_, event, ...)
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

  frame:SetScript("OnUpdate", function(_, elapsed) tickSweep(elapsed) end)
  Ingest.frame = frame
  return frame
end

return Ingest
