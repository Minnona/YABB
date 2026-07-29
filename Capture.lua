local ADDON, ns = ...
ns.Capture = ns.Capture or {}
local Capture = ns.Capture

-- ============================================================
-- Persistent classifier-decision log, written to YABB_DB.captures (a
-- ring buffer, drop-oldest at CAPTURE_CAP) so real misclassifications
-- can be grepped out of a player's SavedVariables and fed back into the
-- classifier corpus for tuning. Quiet by default -- nothing is recorded
-- unless db.captureOn is explicitly true. Every function takes the db
-- table as its first argument rather than touching YABB_DB directly, so
-- this file never needs a WoW global to be exercised.
-- ============================================================

local CAPTURE_CAP = 3000
Capture.CAPTURE_CAP = CAPTURE_CAP

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
end

function Capture.count(db)
  if not db or not db.captures then return 0 end
  return #db.captures
end

-- entry = {c=channel, p=poster, v=verdict, t=tag, r=raw}. No-op unless
-- Capture.isOn(db); ring-caps at CAPTURE_CAP by dropping the oldest
-- (index 1) entries, same drop-oldest convention as Diag.lua's own
-- LOG_CAP ring buffer.
function Capture.record(db, entry)
  if not Capture.isOn(db) then return end
  db.captures = db.captures or {}
  local list = db.captures
  entry = entry or {}
  list[#list + 1] = { c = entry.c, p = entry.p, v = entry.v, t = entry.t, r = entry.r }
  while #list > CAPTURE_CAP do
    table.remove(list, 1)
  end
end

-- One greppable tab-separated line per capture: "<verdict>\t<channel>\t
-- <poster>\t<tag>\t<raw>". db.captures is append order (oldest at index
-- 1), so iterating it in order naturally puts the newest capture last.
function Capture.exportText(db)
  if not db or not db.captures then return "" end
  local list = db.captures
  local lines = {}
  for i = 1, #list do
    local e = list[i]
    lines[#lines + 1] = table.concat({
      tostring(e.v or ""), tostring(e.c or ""), tostring(e.p or ""), tostring(e.t or ""), tostring(e.r or ""),
    }, "\t")
  end
  return table.concat(lines, "\n")
end

return Capture
