local ADDON, ns = ...
ns.FiltersUI = ns.FiltersUI or {}
local FiltersUI = ns.FiltersUI

-- ============================================================
-- Rules editor: a two-tab config window over the classifier's live
-- tables.
--
--   Categories tab -- ns.C.categories, an ordered {name, color} list.
--   Reorder, recolor, rename (also retargets every pipeline outcome
--   that pointed at the old name), remove, add, or reset to defaults.
--   A category's only state is whether it's in the list, and where.
--
--   Priority & Rules tab -- ns.C.pipeline, an ordered, first-match-wins
--   matcher list. Each entry has a name, a pattern list (plain text or
--   Lua pattern), and an outcome: route to a category, do nothing, or
--   hide. The live-test box runs the real classifier
--   (Classifier.categoryOfDebug) against a typed line and shows which
--   entry decided it.
--
-- Persistence: YABB_DB.userConfig.categories/.pipeline are the
-- canonical editable arrays. An empty {} means "not customized"
-- (Filters.applyOverlay's own fall-back-to-defaults sentinel). Opening
-- the editor materializes both with a deep copy of the shipped
-- defaults so there are real rows to edit; applyPersisted (run once at
-- login) deliberately does not materialize, so an untouched install
-- stays on defaults and a saved legacy config still migrates correctly
-- on first load. Every edit mutates db() in place, then calls
-- FiltersUI.reapply(), which re-applies the overlay and refreshes the
-- board.
--
-- "Reset to defaults" is a genuine, destructive reset (see
-- FiltersUI.performFullReset), gated behind a two-click arm-then-
-- confirm state shared by both tabs' buttons.
--
-- Public entry points other files call into: FiltersUI.showCopyWindow
-- (Dump.lua/Diag.lua) and FiltersUI.openSettings() (UI.lua's titlebar
-- gear button).
--
-- Every frame here is a plain, template-less CreateFrame (or a stock
-- non-Backdrop template such as UIPanelButtonTemplate/
-- UIPanelScrollFrameTemplate/UIDropDownMenuTemplate), styled only via
-- ns.Compat.applyBackdrop's native SetBackdrop calls. Never
-- "BackdropTemplate", not even via the nil-safe "and X or nil" ternary
-- (see Compat.lua for why). Every EditBox here is template-less too:
-- InputBoxTemplate's fixed-size 3-slice border art doesn't scale to
-- this panel's short row fields and renders as a floating outline over
-- unreadable text (see themeEditBox's own header note). No WoW global
-- is read at module (file) load scope -- every CreateFrame/UIParent/
-- EasyMenu reference lives inside a function body, so this file loads
-- clean under the plain-Lua test stub.
-- ============================================================

local PANEL_W, PANEL_H = 760, 580
local CONTENT_W = 700
local TEST_SECTION_H = 78
local SCROLL_STEP = 24
local ROW_H = 26
local ROW_GAP = 5

-- Priority & Rules tab, pinned footer: panel.RulesPinned sits outside
-- panel.BodyScroll/BodyScrollChild entirely -- a sibling of the scroll,
-- not a child of panel.RulesBody -- so only the matcher rows themselves
-- ever scroll; the "+ Add matcher"/"Reset to defaults" row and the live
-- test box stay fixed at the bottom of the panel regardless of scroll
-- position. PINNED_ROW_H is the add/reset button row's own height
-- allotment; PINNED_GAP separates it from the test box below it.
local PINNED_ROW_H = 26
local PINNED_GAP = 6
local RULES_PINNED_H = PINNED_ROW_H + PINNED_GAP + TEST_SECTION_H

-- Fixed swatch palette -- a small grid rather than the native
-- ColorPickerFrame, simpler to render and verify.
local COLORS = {
  { 0.42, 0.76, 0.42 }, { 0.29, 0.56, 0.85 }, { 0.69, 0.42, 0.84 }, { 0.85, 0.38, 0.23 },
  { 0.88, 0.59, 0.23 }, { 0.95, 0.82, 0.29 }, { 0.24, 0.78, 0.78 }, { 0.84, 0.29, 0.35 },
  { 0.49, 0.52, 0.58 }, { 0.91, 0.77, 0.42 }, { 0.61, 0.55, 1.00 }, { 0.34, 0.78, 0.64 },
  { 1.00, 0.62, 0.43 }, { 0.78, 0.44, 0.63 }, { 0.55, 0.83, 0.31 }, { 0.35, 0.66, 1.00 },
}

-- Outcome/dot colors for the two set-apart pipeline actions. AUTO_COLOR
-- renders a category outcome that has no .name -- a defensive fallback
-- for a hand-edited or not-yet-migrated pipeline entry; every entry the
-- editor itself creates always sets a name (see outcomeLabel's matching
-- "Auto (varies)" fallback text below).
local NOTHING_COLOR = { 0.49, 0.52, 0.58 }
local HIDE_COLOR = { 0.82, 0.35, 0.42 }
local AUTO_COLOR = { 0.91, 0.77, 0.42 }
local NEUTRAL_COLOR = { 0.5, 0.53, 0.6 }

-- Friendly display labels for the two pattern kinds that aren't
-- inline-editable in the Priority & Rules tab: {kind="catalog"} (the
-- datamined worldboss/raid/dungeon name lists) and {kind="special"}
-- (structural predicates: questlink/questword/catchall). Purely
-- cosmetic -- the actual matching logic lives in Classifier.lua
-- (patternMatchesCatalog/patternMatchesSpecial) and is never duplicated
-- here.
local CATALOG_NAME = { worldboss = "World Boss", raid = "Raid", dungeon = "Dungeon" }
local SPECIAL_SHORT = { questlink = "quest-link", questword = "quest-word", catchall = "catch-all" }
local SPECIAL_DESC = {
  questlink = "a |Hquest| hyperlink is in the message",
  questword = "the standalone \"quest\"/\"quests\" keyword",
  catchall = "matches every remaining line (catch-all)",
}

-- patternText/patternSummary -- pure, no WoW API: format one pattern / a
-- whole matcher's pattern list into the compact text the collapsed row
-- header shows. Public so tests/*_spec.lua can exercise the exact
-- formatter the header renders without a live client -- pure logic is
-- unit-tested directly, frame code only in-game.
function FiltersUI.patternText(p)
  if type(p) ~= "table" then return "?" end
  if p.kind == "keyword" then return tostring(p.value or "") end
  if p.kind == "regex" then return "/" .. tostring(p.value or "") .. "/" end
  if p.kind == "catalog" then return "[" .. (CATALOG_NAME[p.value] or tostring(p.value or "?")) .. "]" end
  if p.kind == "special" then return "{" .. (SPECIAL_SHORT[p.id] or tostring(p.id or "?")) .. "}" end
  return "{?}"
end

function FiltersUI.patternSummary(entry)
  local patterns = (type(entry) == "table" and type(entry.patterns) == "table") and entry.patterns or {}
  if #patterns == 0 then return "(no patterns yet)" end
  local parts = {}
  for i = 1, #patterns do parts[#parts + 1] = FiltersUI.patternText(patterns[i]) end
  return table.concat(parts, "  ")
end

-- clipText -- pure, no WoW API: character-count truncation with an ASCII
-- "..." suffix when `text` exceeds `maxChars`. Used to hard-cap the
-- collapsed header's Name/Summary FontStrings (see acquireRuleRow's
-- row.Name/row.Summary below) so a long matcher name can never grow
-- past its allotted box and starve/overrun the MATCH marker/outcome
-- dropdown/remove x; WoW 3.3.5 FontStrings don't reliably clip or
-- ellipsize overflow on their own, so the string itself is bounded
-- before SetText rather than left to the client's word-wrap.
function FiltersUI.clipText(text, maxChars)
  text = (type(text) == "string") and text or tostring(text or "")
  maxChars = tonumber(maxChars)
  if not maxChars or maxChars < 1 or #text <= maxChars then return text end
  if maxChars <= 3 then return text:sub(1, maxChars) end
  return text:sub(1, maxChars - 3) .. "..."
end

FiltersUI.activeTab = FiltersUI.activeTab or "cats"
FiltersUI.testLine = FiltersUI.testLine or ""
FiltersUI.pendingCatColor = FiltersUI.pendingCatColor or COLORS[10]
-- Which matcher rows are expanded, keyed by pipeline POSITION (1-based)
-- -- in-memory UI state only, never persisted, and not remapped when a
-- matcher is reordered/inserted/removed, so "row 3 is expanded" survives
-- a swap as "whatever is now at position 3 is expanded", not "the same
-- matcher stays expanded".
FiltersUI.rulesOpen = FiltersUI.rulesOpen or {}

-- Fail-soft wrapper for a fire-and-forget call: routes through
-- Compat.guard (tags the error for Diag's verbose log) when it's
-- available, otherwise degrades to a bare pcall -- identical
-- swallow-the-error behavior either way once verbose logging is off,
-- which is the default.
local function runGuarded(fn, tag)
  if ns.Compat and ns.Compat.guard then
    ns.Compat.guard(fn, tag)
  else
    pcall(fn)
  end
end

-- ============================================================
-- persistence -- YABB_DB.userConfig, always fully shaped so every other
-- function below can index straight into cfg.X without a nil guard.
-- categories/pipeline default to {} -- Filters.applyOverlay's own
-- "not customized" sentinel (Filters.lua reconcileList), NOT materialized
-- here (see this file's header note on why materialization is deferred
-- to openEditor).
-- ============================================================

local function db()
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  if type(YABB_DB.userConfig) ~= "table" then YABB_DB.userConfig = {} end
  local cfg = YABB_DB.userConfig
  -- Type-guard before any #/ipairs use below: a corrupt or hand-edited
  -- SavedVariables entry (or a bad import) could set either field to a
  -- non-table. Filters.lua's own reconcileList covers this too, but this
  -- file reads userConfig.categories/.pipeline BEFORE applyOverlay/
  -- reconcileList ever runs (openEditor -> this), so it needs its own
  -- guard.
  if type(cfg.categories) ~= "table" then cfg.categories = {} end
  if type(cfg.pipeline) ~= "table" then cfg.pipeline = {} end
  return cfg
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Materialize: if either saved array is still the empty "use defaults"
-- sentinel, fill it with a deep copy of the shipped default so the editor
-- has real, mutable rows. A no-op once either has ever been edited/saved.
local function ensureMaterialized()
  local cfg = db()
  local Cls, Filters = ns.Classifier, ns.Filters
  local dc = (Filters and Filters.deepcopy) or function(t) return t end
  if #cfg.categories == 0 then
    cfg.categories = dc((Cls and Cls.DEFAULT_CATEGORIES) or (ns.C and ns.C.categories) or {})
  end
  if #cfg.pipeline == 0 then
    cfg.pipeline = dc((Cls and Cls.DEFAULT_PIPELINE) or (ns.C and ns.C.pipeline) or {})
  elseif Filters and Filters.migratePipelineToR12 then
    -- A saved pipeline from before the uniform {name,patterns,outcome}
    -- shape is migrated once, here, in place. migratePipelineToR12 is
    -- idempotent (it returns the SAME table object once every entry
    -- already carries .patterns), so this keeps cfg.pipeline ==
    -- ns.C.pipeline (same table object, not just equal contents) after
    -- the next reapply()/applyOverlay call, exactly like categories
    -- already are -- without this, a legacy user's cfg.pipeline would
    -- stay old-shaped forever while ns.C.pipeline (applyOverlay's own
    -- migrated copy) silently diverged into a separate table.
    cfg.pipeline = Filters.migratePipelineToR12(cfg.pipeline, ns.C)
  end
  return cfg
end

-- ============================================================
-- "Reset to defaults" -- a genuine, destructive reset, reachable from a
-- button on either tab (shared handler/state below), that wholesale-
-- replaces db().categories/.pipeline with a fresh deep copy of the
-- shipped Classifier.DEFAULT_CATEGORIES/DEFAULT_PIPELINE -- exact
-- default names, colors, order, and pipeline -- discarding every user
-- modification (renames, reorders, recolors, custom categories,
-- custom/reordered rules). Calls the existing, already-tested
-- Filters.resetToDefaults against db() rather than re-implementing the
-- deep-copy, pointed at the persisted userConfig table instead of the
-- live ns.C -- reapply()'s own Filters.applyOverlay call immediately
-- after makes that persisted write take effect on ns.C too.
--
-- Confirmation: gated behind a two-click "arm, then confirm" pattern
-- (FiltersUI.resetArmed) rather than firing on a single click. Arming
-- does not touch categories/pipeline at all, only flips the shared flag
-- and restyles the button; a second click while armed performs the
-- actual reset. Switching tabs or reopening the editor cancels an
-- armed-but-unconfirmed click (see the TabCats/TabRules/openEditor call
-- sites below) so a stray click on the OTHER tab's button (shared
-- state, different physical button) can never land a reset nobody
-- confirmed.
-- ============================================================

FiltersUI.resetArmed = FiltersUI.resetArmed or false

-- Cancels an armed-but-unconfirmed reset click without performing it.
-- Pure state flip -- safe to call unconditionally (tab switches, editor
-- open) even when nothing is armed.
function FiltersUI.cancelResetArm()
  FiltersUI.resetArmed = false
end

-- The actual destructive reset -- see the header note above. Always
-- performs the reset immediately (no confirm gate of its own); callers
-- that need the two-click gate go through FiltersUI.requestReset below.
-- Pure enough to unit-test directly under the plain-Lua stub: only touches
-- YABB_DB (via db()) and calls through FiltersUI.reapply/renderActiveTab,
-- both of which already guard on the WoW-only bits they need (FiltersUI.panel
-- nil under the stub -- see this file's header note on the test convention).
function FiltersUI.performFullReset()
  local cfg = db()
  if ns.Filters and ns.Filters.resetToDefaults then
    ns.Filters.resetToDefaults(cfg)
  else
    -- Defensive fallback if ns.Filters is ever missing entirely (should
    -- never happen in a real load, matches this file's own guard style
    -- elsewhere, e.g. ensureMaterialized's identical dc() fallback).
    local Cls = ns.Classifier
    local dc = function(t) return t end
    cfg.categories = dc((Cls and Cls.DEFAULT_CATEGORIES) or {})
    cfg.pipeline = dc((Cls and Cls.DEFAULT_PIPELINE) or {})
  end
  FiltersUI.resetArmed = false
  FiltersUI.reapply()
end

-- Two-click gate: first call arms (re-renders so the button shows the
-- confirm state), second call while armed performs the reset. Shared by
-- both tabs' Reset buttons (FiltersUI.resetArmed is not per-tab).
function FiltersUI.requestReset()
  if FiltersUI.resetArmed then
    FiltersUI.performFullReset()
    return
  end
  FiltersUI.resetArmed = true
  FiltersUI.renderActiveTab()
  local panel = FiltersUI.panel
  if panel and panel.Status then
    panel.Status:SetText("|cffff8040Click again to confirm -- this can't be undone|r")
  end
end

-- Applies whatever is already saved, at addon load. pcall-wrapped around
-- applyOverlay itself: a hostile or hand-corrupted userConfig table must
-- not be able to raise here, since that would abort FiltersUI.init()
-- with no in-game recovery (Filters.applyOverlay has its own type
-- guards on the overlay keys; this is the backstop for anything those
-- guards miss).
function FiltersUI.applyPersisted()
  local cfg = db()
  if ns.Filters and ns.Filters.applyOverlay and ns.C then
    pcall(ns.Filters.applyOverlay, ns.C, cfg)
  end
  -- Apply the persisted expiry (YABB_DB.expiry, seconds; 0/nil handled by
  -- Board.lua's own setTtl) to the live board so a saved setting actually
  -- survives reload/relog instead of reverting to Board.lua's DEFAULT_TTL
  -- every login. Only calls setTtl when a value has actually been
  -- configured AND is a number (type(...)=="number", not just ~= nil):
  -- Board:sweep does `now - entry.lastSeen > self.ttl`, which throws on a
  -- string/table, and this field is a raw SavedVariables read with no
  -- other gate between a hand-edited or corrupted file and that compare.
  -- Board:setTtl has its own matching guard as a second line of defense;
  -- this one just avoids ever calling it with garbage in the first place.
  runGuarded(function()
    if ns.board and ns.board.setTtl and YABB_DB and type(YABB_DB.expiry) == "number" then
      ns.board:setTtl(YABB_DB.expiry)
    end
  end, "FiltersUI.applyPersisted:setTtl")
end

-- Recompute + redraw everything: called after every edit. Safe to call
-- before the panel has ever been built (renderActiveTab guards on
-- FiltersUI.panel).
function FiltersUI.reapply()
  local cfg = db()
  if ns.Filters and ns.Filters.applyOverlay and ns.C then
    ns.Filters.applyOverlay(ns.C, cfg)
  end
  if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  FiltersUI.renderActiveTab()
  FiltersUI.scheduleBoardReeval()
end

-- ============================================================
-- Debounced board re-eval: reapply() only re-renders the editor, it
-- never re-runs the classifier over listings already on the board, so
-- an edit that changes what a line matches needs a separate sweep.
-- Every edit path in this file funnels through here (either via
-- reapply() above, or directly at the per-keystroke sites that
-- deliberately skip reapply()'s full re-render to avoid fighting the
-- field the player is actively typing into -- see layoutMatcherBody's
-- NameField/pr.Input handlers and the Categories rename handler).
--
-- Coalesced via a generation counter rather than trying to cancel a
-- pending Compat.after (this client has no timer handle to cancel):
-- every call bumps FiltersUI._reevalGen and captures it; when the
-- scheduled callback finally fires, it only proceeds if no LATER call
-- has bumped the counter since -- so ten edits in one second still only
-- run one real sweep, ~0.4s after the last one.
-- ============================================================

FiltersUI._reevalGen = FiltersUI._reevalGen or 0

-- The actual sweep: re-runs the real classifier over every current board
-- listing against the live ns.C, dropping anything newly rejected/hidden
-- and updating everything else's classification fields in place (see
-- Board.lua's own reclassifyAll header note).
function FiltersUI.runBoardReeval()
  runGuarded(function()
    if ns.board and ns.board.reclassifyAll and ns.Classifier and ns.Classifier.classify and ns.C then
      ns.board:reclassifyAll(ns.C, ns.Classifier.classify)
    end
  end, "FiltersUI.runBoardReeval")
  if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

function FiltersUI.scheduleBoardReeval()
  FiltersUI._reevalGen = FiltersUI._reevalGen + 1
  local myGen = FiltersUI._reevalGen
  if not (ns.Compat and ns.Compat.after) then return end
  ns.Compat.after(0.4, function()
    if FiltersUI._reevalGen == myGen then FiltersUI.runBoardReeval() end
  end)
end

-- ============================================================
-- shared color helpers -- category name -> {r,g,b}, and an outcome's
-- display color/label (category color / NOTHING_COLOR / HIDE_COLOR /
-- AUTO_COLOR for the dynamic-no-name case). Mirrored in UI.lua's own
-- categoryColorOf -- edit both together.
-- ============================================================

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
  return NEUTRAL_COLOR
end

-- type(outcome)=="table" guard: a persisted/hand-edited pipeline entry
-- can have a non-table outcome. Filters.lua's importString boundary
-- check is the primary defense -- this is the backstop for anything
-- already on disk from before that check, or a future direct
-- SavedVariables edit.
local function outcomeColor(outcome)
  if type(outcome) ~= "table" or outcome.kind == "nothing" then return NOTHING_COLOR end
  if outcome.kind == "hide" then return HIDE_COLOR end
  if outcome.kind == "category" then
    if outcome.name then return categoryColorOf(outcome.name) end
    return AUTO_COLOR
  end
  return NOTHING_COLOR
end

local function outcomeLabel(outcome)
  if type(outcome) ~= "table" or outcome.kind == "nothing" then return "Do Nothing" end
  if outcome.kind == "hide" then return "Hide" end
  if outcome.kind == "category" then
    return outcome.name or "Auto (varies)"
  end
  return "?"
end

-- ============================================================
-- live test -- runs the real classifier's pre-categoryOf pipeline
-- (Classifier.normalize/isRejected/resolveTarget/hasQuestLink/tierOf,
-- every one of them the exact function Classifier.classify itself calls,
-- in the exact same order) and then Classifier.categoryOfDebug -- the
-- same evaluator categoryOf itself is a thin wrapper around -- so this
-- box can show which pipeline entry decided the result, something
-- classify()'s own return value doesn't expose. No classification logic
-- is duplicated here, only orchestration of already-public Classifier
-- functions in classify()'s own call order.
-- ============================================================

function FiltersUI.runRulesTest(line)
  local Cls = ns.Classifier
  if not (Cls and Cls.normalize and Cls.isRejected and Cls.resolveTarget
      and Cls.tierOf and Cls.categoryOfDebug and Cls.hasQuestLink and ns.C) then
    return nil
  end
  if not line or line == "" then return nil end
  local ok, result = pcall(function()
    local tokens, normStr = Cls.normalize(line)
    local rejected, rReason = Cls.isRejected(line, tokens, ns.C)
    if rejected then return { rejected = true, reason = rReason } end
    local target = Cls.resolveTarget(tokens, normStr, ns.C, nil)
    if Cls.hasQuestLink(line) then target = nil end
    local tier = Cls.tierOf(tokens, ns.C)
    local category, index, entry = Cls.categoryOfDebug(target, tier, ns.C, tokens, normStr, line)
    return { rejected = false, category = category, index = index, entry = entry }
  end)
  if not ok then return nil end
  return result
end

-- ============================================================
-- shared window-frame helpers -- scroll+EditBox widget (share/import
-- body) and window chrome (title bar/close/status). Same idiom as
-- TipTac's ShowCopyWindow (movable/ESC-closable popup,
-- UIPanelScrollFrameTemplate+EditBox, SetText->HighlightText()->
-- SetFocus() select-all -- the era-standard "no OS clipboard on 3.3.5"
-- trick) and Cell_Ascension's ImportExport.lua select-on-focus idiom.
-- ============================================================

-- Forward-declared (assigned further down): themed chrome is needed here,
-- in createScrollEditBox, which is defined earlier in the file than that
-- section. A plain assignment below (not a second `local`) fills the SAME
-- upvalue slot every closure created above captures, the standard Lua
-- forward-declare pattern. wireMouseWheel/updateScrollbar are
-- forward-declared for the same reason.
local themeButton, themeScrollbar, wireMouseWheel, updateScrollbar

local function createScrollEditBox(name, parent, width, height)
  local scroll = CreateFrame("ScrollFrame", name .. "Scroll", parent, "UIPanelScrollFrameTemplate")
  scroll:SetWidth(width)
  scroll:SetHeight(height)

  local editBox = CreateFrame("EditBox", name .. "EditBox", scroll)
  editBox:SetMultiLine(true)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetAutoFocus(false)
  editBox:SetMaxLetters(99999)
  editBox:EnableMouse(true)
  editBox:SetWidth(width - 20)

  scroll:SetScrollChild(editBox)
  scroll:SetScript("OnSizeChanged", function(self, w)
    if w and w > 0 then editBox:SetWidth(w - 20) end
    if updateScrollbar then updateScrollbar(self) end
  end)
  if themeScrollbar then themeScrollbar(scroll) end
  -- The EditBox has EnableMouse(true) above, so wheel input never falls
  -- through to the ScrollFrame. Enable the wheel ON the EditBox but drive the
  -- PARENT ScrollFrame -- GetVerticalScrollRange/SetVerticalScroll are
  -- ScrollFrame methods, NOT EditBox methods (they would nil-error on an
  -- EditBox). This mirrors the real prior art: Chattynator/Core/Widgets.lua
  -- and AceGUI's MultiLineEditBox both enable wheel on the editbox and scroll
  -- the parent scrollframe.
  if editBox.EnableMouseWheel then
    editBox:EnableMouseWheel(true)
    editBox:SetScript("OnMouseWheel", function(_, delta)
      local range = scroll:GetVerticalScrollRange() or 0
      local new = (scroll:GetVerticalScroll() or 0) - delta * SCROLL_STEP
      if new < 0 then
        new = 0
      elseif new > range then
        new = range
      end
      scroll:SetVerticalScroll(new)
    end)
  end

  return scroll, editBox
end

local function buildWindowChrome(frameName, width, height, titleText)
  local win = CreateFrame("Frame", frameName, UIParent)
  win:SetWidth(width)
  win:SetHeight(height)
  win:SetPoint("CENTER")
  win:SetFrameStrata("DIALOG")
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(win, {
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
      bgColor = { 0, 0, 0, 0.9 },
      borderColor = { 0.6, 0.6, 0.6, 1 },
    })
  end
  win:Hide()
  if UISpecialFrames and tinsert then tinsert(UISpecialFrames, frameName) end

  win.TitleBar = CreateFrame("Frame", nil, win)
  win.TitleBar:SetPoint("TOPLEFT", 12, -10)
  win.TitleBar:SetPoint("TOPRIGHT", -32, -10)
  win.TitleBar:SetHeight(20)
  win.TitleBar:EnableMouse(true)
  win.TitleBar:SetScript("OnMouseDown", function() win:StartMoving() end)
  win.TitleBar:SetScript("OnMouseUp", function() win:StopMovingOrSizing() end)

  win.TitleText = win.TitleBar:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  win.TitleText:SetPoint("LEFT")
  win.TitleText:SetJustifyH("LEFT")
  win.TitleText:SetText(titleText or "YABB")

  win.CloseBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  win.CloseBtn:SetPoint("TOPRIGHT", -2, -2)
  win.CloseBtn:SetScript("OnClick", function() win:Hide() end)

  win.Scroll, win.EditBox = createScrollEditBox(frameName .. "Body", win, width - 40, height - 90)
  win.Scroll:SetPoint("TOPLEFT", win.TitleBar, "BOTTOMLEFT", 0, -8)
  win.EditBox:SetScript("OnEscapePressed", function() win:Hide() end)

  win.Status = win:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  win.Status:SetPoint("BOTTOMLEFT", 14, 12)
  win.Status:SetPoint("RIGHT", -14, 0)
  win.Status:SetJustifyH("LEFT")

  return win
end

-- Public, external-caller contract (Dump.lua `/yabb dump`, Diag.lua
-- `/yabb capture dump`): lazily built once, repopulated on every call.
function FiltersUI.showCopyWindow(titleText, bodyText)
  if not CreateFrame then return end
  local win = FiltersUI.copyWindow
  if not win then
    win = buildWindowChrome("YABBFiltersCopyWindow", 480, 340, titleText)
    FiltersUI.copyWindow = win
  end
  win.TitleText:SetText(tostring(titleText or "YABB"))
  win.Status:SetText("")
  win:Show()
  win.EditBox:SetText(tostring(bodyText or ""))
  win.Scroll:SetVerticalScroll(0)
  win.EditBox:HighlightText()
  win.EditBox:SetFocus()
end

-- Import half: same chrome, an empty paste-in box, and its own "Apply
-- import" button (Cell_Ascension ImportExport.lua's paste-then-apply
-- shape). The shared string is a bare {categories=,pipeline=} table,
-- wholesale-replacing whichever of the two fields the pasted config
-- actually carries (a config exported by an older build might carry
-- only one, or neither -- either is left untouched). Filters.importString
-- transparently routes a compact "!YABB:1!" encoded string through
-- LibDeflate/LibSerialize, or an older raw string through the sandboxed
-- Filters.import parser, and fail-softly rejects anything that isn't a
-- real YABB config either way (never a Lua error -- see Filters.lua's
-- own header note on importString).
local function importFailedText(detail)
  return "|cffff4040Import failed. That doesn't look like a YABB config string. "
    .. "Check you copied the whole thing.|r\n|cff808080" .. tostring(detail or "") .. "|r"
end

function FiltersUI.openImportWindow()
  if not CreateFrame then return end
  local win = FiltersUI.importWindow
  if not win then
    win = buildWindowChrome("YABBRulesImportWindow", 480, 360, "Import a shared rules config")
    win.Scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -30, 46)
    win.ApplyBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    win.ApplyBtn:SetWidth(110)
    win.ApplyBtn:SetHeight(20)
    win.ApplyBtn:SetPoint("BOTTOMRIGHT", win.Status, "TOPRIGHT", 0, 6)
    win.ApplyBtn:SetText("Apply import")
    themeButton(win.ApplyBtn)
    win.ApplyBtn:SetScript("OnClick", function()
      local ok, err = pcall(function()
        local text = win.EditBox:GetText() or ""
        local imported, importErr = ns.Filters.importString(text)
        if not imported then
          win.Status:SetText(importFailedText(importErr))
          return
        end
        local cfg = db()
        local changed = false
        if type(imported.categories) == "table" and #imported.categories > 0 then
          cfg.categories = imported.categories
          changed = true
        end
        if type(imported.pipeline) == "table" and #imported.pipeline > 0 then
          cfg.pipeline = imported.pipeline
          changed = true
        end
        if not changed then
          win.Status:SetText("|cffff4040Import failed: that string has no categories or rules in it.|r")
          return
        end
        FiltersUI.reapply()
        win.Status:SetText("|cff40ff40Imported OK|r")
      end)
      if not ok then win.Status:SetText(importFailedText(err)) end
    end)
    FiltersUI.importWindow = win
  end
  win.Status:SetText("")
  win:Show()
  win.EditBox:SetText("")
  win.EditBox:SetFocus()
end

-- ============================================================
-- mouse wheel: UIPanelScrollFrameTemplate wires the scrollbar buttons
-- but not wheel input. Mirrored in UI.lua's own wireMouseWheel -- edit
-- both together.
-- ============================================================

wireMouseWheel = function(scrollFrame)
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

-- ============================================================
-- themed chrome. Blanks a template's native textures and lays a real
-- SetBackdrop over them rather than replacing the frame from scratch,
-- so the template's automatic Enable/Disable font-object swap stays
-- free for the abc/.* and tab segments below. Mirrored in UI.lua's own
-- copy -- edit both together.
-- ============================================================

themeButton = function(btn)
  runGuarded(function()
    if not btn then return end
    if btn.SetNormalTexture then btn:SetNormalTexture("") end
    if btn.SetPushedTexture then btn:SetPushedTexture("") end
    if btn.SetDisabledTexture then btn:SetDisabledTexture("") end
    if btn.SetDisabledFontObject and GameFontNormal then btn:SetDisabledFontObject(GameFontNormal) end
    local hi = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hi then
      hi:SetTexture(0.91, 0.77, 0.42, 0.18)
      if hi.SetBlendMode then hi:SetBlendMode("ADD") end
    end
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(btn, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { 0.09, 0.10, 0.13, 0.9 },
        borderColor = { 0.91, 0.77, 0.42, 0.35 },
      })
    end
    local fs = btn.GetFontString and btn:GetFontString()
    if fs then fs:SetTextColor(0.87, 0.90, 0.96, 1) end
  end, "FiltersUI.themeButton")
end

-- Reorder up/down arrows. Blizzard's stock scrollbar-arrow art
-- (Interface\Buttons\UI-ScrollBar-Scroll{Up,Down}Button-*) is built for a
-- much larger scrollbar button: most of the texture is beveled chrome
-- around a small arrow glyph, so at this row's compact ~14px size the
-- chrome dominates and the arrow reads as a muddy smudge. The ChatFrame
-- scroll icons are plain, borderless arrow glyphs that stay crisp at
-- small sizes, so they're used for both directions here -- the client's
-- own FrameXML pairs the same two icon families the same way (e.g.
-- floatingchatframe.xml:629-659, channelframe.xml:1295-1314), so this is
-- matching stock usage rather than repurposing an unrelated icon.
local ARROW_ICON_UP = "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp"
local ARROW_ICON_DOWN = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown"

local function skinArrowButton(btn, pointsUp)
  if not btn then return end
  local base = pointsUp and ARROW_ICON_UP or ARROW_ICON_DOWN
  runGuarded(function()
    if btn.SetNormalTexture then btn:SetNormalTexture(base .. "-Up") end
    if btn.SetPushedTexture then btn:SetPushedTexture(base .. "-Down") end
    if btn.SetDisabledTexture then btn:SetDisabledTexture(base .. "-Disabled") end
    if btn.SetHighlightTexture then btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD") end
    local n = btn.GetNormalTexture and btn:GetNormalTexture()
    if n and n.SetAllPoints then n:SetAllPoints(btn) end
    local p = btn.GetPushedTexture and btn:GetPushedTexture()
    if p and p.SetAllPoints then p:SetAllPoints(btn) end
    local d = btn.GetDisabledTexture and btn:GetDisabledTexture()
    if d and d.SetAllPoints then d:SetAllPoints(btn) end
    local h = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if h and h.SetAllPoints then h:SetAllPoints(btn) end
  end, "FiltersUI.skinArrowButton")
end

-- themeEditBox(eb): the Categories name field and the Priority-tab rule
-- pattern field were originally built as
-- CreateFrame("EditBox", ..., "InputBoxTemplate"), the stock 3-slice
-- border template. Its Left/Middle/Right border textures are fixed-size
-- art anchored to the EditBox's OWN frame edges but sized for the
-- template's native ~20-22px tall usage -- squeezed into this panel's much
-- shorter 18px row fields, the border art no longer tracks the visible
-- text rect, rendering as a dislocated floating outline with no text
-- inset (typed text starts flush at the border pixel, unreadable under it).
-- UI.xml's FilterBox hit the identical InputBoxTemplate mismatch -- the fix here matches
-- that same working prior art (UI.xml's FilterBox + UI.lua's own
-- FilterBox:SetFontObject/SetTextColor styling) and this file's own
-- createScrollEditBox: a plain, template-less EditBox styled ONLY via
-- ns.Compat.applyBackdrop's native SetBackdrop directly ON the edit box's
-- own frame (so the border is drawn at exactly the box's own geometry, at
-- every size, with no separate mis-scaled template texture to drift out of
-- place) plus SetTextInsets so the caret/text never sits under the border.
local function themeEditBox(eb)
  if not eb then return end
  runGuarded(function()
    eb:SetFontObject(ChatFontNormal)
    eb:SetTextColor(0.87, 0.90, 0.96, 1)
    if eb.SetTextInsets then eb:SetTextInsets(6, 6, 0, 0) end
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(eb, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { 0.02, 0.02, 0.03, 0.9 },
        borderColor = { 1, 1, 1, 0.16 },
      })
    end
  end, "FiltersUI.themeEditBox")
end

-- Selected state for the segmented controls (tab bar, abc/.* mode
-- toggle). MUST be called AFTER Enable()/Disable(): the state change
-- swaps the ButtonText's font object, which would otherwise stomp the
-- colour set here.
local function setSegmentActive(btn, active)
  if not btn then return end
  local fs = btn.GetFontString and btn:GetFontString()
  if active then
    if btn.SetBackdropColor then btn:SetBackdropColor(0.91, 0.77, 0.42, 0.14) end
    if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.75) end
    if fs then fs:SetTextColor(0.91, 0.77, 0.42, 1) end
  else
    if btn.SetBackdropColor then btn:SetBackdropColor(0.09, 0.10, 0.13, 0.9) end
    if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(1, 1, 1, 0.14) end
    if fs then fs:SetTextColor(0.60, 0.64, 0.71, 1) end
  end
end

-- Reflects FiltersUI.resetArmed on a Reset-to-defaults button: a warm
-- red/orange "confirm" state when armed (distinct from setSegmentActive's
-- gold "selected" tint above, so the two visually distinct meanings --
-- "this tab is active" vs. "this click is destructive, click again" --
-- never look the same), the normal themed look otherwise. Called on every
-- render of either tab (both tabs share FiltersUI.resetArmed).
local function styleResetButton(btn)
  if not btn then return end
  local fs = btn.GetFontString and btn:GetFontString()
  if FiltersUI.resetArmed then
    btn:SetText("Click again to confirm")
    if fs then fs:SetTextColor(1, 0.45, 0.35, 1) end
    if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(1, 0.45, 0.35, 0.85) end
  else
    btn:SetText("Reset to defaults")
    if fs then fs:SetTextColor(0.87, 0.90, 0.96, 1) end
    if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.35) end
  end
end

-- Mirrored in UI.lua's own themeScrollbar -- edit both together.
themeScrollbar = function(scrollFrame)
  runGuarded(function()
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
    -- buttons we just hid the instant content overflows, so the one-shot
    -- Hide above is not durable. Routing range changes through our own
    -- updater keeps the arrows suppressed and drives auto-hide + proportional
    -- thumb sizing on every range change (e.g. an EditBox scroll pane, whose
    -- child height we do not own -- see updateScrollbar's no-contentHeight
    -- branch).
    scrollFrame:SetScript("OnScrollRangeChanged", function(self)
      if updateScrollbar then updateScrollbar(self) end
    end)
  end, "FiltersUI.themeScrollbar")
end

local FILTERSUI_MIN_THUMB_HEIGHT = 20 -- draggable floor; matches UI.lua's own constant

-- updateScrollbar(scrollFrame, contentHeight). Mirrored in UI.lua's own
-- copy -- edit both together. contentHeight = the TRUE (unclamped)
-- content height. Omit it to reuse the last one (resize path) or, for
-- engine-sized children (createScrollEditBox's EditBox), to take the
-- GetVerticalScrollRange() branch instead. Never reads
-- GetVerticalScrollRange() for a pane whose child height we set
-- ourselves -- that value is a frame stale (Cell Widgets.lua:2756-2758,
-- Chattynator Widgets.lua:479-484).
updateScrollbar = function(scrollFrame, contentHeight)
  if not scrollFrame then return end
  runGuarded(function()
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
      if h < FILTERSUI_MIN_THUMB_HEIGHT then h = FILTERSUI_MIN_THUMB_HEIGHT end
      if h > barH then h = barH end
      thumb:SetHeight(h)
      thumb:Show()
    end
    bar:Show()
  end, "FiltersUI.updateScrollbar")
end

-- ============================================================
-- color palette popout -- ONE shared floating frame (a tooltip-like
-- popup, not per-row) that opens anchored under whichever swatch button
-- was clicked and hands the picked color to that swatch's own callback.
-- A single shared instance (instead of one per row) keeps this cheap
-- regardless of category count, since only one can ever be open at a
-- time anyway.
-- ============================================================

local function buildPalettePopout()
  local pop = CreateFrame("Frame", "YABBRulesPalette", UIParent)
  local cols, sz, gap, pad = 8, 20, 4, 6
  local rows = math.ceil(#COLORS / cols)
  pop:SetWidth(pad * 2 + cols * sz + (cols - 1) * gap)
  pop:SetHeight(pad * 2 + rows * sz + (rows - 1) * gap)
  pop:SetFrameStrata("TOOLTIP")
  pop:SetToplevel(true)
  pop:SetClampedToScreen(true)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(pop, {
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
      bgColor = { 0.03, 0.03, 0.04, 0.97 },
      borderColor = { 0.91, 0.77, 0.42, 0.5 },
    })
  end
  pop:Hide()

  pop.Swatches = {}
  for i, color in ipairs(COLORS) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local btn = CreateFrame("Button", nil, pop)
    btn:SetWidth(sz)
    btn:SetHeight(sz)
    btn:SetPoint("TOPLEFT", pop, "TOPLEFT", pad + col * (sz + gap), -(pad + row * (sz + gap)))
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(btn, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { color[1], color[2], color[3], 1 },
        borderColor = { 1, 1, 1, 0.18 },
      })
    end
    btn:SetScript("OnClick", function()
      if pop.onPick then pop.onPick(color) end
      pop:Hide()
    end)
    pop.Swatches[i] = btn
  end
  return pop
end

-- openPalette(anchorFrame, onPick): (re)anchors the shared popout under
-- anchorFrame and shows it; clicking a swatch calls onPick({r,g,b}) (0-1
-- floats) then hides it. Clicking the SAME anchor again toggles it shut
-- (no separate close button needed for the common case); a genuine
-- click-anywhere-else-to-dismiss is a deliberate simplification left out
-- (same class of tradeoff this file's other fixed-swatch pickers already
-- accept) -- the popout still closes the instant any color is actually
-- picked, which is the path every real edit takes.
function FiltersUI.openPalette(anchorFrame, onPick)
  if not CreateFrame then return end
  local pop = FiltersUI.palette or buildPalettePopout()
  FiltersUI.palette = pop
  if pop:IsShown() and pop.anchor == anchorFrame then
    pop:Hide()
    return
  end
  pop.anchor = anchorFrame
  pop.onPick = onPick
  pop:ClearAllPoints()
  pop:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -3)
  pop:Show()
end

-- ============================================================
-- outcome dropdown -- categories (from ns.C.categories, in order), then a
-- menu-header divider, then the two set-apart actions: Do Nothing / Hide.
-- EasyMenu (UI.lua's own prior art: showRowMenu/buildRowMenu) rather than
-- a hand-rolled popout -- native menu chrome, keyboard/mouse dismissal
-- for free.
-- ============================================================

local outcomeMenuFrame

local function buildOutcomeMenu(onPick)
  local menu = {}
  menu[#menu + 1] = { text = "Route to a category", isTitle = true, notCheckable = true }
  local cats = (ns.C and ns.C.categories) or {}
  for i = 1, #cats do
    local c = cats[i]
    if type(c) == "table" and c.name then
      local name = c.name
      menu[#menu + 1] = {
        text = name, notCheckable = true,
        func = function() onPick({ kind = "category", name = name }) end,
      }
    end
  end
  -- Set-apart group: a menu header divider, then the two special actions,
  -- visibly separated from the category list above. Plain ASCII text
  -- only -- no icon glyph -- an unverified Unicode symbol or emoji risks
  -- rendering as tofu on this client's fonts (see UI.lua's
  -- NEUTRAL_INTENT_LABEL/HIDDEN_MARK_GLYPH for the same caution).
  -- outcomeLabel() (used for the row's own OutBtn text) stays consistent
  -- with these exact same plain strings.
  menu[#menu + 1] = { text = "Other actions", isTitle = true, notCheckable = true }
  menu[#menu + 1] = { text = "Do Nothing", notCheckable = true, func = function() onPick({ kind = "nothing" }) end }
  menu[#menu + 1] = { text = "Hide", notCheckable = true, func = function() onPick({ kind = "hide" }) end }
  return menu
end

local function showOutcomeMenu(anchorBtn, onPick)
  if not CreateFrame or not EasyMenu then return end
  if not outcomeMenuFrame then
    outcomeMenuFrame = CreateFrame("Frame", "YABBRulesOutcomeMenu", UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(buildOutcomeMenu(onPick), outcomeMenuFrame, anchorBtn, 0, 0, "MENU")
end

-- ============================================================
-- CATEGORIES tab -- pooled rows over db().categories.
-- ============================================================

local catRowPool = {}

local function acquireCatRow(i, parent)
  local row = catRowPool[i]
  if not row then
    row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(row, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { 0.047, 0.055, 0.071, 0.85 },
        borderColor = { 1, 1, 1, 0.10 },
      })
    end

    row.UpBtn = CreateFrame("Button", nil, row)
    row.UpBtn:SetWidth(14); row.UpBtn:SetHeight(14)
    row.UpBtn:SetPoint("LEFT", row, "LEFT", 4, 7)
    skinArrowButton(row.UpBtn, true)

    row.DownBtn = CreateFrame("Button", nil, row)
    row.DownBtn:SetWidth(14); row.DownBtn:SetHeight(14)
    row.DownBtn:SetPoint("LEFT", row, "LEFT", 4, -7)
    skinArrowButton(row.DownBtn, false)

    -- SwBtn/NameField anchor straight to `row`'s own LEFT (row vertical
    -- center), NOT chained off UpBtn/DownBtn -- those two sit +-7px off
    -- center (stacked to make room for each other), so anchoring through
    -- either one would drag every widget after it off-center too.
    row.SwBtn = CreateFrame("Button", nil, row)
    row.SwBtn:SetWidth(18); row.SwBtn:SetHeight(18)
    row.SwBtn:SetPoint("LEFT", row, "LEFT", 30, 0)
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(row.SwBtn, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { 0.5, 0.53, 0.6, 1 },
        borderColor = { 1, 1, 1, 0.2 },
      })
    end

    -- Plain EditBox (no InputBoxTemplate -- see themeEditBox's header note):
    -- anchored LEFT+RIGHT off `row` itself, like UI.xml's own FilterBox
    -- (TOPLEFT+BOTTOMRIGHT off FilterBg), so its width comes from the row's
    -- own slot instead of a fixed too-small SetWidth -- the -190 right
    -- margin clears both UsesText's (right-justified, unbounded-growth)
    -- widest realistic text and RemoveBtn.
    row.NameField = CreateFrame("EditBox", nil, row)
    row.NameField:SetHeight(20)
    row.NameField:SetAutoFocus(false)
    row.NameField:SetPoint("LEFT", row, "LEFT", 60, 0)
    row.NameField:SetPoint("RIGHT", row, "RIGHT", -190, 0)
    themeEditBox(row.NameField)
    row.NameField:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    row.NameField:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    row.UsesText = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.UsesText:SetPoint("RIGHT", row, "RIGHT", -32, 0)
    row.UsesText:SetJustifyH("RIGHT")

    row.RemoveBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.RemoveBtn:SetWidth(20); row.RemoveBtn:SetHeight(20)
    row.RemoveBtn:SetText("x")
    row.RemoveBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    themeButton(row.RemoveBtn)

    catRowPool[i] = row
  end
  return row
end

local function usesCountText(pipeline, name)
  local n = 0
  for _, e in ipairs(pipeline) do
    if type(e) == "table" and e.outcome and e.outcome.kind == "category" and e.outcome.name == name then
      n = n + 1
    end
  end
  return n .. (n == 1 and " matcher" or " matchers") .. " -> here"
end

function FiltersUI.renderCategoriesTab()
  local panel = FiltersUI.panel
  if not panel then return end
  local cfg = db()
  local cats, pipeline = cfg.categories, cfg.pipeline
  local root = panel.CatsBody
  local y = 0

  for i, cat in ipairs(cats) do
    -- Defense in depth: a persisted or hand-edited config can hold a
    -- non-table category element (Filters.lua's importString boundary
    -- check -- validCategoriesShape -- is the primary defense; this is
    -- the backstop for anything already on disk from before that check
    -- existed). Never index into it -- just skip rendering a row for
    -- this slot, matching categoryColorOf's own type(c)=="table" guard.
    if type(cat) ~= "table" then
      local stale = catRowPool[i]
      if stale then stale:Hide() end
    else
      local row = acquireCatRow(i, root)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
      row:SetPoint("RIGHT", root, "RIGHT", 0, 0)
      row:Show()

      if i == 1 then row.UpBtn:Disable() else row.UpBtn:Enable() end
      if i == #cats then row.DownBtn:Disable() else row.DownBtn:Enable() end

      local col = (type(cat.color) == "table") and cat.color or { r = 0.5, g = 0.53, b = 0.6 }
      row.SwBtn:SetBackdropColor(col.r or 0.5, col.g or 0.53, col.b or 0.6, 1)

      if not row.NameField:HasFocus() then
        row.NameField:SetText(cat.name or "")
      end
      row.UsesText:SetText(usesCountText(pipeline, cat.name))

      row.UpBtn:SetScript("OnClick", function()
        if i > 1 then cats[i - 1], cats[i] = cats[i], cats[i - 1]; FiltersUI.reapply() end
      end)
      row.DownBtn:SetScript("OnClick", function()
        if i < #cats then cats[i + 1], cats[i] = cats[i], cats[i + 1]; FiltersUI.reapply() end
      end)
      row.RemoveBtn:SetScript("OnClick", function()
        table.remove(cats, i)
        FiltersUI.reapply()
      end)
      row.SwBtn:SetScript("OnClick", function()
        FiltersUI.openPalette(row.SwBtn, function(picked)
          cat.color = { r = picked[1], g = picked[2], b = picked[3], a = 1 }
          FiltersUI.reapply()
        end)
      end)
      -- Live rename: retarget every pipeline outcome that pointed at the
      -- pre-keystroke name to the new one, on every keystroke -- not just
      -- on commit -- so a mid-typing name never silently orphans its own
      -- matchers even if Enter is never pressed. No full re-render from
      -- here (would reset this very EditBox's cursor mid-type); only this
      -- row's own Uses readout (a different widget) is refreshed.
      --
      -- DO NOT REMOVE THIS GUARD. On 3.3.5, EditBox:SetText fires
      -- OnTextChanged SYNCHRONOUSLY. In a pooled row, SetText runs before
      -- this SetScript rebinds, so the handler that fires is the
      -- PREVIOUS render's closure, still capturing the previous render's
      -- category -- it would rename the wrong entry. The handler's
      -- second argument is true only for a real keystroke and false for
      -- a programmatic SetText, so bailing out when it is not true both
      -- neutralizes the stale closure and stops an applyOverlay+Refresh
      -- storm of one per row per render.
      row.NameField:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local newName = self:GetText() or ""
        if newName == "" or newName == cat.name then return end
        local oldName = cat.name
        for _, e in ipairs(pipeline) do
          if type(e) == "table" and e.outcome and e.outcome.kind == "category" and e.outcome.name == oldName then
            e.outcome.name = newName
          end
        end
        cat.name = newName
        row.UsesText:SetText(usesCountText(pipeline, newName))
        if ns.Filters and ns.Filters.applyOverlay and ns.C then ns.Filters.applyOverlay(ns.C, cfg) end
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
        FiltersUI.scheduleBoardReeval()
      end)

      y = y - (ROW_H + ROW_GAP)
    end
  end
  for i = #cats + 1, #catRowPool do catRowPool[i]:Hide() end

  -- add-category row
  local add = panel.CatsBody.AddRow
  add:ClearAllPoints()
  add:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  add.SwBtn:SetBackdropColor(FiltersUI.pendingCatColor[1], FiltersUI.pendingCatColor[2], FiltersUI.pendingCatColor[3], 1)
  y = y - 30

  panel.CatsBody.ResetBtn:ClearAllPoints()
  panel.CatsBody.ResetBtn:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  styleResetButton(panel.CatsBody.ResetBtn)
  y = y - 26

  if updateScrollbar then updateScrollbar(panel.BodyScroll, -y) end
end

-- ============================================================
-- PRIORITY & RULES tab: a collapsible, edit-in-place matcher editor
-- over db().pipeline (kept identity-same as ns.C.pipeline once
-- materialized -- see ensureMaterialized above). Every matcher is
-- name + patterns -> outcome. Each row is pooled (ruleRowPool[i]) and
-- split into a fixed-height Header (collapsed summary, always visible)
-- and a variable-height Body (the pattern editor, shown only while
-- FiltersUI.rulesOpen[i] is true).
-- ============================================================

local ruleRowPool = {}

-- Header-row name/summary caps: row.Name has no natural width limit -- a
-- FontString auto-sizes to its text unless bounded -- so an
-- unbounded-length matcher name (a fully-supported rename) would grow
-- the header rightward over the MATCH marker/outcome dropdown/remove x,
-- squeezing row.Summary (anchored between Name.RIGHT and MatchLabel.LEFT)
-- to zero/negative width. Both the WIDTH and the TEXT are capped: the
-- width (SetWidth + SetWordWrap(false)) keeps Summary's LEFT anchor
-- point fixed regardless of name length, and the text cap (FiltersUI.
-- clipText) guarantees visible containment even though 3.3.5 FontStrings
-- don't reliably clip overflow on their own.
-- SUMMARY_MAX_CHARS: with row.Name fixed-width, row.Summary's own box
-- (LEFT anchored off Name.RIGHT, RIGHT anchored off MatchLabel.LEFT) is
-- also a fixed, deterministic width -- worked out from the same header's
-- other fixed offsets (Caret/Dot/gaps, MatchLabel/OutBtn/RemoveBtn) to
-- roughly 205px, vs. Name's 180px box; same px-per-char ratio as
-- NAME_MAX_CHARS (180/28) applied to 205px gives ~32.
local NAME_CAP_W, NAME_MAX_CHARS = 180, 28
local SUMMARY_MAX_CHARS = 32

-- Layout constants for an expanded matcher's Body -- pure numbers, no
-- widget geometry ever read back (GetHeight/GetStringWidth) to compute
-- them: every height below is COUNTED (pattern rows, whether a catalog
-- note is present), never MEASURED, so layout stays correct even under a
-- harness that can't actually lay out real text (tests/filters_encoded_
-- spec.lua's mock frames). CATNOTE_H is only the FALLBACK allotment for
-- the catalog note -- layoutMatcherBody prefers the real
-- GetStringHeight() measurement (guarded, real client only) since the
-- note word-wraps and a long one (e.g. the ~150-char Dungeon note) can
-- run 2-3 lines; CATNOTE_H is a 3-line-safe fallback for when measuring
-- isn't available or trustworthy (the mock harness above).
local LEFT_PAD = 34
local BODY_TOP_PAD, BODY_BOTTOM_PAD = 8, 8
local NAME_ROW_H, PLABEL_H = 26, 16
local PAT_ROW_H, PAT_GAP = 22, 4
local ADDPAT_ROW_H = 26
local CATNOTE_H = 54

-- chipTextFor/chipColorFor: the read-only line a NOT-inline-editable
-- pattern (catalog/special, or any kind this UI doesn't recognize) shows
-- in an expanded matcher's pattern list, in place of an editable Input.
-- An unrecognized kind falls through to a plain UNRECOGNIZED line
-- instead of erroring, so a matcher with a pattern this build doesn't
-- know about still renders.
local function chipTextFor(p)
  if type(p) ~= "table" then return "(invalid pattern)" end
  if p.kind == "catalog" then
    local label = CATALOG_NAME[p.value] or tostring(p.value or "?")
    return "CATALOG -- " .. label .. ": matches datamined names automatically"
  elseif p.kind == "special" then
    local desc = SPECIAL_DESC[p.id] or ("id=" .. tostring(p.id or "?"))
    return "STRUCTURAL -- " .. desc
  else
    return "UNRECOGNIZED pattern kind (" .. tostring(p.kind or "nil") .. ")"
  end
end

local function chipColorFor(p)
  if type(p) == "table" and p.kind == "catalog" then return { 0.53, 0.85, 0.72 } end
  if type(p) == "table" and p.kind == "special" then return NEUTRAL_COLOR end
  return HIDE_COLOR
end

-- The bottom "extend this catalog with your own patterns" note. nil
-- when the matcher has no catalog pattern at all.
local function catalogNoteText(patterns)
  for pi = 1, #patterns do
    local p = patterns[pi]
    if type(p) == "table" and p.kind == "catalog" then
      local label = CATALOG_NAME[p.value] or tostring(p.value or "?")
      return "The " .. label .. " catalog matches datamined names automatically -- not inline-editable, but add your own keyword/regex patterns above that match on top of it."
    end
  end
  return nil
end

-- Tooltip for the unlabeled abc/.* pattern-mode toggle -- otherwise
-- unexplained anywhere in the panel. Reads the button's own current
-- text rather than tracking separate state, so one attach covers every
-- future SetText("abc"/".*") this button gets.
local function attachModeTooltip(btn)
  if not btn then return end
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self:GetText() == ".*" and "Lua pattern" or "Plain text")
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- acquirePatRow: one row in an expanded matcher's pattern list. Carries
-- BOTH widget sets (editable Input+ModeBtn+RemoveBtn for keyword/regex,
-- read-only Chip for catalog/special/unrecognized) permanently -- render
-- just shows/hides whichever set the current pattern's kind needs, same
-- "pool carries every widget it might ever need" idiom as acquireRuleRow.
local function acquirePatRow(parentBody, pool, j)
  local pr = pool[j]
  if not pr then
    pr = CreateFrame("Frame", nil, parentBody)
    pr:SetHeight(PAT_ROW_H)

    pr.RemoveBtn = CreateFrame("Button", nil, pr, "UIPanelButtonTemplate")
    pr.RemoveBtn:SetWidth(20); pr.RemoveBtn:SetHeight(20)
    pr.RemoveBtn:SetText("x")
    pr.RemoveBtn:SetPoint("RIGHT", pr, "RIGHT", 0, 0)
    themeButton(pr.RemoveBtn)

    pr.ModeBtn = CreateFrame("Button", nil, pr, "UIPanelButtonTemplate")
    pr.ModeBtn:SetWidth(36); pr.ModeBtn:SetHeight(18)
    pr.ModeBtn:SetPoint("RIGHT", pr.RemoveBtn, "LEFT", -4, 0)
    themeButton(pr.ModeBtn)
    attachModeTooltip(pr.ModeBtn)

    -- Plain EditBox (no InputBoxTemplate -- see themeEditBox's own header
    -- note on why every EditBox in this file is template-less).
    pr.Input = CreateFrame("EditBox", nil, pr)
    pr.Input:SetHeight(20)
    pr.Input:SetAutoFocus(false)
    pr.Input:SetPoint("LEFT", pr, "LEFT", 0, 0)
    pr.Input:SetPoint("RIGHT", pr.ModeBtn, "LEFT", -6, 0)
    themeEditBox(pr.Input)
    pr.Input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    pr.Input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    pr.Chip = pr:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    pr.Chip:SetPoint("LEFT", pr, "LEFT", 0, 0)
    pr.Chip:SetPoint("RIGHT", pr, "RIGHT", 0, 0)
    pr.Chip:SetJustifyH("LEFT")

    pool[j] = pr
  end
  return pr
end

-- layoutMatcherBody: positions+wires every widget in an OPEN matcher's
-- Body (name field, pattern list, add-pattern row, catalog note) and
-- returns the body's real total height (counted, per the header note
-- above) so the caller can size row.Body/row and stack the NEXT matcher
-- row below it. `cfg` is db() (same table `entry`/`patterns` already live
-- in) -- threaded through so every edit here can persist via the exact
-- same applyOverlay+UI.Refresh calls every other edit in this file uses.
local function layoutMatcherBody(row, entry, cfg, i)
  local body = row.Body
  local patterns = (type(entry.patterns) == "table") and entry.patterns or {}
  local y = -BODY_TOP_PAD

  body.NameLabel:ClearAllPoints()
  body.NameLabel:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT_PAD, y)

  body.NameField:ClearAllPoints()
  body.NameField:SetPoint("TOPLEFT", body.NameLabel, "TOPRIGHT", 8, 4)
  body.NameField:SetPoint("RIGHT", body, "RIGHT", -10, 0)
  if not body.NameField:HasFocus() then
    body.NameField:SetText((type(entry.name) == "string") and entry.name or "")
  end
  -- DO NOT REMOVE THIS GUARD. On 3.3.5, EditBox:SetText fires
  -- OnTextChanged SYNCHRONOUSLY. In a pooled row, SetText runs before
  -- this SetScript rebinds, so the handler that fires is the PREVIOUS
  -- render's closure, still capturing the previous render's matcher --
  -- it would edit the wrong entry. The handler's second argument is
  -- true only for a real keystroke and false for a programmatic
  -- SetText, so bailing out when it is not true both neutralizes the
  -- stale closure and stops an applyOverlay+Refresh storm of one per
  -- row per render.
  body.NameField:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    local newName = self:GetText() or ""
    entry.name = newName
    if row.Name then row.Name:SetText(FiltersUI.clipText(newName ~= "" and newName or "Unnamed matcher", NAME_MAX_CHARS)) end
    if ns.Filters and ns.Filters.applyOverlay and ns.C then ns.Filters.applyOverlay(ns.C, cfg) end
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
    FiltersUI.scheduleBoardReeval()
  end)
  y = y - NAME_ROW_H

  body.PatLabel:ClearAllPoints()
  body.PatLabel:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT_PAD, y)
  y = y - PLABEL_H

  local pool = row.PatRowPool
  local n = #patterns
  for j = 1, n do
    local pr = acquirePatRow(body, pool, j)
    pr:ClearAllPoints()
    pr:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT_PAD, y)
    pr:SetPoint("RIGHT", body, "RIGHT", -10, 0)
    pr:Show()

    local p = patterns[j]
    if type(p) == "table" and (p.kind == "keyword" or p.kind == "regex") then
      pr.Chip:Hide()
      pr.Input:Show(); pr.ModeBtn:Show(); pr.RemoveBtn:Show()
      local isRegex = (p.kind == "regex")
      if not pr.Input:HasFocus() then pr.Input:SetText(p.value or "") end
      pr.ModeBtn:SetText(isRegex and ".*" or "abc")
      -- Same stale-closure guard as body.NameField above -- do not remove.
      pr.Input:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        p.value = self:GetText() or ""
        if ns.Filters and ns.Filters.applyOverlay and ns.C then ns.Filters.applyOverlay(ns.C, cfg) end
        if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
        FiltersUI.scheduleBoardReeval()
        if row.Summary then row.Summary:SetText(FiltersUI.clipText(FiltersUI.patternSummary(entry), SUMMARY_MAX_CHARS)) end
        FiltersUI.refreshRulesLive()
      end)
      pr.ModeBtn:SetScript("OnClick", function()
        p.kind = isRegex and "keyword" or "regex"
        FiltersUI.reapply()
      end)
      pr.RemoveBtn:SetScript("OnClick", function()
        table.remove(patterns, j)
        FiltersUI.reapply()
      end)
    else
      -- catalog/special/unrecognized: read-only, not inline-editable --
      -- add a keyword/regex pattern above that matches on top of it.
      pr.Input:Hide(); pr.ModeBtn:Hide(); pr.RemoveBtn:Hide()
      pr.Chip:Show()
      pr.Chip:SetText(chipTextFor(p))
      local col = chipColorFor(p)
      pr.Chip:SetTextColor(col[1], col[2], col[3], 1)
    end
    y = y - (PAT_ROW_H + PAT_GAP)
  end
  for j = n + 1, #pool do pool[j]:Hide() end

  body.AddBtn:ClearAllPoints()
  body.AddBtn:SetPoint("TOPRIGHT", body, "TOPRIGHT", -10, y)
  body.AddModeBtn:ClearAllPoints()
  body.AddModeBtn:SetPoint("TOPRIGHT", body.AddBtn, "TOPLEFT", -6, 1)
  body.AddInput:ClearAllPoints()
  body.AddInput:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT_PAD, y)
  body.AddInput:SetPoint("RIGHT", body.AddModeBtn, "LEFT", -6, 0)
  -- This input's text is only ever read (via GetText()) on the Add
  -- click below, never persisted per-keystroke, so the guard is a
  -- defensive no-op here rather than load-bearing -- kept for
  -- uniformity with every other EditBox in this file.
  body.AddInput:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
  end)
  -- addPattern: the one add-pattern action, shared by the "+ Add pattern"
  -- button and the add-pattern input's Enter key. Resets body.AddModeBtn
  -- back to keyword/"abc" after every add -- otherwise a mode toggle
  -- left on regex/".*" would silently carry over and default the next
  -- typed pattern to regex too, the same class of bug as a stale
  -- checkbox.
  local function addPattern()
    local text = trim(body.AddInput:GetText() or "")
    if text == "" then return end
    local isRegex = body.AddModeBtn.isRegex and true or false
    local pats = (type(entry.patterns) == "table") and entry.patterns or {}
    entry.patterns = pats
    pats[#pats + 1] = { kind = isRegex and "regex" or "keyword", value = text }
    body.AddInput:SetText("")
    body.AddInput:ClearFocus()
    body.AddModeBtn.isRegex = false
    body.AddModeBtn:SetText("abc")
    FiltersUI.rulesOpen[i] = true
    FiltersUI.reapply()
  end
  body.AddBtn:SetScript("OnClick", addPattern)
  body.AddInput:SetScript("OnEnterPressed", addPattern)
  body.AddModeBtn:SetScript("OnClick", function()
    body.AddModeBtn.isRegex = not body.AddModeBtn.isRegex
    body.AddModeBtn:SetText(body.AddModeBtn.isRegex and ".*" or "abc")
  end)
  y = y - ADDPAT_ROW_H

  local noteText = catalogNoteText(patterns)
  if noteText then
    body.CatalogNote:Show()
    body.CatalogNote:ClearAllPoints()
    body.CatalogNote:SetPoint("TOPLEFT", body, "TOPLEFT", LEFT_PAD, y)
    body.CatalogNote:SetWidth(CONTENT_W - LEFT_PAD - 20)
    body.CatalogNote:SetText(noteText)
    -- The note word-wraps (SetWordWrap(true) at creation) and a long
    -- catalog note (e.g. the ~150-char Dungeon note) can wrap to 2-3
    -- lines at this width, so a fixed height allotment would undercount
    -- the real height and the next matcher's header would overlap the
    -- note's bottom. Prefer the real measured height (GetStringHeight,
    -- only meaningful against a real laid-out FontString); guarded with
    -- a type(...)=="number" check so this stays safe under
    -- tests/filters_encoded_spec.lua's mock-widget harness, where
    -- GetStringHeight() returns a truthy mock table, not a number, and
    -- CATNOTE_H (3-line-safe slack) is the fallback.
    local measured = body.CatalogNote.GetStringHeight and body.CatalogNote:GetStringHeight()
    local noteH = (type(measured) == "number" and measured > 0) and measured or CATNOTE_H
    y = y - noteH
  else
    body.CatalogNote:Hide()
  end

  return -y + BODY_BOTTOM_PAD
end

local function acquireRuleRow(i, parent)
  local row = ruleRowPool[i]
  if not row then
    row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    if ns.Compat and ns.Compat.applyBackdrop then
      ns.Compat.applyBackdrop(row, {
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
        bgColor = { 0.047, 0.055, 0.071, 0.85 },
        borderColor = { 1, 1, 1, 0.10 },
      })
    end

    -- ---- collapsed header (always visible; fixed height) ----
    row.Header = CreateFrame("Frame", nil, row)
    row.Header:SetHeight(ROW_H)
    row.Header:EnableMouse(true)

    row.Rank = row.Header:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Rank:SetWidth(16)
    row.Rank:SetJustifyH("RIGHT")
    row.Rank:SetPoint("LEFT", row.Header, "LEFT", 3, 0)

    row.UpBtn = CreateFrame("Button", nil, row.Header)
    row.UpBtn:SetWidth(14); row.UpBtn:SetHeight(14)
    row.UpBtn:SetPoint("LEFT", row.Rank, "RIGHT", 4, 7)
    skinArrowButton(row.UpBtn, true)

    row.DownBtn = CreateFrame("Button", nil, row.Header)
    row.DownBtn:SetWidth(14); row.DownBtn:SetHeight(14)
    row.DownBtn:SetPoint("LEFT", row.Rank, "RIGHT", 4, -7)
    skinArrowButton(row.DownBtn, false)

    -- Caret/Dot/Name/OutBtn/RemoveBtn/MatchLabel/Summary all anchor
    -- straight to row.Header's own LEFT/RIGHT (header vertical center),
    -- NOT chained off UpBtn/DownBtn -- see the identical note in
    -- acquireCatRow above.
    row.Caret = row.Header:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Caret:SetWidth(12)
    row.Caret:SetJustifyH("CENTER")
    row.Caret:SetPoint("LEFT", row.Header, "LEFT", 45, 0)

    row.Dot = row.Header:CreateTexture(nil, "ARTWORK")
    row.Dot:SetWidth(8); row.Dot:SetHeight(8)
    row.Dot:SetPoint("LEFT", row.Caret, "RIGHT", 4, 0)

    row.Name = row.Header:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.Name:SetPoint("LEFT", row.Dot, "RIGHT", 6, 0)
    row.Name:SetWidth(NAME_CAP_W)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)

    row.OutBtn = CreateFrame("Button", nil, row.Header, "UIPanelButtonTemplate")
    row.OutBtn:SetWidth(130); row.OutBtn:SetHeight(20)
    row.OutBtn:SetPoint("RIGHT", row.Header, "RIGHT", -26, 0)
    themeButton(row.OutBtn)

    row.RemoveBtn = CreateFrame("Button", nil, row.Header, "UIPanelButtonTemplate")
    row.RemoveBtn:SetWidth(20); row.RemoveBtn:SetHeight(20)
    row.RemoveBtn:SetText("x")
    row.RemoveBtn:SetPoint("RIGHT", row.Header, "RIGHT", -2, 0)
    themeButton(row.RemoveBtn)

    row.MatchLabel = row.Header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    row.MatchLabel:SetText("MATCHED")
    row.MatchLabel:SetTextColor(0.91, 0.77, 0.42, 1)
    row.MatchLabel:SetPoint("RIGHT", row.OutBtn, "LEFT", -8, 0)
    row.MatchLabel:Hide()

    row.Summary = row.Header:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Summary:SetPoint("LEFT", row.Name, "RIGHT", 8, 0)
    row.Summary:SetPoint("RIGHT", row.MatchLabel, "LEFT", -8, 0)
    row.Summary:SetJustifyH("LEFT")
    row.Summary:SetWordWrap(false)

    -- ---- expanded body (edit-in-place pattern editor; shown only while
    -- FiltersUI.rulesOpen[i] is true, height set every render) ----
    row.Body = CreateFrame("Frame", nil, row)
    row.Body:SetHeight(1)
    row.Body:Hide()

    row.Body.NameLabel = row.Body:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Body.NameLabel:SetText("NAME")

    row.Body.NameField = CreateFrame("EditBox", nil, row.Body)
    row.Body.NameField:SetHeight(20)
    row.Body.NameField:SetAutoFocus(false)
    themeEditBox(row.Body.NameField)
    row.Body.NameField:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    row.Body.NameField:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    row.Body.PatLabel = row.Body:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Body.PatLabel:SetText("Matches if the line contains any of these:")

    row.PatRowPool = {}

    row.Body.AddBtn = CreateFrame("Button", nil, row.Body, "UIPanelButtonTemplate")
    row.Body.AddBtn:SetWidth(96); row.Body.AddBtn:SetHeight(20)
    row.Body.AddBtn:SetText("+ Add pattern")
    themeButton(row.Body.AddBtn)

    row.Body.AddModeBtn = CreateFrame("Button", nil, row.Body, "UIPanelButtonTemplate")
    row.Body.AddModeBtn:SetWidth(36); row.Body.AddModeBtn:SetHeight(18)
    row.Body.AddModeBtn:SetText("abc")
    row.Body.AddModeBtn.isRegex = false
    themeButton(row.Body.AddModeBtn)
    attachModeTooltip(row.Body.AddModeBtn)

    row.Body.AddInput = CreateFrame("EditBox", nil, row.Body)
    row.Body.AddInput:SetHeight(20)
    row.Body.AddInput:SetAutoFocus(false)
    themeEditBox(row.Body.AddInput)
    row.Body.AddInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    row.Body.CatalogNote = row.Body:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    row.Body.CatalogNote:SetJustifyH("LEFT")
    row.Body.CatalogNote:SetWordWrap(true)

    ruleRowPool[i] = row
  end
  return row
end

-- Plain-English sentences for the classifier's raw internal reject/route
-- codes -- this box is the most-visited diagnostic surface in the addon
-- and a raw enum ("nearmiss", "notLFG") means nothing to a player. The
-- raw code itself stays reachable through /yabb parse for tuning; this
-- map only governs what THIS box prints. Unmapped codes fall back to
-- their raw text rather than going blank.
local REASON_TEXT = {
  spam = "Rejected: looks like spam or a gold seller.",
  service = "Rejected: looks like a crafting or service post.",
  guild = "Rejected: looks like guild recruitment.",
  question = "Rejected: reads like a question, not a group post.",
  gibberish = "Rejected: not readable text.",
  tooShort = "Rejected: too short.",
  nearmiss = "Close, but not enough group signal to list.",
  notLFG = "Ignored: not a group message.",
  userhide = "Hidden by your own rule.",
  unmatched = "No rule claimed this line.",
}

local function reasonText(code)
  return REASON_TEXT[code] or tostring(code)
end

-- updateTestResultDisplay: called on every Live Test / pattern-field
-- keystroke. Recomputes the win index and updates ONLY each row's border
-- highlight + MATCH marker + the test result line -- never repositions/
-- rebuilds a row or calls SetText on any EditBox, so it never fights the
-- field the player is actively typing into.
local function updateTestResultDisplay()
  local panel = FiltersUI.panel
  if not panel or not panel.RulesPinned or not panel.RulesPinned.TestSection
      or not panel.RulesPinned.TestSection.TestResult then return end
  local out = panel.RulesPinned.TestSection.TestResult
  local line = FiltersUI.testLine or ""
  if line == "" then
    out:SetText("")
    return
  end
  local dbg = FiltersUI.runRulesTest(line)
  local Cls = ns.Classifier
  if not dbg then
    out:SetText("Couldn't test that line.")
    out:SetTextColor(0.60, 0.64, 0.71, 1)
  elseif dbg.rejected then
    -- Distinct from the pipeline-outcome "no rule claimed this line"
    -- below: this line never reached ns.C.pipeline at all --
    -- Classifier.isRejected caught it first (matches classify()'s own
    -- real order, see runRulesTest's header comment), so no matcher had
    -- a chance to act on it.
    out:SetText(reasonText(dbg.reason or "notLFG"))
    out:SetTextColor(0.60, 0.64, 0.71, 1)
  elseif Cls and dbg.category == Cls.HIDE then
    local mname = (type(dbg.entry) == "table" and type(dbg.entry.name) == "string" and dbg.entry.name ~= "") and dbg.entry.name or "?"
    out:SetText("Hidden by \"" .. mname .. "\" (rule " .. tostring(dbg.index) .. ")")
    out:SetTextColor(HIDE_COLOR[1], HIDE_COLOR[2], HIDE_COLOR[3], 1)
  elseif dbg.category then
    local mname = (type(dbg.entry) == "table" and type(dbg.entry.name) == "string" and dbg.entry.name ~= "") and dbg.entry.name or "?"
    local c = categoryColorOf(dbg.category)
    out:SetText(tostring(dbg.category) .. " via \"" .. mname .. "\" (rule " .. tostring(dbg.index) .. ")")
    out:SetTextColor(c[1], c[2], c[3], 1)
  else
    out:SetText(reasonText("unmatched"))
    out:SetTextColor(0.60, 0.64, 0.71, 1)
  end
end

function FiltersUI.refreshRulesLive()
  local panel = FiltersUI.panel
  if not panel or FiltersUI.activeTab ~= "rules" then return end
  local dbg = FiltersUI.runRulesTest(FiltersUI.testLine)
  local winIndex = (dbg and not dbg.rejected) and dbg.index or nil
  local pipeline = db().pipeline
  for i = 1, #pipeline do
    local row = ruleRowPool[i]
    if row and row:IsShown() then
      local isWin = (i == winIndex)
      if isWin then
        row:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.9)
      else
        row:SetBackdropBorderColor(1, 1, 1, 0.10)
      end
      if row.MatchLabel then
        if isWin then row.MatchLabel:Show() else row.MatchLabel:Hide() end
      end
    end
  end
  updateTestResultDisplay()
end

function FiltersUI.renderRulesTab()
  local panel = FiltersUI.panel
  if not panel then return end
  local cfg = db()
  local pipeline = cfg.pipeline
  local root = panel.RulesBody
  local dbg = FiltersUI.runRulesTest(FiltersUI.testLine)
  local winIndex = (dbg and not dbg.rejected) and dbg.index or nil
  local y = 0

  for i, entry in ipairs(pipeline) do
    -- Defense in depth: a persisted or hand-edited config can hold a
    -- non-table pipeline element (Filters.lua's importString boundary
    -- check -- validPipelineShape -- is the primary defense; this is
    -- the backstop for anything already on disk from before that check
    -- existed, or a legacy-shaped entry reached directly without going
    -- through ensureMaterialized/openEditor first -- see
    -- tests/filters_encoded_spec.lua). Never index into it -- just skip
    -- rendering a row for this slot.
    if type(entry) ~= "table" then
      local stale = ruleRowPool[i]
      if stale then stale:Hide() end
    else
      local row = acquireRuleRow(i, root)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
      row:SetPoint("RIGHT", root, "RIGHT", 0, 0)
      row:Show()

      row.Header:ClearAllPoints()
      row.Header:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
      row.Header:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
      row.Body:ClearAllPoints()
      row.Body:SetPoint("TOPLEFT", row.Header, "BOTTOMLEFT", 0, 0)
      row.Body:SetPoint("TOPRIGHT", row.Header, "BOTTOMRIGHT", 0, 0)

      -- Same defense-in-depth class as the non-table-entry guard above:
      -- a legacy-shaped entry (.name/.patterns absent) or a hand-edited
      -- malformed one must render, not crash -- even a matcher with an
      -- empty patterns list still needs a row.
      local name = (type(entry.name) == "string" and entry.name ~= "") and entry.name or "Unnamed matcher"
      local patterns = (type(entry.patterns) == "table") and entry.patterns or {}
      local isOpen = FiltersUI.rulesOpen[i] and true or false
      local isWin = (i == winIndex)
      local oc = outcomeColor(entry.outcome)

      row.Rank:SetText(tostring(i))
      if i == 1 then row.UpBtn:Disable() else row.UpBtn:Enable() end
      if i == #pipeline then row.DownBtn:Disable() else row.DownBtn:Enable() end
      row.Caret:SetText(isOpen and "v" or ">")
      row.Dot:SetTexture(oc[1], oc[2], oc[3], 1)
      row.Name:SetText(FiltersUI.clipText(name, NAME_MAX_CHARS))
      row.Summary:SetText(FiltersUI.clipText(FiltersUI.patternSummary(entry), SUMMARY_MAX_CHARS))
      if isWin then row.MatchLabel:Show() else row.MatchLabel:Hide() end
      row.OutBtn:SetText(outcomeLabel(entry.outcome))
      local ofs = row.OutBtn.GetFontString and row.OutBtn:GetFontString()
      if ofs then ofs:SetTextColor(oc[1], oc[2], oc[3], 1) end

      if isWin then
        row:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.9)
      else
        row:SetBackdropBorderColor(1, 1, 1, 0.10)
      end

      row.UpBtn:SetScript("OnClick", function()
        if i > 1 then pipeline[i - 1], pipeline[i] = pipeline[i], pipeline[i - 1]; FiltersUI.reapply() end
      end)
      row.DownBtn:SetScript("OnClick", function()
        if i < #pipeline then pipeline[i + 1], pipeline[i] = pipeline[i], pipeline[i + 1]; FiltersUI.reapply() end
      end)
      row.RemoveBtn:SetScript("OnClick", function()
        table.remove(pipeline, i)
        FiltersUI.rulesOpen[i] = nil
        FiltersUI.reapply()
      end)
      row.OutBtn:SetScript("OnClick", function()
        showOutcomeMenu(row.OutBtn, function(newOutcome)
          entry.outcome = newOutcome
          FiltersUI.reapply()
        end)
      end)
      -- Click-to-expand: bound on row.Header (the EnableMouse'd background
      -- strip) only. Arrows/outcome-dropdown/remove are child Buttons that
      -- capture their own clicks first (WoW's normal topmost-interactive-
      -- frame routing), so this only fires on the empty part of the header.
      -- A local render (not a full reapply()) -- toggling a row open/closed
      -- is pure UI state, no data changed, no board refresh needed.
      row.Header:SetScript("OnMouseDown", function()
        FiltersUI.rulesOpen[i] = not FiltersUI.rulesOpen[i]
        FiltersUI.renderRulesTab()
      end)

      local bodyH = 0
      if isOpen then
        row.Body:Show()
        bodyH = layoutMatcherBody(row, entry, cfg, i)
      else
        row.Body:Hide()
      end
      row.Body:SetHeight(bodyH > 0 and bodyH or 1)
      row:SetHeight(ROW_H + bodyH)

      y = y - (ROW_H + bodyH + ROW_GAP)
    end
  end
  for i = #pipeline + 1, #ruleRowPool do ruleRowPool[i]:Hide() end

  -- root (panel.RulesBody) now holds ONLY matcher rows -- the scroll
  -- region's true content height is exactly their stacked height. The
  -- add-matcher/reset row and the live test box are PINNED outside the
  -- scroll entirely (panel.RulesPinned, a sibling of panel.BodyScroll --
  -- see renderRulesPinned below and buildPanel's own header note on why).
  if updateScrollbar then updateScrollbar(panel.BodyScroll, -y) end
  FiltersUI.renderRulesPinned()
end

-- renderRulesPinned: refreshes the PINNED footer's live state (the reset
-- button's armed/confirm styling, the live-test result line) -- called on
-- every renderRulesTab() pass. The pinned widgets' own POSITIONS are set
-- once in buildPanel (they never scroll and never reflow), so this only
-- ever touches their content, never ClearAllPoints/SetPoint.
function FiltersUI.renderRulesPinned()
  local panel = FiltersUI.panel
  if not panel or not panel.RulesPinned then return end
  styleResetButton(panel.RulesPinned.ResetBtn)
  updateTestResultDisplay()
end

-- ============================================================
-- tab switch + panel build
-- ============================================================

local CATS_HINT = "A category is a name, a color, and its order in the board's rail. The Priority & Rules tab decides which lines actually use it."
local RULES_HINT = "Matchers run top to bottom -- first match wins. Click a row to edit its name and patterns. Each one routes to a category, or Do Nothing (skip it) / Hide (keep it off the board)."

-- BodyScroll's bottom anchor moves depending on the active tab: on
-- Categories it reaches almost to the panel bottom (nothing pinned below
-- it); on Priority & Rules it stops short, above panel.RulesPinned (the
-- add-matcher/reset row + the live test box, fixed outside the scroll --
-- see this file's header note above renderRulesPinned). Re-anchoring a
-- shared ScrollFrame per tab, rather than building two separate scroll
-- frames, matches this file's existing "one BodyScroll, two bodies shown/
-- hidden inside it" pattern.
local function positionBodyScroll(panel)
  panel.BodyScroll:ClearAllPoints()
  panel.BodyScroll:SetPoint("TOPLEFT", panel.Hint, "BOTTOMLEFT", -2, -8)
  if FiltersUI.activeTab == "rules" then
    panel.BodyScroll:SetPoint("BOTTOMRIGHT", panel.RulesPinned, "TOPRIGHT", 0, PINNED_GAP)
  else
    panel.BodyScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 34)
  end
end

function FiltersUI.renderActiveTab()
  local panel = FiltersUI.panel
  if not panel then return end
  setSegmentActive(panel.TabCats, FiltersUI.activeTab == "cats")
  setSegmentActive(panel.TabRules, FiltersUI.activeTab == "rules")
  positionBodyScroll(panel)
  if FiltersUI.activeTab == "cats" then
    panel.Hint:SetText(CATS_HINT)
    panel.RulesBody:Hide()
    if panel.RulesPinned then panel.RulesPinned:Hide() end
    panel.CatsBody:Show()
    FiltersUI.renderCategoriesTab()
  else
    panel.Hint:SetText(RULES_HINT)
    panel.CatsBody:Hide()
    if panel.RulesPinned then panel.RulesPinned:Show() end
    panel.RulesBody:Show()
    FiltersUI.renderRulesTab()
  end
end

local function buildPanel()
  if not CreateFrame then return nil end

  local panel = CreateFrame("Frame", "YABBRulesEditor", UIParent)
  panel:SetWidth(PANEL_W)
  panel:SetHeight(PANEL_H)
  panel:SetPoint("CENTER")
  panel:SetFrameStrata("DIALOG")
  panel:SetToplevel(true)
  panel:SetClampedToScreen(true)
  panel:SetMovable(true)
  panel:EnableMouse(true)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(panel, {
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
      bgColor = { 0.047, 0.055, 0.071, 0.97 },
      borderColor = { 0.91, 0.77, 0.42, 0.35 },
    })
  end
  panel:Hide()
  if UISpecialFrames and tinsert then tinsert(UISpecialFrames, "YABBRulesEditor") end

  panel:SetScript("OnMouseDown", function(self, button) if button == "LeftButton" then self:StartMoving() end end)
  panel:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)

  panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  panel.Title:SetPoint("TOPLEFT", 16, -14)
  panel.Title:SetText("YABB rules editor")
  panel.Title:SetTextColor(0.91, 0.77, 0.42, 1)

  panel.Close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  panel.Close:SetPoint("TOPRIGHT", -4, -4)

  panel.ShareBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.ShareBtn:SetWidth(96)
  panel.ShareBtn:SetHeight(20)
  panel.ShareBtn:SetPoint("TOPRIGHT", panel.Close, "TOPLEFT", -6, -2)
  panel.ShareBtn:SetText("Share config")
  themeButton(panel.ShareBtn)
  panel.ShareBtn:SetScript("OnClick", function()
    -- Shares the LIVE effective config (ns.C), not db() -- so sharing works
    -- correctly even for a user who never opened this editor and is still
    -- running the shipped defaults (db().categories/.pipeline would still
    -- be the empty "use defaults" sentinel in that case).
    local snapshot = { categories = (ns.C and ns.C.categories) or {}, pipeline = (ns.C and ns.C.pipeline) or {} }
    -- Compact path first (LibDeflate/LibSerialize, client-bundled --
    -- Filters.exportEncoded): a "!YABB:1!" string far shorter than the raw
    -- Lua-literal dump. Filters.exportEncoded itself never errors (it
    -- returns nil when the libs aren't resolvable) but this stays
    -- pcall-wrapped defensively regardless. If it returns nil, fall back
    -- to the raw export so sharing keeps working either way, and note
    -- the fallback on the copy window itself, where it's actually seen.
    local okEnc, encoded = pcall(ns.Filters.exportEncoded, snapshot)
    if okEnc and encoded then
      FiltersUI.showCopyWindow("YABB rules config", encoded)
      return
    end
    local ok, str = pcall(ns.Filters.export, snapshot)
    if ok then
      FiltersUI.showCopyWindow("YABB rules config", str)
      local win = FiltersUI.copyWindow
      if win and win.Status then
        win.Status:SetText("|cffff8040Shared as an uncompressed string, so it will be longer than usual.|r")
      end
    else
      panel.Status:SetText("|cffff4040Share failed: " .. tostring(str) .. "|r")
    end
  end)

  panel.ImportBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.ImportBtn:SetWidth(70)
  panel.ImportBtn:SetHeight(20)
  panel.ImportBtn:SetPoint("TOPRIGHT", panel.ShareBtn, "TOPLEFT", -6, 0)
  panel.ImportBtn:SetText("Import")
  themeButton(panel.ImportBtn)
  panel.ImportBtn:SetScript("OnClick", function() FiltersUI.openImportWindow() end)

  panel.Status = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  panel.Status:SetPoint("BOTTOMLEFT", 16, 8)
  panel.Status:SetPoint("RIGHT", -16, 8)
  panel.Status:SetJustifyH("LEFT")

  panel.TabCats = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.TabCats:SetWidth(100); panel.TabCats:SetHeight(22)
  panel.TabCats:SetPoint("TOPLEFT", 14, -40)
  panel.TabCats:SetText("Categories")
  themeButton(panel.TabCats)
  -- FiltersUI.cancelResetArm() on every tab switch: FiltersUI.resetArmed
  -- is shared across both tabs' Reset buttons, so switching tabs while
  -- armed (but not yet confirmed) must not leave the OTHER tab's button
  -- primed to fire on a click nobody meant as a confirmation.
  panel.TabCats:SetScript("OnClick", function()
    FiltersUI.cancelResetArm()
    FiltersUI.activeTab = "cats"
    FiltersUI.renderActiveTab()
  end)

  panel.TabRules = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  panel.TabRules:SetWidth(140); panel.TabRules:SetHeight(22)
  panel.TabRules:SetPoint("LEFT", panel.TabCats, "RIGHT", 4, 0)
  panel.TabRules:SetText("Priority & Rules")
  themeButton(panel.TabRules)
  panel.TabRules:SetScript("OnClick", function()
    FiltersUI.cancelResetArm()
    FiltersUI.activeTab = "rules"
    FiltersUI.renderActiveTab()
  end)

  panel.Hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  panel.Hint:SetPoint("TOPLEFT", panel.TabCats, "BOTTOMLEFT", 2, -8)
  panel.Hint:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  panel.Hint:SetJustifyH("LEFT")
  panel.Hint:SetHeight(32)

  -- ---- Priority & Rules tab's pinned footer (add/reset row + live
  -- test box) -- built BEFORE panel.BodyScroll below since
  -- positionBodyScroll (called from every renderActiveTab) anchors the
  -- scroll's bottom edge off this frame's TOPRIGHT on the Rules tab. A
  -- sibling of panel.BodyScroll, NOT a child of
  -- panel.BodyScrollChild/RulesBody -- it never scrolls, so the
  -- add-matcher/reset row and the live test box stay visible regardless
  -- of scroll position. Hidden by default (renderActiveTab shows it
  -- only on the Rules tab).
  panel.RulesPinned = CreateFrame("Frame", nil, panel)
  panel.RulesPinned:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 34)
  panel.RulesPinned:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 34)
  panel.RulesPinned:SetHeight(RULES_PINNED_H)
  panel.RulesPinned:Hide()

  -- Same row, opposite sides: "+ Add matcher" LEFT, "Reset to defaults"
  -- RIGHT -- not stacked.
  panel.RulesPinned.AddBtn = CreateFrame("Button", nil, panel.RulesPinned, "UIPanelButtonTemplate")
  panel.RulesPinned.AddBtn:SetWidth(110); panel.RulesPinned.AddBtn:SetHeight(20)
  panel.RulesPinned.AddBtn:SetPoint("TOPLEFT", panel.RulesPinned, "TOPLEFT", 0, 0)
  panel.RulesPinned.AddBtn:SetText("+ Add matcher")
  themeButton(panel.RulesPinned.AddBtn)
  panel.RulesPinned.AddBtn:SetScript("OnClick", function()
    -- New matcher: name + patterns -> outcome, lands just above the
    -- catch-all, expanded for editing immediately.
    local cfg = ensureMaterialized()
    local insertAt = (#cfg.pipeline > 0) and #cfg.pipeline or 1
    table.insert(cfg.pipeline, insertAt, { name = "New matcher", patterns = {}, outcome = { kind = "hide" } })
    FiltersUI.rulesOpen[insertAt] = true
    FiltersUI.reapply()
  end)

  -- Same genuine, destructive reset as the Categories tab's ResetBtn
  -- below (shared FiltersUI.requestReset/resetArmed).
  panel.RulesPinned.ResetBtn = CreateFrame("Button", nil, panel.RulesPinned, "UIPanelButtonTemplate")
  panel.RulesPinned.ResetBtn:SetWidth(150); panel.RulesPinned.ResetBtn:SetHeight(20)
  panel.RulesPinned.ResetBtn:SetPoint("TOPRIGHT", panel.RulesPinned, "TOPRIGHT", 0, 0)
  panel.RulesPinned.ResetBtn:SetText("Reset to defaults")
  themeButton(panel.RulesPinned.ResetBtn)
  panel.RulesPinned.ResetBtn:SetScript("OnClick", FiltersUI.requestReset)

  -- LIVE TEST box -- pinned at the very bottom of the panel, below the
  -- add/reset row, always visible regardless of scroll position.
  panel.RulesPinned.TestSection = CreateFrame("Frame", nil, panel.RulesPinned)
  panel.RulesPinned.TestSection:SetPoint("TOPLEFT", panel.RulesPinned, "TOPLEFT", 0, -(PINNED_ROW_H + PINNED_GAP))
  panel.RulesPinned.TestSection:SetPoint("TOPRIGHT", panel.RulesPinned, "TOPRIGHT", 0, -(PINNED_ROW_H + PINNED_GAP))
  panel.RulesPinned.TestSection:SetHeight(TEST_SECTION_H)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(panel.RulesPinned.TestSection, {
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
      bgColor = { 0.02, 0.02, 0.03, 0.6 },
      borderColor = { 1, 1, 1, 0.10 },
    })
  end
  panel.RulesPinned.TestSection.Label = panel.RulesPinned.TestSection:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  panel.RulesPinned.TestSection.Label:SetPoint("TOPLEFT", 10, -8)
  panel.RulesPinned.TestSection.Label:SetText("TEST A LINE")

  -- Plain EditBox (no InputBoxTemplate -- see themeEditBox's header note):
  -- same broken-border template the two per-row fields above had.
  panel.RulesPinned.TestInput = CreateFrame("EditBox", "YABBRulesTestInput", panel.RulesPinned.TestSection)
  panel.RulesPinned.TestInput:SetHeight(20)
  panel.RulesPinned.TestInput:SetAutoFocus(false)
  panel.RulesPinned.TestInput:SetPoint("TOPLEFT", panel.RulesPinned.TestSection.Label, "BOTTOMLEFT", 4, -6)
  panel.RulesPinned.TestInput:SetPoint("RIGHT", panel.RulesPinned.TestSection, "RIGHT", -14, 0)
  themeEditBox(panel.RulesPinned.TestInput)
  panel.RulesPinned.TestInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  panel.RulesPinned.TestInput:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    FiltersUI.testLine = self:GetText() or ""
    FiltersUI.refreshRulesLive()
  end)

  panel.RulesPinned.TestSection.TestResult = panel.RulesPinned.TestSection:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  panel.RulesPinned.TestSection.TestResult:SetPoint("TOPLEFT", panel.RulesPinned.TestInput, "BOTTOMLEFT", -4, -8)
  panel.RulesPinned.TestSection.TestResult:SetPoint("RIGHT", panel.RulesPinned.TestSection, "RIGHT", -14, 0)
  panel.RulesPinned.TestSection.TestResult:SetJustifyH("LEFT")

  panel.BodyScroll = CreateFrame("ScrollFrame", "YABBRulesBodyScroll", panel, "UIPanelScrollFrameTemplate")
  panel.BodyScroll:SetPoint("TOPLEFT", panel.Hint, "BOTTOMLEFT", -2, -8)
  panel.BodyScroll:SetPoint("BOTTOMRIGHT", -30, 34)
  panel.BodyScrollChild = CreateFrame("Frame", nil, panel.BodyScroll)
  panel.BodyScrollChild:SetWidth(CONTENT_W)
  panel.BodyScrollChild:SetHeight(1)
  panel.BodyScroll:SetScrollChild(panel.BodyScrollChild)
  wireMouseWheel(panel.BodyScroll)
  themeScrollbar(panel.BodyScroll)

  -- ---- Categories tab body ----
  panel.CatsBody = CreateFrame("Frame", nil, panel.BodyScrollChild)
  panel.CatsBody:SetPoint("TOPLEFT", panel.BodyScrollChild, "TOPLEFT", 0, 0)
  panel.CatsBody:SetWidth(CONTENT_W)
  panel.CatsBody:SetHeight(1)

  panel.CatsBody.AddRow = CreateFrame("Frame", nil, panel.CatsBody)
  panel.CatsBody.AddRow:SetWidth(CONTENT_W)
  panel.CatsBody.AddRow:SetHeight(24)

  panel.CatsBody.AddRow.SwBtn = CreateFrame("Button", nil, panel.CatsBody.AddRow)
  panel.CatsBody.AddRow.SwBtn:SetWidth(20); panel.CatsBody.AddRow.SwBtn:SetHeight(20)
  panel.CatsBody.AddRow.SwBtn:SetPoint("LEFT", panel.CatsBody.AddRow, "LEFT", 0, 0)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(panel.CatsBody.AddRow.SwBtn, {
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
      bgColor = { FiltersUI.pendingCatColor[1], FiltersUI.pendingCatColor[2], FiltersUI.pendingCatColor[3], 1 },
      borderColor = { 1, 1, 1, 0.2 },
    })
  end
  panel.CatsBody.AddRow.SwBtn:SetScript("OnClick", function()
    FiltersUI.openPalette(panel.CatsBody.AddRow.SwBtn, function(picked)
      FiltersUI.pendingCatColor = picked
      panel.CatsBody.AddRow.SwBtn:SetBackdropColor(picked[1], picked[2], picked[3], 1)
    end)
  end)

  -- Plain EditBox (no InputBoxTemplate -- see themeEditBox's header note):
  -- same broken-border template the two per-row fields above had.
  panel.CatsBody.AddRow.NameField = CreateFrame("EditBox", "YABBRulesAddCatName", panel.CatsBody.AddRow)
  panel.CatsBody.AddRow.NameField:SetHeight(20)
  panel.CatsBody.AddRow.NameField:SetAutoFocus(false)
  panel.CatsBody.AddRow.NameField:SetWidth(220)
  panel.CatsBody.AddRow.NameField:SetPoint("LEFT", panel.CatsBody.AddRow.SwBtn, "RIGHT", 12, 0)
  themeEditBox(panel.CatsBody.AddRow.NameField)
  panel.CatsBody.AddRow.NameField:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  panel.CatsBody.AddRow.AddBtn = CreateFrame("Button", nil, panel.CatsBody.AddRow, "UIPanelButtonTemplate")
  panel.CatsBody.AddRow.AddBtn:SetWidth(70); panel.CatsBody.AddRow.AddBtn:SetHeight(20)
  panel.CatsBody.AddRow.AddBtn:SetPoint("LEFT", panel.CatsBody.AddRow.NameField, "RIGHT", 10, 0)
  panel.CatsBody.AddRow.AddBtn:SetText("+ Add")
  themeButton(panel.CatsBody.AddRow.AddBtn)
  local function submitAddCategory()
    local name = trim(panel.CatsBody.AddRow.NameField:GetText() or "")
    if name == "" then return end
    local cfg = ensureMaterialized()
    local color = FiltersUI.pendingCatColor or COLORS[10]
    local insertAt = (#cfg.categories > 0) and #cfg.categories or 1
    table.insert(cfg.categories, insertAt, { name = name, color = { r = color[1], g = color[2], b = color[3], a = 1 } })
    panel.CatsBody.AddRow.NameField:SetText("")
    FiltersUI.reapply()
  end
  panel.CatsBody.AddRow.AddBtn:SetScript("OnClick", submitAddCategory)
  panel.CatsBody.AddRow.NameField:SetScript("OnEnterPressed", submitAddCategory)

  -- Genuine, destructive reset (see FiltersUI.requestReset/
  -- performFullReset's own header note above): a second, identical
  -- button lives in the Priority & Rules tab's pinned footer
  -- (panel.RulesPinned.ResetBtn, built above), both wired to the same
  -- two-click-gated FiltersUI.requestReset.
  panel.CatsBody.ResetBtn = CreateFrame("Button", nil, panel.CatsBody, "UIPanelButtonTemplate")
  panel.CatsBody.ResetBtn:SetWidth(150); panel.CatsBody.ResetBtn:SetHeight(20)
  panel.CatsBody.ResetBtn:SetText("Reset to defaults")
  themeButton(panel.CatsBody.ResetBtn)
  panel.CatsBody.ResetBtn:SetScript("OnClick", FiltersUI.requestReset)

  -- ---- Priority & Rules tab body -- matcher rows only. The
  -- add-matcher/reset row and the live test box live in
  -- panel.RulesPinned, built above, outside the scroll entirely.
  panel.RulesBody = CreateFrame("Frame", nil, panel.BodyScrollChild)
  panel.RulesBody:SetPoint("TOPLEFT", panel.BodyScrollChild, "TOPLEFT", 0, 0)
  panel.RulesBody:SetWidth(CONTENT_W)
  panel.RulesBody:SetHeight(1)
  panel.RulesBody:Hide()

  FiltersUI.panel = panel
  return panel
end

-- ============================================================
-- open / show / hide / toggle
-- ============================================================

function FiltersUI.openEditor()
  ensureMaterialized()
  FiltersUI.cancelResetArm() -- a stale armed-from-last-session click must never carry into a fresh open
  local panel = FiltersUI.panel or buildPanel()
  if not panel then return end
  panel:Show()
  FiltersUI.reapply()
end

-- ============================================================
-- Settings panel -- ns.FiltersUI.openSettings() is the seam UI.lua's
-- titlebar gear button calls into (openEditor above is one click
-- further in, via this panel's own "Edit categories & rules" button).
-- Four groups stack in one vertical scroll pane: Channels to watch,
-- Listings expire after, Categories & rules (a single button into the
-- rules editor -- categories are that editor's job, not this panel's),
-- and Display.
--
-- Persistence -- two flat top-level YABB_DB keys (deliberately NOT
-- under userConfig, which is the rules-editor's own namespace):
--   YABB_DB.expiry  -- seconds; 0 = never expire; nil = not yet
--     configured (falls back to the 5-minute segment, matching
--     Board.lua's own DEFAULT_TTL of 300 -- the segmented control
--     always shows exactly one active segment, never "none selected").
--   YABB_DB.display.{roleIcons,classColors,showLevel,compact} --
--     booleans; nil reads as that flag's own default (true for the
--     first three, false for compact). UI.lua duplicates this exact
--     default table for its own row-render reads rather than calling
--     through to this file -- every file reads YABB_DB directly and
--     stays self-sufficient (see Ingest.isChannelEnabled for the same
--     convention).
-- Channel mute state is unchanged: YABB_DB.channels.<name>, owned by
-- Ingest.lua (Ingest.isChannelEnabled/setChannelEnabled) -- this panel
-- is just another caller of that existing seam.
-- ============================================================

local SETTINGS_W, SETTINGS_H = 480, 480
local SETTINGS_CONTENT_W = 420
local TOGGLE_H = 22

local DISPLAY_DEFAULT = { roleIcons = true, classColors = true, showLevel = true, compact = false }
local DISPLAY_ORDER = { "roleIcons", "classColors", "showLevel", "compact" }
local DISPLAY_LABEL = {
  roleIcons = "Role icons", classColors = "Class colors",
  showLevel = "Show level", compact = "Compact rows",
}

-- Segmented-control data: label + the exact seconds Board.lua's setTtl
-- expects (Never -> 0, Board.lua's own "sweep becomes a no-op" sentinel).
local EXPIRY_OPTIONS = {
  { label = "2 min", seconds = 120 },
  { label = "5 min", seconds = 300 },
  { label = "10 min", seconds = 600 },
  { label = "Never", seconds = 0 },
}
FiltersUI.EXPIRY_OPTIONS = EXPIRY_OPTIONS

-- Pure, no WoW global touched -- TDD'd, tests/settings_spec.lua. Which
-- segment is "active" for a saved seconds value; falls back to the
-- 5-minute segment (index 2) both when sec is nil (never configured)
-- and when it doesn't exactly match one of the four options (e.g. a
-- hand-edited SavedVariables value), so the UI never renders with zero
-- segments highlighted.
function FiltersUI.expiryIndexForSeconds(sec)
  if sec == nil then sec = 300 end
  for i, opt in ipairs(EXPIRY_OPTIONS) do
    if opt.seconds == sec then return i end
  end
  return 2
end

-- Pure read (references the YABB_DB global, never a WoW API function --
-- safe at any time, including under the plain-Lua stub where YABB_DB is
-- simply nil/whatever a test set it to). nil (never configured) reads
-- as the flag's own default, per-key -- NOT a single hardcoded true,
-- since compact's shipped default is false.
function FiltersUI.isDisplayOn(key)
  local v
  if type(YABB_DB) == "table" and type(YABB_DB.display) == "table" then
    v = YABB_DB.display[key]
  end
  if v == nil then return DISPLAY_DEFAULT[key] end
  return v ~= false
end

function FiltersUI.setDisplay(key, on)
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  if type(YABB_DB.display) ~= "table" then YABB_DB.display = {} end
  YABB_DB.display[key] = on and true or false
  if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  FiltersUI.renderSettings()
end

function FiltersUI.setExpiry(sec)
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  YABB_DB.expiry = sec
  if ns.board and ns.board.setTtl then ns.board:setTtl(sec) end
  if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
  FiltersUI.renderSettings()
end

-- ============================================================
-- toggle-pill pool factory -- a small on/off pill (dot + label, gold
-- border when on), flow-wrapped left-to-right: same acquire-or-create /
-- measure-real-text-width / show-in-use-hide-rest idiom as the chip
-- pool above, just non-removable and click=toggle instead of
-- click=remove. TWO separate pools (channels/display), not one shared
-- one -- a pooled frame's parent is fixed forever at CreateFrame time,
-- and channels/display render into two DIFFERENT container frames every
-- pass; a shared pool reused across both would leave stale frames
-- parented to the wrong container whenever the channel count changes
-- between renders (the exact bug class chip/rail pools avoid by each
-- ever having exactly one container).
-- ============================================================

local function newTogglePool()
  local pool = {}
  local function acquire(i, parent)
    local t = pool[i]
    if not t then
      t = CreateFrame("Button", nil, parent)
      t:SetHeight(TOGGLE_H)
      if ns.Compat and ns.Compat.applyBackdrop then
        ns.Compat.applyBackdrop(t, {
          bgFile = "Interface\\Buttons\\WHITE8x8",
          edgeFile = "Interface\\Buttons\\WHITE8x8",
          tile = false, edgeSize = 1,
          insets = { left = 1, right = 1, top = 1, bottom = 1 },
          bgColor = { 0.047, 0.055, 0.071, 0.9 },
          borderColor = { 1, 1, 1, 0.14 },
        })
      end
      t.Dot = t:CreateTexture(nil, "ARTWORK")
      t.Dot:SetWidth(8)
      t.Dot:SetHeight(8)
      t.Dot:SetPoint("LEFT", 9, 0)
      t.Text = t:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      t.Text:SetJustifyH("LEFT")
      t.Text:SetPoint("LEFT", t.Dot, "RIGHT", 7, 0)
      t:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
      pool[i] = t
    end
    return t
  end
  -- items: array of {label=, on=, onClick=}. Returns the flowed height.
  return function(container, items, width)
    local x, y = 0, 0
    for i, item in ipairs(items) do
      local t = acquire(i, container)
      t.Text:SetText(tostring(item.label))
      if item.on then
        t.Dot:SetTexture(0.27, 0.75, 0.48, 1)
        t.Text:SetTextColor(0.87, 0.90, 0.96, 1)
        t:SetBackdropBorderColor(0.91, 0.77, 0.42, 0.45)
      else
        t.Dot:SetTexture(0.55, 0.58, 0.66, 1)
        t.Text:SetTextColor(0.60, 0.64, 0.71, 1)
        t:SetBackdropBorderColor(1, 1, 1, 0.14)
      end
      local textW = t.Text:GetStringWidth() or 60
      local w = 9 + 8 + 7 + textW + 10
      t:SetWidth(w)
      t:SetScript("OnClick", function() pcall(item.onClick) end)
      if x > 0 and x + w > width then
        x = 0
        y = y - (TOGGLE_H + 6)
      end
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
      t:Show()
      x = x + w + 6
    end
    for i = #items + 1, #pool do pool[i]:Hide() end
    if #items == 0 then return 0 end
    return -y + TOGGLE_H
  end
end

local flowChannelToggles = newTogglePool()
local flowDisplayToggles = newTogglePool()

-- ============================================================
-- render -- lays out all four groups top-to-bottom into
-- panel.BodyScrollChild, exactly the same "measure real text/content
-- height as you go, ClearAllPoints+SetPoint every widget every call"
-- discipline the rules editor above already uses. Safe to call before
-- the panel exists (guards on FiltersUI.settingsPanel).
-- ============================================================

function FiltersUI.renderSettings()
  local panel = FiltersUI.settingsPanel
  if not panel then return end
  local root = panel.BodyScrollChild
  local y = 0

  -- ---- Channels to watch ----
  root.ChanHeader:ClearAllPoints()
  root.ChanHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - 16

  local channels = (ns.Compat and ns.Compat.getJoinedChannels and ns.Compat.getJoinedChannels()) or {}
  local chanItems, seen = {}, {}
  for _, ch in ipairs(channels) do
    local name = ch and ch.name
    if name and not seen[name] then
      seen[name] = true
      local on = true
      if ns.Ingest and ns.Ingest.isChannelEnabled then on = ns.Ingest.isChannelEnabled(name) end
      chanItems[#chanItems + 1] = {
        label = name, on = on,
        onClick = function()
          if ns.Ingest and ns.Ingest.setChannelEnabled then
            ns.Ingest.setChannelEnabled(name, not on)
          end
          FiltersUI.renderSettings()
        end,
      }
    end
  end

  root.ChanContainer:ClearAllPoints()
  root.ChanContainer:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  local chanH
  if #chanItems == 0 then
    root.ChanContainer:Hide()
    root.ChanEmpty:Show()
    root.ChanEmpty:ClearAllPoints()
    root.ChanEmpty:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
    chanH = root.ChanEmpty:GetHeight() or 14
  else
    root.ChanEmpty:Hide()
    root.ChanContainer:Show()
    chanH = flowChannelToggles(root.ChanContainer, chanItems, SETTINGS_CONTENT_W)
    root.ChanContainer:SetHeight(math.max(chanH, 1))
  end
  y = y - chanH - 6

  root.ChanHint:ClearAllPoints()
  root.ChanHint:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - (root.ChanHint:GetHeight() or 14) - 20

  -- ---- Listings expire after ----
  root.ExpiryHeader:ClearAllPoints()
  root.ExpiryHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - 16

  root.ExpirySeg:ClearAllPoints()
  root.ExpirySeg:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  local activeIdx = FiltersUI.expiryIndexForSeconds(YABB_DB and YABB_DB.expiry)
  for i, btn in ipairs(root.ExpiryButtons) do
    btn:ClearAllPoints()
    if i == 1 then
      btn:SetPoint("LEFT", root.ExpirySeg, "LEFT", 0, 0)
    else
      btn:SetPoint("LEFT", root.ExpiryButtons[i - 1], "RIGHT", 4, 0)
    end
    if i == activeIdx then btn:Disable() else btn:Enable() end
    setSegmentActive(btn, i == activeIdx)
  end
  y = y - 26

  root.ExpiryHint:ClearAllPoints()
  root.ExpiryHint:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - (root.ExpiryHint:GetHeight() or 14) - 20

  -- ---- Categories & rules (a link into the rules editor) ----
  root.RulesHeader:ClearAllPoints()
  root.RulesHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - 16

  root.RulesHint:ClearAllPoints()
  root.RulesHint:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - (root.RulesHint:GetHeight() or 14) - 8

  root.EditRulesBtn:ClearAllPoints()
  root.EditRulesBtn:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - 22 - 20

  -- ---- Display ----
  root.DisplayHeader:ClearAllPoints()
  root.DisplayHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  y = y - 16

  local dispItems = {}
  for _, key in ipairs(DISPLAY_ORDER) do
    local on = FiltersUI.isDisplayOn(key)
    dispItems[#dispItems + 1] = {
      label = DISPLAY_LABEL[key], on = on,
      onClick = function() FiltersUI.setDisplay(key, not on) end,
    }
  end
  root.DisplayContainer:ClearAllPoints()
  root.DisplayContainer:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
  local dispH = flowDisplayToggles(root.DisplayContainer, dispItems, SETTINGS_CONTENT_W)
  root.DisplayContainer:SetHeight(math.max(dispH, 1))
  y = y - dispH - 10

  if updateScrollbar then updateScrollbar(panel.BodyScroll, -y) end
end

-- ============================================================
-- panel build -- lazy, first openSettings() call. Same fixed-size,
-- movable-by-titlebar-only, native-Backdrop, UISpecialFrames (ESC
-- closes) convention as buildPanel() (the rules editor) above; every
-- FontString/Frame widget is created ONCE here, then positioned/filled
-- by renderSettings() on every call (including this one, at the end).
-- ============================================================

local function buildSettingsPanel()
  if not CreateFrame then return nil end

  local panel = CreateFrame("Frame", "YABBSettingsPanel", UIParent)
  panel:SetWidth(SETTINGS_W)
  panel:SetHeight(SETTINGS_H)
  panel:SetPoint("CENTER")
  panel:SetFrameStrata("DIALOG")
  panel:SetToplevel(true)
  panel:SetClampedToScreen(true)
  panel:SetMovable(true)
  panel:EnableMouse(true)
  if ns.Compat and ns.Compat.applyBackdrop then
    ns.Compat.applyBackdrop(panel, {
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      tile = false, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
      bgColor = { 0.047, 0.055, 0.071, 0.97 },
      borderColor = { 0.91, 0.77, 0.42, 0.35 },
    })
  end
  panel:Hide()
  if UISpecialFrames and tinsert then tinsert(UISpecialFrames, "YABBSettingsPanel") end

  panel:SetScript("OnMouseDown", function(self, button) if button == "LeftButton" then self:StartMoving() end end)
  panel:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)

  panel.Title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  panel.Title:SetPoint("TOPLEFT", 16, -14)
  panel.Title:SetText("YABB settings")
  panel.Title:SetTextColor(0.91, 0.77, 0.42, 1)

  panel.Close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  panel.Close:SetPoint("TOPRIGHT", -4, -4)

  panel.Status = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  panel.Status:SetPoint("BOTTOMLEFT", 16, 8)
  panel.Status:SetPoint("RIGHT", -16, 8)
  panel.Status:SetJustifyH("LEFT")

  panel.BodyScroll = CreateFrame("ScrollFrame", "YABBSettingsBodyScroll", panel, "UIPanelScrollFrameTemplate")
  panel.BodyScroll:SetPoint("TOPLEFT", 16, -44)
  panel.BodyScroll:SetPoint("BOTTOMRIGHT", -30, 34)
  panel.BodyScrollChild = CreateFrame("Frame", nil, panel.BodyScroll)
  panel.BodyScrollChild:SetWidth(SETTINGS_CONTENT_W)
  panel.BodyScrollChild:SetHeight(1)
  panel.BodyScroll:SetScrollChild(panel.BodyScrollChild)
  wireMouseWheel(panel.BodyScroll)
  themeScrollbar(panel.BodyScroll)

  local root = panel.BodyScrollChild

  root.ChanHeader = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.ChanHeader:SetText("CHANNELS TO WATCH")
  root.ChanHeader:SetJustifyH("LEFT")
  root.ChanHeader:SetTextColor(0.91, 0.77, 0.42, 0.85)

  root.ChanContainer = CreateFrame("Frame", nil, root)
  root.ChanContainer:SetWidth(SETTINGS_CONTENT_W)
  root.ChanContainer:SetHeight(1)

  root.ChanEmpty = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.ChanEmpty:SetText("No channels detected yet -- open a chat channel window, then reopen settings.")
  root.ChanEmpty:SetWidth(SETTINGS_CONTENT_W)
  root.ChanEmpty:SetJustifyH("LEFT")

  root.ChanHint = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.ChanHint:SetText("Every channel you're in is watched by default. Click one to mute it.")
  root.ChanHint:SetWidth(SETTINGS_CONTENT_W)
  root.ChanHint:SetJustifyH("LEFT")

  root.ExpiryHeader = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.ExpiryHeader:SetText("LISTINGS EXPIRE AFTER")
  root.ExpiryHeader:SetJustifyH("LEFT")
  root.ExpiryHeader:SetTextColor(0.91, 0.77, 0.42, 0.85)

  root.ExpirySeg = CreateFrame("Frame", nil, root)
  root.ExpirySeg:SetWidth(SETTINGS_CONTENT_W)
  root.ExpirySeg:SetHeight(20)
  root.ExpiryButtons = {}
  for i, opt in ipairs(EXPIRY_OPTIONS) do
    local btn = CreateFrame("Button", nil, root.ExpirySeg, "UIPanelButtonTemplate")
    btn:SetWidth(64)
    btn:SetHeight(20)
    btn:SetText(opt.label)
    themeButton(btn)
    btn:SetScript("OnClick", function() FiltersUI.setExpiry(opt.seconds) end)
    root.ExpiryButtons[i] = btn
  end

  root.ExpiryHint = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.ExpiryHint:SetText("How long a listing stays before it disappears.")
  root.ExpiryHint:SetWidth(SETTINGS_CONTENT_W)
  root.ExpiryHint:SetJustifyH("LEFT")

  root.RulesHeader = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.RulesHeader:SetText("CATEGORIES & RULES")
  root.RulesHeader:SetJustifyH("LEFT")
  root.RulesHeader:SetTextColor(0.91, 0.77, 0.42, 0.85)

  root.RulesHint = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.RulesHint:SetText("Categories decide how listings are grouped and colored on the board. Add or edit them in the rules editor.")
  root.RulesHint:SetWidth(SETTINGS_CONTENT_W)
  root.RulesHint:SetJustifyH("LEFT")

  root.EditRulesBtn = CreateFrame("Button", nil, root, "UIPanelButtonTemplate")
  root.EditRulesBtn:SetWidth(160)
  root.EditRulesBtn:SetHeight(22)
  root.EditRulesBtn:SetText("Edit categories & rules")
  themeButton(root.EditRulesBtn)
  root.EditRulesBtn:SetScript("OnClick", function()
    if ns.FiltersUI and ns.FiltersUI.openEditor then ns.FiltersUI.openEditor() end
  end)

  root.DisplayHeader = root:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  root.DisplayHeader:SetText("DISPLAY")
  root.DisplayHeader:SetJustifyH("LEFT")
  root.DisplayHeader:SetTextColor(0.91, 0.77, 0.42, 0.85)

  root.DisplayContainer = CreateFrame("Frame", nil, root)
  root.DisplayContainer:SetWidth(SETTINGS_CONTENT_W)
  root.DisplayContainer:SetHeight(1)

  FiltersUI.settingsPanel = panel
  FiltersUI.renderSettings()
  return panel
end

function FiltersUI.openSettings()
  local panel = FiltersUI.settingsPanel or buildSettingsPanel()
  if not panel then return end
  panel:Show()
  FiltersUI.renderSettings()
end

-- ============================================================
-- init(): apply any persisted config -- safe with no WoW global present,
-- and safe against a hostile saved config, since applyPersisted's own
-- applyOverlay call is pcall-wrapped. The panels themselves are built
-- lazily on first openEditor()/openSettings() call, so init() never
-- creates any frame, staying cheap and safe to call from Init.lua's
-- central orchestrator regardless of load order relative to UI.lua.
-- ============================================================

function FiltersUI.init()
  FiltersUI.applyPersisted()
  if not CreateFrame then return false end
  return true
end

-- FiltersUI.init() is invoked exactly once by Init.lua's central
-- fail-soft orchestrator, pcall-wrapped.

return FiltersUI
