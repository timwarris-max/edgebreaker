-- The window size. A dialog cannot resize itself, so this is decided before it
-- opens and there is no recovery at the machine -- which is why a wrong answer
-- here shipped once already (v1.9.0, reported from the field: the window opened
-- bigger than a stranger's screen and the OK button landed off the bottom).
--
-- v1.10.0 stops guessing. The page measures the screen and hands the numbers
-- back, so this is now pure arithmetic on those numbers and the whole rule is
-- testable offline.
local CO = EdgeBreaker

-- The rule, stated once: usable screen, less a margin, capped at the design
-- size and at SCREEN_FRACTION of the screen. Nothing about it depends on which
-- machine we are on, and as of v1.10.4 there is NO floor: Tim looked at the
-- floored 1280x700 filling 94% of the Acer's 1366-wide panel and called it
-- comically large, and the same window at 67% of the big monitor perfect.
-- Proportion is the product; the fraction rules at every size.
do
   local w, h = CO.dialog_size(2880, 1712)
   CHECK(w == 1800 and h == 1000,
         "a big screen is capped at the design size (got " .. w .. "x" .. h .. ")")
   local w2, h2 = CO.dialog_size(5120, 1400)
   CHECK(w2 == 1800 and h2 == 1000, "the ultrawide is capped in both directions")
   local w3, h3 = CO.dialog_size(1366, 720)
   CHECK(w3 == 1092 and h3 == 576,
         "the Acer's laptop panel gets 80%, not a floored 1280x700 (got " .. w3 .. "x" .. h3 .. ")")
   local w4, h4 = CO.dialog_size(1280, 680)
   CHECK(w4 == 1024 and h4 == 544, "1280x720 gets 80% too")
   local w5, h5 = CO.dialog_size(1024, 728)
   CHECK(w5 == 819 and h5 == 582, "so does a 1024-wide screen")
end

-- v1.10.1: the fraction cap. A 1920x1080 screen reached the design size on both
-- axes, so the dialog covered ~93% of the screen and read as fullscreen rather
-- than as a window. Seen on the Acer, 2026-07-30.
do
   local w, h = CO.dialog_size(1920, 1032)
   CHECK(w == 1536 and h == 825,
         "1080p gets 80% of the screen, not the design size (got " .. w .. "x" .. h .. ")")
   local ok = true
   for _, s in ipairs({ {1920,1032}, {1680,1000}, {2048,1152}, {2560,1400} }) do
      local ww, hh = CO.dialog_size(s[1], s[2])
      if ww > s[1] * CO.SCREEN_FRACTION or hh > s[2] * CO.SCREEN_FRACTION then ok = false end
      if ww > s[1] - CO.SCREEN_MARGIN or hh > s[2] - CO.SCREEN_MARGIN then ok = false end
   end
   CHECK(ok, "no screen big enough to be cut by the fraction exceeds it")
end

-- v1.10.4: the floor is GONE, and no screen -- however small -- ever gets a
-- window past the fraction or off the screen.
do
   CHECK(select("#", CO.dialog_size(1600, 900)) == 2, "dialog_size returns a pair")
   local w, h = CO.dialog_size(1600, 900)
   CHECK(w == 1280 and h == 720,
         "1600x900 gets 80% on both axes (got " .. w .. "x" .. h .. ")")
   local ok = true
   for _, s in ipairs({ {640,480}, {800,600}, {1024,680}, {1280,680}, {1366,728},
                        {1600,900}, {1920,1032} }) do
      local ww, hh = CO.dialog_size(s[1], s[2])
      if ww > s[1] - CO.SCREEN_MARGIN or hh > s[2] - CO.SCREEN_MARGIN then ok = false end
      if ww > s[1] * CO.SCREEN_FRACTION or hh > s[2] * CO.SCREEN_FRACTION then ok = false end
   end
   CHECK(ok, "no screen gets a window past the fraction or off the screen")
end

-- Each dimension is worked out on its own: a wide, short screen must not get a
-- tall window just because its width reached a cap.
do
   local w, h = CO.dialog_size(3000, 800)
   CHECK(w == 1800 and h == 640, "width capped at the design size, height at the fraction")
   local w2, h2 = CO.dialog_size(1200, 1400)
   CHECK(w2 == 960 and h2 == 1000, "height capped at the design size, width at the fraction")
end

-- CO.dialog_size never exceeds the design size. Since v1.12.0 that is a
-- statement about the GUESS, not about the window: fitToWindow() scales above 1
-- and the operator can drag the window larger, and CO.window_size honours a
-- remembered size past this cap. This pins the guess only.
do
   local ok = true
   for _, s in ipairs({ {1920,1080}, {2560,1440}, {5120,1440}, {1366,768} }) do
      local w, h = CO.dialog_size(s[1], s[2])
      if w > CO.DESIGN_SIZE[1] or h > CO.DESIGN_SIZE[2] then ok = false end
   end
   CHECK(ok, "no screen produces a window larger than the design size")
end

-- Anything we cannot believe falls back to the shipped default, silently. This
-- is the ONLY failure path in the whole feature: a cancelled probe, scripting
-- turned off, a mangled file and a garbage number all arrive here.
do
   local function is_default(w, h) return w == CO.DEFAULT_SIZE[1] and h == CO.DEFAULT_SIZE[2] end
   CHECK(is_default(CO.dialog_size(nil, nil)), "no measurement -> the default")
   CHECK(is_default(CO.dialog_size(1920, nil)), "half a measurement -> the default")
   CHECK(is_default(CO.dialog_size("", "")), "empty strings -> the default")
   CHECK(is_default(CO.dialog_size("wide", "tall")), "non-numeric -> the default")
   CHECK(is_default(CO.dialog_size(0, 0)), "zero -> the default")
   CHECK(is_default(CO.dialog_size(-1920, -1080)), "negative -> the default")
   CHECK(is_default(CO.dialog_size(320, 240)), "smaller than any real screen -> the default")
   CHECK(is_default(CO.dialog_size(999999, 999999)), "absurdly large -> the default")
   CHECK(is_default(CO.dialog_size({}, {})), "a table -> the default, not a crash")
end

-- Numeric strings ARE believable: the value arrives from a hidden field, so it
-- is a string every time it comes off a real dialog.
do
   local w, h = CO.dialog_size("1920", "1032")
   CHECK(w == 1536 and h == 825, "a measurement that arrived as text is used")
end

-- The floor is on the MEASUREMENT, not on the window. A believable-but-small
-- screen gets a small window: a dialog that is fully on screen beats a legible
-- one with OK off the bottom, which is the exact defect this feature exists to
-- fix. 640x480 is the smallest thing we will believe is a screen.
do
   CHECK(CO.believable_screen(640, 480) == true, "640x480 is the smallest believable screen")
   CHECK(CO.believable_screen(639, 480) == false, "one pixel narrower is not believed")
   CHECK(CO.believable_screen(640, 479) == false, "one pixel shorter is not believed")
   local w, h = CO.dialog_size(640, 480)
   CHECK(w == 512 and h == 384, "a believable small screen gets a small window, not the default")
end

-- v1.12.0: the ask-Windows apparatus is GONE, not disabled. It cost up to six
-- seconds on every run of a multi-monitor machine -- measured 5.57s of a 5.57s
-- total on 2026-07-31, from a command that takes 0.27s in a console -- because a
-- child process spawned from a GUI app pays a cold-start cost we cannot tune and
-- do not control on other people's machines. It could also come back EMPTY and
-- fall silently into primary-sized guessing, which is the wrong-monitor defect
-- it was built to fix.
--
-- The blink replaces it: a window can be asked where it is, and a window costs
-- nothing to open. Nothing here should ever spawn a process again.
CHECK(CO.PS_MONITORS == nil, "the PowerShell line is gone")
CHECK(CO.parse_monitor_output == nil, "its parser is gone")
CHECK(CO.should_ask_windows == nil, "the should-we-ask decision is gone")
CHECK(CO.screen_for_run == nil, "the DPI conversion is gone with it")
CHECK(CO.sdk_query_monitors == nil, "and the popen shell is gone")
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   -- Every pin in this block is an ABSENCE pin, so an empty or truncated slurp
   -- would pass all of them silently while proving nothing. Anchor on
   -- something that must be there. Line 16's alias is the right anchor twice
   -- over: it is also what makes the bare-name matching below correct.
   CHECK(src:find("local CO = EdgeBreaker", 1, true) ~= nil,
         "the gadget source really was read -- the pins below are absence pins " ..
         "and an empty read would pass every one of them")
   CHECK(src:find("io%.popen") == nil, "nothing in the gadget spawns a process")
   CHECK(src:find("powershell", 1, true) == nil, "and nothing shells out to PowerShell")

   -- The same five names again, this time across the WHOLE file. The nil-field
   -- pins above catch a returning DEFINITION; test_release.lua catches a
   -- returning CALL inside main(), which is the click path and the six
   -- seconds. Neither of them can see a call anywhere ELSE in the file -- and
   -- "anywhere else" is not hypothetical: CO.show_message was a caller of this
   -- apparatus in v1.10.4/v1.10.5 (CO.RUN_SCREEN carried it the monitor
   -- answer), so it is exactly where a half-applied revert lands. Such a call
   -- with no definition behind it leaves the field nil, leaves this suite
   -- green, and leaves "attempt to call a nil value" waiting for the next run
   -- in Aspire.
   --
   -- This matches a CALL -- the name, optional space, open paren -- and
   -- deliberately not a bare mention: EdgeBreaker.lua's own comments
   -- legitimately discuss what was deleted and why, and a pin that goes red
   -- because somebody EXPLAINED the deletion is a pin the next person deletes.
   -- Don't "simplify" it back to a plain name find.
   --
   -- Bare names, not "CO."-qualified: the file aliases CO to EdgeBreaker, so a
   -- returning call can be spelled either way and the bare name catches both.
   -- PS_MONITORS was a string constant, never called, so its entry here is
   -- belt-and-braces -- the io.popen pin above is what really catches that one
   -- coming back.
   for _, gone in ipairs({ "PS_MONITORS", "parse_monitor_output",
                           "should_ask_windows", "screen_for_run",
                           "sdk_query_monitors" }) do
      CHECK(src:find(gone .. "%s*%(") == nil,
            "nothing anywhere in the gadget calls " .. gone ..
            " -- the ask-Windows apparatus is deleted, not merely undefined")
   end
end

-- The per-machine table is GONE. It is the mechanism that caused the v1.9.0
-- defect -- our machines were in it and everyone else's screen was a guess --
-- and leaving it in place beside a measurement means two mechanisms deciding
-- one thing, which is how the bad default looked deliberate for four versions.
CHECK(CO.SCREEN_SIZES == nil, "the per-machine screen table is gone")
CHECK(CO.DEFAULT_SIZE[1] == 1280 and CO.DEFAULT_SIZE[2] == 700,
      "the default is unchanged -- it is now only the fallback")
CHECK(CO.DEFAULT_SIZE[1] <= CO.DESIGN_SIZE[1] and CO.DEFAULT_SIZE[2] <= CO.DESIGN_SIZE[2],
      "the fallback does not exceed the design size")

-- v1.12.0. The window is draggable and the size is remembered, so dialog_size
-- stops being the answer and becomes the OPENING GUESS. window_size is the
-- whole decision:
--
--                     | on primary                        | off primary
--   remembered exists | remembered, clamped to the screen | remembered, as-is
--   nothing remembered| dialog_size(screen)               | dialog_size(1366x720)
--
-- A remembered size is a CHOICE and beats every guess. It is still clamped on
-- the primary because a screen can shrink under a stored value (someone drops
-- their resolution) and OK off the bottom is the one outcome worth preventing.
-- It is NOT clamped to SCREEN_FRACTION or DESIGN_SIZE: a fraction is right for
-- a guess and wrong for a choice -- if the operator drags it to 95% of their
-- screen, that is the answer, not an error to correct.
do
   local w, h = CO.window_size({ 1800, 1000 }, 1920, 1032, false)
   CHECK(w == 1800 and h == 1000, "a remembered size is used as-is when it fits")

   local w2, h2 = CO.window_size({ 2400, 1300 }, 2560, 1400, false)
   CHECK(w2 == 2400 and h2 == 1300,
         "a remembered size past DESIGN_SIZE is honoured -- the page scales up now")

   local w3, h3 = CO.window_size({ 2000, 1200 }, 1920, 1032, false)
   CHECK(w3 == 1904 and h3 == 1016,
         "on the primary it is clamped to the screen less the margin (got " ..
         w3 .. "x" .. h3 .. ")")

   local w3b, h3b = CO.window_size({ 1900, 1000 }, 1920, 1032, false)
   CHECK(w3b == 1900 and h3b == 1000,
         "a remembered size that already fits is not touched by the clamp")

   local w4, h4 = CO.window_size({ 1800, 1000 }, 1366, 768, true)
   CHECK(w4 == 1800 and h4 == 1000,
         "off the primary a remembered size is NOT clamped -- the screen numbers " ..
         "describe a different monitor")
end

-- The table's fifth cell: ON the primary, but the screen measurement itself is
-- unbelievable. The clamp's guard (`not off and believable_screen(...)`) is
-- false either way, so this lands on the same "as-is" the table only names for
-- off-primary -- for a different reason. Pinning current behaviour, not
-- inventing a new one: see the comment beside the clamp in CO.window_size for
-- why a real remembered size can never actually arrive here next to a screen
-- number the store itself refused.
do
   local w, h = CO.window_size({ 1800, 1000 }, 100, 100, false)
   CHECK(w == 1800 and h == 1000,
         "on the primary, an unbelievable screen measurement skips the clamp -- " ..
         "the remembered size comes back exactly as stored")

   local w2, h2 = CO.window_size({ 1800, 1000 }, nil, nil, false)
   CHECK(w2 == 1800 and h2 == 1000,
         "no screen measurement at all is the same case -- still unclamped")
end

-- Nothing remembered: guess, and the guess depends only on whether we know
-- which screen we are on.
do
   local w, h = CO.window_size(nil, 1920, 1032, false)
   CHECK(w == 1536 and h == 825, "on the primary, nothing remembered -> the v1.10.4 rule")

   local w2, h2 = CO.window_size(nil, 5120, 1368, true)
   CHECK(w2 == 1092 and h2 == 576,
         "off the primary, nothing remembered -> the safe guess, NOT the primary's size")

   local w3, h3 = CO.dialog_size(CO.SAFE_SCREEN[1], CO.SAFE_SCREEN[2])
   CHECK(w3 == 1092 and h3 == 576,
         "the safe guess is the ordinary rule on the smallest likely panel, not a constant")
   CHECK(CO.SAFE_SCREEN[1] == 1366 and CO.SAFE_SCREEN[2] == 720,
         "and it is the USABLE screen -- taskbar already gone, like everything " ..
         "dialog_size is ever fed. 768 here would give 1092x614 and break the row above.")

   local w4, h4 = CO.window_size(nil, nil, nil, false)
   CHECK(w4 == CO.DEFAULT_SIZE[1] and h4 == CO.DEFAULT_SIZE[2],
         "no measurement at all still lands on the shipped default")
end

-- Garbage cannot reach the constructor. A remembered size we do not believe is
-- not a remembered size, and the run falls through to the guess.
do
   local w, h = CO.window_size({ 9, 9 }, 1920, 1032, false)
   CHECK(w == 1536 and h == 825, "an unbelievable remembered size falls through to the guess")
   local w2, h2 = CO.window_size({}, 1920, 1032, false)
   CHECK(w2 == 1536 and h2 == 825, "an empty table falls through too")
   local w3, h3 = CO.window_size("1800x1000", 1920, 1032, false)
   CHECK(w3 == 1536 and h3 == 825, "a string is not a pair, and is not a crash")
   CHECK(select("#", CO.window_size(nil, 1920, 1032, false)) == 2, "window_size returns a pair")
end

-- The off-primary safe guess fits every panel anyone is likely to have. This is
-- the assumption written down in the spec: nobody runs Aspire on a secondary
-- narrower than 1092. If they do, they drag it once and it sticks.
do
   local w, h = CO.window_size(nil, nil, nil, true)
   CHECK(w == 1092 and h == 576,
         "off primary with no measurement at all is still the safe guess, not the default")
   CHECK(w <= 1366 - CO.SCREEN_MARGIN and h <= 720 - CO.SCREEN_MARGIN,
         "and it fits the screen it was derived from")
end
