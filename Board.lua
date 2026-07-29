local ADDON, ns = ...
ns.Board = ns.Board or {}
local Board = ns.Board

local DEFAULT_TTL = 300
local DEFAULT_MAX_ENTRIES = 1000

local BoardMt = { __index = {} }
local M = BoardMt.__index

local NILABLE_CLASSIFICATION_FIELDS = {
  "target", "tier", "posterLevel", "levelFilter", "intentReason",
  "classTag", "classRole", "intent",
}

local function dedupeKey(listing)
  return tostring(listing.poster) .. "\0" .. tostring(listing.target or listing.category)
end

local function clearNilableFields(entry)
  for i = 1, #NILABLE_CLASSIFICATION_FIELDS do
    entry[NILABLE_CLASSIFICATION_FIELDS[i]] = nil
  end
end

local function invalidate(self)
  self.revision = (self.revision or 0) + 1
  self._cacheRevision = -1
  self._sortedAll = nil
  self._sortedByCategory = nil
  self._countsByCategory = nil
end

local function cacheSearchText(entry)
  local raw = entry.rawText
  entry._searchText = type(raw) == "string" and raw:lower() or ""
end

local function removeAt(self, index)
  local entries = self.entries
  local entry = entries[index]
  if not entry then return nil end

  self.byKey[entry._dedupeKey or dedupeKey(entry)] = nil
  for i = index, #entries - 1 do
    entries[i] = entries[i + 1]
  end
  entries[#entries] = nil
  return entry
end

local function enforceCap(self)
  local cap = self.maxEntries
  if type(cap) ~= "number" or cap <= 0 or #self.entries <= cap then return end

  while #self.entries > cap do
    local oldestIndex = 1
    local oldestSeen = self.entries[1] and self.entries[1].lastSeen or math.huge
    for i = 2, #self.entries do
      local seen = self.entries[i].lastSeen or 0
      if seen < oldestSeen then
        oldestSeen = seen
        oldestIndex = i
      end
    end
    removeAt(self, oldestIndex)
  end
end

local function rebuildCaches(self)
  if self._cacheRevision == self.revision and self._sortedAll and self._countsByCategory then
    return
  end

  local all = {}
  local counts = {}
  for i = 1, #self.entries do
    local entry = self.entries[i]
    all[i] = entry
    local cat = entry.category or "Other"
    counts[cat] = (counts[cat] or 0) + 1
  end

  table.sort(all, function(a, b)
    local al, bl = a.lastSeen or 0, b.lastSeen or 0
    if al == bl then return (a.firstSeen or 0) > (b.firstSeen or 0) end
    return al > bl
  end)

  self._sortedAll = all
  self._sortedByCategory = {}
  self._countsByCategory = counts
  self._cacheRevision = self.revision
end

-- opts: { ttl = seconds, maxEntries = count }. ttl 0/nil means never expire.
function Board.new(opts)
  opts = opts or {}
  local ttl = opts.ttl
  if type(ttl) ~= "number" then ttl = DEFAULT_TTL end

  local maxEntries = opts.maxEntries
  if type(maxEntries) ~= "number" then maxEntries = DEFAULT_MAX_ENTRIES end

  local board = {
    ttl = ttl,
    maxEntries = maxEntries,
    entries = {},
    byKey = {},
    revision = 0,
    _cacheRevision = -1,
  }
  return setmetatable(board, BoardMt)
end

function M:add(listing, now)
  local key = dedupeKey(listing)
  local existing = self.byKey[key]
  if existing then
    local firstSeen = existing.firstSeen
    clearNilableFields(existing)
    for k, v in pairs(listing) do existing[k] = v end
    existing.firstSeen = firstSeen
    existing.lastSeen = now
    existing._dedupeKey = key
    cacheSearchText(existing)
    invalidate(self)
    return existing
  end

  local entry = {}
  for k, v in pairs(listing) do entry[k] = v end
  entry.firstSeen = now
  entry.lastSeen = now
  entry._dedupeKey = key
  cacheSearchText(entry)

  self.byKey[key] = entry
  self.entries[#self.entries + 1] = entry
  enforceCap(self)
  invalidate(self)
  return entry
end

function M:setTtl(sec)
  if type(sec) ~= "number" then sec = nil end
  if self.ttl ~= sec then
    self.ttl = sec
    invalidate(self)
  end
end

function M:setMaxEntries(count)
  if type(count) ~= "number" then count = DEFAULT_MAX_ENTRIES end
  count = math.floor(count)
  if count < 0 then count = 0 end
  if self.maxEntries == count then return end
  self.maxEntries = count
  enforceCap(self)
  invalidate(self)
end

-- In-place compaction avoids allocating a fresh array on every sweep.
function M:sweep(now)
  if not self.ttl or self.ttl == 0 then return 0 end

  local entries = self.entries
  local write = 1
  local removed = 0
  for read = 1, #entries do
    local entry = entries[read]
    if now - (entry.lastSeen or now) > self.ttl then
      self.byKey[entry._dedupeKey or dedupeKey(entry)] = nil
      removed = removed + 1
    else
      if write ~= read then entries[write] = entry end
      write = write + 1
    end
  end
  for i = #entries, write, -1 do entries[i] = nil end

  if removed > 0 then invalidate(self) end
  return removed
end

function M:count()
  return #self.entries
end

function M:getRevision()
  return self.revision or 0
end

function M:countsByCategory()
  rebuildCaches(self)
  return self._countsByCategory
end

function M:listFor(category)
  rebuildCaches(self)
  local cached = self._sortedByCategory[category]
  if cached then return cached end

  local list = {}
  local all = self._sortedAll
  for i = 1, #all do
    local entry = all[i]
    if entry.category == category then list[#list + 1] = entry end
  end
  self._sortedByCategory[category] = list
  return list
end

function M:all()
  local list = {}
  for i = 1, #self.entries do list[i] = self.entries[i] end
  return list
end

function M:listAll()
  rebuildCaches(self)
  return self._sortedAll
end

function M:reclassifyAll(C, classifyFn)
  if type(classifyFn) ~= "function" then return 0 end

  local removed = 0
  local kept = {}
  local newByKey = {}
  local slotByKey = {}

  for i = 1, #self.entries do
    local entry = self.entries[i]
    local ok, listing = pcall(classifyFn, entry.rawText,
      { poster = entry.poster, channelName = entry.channelName, guid = entry.guid }, C)

    if ok and listing then
      local firstSeen, lastSeen = entry.firstSeen, entry.lastSeen
      clearNilableFields(entry)
      for k, v in pairs(listing) do entry[k] = v end
      entry.firstSeen = firstSeen
      entry.lastSeen = lastSeen
      cacheSearchText(entry)

      local key = dedupeKey(entry)
      entry._dedupeKey = key
      local occupant = newByKey[key]
      if occupant then
        removed = removed + 1
        if (entry.lastSeen or 0) > (occupant.lastSeen or 0) then
          local slot = slotByKey[key]
          kept[slot] = entry
          newByKey[key] = entry
        end
      else
        kept[#kept + 1] = entry
        slotByKey[key] = #kept
        newByKey[key] = entry
      end
    else
      removed = removed + 1
    end
  end

  self.entries = kept
  self.byKey = newByKey
  enforceCap(self)
  invalidate(self)
  return removed
end

return Board
