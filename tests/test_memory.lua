-- Chamfer memory blob. What a chamfer remembers (shapes, size, mode, side,
-- percent, bit) travels as ONE framed line of key=value pairs inside the
-- blessed store's free text, so user-written notes around it survive every
-- rewrite. Pure halves only; where the blob lives is the Task 1 verdict and
-- the SDK read/write glue is Task 7.
local CO = EdgeBreaker

local mem = { size = 0.02, mode = "setback", side = "auto", percent = 80, tool = "T|9",
              units = "in", fps = { { cx = 1, cy = 1, xlen = 2, ylen = 2 } } }
local line = CO.encode_memory(mem)
CHECK(line:find("[EdgeBreaker-DATA]EB1|", 1, true) == 1, "frame + version prefix")
CHECK(line:find("[/EdgeBreaker-DATA]", 1, true) ~= nil, "closing frame")
CHECK(line:find("T|9", 1, true) == nil, "pipe in tool text sanitized")
local back = CO.decode_memory("user wrote this\n" .. line .. "\nand this")
CHECK(back ~= nil and back.size == 0.02 and back.percent == 80, "round-trip scalars")
-- A remembered SIZE is a length: without its units a 0.02 built in inches
-- would seed a millimetre job with 0.02 mm and look like the gadget forgot.
CHECK(back.units == "in", "round-trip units")
local seed_ok = CO.apply_settings(back, CO.unit_info(false))
CHECK(seed_ok.size == 0.02, "a remembered size seeds a job in the same units")
local seed_mm = CO.apply_settings(back, CO.unit_info(true))
CHECK(seed_mm.size ~= 0.02, "a remembered inch size is dropped in a mm job")
CHECK(CO.decode_memory("[EdgeBreaker-DATA]EB1|size=1[/EdgeBreaker-DATA]").units == nil,
      "a pre-units blob still parses, just without units")
NEAR(back.fps[1].xlen, 2, 1e-9, "round-trip fp")
CHECK(CO.decode_memory("no frame here") == nil, "no frame -> nil")
CHECK(CO.decode_memory("[EdgeBreaker-DATA]EB9|size=1[/EdgeBreaker-DATA]") ~= nil,
      "future version still parses known keys")
local text2 = CO.embed_memory("keep me\n" .. line, { size = 0.5, mode = "leg",
              side = "auto", percent = 20, fps = {} })
CHECK(text2:find("keep me", 1, true) == 1, "user text preserved")
CHECK(CO.decode_memory(text2).size == 0.5, "embed replaced in place")
CHECK(select(2, text2:gsub("%[EdgeBreaker%-DATA%]", "")) == 1, "exactly one frame after embed")

-- A chamfer cut at 0% must come back at 0%, not at the 80% default: the blob
-- writes the number as text and a "0" that reads as "nothing here" anywhere on
-- the way would rebuild the chamfer at a different depth than it was cut.
local mem0 = { size = 0.02, mode = "setback", side = "auto", percent = 0,
               units = "in", fps = {} }
local back0 = CO.decode_memory(CO.encode_memory(mem0))
CHECK(back0.percent == 0, "round-trip a 0% cut position")
CHECK(CO.apply_settings(back0, CO.unit_info(false)).percent == 0,
      "a remembered 0% seeds the rebuild at 0%")

-- Start depth (v1.6.0). Unlike size/mode/side/percent it is NOT mirrored into
-- the last-used settings file -- see test_settings.lua -- so the blob is the
-- only place it is ever remembered.
local memS = { size = 0.02, mode = "setback", side = "auto", percent = 80,
               units = "in", start = 0.25, fps = {} }
local backS = CO.decode_memory(CO.encode_memory(memS))
NEAR(backS.start, 0.25, 1e-12, "round-trip start depth")
NEAR(CO.apply_settings(backS, CO.unit_info(false)).start, 0.25, 1e-12,
     "a remembered start depth seeds a rebuild in the same units")

-- A v1.5.0 blob has no start key at all. decode_memory already ignores keys
-- it does not know, so old chamfers read back as "not set" and seed 0 --
-- backward compatible with no version check.
local v150 = CO.decode_memory("[EdgeBreaker-DATA]EB1|size=1|units=in[/EdgeBreaker-DATA]")
CHECK(v150.start == nil, "a v1.5.0 blob carries no start depth")
NEAR(CO.apply_settings(v150, CO.unit_info(false)).start, 0, 1e-12,
     "...and a v1.5.0 chamfer rebuilds at start depth 0")

-- Sharp (v1.11.0): remembered per chamfer, raw checkbox value -- the APPLIED
-- value is gated by CO.sharp_applies at run time, so a blob carrying sharp=1
-- with side=outside deterministically rebuilds without it (spec 5).
local memP = { size = 0.02, mode = "setback", side = "inside", percent = 80,
               units = "in", sharp = 1, fps = {} }
local backP = CO.decode_memory(CO.encode_memory(memP))
CHECK(backP.sharp == 1, "round-trip sharp=1")
CHECK(CO.apply_settings(backP, CO.unit_info(false)).sharp == 1,
      "a remembered sharp seeds the rebuild ticked")
local memQ = { size = 0.02, mode = "setback", side = "auto", percent = 80,
               units = "in", fps = {} }
CHECK(CO.decode_memory(CO.encode_memory(memQ)).sharp == 0,
      "an unset sharp encodes as the inert sharp=0, not as absence")
-- A pre-1.11.0 blob has no sharp key at all: reads back nil, seeds off.
local v1100 = CO.decode_memory("[EdgeBreaker-DATA]EB1|size=1|units=in[/EdgeBreaker-DATA]")
CHECK(v1100.sharp == nil, "an old blob carries no sharp key")
CHECK(CO.apply_settings(v1100, CO.unit_info(false)).sharp == 0,
      "...and an old chamfer rebuilds with sharp off")

-- The blob has to be readable from ANY pass: an operator who deletes pass 1 by
-- hand must not silently lose the chamfer's memory. Same content on each, so
-- the read side does not care which it finds.
CHECK(type(CO.sdk_write_memory_all) == "function", "there is a write-all")
CHECK(type(CO.sdk_find_toolpaths_by_slot) == "function", "and a find-all")
-- The blob itself is unchanged by multi-pass: no pass count is stored, because
-- it is derived from the size and the bit and a stored copy could contradict it.
local blob = CO.encode_memory({ fps = {}, size = 0.25, mode = "setback", side = "auto",
                                percent = 80, units = "in", start = 0, sharp = false,
                                tool = "90 deg V-bit" })
CHECK(blob:find("passes", 1, true) == nil, "no pass count is stored in the blob")
local back = CO.decode_memory(blob)
CHECK(back ~= nil and back.size == 0.25, "the blob still round-trips")
