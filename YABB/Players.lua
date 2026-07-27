local ADDON, ns = ...
ns.Players = ns.Players or {}
local Players = ns.Players

-- ============================================================
-- Player-info enrichment (class + level) backing the board's class-color
-- and level columns. /who is dead on Ascension (SendWho is
-- server-neutered), so every enrichment path here is free/passive.
--
-- No persistent player cache: a name-keyed SavedVariables cache grew
-- unbounded (thousands of distinct chat senders, no eviction) and was a
-- suspected contributor to client GC lag on panel open. Two independent
-- enrichment paths remain, neither persisted:
--   1. classFor(guid) -- free/synchronous, resolved ON DEMAND at render
--      time (UI.lua's row render, visible rows only) straight off
--      GetPlayerInfoByGUID. Nothing is cached -- the call itself is
--      cheap and synchronous, so there is nothing worth caching.
--   2. levelFor(name) -- reads a transient, session-only, module-local
--      `levels` table topped up by four passive listeners (guild roster,
--      friends list, party/raid roster, target/mouseover unit). Bounded
--      by roster/party/friends size and resets on every /reload or
--      relog -- zero SavedVariables growth, ever.
-- ============================================================

-- keyFor(name) -- the level-map key: lowercased player name. nil/""/
-- non-string collapse to nil so every write/read site can just check the
-- return instead of re-validating name itself.
local function keyFor(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name:lower()
end

-- ============================================================
-- classFor(guid) -- free/synchronous, ON-DEMAND class lookup off a chat
-- listing's own GUID. Never stored anywhere -- called straight from
-- UI.lua's row render for whichever rows are currently visible. Guards
-- BOTH nil and "": the client passes arg12="" (not nil) for no-guid
-- events, and GetPlayerInfoByGUID("") is a hard C error, not a graceful
-- nil return -- proven guard shape from Chattynator-335/Core/Messages.lua
-- :525 (`playerGUID and playerGUID ~= ""`) and :914-916 (same guard, its
-- own comment: "senderGUID is "" (not nil) for no-guid events;
-- GetPlayerInfoByGUID("") C-errors"). Return value #2 is the classFile
-- token (Messages.lua:917) -- proven to work for arbitrary chat senders
-- on this exact client, not just the player themself. pcall-wrapped
-- since this is a live WoW C call.
-- ============================================================
function Players.classFor(guid)
  if guid == nil or guid == "" then return nil end
  if not GetPlayerInfoByGUID then return nil end
  local ok, _, englishClass = pcall(GetPlayerInfoByGUID, guid)
  if not ok or type(englishClass) ~= "string" or englishClass == "" then
    return nil
  end
  return englishClass
end

-- ============================================================
-- levels -- transient, session-only, name-keyed map: {level=, source=}.
-- NEVER persisted -- no code path in this file ever touches YABB_DB.players
-- (the one-time cleanup in Players.init() below only ever nils it). Resets
-- on every /reload or relog, by design.
-- ============================================================
local levels = {}

-- levelFor(name) -> {level=, source=} | nil. Returns a shallow copy so a
-- caller mutating the result can never corrupt the map (same defensive-copy
-- convention the old persistent get() used).
function Players.levelFor(name)
  local k = keyFor(name)
  if not k then return nil end
  local rec = levels[k]
  if not rec then return nil end
  return { level = rec.level, source = rec.source }
end

-- levelCount()/levelsBySource() -- pure diagnostic reads over the
-- transient map, for /yabb cache and /yabb dump's PLAYERS section. Neither
-- is a persistence mechanism -- both just describe the in-memory `levels`
-- table as it stands right now.
function Players.levelCount()
  local n = 0
  for _ in pairs(levels) do n = n + 1 end
  return n
end

function Players.levelsBySource()
  local counts = {}
  for _, rec in pairs(levels) do
    local s = rec.source or "?"
    counts[s] = (counts[s] or 0) + 1
  end
  return counts
end

-- noteLevel(name, level, source) -- writes into the transient `levels`
-- map only (never YABB_DB). Rejects a non-numeric or non-positive level
-- (UnitLevel's out-of-detect-range/??-boss sentinel is -1, not 0 --
-- level>0 covers both) so a garbage top-up call can't stamp a bogus entry.
-- The transient map is session-only + never persisted, but the unit/mouseover
-- top-up can still add a distinct entry per player seen, so cap it so a very
-- long uninterrupted session can't grow the heap unbounded either (the whole
-- point of ditching the persistent cache was to stop unbounded growth). At the
-- ceiling, clear IN PLACE (same table every closure holds) -- guild/party/
-- friend levels re-populate within seconds from their periodic events, so the
-- bound self-heals. NEVER touches YABB_DB.
Players.MAX_LEVELS = 500
local levelsCount = 0

local function noteLevel(name, level, source)
  local k = keyFor(name)
  if not k then return false end
  if type(level) ~= "number" or level <= 0 then return false end
  if levels[k] == nil then
    if levelsCount >= Players.MAX_LEVELS then
      for kk in pairs(levels) do levels[kk] = nil end
      levelsCount = 0
    end
    levelsCount = levelsCount + 1
  end
  levels[k] = { level = level, source = source }
  return true
end

-- ============================================================
-- resolveLevel(rec) -- authoritative-source-ONLY: an authoritative live
-- source (rec.level, from guild/party/friend/unit -- always rendered
-- exact) beats "-" (NEVER "?"). rec is a Players.levelFor()-shaped table
-- (or nil). Returns {text=, source=, exact=} so a caller never has to
-- re-derive the priority itself.
-- ============================================================
function Players.resolveLevel(rec)
  if rec and type(rec.level) == "number" then
    return { text = tostring(rec.level), source = rec.source or "who", exact = true }
  end
  return { text = "-", source = nil, exact = nil }
end

-- ============================================================
-- Free level-source top-ups: guild roster / friends list / party+raid
-- roster / target+mouseover unit, wired as passive listeners on
-- Players.start()'s own frame -- never a forced GuildRoster()/
-- SetGuildRosterShowOffline poll (Ascension monkeypatches the latter into
-- a server addon-message, GlobalOverwrites.lua:16-28), never a pop, never
-- a /who. Grounded 1:1 against FrameXML (GetGuildRosterInfo level=
-- return#4, GetFriendInfo level=return#2/connected=return#5 --
-- FriendsFrame.lua:882,432,2196; GUILD_ROSTER_UPDATE/FRIENDLIST_UPDATE
-- handlers never call Show(), FriendsFrame.lua:1286-1294/1249-1250) and
-- the installed SignalFire (SignalFireUI.lua:5240-5252
-- GetGuildRosterInfo/GetFriendInfo shape, BronzeLFG.lua:16145/16468
-- `UnitLevel(unit) or 0` over party/raid, proving the passive-only
-- pattern works pop-free on this exact client). Every source tags
-- noteLevel's `source` argument so the UI can label WHERE a level came
-- from (resolveLevel's own header).
-- ============================================================

local TOPUP_CAP = 512 -- SignalFireUI.lua's own min(512, count) roster cap

local function topUpGuild()
  if not (GetNumGuildMembers and GetGuildRosterInfo) then return end
  local ok, n = pcall(GetNumGuildMembers)
  if not ok then return end
  n = math.min(TOPUP_CAP, tonumber(n) or 0)
  for i = 1, n do
    -- 11-value FrameXML shape (FriendsFrame.lua:882/963): name, rank,
    -- rankIndex, level, class, zone, note, officernote, online, status,
    -- classFileName. Class is deliberately ignored here -- classFor(guid)
    -- is the sole class source now, and guild-roster rows carry no GUID.
    local ok2, name, _rank, _rankIndex, level = pcall(GetGuildRosterInfo, i)
    if ok2 and type(name) == "string" and name ~= "" and type(level) == "number" and level > 0 then
      noteLevel(name, level, "guild")
    end
  end
end

local function topUpFriends()
  if not (GetNumFriends and GetFriendInfo) then return end
  local ok, n = pcall(GetNumFriends)
  if not ok then return end
  n = tonumber(n) or 0
  for i = 1, n do
    local ok2, name, level, _class, _area, connected = pcall(GetFriendInfo, i)
    if ok2 and type(name) == "string" and name ~= "" and connected
        and type(level) == "number" and level > 0 then
      noteLevel(name, level, "friend")
    end
  end
end

local function safeCount(fn)
  if not fn then return 0 end
  local ok, n = pcall(fn)
  if ok and type(n) == "number" then return n end
  return 0
end

local function topUpUnit(unit)
  local okName, name = pcall(UnitName, unit)
  local okLvl, level = pcall(UnitLevel, unit)
  if okName and okLvl and type(name) == "string" and name ~= ""
      and type(level) == "number" and level > 0 then
    noteLevel(name, level, "party")
  end
end

local function topUpGroup()
  if not (UnitName and UnitLevel) then return end
  local nr = safeCount(GetNumRaidMembers)
  if nr > 0 then
    for i = 1, nr do topUpUnit("raid" .. i) end
  else
    local np = safeCount(GetNumPartyMembers)
    for i = 1, np do topUpUnit("party" .. i) end
  end
end

-- topUpFromUnit(unit) -- opportunistic, passive UnitLevel top-up on
-- whichever unit the player happens to target or mouseover. Modeled
-- exactly on topUpUnit above, just its own named function (exposed) since
-- it's driven by different events (PLAYER_TARGET_CHANGED/
-- UPDATE_MOUSEOVER_UNIT below, not a roster-change event) and tags its
-- own "unit" source rather than "party". Guards UnitGUID BOTH nil AND ""
-- (hard project rule, same shape as classFor's own guid guard above) even
-- though a real unit token generally has one; pcall-wrapped per-call since
-- every Unit* read here is a live WoW C call. Rejects level<=0 --
-- UnitLevel's own out-of-detect-range/??-boss sentinel is -1, not 0; the
-- level>0 guard already covers both, do not relax it to >=0.
local function topUpFromUnit(unit)
  if not (UnitName and UnitLevel and UnitGUID) then return end
  local okG, guid = pcall(UnitGUID, unit)
  if not okG or guid == nil or guid == "" then return end
  local okName, name = pcall(UnitName, unit)
  local okLvl, level = pcall(UnitLevel, unit)
  if okName and okLvl and type(name) == "string" and name ~= ""
      and type(level) == "number" and level > 0 then
    noteLevel(name, level, "unit")
  end
end

-- Exposed (not local) purely so tests can call each top-up pass directly
-- against injected fake WoW globals without needing a live OnEvent fire.
Players.topUpGuild = topUpGuild
Players.topUpFriends = topUpFriends
Players.topUpGroup = topUpGroup
Players.topUpFromUnit = topUpFromUnit

-- ============================================================
-- start()/init() -- live wiring. start() registers the driver frame
-- (guarded on CreateFrame, so a no-op under the test stub, same
-- convention as Ingest.start()/Compat.after()) for the free top-up
-- events ONLY -- WHO_LIST_UPDATE is never registered here, and never will
-- be: /who is dead on Ascension (SendWho is server-neutered). init() is
-- the single entry point Init.lua's orchestrator calls.
-- ============================================================

-- session-only flag recording whether Players.init() actually ran --
-- distinct from the module simply existing (ns.Players truthy). Surfaced
-- in /yabb dump's PLAYERS section so a load-but-never-initialized module
-- is distinguishable from one that never loaded at all.
local didInit = false

function Players.initRan()
  return didInit
end

function Players.start()
  if not CreateFrame then
    return nil
  end

  local frame = CreateFrame("Frame")
  frame:RegisterEvent("GUILD_ROSTER_UPDATE")
  frame:RegisterEvent("FRIENDLIST_UPDATE")
  frame:RegisterEvent("PARTY_MEMBERS_CHANGED")
  frame:RegisterEvent("RAID_ROSTER_UPDATE")
  frame:RegisterEvent("PLAYER_TARGET_CHANGED")
  frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "GUILD_ROSTER_UPDATE" then
      pcall(topUpGuild)
    elseif event == "FRIENDLIST_UPDATE" then
      pcall(topUpFriends)
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
      pcall(topUpGroup)
    elseif event == "PLAYER_TARGET_CHANGED" then
      pcall(topUpFromUnit, "target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
      pcall(topUpFromUnit, "mouseover")
    end
  end)

  Players.frame = frame
  return frame
end

function Players.init()
  didInit = true
  -- One-time cleanup: clear any cache a previous version persisted.
  -- Guarded on YABB_DB existing (it may not, on a brand-new install, or
  -- under the test stub) -- referencing/assigning it is never an error
  -- even then, unlike calling a missing C function.
  if YABB_DB then
    YABB_DB.players = nil
  end
  return Players.start()
end

return Players
