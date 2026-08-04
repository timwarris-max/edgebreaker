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
