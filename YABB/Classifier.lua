local ADDON, ns = ...
ns.Classifier = ns.Classifier or {}
local Classifier = ns.Classifier

-- ============================================================
-- Small, overridable token tables. Everything else (dungeons,
-- classes, aliases, mode tokens, role words/hints) comes from ns.C.
-- ============================================================

-- Weighted spam/gold-seller vocabulary. Score >= threshold rejects.
-- Fallback default only -- Content.aliases.lua's ns.C.spamWeights (same
-- values) is what a fully-loaded addon actually classifies against, so
-- the rules editor's "Reject / spam" chip editor can add/remove entries;
-- isRejected below reads C.spamWeights first and falls back to this
-- table only when the caller's C omits it.
local SPAM_WEIGHTS = {
  wts = 1, wtb = 1, wtt = 1, sell = 1, selling = 1, buying = 1, boost = 1,
  recruiting = 1, recruit = 1, guild = 0.6, dp = 0.7, gold = 0.5,
  ["2v2"] = 1, ["3v3"] = 1, ["5v5"] = 1,
}

-- Words that are never useful as dungeon/boss "significant words" because
-- they are common English glue words that also happen to appear inside
-- generated dungeon names (e.g. "Road to De Other Side", "The Escape From
-- Durnholde"). "to" is included because it collides with ordinary chatter
-- ("...just have to believe!").
local STOPWORDS = {
  the = true, of = true, de = true, a = true, an = true, ["and"] = true,
  to = true, ["for"] = true, from = true, ["in"] = true, on = true,
  at = true, is = true, with = true, lower = true, upper = true,
}

-- word -> modifier key
local MODIFIER_WORDS = {
  aura = "aura", xp = "aura", pst = "pst", pumper = "pumper",
}

-- tierOf precedence when multiple mode tokens are present on one line.
local TIER_PRIORITY = { "adventure", "mythicplus", "mythic", "heroic", "leveling", "manastorm" }

-- Sane upper bound for a "need N <role>" count (bigger numbers are almost
-- always the poster's own character level, not a headcount request).
local MAX_NEED_COUNT = 9

-- extractIntent's positional fallback vocabulary. Content.aliases.lua's
-- ns.C.personWords/ns.C.contentWords (same values) are what a
-- fully-loaded addon actually scans -- these are the literal defaults
-- for any bare-C caller (tests, isRejected's own unit tests) that omits
-- them. PERSON deliberately excludes roleWords/classWords vocabulary --
-- extractIntent unions those in separately at match time.
local PERSON_EXTRA_WORDS = {
  guy = true, guys = true, player = true, players = true, ppl = true,
  people = true, pumper = true, pumpers = true, dude = true, man = true,
  mate = true, mates = true, buddy = true, member = true, members = true,
  someone = true, haver = true, role = true, roles = true, healz = true,
  dd = true,
}
local CONTENT_EXTRA_WORDS = {
  rdf = true, rfd = true, rdfs = true, dungeon = true, dungeons = true,
  dung = true, dungs = true, dungy = true, dng = true, dngn = true,
  dg = true, dgs = true, dj = true, spam = true, raid = true, raids = true,
  group = true, groups = true, grp = true, pug = true, run = true, runs = true,
  wb = true, worldboss = true, boss = true, bosses = true, instance = true,
  instanced = true, quest = true, party = true, team = true,
}

-- Known abbreviation collisions that need extra context (poster level) to
-- disambiguate. Data-driven so more can be added without touching logic.
local COLLISION_OVERRIDES = {
  dm = function(C, posterLevel)
    if posterLevel and posterLevel >= 40 then
      return C.aliases and (C.aliases.diremaul or C.aliases["dire maul"]) or nil
    end
    return C.aliases and C.aliases.dm or nil
  end,
}

-- ============================================================
-- normalize
-- ============================================================

-- ============================================================
-- stripWowEscapes(s, keepAllLinkText) -- pipe-escape removal shared by
-- normalize (which lowercases afterward, for token matching) and
-- plainText (case-preserving, for display). Order matters: |c color
-- codes must be stripped BEFORE lowercasing wherever the caller does
-- that, since |H hyperlinks use a capital H and are case-sensitive --
-- lowering first would turn "|H" into "|h" and the real links would
-- never match, leaking their payload into tokens instead of being
-- stripped.
--
-- The link-visible-text rule below is tokenizer policy, not a display
-- rule: only a quest link's target name is trustworthy enough to feed
-- resolveTarget, so tokenization keeps a |Hquest: link's [text] and
-- drops every other link type's. A listing's message line/tooltip
-- should still show whatever the poster actually typed, including
-- "[Thunderfury]"/"[Guild Charter]" item-link text -- keepAllLinkText
-- (true for plainText, unset/false for normalize) selects which policy
-- applies.
-- ============================================================
local function stripWowEscapes(s, keepAllLinkText)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")     -- |cAARRGGBB color start
  s = s:gsub("|T.-|t", "")                  -- |Ttexture:size|t icon escape
  -- Link-type-aware strip. A |Hquest:... link names its target
  -- unambiguously -- keep its visible [text] so resolveTarget can still
  -- match a quest-link listing ("LFM |Hquest:...|h[Vaults of
  -- Inquisition]|h" must not lose its target). Every other link type
  -- (item/enchant/recipe/trade/spell/...) can carry a preview name
  -- unrelated to the actual target being advertised (an enchant preview
  -- link named "...Crusader" is the classic trap), so its visible text
  -- is dropped for tokenization. For display (keepAllLinkText), all link
  -- text is kept -- a player reads the row/tooltip to see what was
  -- actually said.
  s = s:gsub("|H(%a+):.-|h(.-)|h", function(kind, text)
    return (keepAllLinkText or kind:lower() == "quest") and text or ""
  end)
  s = s:gsub("|H[^|]*|?h?", "")             -- malformed/unclosed leftovers
  s = s:gsub("|r", "")                      -- color reset
  s = s:gsub("|h", "")                      -- stray closing tags
  s = s:gsub("||", "|")                     -- collapse escaped-pipe residuals
  return s
end

function Classifier.normalize(line)
  line = line or ""
  local s = stripWowEscapes(line)
  s = s:lower()

  local tokens = {}
  for w in s:gmatch("[%w+]+") do
    tokens[#tokens + 1] = w
  end
  return tokens, s
end

-- plainText(line) -- case-preserving copy of the same escape-strip
-- normalize does, for DISPLAY (the row's raw-message line) rather than
-- tokenization -- so a truncated/measured row never cuts a WoW escape
-- sequence mid-token (an unterminated |c/|H both renders literally and
-- corrupts GetStringWidth's measurement) and never shows an
-- all-lowercased raw chat line. Passes keepAllLinkText=true, so unlike
-- normalize's tokenizer-only policy, every link type's visible text
-- survives here, not just quest links -- normalize and plainText
-- deliberately diverge on non-quest links; they still agree on
-- everything else via the same shared strip.
function Classifier.plainText(line)
  return stripWowEscapes(line or "", true)
end

-- ============================================================
-- Quest category detection: two independent forms, both public so
-- categoryOf/classify (below) and tests can call them directly.
--
-- FORM A -- quest hyperlink, unambiguous, highest precedence: a real
-- |Hquest:... link names its target unambiguously even when its visible
-- [text] happens to collide with a real generated dungeon name (Content.
-- generated.lua's own "Road to De Other Side"/"Vaults of Inquisition"
-- rows). Plain-text find (no pattern), case-sensitive on purpose -- WoW
-- always emits a capital H, and Classifier.normalize lowercases its own
-- copy, so this always reads the RAW line, never normStr. Guards
-- rawLine==nil (categoryOf's own callers, and some existing tests, call
-- it without one).
--
-- FORM B -- standalone "quest"/"quests" keyword: word-boundaried via the
-- %f[%w]/%f[%W] frontier pattern (a word-char neighbor kills the
-- frontier), so it can never match inside "conquest"/"question"/
-- "questionable"/"questline"/"request"/"quester" or the typos "qquest"/
-- "questt" (those fall to Other -- an acceptable miss, not a false
-- positive; do not loosen the boundary to catch them). QUEST_XP_ITEMS are
-- Ascension XP-consumable slang, not a quest run -- stripped from a
-- working copy first so "got XP aura and quest ball/orb/head" never trips
-- this.
-- ============================================================

local QUEST_XP_ITEMS = { "quest ball", "quest orb", "quest head" }

function Classifier.hasQuestLink(rawLine)
  return rawLine ~= nil and rawLine:find("|Hquest:", 1, true) ~= nil
end

function Classifier.hasQuestKeyword(normStr)
  if not normStr then return false end
  local s = normStr
  for _, ex in ipairs(QUEST_XP_ITEMS) do s = s:gsub(ex, "") end
  return s:find("%f[%w]quests?%f[%W]") ~= nil
end

-- ============================================================
-- small local predicates shared by isRejected/extraction
-- ============================================================

local function isIntentWordToken(t)
  -- lf%d+ (bare, e.g. "lf1"/"lf2") is the fused LFM count-request form
  -- ("LF1 DPS 55+ RDF") -- recognized here too so isRejected's strong-LFG
  -- gate (spam threshold, question-lead exception) treats it the same as
  -- lf/lfm/lf%d+m instead of falling through to the weaker role/mode
  -- signal path.
  return t == "lf" or t == "lfm" or t == "lfg" or t:match("^lf%d+m$") ~= nil
    or t:match("^lf%d+$") ~= nil
end

local function hasIntentWord(tokens)
  for _, t in ipairs(tokens) do
    if isIntentWordToken(t) then return true end
  end
  return false
end

local function hasLevelSignal(tokens)
  for _, t in ipairs(tokens) do
    if t:match("^%d+%+$") or t:match("^lvl%d*$") then return true end
  end
  return false
end

local function hasModeToken(tokens, C)
  if not C.modeTokens then return false end
  for _, t in ipairs(tokens) do
    if C.modeTokens[t] then return true end
  end
  return false
end

local function hasRoleWord(tokens, C)
  if not C.roleWords then return false end
  for _, t in ipairs(tokens) do
    if C.roleWords[t] then return true end
  end
  return false
end

-- Words/phrases that mark a line as "about forming/joining a group" even
-- without a formal lf/lfm/lfg intent token (e.g. "anyone up for azuregos
-- world boss"). Single tokens plus one multi-word phrase.
local GROUP_WORDS = {
  group = true, grp = true, run = true, runs = true, pug = true,
  wb = true, raid = true,
}
local GROUP_PHRASES = { "world boss" }

local function hasGroupWord(tokens, normStr)
  for _, t in ipairs(tokens) do
    if GROUP_WORDS[t] then return true end
  end
  if normStr then
    for _, phrase in ipairs(GROUP_PHRASES) do
      if normStr:find(phrase, 1, true) then return true end
    end
  end
  return false
end

-- "N more" quantity shorthand (e.g. "2 more for scholo") is terse real LFG
-- but carries none of the other weak signals (no intent word, role word,
-- mode token, level filter, or group word), so it needs its own check.
local function hasQuantitySignal(normStr)
  if not normStr then return false end
  return normStr:find("%d+%s+more") ~= nil
end

-- Guild-recruitment posts often carry LFG-shaped tokens (roles, M0/M+
-- tier tokens) that would otherwise classify as a real listing. A rule
-- built on generic recruit-context words ("looking to", "whisper for",
-- "members", "social") over-rejects, because legit tagged LFMs use the
-- same vocabulary ("<Guild Run> LFM...", "enchanter welcome"). This list
-- is curated to STRONG, unambiguous recruitment phrases only -- no tag
-- requirement, no generic words -- deliberately excluding bare "guild",
-- "members", "social", "looking to", "whisper for", "join us"/"join our",
-- and "welcome". "recruit"/"recruiting" are also in SPAM_WEIGHTS; kept
-- here too since they're unambiguous on their own.
local RECRUIT_PHRASES = {
  "recruit", "recruiting", "community", "raid team", "looking to build",
  "active guild", "casual guild", "new guild", "join our guild",
  "join the guild", "discord", "whisper for info", "pst for info",
  "dm for info", "for info or an invite", "accepting all",
}

local function hasRecruitContext(lowerLine)
  for _, phrase in ipairs(RECRUIT_PHRASES) do
    if lowerLine:find(phrase, 1, true) then return true end
  end
  return false
end

-- ============================================================
-- Generalized guild-ad reject. hasRecruitContext above catches a curated
-- list of STRONG, unambiguous phrases but dodges easily -- a guild ad
-- that hits none of those exact phrases (a member-count brag, a foreign
-- recruit verb, open-welcome phrasing, an activity laundry-list, or a
-- <GuildTag> paired with a join/welcome/member-solicit phrase) can still
-- read as a real listing (e.g. "Helldivers Of Alliance...300+
-- Member...Guild LF Members Pvp/Pve...Mythic...Rdf...World Boss
-- Tours...Everyone is Welcome" would otherwise classify as Mythic+). This
-- generalizes by COMBINING weak signals -- see each hasX helper's own
-- comment for why none of guild/members/welcome/join may ever reject
-- alone (each one also appears in genuine tagged LFMs: "<Guild Run> LFM
-- ...", "need 2 more members to fill raid", "enchanter welcome", "whisper
-- for invite").
--
-- Config-over-code: the phrase lists below are ns.C-overridable (same
-- rules-editor seam as SPAM_WEIGHTS/personWords/contentWords -- each
-- literal table here is the fallback default for any bare-C caller). The
-- AND/OR/count COMBINATION logic in Classifier.isGuildAd itself is
-- deliberately NOT config-surfaced -- it is structural, and loosening it
-- (e.g. letting guild-context alone reject) reopens the over-rejection a
-- flat strong-phrase-only list causes.
-- ============================================================

local GUILD_RECRUIT_VERBS = {
  "recruit", "recruiting", "recrute", "recruta", "reclut",
  "now hiring", "is hiring", "hiring", "psaxnei", "psaxnoume",
}

local GUILD_OPEN_WELCOME = {
  "everyone welcome", "everyone is welcome", "all welcome", "all are welcome",
  "all levels welcome", "anyone is welcome", "anyone welcome",
}

local GUILD_JOIN_PHRASES = {
  "join us", "join our", "join the guild", "join my guild", "whisper to join",
}

local GUILD_EUPHEMISMS = {
  "bolstering ranks", "welcomes new", "new souls", "growing our", "building our roster",
}

local GUILD_MEMBER_SOLICIT = {
  "lf members", "looking for members", "recruiting members",
}

-- domain-name -> list of Lua patterns (any pattern in the list counts as
-- that ONE domain -- see activityDomains, which counts distinct domains,
-- not occurrences). "arena"/"pex" are deliberately bare substrings (no
-- %f frontier) matching the grounding spec verbatim.
local GUILD_ACTIVITY_DOMAINS = {
  { "pvp", { "%f[%w]pvp" } },
  { "pve", { "%f[%w]pve" } },
  { "pvx", { "%f[%w]pvx" } },
  { "raid", { "%f[%w]raid" } },
  { "mythic", { "%f[%w]m%+", "%f[%w]mythic", "%f[%w]mm%+", "%f[%w]m0%f[%W]" } },
  { "rdf", { "%f[%w]rdf" } },
  { "dungeon", { "%f[%w]d[ou]n[gj]" } },
  { "bg", { "%f[%w]bgs?%f[%W]" } },
  { "arena", { "aren" } },
  { "worldboss", { "world boss", "%f[%w]wb%f[%W]" } },
  { "hardcore", { "%f[%w]hc%f[%W]" } },
  { "leveling", { "%f[%w]lvl", "leveling", "lvling", "pex" } },
}

local function findAnyPlain(lower, phrases)
  for _, p in ipairs(phrases) do
    if lower:find(p, 1, true) then return true end
  end
  return false
end

local function findAnyPattern(lower, patterns)
  for _, pat in ipairs(patterns) do
    if lower:find(pat) then return true end
  end
  return false
end

-- Deliberately loose: also matches the bare word inside a "<Guild Run>"
-- LFM tag and a player's own "LF guild" post -- safe ONLY because
-- guild-context alone never rejects below; it's always ANDed with a
-- partner signal.
function Classifier.hasGuildContext(lower)
  return lower:find("%f[%w]guilds?%f[%W]") ~= nil or lower:find("%f[%w]guildes?%f[%W]") ~= nil
end

function Classifier.hasRecruitVerb(lower, C)
  return findAnyPlain(lower, (C and C.guildRecruitVerbs) or GUILD_RECRUIT_VERBS)
end

-- A member-COUNT brag: a number carrying a trailing "+", adjacent to
-- member(s) in either order ("300+ member" / "(300+ members)"). The
-- "+"-adjacent form is deliberately the ONLY form checked: a bare number
-- >=20 with no "+" is a normal raid size ("forming ICC need 20 members",
-- "LFM 25 members icc"), not a guild headcount brag -- do not resurrect a
-- bare-number threshold, it rejects real raid-formation LFMs.
function Classifier.hasMemberCountBrag(lower)
  for _, plus in lower:gmatch("(%d+)(%+?)%s*members?%f[%W]") do
    if plus == "+" then return true end
  end
  for _, plus in lower:gmatch("members?%s*%(?(%d+)(%+?)") do
    if plus == "+" then return true end
  end
  return false
end

-- Generic members-as-object, no role/count ("lf members"/"looking for
-- members"/"recruiting members"). Deliberately does NOT include bare "for
-- members" -- tested and dropped as too broad; the count-brag check above
-- already covers the number-bearing case.
function Classifier.hasMemberSolicit(lower, C)
  return findAnyPlain(lower, (C and C.guildMemberSolicit) or GUILD_MEMBER_SOLICIT)
end

-- Only the full open-invite phrases count -- bare "welcome" ("enchanter
-- welcome", "guildies welcome") is common in genuine LFMs and must never
-- trigger this on its own.
function Classifier.hasOpenWelcome(lower, C)
  return findAnyPlain(lower, (C and C.guildOpenWelcome) or GUILD_OPEN_WELCOME)
end

-- Deliberately excludes every bare contact verb ("whisper for invite",
-- "/w me for invite", "pm me") -- those appear in both guild ads and
-- legit LFMs alike and carry no signal either way.
function Classifier.hasGuildJoin(lower, C)
  return findAnyPlain(lower, (C and C.guildJoinPhrases) or GUILD_JOIN_PHRASES)
end

function Classifier.hasRecruitEuphemism(lower, C)
  return findAnyPlain(lower, (C and C.guildEuphemisms) or GUILD_EUPHEMISMS)
end

-- Count of DISTINCT activity domains present (one point per domain, no
-- matter how many times/boss-name variants it repeats -- "WB (Snowgrave/
-- Kaldros/kazzak)" is 1 domain, not 3).
function Classifier.activityDomains(lower, C)
  local domains = (C and C.guildActivityDomains) or GUILD_ACTIVITY_DOMAINS
  local count = 0
  for _, d in ipairs(domains) do
    if findAnyPattern(lower, d[2]) then count = count + 1 end
  end
  return count
end

-- The combinator. Fires BEFORE target/tier/spam resolution (same
-- precedence as hasRecruitContext -- see isRejected below), so a guild ad
-- can never be handed a false category (Mythic+/World Boss/Raid) from an
-- incidental M+/raid/wb token. First-match-wins; see the DECISION order
-- comment inline. Single weak signals never reject alone -- every branch
-- either is unambiguous on its own (member-count brag, recruit-verb+
-- guild-context, recruit-verb+2-domains) or requires guild-context (or a
-- <Tag>) ANDed with a partner signal.
function Classifier.isGuildAd(rawLine, C)
  if not rawLine then return false end
  local lower = rawLine:lower()
  C = C or {}

  -- 1: strong-alone signals, no guild word needed.
  if Classifier.hasMemberCountBrag(lower) then return true end
  local recruitVerb = Classifier.hasRecruitVerb(lower, C)
  local guildContext = Classifier.hasGuildContext(lower)
  if recruitVerb and guildContext then return true end
  local domains = Classifier.activityDomains(lower, C)
  if recruitVerb and domains >= 2 then return true end

  -- 2: compound -- requires guild context AND one partner signal.
  if guildContext then
    if Classifier.hasMemberSolicit(lower, C) then return true end
    if Classifier.hasOpenWelcome(lower, C) then return true end
    if Classifier.hasGuildJoin(lower, C) then return true end
    if Classifier.hasRecruitEuphemism(lower, C) then return true end
    if domains >= 3 then return true end
  end

  -- 3: tag fallback -- a <GuildTag> plus a join/member-solicit signal,
  -- catching a guild ad with no bare "guild" word anywhere on the line
  -- ("<The Crypt> ... Whisper to Join us"). <Tag>+open-welcome ALONE is
  -- deliberately not enough: a guild-tagged PUG run ("<Reckoning> LFM 2
  -- dps ZF all are welcome", "<Bloodbath> LFM UBRS all welcome") is
  -- exactly that shape and is a legit LFM, not a guild ad -- open-welcome
  -- only counts here when it ALSO carries a recruit verb ("<Tag> ...
  -- hiring ... everyone welcome"), the ambiguity-breaker those examples
  -- lack.
  if rawLine:find("<%a") then
    if Classifier.hasGuildJoin(lower, C) or Classifier.hasMemberSolicit(lower, C) then
      return true
    end
    if Classifier.hasOpenWelcome(lower, C) and Classifier.hasRecruitVerb(lower, C) then
      return true
    end
  end

  return false
end

-- A line that STARTS WITH an interrogative/conversational lead ("what lvl
-- is pale reach?", "has anyone else experienced a bug...") reads as a
-- question or chatter, not a listing, even when it happens to contain
-- LFG-shaped vocabulary further in. Matched token-by-token from the start
-- of the line (not a raw substring find) so a lead only fires on the
-- actual leading word(s) -- "anyone up for..."/"anyone wanna..." do NOT
-- start with the "anyone else" lead and must keep accepting.
local QUESTION_LEADS = {
  { "what" }, { "whats" }, { "why" }, { "how" }, { "where" }, { "when" }, { "which" },
  { "is", "there" }, { "are", "there" }, { "does" }, { "do", "you" }, { "did", "anyone" },
  { "has", "anyone" }, { "anyone", "else" }, { "if", "you" }, { "quick", "question" },
}

local function startsWithQuestionLead(tokens)
  for _, lead in ipairs(QUESTION_LEADS) do
    local matched = true
    for i, w in ipairs(lead) do
      if tokens[i] ~= w then matched = false; break end
    end
    if matched then return true end
  end
  return false
end

-- Strong LFG intent: an explicit intent word, or "need" paired with a
-- role word ("need 2 tanks"). A question lead only rejects when the line
-- ALSO lacks this -- real LFG that starts with a lead-shaped word but is
-- clearly forming a group still accepts.
local function hasStrongLFGIntent(tokens, C)
  if hasIntentWord(tokens) then return true end
  local hasNeed = false
  for _, t in ipairs(tokens) do
    if t == "need" then hasNeed = true; break end
  end
  return hasNeed and hasRoleWord(tokens, C)
end

-- Service/profession posts (crafting/enchanting services, not a dungeon
-- group) reject outright. Requires a trade-intent token (lf/wtb/wts/wtt)
-- co-occurring with profession vocabulary, OR the raw (pre-strip) line
-- carries an enchant/recipe hyperlink on its own -- that alone is
-- unambiguous service-shop chatter.
local SERVICE_WORDS = {
  chanter = true, enchanter = true, enchant = true, craft = true, crafter = true,
  blacksmith = true, smithing = true, leatherwork = true, leatherworker = true,
  tailor = true, tailoring = true, jewelcraft = true, jewelcrafter = true,
  alchemist = true, alchemy = true, scribe = true, inscription = true,
  glyph = true, transmute = true,
}

local function isTradeToken(t)
  return t == "lf" or t == "wtb" or t == "wts" or t == "wtt"
end

-- Co-occurrence anywhere in the line over-fires on genuine LFG posts that
-- merely mention a profession word ("LF tank for heroic BRD, enchanter
-- welcome"), since "lf" is both the LFG intent token and a trade token.
-- The profession word must sit within 3 tokens after the trade token
-- ("LF blacksmith 300", "LF a good enchanter", "LF someone to enchant my
-- weapon") -- narrow enough to keep real service rejects, wide enough to
-- allow one filler word between the trade token and the profession word.
-- 4 tokens would over-fire on "LF group for mystic enchant farm heroic
-- scholo" ("lf" sits 4 tokens back from "enchant"), so 3 is the max safe
-- value.
local function hasServiceWord(tokens)
  for i, t in ipairs(tokens) do
    if SERVICE_WORDS[t] then
      local p1, p2, p3 = tokens[i - 1], tokens[i - 2], tokens[i - 3]
      if (p1 and isTradeToken(p1)) or (p2 and isTradeToken(p2)) or (p3 and isTradeToken(p3)) then
        return true
      end
    end
    if t == "wtb" and tokens[i + 1] == "ench" then return true end
  end
  return false
end

local function hasServiceLink(rawLine)
  if not rawLine then return false end
  for linkType in rawLine:gmatch("|H(%a+):") do
    local lt = linkType:lower()
    if lt == "enchant" or lt == "recipe" then return true end
  end
  return false
end

-- ============================================================
-- resolveTarget
-- ============================================================

local function stripWingSuffix(name)
  return (name:gsub("%s*%(PvE%)", ""):gsub("%s*%(PvP%)", ""))
end

local function buildTargetLookup(C)
  if C._targetLookup then return C._targetLookup end
  local lookup = {} -- word (lower) -> { exactName, ... }

  local function add(word, name)
    word = word:lower()
    if word == "" then return end
    local list = lookup[word]
    if not list then
      list = {}
      lookup[word] = list
    end
    for _, n in ipairs(list) do
      if n == name then return end
    end
    list[#list + 1] = name
  end

  if C.aliases then
    for aliasKey, exactName in pairs(C.aliases) do
      add(aliasKey, exactName)
    end
  end

  if C.dungeons then
    -- Name-derived "significant word" harvesting. Two guards keep this from
    -- indexing ordinary English:
    --   1. length >= 5 (drops keep/west/east/old/will/hold/core/map/hall/
    --      gate/past/lord/rise and similar short glue words outright).
    --   2. cross-instance ambiguity: for a given word, group the dungeon
    --      rows whose (stripped) name contains it into "instances" -- two
    --      rows are the SAME instance if they share either an exact name
    --      (world-boss realm/phase-variant rows reuse one name across
    --      several mapIds, e.g. Azuregos/Naxxramas) OR a mapId (wing/tier
    --      rows of one zone share a mapId under different names, e.g.
    --      Lower/Upper Scholomance share Scholomance's mapId). Counting by
    --      mapId alone would wrongly flag same-name world-boss rows as
    --      ambiguous; counting by name alone would wrongly flag
    --      same-mapId wing rows as ambiguous -- only the combined grouping
    --      gets both right. If a word's rows collapse to a SINGLE instance
    --      under this combined grouping, it's a reliable identifier and
    --      gets indexed (all of its distinct name spellings, tie-broken
    --      later to the shortest). If they span 2+ genuinely different
    --      instances (blackrock -> Depths/Spire/Caverns; temple -> Sunken
    --      Temple/Ahn'Qiraj Temple; stratholme -> Stratholme wings vs "The
    --      Culling of Stratholme") it's dropped.
    -- The STOPWORDS list stays as a belt-and-suspenders extra, not the
    -- primary guard.
    -- Class names (e.g. "Tinker") normalize to short, plain-English-looking
    -- words that can collide with a dungeon's generated name (Gnomeregan -
    -- Tinker's Court). Skip them here so a class word never resolves a
    -- dungeon target; C.aliases (explicit, curated) are unaffected.
    local classWords = {}
    if C.classes then
      for _, cl in ipairs(C.classes) do
        if cl.name then
          classWords[cl.name:lower():gsub("%s+", "")] = true
        end
      end
    end
    -- Curated archetype/spec words (Ascension-flavored names like
    -- "crusader"/"templar") that aren't in the ns.C.classes dataset rows.
    if C.classWords then
      for w in pairs(C.classWords) do
        classWords[w] = true
      end
    end

    local wordRows = {} -- word -> { {name=,mapId=}, ... }, deduped by name+mapId
    local wordRowSeen = {} -- word -> set of "name\0mapId"
    local function markWord(word, name, mapId)
      local seen = wordRowSeen[word]
      if not seen then
        seen = {}
        wordRowSeen[word] = seen
      end
      local key = name .. "\0" .. tostring(mapId)
      if seen[key] then return end
      seen[key] = true
      local rows = wordRows[word]
      if not rows then
        rows = {}
        wordRows[word] = rows
      end
      rows[#rows + 1] = { name = name, mapId = mapId }
    end

    for _, d in ipairs(C.dungeons) do
      local bare = stripWingSuffix(d.name)
      for w in bare:lower():gmatch("[%w+]+") do
        if not STOPWORDS[w] and not classWords[w] and #w >= 5 then
          markWord(w, d.name, d.mapId)
        end
      end
    end

    -- Union each word's rows by shared name or shared mapId, then count the
    -- resulting distinct instances.
    for word, rows in pairs(wordRows) do
      local groupOfName, groupOfMapId, nextGroup = {}, {}, 1
      for _, row in ipairs(rows) do
        local ng, mg = groupOfName[row.name], groupOfMapId[row.mapId]
        local g
        if ng and mg then
          g = ng
          if ng ~= mg then
            -- merge: relabel every reference to the old group onto the new one
            for k, v in pairs(groupOfName) do if v == mg then groupOfName[k] = ng end end
            for k, v in pairs(groupOfMapId) do if v == mg then groupOfMapId[k] = ng end end
          end
        elseif ng then
          g = ng
        elseif mg then
          g = mg
        else
          g = nextGroup
          nextGroup = nextGroup + 1
        end
        groupOfName[row.name] = g
        groupOfMapId[row.mapId] = g
      end

      -- Final pass reads the now-fully-merged group ids, so it's immune to
      -- rows that were assigned a group id before a later row merged it.
      local seenGroups, groupCount = {}, 0
      local distinctNames, nameSeen = {}, {}
      for _, row in ipairs(rows) do
        local g = groupOfName[row.name]
        if not seenGroups[g] then seenGroups[g] = true; groupCount = groupCount + 1 end
        if not nameSeen[row.name] then
          nameSeen[row.name] = true
          distinctNames[#distinctNames + 1] = row.name
        end
      end

      if groupCount < 2 then
        for _, name in ipairs(distinctNames) do
          add(word, name)
        end
      end
    end
  end

  C._targetLookup = lookup
  return lookup
end

-- A content-name match only counts toward the "is this an LFG line at all"
-- signal when it's "substantial": length > 3. This filters out <=3-char
-- alias collisions (vc/st/wc/dm) with everyday words -- those may still
-- RESOLVE a target (via resolveTarget/COLLISION_OVERRIDES) once some other
-- signal already justifies accepting the line, but they can't singlehandedly
-- manufacture one. Word-derived lookup entries are already length>=5 (see
-- buildTargetLookup), so this only ever excludes short alias keys.
local function hasSubstantialContentMatch(tokens, normStr, C)
  if not C or not C.dungeons then return false end
  local lookup = buildTargetLookup(C)
  for _, t in ipairs(tokens) do
    if #t > 3 and lookup[t] then return true end
  end
  if C.aliases and normStr then
    for aliasKey in pairs(C.aliases) do
      if #aliasKey > 3 and aliasKey:find(" ", 1, true) and normStr:find(aliasKey, 1, true) then
        return true
      end
    end
  end
  return false
end

function Classifier.resolveTarget(tokens, normStr, C, posterLevel)
  if not C or not C.aliases or not C.dungeons then return nil end

  -- known collisions (e.g. "dm") need poster-level context first
  for _, t in ipairs(tokens) do
    local override = COLLISION_OVERRIDES[t]
    if override then
      local r = override(C, posterLevel)
      if r then return r end
    end
  end

  local lookup = buildTargetLookup(C)
  local candidates, seen = {}, {}
  local function addCandidate(name)
    if name and not seen[name] then
      seen[name] = true
      candidates[#candidates + 1] = name
    end
  end

  for _, t in ipairs(tokens) do
    local list = lookup[t]
    if list then
      for _, n in ipairs(list) do addCandidate(n) end
    end
  end

  -- multi-word alias keys (e.g. "sm lib") only show up as substrings
  if normStr then
    for aliasKey, exactName in pairs(C.aliases) do
      if aliasKey:find(" ", 1, true) and normStr:find(aliasKey, 1, true) then
        addCandidate(exactName)
      end
    end
  end

  if #candidates == 0 then return nil end
  -- prefer the shortest (least-qualified) generated name
  table.sort(candidates, function(a, b) return #a < #b end)
  return candidates[1]
end

-- ============================================================
-- tierOf
-- ============================================================

local function tierOf(tokens, C)
  if not C.modeTokens then return nil end
  local found = {}
  for _, t in ipairs(tokens) do
    local tier = C.modeTokens[t]
    if tier then found[tier] = true end
  end
  for _, tier in ipairs(TIER_PRIORITY) do
    if found[tier] then return tier end
  end
  return nil
end
Classifier.tierOf = tierOf

-- ============================================================
-- categoryOf
-- ============================================================

local function buildNameIndex(C)
  if C._dungeonByName then return C._dungeonByName end
  local idx = {}
  if C.dungeons then
    for _, d in ipairs(C.dungeons) do
      if not idx[d.name] then idx[d.name] = d end
    end
  end
  C._dungeonByName = idx
  return idx
end

-- Public name -> ns.C.dungeons[] row accessor, reusing the same memoized
-- _dungeonByName index categoryOf builds.
function Classifier.rowForName(name, C)
  if not name or not C then return nil end
  return buildNameIndex(C)[name]
end

-- ============================================================
-- Pipeline: every matcher is UNIFORM -- {name, patterns={...}, outcome}.
-- A matcher FIRES if ANY of its patterns matches (patternFires/
-- matcherFires below). Four pattern kinds:
--   {kind="keyword", value=<string>} -- dual rule (see patternMatchesKeyword):
--     a single-token value (no space/separator -- v:match("^[%w+]+$")) is
--     WHOLE-TOKEN membership against ctx.tokens (incl. "h"/"m0"/"m+" as
--     ONE token); any other value (contains a space or punctuation, e.g.
--     "world boss") is a PLAIN SUBSTRING of ctx.normStr. NEVER a generic
--     substring for a single word -- that would catastrophically
--     over-match ("h" inside "the"/every line).
--   {kind="regex", value=<lua pattern>} -- pcall-guarded string.find
--     against ctx.normStr; a malformed pattern silently never matches.
--   {kind="catalog", value="worldboss"|"raid"|"dungeon"} -- delegates to
--     the existing resolveTarget+row.kind logic (ctx.row, set by
--     categoryOfDebug from the caller-resolved `target`) -- NOT
--     inline-editable, matches the datamined name catalog only. The
--     catalog values are deliberately the same strings as
--     Content.generated.lua's row.kind, so matching is a plain equality.
--   {kind="special", id="questlink"|"questword"|"catchall"} -- structural/
--     custom-logic patterns delegating to existing predicates:
--       questlink -- a real |Hquest:...|h hyperlink (Classifier.hasQuestLink)
--       questword -- the LFG-gated "quest"/"quests" keyword, with the
--         conquest/question/questionable/request frontier exclusions
--         (hasStrongLFGIntent + Classifier.hasQuestKeyword)
--       catchall  -- always true (the terminal "Everything else" matcher)
-- outcome is always one of:
--   {kind="category", name=<category name>} -- assign + stop (if the
--     category still exists in ns.C.categories; otherwise fall through)
--   {kind="nothing"}                        -- fall through & relabel
--   {kind="hide"}                           -- reject (Classifier.HIDE)
-- Every matcher's outcome.name is authoritative -- there is no dynamic
-- "resolved category" fallback. A saved legacy-shape pipeline is migrated
-- to this shape once, in Filters.applyOverlay -- categoryOf/
-- categoryOfDebug below only ever walk this {name,patterns,outcome} shape.
--
-- ctx.tier and ctx.target survive as context fields for future pattern
-- kinds; no shipped matcher kind currently reads either.
-- ============================================================

-- Keyword dual-rule -- see the pipeline header comment above for the
-- single-token vs multi-word split this reproduces (tierOf's whole-token
-- membership test for single words, plain substring for phrases).
local function patternMatchesKeyword(value, ctx)
  if type(value) ~= "string" or value == "" then return false end
  local v = value:lower()
  if v:match("^[%w+]+$") then
    if not ctx.tokens then return false end
    for _, t in ipairs(ctx.tokens) do
      if t == v then return true end
    end
    return false
  end
  return ctx.normStr ~= nil and ctx.normStr:find(v, 1, true) ~= nil
end

-- {kind="regex"} -- pcall-guarded string.find against ctx.normStr.
local function patternMatchesRegex(value, ctx)
  if type(value) ~= "string" or value == "" or not ctx.normStr then return false end
  local ok, matched = pcall(string.find, ctx.normStr, value)
  return ok and matched ~= nil
end

-- {kind="catalog"} -- ctx.row is the Content.generated.lua row for the
-- already-resolved `target` (set by categoryOfDebug); value is one of
-- row.kind's own literal strings ("worldboss"/"raid"/"dungeon").
local function patternMatchesCatalog(value, ctx)
  return ctx.row ~= nil and ctx.row.kind == value
end

-- {kind="special"} -- structural predicates that cannot be expressed as a
-- plain keyword/regex (see the header comment above for why).
local function patternMatchesSpecial(id, ctx)
  if id == "questlink" then
    -- FORM A precedence: checked before target/tier resolution ever gets
    -- a say, so a quest link's visible text can never be mistaken for an
    -- instance (see Classifier.hasQuestLink's own header).
    return Classifier.hasQuestLink(ctx.rawLine)
  elseif id == "questword" then
    -- FORM B: standalone "quest"/"quests" keyword. Gated on the same
    -- lf-family intent that already got this line past isRejected.
    return ctx.tokens ~= nil and hasStrongLFGIntent(ctx.tokens, ctx.C)
      and Classifier.hasQuestKeyword(ctx.normStr)
  elseif id == "catchall" then
    return true
  end
  return false
end

local function patternFires(p, ctx)
  if type(p) ~= "table" then return false end
  if p.kind == "keyword" then return patternMatchesKeyword(p.value, ctx)
  elseif p.kind == "regex" then return patternMatchesRegex(p.value, ctx)
  elseif p.kind == "catalog" then return patternMatchesCatalog(p.value, ctx)
  elseif p.kind == "special" then return patternMatchesSpecial(p.id, ctx)
  end
  return false
end

-- A matcher fires if ANY of its patterns matches.
local function matcherFires(entry, ctx)
  local patterns = entry.patterns
  if type(patterns) ~= "table" then return false end
  for i = 1, #patterns do
    if patternFires(patterns[i], ctx) then return true end
  end
  return false
end
Classifier.matcherFires = matcherFires

local function cat(name) return { kind = "category", name = name } end
local function kw(value) return { kind = "keyword", value = value } end
local function rx(value) return { kind = "regex", value = value } end
local function catalog(value) return { kind = "catalog", value = value } end
local function special(id) return { kind = "special", id = id } end

-- First match wins, so matcher order IS the tier tiebreak. The tier block
-- is ordered by tier priority: Adventure > Mythic+ > Heroic > Leveling
-- (RDF) > Manastorm. World Boss (mentions) and PvP sit after the tier
-- block and the Dungeon matcher, before the Quest-word matcher. The list
-- ends in a catch-all; remove it and unmatched lines are dropped rather
-- than filed under Other.
local DEFAULT_PIPELINE = {
  { name = "Quest link",          patterns = { special("questlink") },        outcome = cat("Quest") },
  { name = "World Boss",          patterns = { catalog("worldboss") },        outcome = cat("World Boss") },
  { name = "Raid",                patterns = { catalog("raid") },             outcome = cat("Raid") },
  { name = "Adventure",           patterns = { kw("adventure") },             outcome = cat("Leveling") },
  { name = "Mythic+",             patterns = { kw("m+"), kw("key"), kw("keystone"), kw("mythic"), kw("m0") },
                                                                               outcome = cat("Mythic+") },
  { name = "Heroic", id = "heroic", patterns = { kw("heroic"), kw("hc"), kw("h") },
                                                                               outcome = cat("Heroic") },
  { name = "Leveling (RDF)",      patterns = { kw("rdf"), kw("spam"), kw("aura") },
                                                                               outcome = cat("Leveling") },
  { name = "Manastorm",           patterns = { kw("manastorm") },             outcome = cat("Manastorm") },
  { name = "Dungeon (leveling)",  patterns = { catalog("dungeon") },          outcome = cat("Leveling") },
  { name = "World Boss (mentions)", patterns = { kw("wb"), kw("worldboss"), kw("world boss") },
                                                                               outcome = cat("World Boss") },
  { name = "PvP",                 patterns = { kw("pvp"), kw("arena"), kw("bg"), kw("battleground") },
                                                                               outcome = cat("PvP") },
  { name = "Quest word",          patterns = { special("questword") },        outcome = cat("Quest") },
  { name = "Everything else",     patterns = { special("catchall") },         outcome = cat("Other") },
}
Classifier.DEFAULT_PIPELINE = DEFAULT_PIPELINE

-- A category is a name, a color, and a position in this list -- nothing
-- else. There is no enabled flag: a category either appears here or it
-- does not. These nine colors are duplicated verbatim in
-- Content.aliases.lua's ns.C.categories; keep the two in sync. Every
-- default must stay visually distinct from every other -- World Boss and
-- Raid in particular are easy to collapse into the same orange, and the
-- board, rail and export all rely on color alone to tell them apart.
local DEFAULT_CATEGORIES = {
  { name = "Leveling",   color = { r = .60, g = .63, b = .69, a = 1 } },
  { name = "Heroic",     color = { r = .31, g = .58, b = .84, a = 1 } },
  { name = "Mythic+",    color = { r = .66, g = .37, b = .91, a = 1 } },
  { name = "Raid",       color = { r = .91, g = .53, b = .23, a = 1 } },
  { name = "World Boss", color = { r = .85, g = .68, b = .10, a = 1 } },
  { name = "Manastorm",  color = { r = .27, g = .75, b = .48, a = 1 } },
  { name = "PvP",        color = { r = .91, g = .77, b = .42, a = 1 } },
  { name = "Quest",      color = { r = .95, g = .85, b = .35, a = 1 } },
  { name = "Other",      color = { r = .5,  g = .53, b = .6,  a = 1 } },
}
Classifier.DEFAULT_CATEGORIES = DEFAULT_CATEGORIES

-- Sentinel returned by categoryOf when a "hide"-outcome pipeline entry
-- matches. Must be a UNIQUE TABLE, not a plain string -- a plain-string
-- sentinel could collide with a real (if unlikely) user category named
-- the same string; a fresh table is `==`-equal to nothing else that ever
-- exists. Never a real category name -- Classifier.classify checks for
-- it and drops the line with reason "userhide" instead of building a
-- listing.
local HIDE = {}
Classifier.HIDE = HIDE

-- name -> does a row with this name exist in ns.C.categories (or
-- DEFAULT_CATEGORIES when C.categories is absent entirely)? A category
-- either exists (usable) or has been removed from the list outright
-- (never usable) -- there is no third state.
local function categoryExists(name, C)
  if not name then return false end
  local cats = (C and C.categories) or DEFAULT_CATEGORIES
  for _, c in ipairs(cats) do
    if type(c) == "table" and c.name == name then return true end
  end
  return false
end

-- categoryOf(target, tier, C, tokens, normStr, rawLine) -- walks
-- ns.C.pipeline (or DEFAULT_PIPELINE) top-down, first-match-wins. Each
-- entry is a {name, patterns, outcome} matcher (matcherFires above); on a
-- match, its outcome decides what happens next:
--   category -- if that category still exists in ns.C.categories, return it
--     (stop); otherwise treat exactly like "nothing" (fall through).
--   nothing  -- fall through to the next entry (relabel by a later matcher).
--   hide     -- return Classifier.HIDE immediately (classify() rejects the
--     line with reason "userhide").
-- Every entry's outcome.name is authoritative -- there is no dynamic
-- "resolved category" fallback; every matcher names its own fixed
-- category. If nothing in the pipeline ever returns a category or hide
-- (every matcher fell through, or the walk fell off the end of a
-- pipeline with no terminal catch-all), categoryOf returns nil --
-- classify() rejects the line with reason "unmatched". Other is just the
-- default pipeline's own terminal entry, removable like any other -- there
-- is no unconditional "always ends in Other" guarantee.
-- The walk itself lives in categoryOfDebug (below) -- categoryOf is a
-- thin wrapper that discards its extra two returns, so callers that only
-- want the category (classify) and callers that also want to know WHICH
-- entry decided it (the rules editor's live-test box) share one
-- evaluator.
-- categoryOfDebug: identical walk to categoryOf, but ALSO returns the
-- winning pipeline entry's 1-based index and the entry table itself (nil,
-- nil when nothing ever decided a result). categoryOf below is just this
-- function with the two extra returns discarded -- ONE evaluator, so the
-- rules editor's live-test box can show/highlight WHICH entry fired
-- without any risk of a second, drifting copy of the walk.
function Classifier.categoryOfDebug(target, tier, C, tokens, normStr, rawLine)
  C = C or {}
  local pipeline = C.pipeline or DEFAULT_PIPELINE
  local row = target and buildNameIndex(C)[target]
  local ctx = {
    target = target, tier = tier, C = C, tokens = tokens,
    normStr = normStr, rawLine = rawLine, row = row,
  }

  for i, entry in ipairs(pipeline) do
    if type(entry) == "table" and matcherFires(entry, ctx) then
      local outcome = entry.outcome or { kind = "nothing" }
      if outcome.kind == "hide" then
        return HIDE, i, entry
      elseif outcome.kind == "category" then
        if categoryExists(outcome.name, C) then return outcome.name, i, entry end
        -- resolved category no longer exists: fall through
      end
      -- outcome.kind == "nothing" (or unrecognized): fall through
    end
  end

  return nil, nil, nil
end

function Classifier.categoryOf(target, tier, C, tokens, normStr, rawLine)
  local category = Classifier.categoryOfDebug(target, tier, C, tokens, normStr, rawLine)
  return category
end

-- ============================================================
-- isRejected
-- ============================================================

function Classifier.isRejected(line, tokens, C)
  if not line or #line < 4 then return true, "tooShort" end

  local alpha = line:lower():gsub("[^a-z]", "")
  if #alpha > 0 then
    local first, allSame = alpha:sub(1, 1), true
    for i = 2, #alpha do
      if alpha:sub(i, i) ~= first then allSame = false; break end
    end
    if allSame then return true, "gibberish" end
    -- A vowel-less run only means keyboard-mash spam when it's a single
    -- unspaced blob (e.g. "asdfghjkl"). Multi-word abbreviation chat like
    -- "lf dm grp" is all-consonant per-word too but is legitimate LFG
    -- shorthand, not gibberish, so don't flag it once spaces are present.
    if not line:find("%s") and not alpha:find("[aeiou]") and #line > 3 then
      return true, "gibberish"
    end
  end

  -- Guild recruitment. Fires before target/tier resolution so a
  -- recruitment post never gets a false category from an incidental
  -- role/tier token (e.g. "M0" inside a recruiting pitch).
  -- hasRecruitContext is the curated strong-phrase list (no tag
  -- requirement -- a strong phrase alone is unambiguous either way);
  -- Classifier.isGuildAd generalizes beyond it by combining weaker
  -- signals (member-count brags, foreign recruit verbs, open-welcome
  -- phrasing, activity laundry-lists, <Tag>+join/welcome/member-solicit)
  -- -- see its own header comment for the full rationale.
  local lowerLine = line:lower()
  if hasRecruitContext(lowerLine) or Classifier.isGuildAd(line, C) then
    return true, "guild"
  end

  -- Question/conversational-opener reject. Fires before target/tier/spam
  -- resolution for the same reason as the guild check above -- an
  -- incidental content or level-shaped word later in a question ("what
  -- lvl is pale reach?") must not manufacture a false accept.
  if startsWithQuestionLead(tokens) and not hasStrongLFGIntent(tokens, C) then
    return true, "question"
  end

  -- Service/profession reject. hasServiceWord already requires the
  -- profession word to sit next to a trade token, so it implies a
  -- trade-intent token is present -- no separate check needed here.
  if hasServiceWord(tokens) or hasServiceLink(line) then
    return true, "service"
  end

  local spamWeights = (C and C.spamWeights) or SPAM_WEIGHTS
  local score = 0
  for _, t in ipairs(tokens) do
    local w = spamWeights[t]
    if w then score = score + w end
  end
  local strongLFG = hasIntentWord(tokens)
  local threshold = strongLFG and 2 or 1
  if score >= threshold then return true, "spam" end

  local intentWord = strongLFG or tokens[1] == "need"
  local normStr = table.concat(tokens, " ")
  local roleWord = hasRoleWord(tokens, C)
  local levelSig = hasLevelSignal(tokens)
  local modeTok = hasModeToken(tokens, C)
  local groupWord = hasGroupWord(tokens, normStr)
  local quantitySig = hasQuantitySignal(normStr)

  -- A content-name match is not an LFG signal on its own -- "did scholo
  -- earlier lol" is chatter, not a listing. It only counts toward
  -- ACCEPTING once it co-occurs with some other weak signal, and only if
  -- the match itself is "substantial" (see hasSubstantialContentMatch).
  -- Computed unconditionally (not gated behind weakSignal) because the
  -- nearmiss/notLFG split below needs it even on lines with NO other weak
  -- signal at all -- e.g. "did scholo earlier lol" has no role/mode/
  -- group/level/quantity word, only a content match.
  local contentMatch = hasSubstantialContentMatch(tokens, normStr, C)
  local weakSignal = intentWord or roleWord or modeTok or levelSig or groupWord or quantitySig
  local substantialContentMatch = weakSignal and contentMatch

  local signal = intentWord or (roleWord and (levelSig or modeTok)) or substantialContentMatch
  if not signal then
    -- Reject-reason split: "nearmiss" (looks like LFG but got dropped --
    -- a real review candidate for corpus tuning) vs "notLFG" (nothing
    -- LFG-ish at all -- ordinary chatter). Reuses the exact signals just
    -- computed above -- content match, role word, group word, mode token
    -- -- no second scan. intentWord can't reach here: it alone satisfies
    -- `signal` above, so every line in this branch has intentWord=false.
    -- levelSig/quantitySig are deliberately NOT nearmiss triggers on
    -- their own -- e.g. "2 more beers please" is plain chatter, not a
    -- dropped listing.
    if contentMatch or roleWord or groupWord or modeTok then
      return true, "nearmiss"
    end
    return true, "notLFG"
  end

  return false
end

-- ============================================================
-- extraction: levelFilter, roles, needCounts, intent, modifiers
-- ============================================================

local LEVEL_PATTERNS = { "(%d+)%+", "lvl%s*(%d+)", "lvl%+(%d+)", "(%d+)%s*%+" }

local function extractLevelFilter(normStr)
  for _, pat in ipairs(LEVEL_PATTERNS) do
    local d = normStr:match(pat)
    if d then return tonumber(d) end
  end
  return nil
end

-- ============================================================
-- extractPosterLevel(line) -- narrow bare-text self-level parse.
-- Deliberately its own tokenizer, NOT Classifier.normalize's -- a "+"/"-"
-- glued to a digit is semantically load-bearing here (it marks a
-- STIPULATION -- a group REQUIREMENT, not the poster's own level) and
-- normalize's tokenizer drops "-" as a bare separator entirely, which
-- would collapse a slot-range like "10-16" into two adjacent bare
-- numbers. Grammar-shape only (no ns.C vocabulary dependency) so a
-- rules-editor role-word addition can never quietly reopen a
-- count-as-level hole.
--
-- Callers gate this to intent=="LFG" only (Classifier.classify below) --
-- an LFM line's numbers describe headcounts/roles being recruited, never
-- the poster's own level ("any LFM line -> NO text level").
--
-- Grammar (first-match-wins, in priority order):
--   1. explicit "lvl N"/"level N"/"l N" (fused or spaced) -- but ONLY a
--      bare (no +/- suffix) N; an explicit level word with a stipulation
--      argument ("lvl 55+") is a dead end, not a hint to try a weaker
--      rule.
--   2. a role-token-adjacent bare number ("55 dps"/"dps 55").
--   3. a single standalone bare number in a plausible level band -- only
--      when it is the ONE such candidate on the line (two or more is a
--      headcount/roster-size line, not a stated level) and it isn't
--      sitting next to a group-size word ("25 man raid").
-- REJECTS outright (returns nil) any trailing "+", "N-M" range, or the
-- words "plus"/"up"/"and up" anywhere on the line -- those are group
-- stipulations, never the poster's own level. A wrong level is worse
-- than nil.
-- ============================================================
local POSTER_LEVEL_MAX = 80
local POSTER_LEVEL_ROLE = {
  heal = true, heals = true, healer = true, healers = true, healz = true,
  dps = true, dd = true, tank = true, tanks = true, dmg = true,
}
local POSTER_LEVEL_STIPULATION_WORD = { plus = true, up = true }
-- Also covers "N queues"/"a roll"/"N runs" quantity chatter (a run/queue
-- count, not a level) alongside the pre-existing group-size words.
local POSTER_LEVEL_SIZE_MARKER = {
  man = true, men = true, group = true, raid = true, party = true,
  team = true, roster = true, people = true, ppl = true,
  queue = true, queues = true, roll = true, run = true, runs = true,
}
-- A number immediately preceded by one of these is an item level/gearscore
-- reading ("ilvl 61", "gs 450"), never the poster's own character level --
-- rejected outright rather than fed to RULE 2/3. "item level N" is already
-- caught upstream: RULE 1 unconditionally consumes any "level" token before
-- RULE 2/3 ever run.
local POSTER_LEVEL_ITEM_MARKER = {
  ilvl = true, il = true, gs = true, gearscore = true, gear = true, item = true,
}
-- A "lvl N"/"level N" immediately preceded by one of these reads as a GOAL
-- ("goal lvl 60", "grinding to lvl 60"), not the poster's current level.
local POSTER_LEVEL_GOAL_WORD = {
  goal = true, by = true, to = true, reach = true, hit = true,
  want = true, till = true, ["until"] = true, need = true,
}

-- Keeps "+"/"-" glued to their digits (significant here); everything else
-- (including "/") is a bare separator. Escapes stripped first via the
-- same stripWowEscapes normalize/plainText already use, so a hyperlink's
-- numeric payload (item id, quest level req -- never a character level)
-- is removed before tokenizing, not pattern-matched around.
local function posterLevelTokens(line)
  local s = stripWowEscapes(line or "")
  s = s:lower()
  s = s:gsub("[^%w%+%-]", " ")
  local tokens = {}
  for w in s:gmatch("%S+") do
    tokens[#tokens + 1] = w
  end
  return tokens
end

-- A "bare" number: a clean run of digits only -- any "+"/"-" anywhere in
-- the token (glued on by the tokenizer above) disqualifies it.
local function bareLevelNum(t)
  local n = t and t:match("^(%d+)$")
  return n and tonumber(n) or nil
end

-- True when tokens[idx] sits immediately after an item-level/gearscore
-- marker -- RULE 2/RULE 3's shared reject check (see POSTER_LEVEL_ITEM_MARKER).
local function precededByItemLevelMarker(tokens, idx)
  local p = tokens[idx - 1]
  return p ~= nil and POSTER_LEVEL_ITEM_MARKER[p] == true
end

-- A bare number sitting at the very front of the line, in the same plausible
-- band RULE 2/3 use -- the "leading self-level" a goal clause must not be
-- allowed to override (see RULE 1's goal-word guard below).
local function leadingBareSelfLevel(tokens)
  local n = bareLevelNum(tokens[1])
  if not n or n < 10 or n > POSTER_LEVEL_MAX then return nil end
  local nxt = tokens[2]
  if nxt and POSTER_LEVEL_SIZE_MARKER[nxt] then return nil end
  return n
end

function Classifier.extractPosterLevel(line)
  if type(line) ~= "string" or line == "" then return nil end
  local tokens = posterLevelTokens(line)
  if #tokens == 0 then return nil end

  -- Stipulation words anywhere on the line reject the whole parse outright
  -- -- safer than guessing which number they modify.
  for i, t in ipairs(tokens) do
    if POSTER_LEVEL_STIPULATION_WORD[t] then return nil end
    if t == "and" and tokens[i + 1] == "up" then return nil end
  end

  -- RULE 1: explicit lvl/level/l word. A goal word immediately before it
  -- ("goal lvl 60", "grinding to lvl 60") means this occurrence names a
  -- TARGET level, not the poster's own -- prefer a bare leading self-level
  -- earlier in the line when one is present, since first-match-wins would
  -- otherwise let the goal clause's number win outright.
  for i, t in ipairs(tokens) do
    local attached = t:match("^level(%d+)$") or t:match("^lvl(%d+)$") or t:match("^l(%d+)$")
    if attached then
      local n = tonumber(attached)
      if n and n >= 1 and n <= POSTER_LEVEL_MAX then
        if POSTER_LEVEL_GOAL_WORD[tokens[i - 1]] then
          local lead = leadingBareSelfLevel(tokens)
          if lead then return lead end
        end
        return n
      end
    end
    if t == "lvl" or t == "level" or t == "l" then
      local n = bareLevelNum(tokens[i + 1])
      if n and n >= 1 and n <= POSTER_LEVEL_MAX then
        if POSTER_LEVEL_GOAL_WORD[tokens[i - 1]] then
          local lead = leadingBareSelfLevel(tokens)
          if lead then return lead end
        end
        return n
      end
      return nil -- explicit level word present but its argument is a
                 -- stipulation ("lvl 55+") or missing -- don't fall
                 -- through to a weaker rule and risk a different number.
    end
  end

  -- RULE 2: role-token-adjacent bare number (10..MAX -- the 2-digit floor
  -- is what keeps "1 dps"/"3 dps" headcounts from ever landing here).
  -- Skips a number preceded by an item-level/gearscore marker ("ilvl 61
  -- tank" is a gear reading, not this tank's character level).
  for i, t in ipairs(tokens) do
    if POSTER_LEVEL_ROLE[t] then
      for _, j in ipairs({ i - 1, i + 1 }) do
        local n = bareLevelNum(tokens[j])
        if n and n >= 10 and n <= POSTER_LEVEL_MAX and not precededByItemLevelMarker(tokens, j) then
          return n
        end
      end
    end
  end

  -- RULE 3: a single standalone bare number (10..MAX) -- only when it's
  -- the ONE such candidate on the line, and it isn't touching a
  -- group-size word ("25 man raid" is a raid size, not a level). A number
  -- preceded by an item-level/gearscore marker ("ilvl 61") never becomes a
  -- candidate at all.
  local candidates = {}
  for i, t in ipairs(tokens) do
    local n = bareLevelNum(t)
    if n and n >= 10 and n <= POSTER_LEVEL_MAX and not precededByItemLevelMarker(tokens, i) then
      candidates[#candidates + 1] = { n = n, i = i }
    end
  end
  if #candidates == 1 then
    local c = candidates[1]
    local prev, nxt = tokens[c.i - 1], tokens[c.i + 1]
    if not ((prev and POSTER_LEVEL_SIZE_MARKER[prev]) or (nxt and POSTER_LEVEL_SIZE_MARKER[nxt])) then
      return c.n
    end
  end

  return nil
end

local function extractRoles(tokens, C)
  local roles = {}
  if not C.roleWords then return roles end
  for _, t in ipairs(tokens) do
    local r = C.roleWords[t]
    if r then roles[r] = true end
  end
  return roles
end

-- Known filler words that legitimately sit between a bare leading numeral
-- and the role it's counting ("1 last dps" -> DPS=1, "1 big dps" -> DPS=1).
-- Config-surfaced (ns.C.countFillerWords, rules-editor seam) the same way
-- every other lexicon table in this file is -- this literal is the
-- fallback for any bare-C caller (tests, an older/partial fixture).
local COUNT_FILLER_WORDS = { last = true, more = true, big = true, x = true }

-- A bare leading numeral binds ONLY to the role word immediately after it
-- -- no scanning past intervening words -- UNLESS that one intervening
-- word is a known filler (COUNT_FILLER_WORDS above), in which case a
-- single extra hop is allowed ("1 last dps"/"1 big dps"). The scan also
-- aborts outright (never binds) the instant it crosses "need"/"needs" (a
-- real need-clause, not a count-adjacent role) or another bare numeral --
-- load-bearing because normalize drops "/" entirely, so a fraction like
-- "2/5" becomes two adjacent bare-numeral tokens, and an unguarded scan
-- could otherwise skip over "need" to bind a distant role to the wrong
-- number ("LFM Zul Farak 2/5 need dps" must not bind DPS=5).
local function bindCountToNearestRole(counts, tokens, from, n, C)
  local filler = C.countFillerWords or COUNT_FILLER_WORDS
  local j = from
  while j <= #tokens do
    local nt = tokens[j]
    if nt == "need" or nt == "needs" then return end
    if nt:match("^%d+$") then return end
    local role = C.roleWords[nt]
    if role then
      counts[role] = (counts[role] or 0) + n
      return
    end
    if j == from and filler[nt] then
      j = j + 1
    else
      return
    end
  end
end

local function extractNeedCounts(tokens, C)
  local counts = {}
  if not C.roleWords then return counts end

  -- separate tokens: strict adjacency (or one filler-word hop, see
  -- bindCountToNearestRole). Skips a numeral immediately PRECEDED by
  -- another bare numeral: once "/"/"-" is stripped by the tokenizer, a
  -- fraction like "2/5" or a range like "10-16" leaves two adjacent
  -- bare-numeral tokens, and without this guard the second one (the
  -- denominator/upper bound) would be treated as its own separate
  -- headcount.
  for i = 1, #tokens do
    local n = tokens[i]:match("^(%d+)$")
    if n then
      n = tonumber(n)
      local prevTok = tokens[i - 1]
      local precededByNumeral = prevTok and prevTok:match("^%d+$") ~= nil
      if n >= 1 and n <= MAX_NEED_COUNT and not precededByNumeral then
        bindCountToNearestRole(counts, tokens, i + 1, n, C)
      end
    end
  end

  -- fused "lfN" prefix (no space, no role suffix in the same token):
  -- "LF1 DPS" -> DPS=1. Anchored to `$` so it never matches the lf%d+m
  -- LFM marker ("lf2m") or plain "lf".
  for i, t in ipairs(tokens) do
    local n = t:match("^lf(%d+)$")
    if n then
      n = tonumber(n)
      if n >= 1 and n <= MAX_NEED_COUNT then
        bindCountToNearestRole(counts, tokens, i + 1, n, C)
      end
    end
  end

  -- fused tokens: "3dps", "1tank1heal", "lf3tanks"
  for _, t in ipairs(tokens) do
    for numStr, wordStr in t:gmatch("(%d+)(%a+)") do
      local role = C.roleWords[wordStr]
      local n = tonumber(numStr)
      if role and n and n >= 1 and n <= MAX_NEED_COUNT then
        counts[role] = (counts[role] or 0) + n
      end
    end
  end

  return counts
end

-- ============================================================
-- extractIntent -- decides LFG (seeking a group) vs LFM (recruiting for
-- one) from word order, since a bare "lf" token alone carries no notion
-- of what the poster wants. In real chat, the first *head noun* after
-- "lf" decides -- a PERSON (role/class/"1 guy"/"all roles") means
-- recruiting (LFM); a CONTENT noun (rdf/dungeon/spam/a dungeon name)
-- means seeking (LFG). "lf DPS ... rdf" = LFM, "lf RDF ... dps" = LFG --
-- word order, not vocabulary, carries the meaning.
--
-- Ordered, first-match-wins; returns intent (may be nil -- unset beats a
-- wrong guess, since the user filters on this) plus a reason string. The
-- reason is a reserved tuning field with no current consumer.
-- ============================================================

local function intentCountToken(t)
  local n = t:match("^(%d+)$")
  if not n then return nil end
  n = tonumber(n)
  if n >= 1 and n <= MAX_NEED_COUNT then return n end
  return nil
end

-- nxt (the following token) is optional -- when given, also tries the
-- token-bigram concat against C.classWords ("sun"+"cleric" ->
-- "suncleric"), so every call site gets that for free.
local function isPersonToken(t, nxt, C)
  if not t then return false end
  if C.roleWords and C.roleWords[t] then return true end
  if C.classWords then
    if C.classWords[t] then return true end
    if nxt and C.classWords[t .. nxt] then return true end
  end
  local extra = C.personWords or PERSON_EXTRA_WORDS
  return extra[t] == true
end

-- Narrower than isPersonToken -- role/class words only, no personWords
-- extras ("guy"/"pumper"/...). Used only for the before-the-seek-head
-- self-description tiebreak (7c): a bare "guy"/"pumper" earlier in the
-- line isn't a reliable self-description signal the way an actual role
-- or class name is.
local function isRoleOrClassToken(t, nxt, C)
  if not t then return false end
  if C.roleWords and C.roleWords[t] then return true end
  if C.classWords then
    if C.classWords[t] then return true end
    if nxt and C.classWords[t .. nxt] then return true end
  end
  return false
end

-- A content-name match only counts when "substantial" (length >= 3) --
-- same reasoning as hasSubstantialContentMatch: short alias keys (vc/st/
-- wc/dm) collide too easily with everyday words to anchor a positional
-- decision on their own. Literal ns.C.contentWords entries (rdf, dg, dj,
-- ...) are exempt -- they're curated, not word-collision-prone.
local function isContentToken(t, C)
  if not t then return false end
  local extra = C.contentWords or CONTENT_EXTRA_WORDS
  if extra[t] then return true end
  if #t < 3 then return false end
  return buildTargetLookup(C)[t] ~= nil
end

-- first "lf"/"lfp" token, or the "for" of a "looking for"/"lookin for"
-- phrase (scanning starts right after it, same as after a bare "lf").
local function findSeekHead(tokens)
  for i, t in ipairs(tokens) do
    if t == "lf" or t == "lfp" then return i end
    if (t == "looking" or t == "lookin") and tokens[i + 1] == "for" then
      return i + 1
    end
  end
  return nil
end

-- "need"/"needs" followed within 3 tokens by a person noun or "all" --
-- catches need-clauses with no lf/lfm/lfg token at all ("50+ rdf spam
-- need heal and dps"). The role/person requirement is deliberate: it
-- excludes non-recruiting "need" uses ("(need Aura)", "how stupid do you
-- need to be").
local function needFollowedByPerson(tokens, C)
  for i, t in ipairs(tokens) do
    if t == "need" or t == "needs" then
      for j = i + 1, math.min(i + 3, #tokens) do
        local nt = tokens[j]
        if nt == "all" then return true, "need-clause:all" end
        if isPersonToken(nt, tokens[j + 1], C) then return true, "need-clause:" .. nt end
      end
    end
  end
  return false, nil
end

-- "N more" ("1 more dps for rdf") or "+N <person>" ("+1 tank rdf spam
-- 50+ good grp") -- terse recruiting shorthand with no lf/need token.
local function countMoreOrPlusPerson(tokens, C)
  for i, t in ipairs(tokens) do
    if intentCountToken(t) and tokens[i + 1] == "more" then
      return true, "n-more:" .. t
    end
    local plusN = t:match("^%+(%d+)$")
    if plusN then
      local n = tonumber(plusN)
      if n and n >= 1 and n <= MAX_NEED_COUNT and isPersonToken(tokens[i + 1], tokens[i + 2], C) then
        return true, "plus-role:" .. t
      end
    end
  end
  return false, nil
end

local function extractIntent(tokens, needCounts, C)
  C = C or {}

  if tokens[1] == "need" then return "LFM", "need-first" end
  for _, t in ipairs(tokens) do
    if t == "lfm" or t:match("^lf%d+m$") then return "LFM", "lfm-token" end
  end

  local needHit, needReason = needFollowedByPerson(tokens, C)
  if needHit then return "LFM", needReason end

  local moreHit, moreReason = countMoreOrPlusPerson(tokens, C)
  if moreHit then return "LFM", moreReason end

  -- Explicit "lfg" MUST outrank the count/seek-head paths below it --
  -- otherwise a count elsewhere in the line ("tank and 2 dps LF random
  -- lfg, have that exp boost thing?") would flip an explicit LFG to LFM.
  for _, t in ipairs(tokens) do
    if t == "lfg" then return "LFG", "lfg-token" end
  end

  for _, t in ipairs(tokens) do
    if t:match("^lf%d+$") then return "LFM", "lfN:" .. t end
  end

  if needCounts and next(needCounts) then return "LFM", "count-role" end

  local headIdx = findSeekHead(tokens)
  if headIdx then
    if tokens[headIdx + 1] == "all" then return "LFM", "lf-all" end

    for i = headIdx + 1, #tokens do
      local t, nt = tokens[i], tokens[i + 1]
      if intentCountToken(t) then
        return "LFM", "count-after-lf:" .. t
      end
      if isPersonToken(t, nt, C) then
        return "LFM", "person-after-lf:" .. t
      end
      if isContentToken(t, C) then
        return "LFG", "content-after-lf:" .. t
      end
    end

    -- No terminal after the head at all -- a role/class word sitting
    -- BEFORE it usually just self-describes the poster ("59 TANK LF 55+
    -- RDF SPAM"), which reads LFG. Known miss: "any tanks lf mythic"
    -- inverts this (it means "[we] want mythic"), but the self-
    -- description reading is right far more often in the corpus. Uses
    -- the narrower role/class check, not the full person set -- a bare
    -- "guy"/"pumper" earlier isn't a reliable self-description signal.
    for i = 1, headIdx - 1 do
      if isRoleOrClassToken(tokens[i], tokens[i + 1], C) then
        return "LFG", "self-role-before-lf:" .. tokens[i]
      end
    end

    return nil, "unset-no-terminal"
  end

  return nil, "unset-no-seek-head"
end

local function extractModifiers(tokens)
  local mods = {}
  for _, t in ipairs(tokens) do
    local m = MODIFIER_WORDS[t]
    if m then mods[m] = true end
  end
  return mods
end

-- ============================================================
-- optional class tag (never gates classification)
-- ============================================================

local function buildClassCandidates(C)
  if C._classCandidates then return C._classCandidates end
  local list = {}
  local seen = {}
  local function push(name)
    if name and not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  if C.classes then
    for _, cl in ipairs(C.classes) do
      if cl.name and cl.name ~= "_other" then push(cl.name) end
    end
  end
  if C.roleHints then
    for name in pairs(C.roleHints) do push(name) end
  end
  C._classCandidates = list
  return list
end

local function normClassKey(s)
  return (s:lower():gsub("%s+", ""))
end

local function extractClassTag(tokens, normStr, C)
  if not C.classes and not C.roleHints then return nil, nil end
  local candidates = buildClassCandidates(C)
  for _, name in ipairs(candidates) do
    local matched = false
    if name:find("%s") then
      if normStr:find(name:lower(), 1, true) then matched = true end
    else
      local key = normClassKey(name)
      for _, t in ipairs(tokens) do
        if t == key then matched = true; break end
      end
    end
    if matched then
      local role = C.roleHints and C.roleHints[name]
      return name, role
    end
  end
  return nil, nil
end

-- ============================================================
-- classify
-- ============================================================

function Classifier.classify(line, meta, C)
  local ok, result, reason = pcall(function()
    meta = meta or {}
    C = C or {}

    local tokens, normStr = Classifier.normalize(line)

    local rejected, rReason = Classifier.isRejected(line, tokens, C)
    if rejected then return nil, rReason end

    local target = Classifier.resolveTarget(tokens, normStr, C, meta.posterLevel)
    -- A quest link must not slot a dungeon target -- it would collide
    -- with generated dungeon names like "Road to De Other Side"/"Vaults
    -- of Inquisition" whose own visible text equals a real dungeon name.
    if Classifier.hasQuestLink(line) then target = nil end
    local tier = tierOf(tokens, C)
    local roles = extractRoles(tokens, C)
    local needCounts = extractNeedCounts(tokens, C)
    local levelFilter = extractLevelFilter(normStr)
    local intent, intentReason = extractIntent(tokens, needCounts, C)
    -- The bare-text self-level parse is ONLY ever attempted (and stored)
    -- on a real LFG-intent line -- an LFM line's numbers describe
    -- headcounts/roles being recruited, never the poster's own level.
    -- levelFilter above stays the ONLY reader of "+"/range group
    -- requirements.
    local posterLevel = (intent == "LFG") and Classifier.extractPosterLevel(line) or nil
    local modifiers = extractModifiers(tokens)
    local category = Classifier.categoryOf(target, tier, C, tokens, normStr, line)
    if category == Classifier.HIDE then return nil, "userhide" end
    if category == nil then return nil, "unmatched" end
    local classTag, classRole = extractClassTag(tokens, normStr, C)

    local listing = {
      poster = meta.poster,
      guid = meta.guid,
      rawText = line,
      channelName = meta.channelName,
      intent = intent,
      intentReason = intentReason,
      roles = roles,
      needCounts = needCounts,
      levelFilter = levelFilter,
      posterLevel = posterLevel,
      target = target,
      tier = tier,
      modifiers = modifiers,
      category = category,
    }
    if classTag then listing.classTag = classTag end
    if classRole then listing.classRole = classRole end

    return listing, nil
  end)

  if not ok then return nil, "error" end
  return result, reason
end
