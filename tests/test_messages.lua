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
