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
