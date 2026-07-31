-- Last-used settings: the dialog reopens with the previous run's entries.
-- Every remembered value must be re-validated against the current job, so the
-- checks below are mostly about what gets DROPPED, not what survives.
local CO = EdgeBreaker

local IN = CO.unit_info(false)
local MM = CO.unit_info(true)
-- 1.1.0: the BIT is no longer remembered here. Aspire remembers it natively
-- through ToolDBId Save/LoadDefaults, which seeds the setup dialog's own
-- picker, so these settings only restore what was typed on that dialog.

-- round-trip
local written = CO.serialize_settings({ units = "in",
   mode = "leg", side = "inside", percent = 40, size = 0.0325 })
local back = CO.parse_settings(written)
CHECK(back.units == "in", "round-trip: units")
CHECK(back.mode == "leg" and back.side == "inside", "round-trip: mode and side")
NEAR(tonumber(back.percent), 40, 1e-9, "round-trip: percent")
NEAR(tonumber(back.size), 0.0325, 1e-12, "round-trip: size keeps its precision")
CHECK(written:find("^#") ~= nil, "file leads with a comment line")

-- parser tolerance: junk, comments and blank lines are not settings
CHECK(CO.parse_settings("# just a comment\n\n") == nil, "no key=value pairs -> nil")
CHECK(CO.parse_settings("") == nil, "empty file -> nil")
CHECK(CO.parse_settings(nil) == nil, "no file content -> nil")
local mixed = CO.parse_settings("# c\r\nmode = leg \r\nnonsense\r\nsize=0.5\r\n")
CHECK(mixed.mode == "leg" and mixed.size == "0.5", "CRLF, padding and junk lines survive parsing")
-- a value may itself contain '=' (a filename legally can)
CHECK(CO.parse_settings("template=V-Bit 90=deg.ToolpathTemplate").template
      == "V-Bit 90=deg.ToolpathTemplate", "value keeps an inner '='")
-- a multi-line value would be unparseable on the way back in: drop it
CHECK(CO.serialize_settings({ mode = "leg\nside=inside" }):find("side") == nil,
      "a value containing a newline is not written")

-- nothing remembered -> exactly the pre-1.0.6 defaults
local d = CO.apply_settings(nil, IN)
CHECK(d.mode == "setback" and d.side == "auto" and d.percent == 80, "no settings: field defaults")
NEAR(d.size, 0.020, 1e-9, "no settings: inch default size")
local dmm = CO.apply_settings(nil, MM)
NEAR(dmm.size, 0.5, 1e-9, "no settings: mm default size")

-- the bit is deliberately NOT seeded here any more
CHECK(d.template == nil and d.bit_name == nil and d.angle == nil and d.diameter == nil,
      "settings no longer carry the bit -- Aspire remembers it via ToolDBId")
CHECK(CO.TOOL_SECTION == "EdgeBreaker", "tool memory has a registry section")

-- a full, still-valid memory comes back intact
local full = { units = "in", mode = "face",
               side = "outside", percent = 20, size = 0.031 }
local s = CO.apply_settings(full, IN)
CHECK(s.mode == "face" and s.side == "outside" and s.percent == 20, "mode, side, percent restored")
NEAR(s.size, 0.031, 1e-12, "size restored")

-- a settings file written by 1.0.x still has template=; it must parse and be
-- ignored, not upset the values around it
local legacy = CO.parse_settings(
   "units=in\ntemplate=V-Bit 90deg 0.250in.ToolpathTemplate\nmode=leg\nsize=0.031\n")
local upgraded = CO.apply_settings(legacy, IN)
CHECK(upgraded.mode == "leg", "a 1.0.x settings file still restores mode")
NEAR(upgraded.size, 0.031, 1e-12, "a 1.0.x settings file still restores size")
CHECK(CO.serialize_settings(legacy):find("template=") == nil,
      "the dropped template key is not written back out")

-- units guard: size is the one value that is dangerous to carry across
local cross = CO.apply_settings({ units = "in", size = 0.020 }, MM)
NEAR(cross.size, 0.5, 1e-9, "an inch size is not reused in a mm job")
local same = CO.apply_settings({ units = "mm", size = 0.8 }, MM)
NEAR(same.size, 0.8, 1e-12, "a mm size is reused in a mm job")
local nounits = CO.apply_settings({ size = 0.031 }, IN)
NEAR(nounits.size, 0.020, 1e-9, "a size with no saved units is not trusted")
for _, bad in ipairs({ "0", "-0.5", "abc", "" }) do
   local r = CO.apply_settings({ units = "in", size = bad }, IN)
   NEAR(r.size, 0.020, 1e-9, "non-positive/garbage size '" .. bad .. "' is ignored")
end

-- values the dialog cannot produce are ignored rather than passed through
CHECK(CO.apply_settings({ mode = "banana" }, IN).mode == "setback", "unknown mode ignored")
CHECK(CO.apply_settings({ side = "sideways" }, IN).side == "auto", "unknown side ignored")
CHECK(CO.apply_settings({ percent = 55 }, IN).percent == 80,
      "a percent that is not one of the presets is ignored")
CHECK(CO.apply_settings({ percent = "abc" }, IN).percent == 80, "garbage percent ignored")
CHECK(CO.apply_settings({ percent = "100" }, IN).percent == 100,
      "a preset arrives from file as a string and still matches")
-- 0 is the one preset that reads like "nothing saved". It comes back off disk
-- as the string "0", which is exactly what a missing value would look like if
-- the match were ever loosened, so pin it separately from the loop below.
CHECK(CO.apply_settings({ percent = "0" }, IN).percent == 0,
      "0% survives the trip through the settings file")
for _, p in ipairs(CO.PRESETS) do
   CHECK(CO.apply_settings({ percent = p }, IN).percent == p,
         "preset " .. p .. "% is restorable")
end
CHECK(CO.apply_settings({ mode = "setback" }, IN).mode == "setback",
      "every mode the dialog offers is accepted")
for m in pairs(CO.MODES) do
   CHECK(CO.apply_settings({ mode = m }, IN).mode == m, "mode '" .. m .. "' is restorable")
end
for sd in pairs(CO.SIDES) do
   CHECK(CO.apply_settings({ side = sd }, IN).side == sd, "side '" .. sd .. "' is restorable")
end

-- the seed must be usable by the dialog: percent always matches a preset row,
-- and mode is always one CO.w_from_size understands
local seeded = CO.apply_settings({ mode = "junk", percent = 999, size = "x" }, IN)
CHECK(CO.MODES[seeded.mode] == true, "seeded mode is always a known mode")
local matched = false
for _, p in ipairs(CO.PRESETS) do if p == seeded.percent then matched = true end end
CHECK(matched, "seeded percent always matches a preset button")

-- storage location: outside the gadget folder, which sync-gadgets.bat mirrors
local path = CO.settings_path()
CHECK(path == nil or path:find("EdgeBreaker%-settings%.txt") ~= nil,
      "settings file is named predictably")
CHECK(path == nil or path:lower():find("gadgets") == nil,
      "settings file does not live in the Gadgets folder (robocopy /MIR would delete it)")

-- Start depth (v1.6.0) is deliberately NOT a last-used setting. It lives only
-- in a chamfer's own memory blob, which is what makes a NEW chamfer always
-- open at 0: a leftover 0.25 from yesterday's pocket can never apply itself
-- to today's job, where it would silently cut a quarter inch too deep.
local wrote_start = CO.serialize_settings({ units = "in", mode = "setback",
   side = "auto", percent = 80, size = 0.02, start = 0.25 })
CHECK(wrote_start:find("start", 1, true) == nil,
      "the settings file never carries a start depth")
NEAR(CO.apply_settings(CO.parse_settings(wrote_start), IN).start, 0, 1e-12,
     "a new chamfer opens at start depth 0")

-- ...but a value coming from a memory blob IS honoured, under the same rules
-- as a remembered size: it is a length, so it is dropped (never converted)
-- when the job's units no longer match.
NEAR(CO.apply_settings({ start = "0.25", units = "in" }, IN).start, 0.25, 1e-12,
     "a start depth from a memory blob is honoured")
NEAR(CO.apply_settings({ start = "0.25", units = "in" }, MM).start, 0, 1e-12,
     "a remembered inch start depth is dropped in a mm job")
NEAR(CO.apply_settings({ start = "-1", units = "in" }, IN).start, 0, 1e-12,
     "a negative remembered start depth is dropped")
NEAR(CO.apply_settings({ start = "banana", units = "in" }, IN).start, 0, 1e-12,
     "a garbled remembered start depth is dropped")
NEAR(CO.apply_settings({}, IN).start, 0, 1e-12, "no memory at all seeds 0")

-- ==================== v1.10.0: the measured screen ====================
-- The screen size lives in its OWN file, not in the settings file. save_settings
-- writes the whole table from the keys its caller passes, so a screen size
-- living in CO.SETTINGS_KEYS would be erased by every ordinary save unless every
-- call site remembered to carry it. A separate file also gives a clean remedy
-- for a stuck value: delete it and the next run measures again.
CHECK(CO.screen_path() ~= CO.settings_path(), "the screen size has its own file")
CHECK(CO.screen_path():find("EdgeBreaker%-screen%.txt") ~= nil, "and its own name")
do
   local keys = table.concat(CO.SETTINGS_KEYS, ",")
   CHECK(keys:find("screen") == nil, "no screen key rides in the settings file")
end

-- The shape a page writes into its hidden field.
do
   local w, h = CO.parse_screen_field("1920x1040")
   CHECK(w == 1920 and h == 1040, "a page's WxH field parses")
   local w2, h2 = CO.parse_screen_field("  1366 x 728  ")
   CHECK(w2 == 1366 and h2 == 728, "spaces around the x are tolerated")
   CHECK(CO.parse_screen_field("") == nil, "an empty field is nothing, not zero")
   CHECK(CO.parse_screen_field(nil) == nil, "a missing field is nothing")
   CHECK(CO.parse_screen_field("1920") == nil, "half a measurement is nothing")
   CHECK(CO.parse_screen_field("widexhigh") == nil, "words are nothing")
   CHECK(CO.parse_screen_field(1920) == nil, "a non-string is nothing, not a crash")
   -- Believability is enforced here too, so a nonsense value never reaches disk.
   CHECK(CO.parse_screen_field("100x100") == nil, "too small to be a screen -> nothing")
   CHECK(CO.parse_screen_field("99999x99999") == nil, "absurdly large -> nothing")
end

-- Round trip through the real file, then put the user's own file back exactly
-- as it was. This test writes to %APPDATA% on the machine running it.
do
   local path = CO.screen_path()
   local prior = nil
   do
      local f = io.open(path, "rb")
      if f then prior = f:read("*a"); f:close() end
   end
   -- This block also calls CO.save_settings below, which overwrites the real
   -- settings file -- save it and put it back too, same as the screen file.
   local settings_path = CO.settings_path()
   local settings_prior = nil
   do
      local f = io.open(settings_path, "rb")
      if f then settings_prior = f:read("*a"); f:close() end
   end

   CHECK(CO.save_screen(1920, 1040) == true, "a believable screen saves")
   local w, h = CO.load_screen()
   CHECK(w == 1920 and h == 1040, "and reads back as numbers")

   CHECK(CO.save_screen(10, 10) == false, "an unbelievable screen is refused, not written")
   local w2, h2 = CO.load_screen()
   CHECK(w2 == 1920 and h2 == 1040, "and the refused write left the good value alone")

   -- Garbage on disk reads as nothing, which lands on the default window.
   do
      local f = assert(io.open(path, "w"))
      f:write("this is not a screen size\n"); f:close()
      CHECK(CO.load_screen() == nil, "a mangled file reads as no measurement")
   end

   -- The two files do not disturb each other, in either direction.
   CHECK(CO.save_screen(1366, 728) == true, "save a screen")
   CO.save_settings({ units = "in", mode = "setback", side = "auto", percent = 80, size = 0.02 })
   local w3, h3 = CO.load_screen()
   CHECK(w3 == 1366 and h3 == 728, "saving settings leaves the screen size alone")
   local s = CO.load_settings()
   CHECK(s ~= nil and s.size == "0.02", "and the settings file is still readable")

   -- No file at all is the first-run state.
   os.remove(path)
   CHECK(CO.load_screen() == nil, "no file means no measurement")

   if prior then
      local f = assert(io.open(path, "wb")); f:write(prior); f:close()
   end
   if settings_prior then
      local f = assert(io.open(settings_path, "wb")); f:write(settings_prior); f:close()
   else
      os.remove(settings_path)
   end
end
