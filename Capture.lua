local ADDON, ns = ...
ns.Capture = ns.Capture or {}
local Capture = ns.Capture

local CAPTURE_CAP = 3000
Capture.CAPTURE_CAP = CAPTURE_CAP

local function normalise(db)
  if not db then return nil, 1, 0 end
  local list = db.captures
  if type(list) ~= "table" then
    list = {}
    db.captures = list
  end

  local head = tonumber(db.captureHead)
  local size = tonumber(db.captureSize)
  if head and size then
    head = math.floor(head)
    size = math.floor(size)
    if head < 1 or head > CAPTURE_CAP or size < 0 or size > CAPTURE_CAP then
      head, size = nil, nil
    end
  end

  -- Migrate the old dense append-only shape without changing export order.
  if not head or not size then
    size = #list
    if size > CAPTURE_CAP then
      local drop = size - CAPTURE_CAP
      for i = 1, CAPTURE_CAP do list[i] = list[i + drop] end
      for i = size, CAPTURE_CAP + 1, -1 do list[i] = nil end
      size = CAPTURE_CAP
    end
    head = 1
    db.captureHead = head
    db.captureSize = size
  end

  return list, head, size
end

function Capture.isOn(db)
  return db ~= nil and db.captureOn == true
end

function Capture.setOn(db, on)
  if not db then return end
  db.captureOn = on and true or false
end

function Capture.clear(db)
  if not db then return end
  db.captures = {}
  db.captureHead = 1
  db.captureSize = 0
end

function Capture.count(db)
  if not db then return 0 end
  local _, _, size = normalise(db)
  return size
end

-- Fixed-size circular buffer: overwriting the oldest slot is O(1), unlike
-- table.remove(list, 1), which shifted up to 3000 entries per capture.
function Capture.record(db, entry)
  if not Capture.isOn(db) then return end

  local list, head, size = normalise(db)
  entry = entry or {}
  local stored = { c = entry.c, p = entry.p, v = entry.v, t = entry.t, r = entry.r }

  local index
  if size < CAPTURE_CAP then
    index = ((head + size - 1) % CAPTURE_CAP) + 1
    size = size + 1
  else
    index = head
    head = (head % CAPTURE_CAP) + 1
  end

  list[index] = stored
  db.captureHead = head
  db.captureSize = size
end

function Capture.exportText(db)
  if not db then return "" end
  local list, head, size = normalise(db)
  if size == 0 then return "" end

  local lines = {}
  for offset = 0, size - 1 do
    local index = ((head + offset - 1) % CAPTURE_CAP) + 1
    local e = list[index] or {}
    lines[#lines + 1] = table.concat({
      tostring(e.v or ""), tostring(e.c or ""), tostring(e.p or ""),
      tostring(e.t or ""), tostring(e.r or ""),
    }, "\t")
  end
  return table.concat(lines, "\n")
end

return Capture
