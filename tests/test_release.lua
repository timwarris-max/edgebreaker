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
CHECK(unscoped == nil and unscoped_why:find(CO.offset_layer_name(1), 1, true) ~= nil
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
   CHECK(slayers ~= nil and slayers[1] == CO.offset_layer_name(1),
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

-- v1.4.0: the template's layer restriction is rewritten two characters wide so
-- each chamfer cuts its own layer. Same-length means the file's length, record
-- structure and every offset in it are untouched -- the same class of edit as
-- the depth patch, and NOT the record insertion Aspire rejects. The read-back
-- through read_template_layers is the check that actually matters: it proves
-- Aspire's own layout still parses after the swap.
local tbytes
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.ToolpathTemplate", "rb"))
   tbytes = f:read("*a"); f:close()
end

local shipped_layers = CO.read_template_layers(tbytes)
CHECK(shipped_layers ~= nil and #shipped_layers == 1
      and shipped_layers[1] == CO.offset_layer_name(1),
      "shipped template is restricted to slot 1's layer")

local p3 = CO.patch_template_layer(tbytes, 3)
CHECK(type(p3) == "string", "patching to slot 3 succeeds")
CHECK(p3 ~= nil and #p3 == #tbytes, "patch does not change the file length")
local back = p3 and CO.read_template_layers(p3)
CHECK(back ~= nil and #back == 1 and back[1] == CO.offset_layer_name(3),
      "patched template reads back as slot 3's layer")

-- Only the digit characters move. "01" -> "03" changes the second digit alone;
-- "01" -> "12" changes both. In UTF-16LE each digit is one ASCII byte plus a
-- zero byte, and the zero bytes never change -- so the counts are 1 and 2.
local function byte_diff(a, b)
   local n = 0
   for i = 1, #a do
      if a:byte(i) ~= b:byte(i) then n = n + 1 end
   end
   return n
end
CHECK(p3 and byte_diff(tbytes, p3) == 1, "slot 3 changes exactly one byte")
local p12 = CO.patch_template_layer(tbytes, 12)
CHECK(p12 and byte_diff(tbytes, p12) == 2, "slot 12 changes exactly two bytes")
CHECK(p12 and #p12 == #tbytes, "a two-digit slot still preserves the length")
local back12 = p12 and CO.read_template_layers(p12)
CHECK(back12 ~= nil and back12[1] == CO.offset_layer_name(12),
      "slot 12 reads back correctly")

-- Everything else the loader reads must survive untouched.
CHECK(p3 and CO.read_machine_vectors(p3) == "on", "patch leaves Machine Vectors alone")
CHECK(p3 and CO.read_template_units(p3) == CO.read_template_units(tbytes),
      "patch leaves the units flag alone")
CHECK(p3 and CO.find_depth_offset(p3) == CO.find_depth_offset(tbytes),
      "patch leaves the depth field where it was")

-- Slot 1 -> slot 1 is a no-op, not an error.
local p1 = CO.patch_template_layer(tbytes, 1)
CHECK(p1 == tbytes, "patching to the slot it already names changes nothing")

-- Refuse anything that is not the template we shipped. (The plan pointed at
-- tests/tools/; the fixture actually lives in tests/fixtures/.)
local wrong
do
   local f = assert(io.open("tests/fixtures/wrong-layer.ToolpathTemplate", "rb"))
   wrong = f:read("*a"); f:close()
end
local bad, berr = CO.patch_template_layer(wrong, 2)
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
CHECK(CO.VERSION == "1.10.2", "version gate: 1.10.2")
-- The page prints the version in its own header and cannot read the Lua, so the
-- two drift silently -- and the number on screen is what an operator quotes in
-- a bug report.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreakerDialog.htm", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find('<span class="ver">v' .. CO.VERSION .. '</span>', 1, true) ~= nil,
         "the setup dialog's header prints CO.VERSION")
end
CHECK(CO.offset_layer_name(7) == "EdgeBreaker - Offset 07", "new layer name")
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
   local lua  = slurp_text("gadget/EdgeBreaker/EdgeBreaker.lua")
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
   CHECK(dw == "360" and dh == "200",
         "the measuring window is 360x200 -- keep SCR_W/SCR_H in the layout gate in step")

   -- Both pages must actually read the screen, not just declare a field.
   CHECK(page:find("screen.availWidth", 1, true) ~= nil,
         "the measuring page reads availWidth")
   CHECK(dlg:find("screen.availWidth", 1, true) ~= nil,
         "the setup dialog reports its screen too, which is what stops the flash returning")

   -- Sizing is a convenience and must never speak. show_message and
   -- DisplayMessageBox are both shouting; neither belongs on this path.
   local body = lua:match("function CO%.sdk_measure_screen.-\nend\n")
   CHECK(body ~= nil, "sdk_measure_screen exists")
   CHECK(body == nil or body:find("show_message", 1, true) == nil,
         "measuring never opens a message window")
   CHECK(body == nil or body:find("DisplayMessageBox", 1, true) == nil,
         "measuring never opens a message box")
end
