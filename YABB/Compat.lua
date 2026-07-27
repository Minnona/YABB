local ADDON, ns = ...
ns.Compat = ns.Compat or {}
local Compat = ns.Compat

-- ============================================================
-- 3.3.5a/Ascension shim layer (see Loader.lua for the load-scope
-- convention every file here follows). These functions are grounded
-- in prior art working on this exact client, cited per-function
-- below, rather than tested against a mock client.
-- ============================================================

-- ============================================================
-- parseChannelList(...) -- pure, TDD'd.
-- GetChannelList() is 2-stride on this client (index,name,index,
-- name,...), NOT retail's 3-stride (Chattynator Core/Messages.lua:
-- 739-741 documents the same stride bug; GroupBulletinBoard/
-- Chat.lua:14-18 `for i=1,#channelList,2` iterates it the same
-- way). Takes the raw varargs so the live call site can pass
-- GetChannelList() straight through.
-- ============================================================

function Compat.parseChannelList(...)
  local n = select("#", ...)
  local list = {}
  for i = 1, n, 2 do
    local index, name = select(i, ...)
    list[#list + 1] = { index = index, name = name }
  end
  return list
end

-- getJoinedChannels() -- live call site for parseChannelList. Guarded
-- so a client/stub without GetChannelList degrades to an empty list
-- instead of erroring.
function Compat.getJoinedChannels()
  if GetChannelList then
    return Compat.parseChannelList(GetChannelList())
  end
  return {}
end

-- ============================================================
-- playerInfo(guid) -- guards BOTH nil and "" before ever touching
-- GetPlayerInfoByGUID: the client sends arg12="" (not nil) on chat
-- events with no guid, and calling GetPlayerInfoByGUID("") is a hard
-- C error, not a graceful nil return. Model: Chattynator-335
-- Core/Messages.lua:523-529 (`playerGUID and playerGUID ~= ""`
-- guard, same comment).
-- ============================================================

function Compat.playerInfo(guid)
  if guid == nil or guid == "" then
    return nil
  end
  if GetPlayerInfoByGUID then
    return GetPlayerInfoByGUID(guid)
  end
  return nil
end

-- ============================================================
-- classColor(classFilename) -- chains the CLIENT's own class-color
-- tables, CUSTOM_CLASS_COLORS -> RAID_CLASS_COLORS -> grey, proven
-- shape from Chattynator-335/Core/Messages.lua:922-924 and
-- Chattynator-335/Modifiers/ClassColors.lua:12-14 (identical chain in
-- both places). A hardcoded 10-class Vanilla/Wrath table has no entry
-- for Ascension/CoA's custom class tokens (Necromancer/Tinker/
-- Cultist/Starcaller/...), so those posters would fall through to
-- grey -- reading the client's own tables avoids that. Every table
-- read is guarded (`CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token]`,
-- `c.r or 0` when formatting) so a malformed/missing color entry can
-- never index-crash the render path.
--
-- CLASS_COLOR_HEX below is only the fallback for when BOTH client
-- globals are entirely absent (e.g. this file's own plain-Lua test
-- stub, which has neither) -- never consulted when either global
-- exists but simply lacks a given token, since grey is the correct,
-- client-matching answer there. Hex values from GroupBulletinBoard/
-- Backport.lua:21-32.
-- ============================================================

local CLASS_COLOR_HEX = {
  DEATHKNIGHT = "c41f3b",
  DRUID       = "ff7d0a",
  HUNTER      = "abd473",
  MAGE        = "3fc7eb",
  PALADIN     = "f58cba",
  PRIEST      = "ffffff",
  ROGUE       = "fff569",
  SHAMAN      = "0070de",
  WARLOCK     = "8788ee",
  WARRIOR     = "c79c6e",
}

local GREY_CLASS_COLOR = { r = 0.62, g = 0.62, b = 0.62, hex = "9d9d9d" }

function Compat.classColor(classFilename)
  if type(classFilename) ~= "string" then
    return GREY_CLASS_COLOR
  end
  local token = classFilename:upper()

  if CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS then
    -- 3.3.5: these tables are plain {r,g,b}, no ColorMixin/CreateColor
    -- methods (Chattynator-335 Modifiers/ClassColors.lua:15) -- format
    -- the hex directly rather than calling any method on c.
    local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[token])
      or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[token])
    if not c then
      return GREY_CLASS_COLOR
    end
    return {
      r = c.r,
      g = c.g,
      b = c.b,
      hex = ("%02x%02x%02x"):format((c.r or 0) * 255, (c.g or 0) * 255, (c.b or 0) * 255),
    }
  end

  local hex = CLASS_COLOR_HEX[token]
  if not hex then
    return GREY_CLASS_COLOR
  end
  return {
    r = tonumber(hex:sub(1, 2), 16) / 255,
    g = tonumber(hex:sub(3, 4), 16) / 255,
    b = tonumber(hex:sub(5, 6), 16) / 255,
    hex = hex,
  }
end

-- ============================================================
-- isInGroup() -- this client has no IsInGroup()/GetNumGroupMembers;
-- derive it from the era party/raid counts. Model: GroupBulletinBoard
-- /Backport.lua:93-108 (api.IsInParty/IsInRaid/IsInGroup built on
-- GetNumRaidMembers/GetNumPartyMembers) and TipTac335_Compat.lua:
-- 781-787 (`IsInGroup` shim, same two calls, each individually
-- guarded with `and ... or 0` so an absent global degrades safely
-- instead of erroring).
-- ============================================================

function Compat.isInGroup()
  local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
  local party = GetNumPartyMembers and GetNumPartyMembers() or 0
  return raid > 0 or party > 0
end

-- ============================================================
-- after(sec, fn) -- one-shot timer via an OnUpdate accumulator
-- frame; this client has no C_Timer.After. Model: TipTac335_Compat
-- .lua's C_Timer shim (TipTac-335/TipTac/TipTac335_Compat.lua:
-- 414-465) -- a single lazily-created driver frame, a flat list of
-- pending entries, OnUpdate walks the list and pcalls each due
-- callback so one bad callback can't break the driver or the others
-- queued behind it. Simplified to elapsed-time accumulation (OnUpdate's
-- own `elapsed` parameter) rather than the shim's GetTime()-deadline
-- scheme, since a plain accumulator needs no extra guarded global.
-- CreateFrame is only ever referenced inside this function, and only
-- on the first call that actually needs the driver, so the module
-- still loads with zero WoW globals touched at load time.
-- ============================================================

local scheduled = {}
local driver

local function onUpdate(self, elapsed)
  local i = 1
  while i <= #scheduled do
    local entry = scheduled[i]
    entry.remaining = entry.remaining - elapsed
    if entry.remaining <= 0 then
      table.remove(scheduled, i)
      pcall(entry.fn)
    else
      i = i + 1
    end
  end
end

function Compat.after(sec, fn)
  if type(fn) ~= "function" then
    return
  end
  if not CreateFrame then
    return
  end
  if not driver then
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", onUpdate)
  end
  scheduled[#scheduled + 1] = { remaining = tonumber(sec) or 0, fn = fn }
end

-- ============================================================
-- applyBackdrop(frame, opts) -- native frame:SetBackdrop{...} only.
--
-- NEVER pass "BackdropTemplate" to CreateFrame on this client, and
-- never via the usual nil-safe `BackdropTemplateMixin and
-- "BackdropTemplate" or nil` ternary either: Ascension DEFINES
-- BackdropTemplateMixin, so the ternary resolves truthy and silently
-- routes every SetBackdrop call into a broken Lua NineSlice backport.
-- The result is a purely visual defect -- no Lua error, no failed
-- call -- so it survives every automated check and is only visible
-- in-game. Model: HidingBar-335/HidingBar/HidingBar.lua:3111
-- (`CreateFrame("BUTTON", nil, UIParent)` with no template) and
-- Cell_Ascension/Utils.lua:2471-2474 (`CreateFrame("Frame", name,
-- parent, nil)` then native SetBackdrop{bgFile=...}).
--
-- SetBackdrop / SetBackdropColor / SetBackdropBorderColor are native
-- C methods on every 3.3.5 frame regardless of template, so a plain
-- template-less CreateFrame already has everything this needs.
-- Callers own frame creation; this only ever calls methods on the
-- frame it is given.
-- ============================================================

-- ============================================================
-- ROLE_ICON / ROLE_TEXCOORD -- the standard WotLK LFG role-icon
-- atlas, unchanged on Ascension (single client-shipped texture,
-- not addon-provided, so it's data not a shim). ROLE_TEXCOORD is the
-- output of Ascension's own GetTexCoordsForRoleSmallCircle(), which
-- pairs with the small-icon PORTRAITROLES atlas -- NOT UI-LFG-ICON-
-- ROLES, a differently-laid-out 256x256 atlas sized for 36-40px queue
-- buttons. Confirmed by the installed ShadowedUnitFrames/indicators.lua
-- using PORTRAITROLES with these exact texcoords; verify in-game via
-- /yabb dump.
-- ============================================================

Compat.ROLE_ICON = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

Compat.ROLE_TEXCOORD = {
  TANK = {0, 0.296875, 0.34375, 0.640625},
  HEAL = {0.3125, 0.609375, 0.015625, 0.3125},
  DPS  = {0.3125, 0.609375, 0.34375, 0.640625},
}

function Compat.applyBackdrop(frame, opts)
  if not frame or not frame.SetBackdrop then
    return
  end
  opts = opts or {}
  frame:SetBackdrop({
    bgFile = opts.bgFile,
    edgeFile = opts.edgeFile,
    tile = opts.tile,
    tileSize = opts.tileSize,
    edgeSize = opts.edgeSize,
    insets = opts.insets,
  })
  if opts.bgColor and frame.SetBackdropColor then
    frame:SetBackdropColor(unpack(opts.bgColor))
  end
  if opts.borderColor and frame.SetBackdropBorderColor then
    frame:SetBackdropBorderColor(unpack(opts.borderColor))
  end
end

-- ============================================================
-- guard(fn, tag) -- pcalls fn and swallows the error. By default this is
-- byte-identical to a bare pcall: the error is only actually captured
-- when the player has turned on verbose logging (`/yabb log on`), at
-- which point it's pushed to the Diag ring buffer tagged with `tag` so
-- it shows up in `/yabb dump`. That's a deliberate trade -- a player's
-- client can't be watched over their shoulder, and logging every UI-side
-- failure unconditionally would grow the ring buffer from routine,
-- expected pcall trips (a listing mid-teardown, a stale row reference)
-- as much as from real bugs -- but it means this call site alone buys
-- nothing for a bug report unless the reporter was already told to run
-- `/yabb log on` first. `tag` should name the call site (e.g.
-- "UI.updateScrollbar").
-- ============================================================

function Compat.guard(fn, tag)
  local ok, err = pcall(fn)
  if not ok and ns.Diag and ns.Diag.verbose and ns.Diag.log then
    ns.Diag.log(tostring(tag) .. ": " .. tostring(err))
  end
  return ok
end

return Compat
