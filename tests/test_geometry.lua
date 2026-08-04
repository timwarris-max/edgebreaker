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

-- CO.partition_loops: drop the gadget's own offsets from the selection
-- instead of refusing the run (v1.0.8; box-select-everything is the natural
-- way to re-run). A loop is "ours" when its bbox matches an offset-layer
-- fingerprint; an unreadable bbox is unknown and the caller fails closed.
local FP = { cx = 5, cy = 5, xlen = 10, ylen = 10 }
local L_keep = { spans = { "user" }, bbox = { cx = 1, cy = 1, xlen = 2, ylen = 2 } }
local L_ours = { spans = { "offset" }, bbox = { cx = 5, cy = 5, xlen = 10, ylen = 10 } }
local L_unk  = { spans = { "mystery" } }
local kept, skipped, unk = CO.partition_loops({ L_keep, L_ours }, { FP }, 1e-6)
CHECK(#kept == 1 and kept[1] == L_keep and skipped == 1 and unk == 0,
      "partition: our offset dropped, user loop kept")
kept, skipped, unk = CO.partition_loops({ L_keep, L_ours }, {}, 1e-6)
CHECK(#kept == 2 and skipped == 0 and unk == 0,
      "partition: empty offset layer keeps everything (first run)")
kept, skipped, unk = CO.partition_loops({ L_unk }, { FP }, 1e-6)
CHECK(#kept == 0 and skipped == 0 and unk == 1,
      "partition: unreadable bbox is unknown, never silently kept or dropped")
kept, skipped, unk = CO.partition_loops({}, { FP }, 1e-6)
CHECK(#kept == 0 and skipped == 0 and unk == 0, "partition: no loops, no drama")
local L_noise = { spans = {}, bbox = { cx = 5 + 1e-9, cy = 5, xlen = 10, ylen = 10 } }
kept, skipped = CO.partition_loops({ L_noise }, { FP }, 1e-6)
CHECK(#kept == 0 and skipped == 1,
      "partition: sub-epsilon float noise still identifies our offset")
local L_near = { spans = {}, bbox = { cx = 5.1, cy = 5, xlen = 10, ylen = 10 } }
kept, skipped = CO.partition_loops({ L_near }, { FP }, 1e-6)
CHECK(#kept == 1 and skipped == 0,
      "partition: a genuinely different bbox stays user input")
local L2 = { spans = {}, bbox = { cx = 9, cy = 9, xlen = 4, ylen = 4 } }
kept = CO.partition_loops({ L_keep, L2 }, { FP }, 1e-6)
CHECK(kept[1] == L_keep and kept[2] == L2, "partition: kept loops preserve order")

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
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, nil) == base,
         "sharp off: patch_template_run is byte-identical to the old pipeline")
   -- 2026-08-03: the sharp argument carries the SIDE, not a bare yes.
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "inside")
         == CO.patch_template_sharp(base, "inside"),
         "sharp inside: exactly the old pipeline plus the inside sharp patch")
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "outside")
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
   local ins = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "inside")
   local outs = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, "outside")
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
   local br, berr = CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, 1, true)
   CHECK(br == nil and type(berr) == "string" and berr:find("Outside", 1, true) ~= nil,
         "the old boolean `true` is refused by the pipeline, not silently sharpened inside")
end
do
   local bad, err = CO.patch_template_run("junk", 0.1, 0, 1, 1, nil)
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
