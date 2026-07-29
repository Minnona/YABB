local ADDON, ns = ...
ns.Performance = ns.Performance or {}
local Performance = ns.Performance

local CLASS_CACHE_CAP = 512

-- ============================================================
-- Player presentation caches. All caches are session-only and bounded.
-- ============================================================
local function optimisePlayers()
  local Players = ns.Players
  if not Players or Players._performanceOptimised then return end
  Players._performanceOptimised = true

  if type(Players.classFor) == "function" then
    local baseClassFor = Players.classFor
    local cache, order = {}, {}
    local nextSlot, size = 1, 0

    Players.classFor = function(guid)
      if guid == nil or guid == "" then return nil end
      local hit = cache[guid]
      if hit then return hit end

      local class = baseClassFor(guid)
      if not class then return nil end

      if size < CLASS_CACHE_CAP then
        size = size + 1
        order[size] = guid
      else
        local old = order[nextSlot]
        if old then cache[old] = nil end
        order[nextSlot] = guid
        nextSlot = (nextSlot % CLASS_CACHE_CAP) + 1
      end
      cache[guid] = class
      return class
    end
  end

  if type(Players.levelFor) == "function" then
    local baseLevelFor = Players.levelFor
    local baseResolveLevel = Players.resolveLevel
    local MISS = {}
    local UNKNOWN = { text = "-", source = nil, exact = nil }
    local levelCache = {}
    local resolvedCache = setmetatable({}, { __mode = "k" })

    local function clearLevelCache()
      levelCache = {}
      resolvedCache = setmetatable({}, { __mode = "k" })
    end
    Players.clearLevelReadCache = clearLevelCache

    Players.levelFor = function(name)
      if type(name) ~= "string" or name == "" then return nil end
      local key = name:lower()
      local cached = levelCache[key]
      if cached ~= nil then return cached ~= MISS and cached or nil end
      local rec = baseLevelFor(name)
      levelCache[key] = rec or MISS
      return rec
    end

    if type(baseResolveLevel) == "function" then
      Players.resolveLevel = function(rec)
        if not rec then return UNKNOWN end
        local cached = resolvedCache[rec]
        if cached then return cached end
        local result = baseResolveLevel(rec)
        resolvedCache[rec] = result
        return result
      end
    end

    local function wrapTopUp(name)
      local base = Players[name]
      if type(base) ~= "function" then return end
      Players[name] = function(...)
        local result = base(...)
        clearLevelCache()
        return result
      end
    end
    wrapTopUp("topUpGuild")
    wrapTopUp("topUpFriends")
    wrapTopUp("topUpGroup")
    wrapTopUp("topUpFromUnit")

    if type(Players.init) == "function" then
      local baseInit = Players.init
      Players.init = function(...)
        local frame = baseInit(...)
        if frame and frame.HookScript and not frame._yabbPerfLevelHook then
          frame._yabbPerfLevelHook = true
          frame:HookScript("OnEvent", function() clearLevelCache() end)
        end
        return frame
      end
    end
  end
end

optimisePlayers()

return Performance
