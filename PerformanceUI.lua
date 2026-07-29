local ADDON, ns = ...
ns.Performance = ns.Performance or {}
local Performance = ns.Performance

local CHECK_INTERVAL = 0.15
local AGE_INTERVAL = 1
local VIRTUAL_OVERSCAN = 2
local NORMAL_ROW_HEIGHT = 40
local COMPACT_ROW_HEIGHT = 20

local function now()
  if ns.Ingest and ns.Ingest.now then return ns.Ingest.now() end
  if GetTime then return GetTime() end
  return 0
end

local function boardRevision()
  if ns.board and ns.board.getRevision then return ns.board:getRevision() end
  return 0
end

-- ============================================================
-- Virtualised listing rows and revision-driven UI refresh.
-- ============================================================
local function optimiseUI()
  local UI = ns.UI
  if not UI or UI._performanceOptimised then return end
  UI._performanceOptimised = true

  local baseRenderListings = UI.renderListings
  local baseRefresh = UI.Refresh
  local baseInit = UI.init
  if type(baseRenderListings) ~= "function" or type(baseRefresh) ~= "function"
    or type(baseInit) ~= "function" then return end

  -- Ingest owns expiry pruning on a 30-second cadence. Suppress UI.Refresh's
  -- duplicate sweep so opening, filtering, or receiving a listing never scans
  -- the entire board merely to repaint it.
  UI.Refresh = function(...)
    local board = ns.board
    local savedSweep = board and board.sweep
    if board then board.sweep = nil end
    local ok, result = pcall(baseRefresh, ...)
    if board then board.sweep = savedSweep end
    if not ok then
      if ns.Diag and ns.Diag.verbose and ns.Diag.log then
        ns.Diag.log("Performance.Refresh: " .. tostring(result))
      end
      return nil
    end
    return result
  end

  local filterCache
  local rendering = false

  local function compactRows()
    local display = YABB_DB and YABB_DB.display
    return type(display) == "table" and display.compact == true
  end

  local function filteredEntries()
    local revision = boardRevision()
    local focus = UI.focusCategory
    local hiddenIdentity = tostring(UI.hiddenCategories)
    local filterText = UI.filterText or ""
    local intent = UI.intentFilter or "all"

    if filterCache and filterCache.revision == revision and filterCache.focus == focus
      and filterCache.hiddenIdentity == hiddenIdentity and filterCache.filterText == filterText
      and filterCache.intent == intent then
      return filterCache.entries
    end

    local source
    if focus and ns.board and ns.board.listFor then
      source = ns.board:listFor(focus)
    elseif ns.board and ns.board.listAll then
      source = ns.board:listAll()
    else
      source = {}
    end

    local entries = {}
    for i = 1, #source do
      local entry = source[i]
      local include = true
      if not focus and UI.categoryHidden then
        include = not UI.categoryHidden(entry.category, UI.hiddenCategories)
      end
      if include and filterText ~= "" then
        local search = entry._searchText
        if search == nil then
          search = tostring(entry.rawText or ""):lower()
          entry._searchText = search
        end
        include = search:find(filterText, 1, true) ~= nil
      end
      if include and intent ~= "all" then include = entry.intent == intent end
      if include then entries[#entries + 1] = entry end
    end

    filterCache = {
      revision = revision,
      focus = focus,
      hiddenIdentity = hiddenIdentity,
      filterText = filterText,
      intent = intent,
      entries = entries,
    }
    return entries
  end

  local function refreshScrollbar(scrollFrame, contentHeight, viewHeight, scroll)
    if not scrollFrame then return end
    local child = scrollFrame.GetScrollChild and scrollFrame:GetScrollChild()
    if child then child:SetHeight(contentHeight > viewHeight and contentHeight or viewHeight) end
    scrollFrame._contentHeight = contentHeight

    local rangeHandler = scrollFrame.GetScript and scrollFrame:GetScript("OnScrollRangeChanged")
    if rangeHandler then pcall(rangeHandler, scrollFrame, math.max(0, contentHeight - viewHeight)) end

    local maxScroll = math.max(0, contentHeight - viewHeight)
    if scroll > maxScroll then scroll = maxScroll end
    if scroll < 0 then scroll = 0 end
    scrollFrame:SetVerticalScroll(scroll)
  end

  UI.renderListings = function()
    if rendering then return end
    local frame = UI.frame
    if not frame or not frame.ListingScroll or not frame.ListingScrollChild or not ns.board then
      return baseRenderListings()
    end

    rendering = true
    local entries = filteredEntries()
    local total = #entries
    local rowHeight = compactRows() and COMPACT_ROW_HEIGHT or NORMAL_ROW_HEIGHT
    local scrollFrame = frame.ListingScroll
    local viewHeight = scrollFrame:GetHeight() or 0
    local scroll = scrollFrame:GetVerticalScroll() or 0
    local contentHeight = total * rowHeight
    local maxScroll = math.max(0, contentHeight - viewHeight)
    if scroll > maxScroll then scroll = maxScroll end

    local first = math.floor(scroll / rowHeight) + 1 - VIRTUAL_OVERSCAN
    if first < 1 then first = 1 end
    local visibleCount = math.ceil((viewHeight > 0 and viewHeight or rowHeight) / rowHeight)
      + VIRTUAL_OVERSCAN * 2
    local last = math.min(total, first + visibleCount - 1)

    local window = {}
    for i = first, last do window[#window + 1] = entries[i] end

    local board = ns.board
    local rawListAll = rawget(board, "listAll")
    local rawListFor = rawget(board, "listFor")
    local resolvedListAll = board.listAll
    local allCalls = 0
    if UI.focusCategory then
      board.listFor = function() return window end
    else
      board.listAll = function(self)
        allCalls = allCalls + 1
        if allCalls == 1 then return window end
        return resolvedListAll(self)
      end
    end

    local ok, err = pcall(baseRenderListings)
    board.listAll = rawListAll
    board.listFor = rawListFor

    if ok then
      for i = 1, #window do
        local row = _G and _G["YABBListingRow" .. i]
        if row then
          row:ClearAllPoints()
          row:SetPoint("TOPLEFT", frame.ListingScrollChild, "TOPLEFT", 0,
            -((first + i - 2) * rowHeight))
          row:SetPoint("RIGHT", frame.ListingScrollChild, "RIGHT", 0, 0)
        end
      end
      refreshScrollbar(scrollFrame, contentHeight, viewHeight, scroll)

      if frame.EmptyState and total == 0 then
        local boardCount = ns.board.count and ns.board:count()
          or (resolvedListAll and #resolvedListAll(board)) or 0
        frame.EmptyState:SetText(boardCount == 0
          and "Listening to chat. Listings appear here as players post."
          or "No listings match this filter.")
        frame.EmptyState:Show()
      end
    elseif ns.Diag and ns.Diag.verbose and ns.Diag.log then
      ns.Diag.log("Performance.renderListings: " .. tostring(err))
    end

    rendering = false
  end

  local function updateAges()
    local current = now()
    local i = 1
    while i <= 256 do
      local row = _G and _G["YABBListingRow" .. i]
      if not row then break end
      if row:IsShown() and row.listing and row.AgeText then
        local seconds = math.floor(current - (row.listing.lastSeen or current))
        if seconds < 0 then seconds = 0 end
        local text
        if seconds < 60 then
          text = seconds .. "s"
        elseif seconds < 3600 then
          text = math.floor(seconds / 60) .. "m"
        else
          text = math.floor(seconds / 3600) .. "h"
        end
        row.AgeText:SetText(text)
      end
      i = i + 1
    end
  end

  UI.init = function(...)
    local result = baseInit(...)
    local frame = UI.frame
    if not frame or frame._yabbPerformanceDriver then return result end
    frame._yabbPerformanceDriver = true

    local checkAccum, ageAccum = 0, 0
    local lastRevision = boardRevision()
    frame:SetScript("OnUpdate", function(_, elapsed)
      checkAccum = checkAccum + elapsed
      ageAccum = ageAccum + elapsed

      if checkAccum >= CHECK_INTERVAL then
        checkAccum = checkAccum - CHECK_INTERVAL
        local revision = boardRevision()
        if revision ~= lastRevision then
          lastRevision = revision
          filterCache = nil
          UI.Refresh()
        end
      end

      if ageAccum >= AGE_INTERVAL then
        ageAccum = ageAccum - AGE_INTERVAL
        updateAges()
      end
    end)

    local scroll = frame.ListingScroll
    if scroll and scroll.HookScript and not scroll._yabbPerformanceHooks then
      scroll._yabbPerformanceHooks = true
      scroll:HookScript("OnVerticalScroll", function() UI.renderListings() end)
      scroll:HookScript("OnSizeChanged", function() UI.renderListings() end)
    end
    return result
  end
end

optimiseUI()

return Performance
