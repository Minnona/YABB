local ADDON, ns = ...
ns.C = ns.C or {}

-- Runtime lexicon and default-content tables read live by Classifier.lua.
-- Every lexicon table below (aliases, modeTokens, roleWords, spamWeights,
-- personWords, contentWords, countFillerWords) has a literal fallback
-- copy of the same values inside Classifier.lua itself, used by any
-- bare-C caller (tests, an older or partial saved config) that omits the
-- field -- so classification behavior never depends on whether this file
-- happened to load.

ns.C.aliases = { brd="Blackrock Depths - Prison", ubrs="Upper Blackrock Spire", lbrs="Lower Blackrock Spire",
  sm="Scarlet Monastery - Graveyard", ["sm lib"]="Scarlet Monastery - Library", zf="Zul'Farrak", rfc="Ragefire Chasm",
  wc="Wailing Caverns", sfk="Shadowfang Keep", mara="Maraudon - Orange Crystals", strat="Stratholme - Main Gate", scholo="Scholomance",
  vc="Deadmines", dm="Deadmines", diremaul="Dire Maul - East", st="Sunken Temple", ulda="Uldaman",
  voti="Vaults of Inquisition" }
ns.C.modeTokens = { heroic="heroic", hc="heroic", h="heroic", mythic="mythic", m0="mythic",
  ["m+"]="mythicplus", key="mythicplus", keystone="mythicplus", adventure="adventure",
  rdf="leveling", spam="leveling", aura="leveling", manastorm="manastorm" }
ns.C.roleWords = { tank="TANK", tanks="TANK", heal="HEAL", heals="HEAL", healer="HEAL", dps="DPS", dd="DPS" }
ns.C.roleHints = { Necromancer="DPS", Tinker="DPS", Runemaster="DPS", Cultist="HYBRID", Starcaller="HYBRID",
  Templar="TANK", Reaper="DPS", Primalist="HYBRID", ["Witch Hunter"]="DPS" }
-- Class/archetype words excluded from the dungeon/raid NAME-word index in
-- Classifier.buildTargetLookup, alongside ns.C.classes (the 43 CAD
-- dataset rows). Ascension archetype/spec words normalize to
-- short, plain-English-looking tokens that can collide with a generated
-- dungeon name (e.g. "crusader"/"templar" vs Trial of the Crusader) --
-- this curated set catches the archetype vocabulary the dataset rows
-- don't cover. All lowercased, no spaces (matches the token/name-word
-- normalization buildTargetLookup already applies).
ns.C.classWords = {
  crusader=true, templar=true, tinker=true, warden=true, inquisitor=true, blackguard=true,
  reaper=true, cultist=true, starcaller=true, venomancer=true, runemaster=true, bloodmage=true,
  primalist=true, necromancer=true, chronomancer=true, pyromancer=true, stormbringer=true,
  guardian=true, ranger=true, barbarian=true, felsworn=true, suncleric=true, witchhunter=true,
  witchdoctor=true, knightofxoroth=true, sonofarugal=true, monk=true, demonhunter=true,
  warrior=true, paladin=true, hunter=true, rogue=true, priest=true, deathknight=true,
  shaman=true, mage=true, warlock=true, druid=true,
}
-- Legacy hint table: read only by the pipeline migration's
-- splitHintsEntry when converting a saved legacy-shape pipeline. The
-- live equivalents are the World Boss (mentions) and PvP keyword
-- matchers in ns.C.pipeline below -- categoryOf itself never reads this
-- table.
ns.C.categoryHints = { ["world boss"]="World Boss", worldboss="World Boss", wb="World Boss",
  manastorm="Manastorm", pvp="PvP", arena="PvP", bg="PvP", battleground="PvP" }
-- Positional intent-decision vocabulary: "who's being sought" vs "what's
-- being sought", scanned token-by-token after a seek-head (lf/lfp/
-- looking-for). Deliberately does NOT duplicate ns.C.roleWords/
-- ns.C.classWords -- the classifier unions those in at match time; this
-- is only the EXTRA person-noun vocabulary neither of those tables
-- already covers.
ns.C.personWords = {
  guy = true, guys = true, player = true, players = true, ppl = true,
  people = true, pumper = true, pumpers = true, dude = true, man = true,
  mate = true, mates = true, buddy = true, member = true, members = true,
  someone = true, haver = true, role = true, roles = true, healz = true,
  dd = true,
}
-- Content nouns: what's being sought when the seek-head's argument names an
-- activity/instance rather than a person. Extended at match time by
-- Classifier's own dungeon/boss/alias word lookup (a token that resolves a
-- real target counts as content too, without needing a duplicate entry
-- here).
ns.C.contentWords = {
  rdf = true, rfd = true, rdfs = true, dungeon = true, dungeons = true,
  dung = true, dungs = true, dungy = true, dng = true, dngn = true,
  dg = true, dgs = true, dj = true, spam = true, raid = true, raids = true,
  group = true, groups = true, grp = true, pug = true, run = true, runs = true,
  wb = true, worldboss = true, boss = true, bosses = true, instance = true,
  instanced = true, quest = true, party = true, team = true,
}
-- Gold-seller/spam vocabulary, config-surfaced so the "Reject / spam"
-- lexicon group in the rules editor can show/edit it like every other
-- trigger table. Same values as Classifier.lua's own SPAM_WEIGHTS
-- constant; this is the copy the shipped addon actually classifies
-- against once this file has loaded.
ns.C.spamWeights = { wts=1, wtb=1, wtt=1, sell=1, selling=1, buying=1, boost=1,
  recruiting=1, recruit=1, guild=0.6, dp=0.7, gold=0.5,
  ["2v2"]=1, ["3v3"]=1, ["5v5"]=1 }
-- Filler words a bare leading numeral is allowed to hop over to reach
-- the role it's counting ("1 last dps", "1 big dps" -> DPS=1). Same
-- config-over-code seam as every other lexicon table above.
ns.C.countFillerWords = { last=true, more=true, big=true, x=true }

-- ============================================================
-- ns.C.categories / ns.C.pipeline: category = name+color+order only;
-- pipeline matcher entries carry a tagged outcome. Config-over-code,
-- mutable + persisted/shareable the same way every other ns.C table
-- above is -- these two are read live by Classifier.categoryOf.
-- Classifier.lua keeps its own literal-default copy of both,
-- DEFAULT_CATEGORIES/DEFAULT_PIPELINE, as the standing fallback for any
-- bare-C caller that omits them. See Classifier.lua's own header comment
-- above categoryOf for the full outcome-shape rationale.
--
-- ns.C.categories: display-ordered list of { name, color={r,g,b,a} } --
-- nothing else. No enabled flag and no builtin flag -- a category's only
-- state is whether it's IN this list at all (and where). The 9 default
-- rows/colors mirror Classifier.DEFAULT_CATEGORIES exactly -- see that
-- table's comment for the color-distinctness invariant. Every row,
-- including these 9, is removable -- Filters.applyOverlay only
-- substitutes the shipped defaults back in when the SAVED config has no
-- categories of its own at all; once a category exists here, its
-- presence alone is what makes a pipeline entry's category-outcome
-- resolve.
ns.C.categories = {
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

-- ns.C.pipeline: ordered, first-match-wins list of UNIFORM matcher
-- entries -- { name=<string>, patterns={...}, outcome=<outcome> }. A
-- matcher fires if ANY of its patterns matches (see Classifier.lua's
-- matcherFires/patternFires for the four pattern kinds: keyword/regex/
-- catalog/special). outcome is {kind="category",name=<name>} |
-- {kind="nothing"} | {kind="hide"}. Matcher order is the only tiebreak
-- among tiers -- see Classifier.lua's DEFAULT_PIPELINE header for the
-- full rationale:
--   quest-link > worldboss(catalog) > raid(catalog) > adventure > mythic+ >
--   heroic > leveling(rdf) > manastorm > leveling(dungeon catalog) >
--   world-boss(mentions) > pvp > quest-word > everything else
-- A saved legacy-shape pipeline (matcher="detector"/"rule" entries) is
-- migrated to this shape once, in Filters.applyOverlay (see Filters.lua's
-- migration). This literal is kept as a byte-for-byte copy of
-- Classifier.DEFAULT_PIPELINE, same pattern as ns.C.categories above.
ns.C.pipeline = {
  { name = "Quest link",          patterns = { { kind = "special", id = "questlink" } },
    outcome = { kind = "category", name = "Quest" } },
  { name = "World Boss",          patterns = { { kind = "catalog", value = "worldboss" } },
    outcome = { kind = "category", name = "World Boss" } },
  { name = "Raid",                patterns = { { kind = "catalog", value = "raid" } },
    outcome = { kind = "category", name = "Raid" } },
  { name = "Adventure",           patterns = { { kind = "keyword", value = "adventure" } },
    outcome = { kind = "category", name = "Leveling" } },
  { name = "Mythic+",             patterns = {
      { kind = "keyword", value = "m+" }, { kind = "keyword", value = "key" },
      { kind = "keyword", value = "keystone" }, { kind = "keyword", value = "mythic" },
      { kind = "keyword", value = "m0" } },
    outcome = { kind = "category", name = "Mythic+" } },
  { name = "Heroic", id = "heroic", patterns = {
      { kind = "keyword", value = "heroic" }, { kind = "keyword", value = "hc" },
      { kind = "keyword", value = "h" } },
    outcome = { kind = "category", name = "Heroic" } },
  { name = "Leveling (RDF)",      patterns = {
      { kind = "keyword", value = "rdf" }, { kind = "keyword", value = "spam" },
      { kind = "keyword", value = "aura" } },
    outcome = { kind = "category", name = "Leveling" } },
  { name = "Manastorm",           patterns = { { kind = "keyword", value = "manastorm" } },
    outcome = { kind = "category", name = "Manastorm" } },
  { name = "Dungeon (leveling)",  patterns = { { kind = "catalog", value = "dungeon" } },
    outcome = { kind = "category", name = "Leveling" } },
  { name = "World Boss (mentions)", patterns = {
      { kind = "keyword", value = "wb" }, { kind = "keyword", value = "worldboss" },
      { kind = "keyword", value = "world boss" } },
    outcome = { kind = "category", name = "World Boss" } },
  { name = "PvP",                 patterns = {
      { kind = "keyword", value = "pvp" }, { kind = "keyword", value = "arena" },
      { kind = "keyword", value = "bg" }, { kind = "keyword", value = "battleground" } },
    outcome = { kind = "category", name = "PvP" } },
  { name = "Quest word",          patterns = { { kind = "special", id = "questword" } },
    outcome = { kind = "category", name = "Quest" } },
  { name = "Everything else",     patterns = { { kind = "special", id = "catchall" } },
    outcome = { kind = "category", name = "Other" } },
}
