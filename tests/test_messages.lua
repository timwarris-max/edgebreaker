-- Styled messages: the pure half. CO.show_message itself is three lines of SDK
-- contact and can only be proven at the machine; everything with logic in it
-- lives here.
local CO = EdgeBreaker

-- Kind -> style class, and an unknown kind lands on error rather than on
-- nothing: a message with a broken kind is far likelier to be a failure than a
-- success, and error is the one that must never be missed.
CHECK(select(1, CO.message_fields({ kind = "error", headline = "x" })).MKind == "m-error",
      "error kind maps to m-error")
CHECK(select(1, CO.message_fields({ kind = "warn", headline = "x" })).MKind == "m-warn",
      "warn kind maps to m-warn")
CHECK(select(1, CO.message_fields({ kind = "done", headline = "x" })).MKind == "m-done",
      "done kind maps to m-done")
CHECK(select(1, CO.message_fields({ kind = "wat", headline = "x" })).MKind == "m-error",
      "an unknown kind falls back to error")

-- Size is read off the message itself: rows present -> tall. No table, no
-- per-machine branch.
do
   local _, w, h = CO.message_fields({ kind = "error", headline = "x" })
   CHECK(w == CO.MESSAGE_SIZE_SHORT[1] and h == CO.MESSAGE_SIZE_SHORT[2],
         "a message without rows opens at the short size")
   local _, w2, h2 = CO.message_fields({ kind = "done", headline = "x",
                                         rows = { { "G", "0.0403 in" } } })
   CHECK(w2 == CO.MESSAGE_SIZE_TALL[1] and h2 == CO.MESSAGE_SIZE_TALL[2],
         "a message with rows opens at the tall size")
end

-- v1.10.1: and then it is clamped to the screen. The tall window is 700px on a
-- 720px-high laptop, so OK landed under the taskbar -- the same defect the setup
-- dialog fixed in v1.10.0. Safe to shrink because this page pins its bar and
-- scrolls the middle; it does not scale like the setup dialog.
do
   local rows = { { "G", "0.0403 in" } }
   local _, w, h = CO.message_fields({ kind = "done", headline = "x", rows = rows }, 1280, 680)
   CHECK(w == 900 and h == 664,
         "the tall window is cut to fit a 1280x720 laptop (got " .. w .. "x" .. h .. ")")
   local _, w2, h2 = CO.message_fields({ kind = "done", headline = "x", rows = rows }, 1920, 1032)
   CHECK(w2 == CO.MESSAGE_SIZE_TALL[1] and h2 == CO.MESSAGE_SIZE_TALL[2],
         "a screen with room to spare leaves the size alone")
   local _, w3, h3 = CO.message_fields({ kind = "error", headline = "x" }, 640, 480)
   CHECK(w3 == 624 and h3 == 464, "the smallest believable screen still gets a window that fits")
   -- Every failure path of load_screen arrives here as nil, and must not shrink
   -- anything: an unmeasured machine keeps exactly the v1.10.0 behaviour.
   for _, bad in ipairs({ { nil, nil }, { 1920, nil }, { "", "" }, { "wide", "tall" },
                          { 0, 0 }, { -1920, -1080 }, { 320, 240 }, { 999999, 999999 } }) do
      local _, bw, bh = CO.message_fields({ kind = "error", headline = "x" }, bad[1], bad[2])
      CHECK(bw == CO.MESSAGE_SIZE_SHORT[1] and bh == CO.MESSAGE_SIZE_SHORT[2],
            "an unbelievable screen leaves the message size untouched")
   end
end

-- Row encoding: same shape as BannerFacts, which is live-proven to survive a
-- hidden text field.
CHECK(CO.encode_rows(nil) == "", "no rows encodes to an empty string")
CHECK(CO.encode_rows({}) == "", "an empty row list encodes to an empty string")
CHECK(CO.encode_rows({ { "G", "0.0403 in" } }) == "G=0.0403 in", "one row")
CHECK(CO.encode_rows({ { "G", "0.04 in" }, { "Layer", "EdgeBreaker - Offset 02" } })
      == "G=0.04 in;Layer=EdgeBreaker - Offset 02", "two rows")

-- Nothing we generate today contains either delimiter. These pass anyway,
-- because "safe because we control the inputs" is the assumption that breaks
-- quietly the day someone adds a row carrying an Aspire string.
CHECK(CO.encode_rows({ { "K", "a;b" } }) == "K=a\\;b", "a semicolon in a value is escaped")
CHECK(CO.encode_rows({ { "K", "a=b" } }) == "K=a\\=b", "an equals in a value is escaped")
CHECK(CO.encode_rows({ { "K", "a\\b" } }) == "K=a\\\\b", "a backslash in a value is escaped")

-- The optional parts default to empty rather than nil: every one is written
-- straight into a text field, and AddTextField has no use for nil.
do
   local f = CO.message_fields({ kind = "error", headline = "Nothing was changed" })
   CHECK(f.MHead == "Nothing was changed", "the headline is carried through")
   CHECK(f.MBody == "" and f.MNote == "" and f.MRows == "",
         "body, note and rows default to empty strings")
   CHECK(f.MVersion == "v" .. CO.VERSION, "the version is carried through for the header")
end

-- ============================================================
-- Task 2: Capacity ceiling message
-- ============================================================
-- The ceiling message names both numbers. It replaces v1.12.0's "use a larger
-- bit or a smaller chamfer", which multi-pass makes almost unreachable: this
-- only fires past CO.MAX_PASSES.
-- 0.8 on a 1/4 in bit is genuinely past the ceiling -- 0.75 is not, it is the
-- exact eight-band bound and it cuts (Task 1).
local msg = CO.too_big_message("setback", 0.8, 90, 0.25)
CHECK(type(msg) == "string", "the ceiling message is a string")
CHECK(msg:find("8 passes", 1, true) ~= nil, "it says how many passes it tried")
CHECK(msg:find(CO.fmt_len(CO.display_max_size("setback", 90, 0.25)), 1, true) ~= nil,
      "it prints the biggest chamfer this bit can manage")
CHECK(msg:find(CO.fmt_len(CO.display_min_dia("setback", 0.8, 90)), 1, true) ~= nil,
      "it prints the bit that would do the job")
-- No number it cannot stand behind: a degenerate bit falls back to nil and the
-- caller uses the generic sentence rather than printing "can cut is 0".
CHECK(CO.too_big_message("setback", 0.8, 90, 0) == nil,
      "a degenerate bit produces no numbered message")

-- The post-run report named ONE layer of many (defect 3, found live
-- 2026-08-02): CO.offset_layer_name defaults band to 1, so a three-pass run
-- sent the operator looking for their geometry on one of its three layers.
do
   CHECK(CO.offset_layer_phrase(1, 1) == "'EdgeBreaker Offset 01-1'",
         "one pass names one layer, exactly as before")
   CHECK(CO.offset_layer_phrase(1, 3) ==
         "'EdgeBreaker Offset 01-1' to 'EdgeBreaker Offset 01-3'",
         "three passes name the range")
   CHECK(CO.offset_layer_phrase(7, 2) ==
         "'EdgeBreaker Offset 07-1' to 'EdgeBreaker Offset 07-2'",
         "the slot is carried into both ends")
end

-- CO.narrow_refusal: the refusal the narrow-break guard shows. Pure, so the
-- wording is pinned here and cannot drift. DRAFT strings - awaiting Tim's
-- redline - which is exactly why they are pinned: one target to change.
do
   local m = CO.narrow_refusal({ asked = 0.2, suggest = 0.15, n_sel = 17, unit = "in" })
   CHECK(m.kind == "error", "narrow_refusal: refusals are red")
   CHECK(m.headline == "Chamfer's too big for this artwork",
         "narrow_refusal: headline (got " .. tostring(m.headline) .. ")")
   CHECK(m.body:find("0.2 in", 1, true) ~= nil,
         "narrow_refusal: body names the size that was asked for")
   CHECK(m.body:find("The biggest that works here is 0.15 in", 1, true) ~= nil,
         "narrow_refusal: body names the size that fits")
   CHECK(#m.rows == 2, "narrow_refusal: two rows when a size is known")
   CHECK(m.rows[1][1] == "Selected" and m.rows[1][2] == "17 vector(s)",
         "narrow_refusal: first row counts the selection")
   CHECK(m.rows[2][1] == "Biggest that fits" and m.rows[2][2] == "0.15 in",
         "narrow_refusal: second row names the size")
   CHECK(m.plain:find("0.15 in", 1, true) ~= nil,
         "narrow_refusal: the fallback box carries the size too")

   -- size_from_w returns nil where the conversion divides by ~0. Print no
   -- number rather than the word nil, and still refuse.
   local n = CO.narrow_refusal({ asked = 0.2, suggest = nil, n_sel = 3, unit = "mm" })
   CHECK(n.kind == "error", "narrow_refusal: still refuses with no size to name")
   CHECK(n.body:find("Try", 1, true) == nil,
         "narrow_refusal: no 'Try ...' line when there is no size")
   CHECK(n.body:find("nil", 1, true) == nil, "narrow_refusal: never prints nil")
   CHECK(#n.rows == 1, "narrow_refusal: one row when no size is known")
   CHECK(n.plain:find("nil", 1, true) == nil, "narrow_refusal: nor in the fallback")

   -- Trailing zeros are stripped the same way every other length in the
   -- product is, so two messages about the same size read identically.
   local z = CO.narrow_refusal({ asked = 0.2000, suggest = 0.1500, n_sel = 1, unit = "in" })
   CHECK(z.body:find("0.2000", 1, true) == nil, "narrow_refusal: no trailing zeros")

   -- The OFFER (2026-08-13, Tim's call): the refusal can carry a second button
   -- that re-runs at the size that fits. `offer` is the caller's permission, not
   -- the message's own decision -- main() withholds it on a run that is ALREADY
   -- a retry, which is the only thing bounding the loop.
   local o = CO.narrow_refusal({ asked = 0.2, suggest = 0.15, n_sel = 2,
                                 unit = "in", offer = true })
   CHECK(o.choice == "Use 0.15 in",
         "narrow_refusal: the offer button names the size (got " .. tostring(o.choice) .. ")")
   CHECK(m.choice == nil,
         "narrow_refusal: no offer button unless the caller asks for one")

   -- Nothing to offer. A button reading "Use " with no number is worse than no
   -- button, and pressing it would re-run at exactly the size that just failed.
   local no_size = CO.narrow_refusal({ asked = 0.2, suggest = nil, n_sel = 2,
                                       unit = "in", offer = true })
   CHECK(no_size.choice == nil,
         "narrow_refusal: no offer button when there is no size to offer")
end

-- The choice travels to the page in its own field. An empty one is what every
-- display-only message sends, and the page reads that as "one button, OK".
do
   local f = CO.message_fields({ kind = "error", headline = "x", choice = "Use 0.15 in" })
   CHECK(f.MChoice == "Use 0.15 in", "message_fields: the choice label reaches the page")
   local plain = CO.message_fields({ kind = "error", headline = "x" })
   CHECK(plain.MChoice == "", "message_fields: no choice sends an empty field, never nil")
   local named = false
   for _, k in ipairs(CO.MESSAGE_FIELD_NAMES) do if k == "MChoice" then named = true end end
   CHECK(named, "message_fields: MChoice is in the list show_message actually sends")
end

-- ==================== The leftover-offsets offer (2026-08-14) ====================
-- A chamfer whose toolpath was deleted by hand leaves its offsets behind, and
-- removing them by hand is several clicks per layer (they are locked, too).
-- The offer rides on the OK button, exactly like the too-big refusal's, so the
-- answer is Aspire's own true/false and nothing is read back out of the page.
do
   local one = CO.leftover_message({ 3 })
   CHECK(one.choice == "Remove them",
         "leftover_message: the offer is on the button (got " .. tostring(one.choice) .. ")")
   CHECK(one.body:find("Chamfer 3", 1, true) ~= nil,
         "leftover_message: one leftover is named")
   CHECK(one.body:find("Chamfers", 1, true) == nil,
         "leftover_message: and not pluralised")
   CHECK(one.body:find("its toolpath", 1, true) ~= nil,
         "leftover_message: singular all the way through the sentence")

   local two = CO.leftover_message({ 2, 5 })
   CHECK(two.body:find("Chamfers 2 and 5", 1, true) ~= nil,
         "leftover_message: two are joined with 'and', no comma")
   CHECK(two.body:find("their toolpaths", 1, true) ~= nil,
         "leftover_message: and the sentence agrees with them")

   local three = CO.leftover_message({ 2, 3, 5 })
   CHECK(three.body:find("Chamfers 2, 3 and 5", 1, true) ~= nil,
         "leftover_message: three are a list ending in 'and'")

   -- The fallback box has ONE button, so there is nothing to press: it must not
   -- describe a choice it cannot offer, and must say what to do instead.
   CHECK(one.plain:find("Remove them", 1, true) == nil,
         "leftover_message: the plain fallback promises no button")
   CHECK(one.plain:find("Layers panel", 1, true) ~= nil,
         "leftover_message: the plain fallback names the manual fix")
   CHECK(CO.MESSAGE_KINDS[one.kind] ~= nil,
         "leftover_message: the kind is one the page knows")
end

-- What the operator is told when the layers would not go. Aspire's RemoveLayer
-- has never been proven here, so "the offsets are gone but the layers are not"
-- is a real outcome and gets its own honest sentence rather than silence.
do
   CHECK(CO.leftover_report(4, 0) == nil,
         "leftover_report: a clean sweep says nothing at all")
   CHECK(CO.leftover_report(0, 0) == nil,
         "leftover_report: and so does a sweep with nothing to do")
   local stuck = CO.leftover_report(2, 3)
   CHECK(stuck ~= nil and stuck.choice == nil,
         "leftover_report: the trouble report is display-only, not another offer")
   CHECK(stuck.body:find("3 ", 1, true) ~= nil,
         "leftover_report: it counts what is still there")
   CHECK(stuck.body:find("Layers panel", 1, true) ~= nil,
         "leftover_report: and names where to finish the job by hand")
   local one_stuck = CO.leftover_report(0, 1)
   CHECK(one_stuck.body:find("1 layer ", 1, true) ~= nil
         and one_stuck.body:find("1 layers", 1, true) == nil,
         "leftover_report: one is not '1 layers'")
end

-- A job holds up to 99 chamfers, so the naming needs an end -- a message box
-- listing forty numbers is a wall, not information, and it would overflow a
-- window nothing else here can resize.
do
   local four = CO.leftover_message({ 1, 2, 3, 4 })
   CHECK(four.body:find("Chamfers 1, 2, 3 and 4", 1, true) ~= nil,
         "leftover_message: four are still named")
   local five = CO.leftover_message({ 1, 2, 3, 4, 5 })
   CHECK(five.body:find("5 chamfers still have offsets", 1, true) ~= nil,
         "leftover_message: past that it counts them instead")
   CHECK(five.body:find("Chamfers 1", 1, true) == nil,
         "leftover_message: and names none of them")
   CHECK(five.body:find("their toolpaths are gone", 1, true) ~= nil,
         "leftover_message: the counted form still reads as plural")
end
