local ADDON, ns = ...
ns.Filters = ns.Filters or {}
local Filters = ns.Filters

-- ============================================================
-- match(listing, filter)
-- All present criteria in `filter` must hold (AND). Missing
-- criterion = not constrained. Empty filter matches everything.
-- A generic predicate over every field a listing can carry -- only the
-- `keyword` criterion has a shipped caller (UI.lua's search box); the
-- rest exist for callers that need them later.
-- ============================================================

function Filters.match(listing, filter)
  listing = listing or {}
  filter = filter or {}

  if filter.category ~= nil and listing.category ~= filter.category then
    return false
  end

  if filter.tier ~= nil and listing.tier ~= filter.tier then
    return false
  end

  if filter.needsRole ~= nil then
    local need = listing.needCounts and listing.needCounts[filter.needsRole]
    local hasNeed = type(need) == "number" and need > 0
    local hasRole = listing.roles and listing.roles[filter.needsRole] == true
    if not (hasNeed or hasRole) then
      return false
    end
  end

  if filter.keyword ~= nil then
    local text = (listing.rawText or ""):lower()
    if not text:find(filter.keyword, 1, true) then
      return false
    end
  end

  if filter.targetMatch ~= nil then
    local target = listing.target or ""
    if not target:find(filter.targetMatch, 1, true) then
      return false
    end
  end

  return true
end

-- ============================================================
-- applyOverlay(C, userConfig)
-- Copies user aliases/modeTokens/roleWords/roleHints/categoryHints/
-- spamWeights keys into the matching C.* subtable, overriding
-- same-named keys but leaving every other built-in default in place.
-- Mutates C in place. Also deletes userConfig.removedDefaults entries
-- from C after every additive key above, so a user's explicit "remove
-- this default trigger" always wins over the shipped default of the
-- same name. Shape mirrors OVERLAY_KEYS itself:
-- { modeTokens={word=true,...}, categoryHints={...}, ... }.
-- ============================================================

local OVERLAY_KEYS = { "aliases", "modeTokens", "roleWords", "roleHints", "categoryHints", "spamWeights" }

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end
Filters.deepcopy = deepcopy

-- Categories/pipeline reconciliation is not a by-name union -- categories
-- are individually removable (including every built-in), so a saved list
-- that omits one must stay that way, not have it silently re-added. The
-- saved config is AUTHORITATIVE whenever it's present and non-empty; an
-- ABSENT field or an EMPTY {} (the shape a never-customized install's
-- SavedVariables has) falls back to the shipped defaults wholesale. This
-- also naturally handles a fresh/never-configured install the same way.
local function reconcileList(saved, defaults)
  -- type-guard before # -- a corrupt/hand-edited or malformed imported/shared
  -- config could set this field to a number/string, and #<number> raises.
  -- Anything that isn't a non-empty table degrades to the shipped defaults.
  if type(saved) == "table" and #saved > 0 then return saved end
  return deepcopy(defaults or {})
end

-- ============================================================
-- Pipeline migration vocabulary, used throughout the rest of this file:
--   legacy  -- a saved pipeline entry shaped {matcher="detector"|"rule",
--              id=, pattern=, outcome=}. Two distinguishable SavedVariables
--              layouts exist because the addon's matcher format changed
--              once; a saved legacy pipeline still loads and classifies
--              identically once migrated.
--   current -- {name=, patterns={{kind=,value=|id=},...}, outcome=}, the
--              shape the rules editor reads and writes today.
-- ============================================================

-- Legacy userRegex migration: an old pipeline shape had a "userRegex"
-- builtin bridge entry that re-evaluated a live regex-rule list in place,
-- at the slot right after "heroic". That bridge is gone -- a saved legacy
-- userConfig.userRegex list is now converted, once, into individual
-- current-shape {name, patterns={{kind="regex",...}}, outcome} pipeline
-- entries and spliced into a fresh copy of the default pipeline at that
-- same slot, so an existing user's saved regex rules keep classifying
-- identically with no separate manual migration step. Only applies when
-- we are ALREADY falling back to the default pipeline (an empty/absent
-- saved pipeline) -- once a user has a real saved pipeline, that list is
-- authoritative and legacy userRegex is not re-spliced into it. The
-- splice anchor is the entry named/id'd "heroic" -- the shipped default
-- Heroic matcher keeps a stable e.id="heroic" purely for this purpose
-- (see Classifier.lua's DEFAULT_PIPELINE).
local function migrateUserRegexIntoPipeline(pipeline, userRegex)
  if type(userRegex) ~= "table" or #userRegex == 0 then return pipeline end
  local migrated = {}
  for _, rule in ipairs(userRegex) do
    if type(rule) == "table" and rule.pattern and rule.category then
      migrated[#migrated + 1] = {
        name = rule.category .. " (regex)",
        patterns = { { kind = "regex", value = rule.pattern } },
        outcome = { kind = "category", name = rule.category },
      }
    end
  end
  if #migrated == 0 then return pipeline end

  local insertAt = #pipeline + 1
  for i, entry in ipairs(pipeline) do
    if type(entry) == "table" and entry.id == "heroic" then insertAt = i + 1; break end
  end
  local out = {}
  for i = 1, insertAt - 1 do out[#out + 1] = pipeline[i] end
  for _, e in ipairs(migrated) do out[#out + 1] = e end
  for i = insertAt, #pipeline do out[#out + 1] = pipeline[i] end
  return out
end

-- ============================================================
-- migratePipelineToR12(pipeline, C) -- converts a saved legacy-shape
-- pipeline (matcher="detector"/"rule" entries) into the uniform current
-- {name, patterns, outcome} shape. Idempotent: if EVERY entry already
-- carries .patterns, the pipeline is already current-shape and is
-- returned unchanged (running this twice on its own output is always a
-- no-op, since pass-1 output has .patterns and no .matcher). A
-- malformed/unknown entry (not a table, or a detector id with no known
-- mapping) is dropped rather than crashing the migration -- see
-- DETECTOR_MIGRATION below for the exact legacy id -> current
-- {name,patterns} table, and the header comment on "hints"/
-- "tier_leveling" splitting into multiple current-shape entries.
--
-- `C` (optional) is passed so the "hints" detector's split can read the
-- EFFECTIVE (already overlay-merged) C.categoryHints at migration time --
-- Filters.applyOverlay's authoritative-pipeline branch calls this AFTER
-- the categoryHints overlay merge, so a user's own categoryHints overlay
-- (e.g. a custom "ms"->"Manastorm" hint) is picked up and folded into the
-- migrated pipeline correctly. Falls back to Classifier's own
-- ns.C.categoryHints default (via a bare {} C) when C/C.categoryHints is
-- absent, so a bare-C caller (tests) still gets a sane split.
-- ============================================================

local function kw(value) return { kind = "keyword", value = value } end
local function catalogPat(value) return { kind = "catalog", value = value } end
local function specialPat(id) return { kind = "special", id = id } end
local function catOut(name) return { kind = "category", name = name } end

-- Static legacy detector-id -> current {name,patterns} mapping (outcome
-- is kept verbatim from the saved legacy entry -- it's already
-- {kind,name}). "hints" and "tier_leveling" are handled separately below
-- (hints splits by the EFFECTIVE categoryHints table; tier_leveling
-- always expands to the same two fixed matchers, Adventure + Leveling
-- (RDF), same as the shipped default).
local DETECTOR_MIGRATION = {
  questlink        = { name = "Quest link",         patterns = { specialPat("questlink") } },
  worldboss        = { name = "World Boss",         patterns = { catalogPat("worldboss") } },
  raid             = { name = "Raid",               patterns = { catalogPat("raid") } },
  manastorm        = { name = "Manastorm",          patterns = { kw("manastorm") } },
  mythic           = { name = "Mythic+",             patterns = { kw("m+"), kw("key"), kw("keystone"), kw("mythic"), kw("m0") } },
  heroic           = { name = "Heroic",              patterns = { kw("heroic"), kw("hc"), kw("h") }, id = "heroic" },
  dungeon_leveling = { name = "Dungeon (leveling)",  patterns = { catalogPat("dungeon") } },
  quest_keyword    = { name = "Quest word",          patterns = { specialPat("questword") } },
  other            = { name = "Everything else",     patterns = { specialPat("catchall") } },
}

-- Splits a saved legacy "hints" entry (categoryHintOf) into standalone
-- single-outcome current-shape matchers, seeded from the EFFECTIVE C.categoryHints
-- (word -> category name). Grouped by target category so a user's own
-- extra hint word (e.g. a custom "ms"->"Manastorm" alias) lands on the
-- right matcher, in one pass, dedupe-safe. The "manastorm" hint (dead --
-- fully subsumed by the earlier Manastorm tier matcher) is deliberately
-- NOT re-emitted as its own matcher; if the caller's migrated pipeline
-- already has a Manastorm-outcome matcher earlier, any manastorm-routed
-- hint word is folded onto it instead of duplicated.
local function splitHintsEntry(alreadyMigrated, C)
  local hints = (C and C.categoryHints) or {}
  local byCategory, order = {}, {}
  for word, category in pairs(hints) do
    if type(word) == "string" and type(category) == "string" then
      if not byCategory[category] then
        byCategory[category] = {}
        order[#order + 1] = category
      end
      table.insert(byCategory[category], word)
    end
  end
  table.sort(order)

  -- find an already-migrated matcher that routes to `category`, so a
  -- dead/subsumed hint (manastorm) folds onto it instead of duplicating.
  local function findExisting(category)
    for _, e in ipairs(alreadyMigrated) do
      if type(e) == "table" and type(e.outcome) == "table"
        and e.outcome.kind == "category" and e.outcome.name == category then
        return e
      end
    end
    return nil
  end

  local out = {}
  for _, category in ipairs(order) do
    local words = byCategory[category]
    table.sort(words)
    local existing = findExisting(category)
    if existing then
      for _, w in ipairs(words) do
        existing.patterns[#existing.patterns + 1] = kw(w)
      end
    else
      local patterns = {}
      for _, w in ipairs(words) do patterns[#patterns + 1] = kw(w) end
      out[#out + 1] = { name = category .. " (mentions)", patterns = patterns, outcome = catOut(category) }
    end
  end
  return out
end

local function migrateLegacyEntry(entry, out, C)
  if type(entry) ~= "table" then return end
  if entry.matcher == "rule" then
    out[#out + 1] = {
      name = (type(entry.outcome) == "table" and entry.outcome.name or "Custom") .. " rule",
      patterns = { { kind = (entry.mode == "regex") and "regex" or "keyword", value = entry.pattern } },
      outcome = entry.outcome,
    }
  elseif entry.matcher == "detector" then
    if entry.id == "tier_leveling" then
      out[#out + 1] = { name = "Adventure", patterns = { kw("adventure") }, outcome = entry.outcome }
      out[#out + 1] = { name = "Leveling (RDF)", patterns = { kw("rdf"), kw("spam"), kw("aura") }, outcome = entry.outcome }
    elseif entry.id == "hints" then
      local split = splitHintsEntry(out, C)
      for _, e in ipairs(split) do out[#out + 1] = e end
    else
      local mapped = DETECTOR_MIGRATION[entry.id]
      if mapped then
        local e = { name = mapped.name, patterns = mapped.patterns, outcome = entry.outcome }
        if mapped.id then e.id = mapped.id end
        out[#out + 1] = e
      end
    end
  end
end

function Filters.migratePipelineToR12(pipeline, C)
  if type(pipeline) ~= "table" then return pipeline end

  local alreadyCurrent = true
  for _, entry in ipairs(pipeline) do
    if type(entry) ~= "table" or type(entry.patterns) ~= "table" then
      alreadyCurrent = false
      break
    end
  end
  if alreadyCurrent then return pipeline end

  local out = {}
  for _, entry in ipairs(pipeline) do
    if type(entry) == "table" and type(entry.patterns) == "table" then
      -- defensively pass an already-current-shape entry through unchanged
      -- (a mixed saved pipeline should not happen in practice, but never
      -- drop data).
      out[#out + 1] = entry
    else
      migrateLegacyEntry(entry, out, C)
    end
  end
  return out
end

-- Every userConfig.* read below is type-guarded before use: userConfig
-- comes from SavedVariables (hand-editable) or an imported share string,
-- so a corrupt or hostile shape must degrade to "no overlay for this
-- field" rather than raise -- the alternative is FiltersUI's init
-- permanently unable to open with no in-game recovery.
function Filters.applyOverlay(C, userConfig)
  if not userConfig then return C end
  for i = 1, #OVERLAY_KEYS do
    local key = OVERLAY_KEYS[i]
    local userSub = userConfig[key]
    if type(userSub) == "table" then
      C[key] = C[key] or {}
      for k, v in pairs(userSub) do
        C[key][k] = v
      end
    end
  end

  -- Saved config is authoritative when present and non-empty; an absent
  -- or empty saved value falls back to the shipped defaults wholesale.
  -- See reconcileList above.
  local Classifier = ns.Classifier
  C.categories = reconcileList(userConfig.categories, Classifier and Classifier.DEFAULT_CATEGORIES)

  if type(userConfig.pipeline) == "table" and #userConfig.pipeline > 0 then
    -- Migrate a saved legacy-shape pipeline (see migratePipelineToR12
    -- below) to the current {name,patterns,outcome} shape. Idempotent on
    -- an already-current saved pipeline (a no-op). C is passed so the
    -- "hints" split reads the EFFECTIVE (already overlay-merged, see
    -- above) C.categoryHints. This runs whenever the saved pipeline is
    -- authoritative -- migrating in place keeps it authoritative (still
    -- "the user's own list"), just in the current shape.
    C.pipeline = Filters.migratePipelineToR12(userConfig.pipeline, C)
  else
    local defaultPipeline = deepcopy((Classifier and Classifier.DEFAULT_PIPELINE) or C.pipeline or {})
    C.pipeline = migrateUserRegexIntoPipeline(defaultPipeline, userConfig.userRegex)
  end

  if type(userConfig.removedDefaults) == "table" then
    for i = 1, #OVERLAY_KEYS do
      local key = OVERLAY_KEYS[i]
      local removed = userConfig.removedDefaults[key]
      if type(removed) == "table" and C[key] then
        for word in pairs(removed) do
          C[key][word] = nil
        end
      end
    end
  end

  -- Invalidate the Classifier's memoized lookup tables: they're built
  -- lazily off C.aliases/dungeons/classes/roleHints on first classify,
  -- and stay stale -- silently ignoring any overlay applied after that
  -- first call -- unless cleared here.
  C._targetLookup = nil
  C._dungeonByName = nil
  C._classCandidates = nil
  return C
end

-- resetToDefaults(C) -> C -- re-applies the shipped ns.C.categories/
-- ns.C.pipeline defaults verbatim, discarding any edits (the rules
-- editor's "Reset to defaults" action). Deep-copies so the caller's C
-- never aliases Classifier's shared default tables.
function Filters.resetToDefaults(C)
  C = C or {}
  local Classifier = ns.Classifier
  C.categories = deepcopy((Classifier and Classifier.DEFAULT_CATEGORIES) or {})
  C.pipeline = deepcopy((Classifier and Classifier.DEFAULT_PIPELINE) or {})
  C._targetLookup = nil
  C._dungeonByName = nil
  C._classCandidates = nil
  return C
end

-- ============================================================
-- export(userConfig) -> string
-- Hand-rolled recursive Lua-literal encoder. Produces a single
-- expression (a table constructor) that `import` reconstitutes via
-- loadstring("return "..str).
-- ============================================================

local function encodeString(s)
  local escaped = s:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n")
  return "\"" .. escaped .. "\""
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return n > 0
end

local function encodeValue(v)
  local ty = type(v)
  if ty == "string" then
    return encodeString(v)
  elseif ty == "number" or ty == "boolean" then
    return tostring(v)
  elseif ty == "table" then
    return Filters.encodeTable(v)
  else
    error("Filters.export: unsupported value type '" .. ty .. "'")
  end
end

function Filters.encodeTable(t)
  local parts = {}
  if isArray(t) then
    for i = 1, #t do
      parts[#parts + 1] = encodeValue(t[i])
    end
  else
    for k, v in pairs(t) do
      if type(k) ~= "string" then
        error("Filters.export: only string keys are supported")
      end
      parts[#parts + 1] = "[" .. encodeString(k) .. "]=" .. encodeValue(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Filters.export(userConfig)
  return Filters.encodeTable(userConfig or {})
end

-- ============================================================
-- import(str) -> userConfig | nil, err
-- Parses str back via loadstring("return "..str) in a fresh, empty
-- environment (setfenv(fn, {})) so the parsed code has no access to
-- any global. Any error (compile or runtime) is caught and returned
-- as nil, errmsg.
-- ============================================================

function Filters.import(str)
  if type(str) ~= "string" then
    return nil, "Filters.import: expected a string"
  end

  local chunk, loadErr = loadstring("return " .. str)
  if not chunk then
    return nil, loadErr
  end

  setfenv(chunk, {})

  local ok, result = pcall(chunk)
  if not ok then
    return nil, result
  end

  return result
end

-- ============================================================
-- Compact encoded share/import (WeakAuras-style), backed by the
-- CLIENT-BUNDLED LibDeflate/LibSerialize (LibraryXML -- reachable via
-- LibStub with zero addon dependency, confirmed against this client's
-- WeakAuras/Transmission.lua and Cell_Ascension/TurboPlates ImportExport.
-- lua prior art). NOT embedded -- the LibraryXML upgrade-lock makes an
-- embedded copy dead-on-arrival, and embedding would add new files (this
-- addon ships with none, so /reload always stays valid).
--
-- libs() is the ONLY place LibStub is ever read, and only from inside a
-- function body, never at file-load scope (hard constraint -- LibStub is
-- itself a WoW global, and even the ADDON'S OWN LibDeflate/LibSerialize
-- handles must not be resolved until first actually needed). Memoized
-- once a lib resolves; left nil (and retried on the next call) until it
-- does, so load order relative to LibStub never matters. Every call is
-- pcall-guarded -- a missing LibStub global, or a LibStub that errors on
-- an unknown major, degrades to "library unavailable" rather than an
-- addon-load error.
-- ============================================================

local _cachedDeflate, _cachedSerialize

local function libs()
  if not _cachedDeflate and LibStub then
    local ok, lib = pcall(LibStub, "LibDeflate")
    if ok and lib then _cachedDeflate = lib end
  end
  if not _cachedSerialize and LibStub then
    local ok, lib = pcall(LibStub, "LibSerialize")
    if ok and lib then _cachedSerialize = lib end
  end
  return _cachedDeflate, _cachedSerialize
end

local ENCODED_PREFIX = "!YABB:1!"

-- Decompression-bomb caps: a real exported config is a few KB at most.
-- MAX_ENCODED_INPUT bounds the pasted string itself (cheap, first line
-- of defense, also keeps the legacy-path loadstring from ever seeing a
-- multi-MB blob). MAX_DECOMPRESSED_OUTPUT bounds what DecompressDeflate
-- is allowed to hand back -- the real defense against a tiny hostile
-- string inflating to hundreds of MB, since the standard LibDeflate API
-- has no size-limit parameter on DecompressDeflate and can't be asked
-- to cap its own output. Checked immediately after inflate, before the
-- comparatively expensive Deserialize call ever runs on it.
local MAX_ENCODED_INPUT = 100 * 1024        -- ~100KB
local MAX_DECOMPRESSED_OUTPUT = 1024 * 1024 -- ~1MB

-- exportEncoded(cfg) -> string | nil
-- "!YABB:1!" .. EncodeForPrint(CompressDeflate(Serialize(cfg), {level=9})).
-- EncodeForPrint (7-bit print-safe), NOT EncodeForWoWChatChannel -- this
-- backs a copy/paste EditBox, and the WoW-chat-channel encoding is
-- Ascension-bugged. Returns nil (never errors) when LibDeflate/
-- LibSerialize aren't resolvable, so the caller falls back to the raw
-- Filters.export path -- see importString below for why that fallback
-- must stay importable.
function Filters.exportEncoded(cfg)
  local deflate, serialize = libs()
  if not (deflate and serialize) then return nil end
  local ok, result = pcall(function()
    local serialized = serialize:Serialize(cfg or {})
    local compressed = deflate:CompressDeflate(serialized, { level = 9 })
    local printable = deflate:EncodeForPrint(compressed)
    return ENCODED_PREFIX .. printable
  end)
  if not ok then return nil end
  return result
end

-- Recognized top-level YABB config keys -- OVERLAY_KEYS (aliases/
-- modeTokens/roleWords/roleHints/categoryHints/spamWeights) plus
-- categories/pipeline/userRegex/removedDefaults. A decoded/parsed table
-- carrying none of these isn't a YABB config at all (garbage, some other
-- addon's export, a hostile hand-crafted table) and must be rejected
-- outright -- deeper per-field type-safety (a corrupt categories/pipeline
-- etc.) is already the job of the existing reconcileList/applyOverlay
-- type-guards that run when the caller actually applies the result.
local CONFIG_SHAPE_KEYS = { categories = true, pipeline = true, userRegex = true, removedDefaults = true }
for i = 1, #OVERLAY_KEYS do CONFIG_SHAPE_KEYS[OVERLAY_KEYS[i]] = true end

-- Element-level shape validation: the key-presence check above only
-- proves the top-level table LOOKS like a YABB config -- it says
-- nothing about what's actually inside categories/pipeline. A validly-
-- encoded config whose categories/pipeline is a non-empty array of
-- non-table (or wrongly-shaped) elements used to sail straight through:
-- reconcileList/applyOverlay only type-guard the FIELD
-- itself (table vs not), never its elements, so the hostile array got
-- written verbatim to YABB_DB.userConfig and crashed the rules editor's
-- render on every subsequent open (attempt to index a number value),
-- surviving /reload. Reject at THIS boundary, before anything is ever
-- handed back to a caller that might persist it.
local function validCategoriesShape(categories)
  if categories == nil then return true end
  if type(categories) ~= "table" then return false end
  for i = 1, #categories do
    local cat = categories[i]
    if type(cat) ~= "table" or type(cat.name) ~= "string" then return false end
  end
  return true
end

-- A pipeline element is well-formed if it's a table AND EITHER a legacy
-- shape (entry.matcher ~= nil -- kept so an imported legacy share-string
-- still validates; applyOverlay's migratePipelineToR12 converts it to
-- current shape on apply) OR a current shape (type(entry.patterns) ==
-- "table" -- each pattern element itself a table with a string .kind,
-- see validPatternsShape). Either shape's .outcome, if present, must be
-- a table.
local function validPatternsShape(patterns)
  if type(patterns) ~= "table" then return false end
  for i = 1, #patterns do
    local p = patterns[i]
    if type(p) ~= "table" or type(p.kind) ~= "string" then return false end
  end
  return true
end

local function validPipelineShape(pipeline)
  if pipeline == nil then return true end
  if type(pipeline) ~= "table" then return false end
  for i = 1, #pipeline do
    local entry = pipeline[i]
    if type(entry) ~= "table" then return false end
    local isLegacy = entry.matcher ~= nil
    local isCurrent = type(entry.patterns) == "table"
    if not isLegacy and not isCurrent then return false end
    if isCurrent and (type(entry.name) ~= "string" or not validPatternsShape(entry.patterns)) then
      return false
    end
    if entry.outcome ~= nil and type(entry.outcome) ~= "table" then return false end
  end
  return true
end

-- Every OVERLAY_KEYS sibling (aliases/modeTokens/roleWords/roleHints/
-- categoryHints/spamWeights) and removedDefaults must be a table when
-- present -- applyOverlay's own type guards degrade a wrong-shaped one
-- silently, but a config that's wrong-shaped here isn't a YABB config
-- worth accepting at all. Without this, e.g. {aliases=5} passed
-- validation on key-presence alone.
local function validSiblingKeysShape(t)
  for i = 1, #OVERLAY_KEYS do
    local v = t[OVERLAY_KEYS[i]]
    if v ~= nil and type(v) ~= "table" then return false end
  end
  if t.removedDefaults ~= nil and type(t.removedDefaults) ~= "table" then return false end
  return true
end

local function looksLikeYabbConfig(t)
  if type(t) ~= "table" then return false end
  local hasRecognizedKey = false
  for k in pairs(t) do
    if CONFIG_SHAPE_KEYS[k] then hasRecognizedKey = true; break end
  end
  if not hasRecognizedKey then return false end
  if not validCategoriesShape(t.categories) then return false end
  if not validPipelineShape(t.pipeline) then return false end
  if not validSiblingKeysShape(t) then return false end
  return true
end

-- importString(str) -> cfg, nil | nil, errReason
-- The single entry point the UI calls for a pasted share string. Fully
-- fail-soft: every stage is pcall/nil-guarded, and this function itself
-- never raises -- any failure returns (nil, "<reason>"). Routes on the
-- "!YABB:1!" prefix:
--   * present -> the compact encoded path (Decode->Decompress->Deserialize,
--     no loadstring involved at all).
--   * absent  -> the raw path, reusing Filters.import (the sandboxed
--     loadstring/setfenv parser). This is the fallback wire format for
--     a client where LibDeflate/LibSerialize aren't reachable --
--     Filters.exportEncoded returns nil in that case and the export
--     side falls back to a raw Filters.export string, so this path must
--     stay importable or that fallback produces strings nobody can read.
-- Either path's result is shape-validated before being returned, so a
-- garbage or hostile table (wrong shape, or a non-YABB export) can never
-- reach the caller and corrupt live state.
function Filters.importString(str)
  if type(str) ~= "string" then
    return nil, "not a share string"
  end

  if #str > MAX_ENCODED_INPUT then
    return nil, "share string too large"
  end

  if str:sub(1, #ENCODED_PREFIX) == ENCODED_PREFIX then
    local body = str:sub(#ENCODED_PREFIX + 1)
    local deflate, serialize = libs()
    if not (deflate and serialize) then
      return nil, "compression library unavailable"
    end

    local ok1, decoded = pcall(function() return deflate:DecodeForPrint(body) end)
    if not ok1 or type(decoded) ~= "string" then
      return nil, "corrupt: decode"
    end

    local ok2, decompressed = pcall(function() return deflate:DecompressDeflate(decoded) end)
    if not ok2 or type(decompressed) ~= "string" then
      return nil, "corrupt: inflate"
    end
    if #decompressed > MAX_DECOMPRESSED_OUTPUT then
      return nil, "corrupt: too large"
    end

    local ok3, success, data = pcall(function() return serialize:Deserialize(decompressed) end)
    if not ok3 or not success or type(data) ~= "table" then
      return nil, "corrupt: deserialize"
    end

    if not looksLikeYabbConfig(data) then
      return nil, "not a YABB config"
    end
    return data, nil
  end

  -- Filters.import's raw loadstring error (e.g. `[string "return
  -- !YABB"]:1: unexpected symbol...`) is an internal implementation
  -- detail, not a user-facing reason -- map any failure here to one
  -- stable message.
  local data, err = Filters.import(str)
  if not data then
    return nil, "corrupt: not a valid share string"
  end
  if not looksLikeYabbConfig(data) then
    return nil, "not a YABB config"
  end
  return data, nil
end

return Filters
