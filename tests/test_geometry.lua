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

-- evaluate() with chamfer too big for a safe cut: band collapses -> not ok, no presets
local big = CO.evaluate("setback", 0.120, 90, 0.25)  -- W=0.120 > g_hi region
CHECK(big.ok == false, "oversized chamfer: not ok")
CHECK(#big.presets == 0, "no presets when band collapses")
CHECK(type(big.reason) == "string" and #big.reason > 0, "reason explains the block")

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

local sharp = CO.patch_template_sharp(shipped_sharp)
CHECK(type(sharp) == "string" and #sharp == #shipped_sharp,
      "sharp patch preserves the file length")
CHECK(CO.read_machine_vectors(sharp) == "inside",
      "patched MV reads back as Inside through the existing reader")
CHECK(sharp:byte(CO.find_sharpen_offset(sharp)) == 1, "sharpen flag reads back 1")
CHECK(sharp:sub(CO.find_allowance_offset(sharp), CO.find_allowance_offset(sharp) + 7)
      == CO.encode_double(0), "allowance is left untouched -- Aspire ignores it under sharpening")
-- Nothing else moves: the two fields are the only difference.
do
   local diff = 0
   for i = 1, #shipped_sharp do
      if shipped_sharp:byte(i) ~= sharp:byte(i) then diff = diff + 1 end
   end
   CHECK(diff == 2, "only the two patched fields change (got " .. diff .. " differing bytes)")
end
CHECK(CO.find_depth_offset(sharp) == CO.find_depth_offset(shipped_sharp),
      "sharp patch leaves the depth field where it was")
CHECK(CO.read_template_layers(sharp)[1] == CO.read_template_layers(shipped_sharp)[1],
      "sharp patch leaves the layer restriction alone")
CHECK(CO.read_template_units(sharp) == CO.read_template_units(shipped_sharp),
      "sharp patch leaves the units flag alone")
-- Refusal: junk bytes name the missing tag.
local nope, nerr = CO.patch_template_sharp("junk")
CHECK(nope == nil and type(nerr) == "string", "junk bytes are refused with a reason")

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
-- the pipeline's bytes are identical to composing the three v1.10.x patches by
-- hand. Not "close" -- identical, the v1.6.0 "at S = 0" pattern.
do
   local base = CO.patch_template_layer(
      CO.patch_template_start_depth(
         CO.patch_template_depth(shipped_sharp, 0.0838), 0.05), 3)
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, nil) == base,
         "sharp off: patch_template_run is byte-identical to the old pipeline")
   CHECK(CO.patch_template_run(shipped_sharp, 0.0838, 0.05, 3, true)
         == CO.patch_template_sharp(base),
         "sharp on: exactly the old pipeline plus the sharp patch")
end
do
   local bad, err = CO.patch_template_run("junk", 0.1, 0, 1, nil)
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
-- W + s.g -- so starting from -s.g (the forced-inward sharp distance) and
-- adding the shift always lands on +W, for ANY bit/size/percent/angle. If a
-- future edit ever flips a sign or swaps g/d, this catches it immediately
-- rather than waiting on a live sitting.
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
      NEAR(-s.g + CO.sharp_offset_shift(s.d, c.deg), c.W, 1e-9,
           string.format("sharp invariant holds: dia=%g W=%g pct=%d deg=%d",
                          c.dia, c.W, c.percent, c.deg))
   end
end
