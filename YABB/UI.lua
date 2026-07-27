local ADDON, ns = ...
ns.UI = ns.UI or {}
local UI = ns.UI

-- ============================================================
-- Two-pane bulletin-board window. Frame skeleton lives in UI.xml (native
-- SetBackdrop applied from here via ns.Compat.applyBackdrop, GBB-style
-- reusable-row scroll lists); this file wires every behavior onto it
-- programmatically and renders from ns.board/ns.C.
--
-- ns.UI.init() is idempotent (guards on UI.frame already existing) but is
-- not self-invoked here -- Init.lua's central fail-soft orchestrator calls
-- it exactly once, pcall-wrapped, after every subsystem (including this
-- file) has loaded.
-- ============================================================

-- ============================================================
-- config: the synthetic "All Recent" view (board:listAll(), active by
-- default), row anatomy constants, pool sizes, refresh throttle. The
-- category rail carries no hardcoded name list -- categoryNames() (below)
-- reads ns.C.categories live, the same ordered name+color list the rules
-- editor's Categories tab (FiltersUI.lua) manages, so a
-- user-added/renamed/removed/reordered category shows up on the rail with
-- zero extra plumbing.
-- ============================================================

local ALL_RECENT = "All Recent"
UI.ALL_RECENT = ALL_RECENT -- exposed read-only so tests/rail_spec.lua never hardcodes the literal
-- Normal-mode row height fits two lines (name plus the raw-message line
-- below it). Compact mode is a genuinely tighter single line, not just a
-- few px shorter, so the two modes read as visibly distinct.
local LISTING_ROW_HEIGHT = 40
local CATEGORY_ROW_HEIGHT = 22
local RAIL_SEP_GAP = 8   -- vertical space a section divider consumes
local RAIL_CAP_HEIGHT = 16 -- vertical space a section caption consumes
local REFRESH_INTERVAL = 0.2 -- repeating throttle while the window is shown
local SCROLL_STEP = 24

-- Rail selection state. FOCUS (UI.focusCategory) is transient, session-only:
-- nil means "All Recent" (every category), a name means exclusive focus on
-- that one row. HIDDEN (UI.hiddenCategories) is a name-keyed set persisted
-- to YABB_DB.hiddenCategories (applied straight into UI.hiddenCategories in
-- UI.init()) so exclusions survive /reload; focus deliberately does not
-- persist -- every fresh session starts on the all-view. See
-- reduceFocusClick/reduceHideClick/categoryHidden further down for the
-- actual (pure, unit-tested) rules.
UI.focusCategory = nil
UI.hiddenCategories = UI.hiddenCategories or {}
UI.filterText = ""
-- LFG/LFM filter: "all"|"LFG"|"LFM", persisted to YABB_DB.intentFilter by
-- UI.init(). renderListings() below is the sole filter point; the rail
-- counts and the titlebar pulse line are deliberately left unfiltered
-- (documented at their own call sites) -- the rail/pulse always describe
-- the whole board, the listings pane describes what you're currently
-- looking at.
UI.intentFilter = UI.intentFilter or "all"

-- pooled row frames, index-keyed (GBB RequestList.lua:130-137,410-414:
-- pre-create/reuse ~100 named "GBB.Item_"..i frames rather than a
-- FauxScrollFrame scheme; ours grows lazily instead of pre-allocating).
local categoryRows = {}
local listingRows = {}

-- ============================================================
-- Row-anatomy tables (role/category/intent colors), plus the small
-- pure-ish formatting helpers the row/rail renderers use.
-- ============================================================

-- Roles: tank/heal/dps only -- the sole roles ns.Compat.ROLE_TEXCOORD
-- defines. Colors decomposed to 0-1 rgb the same way Compat.classColor
-- already decomposes its own hex table.
local ROLE_ORDER = { "TANK", "HEAL", "DPS" }
local ROLE_SLOT_ICON = { TANK = "RoleTankIcon", HEAL = "RoleHealIcon", DPS = "RoleDpsIcon" }
local ROLE_SLOT_COUNT = { TANK = "RoleTankCount", HEAL = "RoleHealCount", DPS = "RoleDpsCount" }
local ROLE_COLOR = {
  TANK = { 0x4f / 255, 0x93 / 255, 0xd6 / 255 },
  HEAL = { 0x46 / 255, 0xc0 / 255, 0x7a / 255 },
  DPS  = { 0xdf / 255, 0x5a / 255, 0x44 / 255 },
}

-- Intent tag: LFM gold-ish, LFG tank-blue.
local INTENT_COLOR = {
  LFM = { 0.91, 0.77, 0.42 },
  LFG = { 0x4f / 255, 0x93 / 255, 0xd6 / 255 },
}
-- A genuinely-unknown intent (Classifier.extractIntent's own "unset" third
-- state) must render as a visibly NEUTRAL tag, not silently coalesce into
-- "LFG" -- that would assert a guess the classifier deliberately declined
-- to make. Dim grey, distinct from both LFG-blue and LFM-gold.
local NEUTRAL_INTENT_LABEL = "\226\128\148" -- em dash (U+2014); a plain "-" reads as the reject-marker used elsewhere (level column, Diag), so this uses a distinct glyph
local NEUTRAL_INTENT_COLOR = { 0.45, 0.48, 0.55 }

-- Category rail "eye-off" marker: plain Latin-1 text, same "safe glyph, not
-- a guessed icon texture path" posture as NEUTRAL_INTENT_LABEL above.
local HIDDEN_MARK_GLYPH = "\195\151" -- U+00D7 MULTIPLICATION SIGN
local HIDDEN_MARK_COLOR = { 0.55, 0.58, 0.66, 0.9 }

-- Titlebar All/LFG/LFM filter control: ordered {key=, label=} pairs -- key
-- is exactly the persisted YABB_DB.intentFilter value and the value
-- compared against listing.intent in renderListings.
local INTENT_FILTER_OPTIONS = {
  { key = "all", label = "All" },
  { key = "LFG", label = "LFG" },
  { key = "LFM", label = "LFM" },
}

local ALL_RECENT_DOT_COLOR = { 0.75, 0.79, 0.86 }
-- Neutral fallback for a listing/rail name with no matching row in
-- ns.C.categories -- e.g. a category just deleted from the Categories tab
-- while old listings still carry its name. Never nil-index.
local NEUTRAL_CATEGORY_COLOR = { 0.5, 0.53, 0.6 }

-- ============================================================
-- Display toggles: YABB_DB.display.{roleIcons,classColors,showLevel,
-- compact}. Read straight off YABB_DB rather than through any
-- ns.FiltersUI function -- FiltersUI.lua owns the settings panel, not this
-- saved shape, and this file has no common Utils.lua to share the read
-- through (FiltersUI.lua duplicates this identical default table for its
-- own toggle rendering). nil (never configured) reads as each flag's own
-- default, matching Ingest.isChannelEnabled's "absent means not yet
-- decided" convention.
-- ============================================================
local DISPLAY_DEFAULT = { roleIcons = true, classColors = true, showLevel = true, compact = false }
-- 3.3.5 has no C_ClassColor; Compat.classColor's own "unknown class"
-- fallback (Compat.lua GREY_CLASS_COLOR.hex) is reused verbatim here so
-- a classColors-off name and a genuinely-unresolvable class render
-- identically -- one grey, not two slightly different greys.
local CLASS_COLOR_OFF_HEX = "9d9d9d"
-- Compact is a real single-line row, not just a slightly-shorter two-line one.
local COMPACT_ROW_HEIGHT = 20
-- Name sits this many px above row-center in normal (two-line) mode, so the
-- Raw line (anchored off Name's own bottom edge, see layoutListingRow) has
-- room below it; compact mode uses 0 (Name back at row-center, matching
-- every other single-line row element).
local NAME_Y_NORMAL = 6

-- Raw-text pixel fit: FontString:GetStringWidth() is a real 3.3.5 API -- see
-- pixelFitRaw below. RAW_RIGHT_MARGIN mirrors PillBg's own -8 anchor gap
-- (layoutListingRow) plus a hair more since Raw sits a full line below the
-- pill/level/age it's measured against. RAW_MIN_WIDTH is a sane floor so a
-- squeezed/degenerate layout never hands GetStringWidth a near-zero target.
-- RAW_FALLBACK_WIDTH is used ONLY when live geometry isn't resolvable yet
-- (e.g. a pooled row's very first render, before it has ever been shown).
-- RAW_MAX_TRIM_ITER hard-caps the binary search in pixelFitRaw so a
-- pathological string can never spin -- belt-and-suspenders on top of the
-- search's own monotonic lo/hi shrink.
local RAW_RIGHT_MARGIN = 10
local RAW_MIN_WIDTH = 60
local RAW_FALLBACK_WIDTH = 112
local RAW_MAX_TRIM_ITER = 24

-- Type-guarded against a hand-corrupted SavedVariables: YABB_DB.display set
-- to a non-table must fall through to defaults, not index-error.
local function displayOn(key)
  local disp = YABB_DB and YABB_DB.display
  local v = (type(disp) == "table") and disp[key] or nil
  if v == nil then return DISPLAY_DEFAULT[key] end
  return v ~= false
end

local function currentRowHeight()
  if displayOn("compact") then return COMPACT_ROW_HEIGHT end
  return LISTING_ROW_HEIGHT
end

-- measureWidth(fontString, text) -- sets `text` then reads GetStringWidth()
-- (no-arg on this client -- it measures whatever is currently set, unlike
-- retail's optional-string overload), pcall-guarded since it's a live WoW
-- call on the render path. Returns nil (never a crash) on any failure or
-- non-numeric result.
local function measureWidth(fontString, text)
  fontString:SetText(text)
  local ok, w = pcall(fontString.GetStringWidth, fontString)
  if ok and type(w) == "number" then return w end
  return nil
end

-- pixelFitRaw(fontString, text, maxWidth) -- sets the full raw chat text on
-- `fontString`, and if it doesn't fit in `maxWidth` px, binary-searches
-- (bounded: standard lo/hi shrink PLUS a hard RAW_MAX_TRIM_ITER cap, so a
-- pathological string or a maxWidth of 0 can never spin) for the longest
-- prefix that, with a trailing "...", measures within maxWidth. maxLines="1"
-- on the XML template remains the structural backstop against wrap/row
-- growth regardless of how this measurement performs live.
local function pixelFitRaw(fontString, text, maxWidth)
  text = tostring(text or "")
  if not (fontString and fontString.SetText and fontString.GetStringWidth) then
    return
  end
  if text == "" or type(maxWidth) ~= "number" or maxWidth <= 0 then
    fontString:SetText(text)
    return
  end

  local full = measureWidth(fontString, text)
  if not full or full <= maxWidth then
    return -- fontString already holds the untrimmed text from the measure above
  end

  local lo, hi = 0, #text - 1
  local best = "..."
  local iterations = 0
  while lo <= hi and iterations < RAW_MAX_TRIM_ITER do
    iterations = iterations + 1
    local mid = math.floor((lo + hi) / 2)
    local candidate = text:sub(1, mid) .. "..."
    local w = measureWidth(fontString, candidate)
    if w and w <= maxWidth then
      best = candidate
      lo = mid + 1
    else
      hi = mid - 1
    end
  end

  fontString:SetText(best)
end

local function formatAge(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 0 then seconds = 0 end
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  return math.floor(seconds / 3600) .. "h"
end

-- Poster class -> color hex + raw classFilename token (for the poster
-- name's inline |cff color code and the hover tooltip). Resolved on demand
-- every call, with no persistent cache: ns.Players.classFor(listing.guid)
-- first (free/synchronous GetPlayerInfoByGUID off the listing's own guid);
-- on a miss (no guid on this listing, or the lookup failed), falls back to
-- listing.guid -> Compat.playerInfo. Compat.classColor's own internal
-- fallback chain (CUSTOM_CLASS_COLORS -> RAID_CLASS_COLORS -> grey) is the
-- final answer either way. Every step is pcall-guarded so a missing or
-- malformed color can never index-crash the row render; the outer "9d9d9d"
-- is the same grey CLASS_COLOR_OFF_HEX already uses, reached only if the
-- pcall around Compat.classColor itself fails. Called only for visible
-- rows on the already-throttled ~0.2s render tick, so this stays cheap
-- despite running fresh every time.
local function posterClassInfo(listing)
  local classFilename

  if listing and listing.guid and ns.Players and ns.Players.classFor then
    local ok, cf = pcall(ns.Players.classFor, listing.guid)
    if ok and cf then classFilename = cf end
  end

  if not classFilename and listing and listing.guid and ns.Compat and ns.Compat.playerInfo then
    local ok, _, cf = pcall(ns.Compat.playerInfo, listing.guid)
    if ok and cf then classFilename = cf end
  end

  local hex = "9d9d9d"
  if ns.Compat and ns.Compat.classColor then
    local ok, color = pcall(ns.Compat.classColor, classFilename)
    if ok and color and color.hex then
      hex = color.hex
    end
  end
  return hex, classFilename
end

-- resolvedLevel(listing) -> {text=, source=, exact=}: an authoritative live
-- source (guild/party/friend/unit, via ns.Players.levelFor ->
-- ns.Players.resolveLevel -- pure, unit-tested in players_spec.lua) beats
-- "-" (never "?") for any intent; only when that resolves to "-" AND the
-- listing is a real LFG post does a bare, unambiguous self-level parsed
-- straight off the poster's own text (Classifier.classify's own
-- posterLevel field, already LFM-gated at the classify level) get shown --
-- never on an LFM line, whose numbers describe headcounts/roles being
-- recruited, not the poster's own level. This second intent check is
-- deliberately redundant with Classifier's own gate: a future UI-only
-- change can never surface an LFM/unset line's number as if it were a
-- stated level. Deliberately does NOT fall back to listing.levelFilter:
-- that field is the dungeon's own "need N+" bracket requirement, a
-- property of the request, not the poster's character level. The board
-- row and the hover tooltip (UI.onRowEnter) can never disagree -- both
-- call this same wrapper.
local function resolvedLevel(listing)
  local rec
  if listing and listing.poster and ns.Players and ns.Players.levelFor then
    local ok, r = pcall(ns.Players.levelFor, listing.poster)
    if ok then rec = r end
  end
  local result
  if ns.Players and ns.Players.resolveLevel then
    local ok, r = pcall(ns.Players.resolveLevel, rec)
    if ok and r then result = r end
  end
  result = result or { text = "-", source = nil, exact = nil }
  if result.text == "-" and listing and listing.intent == "LFG" and type(listing.posterLevel) == "number" then
    return { text = tostring(listing.posterLevel), source = "text", exact = true }
  end
  return result
end

-- content pill text: category, plus the resolved target (dungeon/boss
-- name) when the classifier found one -- "Heroic - Scarlet Monastery",
-- or just "Other" when nothing more specific resolved.
local function pillText(listing)
  local category = listing.category or "Other"
  if listing.target then
    return category .. " - " .. listing.target
  end
  return category
end

-- level column text: thin wrapper over resolvedLevel (above) so
-- renderListingRow's call site stays unchanged.
local function levelText(listing)
  return resolvedLevel(listing).text
end

-- ============================================================
-- Poster level/class enrichment lives entirely in ns.Players (YABB/
-- Players.lua): class is resolved on demand off each listing's own guid
-- (Players.classFor), level is read from a transient session-only map
-- (Players.levelFor) topped up by four passive, pop-free sources (guild
-- roster / friends list / party+raid roster / target+mouseover unit) --
-- /who is dead on Ascension (SendWho is server-neutered), so this file
-- never calls it. This file's only integration points are
-- posterClassInfo/resolvedLevel (read-only) -- resolvedLevel's own header
-- covers the LFG-only bare-text self-level fallback layered on top.
-- ============================================================

-- ============================================================
-- Mouse wheel: UIPanelScrollFrameTemplate's native classic ScrollFrame
-- wires no wheel input on its own. Modeled on
-- Chattynator-335/Core/SlashCmd.lua:60-68, which wires OnMouseWheel on
-- this exact widget via GetVerticalScroll/SetVerticalScroll/
-- GetVerticalScrollRange.
-- ============================================================

-- Forward-declared: themeScrollbar/wireScrollWidthSync (below) and
-- renderCategories/renderListings (further down) all call this; the
-- definition lives next to themeScrollbar since it shares that function's
-- pcall/existence-guard posture, but callers appear earlier in the file.
local updateScrollbar

-- Fail-soft wrapper for a fire-and-forget call: routes through
-- Compat.guard (tags the error for Diag's verbose log) when it's
-- available, otherwise degrades to a bare pcall -- identical
-- swallow-the-error behavior either way once verbose logging is off,
-- which is the default. Same idiom FiltersUI.lua's own runGuarded uses.
local function runGuarded(fn, tag)
  if ns.Compat and ns.Compat.guard then
    ns.Compat.guard(fn, tag)
  else
    pcall(fn)
  end
end

local function wireMouseWheel(scrollFrame)
  if not scrollFrame or not scrollFrame.EnableMouseWheel then return end
  scrollFrame:EnableMouseWheel(true)
  scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local new = (self:GetVerticalScroll() or 0) - delta * SCROLL_STEP
    if new < 0 then
      new = 0
    elseif new > range then
      new = range
    end
    self:SetVerticalScroll(new)
  end)
end

-- Keeps a ScrollFrame's ScrollChild the same width as the visible scroll
-- area, so rows anchored TOPLEFT+RIGHT to the ScrollChild (the pooled-row
-- convention below) actually stretch to fill the pane instead of being
-- stuck at the ScrollChild's XML-declared placeholder width -- the pill
-- column's flexible width depends on the row's own width being correct.
-- Same idiom FiltersUI.lua's own createScrollEditBox uses for its EditBox
-- (FiltersUI.lua:276-279).
local function wireScrollWidthSync(scrollFrame, child)
  if not scrollFrame or not child then return end
  scrollFrame:SetScript("OnSizeChanged", function(self, w)
    if w and w > 0 then child:SetWidth(w) end
    -- Resize path: reuses self._contentHeight (the TRUE content height, not
    -- the viewport-clamped child height) so shrinking the window cannot
    -- flash a bar for content that still fits.
    if updateScrollbar then updateScrollbar(self) end
  end)
  local w = scrollFrame:GetWidth()
  if w and w > 0 then child:SetWidth(w) end
end

-- ============================================================
-- category rail (left pane)
-- ============================================================

-- name -> {r,g,b}, read live off ns.C.categories (the rules editor's own
-- Categories tab list -- FiltersUI.lua). A name with no matching row (a
-- category just deleted while an old listing still carries its name)
-- falls back to NEUTRAL_CATEGORY_COLOR, never nil-indexes.
local function categoryColorOf(name)
  local cats = ns.C and ns.C.categories
  if cats and name then
    for i = 1, #cats do
      local c = cats[i]
      if type(c) == "table" and c.name == name and type(c.color) == "table" then
        local col = c.color
        return { col.r or 0.5, col.g or 0.53, col.b or 0.6 }
      end
    end
  end
  return NEUTRAL_CATEGORY_COLOR
end

-- cats: {"All Recent", ...ns.C.categories names, in order...}.
local function categoryNames()
  local cats = { ALL_RECENT }
  local live = (ns.C and ns.C.categories) or {}
  for i = 1, #live do
    local c = live[i]
    if type(c) == "table" and c.name then cats[#cats + 1] = c.name end
  end
  return cats
end

local function categoryDotColor(name)
  if name == ALL_RECENT then return ALL_RECENT_DOT_COLOR end
  return categoryColorOf(name)
end

-- ============================================================
-- Rail selection rules: multi-select by two implicit gestures. Pure
-- reducers -- no ns./WoW call anywhere -- so the actual click semantics are
-- unit-testable standalone (tests/rail_spec.lua) independent of any board/
-- frame state; UI.onCategoryLeftClick/onCategoryRightClick below are the
-- thin live wrappers that apply them to UI's own module state and persist/
-- refresh. Exposed on UI (not local-only) for that same testability, same
-- convention FiltersUI.lua already uses for its own pure helpers
-- (expiryIndexForSeconds/isDisplayOn).
--
-- reduceFocusClick(focusCategory, name) -> new focusCategory
--   Left-click: clicking "All Recent" (or clicking the already-focused
--   row again) clears focus; clicking any other row focuses it
--   exclusively.
-- ============================================================
function UI.reduceFocusClick(focusCategory, name)
  if not name then return focusCategory end -- defensive no-op, never reached via a real row click
  if name == ALL_RECENT then return nil end
  if focusCategory == name then return nil end
  return name
end

-- reduceHideClick(hiddenCategories, name) -> new hiddenCategories (a fresh
-- table -- never mutates its argument, so a caller holding the old set,
-- e.g. a test, is never surprised). Right-click "All Recent" resets to an
-- empty set (clear ALL hides); right-click any other row toggles that one
-- name in place. Focus-clearing on right-click is the CALLER's job
-- (onCategoryRightClick below) -- this reducer only ever touches the
-- hidden set.
function UI.reduceHideClick(hiddenCategories, name)
  local new = {}
  for k, v in pairs(hiddenCategories or {}) do new[k] = v end
  if not name then return new end -- defensive no-op, never reached via a real row click
  if name == ALL_RECENT then return {} end
  if new[name] then
    new[name] = nil
  else
    new[name] = true
  end
  return new
end

-- categoryHidden(name, hiddenCategories) -> boolean. Pure predicate the
-- all-view (no focus) render/filter paths both share below.
function UI.categoryHidden(name, hiddenCategories)
  return (hiddenCategories and hiddenCategories[name]) and true or false
end

-- persistHiddenCategories() -- the ONE write path to YABB_DB.hiddenCategories
-- (name-keyed set, r7 spec's own chosen shape), called after every
-- right-click. Copies only the true-valued keys so a stray `false` never
-- round-trips into the saved table. Guarded the same way every other
-- YABB_DB writer in this file is (FiltersUI.lua:1888-1890 mirrors this
-- exact "YABB_DB = YABB_DB or {}" idiom).
function UI.persistHiddenCategories()
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  YABB_DB.hiddenCategories = {}
  for name, v in pairs(UI.hiddenCategories) do
    if v then YABB_DB.hiddenCategories[name] = true end
  end
end

-- saveWindowState() -- the one write path to YABB_DB.window, called after
-- a drag or a resize completes. Type-guarded the same way every other
-- YABB_DB writer in this file is.
function UI.saveWindowState()
  if not UI.frame then return end
  local point, _, relPoint, x, y = UI.frame:GetPoint()
  if not point then return end
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  YABB_DB.window = {
    point = point,
    relPoint = relPoint,
    x = x,
    y = y,
    width = UI.frame:GetWidth(),
    height = UI.frame:GetHeight(),
  }
end

-- Live wrappers: apply a reducer to UI's own state, persist (hide only),
-- and refresh. These are what the row click handler (acquireCategoryRow)
-- actually calls.
function UI.onCategoryLeftClick(name)
  if not name then return end
  UI.focusCategory = UI.reduceFocusClick(UI.focusCategory, name)
  UI.Refresh()
end

function UI.onCategoryRightClick(name)
  if not name then return end
  UI.focusCategory = nil -- right-click always clears focus first (spec)
  UI.hiddenCategories = UI.reduceHideClick(UI.hiddenCategories, name)
  UI.persistHiddenCategories()
  UI.Refresh()
end

-- the entries backing whichever view is currently active: a focused
-- category (exclusive), or -- with no focus -- every category not in the
-- hidden set (All Recent's own resting state, and the default). The rail
-- counts + the pulse line deliberately call ns.board directly instead of
-- this function, so they stay whole-board regardless of focus/hides (see
-- their own call sites).
local function activeEntries()
  if UI.focusCategory then
    if ns.board and ns.board.listFor then return ns.board:listFor(UI.focusCategory) end
    return {}
  end
  local all = (ns.board and ns.board.listAll and ns.board:listAll()) or {}
  local shown = {}
  for i = 1, #all do
    if not UI.categoryHidden(all[i].category, UI.hiddenCategories) then
      shown[#shown + 1] = all[i]
    end
  end
  return shown
end

local function acquireCategoryRow(i, scrollChild)
  local row = categoryRows[i]
  if not row then
    row = CreateFrame("Button", "YABBCategoryRow" .. i, scrollChild, "YABBCategoryRow")
    row:SetScript("OnMouseDown", function(self, button)
      if button == "RightButton" then
        UI.onCategoryRightClick(self.categoryName)
      else
        UI.onCategoryLeftClick(self.categoryName)
      end
    end)
    -- Static per-row (never varies by listing/category), so set once here
    -- rather than every render -- same convention the listing row's own
    -- role-icon setup already uses (acquireListingRow above).
    if row.HiddenMark then
      row.HiddenMark:SetText(HIDDEN_MARK_GLYPH)
      row.HiddenMark:SetTextColor(HIDDEN_MARK_COLOR[1], HIDDEN_MARK_COLOR[2], HIDDEN_MARK_COLOR[3], HIDDEN_MARK_COLOR[4])
    end
    categoryRows[i] = row
  end
  return row
end

function UI.renderCategories()
  local frame = UI.frame
  if not frame or not frame.CategoryScrollChild then return end
  local sc = frame.CategoryScrollChild
  local counts = (ns.board and ns.board.countsByCategory and ns.board:countsByCategory()) or {}
  local totalAll = (ns.board and ns.board.listAll and #ns.board:listAll()) or 0
  local cats = categoryNames()

  local y = 0
  for i, name in ipairs(cats) do
    -- "BY ACTIVITY" divider, always shown, right after "All Recent".
    if i == 2 and sc.RailSep1 and sc.RailCap1 then
      sc.RailSep1:ClearAllPoints()
      sc.RailSep1:SetPoint("TOPLEFT", sc, "TOPLEFT", 4, y - 4)
      sc.RailSep1:SetPoint("TOPRIGHT", sc, "TOPRIGHT", -4, y - 4)
      sc.RailSep1:Show()
      y = y - RAIL_SEP_GAP
      sc.RailCap1:ClearAllPoints()
      sc.RailCap1:SetPoint("TOPLEFT", sc, "TOPLEFT", 6, y)
      sc.RailCap1:Show()
      y = y - RAIL_CAP_HEIGHT
    end

    local row = acquireCategoryRow(i, sc)
    row.categoryName = name
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", sc, "TOPLEFT", 0, y)
    row:SetPoint("RIGHT", sc, "RIGHT", 0, 0)

    local dc = categoryDotColor(name)
    row.Label:SetText(name)
    local count
    if name == ALL_RECENT then
      count = totalAll
    else
      count = counts[name] or 0
    end
    row.CountText:SetText(tostring(count))

    -- Only the row acted on ever changes style. A row is either focused
    -- (gold, exclusive-view indicator), hidden (dimmed label+dot,
    -- struck-through, eye-off marker), or -- for every other row, always --
    -- fully normal: full-color dot, default label color. Recomputed
    -- unconditionally every render (this function runs on the ~0.2s
    -- refresh tick), so a row can never carry stale styling from a prior
    -- focus/hide state. "All Recent" itself (name == ALL_RECENT) can never
    -- be focused or hidden -- it is a pure reset button, not a persistent
    -- state indicator -- so it always renders in this normal branch.
    local isFocused = UI.focusCategory ~= nil and UI.focusCategory == name
    local isHidden = not isFocused and UI.categoryHidden(name, UI.hiddenCategories)

    if isFocused then
      row.Bg:SetTexture(0.91, 0.77, 0.42, 0.10)
      row.Label:SetTextColor(0.91, 0.77, 0.42, 1)
      row.CountText:SetTextColor(0.91, 0.77, 0.42, 1)
      row.CountBg:SetTexture(0.91, 0.77, 0.42, 0.10)
      row.Dot:SetTexture(dc[1], dc[2], dc[3], 1)
      if row.Strike then row.Strike:Hide() end
      if row.HiddenMark then row.HiddenMark:Hide() end
    else
      row.Bg:SetTexture(0, 0, 0, 0)
      row.CountText:SetTextColor(0.60, 0.64, 0.71, 1)
      row.CountBg:SetTexture(0.02, 0.02, 0.03, 0.55)
      if isHidden then
        row.Label:SetTextColor(0.42, 0.44, 0.50, 1)
        row.Dot:SetTexture(dc[1] * 0.35, dc[2] * 0.35, dc[3] * 0.35, 0.55)
        if row.Strike then
          row.Strike:Show()
          row.Strike:SetTexture(0.42, 0.44, 0.50, 0.9)
          local w = (row.Label.GetStringWidth and row.Label:GetStringWidth()) or 0
          row.Strike:SetWidth(w > 0 and w or 1)
        end
        if row.HiddenMark then row.HiddenMark:Show() end
      else
        row.Label:SetTextColor(0.87, 0.90, 0.96, 1)
        row.Dot:SetTexture(dc[1], dc[2], dc[3], 1)
        if row.Strike then row.Strike:Hide() end
        if row.HiddenMark then row.HiddenMark:Hide() end
      end
    end

    row:Show()
    y = y - CATEGORY_ROW_HEIGHT
  end

  for i = #cats + 1, #categoryRows do
    categoryRows[i]:Hide()
  end

  if updateScrollbar then updateScrollbar(frame.CategoryScroll, -y) end
end

-- ============================================================
-- listing rows (right pane): intent tag, role icons+counts, class-colored
-- name, category-colored content pill, level, age, plus a dim pixel-fit
-- raw-message second line (see layoutListingRow / pixelFitRaw). Also shown
-- in full in the hover tooltip (UI.onRowEnter).
-- ============================================================

local function acquireListingRow(i, scrollChild)
  local row = listingRows[i]
  if not row then
    row = CreateFrame("Button", "YABBListingRow" .. i, scrollChild, "YABBListingRow")
    -- Position/height are NOT set here: they depend on the live
    -- compact-rows toggle, which can change after this row already
    -- exists (a pooled row is created once, reused forever) -- so
    -- renderListings positions every row, every render, instead
    -- (mirrors the rail's own acquireRailRow/placeRow split).
    row:SetScript("OnMouseDown", function(self, button) UI.onRowClick(self, button) end)
    row:SetScript("OnEnter", function(self) UI.onRowEnter(self) end)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- Role icon atlas + per-slot color are fixed per SLOT (not per
    -- listing), so they're set once here at creation rather than every
    -- render -- Compat.ROLE_ICON/ROLE_TEXCOORD give the real atlas
    -- sub-rects; SetVertexColor tints the icon, it must NOT be confused
    -- with SetTexture(r,g,b,a) (which would replace the atlas image with a
    -- flat color instead of tinting it).
    if ns.Compat and ns.Compat.ROLE_ICON and ns.Compat.ROLE_TEXCOORD then
      local iconPath = ns.Compat.ROLE_ICON
      for _, role in ipairs(ROLE_ORDER) do
        local tex = row[ROLE_SLOT_ICON[role]]
        local coord = ns.Compat.ROLE_TEXCOORD[role]
        local color = ROLE_COLOR[role]
        if tex and coord then
          tex:SetTexture(iconPath)
          tex:SetTexCoord(coord[1], coord[2], coord[3], coord[4])
          if color then tex:SetVertexColor(color[1], color[2], color[3], 1) end
        end
        local count = row[ROLE_SLOT_COUNT[role]]
        if count and color then
          count:SetTextColor(color[1], color[2], color[3], 1)
        end
      end
    end

    listingRows[i] = row
  end
  return row
end

local function renderRoleSlots(row, listing)
  if not displayOn("roleIcons") then
    for _, role in ipairs(ROLE_ORDER) do
      local icon = row[ROLE_SLOT_ICON[role]]
      local count = row[ROLE_SLOT_COUNT[role]]
      if icon then icon:Hide() end
      if count then count:Hide() end
    end
    return
  end
  for _, role in ipairs(ROLE_ORDER) do
    local icon = row[ROLE_SLOT_ICON[role]]
    local count = row[ROLE_SLOT_COUNT[role]]
    local need = listing.needCounts and listing.needCounts[role]
    local has = listing.roles and listing.roles[role]
    if need or has then
      if icon then icon:Show() end
      if count then
        if type(need) == "number" and need > 0 then
          count:SetText("x" .. need)
          count:Show()
        else
          count:Hide()
        end
      end
    else
      if icon then icon:Hide() end
      if count then count:Hide() end
    end
  end
end

-- rawAvailableWidth(row, pillRightTarget) -- pixel-accurate available width
-- for the Raw line, derived from the SAME two reflow decisions
-- layoutListingRow below just made: Name's just-resolved LEFT edge (already
-- reflow-aware for the roleIcons toggle -- see nameTarget) and
-- pillRightTarget's LEFT edge (the exact same frame PillBg's own RIGHT
-- anchor targets, already reflow-aware for the showLevel toggle). Read live
-- via GetLeft() rather than re-deriving the XML chain's pixel offsets by
-- hand, so this can never silently drift from the real anchors if that XML
-- ever changes. GetLeft() immediately after a same-frame SetPoint reflects
-- the NEW position on this client (WoW resolves a region's rect
-- synchronously on demand, not deferred a frame) -- the same assumption
-- row:GetWidth() already relies on elsewhere in this file right after its
-- own SetPoint (renderListings/wireScrollWidthSync). pcall-guarded per-call
-- since these are live WoW geometry calls on the render path; returns nil
-- (guarded call site falls back to RAW_FALLBACK_WIDTH) if either edge isn't
-- resolvable yet, e.g. a pooled row's very first render before it has ever
-- been shown.
local function rawAvailableWidth(row, pillRightTarget)
  if not (row and row.Name and pillRightTarget) then return nil end
  local ok1, left = pcall(row.Name.GetLeft, row.Name)
  local ok2, right = pcall(pillRightTarget.GetLeft, pillRightTarget)
  if not (ok1 and ok2 and type(left) == "number" and type(right) == "number") then
    return nil
  end
  local w = right - left - RAW_RIGHT_MARGIN
  if w < RAW_MIN_WIDTH then w = RAW_MIN_WIDTH end
  return w
end

-- Row reflow: the row's own anchor targets are recomputed here every
-- render from which display toggles are on, rather than a fixed
-- sibling-chain XML anchor (which would leave a hidden frame's rect -- and
-- therefore a gap -- in place regardless of Show/Hide). Every SetPoint
-- below re-asserts the SAME point name ("LEFT"/"RIGHT"/"TOPLEFT") every
-- call, so it cleanly replaces the prior render's anchor (or the XML
-- placeholder, first call) with no ClearAllPoints needed. PillBg's LEFT
-- point is deliberately left untouched: XML already anchors it
-- relativeTo="$parentName", so it tracks Name's live position for free
-- whenever Name moves, without this function touching it at all.
--
-- Also sizes the Raw line for pixel-fit truncation: Raw's XML-declared
-- width is only a placeholder -- rawAvailableWidth above recomputes its
-- real available width every render from the same nameTarget/
-- pillRightTarget reflow decisions made below, so it stays correct as
-- role icons / level are toggled off. Returns that width (or nil in
-- compact mode, where Raw is hidden) for renderListingRow to feed into
-- pixelFitRaw.
local function layoutListingRow(row)
  local roleIcons = displayOn("roleIcons")
  local showLevel = displayOn("showLevel")
  local compact = displayOn("compact")

  local nameTarget = roleIcons and row.RoleDpsCount or row.IntentBg
  local nameY = compact and 0 or NAME_Y_NORMAL
  -- Raise the whole first line, not just Name -- IntentBg and AgeText are
  -- the two row-relative anchor roots the rest of the line chains off
  -- (role icons off IntentBg, LevelText off AgeText, both via XML
  -- relativeTo -- untouched here), so moving these two is enough to bring
  -- every sibling along for free. x offsets (10 / -10) match the XML
  -- placeholders exactly; only the y changes. Name itself anchors at y=0
  -- since nameTarget already carries nameY -- this also keeps PillBg's
  -- XML-declared LEFT point (which tracks Name's RIGHT edge) and its
  -- Lua-set RIGHT point (pillRightTarget's LEFT edge, below) resolving to
  -- the same vertical centre, instead of disagreeing by nameY.
  row.IntentBg:SetPoint("LEFT", row, "LEFT", 10, nameY)
  row.AgeText:SetPoint("RIGHT", row, "RIGHT", -10, nameY)
  row.Name:SetPoint("LEFT", nameTarget, "RIGHT", 10, 0)
  row.Name:SetFontObject(compact and GameFontNormalSmall or GameFontNormal)

  local pillRightTarget = showLevel and row.LevelText or row.AgeText
  row.PillBg:SetPoint("RIGHT", pillRightTarget, "LEFT", -8, 0)

  local rawWidth
  if compact then
    row.Raw:Hide()
  else
    -- -3, not flush (0), so the tinted pill doesn't sit directly on top of
    -- the message line -- a 1px gap below PillBg's bottom edge.
    row.Raw:SetPoint("TOPLEFT", row.Name, "BOTTOMLEFT", 0, -3)
    rawWidth = rawAvailableWidth(row, pillRightTarget) or RAW_FALLBACK_WIDTH
    row.Raw:SetWidth(rawWidth)
    row.Raw:Show()
  end

  return rawWidth
end

local function renderListingRow(row, listing, now)
  row.listing = listing
  local rawWidth = layoutListingRow(row)

  -- The stripe is a category accent, computed once here (tc, below) and
  -- reused for PillBg/PillDot/PillText too. Reads ns.C.categories (via
  -- categoryColorOf) so a user-renamed/recolored/removed category tints
  -- every row correctly, with a neutral fallback if listing.category no
  -- longer has a row.
  local tc = categoryColorOf(listing.category)
  row.Stripe:SetTexture(tc[1], tc[2], tc[3], 0.7)

  -- A nil intent gets its own dimmed, distinct tag -- never silently
  -- rendered as "LFG" (see NEUTRAL_INTENT_LABEL's own note).
  local intent = listing.intent
  local ic = (intent and INTENT_COLOR[intent]) or NEUTRAL_INTENT_COLOR
  row.IntentBg:SetTexture(ic[1], ic[2], ic[3], intent and 0.16 or 0.08)
  row.IntentText:SetText(intent or NEUTRAL_INTENT_LABEL)
  row.IntentText:SetTextColor(ic[1], ic[2], ic[3], 1)

  renderRoleSlots(row, listing)

  local hex = displayOn("classColors") and posterClassInfo(listing) or CLASS_COLOR_OFF_HEX
  row.Name:SetText("|cff" .. hex .. tostring(listing.poster or "?") .. "|r")
  -- Raw chat text: pixel-fit via GetStringWidth against the reflow-aware
  -- width layoutListingRow just computed (rawWidth). rawWidth is nil
  -- precisely in compact mode (row.Raw hidden there, see
  -- layoutListingRow) -- skip the measure entirely instead of paying for
  -- it on a hidden line. Memoized on (rawText, rawWidth) so a row whose
  -- content hasn't changed since the last ~0.2s tick costs zero
  -- SetText/GetStringWidth calls in steady state, instead of up to 9 pairs
  -- per row every render. Measures/truncates a case-preserving,
  -- escape-stripped copy (Classifier.plainText) instead of the raw chat
  -- string, so a cut can never land mid |c/|H escape sequence (which both
  -- renders literally and corrupts the width measurement); plainText
  -- keeps every link's visible bracketed text (item/enchant/recipe/...),
  -- not just quest links, so "WTS [Thunderfury] pst" still shows the item
  -- name here.
  if rawWidth then
    local rawKey = tostring(listing.rawText) .. "|" .. tostring(rawWidth)
    if row._rawKey ~= rawKey then
      local plain = (ns.Classifier and ns.Classifier.plainText and ns.Classifier.plainText(listing.rawText))
        or tostring(listing.rawText or "")
      pixelFitRaw(row.Raw, plain, rawWidth)
      row._rawKey = rawKey
    end
  else
    row._rawKey = nil
  end

  row.PillBg:SetTexture(tc[1], tc[2], tc[3], 0.14)
  row.PillDot:SetTexture(tc[1], tc[2], tc[3], 1)
  row.PillText:SetText(pillText(listing))
  row.PillText:SetTextColor(tc[1], tc[2], tc[3], 1)

  if displayOn("showLevel") then
    local lvl = levelText(listing)
    row.LevelText:SetText(lvl)
    if lvl == "-" then
      row.LevelText:SetTextColor(0.39, 0.42, 0.49, 1)
    else
      row.LevelText:SetTextColor(0.80, 0.83, 0.90, 1)
    end
    row.LevelText:Show()
  else
    row.LevelText:Hide()
  end

  row.AgeText:SetText(formatAge(now - (listing.lastSeen or now)))

  row:Show()
end

function UI.renderListings()
  local frame = UI.frame
  if not frame or not frame.ListingScrollChild then return end

  local entries = activeEntries()
  local now = (ns.Ingest and ns.Ingest.now and ns.Ingest.now()) or 0
  local filterOpts = (UI.filterText ~= "" and { keyword = UI.filterText }) or nil

  local shown = {}
  for _, entry in ipairs(entries) do
    local include = true
    if filterOpts and ns.Filters and ns.Filters.match then
      include = ns.Filters.match(entry, filterOpts)
    end
    -- A nil-intent entry never coalesces into "LFG" here -- entry.intent
    -- == nil can never equal the "LFG"/"LFM" filter key, so an
    -- unknown-intent post is excluded from both filters and shows only
    -- under "All", matching its neutral tag (renderListingRow above). A
    -- wrong assertion is worse than a neutral one on a field players
    -- filter on directly.
    if include and UI.intentFilter and UI.intentFilter ~= "all" then
      include = entry.intent == UI.intentFilter
    end
    if include then shown[#shown + 1] = entry end
  end

  local rowH = currentRowHeight()
  for i, entry in ipairs(shown) do
    local row = acquireListingRow(i, frame.ListingScrollChild)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame.ListingScrollChild, "TOPLEFT", 0, -(i - 1) * rowH)
    row:SetPoint("RIGHT", frame.ListingScrollChild, "RIGHT", 0, 0)
    row:SetHeight(rowH)
    renderListingRow(row, entry, now)
  end
  for i = #shown + 1, #listingRows do
    listingRows[i]:Hide()
  end

  -- Empty state: nothing else distinguishes "listening, waiting for chat"
  -- from "broken". Two variants depending on whether the board has
  -- anything at all or the current view/filter just excludes it all.
  if frame.EmptyState then
    if #shown == 0 then
      local totalAll = (ns.board and ns.board.listAll and #ns.board:listAll()) or 0
      frame.EmptyState:SetText(totalAll == 0
        and "Listening to chat. Listings appear here as players post."
        or "No listings match this filter.")
      frame.EmptyState:Show()
    else
      frame.EmptyState:Hide()
    end
  end

  if updateScrollbar then updateScrollbar(frame.ListingScroll, #shown * rowH) end
end

-- ============================================================
-- titlebar chrome: server-pulse line + footer expiry text, both built
-- from live board state.
-- ============================================================

-- Just the total, no per-category breakdown -- that's redundant with the
-- rail's own counts, and would overflow into a literal "..." on a full
-- board. Short enough to never truncate against the titlebar's available
-- width.
local function buildPulseLine()
  local total = (ns.board and ns.board.listAll and #ns.board:listAll()) or 0
  return total .. " listings"
end

local function footerExpireText()
  local ttl = ns.board and ns.board.ttl
  if not ttl or ttl == 0 then
    return "listings never expire"
  end
  local mins = math.floor(ttl / 60)
  if mins < 1 then
    return "listings expire after " .. ttl .. "s"
  end
  return "listings expire after " .. mins .. "m"
end

function UI.Refresh()
  if not UI.frame then return end
  -- Board TTL sweep, on the already-throttled ~0.2s OnUpdate tick that
  -- drives this Refresh() while the window is shown, so open-window
  -- counts/rows stay accurate. Guarded on ns.board/ns.board.sweep existing
  -- (mirrors every other ns.board call site in this file) so a missing/
  -- stubbed board never errors the refresh. Ingest.lua carries the
  -- companion ~30s sweep for the closed-window case, since OnUpdate here
  -- never fires while hidden.
  if ns.board and ns.board.sweep then
    local now = (ns.Ingest and ns.Ingest.now and ns.Ingest.now()) or 0
    ns.board:sweep(now)
  end
  UI.renderCategories()
  UI.renderListings()
  if UI.frame.Pulse then UI.frame.Pulse:SetText(buildPulseLine()) end
  if UI.frame.FooterExpire then UI.frame.FooterExpire:SetText(footerExpireText()) end
  -- Verbose hook (/yabb log on|off): mirrors Ingest.lua's own
  -- ns.Diag.verbose-gated ns.Diag.log call -- streams every UI refresh into
  -- the same ring buffer /yabb dump's CLASSIFIER section reads.
  if ns.Diag and ns.Diag.verbose and ns.Diag.log then
    ns.Diag.log("UI refresh focus=" .. tostring(UI.focusCategory or ALL_RECENT) .. " filter=" .. tostring(UI.filterText))
  end
end

-- ============================================================
-- Interactions, modeled on GBB RequestList.lua:858-947
-- (ClickRequest/RequestShowTooltip/RequestHideTooltip): left-click
-- whisper, right-click menu (Whisper/Invite/Ignore), hover tooltip.
-- Left-click is whisper-only; invite lives only in the right-click menu.
-- /who is dead on Ascension (SendWho is server-neutered), so neither the
-- row menu nor the click handler offers it. Native API calls used in
-- place of GBB's own RunSlashCmd indirection (ChatFrame_OpenChat:
-- framexml/chatframe.lua:3587; InviteUnit: C-side, documented
-- PartyDocumentation.lua, used directly e.g.
-- framexml/unitpopup.lua:1319).
-- ============================================================

local menuFrame

local function buildRowMenu(listing)
  local poster = listing.poster
  return {
    { text = tostring(poster), isTitle = true, notCheckable = true },
    { text = "Whisper", notCheckable = true, func = function()
        if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. poster .. " ") end
      end },
    { text = "Invite", notCheckable = true, func = function()
        if InviteUnit then InviteUnit(poster) end
      end },
    { text = "Ignore", notCheckable = true, func = function()
        if AddIgnore then AddIgnore(poster) end
      end },
    { text = "Cancel", notCheckable = true },
  }
end

function UI.showRowMenu(listing)
  if not listing or not listing.poster then return end
  if not CreateFrame or not EasyMenu then return end
  if not menuFrame then
    menuFrame = CreateFrame("Frame", "YABBRowMenu", UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(buildRowMenu(listing), menuFrame, "cursor", 0, 0, "MENU")
end

function UI.onRowClick(row, button)
  local listing = row and row.listing
  if not listing or not listing.poster then return end
  local poster = listing.poster

  if button == "RightButton" then
    UI.showRowMenu(listing)
    return
  end
  -- Left-click is whisper only; invite lives in the right-click menu
  -- (buildRowMenu above). No modifier key is read on this path.
  if ChatFrame_OpenChat then ChatFrame_OpenChat("/w " .. poster .. " ") end
end

-- classFilename ("MAGE", "DEATHKNIGHT", ...) -> a player-facing class name.
-- LOCALIZED_CLASS_NAMES_MALE/_FEMALE both exist on 3.3.5; gender isn't
-- knowable for an arbitrary poster, so MALE is tried first, FEMALE second.
-- Ascension's custom classes (e.g. STARCALLER) aren't in either table, so
-- an unmapped token falls back to a title-cased copy of itself instead of
-- the raw all-caps token.
local function classDisplayName(classFilename)
  if type(classFilename) ~= "string" or classFilename == "" then return nil end
  local token = classFilename:upper()
  local localized = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token])
    or (LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[token])
  if localized then return localized end
  return token:sub(1, 1) .. token:sub(2):lower()
end

function UI.onRowEnter(row)
  local listing = row and row.listing
  if not listing or not GameTooltip then return end

  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(tostring(listing.poster or "?"), 1, 1, 1)

  local _, classFilename = posterClassInfo(listing)
  -- Tooltip shows the level plus its source when known (same resolvedLevel
  -- priority the row's own Level column uses, so they can never disagree).
  local lvl = resolvedLevel(listing)
  local levelLine
  if lvl.text ~= "-" then
    levelLine = "Level " .. lvl.text .. (lvl.source and (" (" .. lvl.source .. ")") or "")
  else
    levelLine = "Level unknown"
  end
  -- classFilename (from posterClassInfo, guid-resolved) is a real class
  -- FILE TOKEN and needs classDisplayName's upper->title-case/localize
  -- transform. listing.classTag (the Classifier's own text-parsed
  -- fallback) is already display-form -- possibly multi-word, already
  -- properly cased Ascension custom class name -- so it's passed through
  -- untouched; running it through classDisplayName would upper-case then
  -- title-case it and mangle anything but a single capitalized word.
  local classText = classDisplayName(classFilename) or listing.classTag
  GameTooltip:AddLine(classText and (levelLine .. " " .. classText) or levelLine, 0.8, 0.8, 0.8)

  if listing.category then
    local line = tostring(listing.category)
    if listing.target then line = line .. " - " .. listing.target end
    GameTooltip:AddLine(line, 0.6, 0.8, 1)
  end
  -- The raw line isn't pixel-measured/truncated the way the row's Raw line
  -- is, and GameTooltip:AddLine(..., true) wraps and renders |c/|H escapes
  -- natively, so it needs no stripping -- shown verbatim.
  if listing.rawText then
    GameTooltip:AddLine(tostring(listing.rawText), 0.9, 0.9, 0.9, true)
  end
  if listing.channelName then
    GameTooltip:AddLine("Channel: " .. tostring(listing.channelName), 0.5, 0.5, 0.5)
  end
  GameTooltip:Show()
end

-- ============================================================
-- static chrome tinting -- the flat no-file Texture regions UI.xml
-- declares (titlebar band/hairline, search box, pane divider, footer
-- hairline, rail section dividers) get their one-time color here via the
-- native `region:SetTexture(r,g,b,a)` numeric-color overload (see
-- UI.xml's own file-top note on this technique). None of these change
-- per-render, unlike the row/rail elements above.
-- ============================================================

local function tintStaticChrome(frame)
  if frame.TitlebarBg then frame.TitlebarBg:SetTexture(0.09, 0.10, 0.13, 0.5) end
  if frame.TitlebarLine then frame.TitlebarLine:SetTexture(0.91, 0.77, 0.42, 0.16) end
  if frame.FilterBg then frame.FilterBg:SetTexture(0.047, 0.055, 0.071, 0.9) end
  if frame.Divider then frame.Divider:SetTexture(0, 0, 0, 0.5) end
  if frame.FooterLine then frame.FooterLine:SetTexture(0.91, 0.77, 0.42, 0.14) end
  local sc = frame.CategoryScrollChild
  if sc then
    if sc.RailSep1 then sc.RailSep1:SetTexture(1, 1, 1, 0.08) end
  end
end

-- ============================================================
-- Themed scrollbars. Native UIPanelScrollFrameTemplate's
-- `$parent`+"ScrollBar"/"ScrollBarScrollUpButton"/"ScrollBarScrollDown
-- Button" global-name convention (the same naming FrameXML itself uses
-- everywhere it wires a scroll frame's own scrollbar, e.g. the well-known
-- ChatConfigFrameScrollFrameScrollBarScrollUpButton pattern), pcall-wrapped
-- and every step existence-guarded so a wrong/absent name degrades to a
-- silent no-op, never an error, same fail-soft posture as this file's
-- font-swap code. Buttons are hidden outright rather than reskinned:
-- click-to-scroll is fully covered by wireMouseWheel + thumb-drag already,
-- and removing the arrow art entirely is simpler and more robust than
-- guessing at each state-texture getter. The trough's own stock art is
-- stripped generically via GetRegions() (real 3.3.5 Texture/FontString
-- enumeration, not a guessed name) rather than by name, skipping only the
-- live thumb texture (identity-compared, never hidden) -- then a thin
-- native SetBackdrop
-- (never BackdropTemplate) draws the dark track, and the thumb itself is
-- reskinned to a slim flat gold bar via the same SetTexture(r,g,b,a)
-- numeric-color overload this file already uses for every other flat
-- region.
-- ============================================================

local function themeScrollbar(scrollFrame)
  local function run()
    if not scrollFrame or not scrollFrame.GetName then return end
    local name = scrollFrame:GetName()
    if not name then return end
    local bar = _G[name .. "ScrollBar"]
    if not bar then return end

    local upBtn = _G[name .. "ScrollBarScrollUpButton"]
    local downBtn = _G[name .. "ScrollBarScrollDownButton"]
    if upBtn then upBtn:Hide() end
    if downBtn then downBtn:Hide() end

    local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
    if thumb and bar.GetRegions then
      local regions = { bar:GetRegions() }
      for _, region in ipairs(regions) do
        if region ~= thumb and region.GetObjectType and region:GetObjectType() == "Texture" then
          region:Hide()
        end
      end
    end

    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(bar, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
        bgColor = { 0.02, 0.02, 0.03, 0.5 },
        borderColor = { 1, 1, 1, 0.06 },
      })
    end

    if thumb then
      thumb:SetTexture(0.91, 0.77, 0.42, 0.9)
      thumb:SetWidth(6)
    end

    -- Replace the stock handler: ScrollFrame_OnScrollRangeChanged
    -- (SharedXML/Scroll/ScrollFrame.lua) unconditionally re-Shows the arrow
    -- buttons just hidden above the instant content overflows, so the
    -- one-shot Hide is not durable. Routing range changes through this
    -- file's own updater keeps the arrows suppressed and drives auto-hide
    -- + proportional thumb sizing on every range change (e.g. an EditBox
    -- scroll pane, whose child height this file does not own -- see
    -- updateScrollbar's no-contentHeight branch).
    scrollFrame:SetScript("OnScrollRangeChanged", function(self)
      if updateScrollbar then updateScrollbar(self) end
    end)
  end
  runGuarded(run, "UI.themeScrollbar")
end

local MIN_THUMB_HEIGHT = 20 -- draggable floor; client's own uses max(52,..) on a 16px-wide bar, ours is 6px slim

-- updateScrollbar(scrollFrame, contentHeight)
-- contentHeight = the TRUE (unclamped) content height. Omit it to reuse the
-- last one (resize path) or, for engine-sized children (EditBox panes), to
-- take the GetVerticalScrollRange() branch instead. Never reads
-- GetVerticalScrollRange() for a pane whose child height is set here
-- directly -- that value is a frame stale (Cell Widgets.lua:2756-2758,
-- Chattynator Widgets.lua:479-484).
updateScrollbar = function(scrollFrame, contentHeight)
  if not scrollFrame then return end
  local function run()
    local name = scrollFrame.GetName and scrollFrame:GetName()
    if not name then return end
    local bar = _G[name .. "ScrollBar"]
    if not bar then return end

    local viewH = scrollFrame:GetHeight() or 0
    if viewH <= 0 then return end -- not laid out yet; a later call fixes it

    local range
    if contentHeight or scrollFrame._contentHeight then
      contentHeight = contentHeight or scrollFrame._contentHeight
      scrollFrame._contentHeight = contentHeight
      local child = scrollFrame.GetScrollChild and scrollFrame:GetScrollChild()
      if child then child:SetHeight(contentHeight > viewH and contentHeight or viewH) end
      range = contentHeight - viewH
    else
      -- engine-sized child (EditBox panes): only valid from OnScrollRangeChanged
      range = scrollFrame:GetVerticalScrollRange() or 0
    end
    if range < 0 then range = 0 end

    if bar.SetMinMaxValues then bar:SetMinMaxValues(0, range) end
    local v = (bar.GetValue and bar:GetValue()) or 0
    if v > range and bar.SetValue then bar:SetValue(range) end

    -- durable arrow suppression: ScrollFrame_OnScrollRangeChanged re-Shows
    -- these every time range goes > 0 (ScrollFrame.lua:191-192)
    local up, down = _G[name .. "ScrollBarScrollUpButton"], _G[name .. "ScrollBarScrollDownButton"]
    if up then up:Hide() end
    if down then down:Hide() end

    local thumb = bar.GetThumbTexture and bar:GetThumbTexture()

    if math.floor(range) <= 0 then -- same threshold the client uses
      if (scrollFrame:GetVerticalScroll() or 0) > 0 then
        scrollFrame:SetVerticalScroll(0) -- Cell Widgets.lua:2752
      end
      if thumb then thumb:Hide() end
      bar:Hide()
      return
    end

    local barH = bar:GetHeight() or 0
    if thumb and barH > 0 then
      local h = barH * (viewH / (viewH + range)) -- == trackH * viewport/content
      if h < MIN_THUMB_HEIGHT then h = MIN_THUMB_HEIGHT end
      if h > barH then h = barH end
      thumb:SetHeight(h)
      thumb:Show()
    end
    bar:Show()
  end
  runGuarded(run, "UI.updateScrollbar")
end

-- ============================================================
-- Titlebar All/LFG/LFM filter. Plain CreateFrame("Button") + applyBackdrop
-- + a FontString throughout -- matches this file's/FiltersUI.lua's own
-- existing themed-button idiom (e.g. FiltersUI.lua's chip/toggle pools)
-- rather than a stock template, so it never needs restyling: it's themed
-- from the moment it's created.
-- ============================================================

local intentFilterButtons = {}

local function styleIntentFilterButton(btn)
  if not (ns.Compat and ns.Compat.applyBackdrop) then return end
  ns.Compat.applyBackdrop(btn, {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile = false, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
    bgColor = { 0.047, 0.055, 0.071, 0.9 },
    borderColor = { 1, 1, 1, 0.14 },
  })
end

local function buildIntentFilter(frame)
  local container = CreateFrame("Frame", "YABBIntentFilter", frame)
  container:SetHeight(20)

  local prevBtn, totalW = nil, 0
  for i, opt in ipairs(INTENT_FILTER_OPTIONS) do
    local btn = CreateFrame("Button", nil, container)
    btn:SetHeight(20)
    styleIntentFilterButton(btn)
    btn.Text = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    btn.Text:SetPoint("CENTER")
    btn.Text:SetText(opt.label)
    local w = (btn.Text:GetStringWidth() or 24) + 16
    btn:SetWidth(w)
    btn:ClearAllPoints()
    if prevBtn then
      btn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
    else
      btn:SetPoint("LEFT", container, "LEFT", 0, 0)
    end
    btn:SetScript("OnClick", function()
      UI.intentFilter = opt.key
      if type(YABB_DB) ~= "table" then YABB_DB = {} end
      YABB_DB.intentFilter = opt.key
      UI.renderIntentFilter()
      UI.renderListings()
    end)
    intentFilterButtons[i] = btn
    prevBtn = btn
    totalW = totalW + w + (i > 1 and 4 or 0)
  end
  container:SetWidth(totalW > 0 and totalW or 1)
  return container
end

-- Active-segment highlight, mirrors renderCategories'/FiltersUI's own
-- gold-when-active / dim-otherwise convention. Safe to call before the
-- control exists (guards on the pooled buttons being populated).
function UI.renderIntentFilter()
  for i, opt in ipairs(INTENT_FILTER_OPTIONS) do
    local btn = intentFilterButtons[i]
    if btn then
      if UI.intentFilter == opt.key then
        btn.Text:SetTextColor(0.91, 0.77, 0.42, 1)
        if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.5) end
        if btn.SetBackdropColor then btn:SetBackdropColor(0.91, 0.77, 0.42, 0.10) end
      else
        btn.Text:SetTextColor(0.60, 0.64, 0.71, 1)
        if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(1, 1, 1, 0.14) end
        if btn.SetBackdropColor then btn:SetBackdropColor(0.047, 0.055, 0.071, 0.9) end
      end
    end
  end
end

-- ============================================================
-- init / Show / Hide / Toggle
-- ============================================================

function UI.init()
  if UI.frame then return true end
  if not CreateFrame then return false end

  local frame = _G and _G["YABBFrame"]
  if not frame then return false end
  UI.frame = frame

  -- Resolve scroll children via the native GetScrollChild() rather than
  -- trusting parentKey resolution inside a nested <ScrollChild> block --
  -- GetScrollChild() is unconditionally reliable regardless of that.
  frame.CategoryScrollChild = frame.CategoryScroll and frame.CategoryScroll.GetScrollChild
    and frame.CategoryScroll:GetScrollChild()
  frame.ListingScrollChild = frame.ListingScroll and frame.ListingScroll.GetScrollChild
    and frame.ListingScroll:GetScrollChild()

  -- Escape-key close (GBB: GroupBulletinBoard.lua:586, tinsert UISpecialFrames).
  if UISpecialFrames and tinsert then
    tinsert(UISpecialFrames, "YABBFrame")
  end

  -- THE BACKDROP RULE: native SetBackdrop only, via ns.Compat.applyBackdrop
  -- -- never "BackdropTemplate", not even via the "X and Y or nil" ternary
  -- (see Compat.lua's own header for why). WHITE8x8 is a real, widely-used
  -- stock solid-fill texture on this exact client (LibSharedMedia's own
  -- default background/statusbar entry; LibCustomGlow's `white` texture --
  -- both confirmed live in the client's Interface\AddOns\Cell_Ascension\
  -- Libs\...), tinted here to a dark ground plus gold hairline.
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(frame, {
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false,
      edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
      bgColor = { 0.047, 0.055, 0.071, 0.97 },
      borderColor = { 0.91, 0.77, 0.42, 0.45 },
    })
  end

  tintStaticChrome(frame)

  -- Wordmark: swap to the client's own serif-ish quest-title font,
  -- pcall-guarded since this is a live font-load call; falls back to the
  -- XML-inherited GameFontNormalLarge if it ever fails.
  if frame.Title and frame.Title.SetFont then
    runGuarded(function() frame.Title:SetFont("Fonts\\MORPHEUS.TTF", 20, "") end, "UI.wordmarkFont")
    frame.Title:SetTextColor(0.91, 0.77, 0.42, 1)
  end

  -- Settings gear: real stock options-cog texture (Interface\Buttons\
  -- UI-OptionsButton, confirmed live via Details/Details_EncounterDetails
  -- -- see UI.xml's own citation). Opens the settings panel
  -- (channels/expiry/display), not the rules editor directly -- settings
  -- is the natural gear target; the rules editor is one click away via its
  -- own "Edit categories & rules" button. Guarded: a broken/missing
  -- FiltersUI load degrades this to a silent no-op, never an error.
  if frame.GearButton then
    frame.GearButton:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    frame.GearButton:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
    local hi = frame.GearButton.GetHighlightTexture and frame.GearButton:GetHighlightTexture()
    if hi and hi.SetBlendMode then hi:SetBlendMode("ADD") end
    frame.GearButton:SetScript("OnClick", function()
      if ns.FiltersUI and ns.FiltersUI.openSettings then
        ns.FiltersUI.openSettings()
      end
    end)
  end

  if frame.FilterBox then
    frame.FilterBox:SetFontObject(ChatFontNormal)
    frame.FilterBox:SetTextColor(0.87, 0.90, 0.96, 1)
    frame.FilterBox:SetAutoFocus(false)
    frame.FilterBox:SetScript("OnTextChanged", function(self)
      UI.filterText = (self:GetText() or ""):lower()
      UI.renderListings()
    end)
  end

  -- LFG/LFM filter: built purely in Lua (no UI.xml change needed), slotted
  -- between the pulse line and the search box. frame.Pulse's LEFT anchor
  -- (VersionText->Pulse, XML-declared) is untouched; only its RIGHT point
  -- is redirected here, from FilterBg to the new control -- WoW replaces a
  -- same-named anchor point in place, so this needs no ClearAllPoints and
  -- can't leave a stray old anchor behind.
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  UI.intentFilter = YABB_DB.intentFilter or UI.intentFilter or "all"

  -- Apply the persisted hidden-category set: the hidden set survives
  -- /reload, focus does not -- UI.focusCategory is left alone here, still
  -- its module-default nil. Rebuilt into a fresh table rather than pointed
  -- straight at YABB_DB.hiddenCategories so a later
  -- persistHiddenCategories() call always writes a clean true-only copy
  -- regardless of what a hand-edited SavedVariables file contains.
  UI.hiddenCategories = {}
  -- Type-guard: a hand-corrupted SavedVariables (hiddenCategories set to a
  -- non-table) must not throw here -- an unguarded pairs() would abort the
  -- whole UI init and the board would never open (fail-soft, not fail-hard).
  if type(YABB_DB.hiddenCategories) == "table" then
    for name, v in pairs(YABB_DB.hiddenCategories) do
      if v then UI.hiddenCategories[name] = true end
    end
  end

  -- Window position/size: restore before anything lays out against the
  -- frame's size. Every field is independently type- and range-guarded
  -- with fall-through to the XML default (CENTER, 900x560) -- a corrupt
  -- SavedVariables must degrade to that default, never abort init.
  if type(YABB_DB.window) == "table" then
    local w = YABB_DB.window
    if type(w.point) == "string" and type(w.x) == "number" and type(w.y) == "number" then
      local relPoint = type(w.relPoint) == "string" and w.relPoint or w.point
      frame:ClearAllPoints()
      frame:SetPoint(w.point, UIParent, relPoint, w.x, w.y)
    end
    if type(w.width) == "number" and w.width >= 660 then frame:SetWidth(w.width) end
    if type(w.height) == "number" and w.height >= 400 then frame:SetHeight(w.height) end
  end

  if frame.FilterBg then
    frame.IntentFilter = buildIntentFilter(frame)
    frame.IntentFilter:SetPoint("RIGHT", frame.FilterBg, "LEFT", -12, 0)
    if frame.Pulse then
      frame.Pulse:SetPoint("RIGHT", frame.IntentFilter, "LEFT", -16, 0)
    end
    UI.renderIntentFilter()
  end

  if frame.VersionText then
    frame.VersionText:SetText(tostring(ns.VERSION or ""))
  end

  -- Empty-state line, centered over the listings pane. Created here (not
  -- at module scope, since it needs a real parent frame) and toggled by
  -- renderListings.
  if frame.ListingScroll and frame.ListingScroll.CreateFontString then
    frame.EmptyState = frame.ListingScroll:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    frame.EmptyState:SetPoint("CENTER", frame.ListingScroll, "CENTER", 0, 0)
    frame.EmptyState:Hide()
  end

  wireScrollWidthSync(frame.CategoryScroll, frame.CategoryScrollChild)
  wireScrollWidthSync(frame.ListingScroll, frame.ListingScrollChild)
  wireMouseWheel(frame.ListingScroll)
  wireMouseWheel(frame.CategoryScroll)
  themeScrollbar(frame.CategoryScroll)
  themeScrollbar(frame.ListingScroll)

  -- Save window position/size after a drag or resize completes. Hooked
  -- from Lua -- HookScript adds a handler alongside the XML-declared
  -- OnDragStop/OnMouseUp (which still do the actual StartMoving/
  -- StopMovingOrSizing) rather than referencing an addon global from
  -- inline XML.
  if frame.HookScript then
    frame:HookScript("OnDragStop", UI.saveWindowState)
  end
  if frame.ResizeGrip and frame.ResizeGrip.HookScript then
    frame.ResizeGrip:HookScript("OnMouseUp", UI.saveWindowState)
  end

  frame:SetScript("OnShow", function() UI.Refresh() end)

  -- ~0.2s throttled refresh while shown. OnUpdate does not fire while the
  -- frame is hidden, so this is inherently "while shown".
  local elapsedAccum = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedAccum = elapsedAccum + elapsed
    if elapsedAccum >= REFRESH_INTERVAL then
      elapsedAccum = 0
      UI.Refresh()
    end
  end)

  -- Poster level/class enrichment lives entirely in ns.Players -- Init.lua's
  -- orchestrator starts it once at PLAYER_LOGIN. This file never registers
  -- WHO_LIST_UPDATE and never calls /who (dead on Ascension), and
  -- UI.renderListings never auto-enqueues anything either.

  UI.Refresh()
  return true
end

function UI.Show()
  if not UI.frame and not UI.init() then return end
  UI.frame:Show()
end

function UI.Hide()
  if UI.frame then UI.frame:Hide() end
end

function UI.Toggle()
  if not UI.frame and not UI.init() then return end
  if UI.frame:IsShown() then
    UI.frame:Hide()
  else
    UI.frame:Show()
  end
end

-- No self-bootstrap here: UI.init() is invoked exactly once by Init.lua's
-- central fail-soft orchestrator (loads last in the TOC), not self-invoked
-- at file end. It never shows the window itself -- quiet by default --
-- init only builds the frame and wires its scripts; UI.Show()/UI.Toggle()
-- (both already idempotent-safe via `if not UI.frame and not UI.init()
-- then return end`) still lazily call UI.init() too, so an /yabb toggle
-- before the orchestrator has run (or after a failed orchestrated init)
-- still works.

return UI
