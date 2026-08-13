local CO = EdgeBreaker
CHECK(type(CO) == "table", "CO table exists")
CHECK(CO.SHOULDER_MARGIN == 0.90, "shoulder margin default")
CHECK(CO.TIP_MARGIN == 0.15, "tip margin default")
CHECK(#CO.PRESETS == 6 and CO.PRESETS[1] == 0 and CO.PRESETS[6] == 100, "six presets 0..100")

local A90 = CO.half_angle(90)   -- 45 deg in radians
NEAR(A90, math.rad(45), 1e-9, "half angle of 90 deg bit")
NEAR(CO.w_from_size("setback", 0.020, A90), 0.020,   1e-9, "setback mode: W = size")
NEAR(CO.w_from_size("face",    0.020, A90), 0.014142,1e-5, "face mode @90: W = L*sin(a)")
NEAR(CO.w_from_size("leg",     0.020, A90), 0.020,   1e-9, "leg mode @90: W = V*tan(a) = V")

local a = CO.half_angle(90)
local W = CO.w_from_size("setback", 0.020, a)
local g_lo, g_hi, d_max = CO.safe_band(0.25, W, a)
NEAR(d_max, 0.125,  1e-9, "D_max = (dia/2)/tan(a)")
NEAR(g_lo,  0.01875,1e-6, "g_lo = TIP_MARGIN*(dia/2)")
NEAR(g_hi,  0.0925, 1e-6, "g_hi = SHOULDER_MARGIN*(dia/2) - W")

-- 0% is the BOTTOM OF THE SAFE BAND, not the bit's literal tip: G is exactly
-- g_lo (TIP_MARGIN * radius = 0.01875) and D follows from it, so the shallowest
-- position still keeps the contact clear of the tip.
local cases = { {0,0.01875,0.03875}, {20,0.0335,0.0535}, {40,0.0483,0.0683},
                {60,0.0630,0.0830}, {80,0.0778,0.0978}, {100,0.0925,0.1125} }
for _, c in ipairs(cases) do
   local s = CO.solve(c[1], 0.25, W, a)
   NEAR(s.g, c[2], 5e-4, "G at " .. c[1] .. "%")
   NEAR(s.d, c[3], 5e-4, "D at " .. c[1] .. "%")
end
-- band + standoff at 100%
local s100 = CO.solve(100, 0.25, W, a)
NEAR(s100.band_lo, 0.0925, 5e-4, "band bottom = G/tan(a)")
NEAR(s100.band_hi, 0.1125, 5e-4, "band top = D")
NEAR(s100.standoff, s100.g,  1e-9, "standoff = G")

-- evaluate() with normal bit: six presets, ok
local r = CO.evaluate("setback", 0.020, 90, 0.25)
CHECK(r.ok == true, "0.25in bit, small chamfer: ok")
CHECK(#r.presets == 6, "six presets returned")
CHECK(r.presets[1].percent == 0 and r.presets[6].percent == 100, "preset percents carried")
-- 0 is a real cut position, not a missing value, and it is the one that lands
-- exactly on a band edge -- so pin it against g_lo rather than a copied number.
NEAR(r.presets[1].g, g_lo, 1e-9, "0% sits exactly on the bottom of the band")
CHECK(r.ok == true and r.reason == nil, "no reason when ok")

-- evaluate() with chamfer that now fits with multiple passes (was rejected in v1.12.0)
local big = CO.evaluate("setback", 0.120, 90, 0.25)  -- W=0.120 fits in 2 passes in multi-pass
CHECK(big.ok == true, "0.120 on a 1/4 in bit fits with multi-pass")
CHECK(big.passes == 2, "it takes two passes")
CHECK(#big.presets == 6, "all presets are offered when multi-pass")
CHECK(big.reason == nil, "no reason when ok")

-- polygonize: line span -> its two endpoints
local pl = CO.polygonize_span({ type="line", x1=0, y1=0, x2=3, y2=4 }, 0.001)
CHECK(#pl == 2 and pl[1][1] == 0 and pl[2][1] == 3 and pl[2][2] == 4, "line span -> 2 pts")

-- quarter-circle arc, r=1, centred on origin, (1,0) -> (0,1), mid at 45 deg
local s2 = math.sqrt(2) / 2
local pa = CO.polygonize_span({ type="arc", x1=1, y1=0, x2=0, y2=1, mx=s2, my=s2 }, 0.001)
CHECK(#pa >= 8, "arc sampled into >= 8 points")
NEAR(pa[1][1], 1, 1e-9, "arc starts at start point")
NEAR(pa[#pa][2], 1, 1e-9, "arc ends at end point")
local rmax_err = 0
for _, p in ipairs(pa) do
   rmax_err = math.max(rmax_err, math.abs(math.sqrt(p[1]^2 + p[2]^2) - 1))
end
CHECK(rmax_err < 1e-9, "every arc sample lies on the circle")

-- degenerate arc (mid point on the chord) -> straight line
local pd = CO.polygonize_span({ type="arc", x1=0, y1=0, x2=2, y2=0, mx=1, my=0 }, 0.001)
CHECK(#pd == 2, "collinear arc degrades to a line")

-- bezier with control points on the chord -> all samples on the line y=x
local pb = CO.polygonize_span({ type="bezier", x1=0, y1=0, x2=1, y2=1,
                                c1x=0.25, c1y=0.25, c2x=0.75, c2y=0.75 }, 0.001)
local bmax_err = 0
for _, p in ipairs(pb) do bmax_err = math.max(bmax_err, math.abs(p[1] - p[2])) end
CHECK(bmax_err < 1e-9, "degenerate bezier stays on the chord")
NEAR(pb[#pb][1], 1, 1e-9, "bezier ends at end point")

-- loop assembly: semicircle (r=1) + closing diameter line -> closed loop, area ~ pi/2
local loop = CO.polygonize({
   { type="arc",  x1=-1, y1=0, x2=1, y2=0, mx=0, my=1 },
   { type="line", x1=1,  y1=0, x2=-1, y2=0 },
}, 0.001)
CHECK(#loop >= 9, "loop has the arc's samples")
-- enabled in Task 2.3 (needs CO.signed_area):
NEAR(math.abs(CO.signed_area(loop)), math.pi / 2, 0.01, "semicircle loop area")

-- signed area: CCW positive, CW negative
NEAR(CO.signed_area({ {0,0},{10,0},{10,10},{0,10} }),  100, 1e-9, "CCW area +")
NEAR(CO.signed_area({ {0,10},{10,10},{10,0},{0,0} }), -100, 1e-9, "CW area -")

-- The offset geometry tests retired here in v1.3.0 (23 assertions). CO.offset_loop
-- was deleted: it mitred sharp corners without a limit (a 10 deg spur threw a point
-- 1.12 in past the corner on a 1/4" bit) and inverted any feature narrower than
-- twice the offset. Aspire's ContourGroup:Offset does both correctly, and it can
-- only be exercised inside Aspire. See the v1.3.0 spec.

-- direction classification: outer boundary vs inner opening
local function rect(x0,y0,w,h) return { pts = { {x0,y0},{x0+w,y0},{x0+w,y0+h},{x0,y0+h} } } end
local dirs = CO.classify_directions({ rect(0,0,10,10), rect(3,3,2,2) })
CHECK(dirs[1] == "outward", "outer boundary offsets outward")
CHECK(dirs[2] == "inward",  "inner opening offsets inward")
local d2 = CO.classify_directions({ rect(0,0,2,2), rect(5,0,2,2) })
CHECK(d2[1] == "outward" and d2[2] == "outward", "disjoint loops both outward")
CHECK(CO.classify_directions({ rect(0,0,2,2) })[1] == "outward", "lone loop outward")

-- IEEE-754 double encoder
local function tohex(s)
   return (s:gsub(".", function(ch) return string.format("%02x", string.byte(ch)) end))
end
local CASES = {
   { 0.03,   "b81e85eb51b89e3f" },   -- the real template's baked depth
   { 1.0,    "000000000000f03f" },
   { 0.1125, "cdccccccccccbc3f" },   -- spec worked example D at 100%
   { 0.0925, "ae47e17a14aeb73f" },   -- spec worked example G at 100%
   { 0.25,   "000000000000d03f" },
   { 0,      "0000000000000000" },
}
for _, c in ipairs(CASES) do
   CHECK(tohex(CO.encode_double(c[1])) == c[2],      "encode_double "      .. c[1])
   CHECK(tohex(CO.encode_double_pure(c[1])) == c[2], "encode_double_pure " .. c[1])
end

-- template binary format: depth patcher and filename parser
local f = assert(io.open("tests/fixtures/sample.ToolpathTemplate", "rb"))
local bytes = f:read("*a"); f:close()
CHECK(#bytes == 7056, "fixture read whole (binary mode)")

local off = CO.find_depth_offset(bytes)
CHECK(off == 2480, "depth value found at known offset")
CHECK(bytes:sub(off, off + 7) == CO.encode_double(0.03), "fixture's baked depth is 0.030")

local patched = CO.patch_template_depth(bytes, 0.1125)
CHECK(#patched == #bytes, "patch preserves length")
CHECK(patched:sub(off, off + 7) == CO.encode_double(0.1125), "new depth written")
CHECK(patched:sub(1, off - 1) == bytes:sub(1, off - 1), "bytes before the depth untouched")

-- A template states its depth TWICE: the _ppdCutDepth double (the form's Cut
-- Depth) and the "_mctddDepthValues" pass list behind Edit Passes. Aspire cuts
-- the PASS LIST. Patching only the double left every chamfer at the template's
-- saved depth -- live 2026-07-25, chamfers came out ~1/4 of the size asked for.
local function u16(s) return (s:gsub(".", "%0\0")) end
CHECK(bytes:find(u16("0.030000;"), 1, true) ~= nil, "fixture pass list mirrors its 0.030 depth")
CHECK(patched:find(u16("0.112500;"), 1, true) ~= nil, "patch rewrites the pass list")
CHECK(patched:find(u16("0.030000;"), 1, true) == nil, "stale pass depth is gone")

-- A user template saved with several passes must collapse to one: the gadget
-- writes a single full-depth V pass, and a stale count would misread the list.
local _, npe = bytes:find(u16("_mctddNumPasses"), 1, true)
local three = bytes:sub(1, npe + 4) .. string.char(3, 0, 0, 0) .. bytes:sub(npe + 9)
local collapsed = CO.patch_template_depth(three, 0.1125)
CHECK(collapsed:sub(npe + 5, npe + 8) == string.char(1, 0, 0, 0), "patch forces a single pass")

-- no anchor -> error, not garbage
local none, err = CO.find_depth_offset("not a template")
CHECK(none == nil and type(err) == "string", "missing anchor reports an error")

-- Start depth (v1.6.0): where the cut BEGINS, measured down from the top of
-- the stock. Identical binary layout to the cut depth -- an 8-byte LE double
-- 4 bytes after the UTF-16LE name -- and "_ppdStartDepthFormula" shares the
-- prefix exactly as "_ppdCutDepthFormula" does, so the same skip applies.
local soff = CO.find_start_depth_offset(bytes)
CHECK(soff == 2374, "start depth value found at known offset")
CHECK(bytes:sub(soff, soff + 7) == CO.encode_double(0), "fixture's baked start depth is 0")

local sp = CO.patch_template_start_depth(bytes, 0.25)
CHECK(#sp == #bytes, "start-depth patch preserves length")
CHECK(sp:sub(soff, soff + 7) == CO.encode_double(0.25), "new start depth written")
CHECK(sp:sub(1, soff - 1) == bytes:sub(1, soff - 1), "bytes before the start depth untouched")

-- The pass list carries its own copy of the start depth, exactly as it
-- carries its own copy of the cut depth. Patching only the form's double
-- is the mistake that shipped undersized chamfers on 2026-07-25.
local mstart = 6632
CHECK(bytes:sub(mstart, mstart + 7) == CO.encode_double(0), "fixture's pass-list start depth is 0")
CHECK(sp:sub(mstart, mstart + 7) == CO.encode_double(0.25), "patch rewrites the pass-list mirror")

-- The cut depth is a different number and must not move.
CHECK(sp:sub(off, off + 7) == bytes:sub(off, off + 7), "start-depth patch leaves the cut depth alone")

-- THE REGRESSION CONTRACT: a start depth of zero must reproduce v1.5.0
-- exactly, so it may not change a single byte.
CHECK(CO.patch_template_start_depth(bytes, 0) == bytes, "a zero start depth changes no bytes")

-- A template with no pass list at all is not an error: patch_pass_depths
-- already treats that as "the cut depth stands alone" and so does this.
local nolist = bytes:gsub(u16("_mctddStartDepth"), u16("_mctddSTARTdepth"), 1)
local nl = CO.patch_template_start_depth(nolist, 0.25)
CHECK(nl ~= nil and #nl == #nolist, "an absent pass-list mirror is tolerated, not an error")

-- no anchor -> error, not garbage
local snone, serr = CO.find_start_depth_offset("not a template")
CHECK(snone == nil and type(serr) == "string", "missing start-depth anchor reports an error")

-- Sharp inside corners (v1.11.0): two more fixed-size in-place patches, the
-- depth-patch class of edit. Codes and encodings pinned against the
-- Aspire-authored fixture in test_release.lua; here the patcher's own
-- behaviour on the shipped bytes.
local shf = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.ToolpathTemplate", "rb"))
local shipped_sharp = shf:read("*a"); shf:close()

-- The allowance needle really does collide with _ppdAllowanceFormula: the raw
-- needle hits twice, the finder resolves exactly one. If the collision ever
-- disappears the F\0 skip is untestable, so pin both counts.
do
   local needle = ("_ppdAllowance"):gsub(".", "%0\0")
   local n, init = 0, 1
   while true do
      local s, e = string.find(shipped_sharp, needle, init, true)
      if s == nil then break end
      n = n + 1; init = e + 1
   end
   CHECK(n == 2, "the raw _ppdAllowance needle hits twice (Formula collision is real)")
end
local al_off = CO.find_allowance_offset(shipped_sharp)
CHECK(type(al_off) == "number", "allowance finder resolves the collision to one offset")
CHECK(shipped_sharp:sub(al_off, al_off + 7) == CO.encode_double(0),
      "shipped template's allowance is 0.0 where the finder points")
local mv_off = CO.find_mv_value_offset(shipped_sharp)
CHECK(type(mv_off) == "number", "MV finder finds the int value")
CHECK(shipped_sharp:byte(mv_off) == 2, "shipped template's MV int reads 2 (On)")
local sh_off = CO.find_sharpen_offset(shipped_sharp)
CHECK(type(sh_off) == "number", "sharpen finder finds the flag byte")
CHECK(shipped_sharp:byte(sh_off) == 0, "shipped template's sharpen flag is off")
-- v1.13.0's third needle. Same 1-byte bool as the sharpen flag (type tag 02),
-- and off in the shipped template, so an unticked run is still untouched.
local sq_off = CO.find_square_offset(shipped_sharp)
CHECK(type(sq_off) == "number", "square-corners finder finds the flag byte")
CHECK(shipped_sharp:byte(sq_off) == 0, "shipped template's square-corners flag is off")

-- 2026-08-03: the patcher takes the SIDE. "inside" writes Machine Vectors 1,
-- "outside" writes 0, and there is no default -- the two codes aim the cut at
-- opposite sides of every vector in the job, so guessing is worse than failing.
local sharp     = CO.patch_template_sharp(shipped_sharp, "inside")
local sharp_out = CO.patch_template_sharp(shipped_sharp, "outside")
CHECK(type(sharp) == "string" and #sharp == #shipped_sharp,
      "sharp patch preserves the file length")
CHECK(type(sharp_out) == "string" and #sharp_out == #shipped_sharp,
      "outside sharp patch preserves the file length")
CHECK(CO.read_machine_vectors(sharp) == "inside",
      "patched MV reads back as Inside through the existing reader")
CHECK(CO.read_machine_vectors(sharp_out) == "outside",
      "patched MV reads back as Outside through the existing reader")
CHECK(sharp:byte(CO.find_sharpen_offset(sharp)) == 1, "sharpen flag reads back 1")
CHECK(sharp_out:byte(CO.find_sharpen_offset(sharp_out)) == 1,
      "outside run sets the same sharpen flag -- only Machine Vectors differs")
-- Both corner treatments, both sides. They cover opposite corners -- sharpening
-- the internal ones, squaring the external ones -- so neither stands in for the
-- other, and a run that sets only one comes out half-mitred. That is exactly
-- what the 2026-08-03 sitting saw before this existed.
CHECK(sharp:byte(CO.find_square_offset(sharp)) == 1,
      "inside run sets the square-corners flag too")
CHECK(sharp_out:byte(CO.find_square_offset(sharp_out)) == 1,
      "outside run sets the square-corners flag too")

-- Everything the sharp patch must NOT touch, on BOTH sides.
for _, c in ipairs({ { "inside", sharp }, { "outside", sharp_out } }) do
   local side, out = c[1], c[2]
   CHECK(out:sub(CO.find_allowance_offset(out), CO.find_allowance_offset(out) + 7)
         == CO.encode_double(0),
         side .. ": allowance is left untouched -- Aspire ignores it under sharpening")
   CHECK(CO.find_depth_offset(out) == CO.find_depth_offset(shipped_sharp),
         side .. ": sharp patch leaves the depth field where it was")
   CHECK(CO.read_template_layers(out)[1] == CO.read_template_layers(shipped_sharp)[1],
         side .. ": sharp patch leaves the layer restriction alone")
   CHECK(CO.read_template_units(out) == CO.read_template_units(shipped_sharp),
         side .. ": sharp patch leaves the units flag alone")
   -- Nothing else moves: the three fields are the only difference. The shipped
   -- MV code is 2 (On) and its three high bytes are already zero, so writing 1
   -- (Inside) or 0 (Outside) changes exactly ONE byte there; the sharpen flag
   -- goes 0 -> 1, and _ppdSquareCorners goes 0 -> 1. THREE on either side --
   -- a literal, so a future patch that quietly rewrote a fourth field could not
   -- compute its way past this. It was 2 until v1.13.0 added squaring.
   local diff = 0
   for i = 1, #shipped_sharp do
      if shipped_sharp:byte(i) ~= out:byte(i) then diff = diff + 1 end
   end
   CHECK(diff == 3,
         side .. ": only the three patched fields change (got " .. diff .. " differing bytes)")
end
-- Refusal: junk bytes name the missing tag.
local nope, nerr = CO.patch_template_sharp("junk", "inside")
CHECK(nope == nil and type(nerr) == "string", "junk bytes are refused with a reason")
-- Refusal: an unrecognised side. NOT a default -- a silent fallback here would
-- machine the wrong side of every vector, so the refusal IS the feature, and the
-- reason has to name both sides the operator is allowed to pick.
for _, bad_side in ipairs({ "\0NIL\0", true, "auto", "banana", "Inside", 1 }) do
   local arg = bad_side
   if arg == "\0NIL\0" then arg = nil end
   local r, why = CO.patch_template_sharp(shipped_sharp, arg)
   CHECK(r == nil and type(why) == "string"
         and why:find("Inside", 1, true) ~= nil and why:find("Outside", 1, true) ~= nil,
         "side " .. tostring(arg) .. " is refused, naming Inside and Outside")
end

-- Tool geometry now comes from Aspire's tool library, not a filename (1.1.0).
-- 1.2.0: renamed from tool_dia_in_job_units -- the same rules now serve a stock
-- thickness as well as a tool diameter. Both are lengths in the job's units.
NEAR(CO.length_in_job_units(0.25, false, false), 0.25, 1e-12, "inch bit, inch job")
NEAR(CO.length_in_job_units(6, true, true), 6, 1e-12, "mm bit, mm job")
NEAR(CO.length_in_job_units(6, true, false), 6 / 25.4, 1e-12, "mm bit in an inch job")
NEAR(CO.length_in_job_units(0.25, false, true), 6.35, 1e-12, "inch bit in a mm job")
NEAR(CO.length_in_job_units(CO.length_in_job_units(0.25, false, true), true, false),
     0.25, 1e-12, "round trip")
CHECK(CO.length_in_job_units(0, false, false) == nil, "zero diameter rejected")
CHECK(CO.length_in_job_units(-1, false, false) == nil, "negative diameter rejected")
CHECK(CO.length_in_job_units(nil, false, false) == nil, "nil diameter rejected")
CHECK(CO.length_in_job_units("0.25", false, false) == nil, "non-number diameter rejected")

-- Stock thickness travels the same path. An unusable value must come back nil,
-- because nil is what suppresses the depth warning -- a warning computed from
-- a bad thickness is worse than no warning.
NEAR(CO.length_in_job_units(0.75, false, false), 0.75, 1e-12, "3/4in stock, inch job")
NEAR(CO.length_in_job_units(18, true, false), 18 / 25.4, 1e-12, "18mm stock in an inch job")
NEAR(CO.length_in_job_units(0.75, false, true), 19.05, 1e-12, "3/4in stock in a mm job")
CHECK(CO.length_in_job_units(0 / 0, false, false) == nil, "NaN thickness rejected")

-- The two numbers the chamfer math cannot survive being wrong.
CHECK(CO.check_tool_geometry(90, 0.25) == true, "ordinary V-bit accepted")
CHECK(CO.check_tool_geometry(12.4, 0.25) == true, "narrow V-bit accepted")
CHECK(CO.check_tool_geometry(0, 0.25) == nil, "zero included angle rejected")
CHECK(CO.check_tool_geometry(180, 0.25) == nil, "180 degree included angle rejected")
CHECK(CO.check_tool_geometry(-30, 0.25) == nil, "negative angle rejected")
CHECK(CO.check_tool_geometry(nil, 0.25) == nil, "nil angle rejected")
CHECK(CO.check_tool_geometry(90, 0) == nil, "zero diameter rejected by geometry check")
CHECK(CO.check_tool_geometry(90, nil) == nil, "nil diameter rejected by geometry check")
local _, why = CO.check_tool_geometry(0, 0.25)
CHECK(type(why) == "string" and why ~= "", "rejection explains itself")

-- CO.same_bbox: value-based object fingerprint (centre + size) used by the
-- offset-layer refusal guard, since wrapper identity is live-disproven.
local A = { cx = 1.25, cy = -0.5, xlen = 3.0, ylen = 2.0 }
CHECK(CO.same_bbox(A, { cx = 1.25, cy = -0.5, xlen = 3.0, ylen = 2.0 }, 1e-6),
      "same_bbox: identical fingerprints match")
CHECK(CO.same_bbox(A, { cx = 1.25 + 1e-9, cy = -0.5, xlen = 3.0, ylen = 2.0 }, 1e-6),
      "same_bbox: sub-epsilon float noise still matches")
CHECK(not CO.same_bbox(A, { cx = 1.30, cy = -0.5, xlen = 3.0, ylen = 2.0 }, 1e-6),
      "same_bbox: shifted centre does not match")
CHECK(not CO.same_bbox(A, { cx = 1.25, cy = -0.5, xlen = 3.155, ylen = 2.155 }, 1e-6),
      "same_bbox: offset-sized copy (2g larger) does not match")
CHECK(not CO.same_bbox(A, { cx = 1.25, cy = -0.5, xlen = 3.0, ylen = 1.9 }, 1e-6),
      "same_bbox: one differing dimension is enough to reject")

-- CO.partition_loops: drop the gadget's own offsets from the selection instead
-- of refusing the run (v1.0.8; box-select-everything is the natural way to
-- re-run). A loop is "ours" when it SITS ON one of our layers.
--
-- It matched bounding boxes until 2026-08-05, and that is the defect this
-- replaced: the aspire chamfer strategy draws copies exactly on top of the
-- operator's vectors, because Aspire's chamfer engine has to cut the operator's
-- own edge -- so an original matched its own copy and was silently dropped.
-- Measured at the machine: two vectors selected, one seen.
--
-- The ids are GUID strings because that is what Aspire returns -- these two are
-- the real ones from the 2026-08-05 Q8 run, 'EdgeBreaker Offset 01-1' and
-- 'Layer 1'. A fixture keyed by small integers would pass while the product
-- failed live, which is the class of mistake this whole design exists to undo.
local OURS_ID = "17f31c3e-499d-4e70-98fd-98df4a7eea99"
local USER_ID = "484e94a6-a0a9-4984-8da5-2aeb9e8d9f7a"
local OWN = { [OURS_ID] = true }
local L_keep = { spans = { "user" }, bbox = { cx = 1, cy = 1, xlen = 2, ylen = 2 },
                 layer_id = USER_ID }
local L_ours = { spans = { "offset" }, bbox = { cx = 5, cy = 5, xlen = 10, ylen = 10 },
                 layer_id = OURS_ID }
local kept, skipped, unk = CO.partition_loops({ L_keep, L_ours }, OWN)
CHECK(#kept == 1 and kept[1] == L_keep and skipped == 1 and unk == 0,
      "partition: our offset dropped, user loop kept")

kept, skipped, unk = CO.partition_loops({ L_keep, L_ours }, {})
CHECK(#kept == 2 and skipped == 0 and unk == 0,
      "partition: no layers of ours yet keeps everything (first run)")

-- THE DEFECT, as a test. Byte-identical bounding boxes, one on our layer and
-- one on the operator's: the original survives and the copy does not. No
-- tolerance can separate these two, which is why the test is the right one.
local SAME = { cx = 3, cy = 3, xlen = 2, ylen = 2 }
local original = { spans = { "user" }, bbox = SAME, layer_id = USER_ID }
local copy     = { spans = { "copy" }, bbox = SAME, layer_id = OURS_ID }
kept, skipped, unk = CO.partition_loops({ original, copy }, OWN)
CHECK(#kept == 1 and kept[1] == original and skipped == 1 and unk == 0,
      "partition: a coincident copy is dropped and its original is kept")

-- Fail closed, both reasons. main() refuses when unknown > 0.
local L_no_layer = { spans = { "mystery" }, bbox = { cx = 1, cy = 1, xlen = 1, ylen = 1 } }
kept, skipped, unk = CO.partition_loops({ L_no_layer }, OWN)
CHECK(#kept == 0 and skipped == 0 and unk == 1,
      "partition: an unreadable layer id is unknown, never silently kept or dropped")

-- The bbox is still needed downstream for chamfer memory, so an unreadable one
-- is still a stop even though the guard itself no longer looks at it.
local L_no_bbox = { spans = { "mystery" }, layer_id = USER_ID }
kept, skipped, unk = CO.partition_loops({ L_no_bbox }, OWN)
CHECK(#kept == 0 and skipped == 0 and unk == 1,
      "partition: an unreadable bbox is unknown too -- memory still needs it")

kept, skipped, unk = CO.partition_loops({}, OWN)
CHECK(#kept == 0 and skipped == 0 and unk == 0, "partition: no loops, no drama")

local L2 = { spans = {}, bbox = { cx = 9, cy = 9, xlen = 4, ylen = 4 }, layer_id = USER_ID }
kept = CO.partition_loops({ L_keep, L2 }, OWN)
CHECK(kept[1] == L_keep and kept[2] == L2, "partition: kept loops preserve order")

-- CO.layer_is_ours: is this layer one the gadget owns and wipes? This is the
-- three-way test sdk_find_objects_by_fps has always done inline, lifted into
-- one place so the own-offsets guard can ask it too. The v1.4.x generation
-- matters: CO.doomed_layer wipes it on adopt, and the old two-way sweep rule
-- did not recognise it -- so a box-selected old-generation offset was kept as
-- input and then wiped out from under the run.
CHECK(CO.layer_is_ours(CO.offset_layer_name(3, 1)) == true,
      "layer_is_ours: the current banded name")
CHECK(CO.layer_is_ours(CO.V112_LAYER_PREFIX .. "03") == true,
      "layer_is_ours: the v1.5.0-1.12.0 unbanded name")
CHECK(CO.layer_is_ours(CO.OLD_LAYER_PREFIX .. "02") == true,
      "layer_is_ours: the v1.4.x generation, which the old sweep rule missed")
CHECK(CO.layer_is_ours(CO.LEGACY_OFFSET_LAYER) == true,
      "layer_is_ours: the pre-1.4.0 unnumbered layer")
CHECK(CO.layer_is_ours("Layer 1") == false,
      "layer_is_ours: someone else's layer is never ours")
CHECK(CO.layer_is_ours("EdgeBreaker Offset ") == false,
      "layer_is_ours: the bare prefix with no slot number is not a layer of ours")
CHECK(CO.layer_is_ours(CO.offset_layer_name(3, 1) .. " ") == false,
      "layer_is_ours: a trailing space is a different layer")
CHECK(CO.layer_is_ours(nil) == false, "layer_is_ours: a nil name is not ours")
CHECK(CO.layer_is_ours(42) == false, "layer_is_ours: a non-string is not ours")

-- CO.resolve_directions: per-run side override (spec 2026-07-25).
-- "outside"/"inside" force every loop; anything else falls back to the
-- nesting-based auto classification.
local rd_sq    = { pts = { {0,0},{10,0},{10,10},{0,10} } }
local rd_inner = { pts = { {2,2},{8,2},{8,8},{2,8} } }
local RD = { rd_sq, rd_inner }
local rd_auto = CO.classify_directions(RD)
local rd = CO.resolve_directions(RD, "outside")
CHECK(rd[1] == "outward" and rd[2] == "outward", "side=outside forces all outward")
rd = CO.resolve_directions(RD, "inside")
CHECK(rd[1] == "inward" and rd[2] == "inward", "side=inside forces all inward")
rd = CO.resolve_directions(RD, "auto")
CHECK(rd[1] == rd_auto[1] and rd[2] == rd_auto[2], "side=auto matches classify_directions")
rd = CO.resolve_directions(RD, nil)
CHECK(rd[1] == rd_auto[1] and rd[2] == rd_auto[2], "side=nil falls back to auto")
rd = CO.resolve_directions(RD, "banana")
CHECK(rd[1] == rd_auto[1] and rd[2] == rd_auto[2], "unknown side falls back to auto")

-- v1.3.0 summary helpers. Aspire's offset collapses a feature narrower than the
-- offset to nothing, which is the correct "too narrow to chamfer" answer -- but
-- a summary that still said "Offset 17 vector(s)" would read as "all of them"
-- and hide it. These two are pure so the reporting stays testable offline even
-- though the geometry no longer is.
CHECK(CO.skip_summary(0) == nil, "skip_summary: nothing skipped -> no sentence")
CHECK(CO.skip_summary(nil) == nil, "skip_summary: nil skipped -> no sentence")
local sk1 = CO.skip_summary(1)
CHECK(type(sk1) == "string" and sk1:find("1 vector(s)", 1, true) ~= nil,
      "skip_summary: one skipped names the count")
local sk3 = CO.skip_summary(3)
CHECK(type(sk3) == "string" and sk3:find("3 vector(s)", 1, true) ~= nil
      and sk3:find("too narrow", 1, true) ~= nil,
      "skip_summary: names the count and the reason")
CHECK(sk3:find("orange", 1, true) ~= nil,
      "skip_summary: tells the user where to look for the missing ones")
-- The aspire path draws its copies ON their originals, so there is no orange
-- offset to look beside and that clause would send the operator hunting for
-- something that was never drawn.
local ska = CO.skip_summary(3, "aspire")
CHECK(type(ska) == "string" and ska:find("3 vector(s)", 1, true) ~= nil
      and ska:find("too narrow", 1, true) ~= nil,
      "skip_summary: the aspire wording still names the count and the reason")
CHECK(ska:find("orange", 1, true) == nil,
      "skip_summary: and drops the orange-offset clause, which cannot apply there")
CHECK(CO.skip_summary(0, "aspire") == nil,
      "skip_summary: nothing skipped is still silent on the aspire path")
-- 2026-08-06 (Tim's ruling): a skip note that says "too narrow" without saying
-- what size WOULD work leaves the operator guessing. When the per-loop bisect
-- found a size that takes every skipped shape, the note names it - the same
-- "Try X or less" sentence the whole-run refusal uses - and the vague "try a
-- smaller size" fallback survives only for runs where no number could be found.
local sks = CO.skip_summary(2, "aspire", 0.12, "in")
CHECK(type(sks) == "string" and sks:find("Try 0.12 in or less", 1, true) ~= nil,
      "skip_summary: a known biggest-that-fits is named, aspire wording")
CHECK(sks:find("smaller chamfer size", 1, true) == nil,
      "skip_summary: the vague sentence gives way to the specific number")
local skb = CO.skip_summary(2, nil, 0.12, "in")
CHECK(type(skb) == "string" and skb:find("orange", 1, true) ~= nil
      and skb:find("Try 0.12 in or less", 1, true) ~= nil,
      "skip_summary: bands wording keeps the orange clause and adds the number")
CHECK(CO.skip_summary(2, "aspire"):find("smaller chamfer size", 1, true) ~= nil,
      "skip_summary: no number found keeps the old fallback sentence")
CHECK(CO.offset_count_phrase(17, 17) == "17 vector(s)",
      "count_phrase: nothing skipped stays a bare count")
CHECK(CO.offset_count_phrase(17, 14) == "14 of 17 vector(s)",
      "count_phrase: some skipped shows both numbers")
CHECK(CO.offset_count_phrase(17, 0) == "0 of 17 vector(s)",
      "count_phrase: all skipped is still honest")
CHECK(CO.offset_count_phrase(1, 1) == "1 vector(s)",
      "count_phrase: one vector uses the same (s) form as every other message")

-- CO.dialog_size moved to tests/test_dialog_size.lua on 2026-07-29. The two
-- assertions here required an unknown machine to get the DESIGN size, which is
-- the defect a user reported from the field -- they pinned it as correct.

-- Spec 9, the compatibility contract, asserted DIRECTLY: with the feature off
-- the pipeline's bytes are identical to composing the three patches by hand,
-- called the same way. Not "close" -- identical, the v1.6.0 "at S = 0" pattern.
-- (The bytes themselves are no longer v1.10.x bytes -- the layer restriction
-- is the v1.13.0 banded form by design -- only the composition contract holds.)
do
   local base = CO.patch_template_layer(
      CO.patch_template_start_depth(
         CO.patch_template_depth(shipped_sharp, 0.0838), 0.05), 3, 1)
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, nil, "in") == base,
         "sharp off: patch_template_run is byte-identical to the old pipeline")
   -- 2026-08-03: the sharp argument carries the SIDE, not a bare yes.
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "inside", "in")
         == CO.patch_template_sharp(base, "inside"),
         "sharp inside: exactly the old pipeline plus the inside sharp patch")
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "outside", "in")
         == CO.patch_template_sharp(base, "outside"),
         "sharp outside: exactly the old pipeline plus the outside sharp patch")
   -- The exact bytes each side produces, asserted against the fields themselves
   -- rather than against patch_template_sharp, so a bug in the patcher cannot
   -- make both halves of the comparison wrong together.
   --
   -- These once said "sharp inside is untouched by the outside work" -- the
   -- v1.13.0 contract that an inside run still produced its v1.11.0 bytes. That
   -- contract is DELIBERATELY retired (2026-08-03): squaring external corners
   -- is not an outside-only concern, so both sides now set _ppdSquareCorners.
   -- The inside cut changes as a result, which sitting check B6 exists to look
   -- at. Nothing about it was measured before -- v1.11.0's sitting checked leg
   -- widths, never corners.
   local ins = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "inside", "in")
   local outs = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "outside", "in")
   local mv_i, sh_i = CO.find_mv_value_offset(base), CO.find_sharpen_offset(base)
   local sq_i = CO.find_square_offset(base)
   local function hand(mv)
      local b = base:sub(1, mv_i - 1) .. string.char(mv, 0, 0, 0) .. base:sub(mv_i + 4)
      b = b:sub(1, sh_i - 1) .. string.char(1) .. b:sub(sh_i + 1)
      return b:sub(1, sq_i - 1) .. string.char(1) .. b:sub(sq_i + 1)
   end
   CHECK(ins == hand(1),
         "sharp inside: base + MV byte 1 + sharpen byte 1 + square byte 1")
   CHECK(outs == hand(0),
         "sharp outside: base + MV byte 0 + sharpen byte 1 + square byte 1")
   CHECK(ins ~= outs, "the two sides really do produce different bytes")
   -- A caller that still passes a boolean gets a refusal, not an inside cut on
   -- an outside chamfer.
   local br, berr = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, true, "in")
   CHECK(br == nil and type(berr) == "string" and berr:find("Outside", 1, true) ~= nil,
         "the old boolean `true` is refused by the pipeline, not silently sharpened inside")
end
do
   local bad, err = CO.patch_template_run("junk", 0.1, 0, 1, 1, nil, "in")
   CHECK(bad == nil and type(err) == "string", "pipeline propagates a patch failure")
end

-- R2: the sharp-run offset shift. On a sharp run the offset loops are drawn
-- shifted by the bit's own radius at the cut depth (spec 15a fact 7, measured
-- 2026-07-31, two bits) -- this is what stands in for the allowance R1 deleted.
NEAR(CO.sharp_offset_shift(0.0953, 90), 0.0953, 1e-6,
     "sharp shift, 90 deg bit: r = D*tan(45) = D")
NEAR(CO.sharp_offset_shift(0.0953, 60), 0.0953 * math.tan(math.rad(30)), 1e-6,
     "sharp shift, 60 deg bit: r = D*tan(30)")

-- Finding 2 (2026-07-31 review): the algebraic invariant the whole shift
-- design rests on. s.d = (W + s.g) / tan(a), so shifting s.d back by
-- tan(a) (== CO.sharp_offset_shift(s.d, angle)) always recovers exactly
-- W + s.g -- so the sharp distance is always W from the wall, for ANY
-- bit/size/percent/angle. If a future edit ever flips a sign or swaps g/d,
-- this catches it immediately rather than waiting on a live sitting.
--
-- 2026-08-03: stated through CO.sharp_offset_distance and swept over BOTH
-- directions. The magnitude is W either way; dir decides which side of the
-- wall it lands on, which is exactly what band_offset_distance is for.
do
   local combos = {
      { dia = 0.5,   W = 0.05, percent = 0,   deg = 90 },
      { dia = 0.5,   W = 0.05, percent = 100, deg = 90 },
      { dia = 0.25,  W = 0.02, percent = 50,  deg = 60 },
      { dia = 1.0,   W = 0.10, percent = 20,  deg = 30 },
      { dia = 0.375, W = 0.03, percent = 80,  deg = 120 },
   }
   for _, c in ipairs(combos) do
      local a = CO.half_angle(c.deg)
      local s = CO.solve(c.percent, c.dia, c.W, a)
      for _, dir in ipairs({ "inward", "outward" }) do
         NEAR(CO.sharp_offset_distance(dir, s.g, s.d, c.deg),
              CO.band_offset_distance(dir, -c.W), 1e-9,
              string.format("sharp invariant holds %s: dia=%g W=%g pct=%d deg=%d",
                             dir, c.dia, c.W, c.percent, c.deg))
      end
      -- Inward is still, byte for byte, the number the old inlined `+` gave.
      CHECK(CO.sharp_offset_distance("inward", s.g, s.d, c.deg)
            == CO.band_offset_distance("inward", s.g) + CO.sharp_offset_shift(s.d, c.deg),
            string.format("inward is EXACTLY the old dist + shift: dia=%g W=%g pct=%d deg=%d",
                           c.dia, c.W, c.percent, c.deg))
   end
end

-- ============================================================
-- Multi-pass (v1.13.0)
-- ============================================================
-- A 1/4 in 90 deg bit is the calibration case throughout: r = 0.125, so the
-- usable flute window is (SHOULDER_MARGIN - TIP_MARGIN) * r = 0.09375 wide.
-- The solver's condition is STRICT, so a band of exactly 0.09375 is refused.
local A45 = CO.half_angle(90)

CHECK(CO.MAX_PASSES == 8, "the ceiling is 8 passes")

CHECK(CO.pass_count(0.25, 0.09, A45) == 1, "0.09 fits one pass on a 1/4 in 90 deg bit")
CHECK(CO.pass_count(0.25, 0.094, A45) == 2, "0.094 just misses one pass")
CHECK(CO.pass_count(0.25, 0.25, A45) == 3, "a 0.25 chamfer takes three passes")
CHECK(CO.pass_count(0.25, 0.5, A45) == 6, "a 0.5 chamfer takes six passes")
-- 0.75 / 8 is EXACTLY 0.09375 -- eight bands that exactly fill the usable flute.
-- That is ACCEPTED (Tim's ruling 2026-08-02): TIP_MARGIN and SHOULDER_MARGIN
-- already ARE the safety, so the boundary is the limit, not a step past it.
-- Decided by CO.FIT_EPS, never by which way the last bit of a double rounded --
-- here 0.90*r - b and 0.15*r differ by 3.5e-18 and the sign of that is luck.
CHECK(CO.pass_count(0.25, 0.75, A45) == 8, "a band that exactly fills the flute is accepted")
CHECK(CO.pass_count(0.25, 0.76, A45) == nil, "genuinely over the ceiling is refused")
CHECK(CO.pass_count(0.25, 0.7, A45) == 8, "0.7 is a ceiling case that still fits")

NEAR(CO.band_width(0.25, 3), 0.0833333, 1e-6, "band width is W/N")

-- Every pass uses exactly one band's worth of flute -- contact does not
-- accumulate down the passes. This is the number the dialog prints.
NEAR(CO.band_width(0.25, 3), 0.25 / 3, 1e-12, "band width is the flute used per pass")

-- Pass geometry. Upper passes have a NEGATIVE offset: the tool axis sits over
-- the part with its tip buried at the band boundary. Only the final pass stands
-- off in the waste.
local W3, N3 = 0.25, 3
local b3 = CO.band_width(W3, N3)
local G3 = CO.solve(80, 0.25, b3, A45).g
local p1 = CO.pass_geometry(1, N3, W3, G3, A45)
local p2 = CO.pass_geometry(2, N3, W3, G3, A45)
local p3 = CO.pass_geometry(3, N3, W3, G3, A45)
NEAR(p1.offset, b3 - W3, 1e-9, "pass 1 offsets into the part")
NEAR(p2.offset, 2 * b3 - W3, 1e-9, "pass 2 offsets into the part, less far")
NEAR(p3.offset, G3, 1e-9, "the final pass stands off in the waste by G")
CHECK(p1.offset < 0 and p2.offset < 0 and p3.offset > 0, "only the final offset is positive")
NEAR(p1.depth, b3 / math.tan(A45), 1e-9, "pass 1 depth is one band down")
NEAR(p2.depth, 2 * b3 / math.tan(A45), 1e-9, "pass 2 depth is two bands down")
NEAR(p3.depth, (W3 + G3) / math.tan(A45), 1e-9, "the final depth is the whole chamfer")
CHECK(p1.depth < p2.depth and p2.depth < p3.depth, "passes get deeper, top down")

-- Every apex lies ON the chamfer face: depth = (offset + W)/tan a, for all k.
for _, p in ipairs({ p1, p2, p3 }) do
   NEAR(p.depth, (p.offset + W3) / math.tan(A45), 1e-9, "apex sits on the chamfer face")
end

-- THE CONTRACT. At N = 1 the arithmetic is v1.12.0's, to the last bit.
local W1 = CO.w_from_size("setback", 0.06, A45)
local s1 = CO.solve(80, 0.25, W1, A45)
local one = CO.pass_geometry(1, 1, W1, s1.g, A45)
CHECK(one.offset == s1.g, "N=1 offset is exactly G, not merely close")
CHECK(one.depth == s1.d, "N=1 depth is exactly v1.12.0's depth, not merely close")

-- solve_band picks G from the BAND (flute contact spans G..G+b) but takes the
-- depth from the WHOLE chamfer (the final apex sits on the face at x = G). At
-- b == W the two are the same number, which is why v1.12.0 could use solve's d.
local sb = CO.solve_band(80, 0.25, W3, b3, A45)
NEAR(sb.g, CO.solve(80, 0.25, b3, A45).g, 1e-12, "solve_band takes G from the band")
NEAR(sb.d, (W3 + sb.g) / math.tan(A45), 1e-12, "solve_band takes depth from the chamfer")
CHECK(sb.d > CO.solve(80, 0.25, b3, A45).d, "the band solver's own depth is too shallow")
local sb1 = CO.solve_band(80, 0.25, W1, W1, A45)
CHECK(sb1.g == s1.g and sb1.d == s1.d, "solve_band at b == W is exactly solve")

-- ============================================================
-- Task 2: Capacity ceiling and its message
-- ============================================================
-- Displayed capacity figures round in a FIXED direction, never to nearest: a
-- stated maximum must be a size that is actually accepted when typed back in,
-- and a suggested diameter must be a bit that actually works. The 1e-9 absorbs
-- binary representation error (0.0925 * 10000 is 924.99999999999996 in a
-- double) without reaching any difference a person could measure.
NEAR(CO.floor4(0.0925), 0.0925, 1e-12, "floor4 does not eat a representable value")
NEAR(CO.floor4(0.09259), 0.0925, 1e-12, "floor4 rounds down")
NEAR(CO.ceil4(0.09251), 0.0926, 1e-12, "ceil4 rounds up")
CHECK(CO.fmt_len(0.7500) == "0.75", "fmt_len strips trailing zeros")
CHECK(CO.fmt_len(0.0938) == "0.0938", "fmt_len keeps significant digits")

NEAR(CO.capacity_fraction(), 0.75, 1e-12, "capacity is derived from the two margins")

-- THE INVARIANT THIS TASK EXISTS FOR: whatever maximum is printed must be a
-- size the gadget accepts when it is typed straight back in. Checked on bits
-- whose eight-pass bound lands exactly on four decimals -- the case where a
-- stated maximum is most likely to be a lie -- and the bound is stated as-is,
-- because a band that exactly fills the flute fits (Task 1, CO.FIT_EPS).
local function max_is_cuttable(dia)
   local a = CO.half_angle(90)
   local m = CO.display_max_size("setback", 90, dia)
   return m ~= nil and CO.pass_count(dia, CO.w_from_size("setback", m, a), a) ~= nil, m
end
for _, dia in ipairs({ 0.25, 0.3125, 0.4375, 0.5, 0.625 }) do
   local okmax, m = max_is_cuttable(dia)
   CHECK(okmax, "the stated maximum for a " .. dia .. " bit is a size it accepts")
   CHECK(m > 0, "and it is a positive size")
end
NEAR(select(2, max_is_cuttable(0.25)), 0.75, 1e-12,
     "the 1/4 in maximum is the exact eight-band bound, stated as-is")
NEAR(select(2, max_is_cuttable(0.5)), 1.5, 1e-12, "and the 1/2 in maximum likewise")

-- The suggested bit must cut the size that was asked for. 0.8 is genuinely past
-- what a 1/4 in bit can do, which is what makes the suggestion worth printing.
local dia = CO.display_min_dia("setback", 0.8, 90)
CHECK(dia ~= nil, "a 0.8 chamfer has a stateable minimum bit")
CHECK(CO.pass_count(dia, CO.w_from_size("setback", 0.8, CO.half_angle(90)),
                    CO.half_angle(90)) ~= nil,
      "the suggested bit actually cuts the requested chamfer")
CHECK(CO.pass_count(0.25, CO.w_from_size("setback", 0.8, CO.half_angle(90)),
                    CO.half_angle(90)) == nil,
      "and the bit they have genuinely cannot")

-- Degenerate inputs produce nil, never a confident nonsense number.
CHECK(CO.display_max_size("setback", 90, 0) == nil, "no maximum for a zero diameter")
CHECK(CO.display_min_dia("setback", 0, 90) == nil, "no bit for a zero size")

-- ============================================================
-- Task 3: evaluate now answers in bands
-- ============================================================
-- A chamfer that v1.12.0 refused outright is accepted with a pass count; only
-- past the ceiling is it still refused.
local ev1 = CO.evaluate("setback", 0.06, 90, 0.25)
CHECK(ev1.ok == true and ev1.passes == 1, "a small chamfer is still one pass")
NEAR(ev1.band, ev1.W, 1e-12, "at one pass the band is the whole chamfer")

local ev3 = CO.evaluate("setback", 0.25, 90, 0.25)
CHECK(ev3.ok == true, "0.25 on a 1/4 in bit is no longer refused")
CHECK(ev3.passes == 3, "it takes three passes")
NEAR(ev3.band, 0.25 / 3, 1e-9, "the band is a third of the chamfer")
CHECK(#ev3.presets == #CO.PRESETS, "all six presets are offered")
for _, p in ipairs(ev3.presets) do
   CHECK(p.passes == 3 and math.abs(p.band - 0.25 / 3) < 1e-9,
         "each preset carries the pass count and band")
   -- The preset's depth is the FINAL pass's depth -- the whole chamfer, not the
   -- band. This is the trap solve_band exists to close.
   NEAR(p.d, (ev3.W + p.g) / math.tan(ev3.a), 1e-9, "preset depth is the full cut")
end

-- 0.8, not 0.75: 0.75 is exactly eight bands on this bit and it CUTS (Task 1).
local evX = CO.evaluate("setback", 0.8, 90, 0.25)
CHECK(evX.ok == false and evX.passes == nil, "past the ceiling is still refused")
CHECK(evX.reason:find("8 passes", 1, true) ~= nil, "and the refusal names the ceiling")
CHECK(#evX.presets == 0, "a refused chamfer offers no presets")

-- THE CONTRACT, at the level main() sees it: a one-pass chamfer's presets are
-- bit-identical to what v1.12.0's evaluate produced.
local a90 = CO.half_angle(90)
local Wc = CO.w_from_size("setback", 0.06, a90)
for i, p in ipairs(CO.evaluate("setback", 0.06, 90, 0.25).presets) do
   local want = CO.solve(CO.PRESETS[i], 0.25, Wc, a90)
   CHECK(p.g == want.g and p.d == want.d,
         "one-pass preset " .. i .. " is exactly v1.12.0's")
end

-- Corner nesting (v1.13.1). A relief band is cut from the FINISHING band's
-- loop, so what it needs is the DIFFERENCE between the two distances, not its
-- own distance from the wall.
do
   -- The run that hooked live: setback 0.12, 1/4in 90 deg bit, 40%, inside.
   local W, n, G, a = 0.12, 2, 0.03225, CO.half_angle(90)
   local b = CO.band_width(W, n)

   local d1 = CO.band_offset_distance("inward", CO.pass_geometry(1, n, W, G, a).offset)
   local d2 = CO.band_offset_distance("inward", CO.pass_geometry(2, n, W, G, a).offset)
   NEAR(d1,  0.06,     1e-9, "inward relief band 1 sits +0.06 on the canvas")
   NEAR(d2, -0.03225,  1e-9, "inward finishing band sits -0.03225")

   NEAR(CO.relief_offset_distance(1, n, W, G, a, "inward"), d1 - d2, 1e-9,
        "the relief offset is the difference between the two distances")
   NEAR(CO.relief_offset_distance(1, n, W, G, a, "inward"), (W - 1 * b) + G, 1e-9,
        "and its magnitude is (W - k*b) + G")

   -- The safety argument of the whole fix: adding the relief offset to the
   -- finishing distance lands exactly where v1.13.0 put the band, so straight
   -- walls cannot move. Only the corner treatment changes.
   for _, dir in ipairs({ "inward", "outward" }) do
      for np = 1, CO.MAX_PASSES do
         local Gx, Wx = 0.03225, 0.30
         local bx = CO.band_width(Wx, np)
         local dn = CO.band_offset_distance(dir, CO.pass_geometry(np, np, Wx, Gx, a).offset)
         for k = 1, np - 1 do
            local dk = CO.band_offset_distance(dir, CO.pass_geometry(k, np, Wx, Gx, a).offset)
            local delta = CO.relief_offset_distance(k, np, Wx, Gx, a, dir)
            NEAR(dn + delta, dk, 1e-9,
                 "net displacement is unchanged, " .. dir .. " n=" .. np .. " k=" .. k)
            NEAR(math.abs(delta), (Wx - k * bx) + Gx, 1e-9,
                 "magnitude (W - k*b) + G, " .. dir .. " n=" .. np .. " k=" .. k)
         end
      end
   end

   -- Sign: a relief band always backs off INTO the part relative to the
   -- finishing loop, whichever way round the loop is. That is what puts the
   -- relief arc around the finishing pass's mitre instead of around the vertex.
   CHECK(CO.relief_offset_distance(1, 2, W, G, a, "inward") > 0,
         "an inward loop's relief band offsets outward from the finishing loop")
   CHECK(CO.relief_offset_distance(1, 2, W, G, a, "outward") < 0,
         "an outward loop's relief band offsets inward from the finishing loop")
end

-- The identity the whole SHARP multi-pass path rests on, and the reason main()
-- does not nest a sharp run's relief bands: every band of a sharp run is drawn
-- at exactly W from the wall on the MATERIAL side, so all n of them are one loop
-- drawn n times and the nested relief offset is identically zero.
--
-- Why it comes out that way: the drawn distance is
--    CO.sharp_offset_distance(dir, offset_k, depth_k, deg)
--    == band_offset_distance(dir, offset_k - depth_k * tan a)
-- and pass_geometry puts every apex on the one chamfer face, depth_k =
-- (offset_k + W)/tan a, so the bracket is -W identically: the tan cancels, the
-- offset cancels, and bit angle, cut position, pass count and band index all
-- drop out. Nothing about this is coincidence-free: it is three functions
-- agreeing, and a change to ANY of pass_geometry, band_offset_distance or
-- sharp_offset_shift would break it silently -- every existing pin here and in
-- test_release.lua passes with it broken.
--
-- IT IS SIDE-INDEPENDENT, and that is the point (spec 2026-08-03 section 3a).
-- The comment that used to sit here said the identity "holds only because dir is
-- inward" and that letting sharpening run outward "would take this identity with
-- it". That was wrong, and it was stated as fact: band_offset_distance applies
-- the sign to the WHOLE bracket -- both terms together -- so the magnitude is W
-- either way and dir only chooses which side of the wall. Inward lands at +W
-- (into the material outside a pocket wall), outward at -W (into the material
-- inside an outline). Both are swept below.
--
-- What genuinely does not survive the move outward is the OLD SPELLING, a bare
-- `dist + shift`, which is only the inward half written out longhand. That
-- naive extension is pinned as wrong at the bottom of this block so nobody
-- re-inlines it.
do
   local worst, worst_label, bands = 0, "none", 0
   for _, dir in ipairs({ "inward", "outward" }) do
      for _, bit in ipairs({ { 90, 0.25 }, { 60, 0.5 }, { 30, 1.0 },
                             { 45, 0.5 }, { 120, 0.375 }, { 140, 0.75 } }) do
         local deg, dia = bit[1], bit[2]
         local ang = CO.half_angle(deg)
         for _, size in ipairs({ 0.02, 0.05, 0.12, 0.30 }) do
            local Wx = CO.w_from_size("setback", size, ang)
            local n = CO.pass_count(dia, Wx, ang)
            if n ~= nil then
               local bx = CO.band_width(Wx, n)
               for _, pct in ipairs(CO.PRESETS) do
                  local s = CO.solve_band(pct, dia, Wx, bx, ang)
                  for k = 1, n do
                     local pg = CO.pass_geometry(k, n, Wx, s.g, ang)
                     local drawn = CO.sharp_offset_distance(dir, pg.offset, pg.depth, deg)
                     local want  = CO.band_offset_distance(dir, -Wx)
                     local err = math.abs(drawn - want)
                     bands = bands + 1
                     if err > worst then
                        worst = err
                        worst_label = string.format("%s %d deg dia=%g W=%g n=%d k=%d pct=%d "
                           .. "(drawn %.17g, want %.17g)",
                           dir, deg, dia, Wx, n, k, pct, drawn, want)
                     end
                     -- Section 6: the inward half must still be, exactly, the
                     -- number the old inlined `dist + shift` produced. Inside
                     -- is untouched by this change.
                     if dir == "inward" then
                        CHECK(drawn == CO.band_offset_distance("inward", pg.offset)
                                       + CO.sharp_offset_shift(pg.depth, deg),
                              "inward still equals the old dist + shift exactly "
                              .. string.format("(%d deg dia=%g W=%g n=%d k=%d pct=%d)",
                                               deg, dia, Wx, n, k, pct))
                     end
                  end
               end
            end
         end
      end
   end
   -- A floor, not the exact count: the guard is here so a sweep that silently
   -- stopped sweeping (a case list emptied, a direction dropped, every
   -- pass_count going nil) cannot read as a pass. 396 bands today -- 198 per
   -- direction, which is what it swept before it swept both.
   CHECK(bands > 300, "the sharp-band sweep actually swept something (" .. bands .. " bands)")
   CHECK(worst <= 1e-12,
         "every sharp band is drawn at exactly W from the wall on the material side, "
         .. "both directions, all bits/pass counts/presets "
         .. "(worst " .. string.format("%.3g", worst) .. " at " .. worst_label .. ")")

   -- THE WRONG FORMULA, PINNED SO IT CANNOT COME BACK. Before 2026-08-03 the
   -- rule was inlined at two call sites as a bare `dist + shift`. Applied
   -- outward that adds the shift to a POSITIVE distance instead of subtracting
   -- it inside the bracket, and the answer is not W from the wall: on the run
   -- that hooked live (setback 0.12, 1/4in 90 deg bit, 40%, two passes) the
   -- relief band lands at 0 -- the original vector itself -- and the finishing
   -- band at 2G + W. The measured numbers are kept; what has changed is what
   -- they are evidence OF. They are no longer a reason to exclude outward runs,
   -- they are the shape of the bug an outward run must not have.
   local Wc, nc, Gc, ac = 0.12, 2, 0.03225, CO.half_angle(90)
   local pg1 = CO.pass_geometry(1, nc, Wc, Gc, ac)
   local pg2 = CO.pass_geometry(2, nc, Wc, Gc, ac)
   local naive1 = CO.band_offset_distance("outward", pg1.offset)
                  + CO.sharp_offset_shift(pg1.depth, 90)
   local naive2 = CO.band_offset_distance("outward", pg2.offset)
                  + CO.sharp_offset_shift(pg2.depth, 90)
   NEAR(naive1, 0.0,    1e-12,
        "the wrong formula outward: the relief band collapses onto the original vector")
   NEAR(naive2, 0.1845, 1e-12,
        "the wrong formula outward: the finishing band lands at 2G + W")
   local right = CO.band_offset_distance("outward", -Wc)
   NEAR(right, -0.12, 1e-12, "the right answer outward is -W, into the material")
   CHECK(math.abs(naive1 - right) > 1e-6 and math.abs(naive2 - right) > 1e-6,
         "the naive dist + shift is NOT the outward answer -- re-inlining a bare + fails here")
   CHECK(CO.sharp_offset_distance("outward", pg1.offset, pg1.depth, 90) ~= naive1
         and CO.sharp_offset_distance("outward", pg2.offset, pg2.depth, 90) ~= naive2,
         "CO.sharp_offset_distance does not reproduce the naive outward numbers")
end

-- Nesting depth (2026-08-03, spec section 3c). CO.classify_directions has always
-- asked "is this loop inside ANY other" and stopped at the first hit. A sharp run
-- needs the COUNT, because Aspire's displacement direction alternates with depth
-- and we only know its answer to depth 1. Same containment predicate, so the two
-- can never disagree about what "inside" means.
do
   local function box(x0, y0, x1, y1)
      return { pts = { {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1} } }
   end
   -- A flat set: three squares side by side, none inside any other.
   local flat = { box(0, 0, 10, 10), box(20, 0, 30, 10), box(40, 0, 50, 10) }
   local d = CO.nesting_depths(flat)
   CHECK(d[1] == 0 and d[2] == 0 and d[3] == 0, "siblings are all depth 0")

   -- One level: an outline with two counters, which is a letter B.
   local letter = { box(0, 0, 100, 100), box(20, 60, 40, 80), box(20, 20, 40, 40) }
   d = CO.nesting_depths(letter)
   CHECK(d[1] == 0, "the outline is depth 0")
   CHECK(d[2] == 1 and d[3] == 1, "both counters are depth 1")

   -- Two levels: a border, a letter inside it, a counter inside that.
   local deep = { box(0, 0, 200, 200), box(50, 50, 150, 150), box(80, 80, 100, 100) }
   d = CO.nesting_depths(deep)
   CHECK(d[1] == 0 and d[2] == 1 and d[3] == 2, "a third level counts as depth 2")

   -- Order must not matter: the same three loops listed inside-out.
   local reversed = { box(80, 80, 100, 100), box(50, 50, 150, 150), box(0, 0, 200, 200) }
   d = CO.nesting_depths(reversed)
   CHECK(d[1] == 2 and d[2] == 1 and d[3] == 0, "depth follows containment, not list order")

   -- Degenerate: two identical loops each contain the other, so NOTHING is
   -- outermost. nesting_depths reports it honestly; the gate in
   -- CO.sharp_nesting_ok is what refuses it.
   local twins = { box(0, 0, 10, 10), box(0, 0, 10, 10) }
   d = CO.nesting_depths(twins)
   CHECK(d[1] == 1 and d[2] == 1, "identical loops each contain the other - no depth 0")

   -- A single loop on its own.
   d = CO.nesting_depths({ box(0, 0, 10, 10) })
   CHECK(d[1] == 0, "one loop is depth 0")
   CHECK(#CO.nesting_depths({}) == 0, "no loops, no depths")
end

-- CO.shape_groups (narrow-break guard, Finding A): each depth-0 loop plus
-- everything nested inside it. The guard runs its piece count once per group, so
-- that a thin bar eaten away in one shape cannot cancel against a dumbbell
-- splitting in another and leave the total unmoved.
do
   local function box(x0, y0, x1, y1)
      return { pts = { {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1} } }
   end
   local function sorted(g)
      local t = {}
      for _, i in ipairs(g) do t[#t + 1] = i end
      table.sort(t)
      return table.concat(t, ",")
   end

   -- Three squares side by side: three shapes, one loop each. This is the case
   -- Finding A exists for - before grouping these shared one count.
   local flat = { box(0, 0, 10, 10), box(20, 0, 30, 10), box(40, 0, 50, 10) }
   local g = CO.shape_groups(flat)
   CHECK(#g == 3, "three separate loops are three shapes")
   CHECK(sorted(g[1]) == "1" and sorted(g[2]) == "2" and sorted(g[3]) == "3",
         "each sibling is alone in its own group")

   -- A letter B: one shape carrying its own two counters, so a waist between
   -- the outline and a counter is still inside a single count.
   local letter = { box(0, 0, 100, 100), box(20, 60, 40, 80), box(20, 20, 40, 40) }
   g = CO.shape_groups(letter)
   CHECK(#g == 1, "an outline and its counters are ONE shape, not three")
   CHECK(sorted(g[1]) == "1,2,3", "the counters travel with their outline")

   -- Two letters, each with a counter. Four loops, two shapes - and neither
   -- letter can hide the other's break.
   local word = { box(0, 0, 100, 100), box(20, 20, 40, 40),
                  box(200, 0, 300, 100), box(220, 20, 240, 40) }
   g = CO.shape_groups(word)
   CHECK(#g == 2, "two letters are two shapes")
   CHECK(sorted(g[1]) == "1,2" and sorted(g[2]) == "3,4",
         "each letter keeps its own counter and nothing else")

   -- Depth 2: an island inside a counter still belongs to the ONE top-level
   -- loop, not to a group of its own. Grouping is by outermost container, not
   -- by immediate parent.
   local deep = { box(0, 0, 200, 200), box(50, 50, 150, 150), box(80, 80, 100, 100) }
   g = CO.shape_groups(deep)
   CHECK(#g == 1, "three nested levels are one shape")
   CHECK(sorted(g[1]) == "1,2,3", "depth 2 joins the top-level loop, not its parent")

   -- List order must not matter, same as nesting_depths.
   local reversed = { box(80, 80, 100, 100), box(50, 50, 150, 150), box(0, 0, 200, 200) }
   g = CO.shape_groups(reversed)
   CHECK(#g == 1 and sorted(g[1]) == "1,2,3", "grouping follows containment, not list order")

   -- The twins case: two identical loops each contain the other, so NOTHING is
   -- depth 0 and neither can be placed. Each is checked on its own, which is
   -- always safe - a group can only hide a change by cancelling inside itself.
   local twins = { box(0, 0, 10, 10), box(0, 0, 10, 10) }
   g = CO.shape_groups(twins)
   CHECK(#g == 2, "loops with no depth-0 container each become their own shape")
   CHECK(sorted(g[1]) == "1" and sorted(g[2]) == "2", "and they are not merged together")

   -- Every input loop reaches exactly one group, in every fixture above.
   for _, fixture in ipairs({ flat, letter, word, deep, reversed, twins }) do
      local seen, total = {}, 0
      for _, grp in ipairs(CO.shape_groups(fixture)) do
         for _, i in ipairs(grp) do
            CHECK(seen[i] == nil, "no loop lands in two shapes")
            seen[i] = true
            total = total + 1
         end
      end
      CHECK(total == #fixture, "every selected loop reaches a shape")
   end

   CHECK(#CO.shape_groups({}) == 0, "no loops, no shapes")
   CHECK(#CO.shape_groups({ box(0, 0, 10, 10) }) == 1, "one loop is one shape")
end

-- classify_directions is now a map over nesting_depths, and must answer exactly
-- what it answered before: outermost outward, everything nested inward. Pinned
-- against the same fixtures so the factoring cannot quietly change what Auto does.
do
   local function box(x0, y0, x1, y1)
      return { pts = { {x0, y0}, {x1, y0}, {x1, y1}, {x0, y1} } }
   end
   local letter = { box(0, 0, 100, 100), box(20, 60, 40, 80), box(20, 20, 40, 40) }
   local dirs = CO.classify_directions(letter)
   CHECK(dirs[1] == "outward", "the outline still classifies outward")
   CHECK(dirs[2] == "inward" and dirs[3] == "inward", "the counters still classify inward")
   local deep = { box(0, 0, 200, 200), box(50, 50, 150, 150), box(80, 80, 100, 100) }
   dirs = CO.classify_directions(deep)
   CHECK(dirs[1] == "outward" and dirs[2] == "inward" and dirs[3] == "inward",
         "and depth 2 is still inward - classify_directions is two-level, deliberately")
end

-- Reading the Aspire chamfer template (2026-08-04, large-chamfer spec section 2).
-- Values verified against the spec's decode of Tim's saved file: start 0,
-- Inside = 1, inches, EditingDialog = uiChamferDialog. The depth is
-- 0.34641016151378 in the first save (Chamfer 1.ToolpathTemplate, the
-- manual fixture below) but the SHIPPED template is the second save, made to
-- pick up the layer restriction (spec section 2a-4) -- and resaving through
-- Aspire's own decimal field rounded the depth to 0.3464101615. Pinned against
-- what is actually in the shipped bytes, not the earlier, more precise save.
do
   local function slurp(p)
      local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b
   end
   local shipped = slurp("gadget/EdgeBreaker/" .. CO.CHAMFER_TEMPLATE_NAME)
   local manual  = slurp("tests/fixtures/chamfer-manual.ToolpathTemplate")
   local profile = slurp("gadget/EdgeBreaker/" .. CO.TEMPLATE_NAME)

   CHECK(CO.read_editing_dialog(shipped) == "uiChamferDialog",
         "the shipped chamfer template identifies itself")
   CHECK(CO.read_editing_dialog(manual) == "uiChamferDialog",
         "so does the manual fixture")
   local ped = CO.read_editing_dialog(profile)
   CHECK(ped ~= "uiChamferDialog",
         "the profile template does NOT read as a chamfer one (got "
         .. tostring(ped) .. ")")

   local doff = CO.find_chamfer_depth_offset(shipped)
   CHECK(type(doff) == "number", "chamfer depth offset found")
   CHECK(shipped:sub(doff, doff + 7) == CO.encode_double(0.3464101615),
         "and the value there is the depth Tim saved")
   local soff = CO.find_chamfer_start_offset(shipped)
   CHECK(type(soff) == "number", "chamfer start-depth offset found")
   CHECK(shipped:sub(soff, soff + 7) == CO.encode_double(0), "saved start depth is 0")
   local ioff = CO.find_chamfer_side_offset(shipped)
   CHECK(type(ioff) == "number", "chamfer side offset found")
   CHECK(shipped:byte(ioff) == 1, "Tim saved the template with Inside = 1")
   local sloff = CO.find_chamfer_slope_offset(shipped)
   CHECK(type(sloff) == "number", "chamfer slope offset found")
   CHECK(shipped:byte(sloff) == 1, "Tim saved the template with Slope Downwards = 1")
   CHECK(CO.read_chamfer_units(shipped) == "in", "template units read as inches")

   -- The profile template must refuse every chamfer finder - no _chpd* records.
   local x, why = CO.find_chamfer_depth_offset(profile)
   CHECK(x == nil and type(why) == "string", "profile template has no chamfer depth")
   x, why = CO.find_chamfer_side_offset(profile)
   CHECK(x == nil and type(why) == "string", "profile template has no chamfer side")
   x, why = CO.find_chamfer_slope_offset(profile)
   CHECK(x == nil and type(why) == "string", "profile template has no chamfer slope")
   x, why = CO.read_chamfer_units(profile)
   CHECK(x == nil and type(why) == "string", "profile template has no chamfer units flag")

   -- And the chamfer template must refuse the PROFILE finders, both ways round.
   x, why = CO.find_depth_offset(shipped)
   CHECK(x == nil and type(why) == "string", "chamfer template has no _ppdCutDepth")
end

-- Patching the chamfer template (2026-08-04, large-chamfer spec section 3e).
-- Every patch is a value overwrite of a kind already proven; the composite runs
-- them in one order so main() cannot invent its own.
do
   local function slurp(p)
      local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b
   end
   local shipped = slurp("gadget/EdgeBreaker/" .. CO.CHAMFER_TEMPLATE_NAME)

   -- Round-trip the doubles to 1e-12 (spec section 5).
   local p1 = CO.patch_chamfer_depth(shipped, 0.5196152422706631)
   CHECK(p1 ~= nil and #p1 == #shipped, "depth patch preserves length")
   local off = CO.find_chamfer_depth_offset(p1)
   CHECK(p1:sub(off, off + 7) == CO.encode_double(0.5196152422706631),
         "patched depth reads back exactly")
   local p2 = CO.patch_chamfer_start_depth(shipped, 0.05)
   CHECK(p2 ~= nil
         and p2:sub(CO.find_chamfer_start_offset(p2), CO.find_chamfer_start_offset(p2) + 7)
             == CO.encode_double(0.05),
         "patched start depth reads back exactly")

   -- The side bool, both directions, and the refusal. Measured 2026-08-04 on
   -- the waste-removed ring with the slope patched and the copies normalized
   -- counter-clockwise: 0 is the form's Inside, which is what an outward loop
   -- (material inside the vector) needs.
   local po = CO.patch_chamfer_side(shipped, "outward")
   CHECK(po ~= nil and po:byte(CO.find_chamfer_side_offset(po)) == 0,
         "outward writes _chpdInside = 0")
   local pi = CO.patch_chamfer_side(shipped, "inward")
   CHECK(pi ~= nil and pi:byte(CO.find_chamfer_side_offset(pi)) == 1,
         "inward writes _chpdInside = 1")
   for _, bad in ipairs({ "auto", "inside", "outside", "", 1, true }) do
      local x, why = CO.patch_chamfer_side(shipped, bad)
      CHECK(x == nil and type(why) == "string",
            "side " .. tostring(bad) .. " refuses instead of guessing")
   end
   -- nil can't ride inside the ipairs table literal above (it would terminate
   -- the array early), so it gets its own explicit call.
   local nx, nwhy = CO.patch_chamfer_side(shipped, nil)
   CHECK(nx == nil and type(nwhy) == "string",
         "side nil refuses instead of guessing")

   -- Single-value patches touch exactly the bytes they claim. Measured against
   -- `po`, not `pi`: the template was saved with Inside = 1, which is what
   -- INWARD writes now, so `pi` changes nothing and would make this check
   -- vacuous. This pin has been re-pointed twice, each time the table flipped -
   -- flipping a constant can turn a byte-diff assertion into a tautology
   -- without ever failing first, so re-check it whenever these values move.
   local diff = 0
   for i = 1, #shipped do if shipped:byte(i) ~= po:byte(i) then diff = diff + 1 end end
   CHECK(diff == 1, "the side patch changes exactly one byte (got " .. diff .. ")")

   -- The layer patch works on this file unchanged - the C0 result, now pinned
   -- offline forever.
   local pl = CO.patch_template_layer(shipped, 7, 1)
   CHECK(pl ~= nil and #pl == #shipped, "patch_template_layer accepts the chamfer template")
   local layers = CO.read_template_layers(pl)
   CHECK(layers ~= nil and #layers == 1 and layers[1] == CO.offset_layer_name(7, 1),
         "and the restriction re-reads as the slot's own layer")

   -- The bit's own angle (sitting 2026-08-04 check D8). The template was saved
   -- with a 90 degree bit, so it carries a 45 degree half-angle; ReplaceTool does
   -- NOT re-derive it when the run installs a different bit, and Aspire then
   -- computes the chamfer's width from the stale number. The patch takes the
   -- bit's INCLUDED angle, the same unit every other call site uses, and halves
   -- it here - so no caller can hand this one a half-angle by mistake.
   CHECK(CO.find_chamfer_angle_offset(shipped) ~= nil, "the shipped template has an angle record")
   local a_at = CO.find_chamfer_angle_offset(shipped)
   CHECK(shipped:sub(a_at, a_at + 7) == CO.encode_double(45),
         "and it reads 45 degrees, the 90 degree bit it was saved with")
   local pa = CO.patch_chamfer_angle(shipped, 60)
   CHECK(pa ~= nil and #pa == #shipped, "angle patch preserves length")
   CHECK(pa:sub(CO.find_chamfer_angle_offset(pa), CO.find_chamfer_angle_offset(pa) + 7)
         == CO.encode_double(30), "a 60 degree bit writes a 30 degree half-angle")
   local pa90 = CO.patch_chamfer_angle(shipped, 90)
   CHECK(pa90 == shipped, "a 90 degree bit rewrites the same 45 and changes nothing")
   local pa120 = CO.patch_chamfer_angle(shipped, 120)
   CHECK(pa120 ~= nil
         and pa120:sub(CO.find_chamfer_angle_offset(pa120), CO.find_chamfer_angle_offset(pa120) + 7)
             == CO.encode_double(60), "an obtuse bit writes the larger half-angle")
   -- Not a count - 45 and 30 are both small exact doubles and share six of their
   -- eight bytes. What matters is that nothing OUTSIDE the value window moved.
   local astray = 0
   for i = 1, #shipped do
      if shipped:byte(i) ~= pa:byte(i) and (i < a_at or i > a_at + 7) then astray = astray + 1 end
   end
   CHECK(astray == 0, "the angle patch touches nothing outside its value (got " .. astray .. ")")
   for _, bad in ipairs({ 0, -90, "90", true, {} }) do
      local x, why = CO.patch_chamfer_angle(shipped, bad)
      CHECK(x == nil and type(why) == "string",
            "angle " .. tostring(bad) .. " refuses instead of writing nonsense")
   end
   local anx, anwhy = CO.patch_chamfer_angle(shipped, nil)
   CHECK(anx == nil and type(anwhy) == "string", "angle nil refuses instead of writing nonsense")

   -- The slope bool (2026-08-04 direction-split sitting, the S1 fail). The form
   -- calls it Slope Downwards / Slope Upwards; the template stores it as
   -- _chpdVectorsAtTop, and Tim saved it Downwards (1) - which anchors the
   -- bevel's SURFACE edge at the drawn vector and digs deeper moving away, so a
   -- coincident copy leaves the part's own edge sharp and sinks a groove into
   -- the face beside it, on both directions at once, with both side bytes
   -- correct. Every EdgeBreaker copy is the wall the chamfer breaks, so every
   -- run wants the vector at the BOTTOM: Slope Upwards, 0. Measured live: both
   -- toolpaths recut correctly the moment the form's slope was flipped.
   local ps = CO.patch_chamfer_slope(shipped)
   CHECK(ps ~= nil and #ps == #shipped, "slope patch preserves length")
   CHECK(ps:byte(CO.find_chamfer_slope_offset(ps)) == 0,
         "slope patch writes Slope Upwards = 0")
   local sldiff = 0
   for i = 1, #shipped do if shipped:byte(i) ~= ps:byte(i) then sldiff = sldiff + 1 end end
   CHECK(sldiff == 1, "the slope patch changes exactly one byte (got " .. sldiff .. ")")

   -- The composite: one call, one order.
   local pr = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 1, "inward", 60, "in")
   CHECK(pr ~= nil and #pr == #shipped, "composite patch preserves length")
   CHECK(pr:sub(CO.find_chamfer_depth_offset(pr), CO.find_chamfer_depth_offset(pr) + 7)
         == CO.encode_double(0.25), "composite wrote the depth")
   CHECK(pr:byte(CO.find_chamfer_side_offset(pr)) == 1, "composite wrote the side")
   CHECK(pr:sub(CO.find_chamfer_angle_offset(pr), CO.find_chamfer_angle_offset(pr) + 7)
         == CO.encode_double(30), "composite wrote the half-angle")
   -- The shipped byte is 1, so this pin cannot go vacuous.
   CHECK(pr:byte(CO.find_chamfer_slope_offset(pr)) == 0, "composite wrote the slope")
   local prl = CO.read_template_layers(pr)
   CHECK(prl ~= nil and prl[1] == CO.offset_layer_name(12, 1),
         "composite restricted to slot 12 band 1")
   local x, why = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 1, "banana", 60, "in")
   CHECK(x == nil and type(why) == "string", "composite propagates a side refusal")
   -- A missing angle must never mean "leave the template's 45 alone" - that
   -- silence IS the defect D8 found, so the composite refuses rather than
   -- shipping a toolpath cut at the wrong angle.
   local ax, awhy = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 1, "inward", nil, "in")
   CHECK(ax == nil and type(awhy) == "string", "composite refuses a run with no bit angle")

   -- The band argument (2026-08-04 direction-split spec section 3b). A mixed
   -- run loads the template once per direction, aimed at its own band layer.
   local pb2 = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 2, "inward", 60, "in")
   CHECK(pb2 ~= nil, "the composite accepts band 2")
   local pb2l = CO.read_template_layers(pb2)
   CHECK(pb2l ~= nil and pb2l[1] == CO.offset_layer_name(12, 2),
         "band 2 aims the template at the slot's band-2 layer")
   -- Band is REQUIRED. A caller that forgot it on a mixed run would silently
   -- aim band 1's layer with band 2's side - the metric-jobs shape: remove the
   -- dangerous fall-through by refusing, not defaulting.
   local bx, bwhy = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, nil, "inward", 60, "in")
   CHECK(bx == nil and type(bwhy) == "string", "a run with no band refuses")
   -- The split's byte guarantees, pinned as pair-diffs. Same depth, start and
   -- angle in every call, so ONLY the named byte may move. Both directions of
   -- each pair differ from the SHIPPED bytes too, so neither comparison can go
   -- vacuous the way the po/pi pin nearly did (session 075).
   local b1o = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 1, "outward", 60, "in")
   local b1i = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 1, "inward", 60, "in")
   local b2i = CO.patch_chamfer_run(shipped, 0.25, 0.1, 12, 2, "inward", 60, "in")
   CHECK(b1o ~= nil and b1i ~= nil and b2i ~= nil, "all three pair-diff patches built")
   local sdiff = 0
   for i = 1, #b1o do if b1o:byte(i) ~= b1i:byte(i) then sdiff = sdiff + 1 end end
   CHECK(sdiff == 1, "outward vs inward on one band is exactly the side byte (got " .. sdiff .. ")")
   CHECK(b1o:byte(CO.find_chamfer_side_offset(b1o)) == 0
         and b1i:byte(CO.find_chamfer_side_offset(b1i)) == 1,
         "and it is the side byte that moved")
   local bdiff = 0
   for i = 1, #b1i do if b1i:byte(i) ~= b2i:byte(i) then bdiff = bdiff + 1 end end
   CHECK(bdiff == 1, "band 1 vs band 2 on one direction is exactly the band digit (got " .. bdiff .. ")")
end

-- The too-narrow probe for the aspire path (2026-08-04 direction-split sitting,
-- S3). Aspire's chamfer engine eats W off the MATERIAL side of every wall, so a
-- shape survives only where it is wider than 2W - the sitting cut a word whose
-- strokes sat between 0.30 and 0.40 and watched 0.15 work and 0.2 destroy them,
-- silently, because this path had no viability check at all.
--
-- The probe distance is the chamfer's own top edge: W into the material, which
-- is band_offset_distance's negative-offset case and therefore the SAME loop a
-- sharp band gets drawn at. If offsetting by it collapses the shape, there is
-- no top edge left to chamfer.
do
   NEAR(CO.chamfer_probe_distance("outward", 0.2), -0.2, 1e-12,
        "an outward loop probes inward, into the material")
   NEAR(CO.chamfer_probe_distance("inward", 0.2), 0.2, 1e-12,
        "an inward loop probes outward, into the material")
   -- Tied to the one sign rule, so the two can never disagree about which way
   -- the material is.
   for _, dir in ipairs({ "outward", "inward" }) do
      for _, W in ipairs({ 0.05, 0.2, 3.5 }) do
         NEAR(CO.chamfer_probe_distance(dir, W), CO.band_offset_distance(dir, -W), 1e-12,
              "probe distance is band_offset_distance(-W) for " .. dir .. " " .. W)
      end
   end
end

-- Winding normalization for the aspire path's copies (2026-08-04 direction-split
-- sitting, the step defect). _chpdInside is stored relative to the loop's TRAVEL
-- direction, not absolute inside/outside: a hand chamfer toolpath reversed one
-- original vector mid-sitting and the same byte started cutting the opposite
-- side of that loop. So every copy is laid down counter-clockwise (positive
-- signed area) and the side table speaks that winding only.
do
   CHECK(CO.chamfer_copy_reverse(-2.5) == true,
         "a clockwise loop (negative area) reverses")
   CHECK(CO.chamfer_copy_reverse(3.1) == false,
         "a counter-clockwise loop is left alone")
   CHECK(CO.chamfer_copy_reverse(0) == false,
         "a degenerate zero-area loop has no winding to fix")
   -- Tied to the real area function, so the two can never disagree about signs.
   local ccw = { {0, 0}, {2, 0}, {2, 2}, {0, 2} }
   local cw  = { {0, 2}, {2, 2}, {2, 0}, {0, 0} }
   CHECK(CO.chamfer_copy_reverse(CO.signed_area(ccw)) == false,
         "a counter-clockwise square stays as drawn")
   CHECK(CO.chamfer_copy_reverse(CO.signed_area(cw)) == true,
         "the same square drawn clockwise reverses")
end

-- Metric jobs (2026-08-04 metric-jobs spec). Aspire converts a template's stored
-- lengths to the job's units when it loads one - measured at the machine: the
-- inch chamfer template's 0.3464 cut depth arrives in a mm job as 8.799. So our
-- numbers go IN in the template's units and Aspire converts them back, and no mm
-- template has to be shipped.
do
   local L = CO.length_in_template_units
   NEAR(L(5, "mm", "mm"), 5, 1e-12, "matching mm units pass through")
   NEAR(L(0.25, "in", "in"), 0.25, 1e-12, "matching inch units pass through")
   NEAR(L(25.4, "mm", "in"), 1, 1e-12, "a mm job's 25.4 is one inch in an inch template")
   NEAR(L(1, "in", "mm"), 25.4, 1e-12, "an inch job's 1 is 25.4 in a mm template")
   -- Zero is the ordinary start depth, which is why length_in_job_units cannot be
   -- reused here: it treats <= 0 as unusable and returns nil.
   CHECK(L(0, "mm", "in") == 0, "a zero start depth converts to zero, not nil")
   CHECK(L(0, "in", "in") == 0, "and stays zero when the units match")
   for _, bad in ipairs({ -1, "5", true, {} }) do
      CHECK(L(bad, "mm", "in") == nil, "length " .. tostring(bad) .. " refuses")
   end
   CHECK(L(nil, "mm", "in") == nil, "a nil length refuses")
   CHECK(L(0 / 0, "mm", "in") == nil, "NaN refuses")
   CHECK(L(5, "furlong", "in") == nil, "an unknown job unit refuses")
   CHECK(L(5, "mm", "furlong") == nil, "an unknown template unit refuses")
   CHECK(L(5, nil, "in") == nil, "no job units refuses - it must never guess")
   CHECK(L(5, "mm", nil) == nil, "no template units refuses")
end

-- The two composites convert before they write, and refuse rather than fall
-- through. A silent fall-through here cuts 25.4x too deep, which is why the
-- missing-units case is a refusal and not a default (the D8 lesson, with worse
-- consequences).
do
   local function slurp(p)
      local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b
   end
   local cham = slurp("gadget/EdgeBreaker/" .. CO.CHAMFER_TEMPLATE_NAME)
   local prof = slurp("gadget/EdgeBreaker/" .. CO.TEMPLATE_NAME)

   -- A 5mm chamfer on a mm job goes into the inch template as 5/25.4.
   local cmm = CO.patch_chamfer_run(cham, 5, 2.54, 12, 1, "inward", 90, "mm")
   CHECK(cmm ~= nil, "the chamfer composite accepts a mm job")
   CHECK(cmm ~= nil and cmm:sub(CO.find_chamfer_depth_offset(cmm),
                                CO.find_chamfer_depth_offset(cmm) + 7)
         == CO.encode_double(5 / 25.4), "mm chamfer depth is written in inches")
   CHECK(cmm ~= nil and cmm:sub(CO.find_chamfer_start_offset(cmm),
                                CO.find_chamfer_start_offset(cmm) + 7)
         == CO.encode_double(0.1), "mm start depth is written in inches too")
   -- An inch job is byte-identical to writing the numbers straight in. The
   -- no-op path is pinned, not assumed.
   local cin = CO.patch_chamfer_run(cham, 0.25, 0.1, 12, 1, "inward", 90, "in")
   CHECK(cin ~= nil and cin:sub(CO.find_chamfer_depth_offset(cin),
                                CO.find_chamfer_depth_offset(cin) + 7)
         == CO.encode_double(0.25), "an inch job's depth goes in untouched")
   local cx, cwhy = CO.patch_chamfer_run(cham, 0.25, 0.1, 12, 1, "inward", 90, nil)
   CHECK(cx == nil and type(cwhy) == "string",
         "the chamfer composite refuses a run with no job units")
   cx, cwhy = CO.patch_chamfer_run(cham, 0.25, 0.1, 12, 1, "inward", 90, "furlong")
   CHECK(cx == nil and type(cwhy) == "string",
         "and refuses a job unit it does not recognise")

   -- The same for the profile template.
   local pmm = CO.patch_template_run(prof, 5, 2.54, 3, 1, nil, "mm")
   CHECK(pmm ~= nil, "the profile composite accepts a mm job")
   CHECK(pmm ~= nil and pmm:sub(CO.find_depth_offset(pmm), CO.find_depth_offset(pmm) + 7)
         == CO.encode_double(5 / 25.4), "mm cut depth is written in inches")
   CHECK(pmm ~= nil and pmm:sub(CO.find_start_depth_offset(pmm),
                                CO.find_start_depth_offset(pmm) + 7)
         == CO.encode_double(0.1), "mm profile start depth is written in inches")
   -- The pass list is text, and it must carry the CONVERTED number - it is what
   -- Aspire actually cuts (the session-025 finding).
   CHECK(pmm ~= nil and pmm:find(string.format("%.6f;", 5 / 25.4):gsub(".", "%0\0"), 1, true) ~= nil,
         "the pass list carries the converted depth, not the job's")
   local px, pwhy = CO.patch_template_run(prof, 0.1, 0, 3, 1, nil, nil)
   CHECK(px == nil and type(pwhy) == "string",
         "the profile composite refuses a run with no job units")
end

-- Direction banding for the chamfer engine (2026-08-04 direction-split spec
-- section 3a). Aspire's chamfer engine does NOT nest - one _chpdInside byte
-- serves every loop in a toolpath (measured 2026-08-04, session 075) - so a
-- mixed run needs a band (layer + template load) per direction. Outward is
-- band 1 whenever present, so a single-direction run lands on NN-1 exactly as
-- before the split.
do
   local b = CO.chamfer_bands({ "outward", "outward" })
   CHECK(b ~= nil and b.n == 1 and b.dir_of_band[1] == "outward"
         and b.band_of[1] == 1 and b.band_of[2] == 1,
         "all-outward is one band, band 1")
   b = CO.chamfer_bands({ "inward", "inward" })
   CHECK(b ~= nil and b.n == 1 and b.dir_of_band[1] == "inward"
         and b.band_of[1] == 1 and b.band_of[2] == 1,
         "all-inward is one band, band 1 - a forced side never splits")
   b = CO.chamfer_bands({ "outward", "inward", "outward" })
   CHECK(b ~= nil and b.n == 2 and b.dir_of_band[1] == "outward"
         and b.dir_of_band[2] == "inward",
         "mixed is two bands, outward first")
   CHECK(b ~= nil and b.band_of[1] == 1 and b.band_of[2] == 2 and b.band_of[3] == 1,
         "each loop maps to its own direction's band")
   b = CO.chamfer_bands({ "inward", "outward" })
   CHECK(b ~= nil and b.n == 2 and b.dir_of_band[1] == "outward"
         and b.band_of[1] == 2 and b.band_of[2] == 1,
         "outward is band 1 whatever order the loops came in")
   b = CO.chamfer_bands({})
   CHECK(b ~= nil and b.n == 0, "no loops, no bands - empty selections were refused long before this")
   local x, why = CO.chamfer_bands({ "outward", "auto" })
   CHECK(x == nil and type(why) == "string",
         "an unrecognised direction refuses instead of guessing")
   x, why = CO.chamfer_bands(nil)
   CHECK(x == nil and type(why) == "string", "nil dirs refuse")
end

-- The strategy switch (2026-08-04, large-chamfer spec section 3a). ONE place;
-- the dialog's JS mirrors it (sharp && sharpMaxPercent === null) and main()
-- consults this. Aspire's engine only when sharp is ticked and not even the 0%
-- preset can sharpen - below that, everything is exactly v1.13.0.
do
   CHECK(CO.chamfer_strategy(1, 0.05, 0.106) == "bands", "small sharp chamfer stays on bands")
   CHECK(CO.chamfer_strategy(1, 0.106, 0.106) == "bands", "the exact ceiling still sharpens on bands")
   CHECK(CO.chamfer_strategy(1, 0.107, 0.106) == "aspire", "one thou over switches to Aspire's engine")
   CHECK(CO.chamfer_strategy(0, 0.5, 0.106) == "bands", "sharp off never switches, at any size")
   CHECK(CO.chamfer_strategy("1", 0.3, 0.106) == "aspire", "the dialog's string '1' counts as ticked")
   CHECK(CO.chamfer_strategy("0", 0.3, 0.106) == "bands", "and its '0' as off")
   CHECK(CO.chamfer_strategy(nil, 0.3, 0.106) == "bands", "no sharp field means off")
end

-- Is this selection FLAT -- nothing inside anything else? (2026-08-07,
-- side-on-flat-selections spec section 3b.) Bounding boxes, not contours,
-- because bbox containment is NECESSARY for real nesting: if no box contains
-- another then nothing is truly nested, which is the only direction this
-- function is allowed to be believed in. The converse does not hold, so it can
-- say "not flat" about shapes that merely overlap -- that greys a control that
-- could have been live, which is the harmless way to be wrong.
do
   local function bb(cx, cy, xlen, ylen) return { cx = cx, cy = cy, xlen = xlen, ylen = ylen } end

   CHECK(CO.selection_is_flat({}) == false,
         "an EMPTY list is not flat - there is nothing to measure, and CO.flat_field is what tells that apart from a measured nesting")
   CHECK(CO.selection_is_flat({ bb(0, 0, 2, 2) }) == true,
         "one shape is flat: a lone pocket or a lone island, which is the case this whole spec exists for")
   CHECK(CO.selection_is_flat({ bb(0, 0, 2, 2), bb(10, 0, 2, 2) }) == true,
         "two shapes side by side are flat")
   CHECK(CO.selection_is_flat({ bb(0, 0, 2, 2), bb(2, 0, 2, 2) }) == true,
         "two shapes TOUCHING at an edge are still flat - containment is the test, not overlap")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(0, 0, 2, 2) }) == false,
         "an outline with something inside it is NOT flat - this is S5's ring, which keeps greying")
   CHECK(CO.selection_is_flat({ bb(0, 0, 2, 2), bb(0, 0, 10, 10) }) == false,
         "and the order it is listed in makes no difference")
   CHECK(CO.selection_is_flat({ bb(0, 0, 2, 2), bb(0, 0, 2, 2) }) == false,
         "IDENTICAL boxes are not flat - the twins case, where each contains the other")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(0, 0, 10, 2) }) == false,
         "a box sharing an outer edge is still CONTAINED, so still not flat")
   CHECK(CO.selection_is_flat({ bb(0, 0, 4, 4), bb(3, 3, 4, 4) }) == true,
         "two boxes that merely OVERLAP are flat - neither contains the other")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(20, 0, 2, 2), bb(0, 0, 1, 1) }) == false,
         "one nested pair anywhere in the selection is enough to fail it")
   -- Containment is FOUR inequalities and every one of them has to be here.
   -- Added 2026-08-07 after a mutation survived: deleting the y-min test left
   -- all eleven checks above green, because not one of them had a box that was
   -- inside another's span on ONE axis and outside it on the other. Each case
   -- below is a shape poking out of another's box in exactly one direction, so
   -- each pins exactly one inequality -- drop any single test and one of these
   -- four calls a flat selection nested.
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(0, -4, 2, 10) }) == true,
         "a shape poking out of the BOTTOM of another's box is not inside it (pins y-min)")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(0, 4, 2, 10) }) == true,
         "a shape poking out of the TOP of another's box is not inside it (pins y-max)")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(4, 0, 10, 2) }) == true,
         "poking out of the RIGHT is not inside it either (pins x-max)")
   CHECK(CO.selection_is_flat({ bb(0, 0, 10, 10), bb(-4, 0, 10, 2) }) == true,
         "and poking out of the LEFT (pins x-min)")
   CHECK(CO.selection_is_flat(nil) == false,
         "and nothing at all is not flat either - the argument has no default, on purpose")
end

-- WHICH boxes a run's flatness is measured on (2026-08-07,
-- side-on-flat-selections spec section 10c). The shapes the run will actually
-- cut: the selection when there is one, otherwise the ones the target chamfer
-- remembers. Spec section 3c used to accept that a recall run simply could not
-- be answered -- it can, because memory stores bounding boxes and those are
-- exactly what the flatness test consumes. No geometry is read and the live
-- Selection is never written, which is the cost section 3c refused to pay.
do
   local function bb(cx, cy, xlen, ylen) return { cx = cx, cy = cy, xlen = xlen, ylen = ylen } end
   local sel = { bb(0, 0, 2, 2) }
   local mem = { bb(9, 9, 4, 4), bb(20, 20, 4, 4) }

   CHECK(CO.flatness_fps(sel, mem) == sel,
         "a run with a SELECTION is judged on the selection - memory is not consulted at all")
   CHECK(CO.flatness_fps({}, mem) == mem,
         "a recall run - nothing selected - is judged on what the chamfer REMEMBERS")
   CHECK(#CO.flatness_fps({}, {}) == 0,
         "nothing selected and nothing remembered leaves nothing to measure")
   CHECK(#CO.flatness_fps(nil, nil) == 0,
         "and neither argument has a default: nil on both sides is still nothing to measure")
   CHECK(CO.flatness_fps(sel, nil) == sel,
         "a selection stands on its own - a chamfer with no memory does not take it away")
   CHECK(#CO.flatness_fps(nil, mem) == 2,
         "and memory stands on its own when the selection is missing rather than merely empty")

   -- The three-valued field the page reads (spec section 10f). Two states are
   -- not enough: "nothing to measure" and "measured and it nests" both grey the
   -- Side row, but they grey it for different reasons and the caption has to say
   -- which. Before this, the page told a recall run its shapes sat inside each
   -- other -- about a job it had never looked at.
   CHECK(CO.flat_field({ bb(0, 0, 2, 2) }) == "1",
         "a lone shape measures FLAT, so the field is 1 and the Side row stays live")
   CHECK(CO.flat_field({ bb(0, 0, 10, 10), bb(0, 0, 2, 2) }) == "0",
         "a ring measures NESTED, so the field is 0 - greyed, and the caption says why")
   CHECK(CO.flat_field({}) == "",
         "nothing to measure is the EMPTY string, which is neither of the other two answers")
   CHECK(CO.flat_field(nil) == "",
         "and nil measures the same as empty rather than throwing")
   -- The fail-safe, restated as a property rather than as three separate cases:
   -- the page greys on anything that is not exactly "1", so every answer other
   -- than a measured flat one lands on v1.14.0's released behaviour.
   CHECK(CO.flat_field({}) ~= "1" and CO.flat_field(nil) ~= "1"
         and CO.flat_field({ bb(0, 0, 10, 10), bb(0, 0, 2, 2) }) ~= "1",
         "every answer but a measured FLAT one is not-1, so a lost field greys rather than offering a control the run would ignore")
end

-- The side override on the aspire path (2026-08-06 side-greyed spec section 3a,
-- NARROWED 2026-08-07 by side-on-flat-selections spec section 4a).
--
-- Aspire's engine picks each loop's side from the NESTING, so a forced side up
-- there contradicts it -- that is the step S5 measured, and a nested selection
-- still drops to auto for exactly that reason. A FLAT selection has no nesting
-- to contradict: a lone closed loop is a pocket or an island and nothing in the
-- geometry says which, so the operator is the only source of the answer and the
-- override is honoured.
--
-- Below the ceiling the function is IDENTITY whatever the flatness, which is
-- what keeps the bands path byte-identical.
do
   CHECK(CO.effective_side("inside",  "aspire", false) == "auto", "a forced Inside drops to auto on a NESTED aspire run")
   CHECK(CO.effective_side("outside", "aspire", false) == "auto", "and so does a forced Outside")
   CHECK(CO.effective_side("auto",    "aspire", false) == "auto", "auto is already what that path does")
   CHECK(CO.effective_side("inside",  "aspire", true) == "inside",
         "but a FLAT aspire run HONOURS Inside - this is the pocket fix")
   CHECK(CO.effective_side("outside", "aspire", true) == "outside", "and Outside just the same")
   CHECK(CO.effective_side("auto",    "aspire", true) == "auto", "and auto is still auto")
   CHECK(CO.effective_side("inside",  "bands", false) == "inside", "the bands path is untouched: Inside stays Inside")
   CHECK(CO.effective_side("outside", "bands", false) == "outside", "and Outside stays Outside")
   CHECK(CO.effective_side("auto",    "bands", false) == "auto", "and auto stays auto")
   CHECK(CO.effective_side("inside",  "bands", true) == "inside", "flatness changes NOTHING on the bands path")
   CHECK(CO.effective_side("outside", "bands", true) == "outside", "for either forced side")
   CHECK(CO.effective_side("inside",  nil, false) == "inside", "no strategy is not the aspire path - the side stands")
   CHECK(CO.effective_side(nil, "aspire", false) == "auto", "a missing side reads as auto there")
   CHECK(CO.effective_side(nil, "bands", false) == nil,
         "and is passed through untouched everywhere else - resolve_directions already reads it as auto")
   -- The argument has NO DEFAULT and this is the reason: a caller that forgets
   -- it passes nil, which is falsy, which greys -- v1.14.0's released behaviour.
   -- Permissive is the wrong way for this one to fail.
   CHECK(CO.effective_side("inside", "aspire") == "auto",
         "a caller that FORGETS the flatness gets the safe answer, not the permissive one")
end

-- When a forced side IS dropped, the run says so (2026-08-07,
-- side-on-flat-selections spec section 4c). Greying the row explains itself on
-- the dialog, but a RECALL run never shows the operator that dialog state: they
-- selected nothing, the stored Inside is dropped for want of a selection to
-- measure, and without this line the run cuts the other side in silence. A run
-- that quietly changed a setting is exactly what CO.should_report exists to
-- break the silence for.
--
-- Pure, and keyed on the two values rather than on the run's kind, so it cannot
-- disagree with what CO.effective_side actually did.
do
   local NOTE = "Aspire picked the side itself - select the shapes to choose it yourself."
   CHECK(CO.dropped_side_note("inside", "auto") == NOTE,
         "a dropped Inside is reported - this is the recall run's missing sentence")
   CHECK(CO.dropped_side_note("outside", "auto") == NOTE, "and a dropped Outside just the same")
   CHECK(CO.dropped_side_note("inside", "inside") == nil,
         "a side that SURVIVED says nothing - the flat pocket run stays silent")
   CHECK(CO.dropped_side_note("outside", "outside") == nil, "and so does a surviving Outside")
   CHECK(CO.dropped_side_note("auto", "auto") == nil,
         "auto was never the operator forcing anything, so nothing was taken away")
   CHECK(CO.dropped_side_note(nil, "auto") == nil, "and a missing side is not a forced one either")
   -- Anything unrecognised is not a forced side. resolve_directions reads a
   -- value it does not know as auto, so nothing was dropped and claiming
   -- otherwise would put a sentence on a run that behaved normally.
   CHECK(CO.dropped_side_note("sideways", "auto") == nil, "an unrecognised side is not a forced one")
end

-- The depth Aspire's engine gets (spec section 8 C2). W is the setback; the cone's
-- flank makes the half-angle with the AXIS, so depth = W / tan(half-angle). At 90
-- degrees the two candidate relations coincide (tan 45 = 1), which is why C2 needs
-- a 60-degree bit at the machine: if Aspire's form disagrees there, THIS function
-- is the only line that changes.
do
   NEAR(CO.chamfer_cut_depth(0.3464, 90), 0.3464, 1e-9, "90 deg bit: depth equals setback")
   NEAR(CO.chamfer_cut_depth(0.1155, 60), 0.1155 / math.tan(math.rad(30)), 1e-9,
        "60 deg bit: steeper wall, deeper cut for the same setback")
   NEAR(CO.chamfer_cut_depth(0.2, 120), 0.2 / math.tan(math.rad(60)), 1e-9,
        "obtuse bit: shallower than its setback")
end

-- Narrow-feature guard: the size inverse (2026-08-04 spec section 4b).
-- The refusal message has to answer "what size CAN I use?", which means going
-- from a chamfer width back to the number the operator types - in whatever
-- mode he is typing in.
local Ain = CO.half_angle(90)
NEAR(CO.size_from_w("setback", 0.15, Ain), 0.15, 1e-9, "setback mode: size = W")
NEAR(CO.size_from_w("face", 0.15, Ain), 0.15 / math.sin(Ain), 1e-9, "face mode: size = W / sin(a)")
NEAR(CO.size_from_w("leg",  0.15, Ain), 0.15 / math.tan(Ain), 1e-9, "leg mode: size = W / tan(a)")

-- Round-trips exactly in every mode and at bit angles either side of 90, so the
-- suggested size can never be a different chamfer from the one measured.
for _, deg in ipairs({ 30, 60, 90, 120 }) do
   local aa = CO.half_angle(deg)
   for _, m in ipairs({ "setback", "face", "leg" }) do
      NEAR(CO.w_from_size(m, CO.size_from_w(m, 0.137, aa), aa), 0.137, 1e-9,
           "size_from_w round-trips w_from_size: " .. m .. " @" .. deg)
   end
end

local ok_bad = pcall(CO.size_from_w, "nonsense", 0.1, Ain)
CHECK(ok_bad == false, "an unknown size mode raises rather than guessing")

-- The nil-on-degenerate-divisor contract is load-bearing: CO.display_min_dia
-- guards on it. A second definition of size_from_w anywhere later in the file
-- would silently overwrite this one and the guard would go unreachable, which
-- is exactly what happened on 2026-08-04 - and the whole suite still passed.
CHECK(CO.size_from_w("face", 0.15, 0) == nil,
      "size_from_w returns nil rather than dividing by ~0 (face)")
CHECK(CO.size_from_w("leg", 0.15, 0) == nil,
      "size_from_w returns nil rather than dividing by ~0 (leg)")
NEAR(CO.size_from_w("setback", 0.15, 0), 0.15, 1e-9,
     "setback needs no divisor, so a zero angle is still fine")

-- CO.erosion_sign: one signed distance has to serve the whole selection, so
-- this answers for all of it or refuses to answer (narrow-break guard spec 4b).
CHECK(CO.erosion_sign({"outward"}, {0}) == -1,
      "erosion_sign: a lone outward loop shrinks (material inside)")
CHECK(CO.erosion_sign({"inward"}, {0}) == 1,
      "erosion_sign: a lone inward loop grows (material outside)")
CHECK(CO.erosion_sign({"inward", "inward"}, {0, 0}) == 1,
      "erosion_sign: two pockets side by side still grow")
CHECK(CO.erosion_sign({"outward", "inward"}, {0, 1}) == -1,
      "erosion_sign: an outline and its counter is one region, shrinking")
CHECK(CO.erosion_sign({"outward", "inward", "outward"}, {0, 1, 2}) == -1,
      "erosion_sign: alternating depths agree, however deep")
CHECK(CO.erosion_sign({"inward", "inward"}, {0, 1}) == nil,
      "erosion_sign: forced Inside over a nested selection has no single region")
CHECK(CO.erosion_sign({"outward", "outward"}, {0, 1}) == nil,
      "erosion_sign: forced Outside over a nested selection has no single region")
CHECK(CO.erosion_sign({}, {}) == nil, "erosion_sign: nothing selected, no answer")
CHECK(CO.erosion_sign({"sideways"}, {0}) == nil,
      "erosion_sign: an unrecognised direction refuses rather than guessing")
CHECK(CO.erosion_sign({"outward", "inward"}, {0}) == nil,
      "erosion_sign: mismatched lengths refuse")
CHECK(CO.erosion_sign(nil, nil) == nil, "erosion_sign: nil input refuses")

-- CO.bisect_w: the guard's answer is yes/no, but the message promises a size,
-- so search for it (narrow-break guard spec 4d). Pure - it is handed the probe
-- - so the whole search is exercised here with a known cutoff and never
-- touches the SDK.
do
   local calls
   local function cutoff_at(c)
      return function(w) calls = calls + 1; return w <= c end
   end

   calls = 0
   local got = CO.bisect_w(0.2, CO.BISECT_STEPS, cutoff_at(0.147))
   CHECK(type(got) == "number" and got <= 0.147,
         "bisect_w: never returns a size above the cutoff (got " .. tostring(got) .. ")")
   CHECK(type(got) == "number" and got >= 0.146,
         "bisect_w: lands within a rounding step of the cutoff (got " .. tostring(got) .. ")")
   CHECK(calls == CO.BISECT_STEPS,
         "bisect_w: calls the probe exactly steps times (got " .. tostring(calls) .. ")")

   calls = 0
   CHECK(CO.bisect_w(0.2, CO.BISECT_STEPS, cutoff_at(-1)) == nil,
         "bisect_w: nothing fits, no size named")
   CHECK(calls == CO.BISECT_STEPS,
         "bisect_w: still costs exactly steps probes when nothing fits")

   -- A cutoff below the rounding step rounds down to zero, and zero is not a
   -- size anyone can type.
   CHECK(CO.bisect_w(0.2, CO.BISECT_STEPS, cutoff_at(0.0004)) == nil,
         "bisect_w: a cutoff under the rounding step names nothing")

   -- Everything fits: the answer is the whole range, rounded down.
   local all = CO.bisect_w(0.2, CO.BISECT_STEPS, cutoff_at(999))
   CHECK(type(all) == "number" and all <= 0.2 and all >= 0.199,
         "bisect_w: everything fits, returns the top of the range (got " .. tostring(all) .. ")")

   CHECK(CO.bisect_w(0, CO.BISECT_STEPS, cutoff_at(1)) == nil, "bisect_w: zero range")
   CHECK(CO.bisect_w(-1, CO.BISECT_STEPS, cutoff_at(1)) == nil, "bisect_w: negative range")
   CHECK(CO.bisect_w(0.2, 0, cutoff_at(1)) == nil, "bisect_w: no steps, no answer")
   CHECK(CO.bisect_w(0.2, CO.BISECT_STEPS, nil) == nil, "bisect_w: no probe, no answer")
end

-- Narrow-break guard, Finding F (final review, 2026-08-04): the refusal prints
-- a suggested SIZE, not the bisected W directly, and the size has to convert
-- back to a W the guard would actually accept. CO.fmt_len rounds to 4dp to
-- NEAREST, and in Face/Leg mode (a non-1 conversion factor) that can round the
-- printed number UP past the W that passed. This is a measured case, not a
-- hypothetical: an included angle of 177 (a=CO.half_angle(177)) and a passing
-- W of 0.146 converts to 0.14605004770367 in face mode, which CO.fmt_len would
-- print as "0.1461" - and 0.1461 converts back to 0.14604993517893, ABOVE the
-- 0.146 that passed. Flooring to 4dp first (CO.floor4, same as
-- CO.display_max_size) prints "0.146", which converts back to 0.14594996944643
-- - at or below the W that passed, every time.
do
   local a177 = CO.half_angle(177)
   local W = 0.146
   local raw = CO.size_from_w("face", W, a177)
   local naive = tonumber(CO.fmt_len(raw))
   CHECK(CO.w_from_size("face", naive, a177) > W,
         "sanity: nearest-rounding (the old behaviour) really did round up past W")

   local floored = CO.floor4(raw)
   CHECK(CO.w_from_size("face", floored, a177) <= W,
         "floor4'd face-mode suggestion converts back to a W at or below the one that passed")

   -- Sweep, not just the one measured case: no fits/angle combination the
   -- bisect search can produce may floor-and-convert back above the W that
   -- passed, in Face mode.
   for _, deg in ipairs({ 5, 30, 60, 90, 120, 150, 177 }) do
      local a = CO.half_angle(deg)
      for milli = 1, 200 do
         local w = milli / 1000
         local size = CO.floor4(CO.size_from_w("face", w, a))
         CHECK(CO.w_from_size("face", size, a) <= w + 1e-9,
               "face mode never rounds up: deg=" .. deg .. " w=" .. w)
      end
   end
end

-- The ignored-vectors note (S6b, Tim's redline 2026-08-06). It stopped saying
-- "offsets", because on the aspire path the things it ignored are copies lying
-- ON the operator's own lines, and "offset" reads as nonsense there. Losing
-- "vector(s)" for real words means the singular has to be real too -- "ignored
-- 1 selected vectors" is exactly the kind of line that makes a tool look
-- unfinished, and one ignored vector is the common case.
do
   local one = CO.selection_skip_notes(0, 1)
   CHECK(one:find("ignored 1 selected vector that", 1, true) ~= nil,
         "skip notes: one ignored vector reads as singular")
   CHECK(one:find("vectors", 1, true) == nil,
         "skip notes: the singular does not say vectors")
   local many = CO.selection_skip_notes(0, 3)
   CHECK(many:find("ignored 3 selected vectors that", 1, true) ~= nil,
         "skip notes: more than one reads as plural")
   CHECK(CO.selection_skip_notes(0, 0) == "",
         "skip notes: nothing ignored says nothing")
end
