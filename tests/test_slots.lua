-- Slot identity. A chamfer is a number that appears in three places: the offset
-- layer name, the toolpath name marker, and the layer restriction inside the
-- template. These are the pure halves -- the SDK scan that finds them in a real
-- job is tested in test_sdk_offset.lua against a fake job.
local CO = EdgeBreaker

CHECK(CO.OFFSET_LAYER_PREFIX == "EdgeBreaker - Offset ",
      "layer prefix keeps its trailing space")
CHECK(CO.offset_layer_name(1) == "EdgeBreaker - Offset 01",
      "layer name pads to two digits")
CHECK(CO.offset_layer_name(12) == "EdgeBreaker - Offset 12",
      "layer name of a two-digit slot")
CHECK(CO.toolpath_marker(3) == "[EdgeBreaker 03]", "marker carries the padded slot")
CHECK(CO.toolpath_name(0.06, "in", 1) == "Chamfer 0.06 in [EdgeBreaker 01]",
      "toolpath name is size, units, then marker")

-- Round trips
CHECK(CO.slot_from_layer_name(CO.offset_layer_name(7)) == 7, "layer name round trip")
CHECK(CO.slot_from_toolpath_name(CO.toolpath_name(0.02, "in", 7)) == 7,
      "toolpath name round trip")

-- The legacy names must NOT read as a slot: they are reported, never rebuilt.
CHECK(CO.slot_from_layer_name(CO.LEGACY_OFFSET_LAYER) == nil,
      "unnumbered legacy layer is not a slot")
CHECK(CO.slot_from_toolpath_name("Chamfer 0.02 in " .. CO.LEGACY_TOOLPATH_MARKER) == nil,
      "unnumbered legacy marker is not a slot")

-- Near misses
CHECK(CO.slot_from_layer_name("EdgeBreaker - Offset 1") == nil, "unpadded slot rejected")
CHECK(CO.slot_from_layer_name("EdgeBreaker - Offset 01 copy") == nil, "trailing text rejected")
CHECK(CO.slot_from_layer_name("Layer 1") == nil, "unrelated layer rejected")
CHECK(CO.slot_from_layer_name(nil) == nil, "nil layer name rejected")
CHECK(CO.slot_from_layer_name(CO.offset_layer_name(0)) == nil, "slot 0 rejected")
CHECK(CO.slot_from_toolpath_name("Chamfer 0.02 in [EdgeBreaker 1]") == nil,
      "unpadded marker rejected")
CHECK(CO.slot_from_toolpath_name("my own profile") == nil, "unmarked toolpath rejected")
CHECK(CO.slot_from_toolpath_name(nil) == nil, "nil toolpath name rejected")

-- The escape hatch: strip the marker and the gadget must stop recognising it.
CHECK(CO.slot_from_toolpath_name("Chamfer 0.02 in") == nil,
      "renaming a toolpath to drop the marker releases it")
CHECK(CO.slot_from_toolpath_name("EdgeBreaker") == nil,
      "the bare word without brackets is NOT the marker")

-- Aspire suffixes duplicate toolpath names with " (1)" -- recorded in the
-- pre-1.4.0 tests and still true, so the marker must be found mid-name.
CHECK(CO.slot_from_toolpath_name("Chamfer 0.02 in " .. CO.toolpath_marker(5) .. " (1)") == 5,
      "a name Aspire suffixed for a duplicate still reads as its slot")
CHECK(CO.size_text_from_toolpath_name("Chamfer 0.02 in " .. CO.toolpath_marker(5) .. " (1)")
      == "0.02 in", "size text survives Aspire's duplicate suffix")
CHECK(CO.slot_from_toolpath_name(42) == nil, "non-string name is safely unslotted")

-- Size text, for the dropdown labels
CHECK(CO.size_text_from_toolpath_name("Chamfer 0.06 in [EdgeBreaker 01]") == "0.06 in",
      "size text read back out of a toolpath name")
CHECK(CO.size_text_from_toolpath_name("Chamfer 1.5 mm [EdgeBreaker 02]") == "1.5 mm",
      "size text in mm")
CHECK(CO.size_text_from_toolpath_name("Chamfer 0.06 in") == nil,
      "no marker means no size text")
CHECK(CO.size_text_from_toolpath_name("Profile 1") == nil, "unrelated name has no size text")

-- Next free slot reuses numbers freed by deletion
CHECK(CO.next_free_slot({}) == 1, "first chamfer is 1")
CHECK(CO.next_free_slot({ 1, 2 }) == 3, "contiguous slots append")
CHECK(CO.next_free_slot({ 2, 3 }) == 1, "a freed low number is reused")
CHECK(CO.next_free_slot({ 1, 3 }) == 2, "a hole is filled")
local all = {}
for n = 1, 99 do all[n] = n end
CHECK(CO.next_free_slot(all) == nil, "no free slot when all 99 are used")

-- Which bit a chamfer was built with lives in Aspire's tool-defaults store
-- under a per-slot key, because a ToolDBId cannot be written to text at all.
CHECK(CO.tool_defaults_key(1) == "slot01", "tool defaults key pads like the layer name")
CHECK(CO.tool_defaults_key(12) ~= CO.tool_defaults_key(1),
      "two chamfers never share a remembered bit")

-- The dropdown is passed to the dialog as one delimited string, the same way
-- Mode and Side already travel. v1.5.0 record: seven |-separated fields
-- "slot|label|relation|size|mode|side|percent", records joined by ";". The
-- relation badges the entry against the CURRENT selection (so the dialog can
-- colour the banner without asking Lua again) and the four seeds let it
-- re-seed the form when the user changes chamfer. Size text is free-form -- it
-- is lifted from a toolpath name the user can edit in Aspire -- so
-- encode_chamfer_list sanitises out both separators (see below).
local fpX = { cx = 1, cy = 1, xlen = 2, ylen = 2 }
local fpY = { cx = 9, cy = 1, xlen = 2, ylen = 1 }
local mem = { fps = { fpX }, size = 0.02, mode = "setback", side = "auto", percent = 80 }
local EPS = 1e-6

CHECK(CO.encode_chamfer_list({}, 1, {}, EPS) == "1|New chamfer (1)|new||||",
      "empty job offers only a new chamfer, with no seeds")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in" } }, 2, {}, EPS)
      == "1|Chamfer 1 - 0.06 in|nomem||||;2|New chamfer (2)|new||||",
      "a chamfer with no memory is 'nomem' and carries no seeds")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in", memory = mem } }, 2, { fpX }, EPS)
      == "1|Chamfer 1 - 0.06 in|match|0.02|setback|auto|80;2|New chamfer (2)|new||||",
      "a remembered chamfer carries its relation and its four seeds")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in", memory = mem } }, 2, { fpY }, EPS)
      :find("|differs|", 1, true) ~= nil,
      "a selection the chamfer does not remember reads 'differs'")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in" }, { slot = 2, size = nil } }, 3, {}, EPS)
      == "1|Chamfer 1 - 0.06 in|nomem||||;2|Chamfer 2 - offsets only|nomem||||;3|New chamfer (3)|new||||",
      "a chamfer whose toolpath was deleted reads 'offsets only'")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in" } }, nil, {}, EPS)
      == "1|Chamfer 1 - 0.06 in|nomem||||",
      "a full job offers no new chamfer")
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in" } }, 2, {}, EPS):find("Chamfer 01") == nil,
      "labels never show the zero padding")

-- Spec 8: a chamfer that remembers shapes none of which are still in the job
-- says so in its label, and is forced to the amber teach relation -- there is
-- nothing left to rebuild it FROM, so picking it must mean "teach it these".
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in", memory = mem, missing_all = true } },
                             2, { fpY }, EPS)
      == "1|Chamfer 1 - 0.06 in - shapes missing or moved|nomem|0.02|setback|auto|80;2|New chamfer (2)|new||||",
      "a chamfer whose shapes are all gone is labelled and forced to teach")

-- A toolpath's name is free text the user can edit in Aspire. Neither
-- separator may survive into a label, or a hand-renamed toolpath could forge
-- a selectable dropdown entry aimed at a slot the user never picked. Memory
-- rides in the toolpath's Notes, which is just as editable, so its seeds are
-- sanitised the same way.
CHECK(CO.encode_chamfer_list({ { slot = 1, size = "0.06 in; 3|evil" } }, 2, {}, EPS)
      == "1|Chamfer 1 - 0.06 in  3 evil|nomem||||;2|New chamfer (2)|new||||",
      "separators in a hand-edited toolpath name cannot forge a dropdown entry")
CHECK(select(2, CO.encode_chamfer_list({ { slot = 1, size = "a;b" } }, nil, {}, EPS):gsub(";", "")) == 0,
      "a sanitised single-entry list contains no separator at all")
CHECK(CO.encode_chamfer_list(
        { { slot = 1, size = "0.06 in",
            memory = { fps = {}, size = 0.02, mode = "set;back", side = "au|to", percent = 80 } } },
        nil, {}, EPS):find("set back", 1, true) ~= nil,
      "a separator hand-typed into the memory blob is scrubbed out of the seeds")

-- Refusals name the chamfers involved, as a sentence rather than a list dump.
CHECK(CO.name_slots({ 2 }) == "Chamfer 2", "one slot is singular")
CHECK(CO.name_slots({ 1, 3 }) == "Chamfers 1 and 3", "two slots join with 'and'")
CHECK(CO.name_slots({ 1, 2, 4 }) == "Chamfers 1, 2 and 4", "three or more use commas")

-- The banner's counts travel as one field too: how many shapes are selected,
-- which chamfers own the ones an add is leaving out, and how many the target
-- chamfer remembers.
CHECK(CO.encode_banner_facts({ excluded = {} }, 2, 0) == "sel=2;excluded=;mem=0",
      "banner facts with nothing excluded still carry every key")
CHECK(CO.encode_banner_facts({ excluded = { { slot = 1, count = 2 }, { slot = 3, count = 1 } } }, 5, 4)
      == "sel=5;excluded=1:2,3:1;mem=4",
      "excluded owners travel as slot:count pairs")
