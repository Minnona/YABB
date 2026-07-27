local ADDON, ns = ...
ns.Board = ns.Board or {}
local Board = ns.Board

local DEFAULT_TTL = 300

local BoardMt = { __index = {} }
local M = BoardMt.__index

local function dedupeKey(listing)
  return tostring(listing.poster).."\0"..tostring(listing.target or listing.category)
end

-- Fields Classifier.classify emits CONDITIONALLY -- nil/absent from the
-- returned listing when the current line/rules don't produce them (e.g.
-- target is nil once a rule stops resolving a dungeon, intent is nil for
-- an ambiguous follow-up line). A plain `for k,v in pairs(listing) do
-- entry[k]=v end` merge never visits a key that's missing from listing,
-- so a stale value from a PRIOR classification would otherwise survive a
-- merge -- e.g. a poster's explicit "LFM" tag surviving on a later,
-- vaguer follow-up line from the same person, which is worse than
-- showing no tag at all. Both M:add and M:reclassifyAll clear these on
-- the entry before merging the new listing over it.
--
-- "guid" is deliberately NOT in this list: it identifies the poster, not
-- a per-line classification result. CHAT_MSG_GUILD/OFFICER carry no guid
-- (Ingest.onGuildMsg passes nil), so a guild follow-up merging onto an
-- existing channel listing must keep that listing's guid rather than
-- losing it -- clearing it here would silently drop the poster's class
-- color and tooltip class line for the rest of the entry's TTL.
local NILABLE_CLASSIFICATION_FIELDS = {
  "target", "tier", "posterLevel", "levelFilter", "intentReason",
  "classTag", "classRole", "intent",
}

local function clearNilableFields(entry)
  for i = 1, #NILABLE_CLASSIFICATION_FIELDS do
    entry[NILABLE_CLASSIFICATION_FIELDS[i]] = nil
  end
end

-- opts optional: {ttl=300}. A non-number opts.ttl coerces to DEFAULT_TTL
-- rather than being stored as-is -- the same kind of defensive coercion
-- setTtl below performs -- so a bad opts.ttl can never reach sweep's
-- `now - entry.lastSeen > self.ttl` compare and throw.
function Board.new(opts)
  opts = opts or {}
  local ttl = opts.ttl
  if type(ttl) ~= "number" then ttl = DEFAULT_TTL end
  local board = {
    ttl = ttl,
    entries = {},        -- array of entry tables (each entry = the listing, plus firstSeen/lastSeen)
    byKey = {},           -- key -> entry
  }
  return setmetatable(board, BoardMt)
end

-- insert or combine; stamps firstSeen/lastSeen
function M:add(listing, now)
  local key = dedupeKey(listing)
  local existing = self.byKey[key]
  if existing then
    -- Same key always maps to one entry: refresh in place. Merge the
    -- newer listing's fields over the existing entry (needCounts/roles
    -- take the newer values), but keep the original firstSeen.
    local firstSeen = existing.firstSeen
    clearNilableFields(existing)
    for k, v in pairs(listing) do
      existing[k] = v
    end
    existing.firstSeen = firstSeen
    existing.lastSeen = now
    return existing
  end

  local entry = {}
  for k, v in pairs(listing) do
    entry[k] = v
  end
  entry.firstSeen = now
  entry.lastSeen = now
  self.byKey[key] = entry
  self.entries[#self.entries + 1] = entry
  return entry
end

-- configurable TTL (seconds). 0/nil = never expire (sweep becomes a no-op).
-- A non-number coerces to nil (never-expire) rather than being stored:
-- sweep does `now - entry.lastSeen > self.ttl`, which throws on a
-- string/table, and this is one of the two seams a ttl can enter a board
-- through -- the other is Board.new's opts.ttl, which coerces a
-- non-number to DEFAULT_TTL instead. Between them (including a raw
-- SavedVariables value read straight off disk and passed as opts.ttl),
-- a corrupted/hand-edited ttl can never brick either sweep call site
-- (UI.lua's Refresh tick, Ingest.lua's 30s sweep).
function M:setTtl(sec)
  if type(sec) ~= "number" then sec = nil end
  self.ttl = sec
end

-- remove entries older than ttl (by lastSeen). No-op when ttl is 0/nil
-- (never expire), so sweep can be called unconditionally by callers.
function M:sweep(now)
  if not self.ttl or self.ttl == 0 then
    return
  end
  local kept = {}
  for i = 1, #self.entries do
    local entry = self.entries[i]
    if now - entry.lastSeen > self.ttl then
      self.byKey[dedupeKey(entry)] = nil
    else
      kept[#kept + 1] = entry
    end
  end
  self.entries = kept
end

-- live counts of current entries, keyed by category
function M:countsByCategory()
  local counts = {}
  for i = 1, #self.entries do
    local cat = self.entries[i].category
    counts[cat] = (counts[cat] or 0) + 1
  end
  return counts
end

-- current entries in a category, newest lastSeen first
function M:listFor(category)
  local list = {}
  for i = 1, #self.entries do
    local entry = self.entries[i]
    if entry.category == category then
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b) return a.lastSeen > b.lastSeen end)
  return list
end

-- all current entries
function M:all()
  local list = {}
  for i = 1, #self.entries do
    list[i] = self.entries[i]
  end
  return list
end

-- all current entries across every category, newest lastSeen first --
-- backs the "All Recent" default board view.
function M:listAll()
  local list = self:all()
  table.sort(list, function(a, b) return a.lastSeen > b.lastSeen end)
  return list
end

-- reclassifyAll(C, classifyFn) -- re-runs classifyFn(rawText, meta, C)
-- for every current entry against a (possibly just-edited) config C, so
-- a rule/category edit re-buckets lines already on the board instead of
-- waiting for fresh chat. classifyFn is a required parameter, never read
-- off any ns.* global (the caller supplies ns.Classifier.classify) --
-- this file stays self-contained. An entry classifyFn now rejects is
-- removed; an entry it still accepts is merged over in place, keeping
-- firstSeen/lastSeen and the entry's own table identity. Each entry is
-- pcall-guarded: a classifyFn error on one entry only removes that
-- entry, never aborts the sweep. self.byKey is rebuilt from scratch
-- because reclassifying can change an entry's dedupe identity; on a key
-- collision (two entries re-bucket to the same key) the newer lastSeen
-- wins and the other is dropped, counted toward `removed`.
-- Returns the number of entries removed.
function M:reclassifyAll(C, classifyFn)
  if type(classifyFn) ~= "function" then return 0 end
  local removed = 0
  local kept = {}
  local newByKey = {}
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
      local newKey = dedupeKey(entry)
      local occupant = newByKey[newKey]
      if occupant then
        removed = removed + 1
        if entry.lastSeen > occupant.lastSeen then
          for j = #kept, 1, -1 do
            if kept[j] == occupant then
              table.remove(kept, j)
              break
            end
          end
          newByKey[newKey] = entry
          kept[#kept + 1] = entry
        end
        -- else: occupant is newer-or-tied, keeps its slot; entry is
        -- simply dropped (not added to kept/newByKey).
      else
        newByKey[newKey] = entry
        kept[#kept + 1] = entry
      end
    else
      removed = removed + 1
    end
  end
  self.entries = kept
  self.byKey = newByKey
  return removed
end

return Board
