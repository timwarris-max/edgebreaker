-- M4 community-release tests: template metadata extractors, validation, units.
local CO = EdgeBreaker

local f = assert(io.open("tests/fixtures/sample.ToolpathTemplate", "rb"))
local sample = f:read("*a"); f:close()

local fo = assert(io.open("tests/fixtures/mv-outside.ToolpathTemplate", "rb"))
local mvOutside = fo:read("*a"); fo:close()

local layers = CO.read_template_layers(sample)
CHECK(type(layers) == "table" and #layers == 1 and layers[1] == "GREEN - Rough Track",
      "sample fixture has one layer restriction")

local outsideLayers = CO.read_template_layers(mvOutside)
CHECK(type(outsideLayers) == "table" and #outsideLayers == 0,
      "unscoped fixture has no layer restriction (empty array, not an error)")

local nl, nerr = CO.read_template_layers("not a template")
CHECK(nl == nil and type(nerr) == "string", "missing _vcgfNumLayers tag reports an error")

local truncated = sample:sub(1, 6225)   -- cuts partway through _vcgfLayerName0's chars
local tl, terr = CO.read_template_layers(truncated)
CHECK(tl == nil and type(terr) == "string", "layer name running past end-of-file reports an error")

-- 1.1.0: one fixed template name. The bit is no longer encoded in it, so the
-- name carries no geometry to parse.
CHECK(CO.TEMPLATE_NAME == "EdgeBreaker.ToolpathTemplate", "single template has a fixed name")
CHECK(CO.parse_template_name == nil, "per-bit filename parsing is gone")
CHECK(CO.sdk_list_templates == nil, "template scanning is gone")

-- Single dialog: the step-1 picker is deleted, and the callback that replaced
-- it is a GLOBAL Aspire looks up by name. A rename would break the feature
-- silently -- the button would simply do nothing.
CHECK(CO.sdk_pick_tool == nil, "the step-1 bit picker is gone")
CHECK(type(OnToolPicker_ToolChooseButton) == "function",
      "the picker callback is defined at file scope")

-- The empty-state word has exactly one writer. The page owns it in its own
-- #BitBadgeNone span; Aspire owns #BitBadgeName from AddToolPicker on. Seeding
-- text into BitBadgeName from Lua makes a second writer of the same words, and
-- on a machine with no remembered bit BOTH land: the badge read
-- "No bit yetNo bit yet" in Aspire on 2026-07-28. The layout gate can never see
-- this -- it renders the .htm and never runs the Lua -- so pin it here.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find('AddLabelField%("BitBadgeName", ""%)') ~= nil,
         "Lua declares BitBadgeName empty and leaves the wording to the page")
end

-- 11 pre-flight messages stay native by design (nothing has started, and one
-- of them reports that the HTML is missing), plus the one inside
-- show_message's own fallback. Anything else calling DisplayMessageBox
-- directly is a message that shipped unstyled -- which is invisible until
-- someone triggers it in Aspire.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   local _, n = src:gsub("DisplayMessageBox%(", "")
   CHECK(n == 12, "only the 11 pre-flight messages and show_message's fallback "
                  .. "call DisplayMessageBox directly (found " .. n .. ")")
end

-- The cut positions are written out twice -- CO.PRESETS here, PRESETS in the
-- dialog's own JavaScript -- and neither side can see the other. Drift is silent
-- and one-directional: the page would offer a position Lua then refuses to
-- recognize, and apply_settings would quietly seed 80% instead on the next run.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local src = f:read("*a"); f:close()
   local list = src:match("PRESETS%s*=%s*%[([%d,%s]*)%]")
   CHECK(list ~= nil, "the dialog declares a PRESETS array")
   local page = {}
   for n in tostring(list):gmatch("%d+") do page[#page + 1] = tonumber(n) end
   CHECK(#page == #CO.PRESETS, "the page offers as many cut positions as Lua accepts")
   local same = #page == #CO.PRESETS
   for i, v in ipairs(CO.PRESETS) do if page[i] ~= v then same = false end end
   CHECK(same, "the page's cut positions are Lua's, in the same order")
end

-- unit info
local mm = CO.unit_info(true)
CHECK(mm.suffix == "mm", "mm suffix"); NEAR(mm.default_size, 0.5, 1e-9, "mm default size")
local inch = CO.unit_info(false)
CHECK(inch.suffix == "in", "in suffix"); NEAR(inch.default_size, 0.020, 1e-9, "in default size")

-- machine-vectors setting
local function slurp(p) local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b end
local mvOn      = slurp("tests/fixtures/mv-on.ToolpathTemplate")
local mvOutside = slurp("tests/fixtures/mv-outside.ToolpathTemplate")
CHECK(CO.read_machine_vectors(mvOn) == "on", "MV=On read")
CHECK(CO.read_machine_vectors(mvOutside) == "outside", "MV=Outside read")
local mv, mverr = CO.read_machine_vectors("not a template")
CHECK(mv == nil and type(mverr) == "string", "missing MV tag reports an error")

-- template unit provenance (_vcgfInMM)
local mmSample = slurp("tests/fixtures/mm-sample.ToolpathTemplate")
CHECK(CO.read_template_units(mmSample) == "mm", "mm-sample template reads mm units")
CHECK(CO.read_template_units(mvOn) == "in", "mv-on template reads in units")
local tu, tuerr = CO.read_template_units("not a template")
CHECK(tu == nil and type(tuerr) == "string", "missing _vcgfInMM tag reports an error")

-- mm depth is stored in native mm units, not converted (byte-pin)
local mm_off = CO.find_depth_offset(mmSample)
CHECK(mmSample:sub(mm_off, mm_off + 7) == CO.encode_double(2.0),
      "mm template stores depth in native mm units")

-- Strategy-template validation (1.1.0). Only the three things Aspire bakes in
-- that we cannot set ourselves are checked; the bit is no longer one of them.
local wrongLayer = slurp("tests/fixtures/wrong-layer.ToolpathTemplate")

-- v1.4.0 made the layer restriction MANDATORY, and the pre-1.4.0 fixtures
-- (mv-on, mv-outside, mm-sample) carry none -- they now stop at the layer check
-- before reaching the branch each was written to exercise. Deriving the
-- specimens from the SHIPPED template instead keeps those branches under test:
-- it is correctly scoped, so flipping exactly the one byte a branch reads
-- isolates that branch. These bytes are parsed by our own readers and never
-- handed to Aspire, so the Aspire-authored rule does not apply to them.
local shippedT = slurp("gadget/EdgeBreaker/" .. CO.TEMPLATE_NAME)
local function set_tag_byte(bytes, tag, value)
   local needle = tag:gsub(".", "%0\0")
   local _, e = string.find(bytes, needle, 1, true)
   assert(e, "tag not found: " .. tag)
   return bytes:sub(1, e + 4) .. string.char(value) .. bytes:sub(e + 6)
end

CHECK(CO.validate_template(shippedT, "in") == true, "good template validates")

-- The new rule itself: no restriction at all is now a rejection, and the
-- message has to name the layer the user must re-save against.
local unscoped, unscoped_why = CO.validate_template(mvOn, "in")
CHECK(unscoped == nil and unscoped_why:find(CO.TEMPLATE_LAYER, 1, true) ~= nil
      and unscoped_why:find("no layer", 1, true) ~= nil,
      "an unscoped template is refused as of v1.4.0, naming the required layer")

local scopedOutside = set_tag_byte(shippedT, "_ppdProfileType", 0)
CHECK(CO.read_machine_vectors(scopedOutside) == "outside",
      "the derived Outside specimen really reads Outside")
local bad_mv, mv_why = CO.validate_template(scopedOutside, "in")
CHECK(bad_mv == nil and mv_why:find("Machine Vectors"), "MV=Outside flagged")

local bad_layer, layer_why = CO.validate_template(wrongLayer, "in")
CHECK(bad_layer == nil and layer_why:find("layer"), "wrong layer flagged")

local bad_bytes, bytes_why = CO.validate_template("junk", "in")
CHECK(bad_bytes == nil and type(bytes_why) == "string", "unreadable content flagged")

local no_bytes, nil_why = CO.validate_template(nil, "in")
CHECK(no_bytes == nil and nil_why:find("read"), "nil bytes flagged")

-- Units are checked against the JOB now, not a filename: patching an inch
-- depth into a template a mm job will read as mm cuts the wrong depth.
local mismatch, mm_why = CO.validate_template(shippedT, "mm")
CHECK(mismatch == nil and mm_why:find("inch") and mm_why:find("mm"),
      "inch template in a mm job is flagged, naming both unit systems")
local scopedMM = set_tag_byte(shippedT, "_vcgfInMM", 1)
CHECK(CO.read_template_units(scopedMM) == "mm", "the derived mm specimen really reads mm")
CHECK(CO.validate_template(scopedMM, "mm") == true, "mm template validates in a mm job")
CHECK(CO.validate_template(scopedMM, "in") == nil, "mm template is refused in an inch job")

-- v1.6.0: a patchable START depth is REQUIRED, the same way the layer
-- restriction became required in v1.4.0. Every Aspire profile template
-- carries one, so this costs nothing real -- and it turns a template we
-- cannot aim in Z into a refusal instead of a silent wrong cut.
local orig_find_start = CO.find_start_depth_offset
CO.find_start_depth_offset = function() return nil, "no start depth" end
local no_start, start_why = CO.validate_template(shippedT, "in")
CHECK(no_start == nil and string.find(start_why, "re-save", 1, true),
      "a template with no patchable start depth is refused")
CO.find_start_depth_offset = orig_find_start

-- v1.11.0: the MV and sharpen fields become template obligations, checked
-- at validation time rather than failing at first use -- the v1.6.0 start-depth
-- precedent. The shipped template carries both (pinned above), so this only
-- ever catches a genuinely broken re-save. Allowance is deliberately NOT a
-- requirement here -- R1 dropped the allowance patch entirely (spec 15:
-- Aspire locks and discards it while sharpening is on), so a template with no
-- readable allowance offset must still validate.
for _, probe in ipairs({ "find_mv_value_offset", "find_sharpen_offset" }) do
   local orig = CO[probe]
   CO[probe] = function() return nil, "gone" end
   local ok_v, why_v = CO.validate_template(shippedT, "in")
   CHECK(ok_v == nil and type(why_v) == "string"
         and string.find(why_v, "re-save", 1, true) ~= nil,
         "a template failing " .. probe .. " is refused with the re-save hint")
   CO[probe] = orig
end
do
   local orig = CO.find_allowance_offset
   CO.find_allowance_offset = function() return nil, "gone" end
   CHECK(CO.validate_template(shippedT, "in") == true,
         "a template with no readable allowance offset still validates -- R1 dropped that requirement")
   CO.find_allowance_offset = orig
end
CHECK(CO.validate_template(shippedT, "in") == true,
      "the shipped template still validates with both sharp fields required")

-- An absent units tag must not block an otherwise-good template: silence is
-- not evidence of a mismatch.
local orig_units = CO.read_template_units
CO.read_template_units = function() return nil, "no tag" end
CHECK(CO.validate_template(shippedT, "mm") == true, "unreadable units tag does not block")
CO.read_template_units = orig_units

-- layers == nil branch: truncate so the depth check passes but layers fails
local truncated_mvOn = mvOn:sub(1, 6139)
local bad_truncated, trunc_why = CO.validate_template(truncated_mvOn, "in")
CHECK(bad_truncated == nil and string.find(trunc_why, "re-save", 1, true),
      "truncated layers tag causes validation failure with re-save hint")

-- Every rejection has to say something a user can act on.
for _, why in ipairs({ mv_why, layer_why, bytes_why, nil_why, mm_why, trunc_why }) do
   CHECK(type(why) == "string" and #why > 20, "rejection reason is explanatory")
end

-- The version is user-visible (the dialog title) and names the .vgadget the
-- release script builds, so it gets a gate of its own. (The current-version
-- assertion lives with the v1.5.0 rename block at the end of this file.)

-- The SHIPPED template is now the gadget's single point of failure: one file
-- serves every bit, so if it is ever re-saved wrong nothing works. Pin it here
-- rather than discovering it in a live Aspire sitting.
local shipped_f = io.open("gadget/EdgeBreaker/" .. CO.TEMPLATE_NAME, "rb")
CHECK(shipped_f ~= nil, "the shipped strategy template exists under its fixed name")
if shipped_f then
   local shipped = shipped_f:read("*a"); shipped_f:close()
   local sok, swhy = CO.validate_template(shipped, "in")
   CHECK(sok == true, "the shipped template validates in an inch job: " .. tostring(swhy))
   CHECK(CO.read_machine_vectors(shipped) == "on", "shipped template machines On")
   CHECK(CO.read_template_units(shipped) == "in", "shipped template is an inch template")
   -- Depth must be patchable: exactly one _ppdCutDepth, and the pass list and
   -- pass count must both take the value (patching only the double shipped an
   -- undersized chamfer once already -- see patch_pass_depths).
   local soff, serr = CO.find_depth_offset(shipped)
   CHECK(soff ~= nil, "shipped template has exactly one patchable cut depth: " .. tostring(serr))
   local patched = CO.patch_template_depth(shipped, 0.1234)
   CHECK(patched ~= nil and #patched > 0, "shipped template accepts a depth patch")
   if patched then
      local poff = CO.find_depth_offset(patched)
      CHECK(patched:sub(poff, poff + 7) == CO.encode_double(0.1234),
            "the patched depth reads back as written")
      CHECK(patched:find(("0.123400"):gsub(".", "%0\0"), 1, true) ~= nil,
            "the pass list carries the patched depth too, not just the double")
   end
   -- Layer scope: EXACTLY slot 1's layer as of v1.4.0. It is no longer optional
   -- -- it is what patch_template_layer rewrites, so an unscoped template has
   -- nothing to aim and would cut every chamfer's offsets at this run's depth.
   local slayers = CO.read_template_layers(shipped)
   CHECK(slayers ~= nil, "shipped template layer list is readable")
   CHECK(slayers ~= nil and #slayers == 1,
         "shipped template names exactly one layer")
   CHECK(slayers ~= nil and slayers[1] == CO.TEMPLATE_LAYER,
         "shipped template is scoped to slot 1's layer, not '" .. tostring(slayers and slayers[1]) .. "'")
end

-- CO.should_restore_layer: after a run, put the user's active layer back.
-- Restore only when we captured a real, different layer name; anything else
-- (capture failed -> nil, empty, our own layer, non-string) means leave Aspire alone.
CHECK(CO.should_restore_layer("Layer 1") == true,
      "restore a normal user layer")
CHECK(CO.should_restore_layer(nil) == false,
      "no captured name -> no restore")
CHECK(CO.should_restore_layer("") == false,
      "empty name -> no restore")
CHECK(CO.should_restore_layer(CO.offset_layer_name(1)) == false,
      "our own offset layer -> no restore (never re-activate a wipe target)")
CHECK(CO.should_restore_layer(CO.offset_layer_name(12)) == false,
      "ANY chamfer's offset layer -> no restore, not just the one being built")
CHECK(CO.should_restore_layer(CO.LEGACY_OFFSET_LAYER) == false,
      "the pre-1.4.0 layer is still never restored")
CHECK(CO.should_restore_layer("Chamfer notes") == true,
      "a user layer whose name merely mentions chamfers is restored normally")
CHECK(CO.should_restore_layer(42) == false,
      "non-string -> no restore")

-- CO.should_recalc_all: the FALLBACK when the per-toolpath recalc is
-- unavailable. Running recalc-all in a job with existing toolpaths
-- recalculates work that is not ours - only safe when the job had none.
CHECK(CO.should_recalc_all(0) == true,
      "recalc-all allowed when the job had no toolpaths")
CHECK(CO.should_recalc_all(1) == false,
      "one existing toolpath -> skip recalc-all")
CHECK(CO.should_recalc_all(5) == false,
      "several existing toolpaths -> skip recalc-all")

-- Toolpath ownership marker (v1.0.7, per-slot since v1.4.0): re-runs replace
-- only toolpaths whose NAME carries THIS chamfer's marker, so both user
-- toolpaths and other chamfers are untouchable by construction. The per-slot
-- parsing itself is exercised in test_slots.lua; this is the release-facing
-- half -- that a generated name is always findable again.
local tn = CO.toolpath_name(0.02, "in", 1)
CHECK(tn:find("0.02", 1, true) ~= nil and tn:find("in", 1, true) ~= nil,
      "toolpath name carries the size and units")
CHECK(CO.slot_from_toolpath_name(tn) == 1, "every generated name is findable by slot")
local tmm = CO.toolpath_name(0.5, "mm", 2)
CHECK(CO.slot_from_toolpath_name(tmm) == 2 and tmm:find("0.5 mm", 1, true) ~= nil,
      "mm names carry their slot too")
CHECK(CO.slot_from_toolpath_name("Chamfer 0.02 in " .. CO.toolpath_marker(1) .. " (1)") == 1,
      "marker mid-name still counts (Aspire suffixes duplicates)")
CHECK(CO.slot_from_toolpath_name("Profile 1") == nil, "plain user toolpath name is unowned")
CHECK(CO.slot_from_toolpath_name("EdgeBreaker") == nil,
      "the bare word without brackets is NOT the marker (rename-to-keep escape hatch)")
CHECK(CO.slot_from_toolpath_name(nil) == nil, "nil name is safely unowned")
CHECK(CO.slot_from_toolpath_name(42) == nil, "non-string name is safely unowned")
-- The marker contains [ and ] - Lua pattern magic. Matching must plain-find.
CHECK(CO.slot_from_toolpath_name("x" .. CO.toolpath_marker(9) .. "y") == 9,
      "marker match is plain text, no pattern surprises")
-- Another chamfer's marker must never read as this one.
CHECK(CO.slot_from_toolpath_name(CO.toolpath_marker(1)) ~= 2,
      "slot 1's marker is not slot 2's")

-- v1.4.0: the template's layer restriction is rewritten so each chamfer cuts
-- its own layer. v1.13.0 rewrites the WHOLE restriction (not just two digits,
-- see CO.patch_template_layer) because the band suffix moved the separator.
-- Same-length means the file's length, record structure and every offset in
-- it are untouched -- the same class of edit as the depth patch, and NOT the
-- record insertion Aspire rejects. The read-back through read_template_layers
-- is the check that actually matters: it proves Aspire's own layout still
-- parses after the swap.
local tbytes
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.ToolpathTemplate", "rb"))
   tbytes = f:read("*a"); f:close()
end

local shipped_layers = CO.read_template_layers(tbytes)
CHECK(shipped_layers ~= nil and #shipped_layers == 1
      and shipped_layers[1] == CO.TEMPLATE_LAYER,
      "shipped template is restricted to slot 1's layer")

local p3 = CO.patch_template_layer(tbytes, 3, 1)
CHECK(type(p3) == "string", "patching to slot 3 succeeds")
CHECK(p3 ~= nil and #p3 == #tbytes, "patch does not change the file length")
local back = p3 and CO.read_template_layers(p3)
CHECK(back ~= nil and #back == 1 and back[1] == CO.offset_layer_name(3, 1),
      "patched template reads back as slot 3's layer")

-- Format-independent stand-in for the old two-digit byte-diff invariant: it
-- can no longer assert an exact byte count (the whole name is rewritten now,
-- not two digits), but the underlying guarantee -- nothing outside the layer
-- restriction moves -- is still fully assertable and strictly stronger than a
-- diff count, because it also catches a same-length write landing at the
-- wrong offset or a second incidental mutation elsewhere in the file. Located
-- by the needle rather than a hardcoded offset, so it survives a future
-- prefix change too.
local ns, ne = tbytes:find((CO.TEMPLATE_LAYER):gsub(".", "%0\0"), 1, true)
CHECK(p3 ~= nil and p3:sub(1, ns - 1) == tbytes:sub(1, ns - 1)
      and p3:sub(ne + 1) == tbytes:sub(ne + 1),
      "slot 3's patch touches nothing outside the layer restriction")

local p12 = CO.patch_template_layer(tbytes, 12, 1)
CHECK(p12 and #p12 == #tbytes, "a two-digit slot still preserves the length")
local back12 = p12 and CO.read_template_layers(p12)
CHECK(back12 ~= nil and back12[1] == CO.offset_layer_name(12, 1),
      "slot 12 reads back correctly")
CHECK(p12 ~= nil and p12:sub(1, ns - 1) == tbytes:sub(1, ns - 1)
      and p12:sub(ne + 1) == tbytes:sub(ne + 1),
      "slot 12's patch touches nothing outside the layer restriction")

-- Everything else the loader reads must survive untouched.
CHECK(p3 and CO.read_machine_vectors(p3) == "on", "patch leaves Machine Vectors alone")
CHECK(p3 and CO.read_template_units(p3) == CO.read_template_units(tbytes),
      "patch leaves the units flag alone")
CHECK(p3 and CO.find_depth_offset(p3) == CO.find_depth_offset(tbytes),
      "patch leaves the depth field where it was")

-- Slot 1, band 1 is no longer a no-op as of v1.13.0: the shipped template's
-- v1.12.0-format restriction ('EdgeBreaker - Offset 01') differs from the
-- banded name even for the first slot/band, because the separator itself
-- changed. It still patches safely to the same length and reads back right.
local p1 = CO.patch_template_layer(tbytes, 1, 1)
CHECK(p1 ~= nil and #p1 == #tbytes, "patching to slot 1, band 1 still preserves length")
local back1 = p1 and CO.read_template_layers(p1)
CHECK(back1 ~= nil and back1[1] == CO.offset_layer_name(1, 1),
      "slot 1, band 1 reads back as the new banded name")

-- Refuse anything that is not the template we shipped. (The plan pointed at
-- tests/tools/; the fixture actually lives in tests/fixtures/.)
local wrong
do
   local f = assert(io.open("tests/fixtures/wrong-layer.ToolpathTemplate", "rb"))
   wrong = f:read("*a"); f:close()
end
local bad, berr = CO.patch_template_layer(wrong, 2, 1)
CHECK(bad == nil and type(berr) == "string",
      "a template restricted to some other layer is refused, not patched")

CHECK(CO.patch_template_layer(tbytes, 0) == nil, "slot 0 refused")
CHECK(CO.patch_template_layer(tbytes, 100) == nil, "slot 100 refused")
CHECK(CO.patch_template_layer(tbytes, nil) == nil, "nil slot refused")

-- ==================== v1.5.0 rename (EdgeBreaker) ====================
-- The gadget is EdgeBreaker as of 1.5.0. Every name the JOB sees moves --
-- layers, toolpath tags, template filename, settings file -- while the v1.4.x
-- spellings stay recognizable so existing chamfers can be ADOPTED rather than
-- orphaned (spec 6). One parser serves both generations; the old_* entry
-- points differ only in which prefix they are handed.
CHECK(CO.VERSION == "1.13.0", "version gate: 1.13.0")
-- The page prints the version in its own header and cannot read the Lua, so the
-- two drift silently -- and the number on screen is what an operator quotes in
-- a bug report.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find('<span class="ver">v' .. CO.VERSION .. '</span>', 1, true) ~= nil,
         "the setup dialog's header prints CO.VERSION")
end
CHECK(CO.offset_layer_name(7) == "EdgeBreaker Offset 07-1", "new layer name")
CHECK(CO.toolpath_marker(7) == "[EdgeBreaker 07]", "new marker")
CHECK(CO.TEMPLATE_NAME == "EdgeBreaker.ToolpathTemplate", "template name")
CHECK(CO.slot_from_layer_name("ChamferOffset - Offset 07") == nil, "old layer no longer ours")
CHECK(CO.old_slot_from_layer_name("ChamferOffset - Offset 07") == 7, "old layer adoptable")
CHECK(CO.old_slot_from_layer_name("EdgeBreaker - Offset 07") == nil, "new name not old")
CHECK(CO.old_slot_from_toolpath_name("Chamfer 0.02 in [ChamferOffset 03]") == 3, "old tag adoptable")
CHECK(CO.old_slot_from_toolpath_name("x [ChamferOffset]") == nil, "unnumbered legacy stays legacy")
CHECK(CO.settings_path():find("EdgeBreaker%-settings%.txt") ~= nil, "settings file renamed")

-- v1.7.0 QUIET SUCCESS -----------------------------------------------------
-- A clean run says nothing at all: the toolpath in the panel, the orange
-- offsets on the canvas and the restored selection are the report. Silence is
-- only honest when there is genuinely nothing to say, so this is the predicate
-- that decides -- and everything that reached sel_notes counts as something.
CHECK(CO.should_report(true, "") == true, "quiet: a failure always reports")
CHECK(CO.should_report(false, "") == false, "quiet: a clean run is silent")
CHECK(CO.should_report(false, nil) == false, "quiet: nil notes are silent")
CHECK(CO.should_report(false, "\n\n") == false, "quiet: whitespace is not a note")
CHECK(CO.should_report(false,
   "\n\nNote: 3 vector(s) were too narrow to chamfer at this size and were skipped")
   == true, "quiet: a skipped shape breaks silence")
CHECK(CO.should_report(false, "\n\nNote: 2 open vector(s) skipped.") == true,
      "quiet: an open vector breaks silence")
CHECK(CO.should_report(true, "\n\nNote: something") == true,
      "quiet: trouble and notes together still report")
CHECK(CO.should_report(true, nil) == true, "quiet: a failure reports with no notes")

-- The one path the Task 2 review missed, found by the v1.7.0 whole-branch review:
-- the delete is wrapped in pcall, and a THROW used to skip the whole result block,
-- leaving trouble false. Harmless while every run ended in a message box; under
-- silence it leaves a duplicate toolpath with nothing said about it.
local t, n = CO.delete_outcome(true, 0, 0, 1)
CHECK(t == false and n == "", "delete: nothing to remove is silent")
t, n = CO.delete_outcome(true, 2, 0, 1)
CHECK(t == false and n == "Replaced Chamfer 1 (removed 2 previous toolpath(s)).",
      "delete: a clean replace reports the count and stays silent")
t, n = CO.delete_outcome(true, 1, 1, 3)
CHECK(t == true and n:find("could not be removed", 1, true) ~= nil,
      "delete: a refused delete is trouble")
t, n = CO.delete_outcome(false, nil, nil, 1)
CHECK(t == true, "delete: a THROWN delete is trouble, not silence")
CHECK(n:find("duplicates", 1, true) ~= nil,
      "delete: a thrown delete names the duplicate it just left behind")

-- The receipt is gone, not hidden. These are the entry points main() used to
-- call; if any of them comes back, the dialog it feeds does not exist.
CHECK(CO.sdk_show_receipt == nil, "receipt: sdk_show_receipt removed")
CHECK(CO.receipt_scene == nil, "receipt: receipt_scene removed")
CHECK(CO.receipt_banner == nil, "receipt: receipt_banner removed")
CHECK(CO.receipt_shapes_phrase == nil, "receipt: receipt_shapes_phrase removed")
CHECK(CO.receipt_size == nil, "receipt: receipt_size removed")
CHECK(CO.sdk_object_loops == nil, "receipt: sdk_object_loops removed")
CHECK(CO.RECEIPT_FIELDS == nil, "receipt: RECEIPT_FIELDS removed")
CHECK(CO.RECEIPT_SIZE == nil, "receipt: RECEIPT_SIZE removed")
CHECK(CO.RECEIPT_STATE == nil, "receipt: RECEIPT_STATE removed")
CHECK(CO.html_escape == nil, "receipt: html_escape removed with its only callers")

-- v1.10.0 SCREEN MEASURING ---------------------------------------------------
-- The window size now comes from the page, through a hidden field, exactly like
-- every other value on this dialog. Three things can drift silently and none of
-- them can be caught by rendering or by running the geometry: the field NAME
-- (Lua and two pages must agree), the measuring window's SIZE (Lua opens it,
-- the gate measures it), and the silence contract.
do
   local function slurp_text(p)
      local f = assert(io.open(p, "rb")); local b = f:read("*a"); f:close(); return b
   end
   -- Normalised to LF right after the read: a fresh clone materialises CRLF
   -- (core.autocrlf, no .gitattributes), and the two "function ... .-\nend\n"
   -- body-matches below require a bare "\n" right before "end" -- under CRLF
   -- that byte is "\r", so both silently fail to match. Worse than failing
   -- loud: both are guarded `body == nil or ...`, so the one automated check
   -- on "sizing never speaks" goes vacuously true in exactly the environment
   -- (a fresh public-repo clone) CLAUDE.md requires running this suite in
   -- before a release.
   local lua  = slurp_text("gadget/EdgeBreaker/EdgeBreaker.lua"):gsub("\r\n", "\n")
   local page = slurp_text("gadget/EdgeBreaker/MeasureScreen.htm")
   local dlg  = slurp_text("gadget/EdgeBreaker/EdgeBreakerDialog.htm")

   -- One field name, three files. A rename in any one of them means every
   -- machine silently falls back to the default window -- the v1.9.0 defect,
   -- back again with no symptom anyone could report.
   CHECK(page:find('id="Screen" name="Screen"', 1, true) ~= nil,
         "the measuring page declares the Screen field")
   CHECK(dlg:find('id="Screen" name="Screen"', 1, true) ~= nil,
         "the setup dialog declares the Screen field too")
   CHECK(lua:find('GetTextField%("Screen"%)') ~= nil,
         "Lua reads the field by that name")

   -- A field that is read but never created (AddTextField) fails silently --
   -- GetTextField just returns nil/throws inside a pcall, so the measuring
   -- window returns forever or the size goes stale, with nothing to see
   -- offline. Exactly two call sites must create it: the measuring dialog and
   -- the setup dialog.
   local _, screen_adds = lua:gsub('AddTextField%("Screen"', "")
   CHECK(screen_adds == 2,
         "AddTextField(\"Screen\" appears exactly twice: measuring dialog + setup dialog")
   local dw, dh = lua:match("CO%.MEASURE_SIZE%s*=%s*{%s*(%d+)%s*,%s*(%d+)%s*}")
   CHECK(dw == "140" and dh == "90",
         "the blink window is 140x90 -- an OUTER size, so the page gets 138x40; " ..
         "keep SCR_W/SCR_H in the layout gate in step")

   -- Both pages must actually read the screen, not just declare a field.
   CHECK(page:find("screen.availWidth", 1, true) ~= nil,
         "the measuring page reads availWidth")
   CHECK(dlg:find("screen.availWidth", 1, true) ~= nil,
         "the setup dialog reports its screen too, which is what stops the flash returning")

   -- Sizing is a convenience and must never speak. v1.12.0 renamed the blink's
   -- function to CO.sdk_ask_page (below, in the same do block); the check for
   -- it living here would just duplicate that one under the old name.

   -- v1.10.3 MULTI-MONITOR. Trident only ever reports the PRIMARY monitor
   -- (ScreenProbe sitting, 2026-07-30), so each page tags its report " off"
   -- when its own window centre is outside the primary, and Lua discards the
   -- numbers on that flag. Three files again, and the same drift risk: a page
   -- that stops sending the suffix, or Lua that stops parsing it, silently
   -- brings back the overflowing-laptop-panel defect with no offline symptom.
   CHECK(page:find('" off"', 1, true) ~= nil,
         "the measuring page can tag its report off-primary")
   CHECK(dlg:find('" off"', 1, true) ~= nil,
         "the setup dialog can tag its report off-primary")
   CHECK(page:find("window.screenLeft", 1, true) ~= nil and
         dlg:find("window.screenLeft", 1, true) ~= nil,
         "both pages read their own position -- the one thing Trident is honest about")
   -- v1.12.0 renamed the persisted flag to `everoff` (sticky -- unlike the
   -- old per-run offprimary, it never clears). A plain find("offprimary")
   -- would stay green even with the write AND the back-compat read both
   -- deleted, because the doc comment alone contains the word. Pin the CODE:
   -- the write site (which reads store.everoff) and the back-compat read of
   -- the old key (t.offprimary) -- neither substring appears in any comment.
   CHECK(lua:find("store.everoff", 1, true) ~= nil,
         "the store persists the sticky off-primary flag under its own key")
   CHECK(lua:find("t.offprimary", 1, true) ~= nil,
         "a pre-v1.12.0 file's offprimary key still seeds the flag on read")
   do
      local w, h, off = CO.parse_screen_field("1920x1032 off")
      CHECK(w == 1920 and off == true, "Lua parses the suffix the pages send")
   end

   -- v1.12.0: the layout follows the window. None of these can be rendered
   -- offline -- the gate never resizes anything -- so they are read instead.
   -- Restoring the `1` would quietly return the dialog to a layout that sits
   -- 1:1 in the corner of any window bigger than the design size, which is
   -- precisely the state Tim photographed on 2026-07-31.
   --
   -- Pin 1 used to match one exact spelling of the cap, `Math.min(1, w/...,
   -- h/...)`. That let `Math.min(w/DESIGN_W, h/DESIGN_H, 1)` -- same cap, args
   -- reordered -- slip past every assertion here AND the whole sweep, since
   -- every gate check is a floor and this pin was the task's real red/green
   -- pair. So instead of matching a spelling, this pulls out the whole
   -- argument list of the `z = Math.min(...)` line and asserts it carries no
   -- bare numeric constant at all: none of `w`, `h`, `DESIGN_W`, `DESIGN_H`
   -- contains a digit, so any digit anywhere in that list can only be a
   -- smuggled-back cap, in either position.
   local zargs = dlg:match("var%s+z%s*=%s*Math%.min%(([^%)]*)%)")
   CHECK(zargs ~= nil, "found the fitToWindow zoom line")
   CHECK(zargs == nil or zargs:find("%d") == nil,
         "the zoom argument list carries no bare numeric constant")
   CHECK(dlg:find("function watchWindowSize%s*%(") ~= nil,
         "the window-size watcher exists")
   CHECK(dlg:find("setInterval%(watchWindowSize") ~= nil,
         "and something actually runs it -- a watcher nobody polls is a no-op")

   -- v1.12.0: the size the operator left the window at travels the same way
   -- the screen measurement does -- a named hidden field, written by the page,
   -- read by Lua after the dialog closes. Same drift risk as Screen: rename it
   -- in one file and every machine silently stops remembering, with nothing to
   -- see offline.
   CHECK(dlg:find('id="WinSize" name="WinSize"', 1, true) ~= nil,
         "the setup dialog declares the WinSize field")

   -- A bare `window.outerWidth` substring pin was tried here first and does
   -- NOT do the job: that exact string already lives in reportScreen()'s
   -- off-primary check (window.screenLeft + (window.outerWidth || 0) / 2), so
   -- it was true before reportWinSize() existed and proves nothing about it --
   -- the same class of hollow pin Task 1 hit twice (a rename that slipped past
   -- a substring match, a reordered argument list that slipped past a spelling
   -- match). Pin the reporter itself instead, anchored the way
   -- watchWindowSize() is pinned just above: this fails if reportWinSize is
   -- renamed or deleted.
   CHECK(dlg:find("function reportWinSize%s*%(") ~= nil,
         "the WinSize reporter exists")

   -- And a reporter nobody calls is exactly as useless as the watcher-nobody-
   -- polls case pinned just above -- so pin both call sites too. The
   -- declaration line reads "function reportWinSize() {", with no semicolon
   -- after the parens, so counting the call syntax "reportWinSize();"
   -- (semicolon included) lands on the two call sites alone -- watchWindowSize()'s
   -- guarded path and the injection poll after reportScreen() -- and skips the
   -- declaration on its own. Deleting either call site drops this count from
   -- 2 to 1.
   local _, winsize_calls = dlg:gsub("reportWinSize%(%);", "")
   CHECK(winsize_calls == 2,
         "reportWinSize(); is called exactly twice -- watchWindowSize() and the injection poll")

   -- v1.12.0 defect fix (live, 2026-07-31). Trident freezes
   -- window.outerWidth/outerHeight at the size the window was CREATED at, so
   -- reading them here is what made "drag it to the size you want" work in one
   -- direction only. What the reporter reads is the whole defect, and nothing
   -- offline can see it -- headless Chrome updates outerWidth quite happily --
   -- so it is pinned in the source instead.
   --
   -- Pinned against the FUNCTION BODY, not the file: `window.outerWidth` also
   -- lives in reportScreen()'s off-primary check a few lines above, so a
   -- whole-file absence pin would be red the day it was written (the same
   -- hollow-pin trap noted just above). reportWinSize's body runs from its
   -- opening brace to the first "}" at the start of a line -- every brace
   -- inside it is indented -- so the match cannot overshoot into fitToWindow.
   local rw = dlg:match("function reportWinSize%(%)%s*{(.-)\n}")
   CHECK(rw ~= nil, "found reportWinSize's body")
   CHECK(rw ~= nil and rw:find("outer") == nil,
         "reportWinSize reads no outer size -- Trident's is frozen at creation")
   CHECK(rw ~= nil and rw:find("document.body.clientWidth", 1, true) ~= nil,
         "reportWinSize reads the client box, the only size here that tracks a drag")
   -- And it must send BOTH boxes: the load-time one is what lets Lua work out
   -- this machine's frame. Lose it and Lua falls back to treating the client
   -- box as an outer size, which shrinks the window by its own frame each run.
   CHECK(rw ~= nil and rw:find('+ "|" + loadW', 1, true) ~= nil,
         "reportWinSize sends the load-time box behind the current one, after a bar")

   CHECK(lua:find('GetTextField%("WinSize"%)') ~= nil,
         "Lua reads the remembered window size by that name")
   local _, win_adds = lua:gsub('AddTextField%("WinSize"', "")
   CHECK(win_adds == 1,
         "AddTextField(\"WinSize\" appears exactly once -- only the setup dialog " ..
         "has a size worth remembering")
   -- The blink is the ONLY thing left that runs before the dialog, and it must
   -- stay as silent as everything else on this path.
   -- Anchored on the exact parameter list, not just the name -- a bare name
   -- match here would also match a renamed "sdk_ask_pageZ(gadget_dir)", since
   -- Lua patterns have no word-boundary of their own (the fifth prefix-match
   -- pin found on this branch).
   local abody = lua:match("function CO%.sdk_ask_page%(gadget_dir%).-\nend\n")
   CHECK(abody ~= nil, "sdk_ask_page exists")
   CHECK(abody == nil or (abody:find("show_message", 1, true) == nil and
                          abody:find("DisplayMessageBox", 1, true) == nil),
         "the blink never speaks")

   -- Task 6 code review: every function above has its own unit tests, but
   -- nothing had proved main() actually WIRES them together -- the suite
   -- stayed green through all three of the mutations below, because
   -- everything else with logic in it is pure and separately tested. main()
   -- itself was the one thing nothing here pinned.
   --
   -- main() is the LAST thing this file defines and nothing follows its
   -- closing "end" (checked with tail -30 against the real file), so its body
   -- is "from the definition to end of file" -- a "\nend\n" match, like
   -- qbody/abody above, would stop at the first bare "end" line inside one of
   -- main()'s own if-blocks, long before the real one.
   local mstart = lua:find("function main(script_path)", 1, true)
   CHECK(mstart ~= nil, "found main()")
   local mbody = mstart ~= nil and lua:sub(mstart) or ""

   -- Mutation: CO.window_size(rem,...) -> CO.dialog_size(screen_w, screen_h)
   -- silently no-ops the entire feature -- the window goes back to guessing
   -- a size from the screen alone, never reading or writing a remembered one.
   CHECK(mbody:find("CO%.window_size%(") ~= nil,
         "main sizes the dialog through CO.window_size, not the old CO.dialog_size call")
   -- Mutation: delete CO.remember_screen(dlg, win_w, win_h) -- nothing is ever
   -- remembered again, on either the OK or the Cancel path. The two arguments
   -- are pinned with it: the page reports only its own client box, so without
   -- the size main ASKED for there is no frame to add back, and remember_screen
   -- stores nothing at all.
   CHECK(mbody:find("CO%.remember_screen%(dlg, win_w, win_h%)") ~= nil,
         "main remembers the dialog's report, and hands over the size it asked for")
   -- Mutation: elseif store.everoff -> elseif true -- the blink fires on
   -- every run of every machine, breaking "single-monitor machines pay
   -- nothing" (v1.10.5's principle, carried into this design).
   CHECK(mbody:find("elseif store%.everoff then") ~= nil,
         "the blink is gated on the sticky flag -- widen this and every machine pays for it")

   -- Task 7 code review. The three pins above prove main WIRES the new sizing;
   -- none of them proves it stopped CALLING the old one. The deletion contract
   -- in test_dialog_size.lua asserts each of these five FIELDS is nil, which is
   -- a different question: a half-applied revert that reintroduces a bare
   -- CO.sdk_query_monitors() call here WITHOUT its definition leaves the field
   -- nil, this whole suite green, and an "attempt to call a nil value" waiting
   -- for the next run in Aspire. Removing those calls is the entire point of
   -- v1.12.0 -- they cost up to six seconds a run -- so the call sites are
   -- pinned as well as the definitions.
   --
   -- Bare names, not "CO."-qualified: the file aliases CO to EdgeBreaker, so a
   -- returning call could be spelled either way and the bare name catches both.
   -- These are plain (non-pattern) finds, so they are PREFIX matches --
   -- "screen_for_run" would also match "screen_for_run_v2". For an ABSENCE pin
   -- that is the safe direction: it can fail on MORE spellings, never fewer,
   -- and every extra spelling it catches is still the deleted thing coming
   -- back. None of the five appears anywhere in EdgeBreaker.lua today, comments
   -- included, so there is nothing to trip on by accident.
   --
   -- These cannot go vacuously true on an empty mbody the way a `body == nil
   -- or ...` pin can: CHECK(mstart ~= nil) and the three presence pins above
   -- all fail first if the extraction ever stops matching.
   for _, gone in ipairs({ "PS_MONITORS", "parse_monitor_output",
                           "should_ask_windows", "screen_for_run",
                           "sdk_query_monitors" }) do
      CHECK(mbody:find(gone, 1, true) == nil,
            "main never mentions " .. gone ..
            " -- the ask-Windows apparatus is deleted, not merely undefined")
   end
end

-- v1.11.0 sharp corners: the Inside code and flag encodings are pinned against
-- an ASPIRE-AUTHORED fixture (saved from the Profile form at the Task 1
-- sitting, 2026-07-31), not inferred. MV_CODES had 1 = inside inferred-only
-- until this. The fixture is committed at
-- tests/fixtures/mv-inside-sharp.ToolpathTemplate; the SKIP branch below is
-- defensive only, in case the fixture file ever goes missing.
do
   local sharpFxFile = io.open("tests/fixtures/mv-inside-sharp.ToolpathTemplate", "rb")
   if sharpFxFile == nil then
      print("SKIP: mv-inside-sharp fixture missing (test_release.lua sharp pins)")
   else
      sharpFxFile:close()
      local sharpFx = slurp("tests/fixtures/mv-inside-sharp.ToolpathTemplate")
      CHECK(CO.read_machine_vectors(sharpFx) == "inside",
            "fixture pins the Inside code (MV_CODES inference confirmed by Aspire bytes)")
      CHECK(sharpFx:byte(CO.find_sharpen_offset(sharpFx)) == 1,
            "fixture pins the sharpen flag byte = 1")
      do
         local off = CO.find_allowance_offset(sharpFx)
         CHECK(type(off) == "number", "fixture's allowance is findable under the F\\0 rule")
         -- The 2026-07-31 sitting found Aspire LOCKS the allowance field while
         -- sharpening is on and stores 0 regardless -- an allowance can never
         -- ride along with sharp corners, so R1 deleted the allowance patch;
         -- compensation moves to where the offset vectors are drawn (R2).
         CHECK(sharpFx:sub(off, off + 7) == CO.encode_double(0),
               "fixture's allowance is 0: Aspire discards allowance under sharpening")
      end
      -- What we patch is what Aspire saves: the patched shipped template reads the
      -- same MV name as the fixture.
      CHECK(CO.read_machine_vectors(CO.patch_template_sharp(shippedT, "inside"))
            == CO.read_machine_vectors(sharpFx),
            "the patcher writes the code Aspire itself stores for Inside")
   end
end

-- The outward mirror (2026-08-03). Sharp corners now run on Outside as well as
-- Inside, and the two sides write OPPOSITE Machine Vectors codes -- so a
-- patcher that got the outward one wrong would machine the wrong side of every
-- vector in the job, silently. Both codes are therefore fixture-pinned against
-- Aspire's own bytes rather than one pinned and the other inferred:
-- mv-outside.ToolpathTemplate is an Aspire save with Machine Vectors = Outside.
-- Same SKIP-if-missing shape as the Inside block above, and defensive for the
-- same reason.
do
   local outFxFile = io.open("tests/fixtures/mv-outside.ToolpathTemplate", "rb")
   if outFxFile == nil then
      print("SKIP: mv-outside fixture missing (test_release.lua outward sharp pin)")
   else
      outFxFile:close()
      local outFx = slurp("tests/fixtures/mv-outside.ToolpathTemplate")
      CHECK(CO.read_machine_vectors(outFx) == "outside",
            "fixture pins the Outside code")
      local patchedOut = CO.patch_template_sharp(shippedT, "outside")
      CHECK(patchedOut ~= nil and CO.read_machine_vectors(patchedOut)
            == CO.read_machine_vectors(outFx),
            "the patcher writes the code Aspire itself stores for Outside")
      -- The outward branch must still turn sharpening ON. Aiming the cut at the
      -- other side of the line while forgetting the flag would cut a correct
      -- outside chamfer with rounded corners -- the exact defect this feature
      -- exists to remove, and it would look like nothing happened.
      CHECK(patchedOut ~= nil
            and patchedOut:byte(CO.find_sharpen_offset(patchedOut)) == 1,
            "and still sets the sharpen flag on the outward side")
      -- An unrecognised side REFUSES rather than defaulting (spec 4a.3): a
      -- silent fallback here picks a side of the line for the operator.
      local bad, badwhy = CO.patch_template_sharp(shippedT, "auto")
      CHECK(bad == nil and type(badwhy) == "string",
            "and a side it does not recognise refuses instead of guessing one")
   end
end

-- v1.11.0: the dialog's greying is UX -- these calls are what actually decide.
-- If any disappears, a ticked box either sharpens a selection Aspire will cut
-- the wrong way round, or silently does not sharpen one it would have cut right,
-- and nothing offline but this would notice.
--
-- Retargeted 2026-08-03 (Auto sharp corners, spec section 5a). The side left
-- sharp_applies, so the gate is now TWO calls and both have to be here.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   -- Scoped to main()'s BODY, not the whole file: CO.sharp_nesting_ok and
   -- CO.sharp_nesting_note are DEFINED earlier in the same file, so a whole-file
   -- search for either name matches the definition and passes whether or not
   -- main() ever calls it. That is a pin that cannot fail, which is worse than
   -- no pin. main() runs from its definition to end of file (same extraction the
   -- absence pins below use).
   local mstart = src:find("function main(script_path)", 1, true)
   CHECK(mstart ~= nil, "found main() for the sharp gate pins")
   local mbody = mstart ~= nil and src:sub(mstart) or ""
   CHECK(mbody:find("local sharp_ok = CO%.sharp_applies%(sharp, s%.d, r%.d_max%)") ~= nil,
         "main() asks the box-and-depth gate first")
   CHECK(mbody:find("CO%.sharp_nesting_ok%(dirs, depths%)") ~= nil,
         "and then asks whether our directions match what Aspire's nesting will do")
   CHECK(mbody:find("local depths = CO%.nesting_depths%(loops%)") ~= nil,
         "main() measures nesting depth from the same loops it classified")
   -- Asking for sharp corners and not getting them must never be silent. TWO
   -- pins, because they can fail apart: main() can still COMPUTE the sentence
   -- while nothing carries it into the report, and a mutation check proved
   -- exactly that -- deleting the append below left the call above untouched and
   -- the suite green.
   CHECK(mbody:find("CO%.sharp_nesting_note%(sharp_why%)") ~= nil,
         "main() builds the refusal sentence from the gate's reason")
   CHECK(mbody:find('sel_notes = sel_notes %.%. "\\n\\n" %.% sharp_refused') ~= nil
         or mbody:find("sharp_refused then sel_notes = sel_notes", 1, true) ~= nil,
         "and appends it to sel_notes, which is what raises the report")
   CHECK(src:find('AddTextField%("Sharp"') ~= nil,
         "main() seeds the dialog's Sharp field")
end

-- R2: sdk_offset_loop and main() are SDK-touching and cannot run offline, so
-- the sharp distance shift and the sharp_run local (computed once, reused at
-- both the offset site and the template-patch call) are pinned by source
-- rather than executed.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find("local sharp_run = sharp_ok and sharp_dir ~= nil") ~= nil,
         "main() computes sharp_run once, from both gates")
   -- Multi-pass: the shift is per BAND, not per chamfer. Aspire computes its own
   -- displacement from THAT pass's cut depth, so the compensation has to
   -- come from the same number -- pg.depth, not the whole chamfer's s.d. At
   -- n == 1 pass_geometry returns (W + G) / tan a, which IS s.d, so a one-pass
   -- sharp run still shifts by exactly what v1.12.0 shifted by.
   --
   -- Retargeted 2026-08-03 (outward sharp corners, spec section 8). This used to
   -- pin the literal `dist_n + CO.sharp_offset_shift(...)`, and that bare `+`
   -- WAS the inside-only rule -- applied outward it draws the loop at 2G + W on
   -- the finishing band and at zero on a relief band, i.e. straight back onto
   -- the original vector. The sign now lives in one place,
   -- CO.sharp_offset_distance, which signs BOTH terms through
   -- band_offset_distance; these pins say both call sites go through it. The
   -- number it returns is pinned in tests/test_geometry.lua; what is pinned
   -- here is that main() asks it rather than doing the arithmetic itself.
   CHECK(src:find("CO%.sharp_offset_distance%(dirs%[i%], pg_n%.offset, pg_n%.depth, angle%)") ~= nil,
         "the finishing band's sharp loop comes from CO.sharp_offset_distance, per band")
   -- The second site, inside the `if sharp_run` carve-out: every relief band of
   -- a sharp run is drawn the same way, from its OWN band's offset and depth.
   -- Two sites doing the sign by hand is two chances to disagree, which is the
   -- whole reason the function exists.
   CHECK(src:find("CO%.sharp_offset_distance%(dirs%[i%], pg%.offset, pg%.depth, angle%)") ~= nil,
         "and so does every relief band's, inside the sharp carve-out")
   -- The negative half, and the one that actually guards the bug: the sign rule
   -- must NOT be re-inlined. main() has no business naming sharp_offset_shift at
   -- all any more -- a bare `dist + shift` anywhere in it is the inside-only
   -- formula coming back, and it would pass both pins above if it were added
   -- alongside them. main() runs from its definition to end of file (same
   -- extraction as the ask-Windows deletion pins earlier in this file).
   do
      local mstart = src:find("function main(script_path)", 1, true)
      CHECK(mstart ~= nil, "found main() for the sharp-shift absence pin")
      local mbody = mstart ~= nil and src:sub(mstart) or ""
      CHECK(mbody:find("sharp_offset_shift", 1, true) == nil,
            "and main() never names sharp_offset_shift itself -- the sign rule lives in one function")
   end
   CHECK(src:find("CO%.sdk_offset_loop%(job, loop%.obj, dist_n, sharp_dist%)") ~= nil,
         "main() passes both the normal dist and sharp_dist into sdk_offset_loop")
   -- Retargeted twice. 2026-08-03 (outward): the template-patch call needs WHICH
   -- side, not merely whether. 2026-08-03 (Auto): that side comes from the
   -- NESTING GATE's answer, mapped into Aspire's words -- never from the dialog's
   -- `side` field. Deriving it from `side` is the defect this whole change
   -- closes, and it is the derivation that reads most naturally: on a nested
   -- selection the forced side is precisely the direction Aspire will not use.
   CHECK(src:find('local sharp_side = sharp_run and %(%(sharp_dir == "outward"%) and "outside" or "inside"%) or nil') ~= nil,
         "main() maps the gate's direction to the patch side")
   CHECK(src:find("tool, sharp_side%)") ~= nil,
         "and reuses that one answer at the template-patch call")
   -- The negative half. `sharp_run and side` is the old line, and it would pass
   -- every positive pin above if somebody put it back alongside them.
   do
      local mstart = src:find("function main(script_path)", 1, true)
      CHECK(mstart ~= nil, "found main() for the sharp_side derivation pin")
      local mbody = mstart ~= nil and src:sub(mstart) or ""
      CHECK(mbody:find("sharp_run and side", 1, true) == nil,
            "and main() never derives the patch side from the dialog's side field")
   end
   CHECK(src:find("function CO%.sdk_offset_loop%(job, obj, dist, sharp_dist%)") ~= nil,
         "sdk_offset_loop takes the normal dist and the sharp_dist flag/shift separately")
   CHECK(src:find("sg:MakeOffsetsSquare%(math%.abs%(sharp_dist%), sharp_dist > 0,") ~= nil,
         -- No longer inferred: OffsetSquareProbe (2026-07-31) read the real
         -- signature off luabind's overload error --
         --    bool MakeOffsetsSquare(ContourGroup*, double, bool, double)
         -- -- and measured both flag values on the same rectangle.
         --
         -- The middle argument is the OFFSET'S DIRECTION, not a squaring
         -- switch: true = offset outward, false = offset inward, and a wrong
         -- answer squares nothing while still returning true. It must therefore
         -- be DERIVED from sharp_dist, never a literal -- a hardcoded `true`
         -- was right only for as long as every run was an inside one, and it
         -- shipped rounded corners on every outside run of v1.13.0.
         -- Measured by SquareProbe 2026-08-03.
         --
         -- The first argument stays the MAGNITUDE; signing it was tried live
         -- the same night and changed nothing.
         "sdk_offset_loop squares with the magnitude and the offset's own direction")
end

-- Multi-pass: main()'s run block is the largest edit in the feature and NOTHING
-- offline can execute it, so its three load-bearing decisions are pinned by
-- source the same way the sharp shift above is. Each one is a silent, dangerous
-- regression if it is ever undone by a later edit:
--   * collapse the two phases back into one and a shape that dies on an upper
--     band gets a chamfer on part of its face and nothing on the rest;
--   * drop the teardown and a part-built chamfer sits in the Toolpaths panel
--     looking finished while it cuts a partial face;
--   * revert to one name for every band and each pass overwrites the last one's
--     marker, so a rebuild can no longer find the whole set.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find("local viable = {}") ~= nil,
         "main() computes every band before drawing any of them (two phases)")
   CHECK(src:find("CO%.sdk_delete_marked_toolpaths,%s*slot,%s*false") ~= nil,
         "main() tears the whole set down when a pass fails part way")
   CHECK(src:find("CO%.toolpath_name%(size, unit%.suffix, slot, k, n_passes%)") ~= nil,
         "main() names each band's toolpath with its own pass number")
   -- The per-pass warnings are kept in TWO accumulators because they have
   -- opposite lifetimes, and merging them back into one is a silent, reachable
   -- self-contradiction: a pass that was renamed but not retooled carries the
   -- marker, so the teardown sweep deletes it -- and a single accumulator would
   -- then print "The passes that had already been built were removed" directly
   -- above "change the tool on it in the Toolpaths panel before cutting".
   -- Only the TAG warnings describe something the sweep cannot see.
   CHECK(src:find('local retool_warnings, tag_warnings = "", ""') ~= nil,
         "main() keeps the retool and tag warnings apart, by lifetime")
   CHECK(src:find("%.%. retool_warnings %.%. tag_warnings") ~= nil,
         "a run that built every pass reports both kinds of warning")
   CHECK(src:find('The offset vectors were still drawn%."%s*%.%. tag_warnings') ~= nil,
         "a torn-down run reports ONLY the passes the sweep could not see")
end

-- Multi-pass: the DIALOG carries a second copy of this arithmetic, written in
-- JavaScript, and the two copies cannot see each other. Everything below is
-- about that gap -- the page telling the operator one thing while the run does
-- another -- and nothing else offline compares them.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local page = f:read("*a"); f:close()

   -- Captured and compared as a NUMBER, never as spelling. string.format("%g",
   -- 1e-9) gives "1e-09" in this Lua while the page says "1e-9" -- one value,
   -- two spellings -- and a literal match would also fail the day somebody
   -- writes 1.0e-9 or 0.000000001. The value is what has to agree.
   local function page_var(name)
      local v = page:match("var " .. name .. " = ([^;]+);")
      return v and tonumber(v) or nil
   end

   -- A page ceiling BELOW the Lua's refuses a cut the gadget would happily
   -- make, and names a bigger bit for it. Above, the dialog draws a pass count
   -- and lets OK through on a chamfer the run then refuses.
   CHECK(page_var("MAX_PASSES") == CO.MAX_PASSES,
         "the page's MAX_PASSES matches CO.MAX_PASSES")
   -- This tolerance decides whether a band that EXACTLY fills the flute fits.
   -- Disagree and the page says n+1 passes where the run cuts n: the note, the
   -- seam count and the ghosted passes then all describe a different cut from
   -- the one OK is about to make.
   CHECK(page_var("FIT_EPS") == CO.FIT_EPS,
         "the page's fit tolerance matches CO.FIT_EPS")
   -- Both have to stay derivations. Arithmetic inlined at the call sites is how
   -- the two copies drift apart without either one looking wrong on its own.
   CHECK(page:find("function passCount", 1, true) ~= nil,
         "the page derives its own pass count")
   CHECK(page:find("function solveBand", 1, true) ~= nil, "and its own band solver")
   -- ONE-SIDED, and the label says so rather than claiming more than it tests.
   -- 0.75 appears in the page's own comments, so "the page never writes 0.75"
   -- is not a check that can be made here at all. What is checked: the fraction
   -- is still computed from the two margins, so a change to TIP_MARGIN or
   -- SHOULDER_MARGIN cannot leave the too-big message quoting a maximum the
   -- gadget will not actually cut.
   CHECK(page:find("SHOULDER_MARGIN - TIP_MARGIN", 1, true) ~= nil,
         "the page derives the capacity fraction from the two margins")
end

-- The invariant the in-place template patch rests on: a banded layer name is
-- exactly as long as the restriction the shipped template was authored with,
-- so the patch rewrites bytes without moving a record. Aspire accepts no other
-- kind of edit -- if this ever fails, the feature needs an Aspire-authored
-- template per pass (the plan's contingency), not a cleverer patcher.
CHECK(#CO.offset_layer_name(99, CO.MAX_PASSES) == #CO.TEMPLATE_LAYER,
      "the banded layer name is exactly as long as the template's restriction")
CHECK(#CO.TEMPLATE_LAYER == 23, "and that length is 23 characters")

-- Corner nesting (v1.13.1). main() is SDK-touching and cannot run offline, so
-- that the relief bands are cut from the FINISHING group -- and not from the
-- original vector, which is the v1.13.0 defect -- is pinned by source. This is
-- the ONLY offline evidence that the product nests; the corner gate proves the
-- arithmetic is nestable and only the sitting proves Aspire nests.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find("CO%.sdk_offset_group%(groups%[n_passes%], delta%)") ~= nil,
         "phase 1 offsets each relief band from the FINISHING band's group")
   CHECK(src:find("local delta = CO%.relief_offset_distance%(k, n_passes, r%.W, s%.g, r%.a, dirs%[i%]%)") ~= nil,
         "and by the difference between the two band distances")
   -- ANCHORED, not merely present. Every other pin in this block is an
   -- independent substring search, so swapping the two arms of `if sharp_run`
   -- -- normal runs on the old path, sharp runs nesting -- leaves every string
   -- textually intact and the whole suite green (proved 2026-08-03). These two
   -- say WHICH ARM each path is on. %s+ so reformatting the file cannot break
   -- them.
   CHECK(src:find("else%s+local delta = CO%.relief_offset_distance") ~= nil,
         "and the nesting is on the ELSE arm -- the path a NON-sharp run takes")
   CHECK(src:find("if sharp_run then%s+local pg = CO%.pass_geometry") ~= nil,
         "while the sharp arm is the one that re-derives the band itself")
   CHECK(src:find("function CO%.sdk_offset_group%(g, dist%)") ~= nil,
         "the group-offset helper exists")
   -- The negative pin: the old spelling, which offset every band from the
   -- original vector on EVERY run, must be gone. Without this the two pins
   -- above could pass alongside leftover as-built code on another path. This
   -- does not rule out the sharp carve-out's own use of the original vector
   -- (spelled dk/pg.depth, not dist/pg.depth) -- that path is covered by the
   -- "if sharp_run then" and "section 7e" pins below, not by this one.
   CHECK(src:find("CO%.sdk_offset_loop%(job, loop%.obj, dist, sharp_dist%)") == nil,
         "the nesting path no longer offsets a band from the original vector by its own full distance")
   -- ... except on a sharp run, where every band is drawn at exactly W from the
   -- wall on the material side (pinned numerically in tests/test_geometry.lua),
   -- so the nested relief offset is identically zero and nesting would produce
   -- the same loop. The carve-out re-derives that loop from the source object
   -- instead of offsetting by zero and squaring the result again. Pinned so it
   -- cannot be deleted by accident, and so the file keeps saying why.
   --
   -- Side-INDEPENDENT, and this is the bit that had to be reread when sharp
   -- corners went outward (2026-08-03 spec section 3d). The old wording here
   -- said "+W", which is the inward half only; CO.sharp_offset_distance signs
   -- both terms, so an inward run lands at +W and an outward one at -W and
   -- every band of EITHER coincides. The relief offset is zero on both sides,
   -- so the carve-out below is still correct and section 7e is not reopened --
   -- which is why these pins are retargeted wording and not deleted checks.
   CHECK(src:find("if sharp_run then") ~= nil,
         "the sharp carve-out is still there")
   CHECK(src:find("identically ZERO") ~= nil,
         "and the file says why -- the nested offset on a sharp run is zero")
   CHECK(src:find("section 7e") ~= nil,
         "and still names where Aspire's half of it gets settled")
   -- The relief loop stops ONE SHORT of the finishing band, which is what makes
   -- the one-pass path untouched: at n_passes == 1 the body never runs at all.
   -- Running it to n_passes would offset the finishing band by zero and hand
   -- phase 2 a duplicate on EVERY run, one pass included -- and that mutation
   -- passes the whole suite without this line (proved 2026-08-03).
   CHECK(src:find("for k = 1, n_passes %- 1 do") ~= nil,
         "the relief loop stops one short of the finishing band, so n=1 never enters it")
   -- The finishing band is still the one cut from the document object, and it
   -- is still the one that carries the sharp path.
   CHECK(src:find("CO%.sdk_offset_loop%(job, loop%.obj, dist_n, sharp_dist%)") ~= nil,
         "the finishing band is still offset from the original vector")
end

-- The page's greying rule is a SECOND copy of CO.sharp_applies and always was.
-- That was tolerable while greying was a convenience; it is not now that it
-- also moves the cut position and decides whether Aspire will accept the run.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local page = f:read("*a"); f:close()
   CHECK(page:find("sharpMaxPercent", 1, true) ~= nil,
         "the page works out the highest cut position that still sharpens")
   -- Both remedies, because both are real: a smaller chamfer or a bigger bit.
   -- The README says both too, and a caption naming only one of them reads as a
   -- different rule from the one the README states.
   CHECK(page:find("needs a smaller chamfer, or a bigger bit", 1, true) ~= nil,
         "and says so when no position will do, naming both ways out")
   -- 2026-08-03 (Auto): the SIDE caption is GONE, both spellings of it. The side
   -- no longer gates the box at all -- Auto is the only side that can sharpen a
   -- letter set -- so a caption saying otherwise would tell the operator the
   -- thing in front of them does not work, on the very run it works best for.
   -- The depth caption is now the only one, which is why the markup default is
   -- pinned to it: SharpCap is written by applySharpState on every redraw, but
   -- the markup is what the first paint shows.
   CHECK(page:find("needs Side: Inside or Outside", 1, true) == nil,
         "the side caption is gone from the page, in the markup and at run time")
   CHECK(page:find('id="SharpCap">needs a smaller chamfer, or a bigger bit</span>', 1, true) ~= nil,
         "and the markup default is the depth caption, the only one left")
   -- The checkbox's own label followed the caption. "Sharp inside corners" over
   -- a working Outside run is worse than no label at all. Pinned with its input
   -- and its closing tag, because the same two words also appear in the "How it
   -- decides" panel and in the drop note, and a bare search would find those and
   -- never look at the control itself.
   CHECK(page:find('<input type="checkbox" id="SharpBox"> Sharp corners</label>', 1, true) ~= nil,
         "and the checkbox is labelled for both sides, not just Inside")
   -- 2026-08-03 (Auto): sharpSideOk is DELETED, along with all three of its call
   -- sites. It existed to hold ONE copy of the side test for the greying, the
   -- cut-position drop and the note that explains the drop. There is no side
   -- test left to hold: a surviving copy would grey a box that now works, and it
   -- would grey it on Auto, which is the side this release exists for.
   -- Matched with the open paren, so it catches the definition AND every call
   -- while still letting a comment name the thing it is explaining the absence
   -- of. A bare name search cannot tell those apart.
   CHECK(page:find("sharpSideOk(", 1, true) == nil,
         "the page has no sharpSideOk left - the side no longer gates the box")
   -- The absence half, unchanged in purpose: if an inline side test comes back,
   -- one of those three sites has been re-narrowed behind the deletion's back.
   CHECK(page:find('el("Side").value === "inside"', 1, true) == nil,
         "and no site re-tests the side inline")
   CHECK(page:find('el("Side").value === "outside"', 1, true) == nil,
         "not for Outside either")
end

-- CO.sharp_max_percent and the page's sharpMaxPercent are two copies of the
-- SAME rule, and the checks above only pin the identifier and one caption --
-- neither notices a page copy that flips <= to <, reorders PRESETS, or drops
-- the g_lo clamp. The formula is pure arithmetic (no DOM), so unlike the rest
-- of this file it can be run for REAL rather than merely read: pull the page's
-- own safeBand/sharpMaxPercent/PRESETS source verbatim (%b{} takes the whole
-- balanced function body, nested object literal and all) and hand it to a bare
-- `node` process, then compare its answers to CO.sharp_max_percent's for the
-- exact same inputs. Same reasoning as the PRESETS-array pin above: compare
-- what the two sides COMPUTE, never what they are spelled.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local page = f:read("*a"); f:close()
   local margins  = page:match("var SHOULDER_MARGIN[^\n]*\n")
   local safeband = page:match("function safeBand%(dia, W, a%)%s*%b{}")
   local sharpmax = page:match("function sharpMaxPercent%(dia, W, b, a%)%s*%b{}")
   CHECK(margins ~= nil, "the page still declares TIP_MARGIN/SHOULDER_MARGIN/PRESETS together")
   CHECK(safeband ~= nil, "the page still defines safeBand the expected way")
   CHECK(sharpmax ~= nil, "the page still defines sharpMaxPercent the expected way")

   if margins and safeband and sharpmax then
      -- One full-range fit, one past-the-ceiling refusal, one narrow
      -- multi-pass window (only 0% fits), one non-90 bit -- chosen to match
      -- the CO.sharp_max_percent block earlier in tests/test_settings.lua, so
      -- a mismatch here points straight at those known-good numbers.
      local a90 = CO.half_angle(90)
      local a60 = CO.half_angle(60)
      -- Case 5 is a BOUNDARY vector, not just another interior point: dia and
      -- W are chosen so g_lo lands on `room` bit-for-bit exactly (verified by
      -- Lua equality before this file was written, not asserted on faith),
      -- and b is small enough that g_hi > g_lo -- a real, non-inverted band --
      -- so preset 0 is the ONLY one that satisfies the rule. Every interior
      -- vector above is silent to a `<=`-to-`<` flip on the loop guard or a
      -- `>`-to-`>=` flip on the g_lo clamp, because both sides of an interior
      -- inequality already agree on which way it goes; only a vector sitting
      -- ON the line forces the operator itself to be the thing that decides
      -- the answer. (Mutation-tested 2026-08-03: flipping either operator in
      -- the page's copy turns this case's 0 into nil, and nothing else here
      -- would have caught it.)
      local dia5, r5 = 0.017, 0.0085
      local W5 = r5 - CO.TIP_MARGIN * r5   -- rounds so that (r5 - W5) == TIP_MARGIN*r5 exactly
      local cases = {
         { 0.25, 0.05,  0.05,                   a90 },
         { 0.25, 0.115, 0.0575,                 a90 },
         { 0.25, 0.10,  CO.band_width(0.10, 2), a90 },
         { 0.50, 0.03,  0.03,                   a60 },
         { dia5, W5,    0.001,                  a90 },
      }
      local js = margins .. "\n" .. safeband .. "\n" .. sharpmax .. "\n" .. "var cases = [\n"
      for _, c in ipairs(cases) do
         js = js .. string.format("[%.17g,%.17g,%.17g,%.17g],\n", c[1], c[2], c[3], c[4])
      end
      js = js .. "];\nconsole.log(cases.map(function(c){" ..
                 "var v=sharpMaxPercent(c[0],c[1],c[2],c[3]);return v===null?'nil':v;" ..
                 "}).join(' '));\n"

      local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
      local jspath = tmp .. "\\edgebreaker_sharp_check.js"
      local jf = io.open(jspath, "w")
      local out = nil
      if jf then
         jf:write(js); jf:close()
         local p = io.popen('node "' .. jspath .. '" 2>&1')
         out = p and p:read("*a") or nil
         if p then p:close() end
         os.remove(jspath)
      end

      -- node missing/broken is reported, not silently skipped: a drift-detector
      -- that goes quiet when its own tool is absent is worse than no detector.
      CHECK(out ~= nil, "node could run the page's own sharpMaxPercent for real")
      if out then
         local tokens = {}
         for tok in out:gmatch("%S+") do tokens[#tokens + 1] = tok end
         for i, c in ipairs(cases) do
            local expected = CO.sharp_max_percent(c[1], c[2], c[3], c[4])
            local got = tokens[i]
            local matches = (expected == nil) and (got == "nil") or (tonumber(got) == expected)
            CHECK(matches, "the page's sharpMaxPercent agrees with CO.sharp_max_percent, case " .. i ..
                  " (want " .. tostring(expected) .. ", page said " .. tostring(got) .. ")")
         end
      end
   end
end

-- sharpMaxPercent is one function out of a whole MIRROR. The block the page
-- labels "Mirror of CO geometry" also carries pass_geometry, pass_count,
-- band_width, solve_band, w_from_size/size_from_w, floor4/ceil4 and the two
-- display_* capacity figures -- and NOTHING pinned any of them. Proved
-- 2026-08-03: a 3x error injected into where the page puts the seams on the
-- chamfer face left this suite and the layout gate both green, because the gate
-- measures overflow and every source check here reads spellings.
--
-- The block is pure arithmetic -- no DOM, no globals -- so it can be run for
-- REAL rather than read: lift it verbatim from the page, drive a table of cases
-- through it in ONE node process, and compare every answer to the Lua's. Same
-- rule as the check above: compare what the two sides COMPUTE, never what they
-- are spelled.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local page = f:read("*a"); f:close()

   -- From the margins declaration to the first line after the mirror that is
   -- not part of it. If the page is reorganised this stops matching and says
   -- so, which is the right failure: an unfound mirror must never read as an
   -- agreeing mirror.
   local block = page:match("(var SHOULDER_MARGIN = .-\n)var UNIT = ")
   CHECK(block ~= nil, "the page's mirror block is still delimited the expected way")

   -- Modes, angles and diameters chosen to exercise both rounding directions
   -- and both sides of the pass ceiling: an acute bit, an obtuse one, a
   -- one-pass chamfer, a multi-pass one, and one past what 8 passes can take.
   local cases = {
      { mode = "setback", size = 0.020, incl = 90,   dia = 0.25 },
      { mode = "setback", size = 0.120, incl = 90,   dia = 0.25 },
      { mode = "setback", size = 0.25,  incl = 90,   dia = 0.25 },
      { mode = "setback", size = 0.70,  incl = 90,   dia = 0.25 },
      { mode = "setback", size = 0.80,  incl = 90,   dia = 0.25 },   -- past the ceiling
      { mode = "face",    size = 0.030, incl = 60,   dia = 0.5  },
      { mode = "leg",     size = 0.030, incl = 12.4, dia = 0.25 },
      { mode = "face",    size = 0.031, incl = 120,  dia = 0.5  },
   }

   if block then
      local js = block .. "\nvar C = [\n"
      for _, c in ipairs(cases) do
         js = js .. string.format('["%s",%.17g,%.17g,%.17g],\n', c.mode, c.size, c.incl, c.dia)
      end
      js = js .. [[
];
function n(x){ return (x===null||x===undefined) ? "nil" : String(x); }
var out = [];
for (var i = 0; i < C.length; i++) {
  var mode = C[i][0], size = C[i][1], incl = C[i][2], dia = C[i][3];
  var a = halfAngle(incl), W = wFromSize(mode, size, a);
  var p = passCount(dia, W, a);
  var b = (p !== null) ? bandWidth(W, p) : W;
  var row = [n(W), n(p), n(b), n(displayMaxSize(mode, incl, dia)), n(displayMinDia(mode, size, incl))];
  if (p !== null) {
    var s = solveBand(80, dia, W, b, a);
    row.push(n(s.g), n(s.d));
    for (var k = 1; k <= p; k++) {
      var pg = passGeometry(k, p, W, s.g, a);
      row.push(n(pg.offset), n(pg.depth));
    }
  }
  out.push(row.join(","));
}
console.log(out.join("\n"));
]]

      local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
      local jspath = tmp .. "\\edgebreaker_mirror_check.js"
      local jf = io.open(jspath, "w")
      local out = nil
      if jf then
         jf:write(js); jf:close()
         local p = io.popen('node "' .. jspath .. '" 2>&1')
         out = p and p:read("*a") or nil
         if p then p:close() end
         os.remove(jspath)
      end

      -- Reported, never silently skipped -- same reasoning as the check above.
      CHECK(out ~= nil, "node could run the page's own geometry mirror for real")
      local lines = {}
      for l in (out or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = l end
      CHECK(#lines == #cases,
            "node produced one row per case (got " .. #lines .. "): " ..
            tostring(out and out:sub(1, 200)))

      local function near(x, want)
         return x ~= nil and math.abs(x - want) <= 1e-12 * math.max(1, math.abs(want))
      end
      local function cmp(tok, want, label)
         if want == nil then
            CHECK(tok == "nil", label .. " (want nil, page said " .. tostring(tok) .. ")")
         else
            CHECK(near(tonumber(tok or ""), want),
                  label .. " (want " .. tostring(want) .. ", page said " .. tostring(tok) .. ")")
         end
      end

      for i, c in ipairs(cases) do
         local toks = {}
         for t in (lines[i] or ""):gmatch("[^,]+") do toks[#toks + 1] = t end
         local ang = CO.half_angle(c.incl)
         local W = CO.w_from_size(c.mode, c.size, ang)
         local p = CO.pass_count(c.dia, W, ang)
         local b = (p ~= nil) and CO.band_width(W, p) or W
         local tag = c.mode .. " " .. c.size .. " " .. c.incl .. "deg " .. c.dia .. ": "
         cmp(toks[1], W, tag .. "W")
         cmp(toks[2], p, tag .. "pass count")
         cmp(toks[3], b, tag .. "band width")
         cmp(toks[4], CO.display_max_size(c.mode, c.incl, c.dia), tag .. "display max size")
         cmp(toks[5], CO.display_min_dia(c.mode, c.size, c.incl), tag .. "display min dia")
         if p ~= nil then
            local s = CO.solve_band(80, c.dia, W, b, ang)
            cmp(toks[6], s.g, tag .. "solve_band G")
            cmp(toks[7], s.d, tag .. "solve_band D")
            for k = 1, p do
               local pg = CO.pass_geometry(k, p, W, s.g, ang)
               cmp(toks[6 + 2 * k], pg.offset, tag .. "pass " .. k .. " offset")
               cmp(toks[7 + 2 * k], pg.depth, tag .. "pass " .. k .. " depth")
            end
         end
      end
   end
end
