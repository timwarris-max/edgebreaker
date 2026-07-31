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
-- size and at SCREEN_FRACTION of the screen, floored at the default size.
-- Nothing about it depends on which machine we are on.
do
   local w, h = CO.dialog_size(2880, 1712)
   CHECK(w == 1800 and h == 1000,
         "a big screen is capped at the design size (got " .. w .. "x" .. h .. ")")
   local w2, h2 = CO.dialog_size(5120, 1400)
   CHECK(w2 == 1800 and h2 == 1000, "the ultrawide is capped in both directions")
   local w3, h3 = CO.dialog_size(1366, 728)
   CHECK(w3 == 1280 and h3 == 700,
         "an ordinary laptop is held up by the floor, not cut to 80%")
   local w4, h4 = CO.dialog_size(1280, 680)
   CHECK(w4 == 1264 and h4 == 664,
         "1280x720 gets a window SHORTER than the old 700px guess -- the case that was broken")
   local w5, h5 = CO.dialog_size(1024, 728)
   CHECK(w5 == 1008 and h5 == 700,
         "a 1024-wide screen gets a window NARROWER than the old 1280px guess")
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

-- The floor. A fraction takes its biggest bite where there is least room, so
-- the default size holds the small machines up -- but it must never push the
-- window back off a screen that cannot hold it, which is the defect v1.10.0
-- existed to fix.
do
   local w, h = CO.dialog_size(1600, 900)
   CHECK(w == 1280 and h == 720,
         "1600x900 is floored on width and cut on height (got " .. w .. "x" .. h .. ")")
   local w2, h2 = CO.dialog_size(1024, 680)
   CHECK(w2 == 1008 and h2 == 664, "the floor never exceeds the screen less the margin")
   local ok = true
   for _, s in ipairs({ {640,480}, {800,600}, {1024,680}, {1280,680}, {1366,728} }) do
      local ww, hh = CO.dialog_size(s[1], s[2])
      if ww > s[1] - CO.SCREEN_MARGIN or hh > s[2] - CO.SCREEN_MARGIN then ok = false end
   end
   CHECK(ok, "the floor never puts the window off the screen")
end

-- Each dimension is worked out on its own: a wide, short screen must not get a
-- tall window just because its width reached a cap.
do
   local w, h = CO.dialog_size(3000, 800)
   CHECK(w == 1800 and h == 700, "width capped at the design size, height floored")
   local w2, h2 = CO.dialog_size(1200, 1400)
   CHECK(w2 == 1184 and h2 == 1000, "height capped, width measured")
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
   CHECK(w == 624 and h == 464, "a believable small screen gets a small window, not the default")
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
