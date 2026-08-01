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

-- v1.10.3: the " off" suffix -- the page's way of saying "these numbers are the
-- primary's and I was NOT on the primary" (Trident only ever reports the
-- primary; ScreenProbe sitting, 2026-07-30).
do
   local w, h, off = CO.parse_screen_field("1920x1032 off")
   CHECK(w == 1920 and h == 1032 and off == true, "WxH off parses, flag up")
   local w2, h2, off2 = CO.parse_screen_field("1920x1032")
   CHECK(w2 == 1920 and off2 == false, "no suffix means on the primary, flag down")
   -- The suffix is a token, not a substring hunt: anything else stays nothing.
   CHECK(CO.parse_screen_field("1920x1032 offx") == nil, "a mangled suffix is nothing")
   CHECK(CO.parse_screen_field("1920x1032 on") == nil, "an unknown word is nothing")
   CHECK(CO.parse_screen_field("off") == nil, "the word alone is nothing")
   CHECK(CO.parse_screen_field("100x100 off") == nil, "believability still applies with the suffix")
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

   CHECK(CO.save_screen({ screen_w = 1920, screen_h = 1040 }) == true,
         "a believable screen saves")
   local store = CO.load_screen()
   CHECK(store ~= nil and store.screen_w == 1920 and store.screen_h == 1040,
         "and reads back as numbers")
   CHECK(store ~= nil and store.everoff == false,
         "no everoff in the store saves as on-primary")

   -- v1.12.0 replaced the per-run offprimary flag with a STICKY everoff bit,
   -- but it still round-trips through the real file the same way.
   CHECK(CO.save_screen({ screen_w = 1920, screen_h = 1040, everoff = true }) == true,
         "the off-primary flag saves")
   local ostore = CO.load_screen()
   CHECK(ostore ~= nil and ostore.screen_w == 1920 and ostore.everoff == true,
         "and reads back true")

   -- v1.12.0 retired the monitor count this block used to round-trip here --
   -- the ask-Windows decision it fed is Task 7's to remove, and what replaced
   -- it is the sticky flag above. CO.remember_screen is what sets it (and the
   -- per-slot window sizes) from a real dialog close, so real-file round trip
   -- coverage belongs to it now. Constraint 1: remember_screen must always
   -- start from CO.load_screen() and OR the flag in, never build a bare table
   -- -- proven here by seeding a real on-disk store first, not just a fresh one.
   CHECK(CO.save_screen({ screen_w = 1920, screen_h = 1040, everoff = false }) == true,
         "seed: a machine that has only ever seen the primary")
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1280x700" end
   end })
   local onclose = CO.load_screen()
   CHECK(onclose ~= nil and onclose.everoff == false,
         "an ordinary on-primary close leaves the sticky flag alone")
   CHECK(onclose ~= nil and onclose.win_on ~= nil and onclose.win_on[1] == 1280
         and onclose.win_on[2] == 700, "...and remembers the on-primary window size")
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032 off" end
      if name == "WinSize" then return "1092x576" end
   end })
   local offclose = CO.load_screen()
   CHECK(offclose ~= nil and offclose.everoff == true,
         "an off-primary close raises the sticky flag")
   CHECK(offclose ~= nil and offclose.win_off ~= nil and offclose.win_off[1] == 1092
         and offclose.win_off[2] == 576,
         "...and remembers the off-primary window size separately")
   CHECK(offclose ~= nil and offclose.win_on ~= nil and offclose.win_on[1] == 1280,
         "...without disturbing the on-primary size remembered earlier")
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
   end })
   local stillup = CO.load_screen()
   CHECK(stillup ~= nil and stillup.everoff == true,
         "a later on-primary close does NOT clear the sticky flag")

   -- Task 6 code review: `off` comes back nil, not false, when the Screen
   -- field fails to parse -- "don't know which monitor" must not default to
   -- "the primary", or a size measured on an unreadable run permanently
   -- overwrites win_on, the slot every single-monitor machine depends on.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "garbage" end
      if name == "WinSize" then return "999x999" end
   end })
   local unknown = CO.load_screen()
   CHECK(unknown ~= nil and unknown.win_on ~= nil and unknown.win_on[1] == 1280,
         "an unreadable Screen field leaves win_on alone rather than guessing it")
   CHECK(unknown ~= nil and unknown.win_off ~= nil and unknown.win_off[1] == 1092,
         "...and leaves win_off alone too -- neither slot is the right guess")

   -- v1.12.0 defect fix, found live 2026-07-31: the page can only see its own
   -- CLIENT box, so remember_screen adds the frame back on before storing an
   -- OUTER size. The frame is derived from the run itself -- asked minus the
   -- client box at load -- never assumed. Every case below uses the machine the
   -- defect was found on: asked 1800x1000, client box 1796x868, so a frame of
   -- 4 wide and 132 tall.
   --
   -- THE INVARIANT, and the whole reason the arithmetic is shaped this way: on
   -- a run nobody resized, current == load, so the stored size comes out
   -- exactly the size the dialog was asked to open at. Open and close it a
   -- hundred times and it cannot drift by one pixel.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1796x868|1796x868" end
   end }, 1800, 1000)
   local noresize = CO.load_screen()
   CHECK(noresize ~= nil and noresize.win_on ~= nil and noresize.win_on[1] == 1800
         and noresize.win_on[2] == 1000,
         "a run nobody resized remembers exactly the size it was asked to open at")

   -- And the half that was broken: a drag moves the client box, and the same
   -- frame carries it back to an outer size. 2396+4 x 1268+132.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "2396x1268|1796x868" end
   end }, 1800, 1000)
   local dragged = CO.load_screen()
   CHECK(dragged ~= nil and dragged.win_on ~= nil and dragged.win_on[1] == 2400
         and dragged.win_on[2] == 1400,
         "a dragged window remembers the size it was dragged to, frame and all")

   -- A page that sends one pair is a page speaking the pre-fix shape, where the
   -- number IS the outer size. Stored as-is, exactly as it was before.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1536x825" end
   end }, 1800, 1000)
   local lone = CO.load_screen()
   CHECK(lone ~= nil and lone.win_on ~= nil and lone.win_on[1] == 1536
         and lone.win_on[2] == 825,
         "a lone pair is still taken as an outer size, frame arithmetic skipped")

   -- Nothing that could be a window frame: 800x600 of it. Storing the client
   -- box as if it were the outer size instead would cost the window its own
   -- frame on every run, so nothing is stored at all and the last good size
   -- stands.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1000x400|1000x400" end
   end }, 1800, 1000)
   local absurd = CO.load_screen()
   CHECK(absurd ~= nil and absurd.win_on ~= nil and absurd.win_on[1] == 1536
         and absurd.win_on[2] == 825,
         "an impossibly large frame stores nothing -- the last good size stands")

   -- The inside of a window cannot be bigger than the outside.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1900x1100|1900x1100" end
   end }, 1800, 1000)
   local negative = CO.load_screen()
   CHECK(negative ~= nil and negative.win_on ~= nil and negative.win_on[1] == 1536,
         "a negative frame stores nothing either")

   -- The ceiling itself, from both sides. 1800-1400 and 1000-600 are exactly
   -- CO.FRAME_MAX; one pixel less client box on each axis is one pixel past it.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1400x600|1400x600" end
   end }, 1800, 1000)
   local atmax = CO.load_screen()
   CHECK(atmax ~= nil and atmax.win_on ~= nil and atmax.win_on[1] == 1800
         and atmax.win_on[2] == 1000,
         "a frame exactly at CO.FRAME_MAX is still believed")
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1399x599|1399x599" end
   end }, 1800, 1000)
   local overmax = CO.load_screen()
   CHECK(overmax ~= nil and overmax.win_on ~= nil and overmax.win_on[1] == 1800
         and overmax.win_on[2] == 1000,
         "one pixel past CO.FRAME_MAX is not, and the last good size stands")

   -- No asked size means no frame, and no frame means no answer. The caller
   -- always has one, but a client box stored as an outer size is the one
   -- outcome worth writing a guard for.
   CO.remember_screen({ GetTextField = function(self, name)
      if name == "Screen" then return "1920x1032" end
      if name == "WinSize" then return "1092x576|1092x576" end
   end })
   local noasked = CO.load_screen()
   CHECK(noasked ~= nil and noasked.win_on ~= nil and noasked.win_on[1] == 1800
         and noasked.win_on[2] == 1000,
         "without the size we asked for, nothing is stored rather than a client box")

   do
      local f = assert(io.open(path, "w"))
      f:write("# EdgeBreaker measured screen size - safe to delete\n")
      f:write("screenw=1920\nscreenh=1040\n"); f:close()
      local vstore = CO.load_screen()
      CHECK(vstore ~= nil and vstore.screen_w == 1920 and vstore.everoff == false,
            "a v1.10.0-2 file with no flag reads as on-primary")
   end

   -- Re-validated (constraint 4): this used to pass only because 10 is not a
   -- table, proving nothing about 10x10 being an unbelievable screen. Wrapped
   -- in a real store, it now exercises the actual believable_screen refusal.
   CHECK(CO.save_screen({ screen_w = 10, screen_h = 10 }) == false,
         "an unbelievable screen is refused, not written")
   local kept = CO.load_screen()
   CHECK(kept ~= nil and kept.screen_w == 1920 and kept.screen_h == 1040,
         "and the refused write left the good value alone")

   -- Garbage on disk reads as nothing, which lands on the default window.
   do
      local f = assert(io.open(path, "w"))
      f:write("this is not a screen size\n"); f:close()
      CHECK(CO.load_screen() == nil, "a mangled file reads as no measurement")
   end

   -- The two files do not disturb each other, in either direction.
   CHECK(CO.save_screen({ screen_w = 1366, screen_h = 728 }) == true, "save a screen")
   CO.save_settings({ units = "in", mode = "setback", side = "auto", percent = 80, size = 0.02 })
   local wstore = CO.load_screen()
   CHECK(wstore ~= nil and wstore.screen_w == 1366 and wstore.screen_h == 728,
         "saving settings leaves the screen size alone")
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

-- Sharp inside corners (v1.11.0). The checkbox is unitless and safe to carry
-- between runs (unlike start depth): it is visible on the dialog and only
-- ever APPLIED when Side = Inside -- CO.sharp_applies gates in Lua whatever
-- the stored field claims (spec 5).
CHECK(CO.serialize_settings({ units = "in", mode = "setback", side = "inside",
   percent = 80, size = 0.02, sharp = 1 }):find("sharp=1", 1, true) ~= nil,
      "sharp is a last-used setting")
CHECK(CO.apply_settings({ sharp = "1" }, IN).sharp == 1, "sharp=1 survives the file")
CHECK(CO.apply_settings({ sharp = "0" }, IN).sharp == 0, "sharp=0 survives the file")
CHECK(CO.apply_settings({}, IN).sharp == 0, "no sharp key seeds off")
CHECK(CO.apply_settings({ sharp = "banana" }, IN).sharp == 0, "garbage sharp seeds off")
CHECK(CO.apply_settings({ sharp = "1", units = "in" }, MM).sharp == 1,
      "sharp is unitless: carried even when the units changed")

-- The Side rule itself: Lua authoritative, the dropdown the complete detector.
CHECK(CO.sharp_applies("inside", 1) == true,  "inside + ticked applies")
CHECK(CO.sharp_applies("inside", "1") == true, "the dialog's text field form applies too")
CHECK(CO.sharp_applies("inside", 0) == false, "inside + unticked does not")
CHECK(CO.sharp_applies("auto", 1) == false,   "auto never applies, whatever the field says")
CHECK(CO.sharp_applies("outside", 1) == false, "outside never applies")
CHECK(CO.sharp_applies(nil, nil) == false,     "nothing applies on missing fields")

-- v1.12.0. The window is draggable, so the store now carries what the operator
-- left it at -- one size per monitor slot, because one size cannot serve both a
-- 5120-wide ultrawide and a laptop panel. The parse and the format are pure so
-- the whole file format is testable without touching %APPDATA%.
do
   CHECK(CO.believable_window(1800, 1000) == true, "a design-size window is believable")
   CHECK(CO.believable_window(320, 200) == true, "the smallest believable window")
   CHECK(CO.believable_window(319, 200) == false, "one pixel narrower is not believed")
   CHECK(CO.believable_window(320, 199) == false, "one pixel shorter is not believed")
   CHECK(CO.believable_window(40000, 1000) == false, "absurdly wide is not believed")
   CHECK(CO.believable_window(nil, nil) == false, "nothing is not believed")
   CHECK(CO.believable_window("wide", "tall") == false, "words are not believed")
   CHECK(CO.believable_window(-1800, -1000) == false, "negative is not believed")

   local w, h = CO.parse_window_field("1800x1000")
   CHECK(w == 1800 and h == 1000, "the field the page sends parses")
   local w2, h2 = CO.parse_window_field("  2560 X 1400  ")
   CHECK(w2 == 2560 and h2 == 1400, "whitespace and a capital X are tolerated")
   CHECK(CO.parse_window_field("") == nil, "an empty field is nothing")
   CHECK(CO.parse_window_field(nil) == nil, "a missing field is nothing")
   CHECK(CO.parse_window_field(1800) == nil, "a non-string is nothing, not a crash")
   CHECK(CO.parse_window_field("1800") == nil, "half a size is nothing")
   CHECK(CO.parse_window_field("100x100") == nil, "too small to be a window is nothing")
   CHECK(CO.parse_window_field("1800x1000 off") == nil,
         "the off suffix belongs to Screen, not here")

   -- v1.12.0 defect fix: the page now sends its CLIENT box twice -- as it is
   -- now, then as it was at load -- because Trident's window.outerWidth is
   -- frozen at the size the window was created at. CO.remember_screen turns the
   -- pair back into an outer size.
   local cw, ch, lw, lh = CO.parse_window_field("2396x1268|1796x868")
   CHECK(cw == 2396 and ch == 1268, "the current client box parses")
   CHECK(lw == 1796 and lh == 868, "and the load-time one behind the bar")
   local ow, oh, olw = CO.parse_window_field("1800x1000")
   CHECK(ow == 1800 and oh == 1000 and olw == nil,
         "a lone pair still parses, with no load box -- that is the pre-fix shape")
   CHECK(CO.parse_window_field("1796x868|") == nil, "a bar with nothing after it is nothing")
   CHECK(CO.parse_window_field("|1796x868") == nil, "a bar with nothing before it is nothing")
   CHECK(CO.parse_window_field("1796x868|1796x868|1796x868") == nil,
         "three pairs is nothing")
   CHECK(CO.parse_window_field("1796x868|100x100") == nil,
         "an unbelievable load box is nothing -- not a lone pair, which would " ..
         "store a client box as an outer size and shrink the window every run")
end

-- The store round-trips: what we write is what we read.
do
   local s = { screen_w = 5120, screen_h = 1368, everoff = true,
               win_on = { 1800, 1000 }, win_off = { 1092, 576 } }
   -- Every check past the first guards on `back ~= nil` (and, for the slot
   -- pairs, on the slot itself being non-nil) with a short-circuiting `and` --
   -- indexing straight into a nil would throw instead of failing the CHECK,
   -- and an uncaught throw here would kill the whole suite: the runner does
   -- not wrap dofile, so test_classify/test_memory/test_messages/
   -- test_dialog_size would silently never run at all.
   local back = CO.parse_screen_store(CO.format_screen_store(s))
   CHECK(back ~= nil, "a full store round-trips")
   CHECK(back ~= nil and back.screen_w == 5120 and back.screen_h == 1368,
         "the measurement survives")
   CHECK(back ~= nil and back.everoff == true, "the sticky off-primary flag survives")
   CHECK(back ~= nil and back.win_on ~= nil and back.win_on[1] == 1800
         and back.win_on[2] == 1000, "the on-primary size survives")
   CHECK(back ~= nil and back.win_off ~= nil and back.win_off[1] == 1092
         and back.win_off[2] == 576, "the off-primary size survives")

   local bare = CO.parse_screen_store(CO.format_screen_store(
      { screen_w = 1920, screen_h = 1032, everoff = false }))
   CHECK(bare ~= nil and bare.everoff == false, "a store with nothing remembered is valid")
   CHECK(bare ~= nil and bare.win_on == nil and bare.win_off == nil,
         "and reports both slots empty")

   -- The commonest real machine has only ever seen the primary, so only
   -- win_on is ever set -- and the mirror, off-primary only, works the same
   -- way in both directions.
   local single = CO.parse_screen_store(CO.format_screen_store(
      { screen_w = 1920, screen_h = 1032, everoff = false, win_on = { 1280, 700 } }))
   CHECK(single ~= nil and single.win_on ~= nil and single.win_on[1] == 1280
         and single.win_on[2] == 700, "a single-monitor store's win_on round-trips")
   CHECK(single ~= nil and single.win_off == nil,
         "...and win_off stays empty, not invented")

   local offonly = CO.parse_screen_store(CO.format_screen_store(
      { screen_w = 1920, screen_h = 1032, everoff = true, win_off = { 1092, 576 } }))
   CHECK(offonly ~= nil and offonly.win_off ~= nil and offonly.win_off[1] == 1092
         and offonly.win_off[2] == 576, "an off-primary-only store's win_off round-trips")
   CHECK(offonly ~= nil and offonly.win_on == nil,
         "...and win_on stays empty, not invented")
end

-- Backward compatibility. A v1.10.5-v1.11.0 file carries offprimary and
-- monitors and no win_* keys. It must read as "this machine has seen a second
-- monitor" (or not) with nothing remembered -- never as a crash, and never
-- losing the measurement, which is the expensive part to reacquire.
do
   local old = "# EdgeBreaker measured screen size - safe to delete\n" ..
               "screenw=1920\nscreenh=1032\noffprimary=1\nmonitors=2\n"
   local s = CO.parse_screen_store(old)
   CHECK(s ~= nil, "a v1.11.0 file still reads")
   CHECK(s ~= nil and s.screen_w == 1920 and s.screen_h == 1032, "its measurement is kept")
   CHECK(s ~= nil and s.everoff == true,
         "offprimary=1 seeds the sticky flag, so the machine does not relearn")
   CHECK(s ~= nil and s.win_on == nil and s.win_off == nil,
         "it remembers no window sizes, correctly")

   -- monitors is deliberately unread (v1.12.0 no longer has a use for it), so
   -- this is NOT a check that a "single-monitor" file behaves differently from
   -- a multi-monitor one -- offprimary=0 alone is what seeds never-off here.
   local onprim = CO.parse_screen_store("screenw=1920\nscreenh=1032\noffprimary=0\nmonitors=1\n")
   CHECK(onprim ~= nil and onprim.everoff == false,
         "offprimary=0 seeds everoff=false, regardless of the (unread) monitors count")
end

-- Garbage in the file is discarded, not repaired -- same rule as the screen
-- measurement. A stored size we cannot believe must not reach the constructor.
do
   CHECK(CO.parse_screen_store("") == nil, "an empty file is nothing")
   CHECK(CO.parse_screen_store(nil) == nil, "no text is nothing")
   CHECK(CO.parse_screen_store("screenw=100\nscreenh=100\n") == nil,
         "an unbelievable measurement voids the whole store")
   local s = CO.parse_screen_store("screenw=1920\nscreenh=1032\nwin_on_w=9\nwin_on_h=9\n")
   CHECK(s ~= nil and s.win_on == nil, "an unbelievable remembered size is dropped, not clamped")
   local s2 = CO.parse_screen_store("screenw=1920\nscreenh=1032\nwin_on_w=1800\n")
   CHECK(s2 ~= nil and s2.win_on == nil, "half a remembered size is no remembered size")
   local s3 = CO.parse_screen_store("screenw=1920\nscreenh=1032\nwin_off_w=x\nwin_off_h=y\n")
   CHECK(s3 ~= nil and s3.win_off == nil, "words are not a remembered size")
end

-- format_screen_store refuses to write a store it could not read back.
do
   CHECK(CO.format_screen_store(nil) == nil, "no store is no text")
   CHECK(CO.format_screen_store({ screen_w = 100, screen_h = 100 }) == nil,
         "an unbelievable measurement is not written")
   local t = CO.format_screen_store({ screen_w = 1920, screen_h = 1032, everoff = false,
                                      win_on = { 9, 9 } })
   CHECK(t ~= nil and t:find("win_on_w") == nil,
         "an unbelievable remembered size is not written either")
end
