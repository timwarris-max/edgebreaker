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

-- The window never exceeds the design size, because the page only scales DOWN
-- (fitToWindow): a bigger window would leave the layout sitting 1:1 in a corner.
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

-- v1.10.4: asking Windows. The parse and the DPI conversion are pure; the
-- popen shell around them is three guarded lines. Windows' answer looks like
--   APP 0 0 1920 1032
--   MON 1920 395 1366 720 0
--   MON 0 0 1920 1032 1
-- (the real Acer output, 2026-07-30) -- work areas, so the taskbar is already
-- gone, matching what Trident's availWidth/Height exclude.
do
   local acer = "APP 0 0 1920 1032\nMON 1920 395 1366 720 0\nMON 0 0 1920 1032 1\n"
   local m = CO.parse_monitor_output(acer)
   CHECK(m ~= nil and m.app.w == 1920 and m.app.h == 1032, "APP line parses")
   CHECK(m.primary.w == 1920 and m.primary.h == 1032, "the flagged primary parses")

   local laptop = "APP 1920 395 1366 720\nMON 1920 395 1366 720 0\nMON 0 0 1920 1032 1\n"
   local m2 = CO.parse_monitor_output(laptop)
   CHECK(m2 ~= nil and m2.app.w == 1366 and m2.app.h == 720,
         "Aspire on the panel: APP is the panel's work area")

   CHECK(CO.parse_monitor_output(nil) == nil, "no text is no answer")
   CHECK(CO.parse_monitor_output("") == nil, "empty text is no answer")
   CHECK(CO.parse_monitor_output("MON 0 0 1920 1032 1\n") == nil,
         "monitors without an APP line is half an answer, which is no answer")
   CHECK(CO.parse_monitor_output("APP 0 0 1920 1032\nMON 1920 395 1366 720 0\n") == nil,
         "an APP line without a flagged primary is no answer either")
   CHECK(CO.parse_monitor_output("APP 0 0 100 100\nMON 0 0 1920 1032 1\n") == nil,
         "an unbelievable APP size is discarded")
   CHECK(CO.parse_monitor_output("garbage\nAPP x y w h\n") == nil, "words are nothing")
end

-- The DPI conversion. Windows answers in its own pixels; Trident wants
-- logical x systemDPI/96, and the ratio between the STORED primary measurement
-- (Trident's unit) and Windows' primary line (Windows' unit) is exactly that
-- factor. Unscaled machines get 1; a missing store gets 1, which errs SMALLER
-- on scaled-up machines and can never overflow.
do
   local acer = CO.parse_monitor_output(
      "APP 1920 395 1366 720\nMON 1920 395 1366 720 0\nMON 0 0 1920 1032 1\n")
   local w, h = CO.screen_for_run(acer, 1920)
   CHECK(w == 1366 and h == 720, "unscaled machine: Windows' numbers pass through")
   -- The desktop: primary stored as 2880 (Trident) vs Windows' 1920 -> 1.5.
   local desk = CO.parse_monitor_output(
      "APP 0 0 1920 1152\nMON 0 0 1920 1152 1\n")
   local dw, dh = CO.screen_for_run(desk, 2880)
   CHECK(dw == 2880 and dh == 1728, "scaled machine: the 1.5 factor converts to Trident's unit")
   local nw, nh = CO.screen_for_run(desk, nil)
   CHECK(nw == 1920 and nh == 1152, "no stored measurement: factor 1, errs small, never overflows")
   local gw, gh = CO.screen_for_run(desk, 100000)
   CHECK(gw == 1920 and gh == 1152, "a ratio too strange to be a DPI scale is refused, factor 1")
   CHECK(CO.screen_for_run(nil, 1920) == nil, "no Windows answer is no run screen")
end

-- v1.10.5: the ask costs a second and a console blink, so a machine the last
-- ask saw as single-monitor never pays again -- its answer cannot vary. The
-- whole decision table:
do
   CHECK(CO.should_ask_windows(nil, false) == true, "never asked -> ask")
   CHECK(CO.should_ask_windows(1, false) == false, "one monitor -> never ask again")
   CHECK(CO.should_ask_windows(2, false) == true, "two monitors -> ask every run")
   CHECK(CO.should_ask_windows(3, false) == true, "three monitors -> ask every run")
   CHECK(CO.should_ask_windows(1, true) == true,
         "off-primary on a 'single-monitor' machine -> the count is stale, ask")
   CHECK(CO.should_ask_windows(nil, true) == true, "off-primary, never asked -> ask")

   local one = CO.parse_monitor_output("APP 0 0 1920 1032\nMON 0 0 1920 1032 1\n")
   CHECK(one ~= nil and one.count == 1, "the parse counts one monitor")
   local two = CO.parse_monitor_output(
      "APP 0 0 1920 1032\nMON 1920 395 1366 720 0\nMON 0 0 1920 1032 1\n")
   CHECK(two ~= nil and two.count == 2, "the parse counts two")
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
