local ADDON, ns = ...
ns.Performance = ns.Performance or {}
local Performance = ns.Performance

local NORMALISE_CACHE_CAP = 256

-- ============================================================
-- Classifier caches and precompiled pipeline matching.
-- ============================================================
local function optimiseClassifier()
  local Classifier = ns.Classifier
  if not Classifier or Classifier._performanceOptimised then return end
  Classifier._performanceOptimised = true

  local aliasLists = setmetatable({}, { __mode = "k" })
  local tokenSets = setmetatable({}, { __mode = "k" })
  local patternCache = setmetatable({}, { __mode = "k" })
  local normaliseCache, normaliseOrder = {}, {}
  local normaliseNext, normaliseSize = 1, 0

  local function invalidate()
    aliasLists = setmetatable({}, { __mode = "k" })
    tokenSets = setmetatable({}, { __mode = "k" })
    patternCache = setmetatable({}, { __mode = "k" })
    normaliseCache, normaliseOrder = {}, {}
    normaliseNext, normaliseSize = 1, 0
  end
  Performance.invalidateClassifierCaches = invalidate

  if type(Classifier.normalize) == "function" then
    local baseNormalize = Classifier.normalize
    Classifier.normalize = function(line)
      local key = type(line) == "string" and line or ""
      local cached = normaliseCache[key]
      if cached then return cached.tokens, cached.normStr end

      local tokens, normStr = baseNormalize(line)
      if normaliseSize < NORMALISE_CACHE_CAP then
        normaliseSize = normaliseSize + 1
        normaliseOrder[normaliseSize] = key
      else
        local old = normaliseOrder[normaliseNext]
        if old ~= nil then normaliseCache[old] = nil end
        normaliseOrder[normaliseNext] = key
        normaliseNext = (normaliseNext % NORMALISE_CACHE_CAP) + 1
      end
      normaliseCache[key] = { tokens = tokens, normStr = normStr }
      return tokens, normStr
    end
  end

  local function getTokenSet(tokens)
    if type(tokens) ~= "table" then return {} end
    local set = tokenSets[tokens]
    if set then return set end
    set = {}
    for i = 1, #tokens do set[tokens[i]] = true end
    tokenSets[tokens] = set
    return set
  end

  local function getMultiAliases(aliases)
    if type(aliases) ~= "table" then return {} end
    local cached = aliasLists[aliases]
    if cached then return cached end
    local list = {}
    for key, name in pairs(aliases) do
      if type(key) == "string" and key:find(" ", 1, true) then
        list[#list + 1] = { key = key, name = name }
      end
    end
    aliasLists[aliases] = list
    return list
  end

  if type(Classifier.resolveTarget) == "function" then
    local baseResolveTarget = Classifier.resolveTarget
    Classifier.resolveTarget = function(tokens, normStr, C, posterLevel)
      if not C or not C.aliases or not C.dungeons then return nil end

      -- Preserve the original DM collision rule exactly.
      local tokenSet = getTokenSet(tokens)
      if tokenSet.dm then
        local result
        if posterLevel and posterLevel >= 40 then
          result = C.aliases.diremaul or C.aliases["dire maul"]
        else
          result = C.aliases.dm
        end
        if result then return result end
      end

      -- isRejected normally builds this memoized index first. Fall back to the
      -- original once when a direct caller reaches resolveTarget before that.
      local lookup = C._targetLookup
      if type(lookup) ~= "table" then return baseResolveTarget(tokens, normStr, C, posterLevel) end

      local best, bestLength
      local function consider(name)
        if type(name) ~= "string" or name == "" then return end
        local length = #name
        if not bestLength or length < bestLength then
          best, bestLength = name, length
        end
      end

      for i = 1, #tokens do
        local names = lookup[tokens[i]]
        if names then
          for j = 1, #names do consider(names[j]) end
        end
      end

      if normStr then
        local aliases = getMultiAliases(C.aliases)
        for i = 1, #aliases do
          local alias = aliases[i]
          if normStr:find(alias.key, 1, true) then consider(alias.name) end
        end
      end
      return best
    end
  end

  local function isIntentToken(token)
    return token == "lf" or token == "lfm" or token == "lfg"
      or token:match("^lf%d+m$") ~= nil or token:match("^lf%d+$") ~= nil
  end

  local function hasStrongIntent(tokens, C, set)
    for i = 1, #tokens do
      if isIntentToken(tokens[i]) then return true end
    end
    if not set.need or type(C.roleWords) ~= "table" then return false end
    for role in pairs(C.roleWords) do
      if set[role] then return true end
    end
    return false
  end

  local function categoryExists(name, C)
    if not name then return false end
    local categories = C.categories or Classifier.DEFAULT_CATEGORIES or {}
    for i = 1, #categories do
      local category = categories[i]
      if type(category) == "table" and category.name == name then return true end
    end
    return false
  end

  local function compilePattern(pattern)
    local cached = patternCache[pattern]
    local kind, value, id = pattern.kind, pattern.value, pattern.id
    if cached and cached.kind == kind and cached.value == value and cached.id == id then
      return cached
    end

    cached = { kind = kind, value = value, id = id }
    if kind == "keyword" and type(value) == "string" and value ~= "" then
      cached.lower = value:lower()
      cached.singleToken = cached.lower:match("^[%w+]+$") ~= nil
    elseif kind == "regex" and type(value) == "string" and value ~= "" then
      cached.regexValid = pcall(string.find, "", value)
    end
    patternCache[pattern] = cached
    return cached
  end

  local function patternMatches(pattern, context)
    if type(pattern) ~= "table" then return false end
    local compiled = compilePattern(pattern)
    local kind = compiled.kind

    if kind == "keyword" then
      if not compiled.lower then return false end
      if compiled.singleToken then return context.tokenSet[compiled.lower] == true end
      return context.normStr ~= nil and context.normStr:find(compiled.lower, 1, true) ~= nil
    elseif kind == "regex" then
      return compiled.regexValid and context.normStr ~= nil
        and context.normStr:find(compiled.value) ~= nil
    elseif kind == "catalog" then
      return context.row ~= nil and context.row.kind == compiled.value
    elseif kind == "special" then
      if compiled.id == "questlink" then
        return Classifier.hasQuestLink(context.rawLine)
      elseif compiled.id == "questword" then
        return hasStrongIntent(context.tokens, context.C, context.tokenSet)
          and Classifier.hasQuestKeyword(context.normStr)
      elseif compiled.id == "catchall" then
        return true
      end
    end
    return false
  end

  local function matcherMatches(entry, context)
    local patterns = entry.patterns
    if type(patterns) ~= "table" then return false end
    for i = 1, #patterns do
      if patternMatches(patterns[i], context) then return true end
    end
    return false
  end

  Classifier.categoryOfDebug = function(target, tier, C, tokens, normStr, rawLine)
    C = C or {}
    tokens = tokens or {}
    local pipeline = C.pipeline or Classifier.DEFAULT_PIPELINE or {}
    local context = {
      target = target,
      tier = tier,
      C = C,
      tokens = tokens,
      tokenSet = getTokenSet(tokens),
      normStr = normStr,
      rawLine = rawLine,
      row = target and Classifier.rowForName(target, C) or nil,
    }

    for i = 1, #pipeline do
      local entry = pipeline[i]
      if type(entry) == "table" and matcherMatches(entry, context) then
        local outcome = entry.outcome
        local kind = outcome and outcome.kind or "nothing"
        if kind == "hide" then
          return Classifier.HIDE, i, entry
        elseif kind == "category" and categoryExists(outcome.name, C) then
          return outcome.name, i, entry
        end
      end
    end
    return nil, nil, nil
  end

  Classifier.categoryOf = function(target, tier, C, tokens, normStr, rawLine)
    local category = Classifier.categoryOfDebug(target, tier, C, tokens, normStr, rawLine)
    return category
  end

  if ns.Filters and type(ns.Filters.applyOverlay) == "function" then
    local baseApplyOverlay = ns.Filters.applyOverlay
    ns.Filters.applyOverlay = function(...)
      local result = baseApplyOverlay(...)
      invalidate()
      return result
    end
  end

  if ns.board and type(ns.board.reclassifyAll) == "function" then
    local baseReclassify = ns.board.reclassifyAll
    ns.board.reclassifyAll = function(self, ...)
      invalidate()
      return baseReclassify(self, ...)
    end
  end
end

optimiseClassifier()

return Performance
