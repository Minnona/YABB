local ADDON, ns = ...
ns.Performance = ns.Performance or {}
local Performance = ns.Performance

-- ============================================================
-- Compat hot-path caches and an idle timer driver.
-- ============================================================
local function optimiseCompat()
  local Compat = ns.Compat
  if not Compat or Compat._performanceOptimised then return end
  Compat._performanceOptimised = true

  if type(Compat.classColor) == "function" then
    local baseClassColor = Compat.classColor
    local colorCache = {}
    Compat.classColor = function(classFilename)
      local key = type(classFilename) == "string" and classFilename:upper() or ""
      local cached = colorCache[key]
      if cached then return cached end
      local color = baseClassColor(classFilename)
      colorCache[key] = color
      return color
    end
    Compat.clearClassColorCache = function() colorCache = {} end
  end

  -- Replace the always-ticking timer shim before any subsystem starts. The
  -- frame is hidden whenever the queue is empty and newly-scheduled callbacks
  -- are never executed recursively in the same OnUpdate pass.
  local scheduled = {}
  local driver

  local function onUpdate(self, elapsed)
    local initialCount = #scheduled
    local processed = 0
    local i = 1
    while i <= #scheduled and processed < initialCount do
      processed = processed + 1
      local entry = scheduled[i]
      entry.remaining = entry.remaining - elapsed
      if entry.remaining <= 0 then
        local last = #scheduled
        scheduled[i] = scheduled[last]
        scheduled[last] = nil
        pcall(entry.fn)
      else
        i = i + 1
      end
    end
    if #scheduled == 0 then self:Hide() end
  end

  Compat.after = function(sec, fn)
    if type(fn) ~= "function" or not CreateFrame then return end
    if not driver then
      driver = CreateFrame("Frame")
      driver:SetScript("OnUpdate", onUpdate)
      driver:Hide()
    end
    scheduled[#scheduled + 1] = { remaining = tonumber(sec) or 0, fn = fn }
    driver:Show()
  end
end

optimiseCompat()

return Performance
