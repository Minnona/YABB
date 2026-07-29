local ADDON, ns = ...
ns.MinimapButton = ns.MinimapButton or {}
local MinimapButton = ns.MinimapButton

-- ============================================================
-- Own draggable minimap button -- no third-party icon-registry library
-- or minimap-button-collector dependency. Button shape/scripts/tooltip
-- and ring position math (angle only, no zoom/distance drag) are
-- modeled on LibGPIMinimapButton.lua and TurboPlates/MinimapButton.lua,
-- both working on this client; SetWidth/SetHeight are used directly
-- since SetSize is native here (matching UI.lua's own convention). The
-- per-quadrant clamp against GetMinimapShape below is lifted from
-- LibGPIMinimapButton.lua's MinimapShapes/UpdatePosition, since a fixed
-- radius alone doesn't account for a non-round minimap skin (e.g. a
-- SexyMap SQUARE/CORNER shape).
--
-- init() is idempotent (guards on MinimapButton.button already
-- existing); Init.lua's central orchestrator calls it exactly once,
-- pcall-wrapped (see Loader.lua for the load-scope convention).
-- ============================================================

local BUTTON_SIZE = 31
local DEFAULT_ANGLE = 225 -- LibGPIMinimapButton.lua:130 default position
local ICON_TEXTURE = "Interface\\Icons\\INV_Misc_Note_06" -- no shipped art; stock scroll/note icon

-- ============================================================
-- db() -- YABB_DB.minimap persistence. Referencing/assigning a plain
-- SavedVariables global is never an error, even before WoW populates it
-- (or under the plain-Lua test stub, where it's simply nil).
-- Type-guarded rather than a bare `or {}` so a hand-corrupted or
-- hostile-imported YABB_DB.minimap degrades to a fresh table instead of
-- raising the next time this is indexed.
-- ============================================================

local function db()
  if type(YABB_DB) ~= "table" then YABB_DB = {} end
  if type(YABB_DB.minimap) ~= "table" then YABB_DB.minimap = {} end
  if YABB_DB.minimap.angle == nil then
    YABB_DB.minimap.angle = DEFAULT_ANGLE
  end
  return YABB_DB.minimap
end

-- ============================================================
-- quadrant clamp table (LibGPIMinimapButton.lua:141-159 MinimapShapes,
-- copied verbatim) -- keeps the button flush against a non-round
-- minimap skin instead of floating off past its corner.
-- ============================================================

local MinimapShapes = {
  ["ROUND"] = { true, true, true, true },
  ["SQUARE"] = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { true, false, false, false },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { false, false, false, true },
  ["SIDE-LEFT"] = { true, true, false, false },
  ["SIDE-RIGHT"] = { false, false, true, true },
  ["SIDE-TOP"] = { true, false, true, false },
  ["SIDE-BOTTOM"] = { false, true, false, true },
  ["TRICORNER-TOPLEFT"] = { true, true, true, false },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { false, true, true, true },
}

-- ============================================================
-- UpdatePosition() -- modeled on LibGPIMinimapButton.lua:161-196, minus
-- its distance factor (this button is always ring-flush; only the angle
-- is saved).
-- ============================================================

function MinimapButton.UpdatePosition()
  local button = MinimapButton.button
  if not button or not Minimap then return end

  local angle = math.rad(db().angle)
  local w = (Minimap:GetWidth() / 2) + 10
  local h = (Minimap:GetHeight() / 2) + 10
  local x, y = math.cos(angle), math.sin(angle)

  local q = 1
  if x < 0 then q = q + 1 end -- lower
  if y > 0 then q = q + 2 end -- right
  local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
  local quad = MinimapShapes[shape] or MinimapShapes.ROUND
  if quad[q] then
    x, y = x * w, y * h
  else
    local rounding = 10
    local diagW = math.sqrt(2 * w ^ 2) - rounding
    local diagH = math.sqrt(2 * h ^ 2) - rounding
    x = math.max(-w, math.min(x * diagW, w))
    y = math.max(-h, math.min(y * diagH, h))
  end

  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- ============================================================
-- drag handlers -- modeled on LibGPIMinimapButton.lua:14-50, angle only
-- (no distance/lockDistance branch). `locked` gate modeled on that same
-- file's `db.lock == false` guard, so an accidental drag doesn't move it.
-- ============================================================

local function onUpdate(button)
  if not Minimap or not GetCursorPosition then return end
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  db().angle = math.deg(math.atan2(py - my, px - mx)) % 360
  MinimapButton.UpdatePosition()
end

local function onDragStart(button)
  if db().locked then return end
  button:LockHighlight()
  button:SetScript("OnUpdate", onUpdate)
  MinimapButton.dragging = true
  if GameTooltip then GameTooltip:Hide() end
end

local function onDragStop(button)
  button:SetScript("OnUpdate", nil)
  button:UnlockHighlight()
  MinimapButton.dragging = false
end

local function onEnter(button)
  if MinimapButton.dragging or not GameTooltip then return end
  GameTooltip:SetOwner(button, "ANCHOR_BOTTOMLEFT")
  GameTooltip:AddLine("YABB")
  GameTooltip:AddLine("Click to open", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Right-click for options", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function onLeave()
  if GameTooltip then GameTooltip:Hide() end
end

-- ============================================================
-- right-click menu -- toggle-window plus a lock-icon checkbox reusing
-- the `locked` drag gate above, same EasyMenu shape UI.lua's own
-- showRowMenu() uses.
-- ============================================================

local menuFrame

local function buildMenu()
  return {
    { text = "YABB", isTitle = true, notCheckable = true },
    { text = "Toggle window", notCheckable = true, func = function()
        if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
      end },
    { text = "Lock icon", checked = db().locked, func = function()
        db().locked = not db().locked
      end },
    { text = "Cancel", notCheckable = true },
  }
end

local function showMenu()
  if not CreateFrame or not EasyMenu then return end
  if not menuFrame then
    menuFrame = CreateFrame("Frame", "YABBMinimapMenu", UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(buildMenu(), menuFrame, "cursor", 0, 0, "MENU")
end

local function onClick(button, mouseButton)
  if GameTooltip then GameTooltip:Hide() end
  if mouseButton == "RightButton" then
    showMenu()
  else
    if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
  end
end

-- ============================================================
-- init() -- modeled on LibGPIMinimapButton.lua:80-139. Guarded on
-- CreateFrame/Minimap so it degrades to a no-op return false under the
-- plain-Lua test stub instead of erroring.
-- ============================================================

function MinimapButton.init()
  if MinimapButton.button then return true end
  if not CreateFrame or not Minimap then return false end

  local button = CreateFrame("Button", "YABBMinimapButton", Minimap)
  MinimapButton.button = button

  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:SetWidth(BUTTON_SIZE)
  button:SetHeight(BUTTON_SIZE)
  button:RegisterForClicks("anyUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = button:CreateTexture(nil, "OVERLAY")
  overlay:SetWidth(53)
  overlay:SetHeight(53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetWidth(20)
  background:SetHeight(20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(17)
  icon:SetHeight(17)
  icon:SetTexture(ICON_TEXTURE)
  icon:SetPoint("TOPLEFT", 7, -6)

  button:SetScript("OnEnter", onEnter)
  button:SetScript("OnLeave", onLeave)
  button:SetScript("OnClick", onClick)
  button:SetScript("OnDragStart", onDragStart)
  button:SetScript("OnDragStop", onDragStop)

  db() -- seed/read the persisted angle before the first placement
  MinimapButton.UpdatePosition()
  button:Show()

  return true
end

return MinimapButton
