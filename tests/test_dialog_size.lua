-- Dialog window size. A dialog cannot resize itself, so this choice is made
-- before it opens and a wrong answer is not recoverable at the machine.
--
-- Reported from the field 2026-07-29 (a VCarve Pro 12.510 user on a basic
-- monitor): every machine except HAAS-LAPTOP fell through to the 1800x1000
-- DESIGN size, which is bigger than a 1366x768 screen in BOTH directions --
-- and since the OK/Cancel bar is pinned to the bottom of the window, the
-- buttons land off-screen. The table listed the one small screen and defaulted
-- to the big one; it now lists the big screens and defaults to small.
--
-- Nothing here touches the SDK, so the whole choice is testable offline. There
-- were no tests on it at all before this file, which is why it shipped.
local CO = EdgeBreaker

-- The size an unlisted machine gets -- a stranger's machine, which is every
-- machine but ours. Must fit the smallest screen we intend to support.
local SMALLEST_W, SMALLEST_H = 1366, 768
CHECK(CO.DEFAULT_SIZE[1] <= SMALLEST_W and CO.DEFAULT_SIZE[2] <= SMALLEST_H,
      "the default window fits a 1366x768 screen")

-- Not merely fitting: a window flush to the screen edge has nowhere for the
-- title bar and sits under the taskbar. Leave real room on the height, which
-- is the dimension that hides the buttons.
CHECK(SMALLEST_H - CO.DEFAULT_SIZE[2] >= 40,
      "the default window leaves room for the taskbar and title bar")

-- Scaling is uniform and clamped at 1 (fitToWindow in EdgeBreakerDialog.htm),
-- so a window LARGER than the design size cannot be filled -- the layout would
-- sit at 1:1 in a corner. No entry may exceed the design size.
do
   local ok = true
   for name, s in pairs(CO.SCREEN_SIZES) do
      if s[1] > CO.DESIGN_SIZE[1] or s[2] > CO.DESIGN_SIZE[2] then
         ok = false
         print("        oversized entry: " .. tostring(name))
      end
   end
   CHECK(ok, "no listed screen exceeds the design size")
   CHECK(CO.DEFAULT_SIZE[1] <= CO.DESIGN_SIZE[1]
         and CO.DEFAULT_SIZE[2] <= CO.DESIGN_SIZE[2],
         "the default size does not exceed the design size")
end

-- An unknown machine, an empty name and no name at all all land on the default.
-- `nil` is the real case: os.getenv("COMPUTERNAME") returning nothing must not
-- throw, and must not pick a listed machine's size.
do
   local w, h = CO.dialog_size("SOMEBODY-ELSES-PC")
   CHECK(w == CO.DEFAULT_SIZE[1] and h == CO.DEFAULT_SIZE[2],
         "an unlisted machine gets the default size")
   local w2, h2 = CO.dialog_size(nil)
   CHECK(w2 == CO.DEFAULT_SIZE[1] and h2 == CO.DEFAULT_SIZE[2],
         "no computer name gets the default size")
   local w3, h3 = CO.dialog_size("")
   CHECK(w3 == CO.DEFAULT_SIZE[1] and h3 == CO.DEFAULT_SIZE[2],
         "an empty computer name gets the default size")
end

-- Our two machines keep the sizes they were verified at, and the lookup is
-- case-insensitive because COMPUTERNAME's case is not guaranteed.
do
   local w, h = CO.dialog_size("FASTTRACKS2026")
   CHECK(w == 1800 and h == 1000, "the ultrawide desktop gets the design size")
   local w2, h2 = CO.dialog_size("fasttracks2026")
   CHECK(w2 == 1800 and h2 == 1000, "the lookup is case-insensitive")
   local w3, h3 = CO.dialog_size("HAAS-LAPTOP")
   CHECK(w3 == 1280 and h3 == 720, "the shop laptop keeps its live-verified size")
end
