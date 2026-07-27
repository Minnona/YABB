-- YABB (Yet Another Bulletin Board)
-- Copyright (C) 2026 srhinos
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 3 as
-- published by the Free Software Foundation. See LICENSE for the full text.

local ADDON, ns = ...
ns.name = ADDON

-- ============================================================
-- Load-scope convention (applies to every file in this addon): a
-- WoW global is only ever referenced inside a function body, guarded
-- by an existence check -- never at file/module scope. That keeps
-- every file loading clean under the plain-Lua test stub
-- (tests/ns_stub.lua), which has no WoW global at all.
-- ============================================================

-- LAST-RESORT FALLBACK ONLY. ns.refreshVersion() below overwrites this
-- with YABB.toc's own `## Version:` line the moment it's safe to call
-- GetAddOnMetadata. A failed read must read as a failure, not a
-- plausible wrong build number -- so this is not a version string.
ns.VERSION = "unknown"
ns.modules = ns.modules or {}

-- ============================================================
-- refreshVersion() -- makes YABB.toc's `## Version:` line the single
-- source of truth for ns.VERSION, read via GetAddOnMetadata(ADDON,
-- "Version"). This is a plain global on 3.3.5, not retail's
-- C_AddOns.GetAddOnMetadata.
--
-- The call is deferred to a function, never invoked at module load
-- scope, so GetAddOnMetadata not existing under the test stub is
-- harmless. The only caller is Init.lua's PLAYER_LOGIN handler, so on
-- a live client this never runs before PLAYER_LOGIN has fired.
-- pcall-wrapped since this is a live WoW C call; any failure (missing
-- global, raised error, empty/non-string return) leaves ns.VERSION
-- exactly as it already was, so a bad read can never blank out or
-- corrupt the version string.
-- ============================================================
function ns.refreshVersion()
  if GetAddOnMetadata then
    local ok, v = pcall(GetAddOnMetadata, ADDON, "Version")
    if ok and type(v) == "string" and v ~= "" then
      ns.VERSION = v
    end
  end
  return ns.VERSION
end
