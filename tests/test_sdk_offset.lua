-- CO.sdk_offset_loop's tri-state contract (v1.3.0): a group means success,
-- bare nil means "too narrow to chamfer, skip and count it", nil+message
-- means an SDK call actually failed and the caller stops. The GEOMETRY behind
-- this is only exercisable inside Aspire, but the branching around the four
-- SDK calls (Selection:Clear/Add, CreateCopyOfSelectedContours, :Offset) is
-- pure Lua and is exactly the place a wrong answer becomes a wrong cut, so it
-- is faked and driven here one outcome at a time. Every case checks BOTH
-- return values, so a bare nil can never be mistaken for a nil+message.
local CO = EdgeBreaker

-- CreateCopyOfSelectedContours is an Aspire SDK global sdk_offset_loop calls
-- unqualified. It does not exist in this harness until we define it below, and
-- it must not leak into later test files (dofile'd into shared state) -- save
-- and restore it.
local SAVED_CREATE_COPY = CreateCopyOfSelectedContours

local FAKE_OBJ = {}   -- stands in for the CAD object handed to Selection:Add

-- A fake job whose Selection has Clear/Add and a Count that the test controls
-- directly (Add doesn't need to compute it -- sdk_offset_loop only reads it).
local function fake_job(selection_count)
   return {
      Selection = {
         Count = selection_count,
         Clear = function() end,
         Add = function() end,
      },
   }
end

local copy_calls, offset_calls

-- Installs CreateCopyOfSelectedContours so it counts its own calls and, if
-- copy_result is a function, delegates copy:Offset(...) to it (recording the
-- call); otherwise copy_result IS what CreateCopyOfSelectedContours returns
-- (nil, or an error thrown via copy_result == "raise:copy").
local function install_copy(offset_result)
   copy_calls, offset_calls = 0, {}
   CreateCopyOfSelectedContours = function(smash_beziers, smash_arcs, tol)
      copy_calls = copy_calls + 1
      if offset_result == "nocopy" then return nil end
      return {
         Offset = function(self, dist, absdist, mode, preserve_arcs)
            offset_calls[#offset_calls + 1] =
               { dist = dist, absdist = absdist, mode = mode, preserve_arcs = preserve_arcs }
            if offset_result == "raise" then error("boom: bad tolerance") end
            return offset_result
         end,
      }
   end
end

-- 1. Success: a group with Count >= 1 comes back as the group, no error.
install_copy({ Count = 3 })
local job = fake_job(1)
local group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(type(group) == "table" and group.Count == 3, "success: returns the offset group")
CHECK(err == nil, "success: no error alongside a real group")
CHECK(copy_calls == 1, "success: copied exactly once")
CHECK(#offset_calls == 1, "success: :Offset called exactly once")
local c = offset_calls[1]
CHECK(c.dist == -0.05, "success: the signed distance reaches Aspire unchanged")
CHECK(c.absdist == 0.05, "success: width arg is abs(dist)")
CHECK(c.mode == 1, "success: mode arg is 1")
CHECK(c.preserve_arcs == true,
      "success: preserve_arcs true -- the only 4-arg form that binds on Aspire 12.5")

-- 2. Count == 0: the "too narrow" skip case, not an error.
install_copy({ Count = 0 })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "zero-count offset: bare nil, not the empty group")
CHECK(err == nil, "zero-count offset: no error -- this is the skip case")

-- 3. :Offset itself returns nil (Aspire collapsed the feature entirely):
-- also the skip case, not an error.
install_copy(nil)
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "offset returns nil: bare nil result")
CHECK(err == nil, "offset returns nil: no error -- still the skip case, not a failure")

-- 4. Unreadable Count on the offset result (wrong property name reads nil
-- rather than raising under luabind) -- this IS a failure, with a message.
install_copy({})   -- a real, non-nil group, but with no readable Count
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "unreadable Count: nil group")
CHECK(type(err) == "string" and err:find("Count", 1, true) ~= nil,
      "unreadable Count: error names the property, not the geometry")

-- 5. CreateCopyOfSelectedContours itself returns nil -- a failure, with a message.
install_copy("nocopy")
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "copy failed: nil group")
CHECK(type(err) == "string" and err:find("copy", 1, true) ~= nil,
      "copy failed: error mentions the copy step")
-- Live 2026-07-26: this, not the Count guard, is the branch a grouped child
-- actually lands on -- Selection:Add(child) succeeds and reports 1, then the
-- copy refuses. Without the hint the user gets a symptom and no way forward.
CHECK(err:find("ungroup", 1, true) ~= nil,
      "copy failed: error tells the user how to fix it (ungroup and retry)")

-- 6. A raise inside one of the SDK calls -- a failure, message carries the
-- original text (pcall catches it and sdk_offset_loop reports tostring(res)).
install_copy("raise")
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "SDK raise: nil group")
CHECK(type(err) == "string" and err:find("boom", 1, true) ~= nil,
      "SDK raise: error carries the original message text")

-- 7. Fix 1's guard: Selection.Count comes back as something other than 1,
-- meaning Add either no-op'd (a group child that didn't take) or promoted to
-- the parent group (sweeping siblings in). Either way this is a failure the
-- caller must stop on, and it must never reach CreateCopyOfSelectedContours.
install_copy({ Count = 3 })   -- would look like success if the guard didn't fire
job = fake_job(0)             -- Add no-op'd: selection stayed empty
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "selection count 0: nil group")
CHECK(type(err) == "string" and err:find("group", 1, true) ~= nil,
      "selection count 0: error mentions grouping")
CHECK(copy_calls == 0, "selection count 0: never reached CreateCopyOfSelectedContours")

install_copy({ Count = 3 })
job = fake_job(5)             -- Add promoted to a 5-member parent group
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05)
CHECK(group == nil, "selection count 5 (promoted): nil group")
CHECK(type(err) == "string" and err:find("group", 1, true) ~= nil,
      "selection count 5 (promoted): error mentions grouping")
CHECK(copy_calls == 0, "selection count 5 (promoted): never reached CreateCopyOfSelectedContours")

-- Sharp mode (v1.11.0, Finding 1 review 2026-07-31): sdk_offset_loop's 4th
-- arg is now sharp_dist, not a plain flag -- nil on a normal run, the shifted
-- distance on a sharp run. On a sharp run the SAME copy is offset TWICE:
-- once at dist (the normal distance) as a viability probe whose group is
-- thrown away, and -- only if that probe comes back non-empty -- again at
-- sharp_dist, which is then squared with MakeOffsetsSquare. This is the fix
-- for the sharp path structurally disabling the too-narrow safety net.
--
-- 2026-08-03, sharp corners on OUTSIDE runs. The old note here said "the
-- shifted distance is always outward, so on its own it can never collapse",
-- and that was only ever the inward half of the story. The sharp loop is the
-- chamfer's top edge, drawn W toward the MATERIAL: outside a pocket wall on an
-- inside run, where nothing can collapse it, but INTO the shape on an outside
-- run, where a stem narrower than two chamfers has no top edge left to draw.
-- So an EMPTY sharp offset is now the same bare-nil "too narrow, skip it and
-- count it" answer as an empty probe -- a real limit of the chamfer, not a
-- fault. Only an UNREADABLE Count is still a failure, because that means a
-- wrong property name rather than a geometry problem. Both come from the
-- shared offset_and_check helper, which is why the two paths cannot drift
-- apart about what an empty offset MEANS (spec 3e / 4a.6).
--
-- Every sharp case below runs both ways round: inward (dist negative,
-- sharp_dist negative) and outward (dist positive, sharp_dist NEGATIVE -- the
-- loop drawn back into the material). The signs are the whole difference
-- between the two sides, so they are asserted, not assumed.
--
-- NILR is a sentinel meaning "this :Offset call returns nil", so a hole in
-- the offsets list can be distinguished from "no more calls expected".
local NILR = {}

-- A fake offset-result group: readable Count, and a MakeOffsetsSquare method
-- whose return value the test controls. Every call's ARGUMENTS are recorded
-- too: the real signature is
--    bool MakeOffsetsSquare(ContourGroup*, double, bool, double)
-- and that bool is the squaring switch. It shipped as false, which Aspire
-- honours by squaring nothing and STILL returning true -- indistinguishable
-- from success at the call site, and only caught by looking at the cut (Task 9
-- sitting, 2026-07-31). Nothing but an argument assertion can hold that line.
local square_calls = {}
local function grp(count, square_result)
   return {
      Count = count,
      MakeOffsetsSquare = function(self, w, flag, w2)
         square_calls[#square_calls + 1] = { w = w, flag = flag, w2 = w2 }
         return square_result
      end,
   }
end

-- Installs CreateCopyOfSelectedContours so repeated :Offset calls on the SAME
-- copy return successive entries from `results`, in order, recording every
-- call's args. A "raise" entry throws instead of returning.
local function install_sharp_copy(results)
   copy_calls, offset_calls, square_calls = 0, {}, {}
   local n = 0
   CreateCopyOfSelectedContours = function()
      copy_calls = copy_calls + 1
      return {
         Offset = function(self, dist, absdist, mode, preserve_arcs)
            n = n + 1
            offset_calls[#offset_calls + 1] =
               { dist = dist, absdist = absdist, mode = mode, preserve_arcs = preserve_arcs }
            local r = results[n]
            if r == "raise" then error("boom: sharp offset") end
            if r == NILR then return nil end
            return r
         end,
      }
   end
end

-- Finding 1: the probe collapses (too narrow at the NORMAL distance) -- skip
-- it and count it, exactly like a normal run, and never even attempt the
-- real sharp offset.
install_sharp_copy({ NILR })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp probe collapses: bare nil, the skip case")
CHECK(err == nil, "sharp probe collapses: no error -- too narrow, not a failure")
CHECK(#offset_calls == 1, "sharp probe collapses: the real sharp offset is never attempted")

-- (a) the probe passes, the real sharp offset passes, MakeOffsetsSquare
-- returns a fresh group with Count >= 1 -- adopted.
install_sharp_copy({ grp(2), grp(2, grp(5)) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(err == nil, "sharp success: no error")
CHECK(type(group) == "table" and group.Count == 5,
      "sharp success: the squared group is adopted")
CHECK(#offset_calls == 2, "sharp success: probe then real sharp offset, two :Offset calls")
CHECK(offset_calls[1].dist == -0.05, "sharp success: the probe uses the plain dist")
CHECK(offset_calls[2].dist == -0.09, "sharp success: the real sharp offset uses sharp_dist")

-- The squaring call's own arguments. The middle one is the whole feature, and
-- it is the OFFSET'S DIRECTION, not an on/off switch: true means "offset
-- outward", false means "offset inward". Get it wrong and the call squares
-- nothing and still returns true -- indistinguishable from success at the call
-- site, which is how it reached two separate live sittings. Measured by
-- SquareProbe 2026-08-03: inward+false and outward+true both give 0 arcs;
-- inward+true and outward+false both leave the arcs untouched.
--
-- This case's sharp_dist is NEGATIVE, so the honest answer is false.
CHECK(#square_calls == 1, "sharp success: MakeOffsetsSquare called exactly once")
CHECK(square_calls[1].flag == false,
      "sharp success: an inward sharp offset tells squaring it went INWARD")
CHECK(square_calls[1].w == 0.09,
      "sharp success: squaring gets the sharp distance's magnitude")
CHECK(square_calls[1].w2 == 0.18,
      "sharp success: squaring's third argument is twice that distance")

-- (b) MakeOffsetsSquare returns true: the post-process worked in place, so
-- the ungrown group is kept.
install_sharp_copy({ grp(2), grp(3, true) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(err == nil, "sharp, square true: no error")
CHECK(type(group) == "table" and group.Count == 3,
      "sharp, square true: the original sharp group is kept")

-- (c) MakeOffsetsSquare returns nil: a refusal, never a silent round-cornered cut.
install_sharp_copy({ grp(2), grp(3, nil) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp, square nil: nil group")
CHECK(type(err) == "string" and err:find("square", 1, true) ~= nil,
      "sharp, square nil: error names the squaring step")

-- (d) MakeOffsetsSquare returns something unreadable (a table with no usable
-- Count): also a refusal.
install_sharp_copy({ grp(2), grp(3, {}) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp, square unreadable: nil group")
CHECK(type(err) == "string" and err:find("square", 1, true) ~= nil,
      "sharp, square unreadable: error names the squaring step")

-- (e) MakeOffsetsSquare throws: caught by pcall, reported as a failure.
-- grp()'s square_result is a fixed value, not callable, so this needs its
-- own fake rather than grp -- MakeOffsetsSquare itself raises.
copy_calls, offset_calls = 0, {}
CreateCopyOfSelectedContours = function()
   copy_calls = (copy_calls or 0) + 1
   local n = 0
   return {
      Offset = function(self, dist, absdist, mode, preserve_arcs)
         n = n + 1
         if n == 1 then return { Count = 2 } end
         return {
            Count = 3,
            MakeOffsetsSquare = function() error("boom: square") end,
         }
      end,
   }
end
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp, square raises: nil group")
CHECK(type(err) == "string" and err:find("boom", 1, true) ~= nil,
      "sharp, square raises: error carries the original message text")

-- (f) The real sharp offset comes back empty after the probe passed. Until
-- outside sharp runs existed this was reported as an unexpected internal
-- failure that stopped the whole run; it is now the ordinary too-narrow SKIP
-- (spec 3e). The shape has no top edge left to draw at this chamfer size --
-- that is a limit of the chamfer, and aborting a whole letter set over one
-- thin stem is the wrong answer. Bare nil, no message, and nothing squared.
install_sharp_copy({ grp(2), NILR })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp offset empty after the probe passed: bare nil, the skip case")
CHECK(err == nil,
      "sharp offset empty after the probe passed: no error -- too narrow, not a failure")
CHECK(#square_calls == 0,
      "sharp offset empty after the probe passed: nothing is squared")

-- (g) ... and the same shape with a zero Count rather than a nil result, which
-- is the other way Aspire says "nothing left": also a skip, also silent.
install_sharp_copy({ grp(2), grp(0) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp offset count 0: bare nil, the skip case")
CHECK(err == nil, "sharp offset count 0: no error")
CHECK(#square_calls == 0, "sharp offset count 0: nothing is squared")

-- (h) An UNREADABLE Count on the sharp offset is still a failure, and must
-- stay one: a nil Count means the property name is wrong, not that the shape
-- is thin, and reporting it as "too narrow" would send the next reader at the
-- chamfer size instead of at the SDK. The message now comes from the shared
-- offset_and_check helper, the same words case 4 above gets on the plain
-- offset.
install_sharp_copy({ grp(2), { Count = "banana" } })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, -0.09)
CHECK(group == nil, "sharp offset with an unreadable Count: nil group")
CHECK(type(err) == "string" and err:find("Count", 1, true) ~= nil,
      "sharp offset with an unreadable Count: error names the property, not the geometry")
CHECK(#square_calls == 0, "sharp offset with an unreadable Count: nothing is squared")

-- OUTWARD sharp runs (2026-08-03). Every case above drives inward distances
-- only, which is where the feature started and no longer where it lives. On an
-- outside run the plain probe goes OUT into the waste (+dist) and the sharp
-- loop goes back IN to the material (-sharp_dist) -- opposite signs on the two
-- calls, which never happens inward. If the signs were ever transposed the cut
-- would land on the wrong side of the wall, so they are asserted one by one.
--
-- (i) Outward success: two :Offset calls, the exact distances in that order,
-- and a squaring call that still takes the MAGNITUDE (and still true).
install_sharp_copy({ grp(2), grp(2, grp(7)) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, 0.05, -0.02)
CHECK(err == nil, "outward sharp success: no error")
CHECK(type(group) == "table" and group.Count == 7,
      "outward sharp success: the squared group is adopted")
CHECK(#offset_calls == 2,
      "outward sharp success: probe then real sharp offset, two :Offset calls")
CHECK(offset_calls[1].dist == 0.05,
      "outward sharp success: the probe goes OUT into the waste")
CHECK(offset_calls[2].dist == -0.02,
      "outward sharp success: the sharp loop goes back IN to the material")
CHECK(offset_calls[2].absdist == 0.02,
      "outward sharp success: the width arg is the magnitude, not the signed distance")
CHECK(#square_calls == 1, "outward sharp success: MakeOffsetsSquare called exactly once")
CHECK(square_calls[1].flag == false,
      "outward sharp success: an OUTSIDE run offsets INWARD, and says so")
-- The magnitude is right and the sign does NOT belong here -- signing this
-- argument was tried live on 2026-08-03 and changed nothing. The direction
-- rides on the flag above.
CHECK(square_calls[1].w == 0.02,
      "outward sharp success: squaring gets abs(sharp_dist), not the negative")
CHECK(square_calls[1].w2 == 0.04,
      "outward sharp success: squaring's third argument is twice that magnitude")

-- (i2) The other direction, and until 2026-08-03 nothing pinned it. Every
-- fixture above drives a NEGATIVE sharp_dist, so a squaring flag hardcoded to
-- false would have passed the lot -- and the real inside run, the one v1.11.0
-- ships and Task 9 verified on the machine, is the POSITIVE case: the plain
-- probe goes into the shape (-dist) and the sharp loop comes back OUT into the
-- material (+sharp_dist). It must tell squaring it went outward, or v1.11.0's
-- sharpening silently stops working. Both directions are pinned from here.
install_sharp_copy({ grp(2), grp(2, grp(6)) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, 0.09)
CHECK(err == nil, "inside sharp success: no error")
CHECK(offset_calls[1].dist == -0.05, "inside sharp success: the probe goes INTO the shape")
CHECK(offset_calls[2].dist == 0.09,
      "inside sharp success: the sharp loop goes OUT to the material")
CHECK(#square_calls == 1, "inside sharp success: MakeOffsetsSquare called exactly once")
CHECK(square_calls[1].flag == true,
      "inside sharp success: an INSIDE run offsets OUTWARD, and says so")
CHECK(square_calls[1].w == 0.09,
      "inside sharp success: squaring still gets the magnitude")

-- (j) THE new failure mode, and the reason this whole change exists (spec 3e):
-- an outward run whose plain probe PASSES -- the shape is wide enough to
-- chamfer at the normal distance -- but whose sharp loop, drawn W into the
-- material, collapses because the stem is narrower than two chamfers. Skip it
-- and count it. It must not stop the run, and it must not square anything.
install_sharp_copy({ grp(2), NILR })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, 0.05, -0.02)
CHECK(group == nil, "outward sharp loop collapses: bare nil, the skip case")
CHECK(err == nil,
      "outward sharp loop collapses: no error -- the shape has no top edge left, "
      .. "which is a chamfer limit, not a fault")
CHECK(#offset_calls == 2,
      "outward sharp loop collapses: the probe passed, so the sharp offset WAS attempted")
CHECK(#square_calls == 0, "outward sharp loop collapses: nothing is squared")

-- (k) The same collapse reported as a zero count instead of a nil result.
install_sharp_copy({ grp(2), grp(0) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, 0.05, -0.02)
CHECK(group == nil, "outward sharp loop count 0: bare nil, the skip case")
CHECK(err == nil, "outward sharp loop count 0: no error")
CHECK(#square_calls == 0, "outward sharp loop count 0: nothing is squared")

-- (l) An outward run whose PLAIN probe collapses is unchanged: still a skip,
-- and the sharp offset is still never attempted.
install_sharp_copy({ NILR })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, 0.05, -0.02)
CHECK(group == nil, "outward probe collapses: bare nil, the skip case")
CHECK(err == nil, "outward probe collapses: no error")
CHECK(#offset_calls == 1,
      "outward probe collapses: the real sharp offset is never attempted")

-- (m) An unreadable Count on an outward sharp offset is still a failure, the
-- same as inward: the side changes what can collapse, never what a broken
-- property name means.
install_sharp_copy({ grp(2), { Count = "banana" } })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, 0.05, -0.02)
CHECK(group == nil, "outward sharp offset with an unreadable Count: nil group")
CHECK(type(err) == "string" and err:find("Count", 1, true) ~= nil,
      "outward sharp offset with an unreadable Count: error names the property")

-- A normal run (sharp_dist == nil) must be completely unaffected: one
-- :Offset call, no MakeOffsetsSquare, exactly the pre-Finding-1 behaviour.
install_sharp_copy({ grp(4) })
job = fake_job(1)
group, err = CO.sdk_offset_loop(job, FAKE_OBJ, -0.05, nil)
CHECK(err == nil and type(group) == "table" and group.Count == 4,
      "normal run: unaffected by the sharp path")
CHECK(#offset_calls == 1, "normal run: exactly one :Offset call")

CreateCopyOfSelectedContours = SAVED_CREATE_COPY

-- sdk_scan_chamfers reads the job twice -- layers for offsets, toolpaths for
-- names -- and a slot counts as existing if EITHER shows it, so a half-deleted
-- chamfer can still be selected and rebuilt. The iteration is Aspire's
-- GetHeadPosition/GetNext shape, faked here.
local function fake_list(items)
   return {
      GetHeadPosition = function() return #items > 0 and 1 or nil end,
      GetNext = function(_, pos)
         local nxt = pos + 1
         return items[pos], (nxt <= #items) and nxt or nil
      end,
   }
end

local SAVED_TPM = ToolpathManager

local function fake_job_with(layer_names, toolpath_names)
   local layers = {}
   for _, n in ipairs(layer_names) do layers[#layers + 1] = { Name = n } end
   local tps = {}
   for _, n in ipairs(toolpath_names) do tps[#tps + 1] = { Name = n } end
   ToolpathManager = function() return fake_list(tps) end
   return { LayerManager = fake_list(layers) }
end

do
   local job = fake_job_with({ "Layer 1" }, { "Profile 1" })
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 0, "a job with no chamfers scans empty")
   CHECK(legacy == false, "a job with no chamfers has no legacy note")
end

do
   local job = fake_job_with(
      { "Layer 1", CO.offset_layer_name(1), CO.offset_layer_name(2) },
      { "Chamfer 0.06 in " .. CO.toolpath_marker(1), "Profile 1" })
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 2, "both chamfer layers found")
   CHECK(found[1].slot == 1 and found[2].slot == 2, "slots come back in ascending order")
   CHECK(found[1].size == "0.06 in", "size read off the toolpath name")
   CHECK(found[2].size == nil, "a slot with no toolpath has no size")
   CHECK(legacy == false, "numbered chamfers are not legacy")
end

do
   -- A toolpath whose layer was deleted by hand must still be listed.
   local job = fake_job_with({ "Layer 1" }, { "Chamfer 0.02 in " .. CO.toolpath_marker(4) })
   local found = CO.sdk_scan_chamfers(job)
   CHECK(#found == 1 and found[1].slot == 4, "a toolpath with no layer still counts")
end

do
   local job = fake_job_with({ CO.LEGACY_OFFSET_LAYER }, {})
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 0, "the pre-1.4.0 layer is not a slot")
   CHECK(legacy == true, "the pre-1.4.0 layer raises the legacy note")
end

do
   local job = fake_job_with({}, { "Chamfer 0.02 in " .. CO.LEGACY_TOOLPATH_MARKER })
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 0, "the pre-1.4.0 marker is not a slot")
   CHECK(legacy == true, "the pre-1.4.0 marker raises the legacy note")
end

-- v1.4.x chamfers are ADOPTED, not orphaned: they keep their number, carry
-- their size, and are marked "old" so the first rebuild migrates them.
do
   local job = fake_job_with({ "ChamferOffset - Offset 02" },
                             { "Chamfer 0.04 in [ChamferOffset 02]" })
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 1 and found[1].slot == 2, "an old-name chamfer is adopted")
   CHECK(found[1].origin == "old", "adopted chamfer is marked old")
   CHECK(found[1].size == "0.04 in", "an adopted chamfer still shows its size")
   CHECK(found[1].memory == nil, "nothing ever wrote memory for an old chamfer")
   CHECK(legacy == false, "adoption alone raises no legacy note")
end

-- Both generations claiming ONE slot: the new entry wins and the clash is
-- reported, or the slot would own two layers and two toolpaths.
do
   local job = fake_job_with({ CO.offset_layer_name(2), "ChamferOffset - Offset 02" },
                             { "Chamfer 0.06 in " .. CO.toolpath_marker(2) })
   local found, legacy = CO.sdk_scan_chamfers(job)
   CHECK(#found == 1 and found[1].origin == "new", "new name wins a slot clash")
   CHECK(found[1].size == "0.06 in", "the winning entry keeps its own size")
   CHECK(legacy == true, "a slot claimed twice is reported")
end

-- CO.sdk_own_layer_ids: one pass over the layers, collecting the Id of every
-- layer the gadget owns. This replaces walking every object on every offset
-- layer and computing a bounding box for each -- the guard now compares ids,
-- not geometry, so it never needs to look at an object at all.
--
-- Id, NOT RawId. Measured at the machine 2026-08-05: Id is a plain GUID string
-- and RawId is opaque userdata with no tostring and no == ("Raw" is the raw
-- HANDLE, not the raw value). The fixtures below use GUID-shaped strings for
-- that reason -- a fixture keyed by integers would pass while the product
-- failed live, which is the whole class of mistake this design exists to undo.
do
   local function layer(name, id)
      return { Name = name, Id = id }
   end
   local function job_of(layers)
      return { LayerManager = {
         GetHeadPosition = function() return #layers > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return layers[pos], (nxt <= #layers) and nxt or nil
         end,
      } }
   end
   -- Shaped like the real thing: "484e94a6-a0a9-4984-8da5-2aeb9e8d9f7a".
   local function guid(n) return string.format("0000000%d-aaaa-4bbb-8ccc-ddddeeeeffff", n) end

   local job = job_of({
      layer("Layer 1", guid(0)),
      layer(CO.offset_layer_name(1, 1), guid(1)),
      layer(CO.offset_layer_name(2, 1), guid(2)),
      layer(CO.offset_layer_name(2, 2), guid(3)),
      layer(CO.OLD_LAYER_PREFIX .. "03", guid(4)),
      layer(CO.LEGACY_OFFSET_LAYER, guid(5)),
   })
   local ids, unknown = CO.sdk_own_layer_ids(job)
   CHECK(unknown == 0, "own ids: readable layers are not counted as unknown")
   CHECK(ids[guid(1)] and ids[guid(2)] and ids[guid(3)] and ids[guid(4)] and ids[guid(5)],
         "own ids: every generation of our layers is collected")
   CHECK(not ids[guid(0)], "own ids: the operator's own layer is never collected")

   -- Every chamfer's layers, not just the one being built: box-selecting a
   -- whole job to build chamfer 3 sweeps in chamfers 1 and 2's offsets, and if
   -- those are not recognised the gadget offsets its own offsets and cuts them.
   local n = 0
   for _ in pairs(ids) do n = n + 1 end
   CHECK(n == 5, "own ids: exactly the five layers of ours, no more")

   -- Fail closed, both ways. A layer whose NAME cannot be read might be ours.
   local bad_name = job_of({ setmetatable({ Id = guid(9) }, { __index = function(_, k)
      if k == "Name" then error("no such member") end
   end }) })
   local _, un_name = CO.sdk_own_layer_ids(bad_name)
   CHECK(un_name == 1, "own ids: an unreadable NAME is unknown, never assumed foreign")

   -- A layer that IS ours whose Id cannot be read would leave a copy able to
   -- ride into the input -- the whole defect. Unknown, so main() refuses.
   local bad_id = job_of({ setmetatable({ Name = CO.offset_layer_name(1, 1) },
      { __index = function(_, k)
         if k == "Id" then error("no such member") end
      end }) })
   local ids_bi, un_id = CO.sdk_own_layer_ids(bad_id)
   CHECK(un_id == 1, "own ids: our layer with an unreadable id is unknown")
   local m = 0
   for _ in pairs(ids_bi) do m = m + 1 end
   CHECK(m == 0, "own ids: and contributes nothing to the set")

   -- An Id that reads but is not a STRING is unknown too. RawId is opaque
   -- userdata on this SDK, so a wrong-member slip lands here rather than
   -- keying the set with something that can never match an object's LayerId.
   local odd_id = job_of({ layer(CO.offset_layer_name(1, 1), 12345) })
   local ids_odd, un_odd = CO.sdk_own_layer_ids(odd_id)
   CHECK(un_odd == 1 and next(ids_odd) == nil,
         "own ids: a non-string id is unknown, not a set key")

   -- A layer that is NOT ours and whose id is unreadable is simply ignored:
   -- its id was never going into the set, so it cannot cost anything.
   local bad_foreign = job_of({ setmetatable({ Name = "Layer 1" },
      { __index = function(_, k)
         if k == "Id" then error("no such member") end
      end }) })
   local _, un_foreign = CO.sdk_own_layer_ids(bad_foreign)
   CHECK(un_foreign == 0, "own ids: a foreign layer's unreadable id is not our problem")

   -- No layers at all is not an error; it is a job with no chamfers in it.
   local ids_e, un_e = CO.sdk_own_layer_ids(job_of({}))
   local e = 0
   for _ in pairs(ids_e) do e = e + 1 end
   CHECK(e == 0 and un_e == 0, "own ids: an empty job yields an empty set")
end

ToolpathManager = SAVED_TPM

-- v1.4.0: both destructive steps take a slot. Deleting another chamfer's
-- toolpath, or wiping another chamfer's layer, is the whole defect this
-- release exists to fix -- so both are asserted against a job holding three.
do
   local asked = {}
   local wiped = {}
   local layer = {
      objs = { "a", "b" },
      GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end,
      GetNext = function(self, pos)
         local nxt = pos + 1
         return self.objs[pos], (nxt <= #self.objs) and nxt or nil
      end,
      RemoveObject = function(_, obj) wiped[#wiped + 1] = obj end,
      SetColour = function() end,
   }
   local job = { LayerManager = {
      GetHeadPosition = function() return nil end,   -- no other layers to sweep
      GetLayerWithName = function(_, name)
         asked[#asked + 1] = name; return layer
      end,
   } }
   local got = CO.sdk_prepare_layers(job, 2, 1, false)
   CHECK(asked[1] == CO.offset_layer_name(2, 1), "prepare_layers asks for THIS slot's band 1")
   CHECK(#wiped == 2, "prepare_layers still wipes the layer it prepared")
   CHECK(got[1] == layer, "prepare_layers returns the layer, one per band")
end

-- v1.5.0 migration: rebuilding an ADOPTED v1.4.x chamfer has to clear the old
-- generation's layer too, or the job keeps two sets of offsets under one
-- number -- the stale one still visible, no longer cut, and impossible to tell
-- from the live one by eye. Only ever on request: a slot that exists under the
-- new name must never have an identically-numbered old layer swept away behind
-- the user's back (merge_scan reports that clash instead).
do
   local function fake_layer(objs)
      return {
         objs = objs,
         GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end,
         GetNext = function(self, pos)
            local nxt = pos + 1
            return self.objs[pos], (nxt <= #self.objs) and nxt or nil
         end,
         RemoveObject = function(self, obj) self.wiped = (self.wiped or 0) + 1 end,
         SetColour = function() end,
      }
   end
   local function fake_lm(named, removable)
      local new_layer = fake_layer({ "stale-new" })
      local layers = {}
      for name, L in pairs(named) do L.Name = name; layers[#layers + 1] = L end
      return new_layer, {
         GetLayerWithName = function(_, name) return new_layer end,
         GetHeadPosition = function() return #layers > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return layers[pos], (nxt <= #layers) and nxt or nil
         end,
         RemoveLayer = function(_, layer)
            if not removable then error("this build has no RemoveLayer") end
            layer.removed = true
         end,
      }
   end

   local old2 = fake_layer({ "old-a", "old-b" })
   local old3 = fake_layer({ "other-chamfer" })
   local new_layer, lm = fake_lm({ ["ChamferOffset - Offset 02"] = old2,
                                   ["ChamferOffset - Offset 03"] = old3 }, true)
   local got, old_left = CO.sdk_prepare_layers({ LayerManager = lm }, 2, 1, true)
   CHECK(got[1] == new_layer, "migration still returns the new layer to draw on")
   CHECK(new_layer.wiped == 1, "the new layer is wiped as always")
   CHECK(old2.wiped == 2, "the old layer's offsets are wiped too")
   CHECK(old2.removed == true, "the emptied old layer is removed")
   CHECK(old3.wiped == nil and old3.removed == nil,
         "another chamfer's old layer is left completely alone")
   CHECK(old_left == false, "a removed old layer is not reported as left behind")

   -- Not asked to migrate: the old layer must not be touched at all.
   local old2b = fake_layer({ "old-a" })
   local nl2, lm2 = fake_lm({ ["ChamferOffset - Offset 02"] = old2b }, true)
   CO.sdk_prepare_layers({ LayerManager = lm2 }, 2, 1, false)
   CHECK(old2b.wiped == nil and old2b.removed == nil,
         "without the migrate flag the old layer is untouched")

   -- RemoveLayer is the one call here we have never run in Aspire. If it is
   -- absent the wipe still stands and the run continues -- an empty leftover
   -- layer is cosmetic, a failed run is not.
   local old2c = fake_layer({ "old-a" })
   local nl3, lm3 = fake_lm({ ["ChamferOffset - Offset 02"] = old2c }, false)
   local got3, left3 = CO.sdk_prepare_layers({ LayerManager = lm3 }, 2, 1, true)
   CHECK(got3[1] == nl3, "a failed RemoveLayer still returns the new layer")
   CHECK(old2c.wiped == 1, "a failed RemoveLayer still leaves the old layer emptied")
   CHECK(left3 == true, "an old layer that could not be removed is reported")

   -- Nothing to migrate (the adopted chamfer was a toolpath with no layer).
   local nl4, lm4 = fake_lm({ ["Layer 1"] = fake_layer({}) }, true)
   local got4, left4 = CO.sdk_prepare_layers({ LayerManager = lm4 }, 2, 1, true)
   CHECK(got4[1] == nl4 and left4 == false, "migrating with no old layer is a no-op")
end

-- Multi-pass: n layers out, and the bands a smaller pass count no longer needs
-- swept away. This is "rebuild a 6-pass chamfer with a bigger bit that needs 2"
-- -- the surplus bands are real layers full of real vectors, and leaving them
-- behind would show four orange rings nothing cuts.
do
   local function band_layer(name)
      return {
         Name = name,
         objs = { "a" },
         GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end,
         GetNext = function(self, pos)
            local nxt = pos + 1
            return self.objs[pos], (nxt <= #self.objs) and nxt or nil
         end,
         RemoveObject = function(self) self.wiped = (self.wiped or 0) + 1 end,
         SetColour = function(self) self.coloured = true end,
      }
   end
   local existing = {}
   for k = 1, 6 do existing[k] = band_layer(CO.offset_layer_name(2, k)) end
   -- Another chamfer's bands, and a band of ours that belongs to no slot we own.
   local other = band_layer(CO.offset_layer_name(3, 5))
   local mine = { existing[1], existing[2], existing[3], existing[4], existing[5],
                  existing[6], other }
   local lm = {
      GetHeadPosition = function() return 1 end,
      GetNext = function(_, pos)
         local nxt = pos + 1
         return mine[pos], (nxt <= #mine) and nxt or nil
      end,
      GetLayerWithName = function(_, name)
         for _, L in ipairs(existing) do if L.Name == name then return L end end
         error("asked for an unexpected layer: " .. tostring(name))
      end,
      RemoveLayer = function(_, layer) layer.removed = true end,
   }
   local got, old_left = CO.sdk_prepare_layers({ LayerManager = lm }, 2, 2, false)
   CHECK(#got == 2, "two passes get two layers")
   CHECK(got[1] == existing[1] and got[2] == existing[2],
         "and they come back in band order")
   CHECK(existing[1].wiped == 1 and existing[2].wiped == 1,
         "the bands that survive are emptied for the new run")
   CHECK(existing[1].removed == nil and existing[2].removed == nil,
         "and not removed -- they are about to be drawn on")
   CHECK(existing[3].removed and existing[4].removed
         and existing[5].removed and existing[6].removed,
         "the surplus bands are removed")
   CHECK(existing[6].wiped == 1, "a surplus band's vectors go with it")
   CHECK(other.wiped == nil and other.removed == nil,
         "another chamfer's bands are left completely alone")
   CHECK(old_left == false, "a clean sweep reports nothing left behind")
end

do
   local deleted = {}
   local tps = {
      { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(1) },
      { Name = "Chamfer 0.02 in " .. CO.toolpath_marker(2) },
      { Name = "Chamfer 0.01 in " .. CO.toolpath_marker(3) },
      { Name = "my own profile" },
      { Name = "Chamfer 0.02 in " .. CO.LEGACY_TOOLPATH_MARKER },
   }
   ToolpathManager = function()
      return {
         GetHeadPosition = function() return 1 end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return tps[pos], (nxt <= #tps) and nxt or nil
         end,
         DeleteToolpath = function(_, tp) deleted[#deleted + 1] = tp.Name end,
      }
   end
   local n, failed = CO.sdk_delete_marked_toolpaths(2)
   CHECK(n == 1 and failed == 0, "exactly one toolpath deleted")
   CHECK(deleted[1] == "Chamfer 0.02 in " .. CO.toolpath_marker(2),
         "only the chosen slot's toolpath is deleted")
   CHECK(#deleted == 1, "other chamfers, unmarked toolpaths and legacy ones survive")
   ToolpathManager = SAVED_TPM
end

-- A nil slot must not read as "matches everything unmarked". This is the one
-- input where the ownership test could invert and delete the user's own work.
do
   local deleted = {}
   local tps = { { Name = "my own profile" },
                 { Name = "Chamfer 0.02 in " .. CO.LEGACY_TOOLPATH_MARKER } }
   ToolpathManager = function()
      return {
         GetHeadPosition = function() return 1 end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return tps[pos], (nxt <= #tps) and nxt or nil
         end,
         DeleteToolpath = function(_, tp) deleted[#deleted + 1] = tp.Name end,
      }
   end
   local ok = pcall(CO.sdk_delete_marked_toolpaths, nil)
   CHECK(ok == false, "a nil slot raises instead of matching every unmarked toolpath")
   CHECK(#deleted == 0, "a nil slot deletes nothing - not user toolpaths, not legacy ones")
   local ok_str = pcall(CO.sdk_delete_marked_toolpaths, "2")
   CHECK(ok_str == false, "a string slot raises too - no accidental coercion")
   CHECK(#deleted == 0, "a string slot still deletes nothing")
   ToolpathManager = SAVED_TPM
end

-- Memory is written to the toolpath found by MARKER, not to the wrapper the
-- template load returned: a recalculate recreates the toolpath and leaves that
-- wrapper pointing at nothing.
do
   local tps = { { Name = "my own profile" },
                 { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(2) } }
   ToolpathManager = function()
      return {
         GetHeadPosition = function() return 1 end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return tps[pos], (nxt <= #tps) and nxt or nil
         end,
      }
   end
   CHECK(CO.sdk_find_toolpath_by_slot(2) == tps[2], "the slot's toolpath is found by its marker")
   CHECK(CO.sdk_find_toolpath_by_slot(3) == nil, "a slot with no toolpath finds nothing")
   ToolpathManager = function() error("no toolpath manager") end
   CHECK(CO.sdk_find_toolpath_by_slot(2) == nil, "an SDK failure is nil, never a raise")
   ToolpathManager = SAVED_TPM
end

-- Multi-pass: find all toolpaths carrying a slot marker (one exists per pass).
do
   local tps = { { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(1) },
                 { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(1) .. " pass 2" },
                 { Name = "Chamfer 0.02 in " .. CO.toolpath_marker(2) },
                 { Name = "my own profile" } }
   ToolpathManager = function()
      return {
         GetHeadPosition = function() return 1 end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return tps[pos], (nxt <= #tps) and nxt or nil
         end,
      }
   end
   local found = CO.sdk_find_toolpaths_by_slot(1)
   CHECK(#found == 2, "every toolpath carrying the slot marker is returned")
   CHECK(found[1] == tps[1] and found[2] == tps[2],
         "all passes come back in list order (cut order)")
   local found2 = CO.sdk_find_toolpaths_by_slot(2)
   CHECK(#found2 == 1, "a single-pass chamfer returns one toolpath")
   CHECK(found2[1] == tps[3], "and it is the right one")
   local found3 = CO.sdk_find_toolpaths_by_slot(3)
   CHECK(#found3 == 0, "a nonexistent slot returns an empty array")
   ToolpathManager = function() error("no toolpath manager") end
   local found_err = CO.sdk_find_toolpaths_by_slot(1)
   CHECK(type(found_err) == "table" and #found_err == 0,
         "an SDK failure is an empty array, never a raise")
   ToolpathManager = SAVED_TPM
end

-- Write memory to every pass: all pass or all fail.
do
   local written = {}
   local tps = { { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(2),
                   Notes = "" },
                 { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(2) .. " pass 2",
                   Notes = "" } }
   ToolpathManager = function()
      return {
         GetHeadPosition = function() return 1 end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return tps[pos], (nxt <= #tps) and nxt or nil
         end,
      }
   end
   -- Mock sdk_write_memory to track calls
   local orig_write = CO.sdk_write_memory
   CO.sdk_write_memory = function(tp, mem)
      written[#written + 1] = { tp = tp, mem = mem }
      return true
   end
   local result = CO.sdk_write_memory_all(2, { size = 0.25 })
   CHECK(result == true, "write_memory_all returns true when all passes accept it")
   CHECK(#written == 2, "memory is written to every pass")
   CHECK(written[1].tp == tps[1] and written[2].tp == tps[2],
         "both passes are written in order")
   -- Restore and test failure case
   written = {}
   CO.sdk_write_memory = function(tp, mem)
      written[#written + 1] = { tp = tp, mem = mem }
      -- Reject the FIRST pass, not the last: rejecting the last one cannot tell
      -- a short-circuit from a full walk, since both stop at the same place.
      if tp == tps[1] then return false end
      return true
   end
   local result2 = CO.sdk_write_memory_all(2, { size = 0.25 })
   CHECK(result2 == false,
         "write_memory_all returns false when any pass rejects it")
   CHECK(#written == 2,
         "but all passes are still attempted (no short-circuit on failure)")
   -- Empty slot case
   local result3 = CO.sdk_write_memory_all(3, { size = 0.25 })
   CHECK(result3 == false, "write_memory_all returns false when no toolpaths exist")
   -- SDK failure case
   ToolpathManager = function() error("no toolpath manager") end
   local result4 = CO.sdk_write_memory_all(2, { size = 0.25 })
   CHECK(result4 == false, "write_memory_all returns false on SDK failure, never a raise")
   CO.sdk_write_memory = orig_write
   ToolpathManager = SAVED_TPM
end

-- The toolpath half of the same migration. An adopted chamfer's toolpath
-- carries the OLD marker, so rebuilding it has to delete that one or the job
-- ends up with two toolpaths for one chamfer. Off by default, for the same
-- reason the layer migration is.
do
   local deleted = {}
   local tps = {
      { Name = "Chamfer 0.04 in [ChamferOffset 02]" },
      { Name = "Chamfer 0.04 in [ChamferOffset 03]" },
      { Name = "Chamfer 0.06 in " .. CO.toolpath_marker(2) },
      { Name = "my own profile" },
   }
   local function install()
      deleted = {}
      ToolpathManager = function()
         return {
            GetHeadPosition = function() return 1 end,
            GetNext = function(_, pos)
               local nxt = pos + 1
               return tps[pos], (nxt <= #tps) and nxt or nil
            end,
            DeleteToolpath = function(_, tp) deleted[#deleted + 1] = tp.Name end,
         }
      end
   end
   install()
   local n = CO.sdk_delete_marked_toolpaths(2)
   CHECK(n == 1 and deleted[1] == "Chamfer 0.06 in " .. CO.toolpath_marker(2),
         "by default an old-marker toolpath is left alone")
   install()
   n = CO.sdk_delete_marked_toolpaths(2, true)
   CHECK(n == 2, "migrating deletes both generations of this slot's toolpath")
   CHECK(#deleted == 2, "and nothing else")
   local names = deleted[1] .. "|" .. deleted[2]
   CHECK(names:find("[ChamferOffset 02]", 1, true) ~= nil,
         "the adopted toolpath is one of them")
   CHECK(names:find("[ChamferOffset 03]", 1, true) == nil,
         "another chamfer's adopted toolpath survives")
   ToolpathManager = SAVED_TPM
end

-- CO.sdk_leave_user_layer: a run must never finish with one of OUR layers active.
-- Aspire draws new work onto the active layer, and our layers are wiped every run,
-- so leaving Offset NN active silently destroys whatever the user draws next
-- (live-hit 2026-07-27, three times: a square, then Convert Text to Curves output).
local function fake_layer_job(layer_names)
   local layers = {}
   for _, n in ipairs(layer_names) do layers[#layers + 1] = { Name = n } end
   local lm = fake_list(layers)
   lm.activated = nil
   lm.SetActiveLayer = function(_, layer) lm.activated = layer.Name end
   return { LayerManager = lm }, lm
end

do
   local job, lm = fake_layer_job({ "Layer 1", CO.offset_layer_name(1) })
   CHECK(CO.sdk_leave_user_layer(job) == true, "leaving a user layer active succeeds")
   CHECK(lm.activated == "Layer 1", "the user's layer is the one activated")
end

do
   -- Ours FIRST in the list: the walk must skip it, not just take the head.
   local job, lm = fake_layer_job({ CO.offset_layer_name(3), CO.offset_layer_name(1), "Art" })
   CO.sdk_leave_user_layer(job)
   CHECK(lm.activated == "Art", "our own offset layers are skipped over")
end

do
   local job, lm = fake_layer_job({ CO.LEGACY_OFFSET_LAYER, "Layer 1" })
   CO.sdk_leave_user_layer(job)
   CHECK(lm.activated == "Layer 1", "the pre-1.4.0 offset layer is not a user layer either")
end

do
   -- Nothing but our layers: fail soft, leave the job alone rather than error.
   local job, lm = fake_layer_job({ CO.offset_layer_name(1) })
   CHECK(CO.sdk_leave_user_layer(job) == true, "a job with no user layer still succeeds")
   CHECK(lm.activated == nil, "and activates nothing")
end

do
   local job, lm = fake_layer_job({})
   CHECK(CO.sdk_leave_user_layer(job) == true, "an empty layer list succeeds")
   CHECK(lm.activated == nil, "and activates nothing")
end

-- Which layers a rebuild sweeps away. Pure, so it can be checked without a job.
-- The dangerous direction is FALSE NEGATIVES: a surplus band left on the canvas
-- is orange geometry that is no longer cut and is indistinguishable by eye from
-- geometry that is.
CHECK(CO.doomed_layer("EdgeBreaker Offset 03-4", 3, 2, false) == true,
      "a band past the new pass count goes")
CHECK(CO.doomed_layer("EdgeBreaker Offset 03-2", 3, 2, false) == false,
      "a band the new run still needs stays (it is wiped, not deleted)")
CHECK(CO.doomed_layer("EdgeBreaker Offset 04-4", 3, 2, false) == false,
      "another chamfer's surplus band is never touched")
CHECK(CO.doomed_layer("EdgeBreaker - Offset 03", 3, 2, false) == true,
      "this slot's v1.12.0 layer always goes")
CHECK(CO.doomed_layer("EdgeBreaker - Offset 04", 3, 2, false) == false,
      "another slot's v1.12.0 layer is never touched")
CHECK(CO.doomed_layer("ChamferOffset - Offset 03", 3, 2, true) == true,
      "the v1.4.x layer goes when adopting")
CHECK(CO.doomed_layer("ChamferOffset - Offset 03", 3, 2, false) == false,
      "and is left alone when not adopting")
CHECK(CO.doomed_layer("ChamferOffset - Offset", 3, 2, true) == false,
      "the pre-1.4.0 unnumbered layer is never deleted")
CHECK(CO.doomed_layer("Tim's vectors", 3, 2, true) == false, "user layers are never touched")
CHECK(CO.doomed_layer(nil, 3, 2, true) == false, "an unreadable name is never deleted")

-- CO.sdk_offset_group (v1.13.1): the same tri-state contract as
-- sdk_offset_loop, on a group that is ALREADY a detached copy. It must not
-- touch the selection and must not copy -- the whole point is that the caller
-- hands it the finishing pass's group and gets a backed-off sibling.
do
   -- A fake ContourGroup whose :Offset returns whatever the test dictates.
   local function fake_group(result)
      return { Offset = function(self, d, ad, mode, keep) return result end }
   end

   local g, err = CO.sdk_offset_group(fake_group({ Count = 3 }), -0.05)
   CHECK(type(g) == "table" and g.Count == 3, "sdk_offset_group returns the offset group")
   CHECK(err == nil, "and no error alongside it")

   local g2, err2 = CO.sdk_offset_group(fake_group(nil), -0.05)
   CHECK(g2 == nil and err2 == nil, "a nil Offset result is the bare-nil 'too narrow' answer")

   local g3, err3 = CO.sdk_offset_group(fake_group({ Count = 0 }), -0.05)
   CHECK(g3 == nil and err3 == nil, "an empty result is 'too narrow', not a failure")

   local g4, err4 = CO.sdk_offset_group(fake_group({ Count = "?" }), -0.05)
   CHECK(g4 == nil and type(err4) == "string",
         "an unreadable Count is a FAILURE, not a silent skip")

   -- A throw inside Aspire must come back as nil+message, never propagate.
   local thrower = { Offset = function() error("luabind: no overload") end }
   local g5, err5 = CO.sdk_offset_group(thrower, -0.05)
   CHECK(g5 == nil and type(err5) == "string" and err5:find("overload") ~= nil,
         "a thrown Offset is caught and reported")

   -- The magnitude argument is always positive even when the distance is not:
   -- relief passes on an outward loop offset by a NEGATIVE distance.
   local seen
   local spy = { Offset = function(self, d, ad, mode, keep)
      seen = { d = d, ad = ad, mode = mode, keep = keep }
      return { Count = 1 }
   end }
   CO.sdk_offset_group(spy, -0.09225)
   NEAR(seen.d, -0.09225, 1e-9, "the signed distance is passed through")
   NEAR(seen.ad, 0.09225, 1e-9, "the magnitude argument is its absolute value")
   CHECK(seen.mode == 1 and seen.keep == true, "the 4-arg Offset form is used")
end

-- CO.sdk_erode_count: shrink the whole selection by one signed distance and
-- count what comes back (narrow-break guard spec 4a). Same tri-state contract
-- as sdk_offset_loop, with one difference that matters: ZERO is an answer, not
-- a failure - it means the chamfer ate everything.
do
   local FAKE_A, FAKE_B = {}, {}

   local function job_with(sel_count)
      return { Selection = { Count = sel_count, Clear = function() end, Add = function() end } }
   end

   -- last_offset is the SHRINK; last_back is the GROW-BACK, which only happens
   -- when a back distance is handed in. The offset result carries its own
   -- :Offset so the chain can be exercised -- that chaining is the opening.
   local last_offset, last_back
   local function install(result, back_result)
      last_offset, last_back = nil, nil
      CreateCopyOfSelectedContours = function()
         if result == "nocopy" then return nil end
         return {
            Offset = function(self, dist, absdist, mode, preserve)
               last_offset = { dist = dist, absdist = absdist, mode = mode, preserve = preserve }
               if result == "raise" then error("boom") end
               if type(result) ~= "table" then return result end
               return {
                  Count = result.Count,
                  Offset = function(_, d2, a2, m2, p2)
                     last_back = { dist = d2, absdist = a2, mode = m2, preserve = p2 }
                     if back_result == "raise" then error("boom on the way back") end
                     return back_result
                  end,
               }
            end,
         }
      end
   end

   install({ Count = 2 })
   local n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == 2 and e == nil, "sdk_erode_count: a readable Count comes straight back")
   CHECK(last_offset ~= nil and last_offset.dist == -0.2 and last_offset.absdist == 0.2,
         "sdk_erode_count: signed distance, magnitude as the limit")
   CHECK(last_offset ~= nil and last_offset.mode == 1 and last_offset.preserve == true,
         "sdk_erode_count: same four-argument Offset the rest of the file uses")

   install({ Count = 0 })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == 0 and e == nil, "sdk_erode_count: zero is an ANSWER - everything vanished")

   install(nil)
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == 0 and e == nil, "sdk_erode_count: a nil group reads as zero, same meaning")

   install({ Count = "lots" })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == nil and type(e) == "string",
         "sdk_erode_count: an unreadable Count is a failure, never zero")

   install("nocopy")
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == nil and type(e) == "string", "sdk_erode_count: no copy is a failure")
   -- N9, measured at the machine (session 088): a GROUPED selection lands on
   -- exactly this branch, and it named no remedy -- a dead end, while the two
   -- branches either side of it already said "ungroup and retry". Pinned the
   -- same way sdk_offset_loop's is, because the words ARE the fix here.
   CHECK(e:find("ungroup", 1, true) ~= nil,
         "sdk_erode_count: no copy tells the user how to fix it (ungroup and retry)")

   install("raise")
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == nil and type(e) == "string", "sdk_erode_count: a thrown error is caught and named")

   -- The selection has to hold everything handed in, or the count compares a
   -- number of loops against an offset of some other set of loops.
   install({ Count = 2 })
   n, e = CO.sdk_erode_count(job_with(1), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == nil and type(e) == "string",
         "sdk_erode_count: a short selection is a failure, not a result")

   -- THE OPENING (2026-08-05, measured on the word EDGEBREAKER and on a welded
   -- dumbbell). Shrink by W, then grow the RESULT back by W, and count THAT.
   -- What survives is the material a disc of width W can reach, so a sharp
   -- inside corner that merely washed out comes back joined while a neck too
   -- thin to hold the disc stays severed. The grow-back distance is optional:
   -- without it this is the plain shrink it always was.
   install({ Count = 5 }, { Count = 1 })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2, 0.2)
   CHECK(n == 1 and e == nil,
         "sdk_erode_count: the OPENED count is the answer, not the shrunken one")
   CHECK(last_back ~= nil and last_back.dist == 0.2 and last_back.absdist == 0.2,
         "sdk_erode_count: the grow-back runs at the distance it is handed")
   CHECK(last_back ~= nil and last_back.mode == 1 and last_back.preserve == true,
         "sdk_erode_count: the grow-back uses the same four-argument Offset form")

   install({ Count = 5 }, { Count = 1 })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2)
   CHECK(n == 5 and e == nil and last_back == nil,
         "sdk_erode_count: no grow-back distance, no second offset - the old contract stands")

   install({ Count = 5 }, nil)
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2, 0.2)
   CHECK(n == 0 and e == nil,
         "sdk_erode_count: nothing survives the round trip - zero is still an ANSWER")

   install(nil, { Count = 3 })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2, 0.2)
   CHECK(n == 0 and e == nil and last_back == nil,
         "sdk_erode_count: a region eaten away is never grown back")

   install({ Count = 5 }, "raise")
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2, 0.2)
   CHECK(n == nil and type(e) == "string",
         "sdk_erode_count: a throw on the way back is caught and named")

   install({ Count = 5 }, { Count = "lots" })
   n, e = CO.sdk_erode_count(job_with(2), { FAKE_A, FAKE_B }, -0.2, 0.2)
   CHECK(n == nil and type(e) == "string",
         "sdk_erode_count: an unreadable opened Count is a failure, never zero")

   CreateCopyOfSelectedContours = SAVED_CREATE_COPY
end

-- CO.sdk_selection_spans tags every loop with the layer it came from, so the
-- own-offsets guard can drop the gadget's own output by MEMBERSHIP instead of
-- by geometry. A coincident copy and its original have the same bounding box
-- and always will -- Aspire's chamfer engine has to cut the operator's own
-- edge -- so the layer is the only thing that separates them.
do
   -- A square, as four line spans: enough for contour_spans to produce a loop.
   local function square_contour()
      local function pt(x, y) return { x = x, y = y } end
      local corners = { pt(0, 0), pt(1, 0), pt(1, 1), pt(0, 1) }
      local spans = {}
      for i = 1, 4 do
         local s, e = corners[i], corners[i % 4 + 1]
         spans[i] = { Type = 1, StartPoint2D = s, EndPoint2D = e }
      end
      return { IsEmpty = false, IsOpen = false,
               GetHeadPosition = function() return 1 end,
               GetNext = function(_, pos)
                  local nxt = pos + 1
                  return spans[pos], (nxt <= #spans) and nxt or nil
               end }
   end
   -- GUID-shaped, because that is what Aspire returns. USER is the operator's
   -- layer, OURS one of the gadget's, THIRD a second, unrelated ordinary
   -- layer -- used to prove a plain group does NOT stamp its own id onto a
   -- child that sits on a different layer (see the "ordinary group" check
   -- below; USER and OURS alone can't distinguish real inheritance from a
   -- same-value coincidence).
   local USER = "484e94a6-a0a9-4984-8da5-2aeb9e8d9f7a"
   local OURS = "17f31c3e-499d-4e70-98fd-98df4a7eea99"
   local THIRD = "9c6e2b1a-0f3d-4a12-b6e5-2d7c8a1f4e33"

   local function contour_obj(layerid)
      return { ClassName = "vcCadContour", LayerId = layerid,
               GetContour = square_contour,
               GetBoundingBox = function()
                  return { IsInvalid = false, Centre = { x = 0.5, y = 0.5 },
                           XLength = 1, YLength = 1 }
               end }
   end
   local function group_obj(layerid, children)
      return { ClassName = "vcCadObjectGroup", LayerId = layerid,
               GetBoundingBox = function()
                  return { IsInvalid = false, Centre = { x = 0.5, y = 0.5 },
                           XLength = 1, YLength = 1 }
               end,
               GetHeadPosition = function() return #children > 0 and 1 or nil end,
               GetNext = function(_, pos)
                  local nxt = pos + 1
                  return children[pos], (nxt <= #children) and nxt or nil
               end }
   end
   local function job_of(objs)
      return { Selection = {
         GetHeadPosition = function() return #objs > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return objs[pos], (nxt <= #objs) and nxt or nil
         end,
      } }
   end

   local loops = CO.sdk_selection_spans(job_of({ contour_obj(USER) }), {})
   CHECK(#loops == 1 and loops[1].layer_id == USER,
         "selection spans: a loop carries the layer it is on")

   -- An object whose LayerId throws (an unregistered member on some other
   -- Aspire build) leaves the field nil, which partition_loops counts as
   -- unknown and main() refuses on. Never silently kept or dropped.
   local mystery = setmetatable(
      { ClassName = "vcCadContour", GetContour = square_contour,
        GetBoundingBox = function()
           return { IsInvalid = false, Centre = { x = 0.5, y = 0.5 },
                    XLength = 1, YLength = 1 }
        end },
      { __index = function(_, k)
         if k == "LayerId" then error("no such member") end
      end })
   local m_loops = CO.sdk_selection_spans(job_of({ mystery }), {})
   CHECK(#m_loops == 1 and m_loops[1].layer_id == nil,
         "selection spans: an unreadable layer id stays nil, for the caller to refuse")

   -- Groups. Whether a child reports its own layer or its parent's is a probe
   -- question (Q7) with two survivable answers, so the recursion carries the
   -- enclosing group's layer down: a child of a group that sits on OUR layer
   -- is ours whatever the child itself reports.
   local child_says_own = contour_obj(USER)
   local g_loops = CO.sdk_selection_spans(
      job_of({ group_obj(OURS, { child_says_own }) }), { [OURS] = true })
   CHECK(#g_loops == 1 and g_loops[1].layer_id == OURS,
         "selection spans: a child of a group on OUR layer inherits the group's id")

   -- The group sits on a DIFFERENT layer (THIRD) from its child (USER), and
   -- own_ids is empty, so the group is not ours. Only a fixture shaped this
   -- way can catch a regression that stamps a group's id onto its children
   -- unconditionally -- USER == USER on both sides would pass either way.
   local plain_group = CO.sdk_selection_spans(
      job_of({ group_obj(THIRD, { contour_obj(USER) }) }), {})
   CHECK(#plain_group == 1 and plain_group[1].layer_id == USER,
         "selection spans: a child of an ordinary group keeps its own id")

   -- Anything that is not a contour, a polyline or a group is COUNTED on its
   -- way out, so main() can tell "you selected text" apart from "you selected
   -- nothing" -- the two produced the same unhelpful refusal until 2026-08-13.
   -- No GetContour at all, because a live text object has none: the class check
   -- has to return before anything asks it for geometry.
   local function alien_obj(cls)
      return { ClassName = cls, LayerId = USER,
               GetBoundingBox = function()
                  return { IsInvalid = false, Centre = { x = 0.5, y = 0.5 },
                           XLength = 1, YLength = 1 }
               end }
   end

   local t_loops, t_open, t_other =
      CO.sdk_selection_spans(job_of({ alien_obj("vcCadText") }), {})
   CHECK(#t_loops == 0 and t_open == 0 and t_other == 1,
         "selection spans: a non-vector object is counted, not silently dropped")

   -- Inside a group as well -- text is commonly grouped with its own shapes.
   local gt_loops, _, gt_other = CO.sdk_selection_spans(
      job_of({ group_obj(THIRD, { alien_obj("vcCadText") }) }), {})
   CHECK(#gt_loops == 0 and gt_other == 1,
         "selection spans: a non-vector inside a group is counted too")

   -- A mixed selection still runs. The count is for the message, never a veto:
   -- one stray text object must not refuse a chamfer on real shapes.
   local mx_loops, _, mx_other = CO.sdk_selection_spans(
      job_of({ contour_obj(USER), alien_obj("vcCadBitmap") }), {})
   CHECK(#mx_loops == 1 and mx_other == 1,
         "selection spans: a non-vector alongside real shapes is counted but not fatal")

   -- The control. Without this the counter could be a constant 1 and every
   -- check above would still pass.
   local _, _, clean_other = CO.sdk_selection_spans(job_of({ contour_obj(USER) }), {})
   CHECK(clean_other == 0,
         "selection spans: an all-vector selection counts no aliens")
end

-- ============================================================
-- The preview decoy (live defect, 2026-08-06). Rebuilding a big-chamfer slot
-- from memory failed with "remembered shapes could not be read back", while
-- another chamfer in the same job recalled fine.
--
-- Cause, measured with LayerVisProbe round 6: Aspire keeps one preview object
-- per toolpath on a SYSTEM layer, 'Toolpath Previews'. On the aspire path the
-- drawn copy is COINCIDENT with the operator's vector, so that toolpath's
-- preview carries the operator's own bounding box exactly -- and Aspire lists
-- the system layer FIRST. The search takes the first match and stops, so it
-- picked a vcCadToolpathPreview, which yields no contour, and the real vector
-- was never reached. The bands path never collided because its offsets are
-- displaced, so its previews sit at a different size.
--
-- Two rules, and the second is why this is not a one-line patch: the operator's
-- shapes are never on a system layer, AND nothing that could not have been
-- INPUT may hold a fingerprint. A decoy does not merely miss -- it SHADOWS,
-- permanently, because first match wins.
do
   local function obj(cls, cx, cy, xlen, ylen)
      return {
         ClassName = cls,
         GetBoundingBox = function()
            return { IsInvalid = false, Centre = { x = cx, y = cy },
                     XLength = xlen, YLength = ylen }
         end,
      }
   end
   local function layer_of(name, system, objs)
      return {
         Name = name, IsSystemLayer = system, objs = objs,
         GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end,
         GetNext = function(self, pos)
            local nxt = pos + 1
            return self.objs[pos], (nxt <= #self.objs) and nxt or nil
         end,
      }
   end
   local function job_of(layers)
      return { LayerManager = {
         GetHeadPosition = function() return #layers > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return layers[pos], (nxt <= #layers) and nxt or nil
         end,
      } }
   end

   local WANT = { cx = 0, cy = 0.126645, xlen = 8.272385, ylen = 8.146709 }
   local star = obj("vcCadContour", 0, 0.126645, 8.272385, 8.146709)
   local preview = obj("vcCadToolpathPreview", 0, 0.126645, 8.272385, 8.146709)

   -- The job as measured: previews first, the operator's layer second.
   local res = CO.sdk_find_objects_by_fps(
      job_of({ layer_of("Toolpath Previews", true, { preview }),
               layer_of("Layer 1", false, { star }) }), { WANT }, 1e-6)
   CHECK(res.found == 1, "find by fps: the remembered shape is still found")
   CHECK(res.objs[1] == star,
         "find by fps: a toolpath preview sharing the bbox does not shadow the vector")

   -- The class rule on its own, with no system layer involved: an unreadable
   -- object on an ordinary layer must not hold the fingerprint either.
   local res2 = CO.sdk_find_objects_by_fps(
      job_of({ layer_of("Layer 1", false, { preview, star }) }), { WANT }, 1e-6)
   CHECK(res2.objs[1] == star,
         "find by fps: an object that could never be input never holds a fingerprint")

   -- A GROUP still matches: a remembered shape can live inside one, and the
   -- selection reader recurses into it. Excluding groups would break that.
   local grp = obj("vcCadObjectGroup", 0, 0.126645, 8.272385, 8.146709)
   grp.GetHeadPosition = function() return nil end
   local res3 = CO.sdk_find_objects_by_fps(
      job_of({ layer_of("Layer 1", false, { grp }) }), { WANT }, 1e-6)
   CHECK(res3.objs[1] == grp, "find by fps: a group can still hold a fingerprint")

   -- The system-layer rule ON ITS OWN. The class rule already keeps a preview
   -- out, so the measured job cannot tell the two apart -- and a rule no test
   -- can fail is this project's oldest recurring defect. This fixture puts a
   -- READABLE contour on a system layer, which is not something Aspire has been
   -- seen doing: it pins the invariant we are choosing, that a system layer is
   -- Aspire's and is never searched, whatever happens to be sitting on it.
   local sys_contour = obj("vcCadContour", 0, 0.126645, 8.272385, 8.146709)
   local res_sys = CO.sdk_find_objects_by_fps(
      job_of({ layer_of("Toolpath Previews", true, { sys_contour }),
               layer_of("Layer 1", false, { star }) }), { WANT }, 1e-6)
   CHECK(res_sys.objs[1] == star, "find by fps: a system layer is never searched")

   -- A copy GROUPED onto the operator's layer (S6c, measured 2026-08-06).
   -- Skipping our LAYERS only reaches what those layers' walks reach, and this
   -- copy is reached through Layer 1 -- while still reporting our layer as its
   -- own, because a group's child reports its own layer, not its parent's. It
   -- shares the original's bounding box exactly, so without the object-level
   -- test whichever is enumerated first wins. Here the copy is enumerated
   -- first, deliberately: in the live job the operator's vector happened to
   -- come first, which is ordering luck, not a rule.
   local OURS_ID, USER_ID = "ours-guid", "user-guid"
   local copy = obj("vcCadContour", 0, 0.126645, 8.272385, 8.146709)
   copy.LayerId = OURS_ID
   local orig = obj("vcCadContour", 0, 0.126645, 8.272385, 8.146709)
   orig.LayerId = USER_ID
   local user_layer = layer_of("Layer 1", false, { copy, orig })
   user_layer.Id = USER_ID
   local our_layer = layer_of(CO.offset_layer_name(1, 1), false, {})
   our_layer.Id = OURS_ID
   local res_grp = CO.sdk_find_objects_by_fps(
      job_of({ user_layer, our_layer }), { WANT }, 1e-6)
   CHECK(res_grp.objs[1] == orig,
         "find by fps: a copy grouped onto the operator's layer is still ours")

   -- Unreadable ids must not start dropping the operator's own shapes: an empty
   -- id set has to leave the search exactly as it was.
   local plain = obj("vcCadContour", 0, 0.126645, 8.272385, 8.146709)
   local no_ids = layer_of("Layer 1", false, { plain })
   local res_noid = CO.sdk_find_objects_by_fps(
      job_of({ no_ids }), { WANT }, 1e-6)
   CHECK(res_noid.objs[1] == plain,
         "find by fps: no readable layer ids leaves the search untouched")

   -- Fail closed on an unreadable IsSystemLayer: the class rule still has to
   -- keep the preview out, or an SDK that does not register it puts the defect
   -- straight back.
   local odd = layer_of("Toolpath Previews", nil, { preview })
   local res4 = CO.sdk_find_objects_by_fps(
      job_of({ odd, layer_of("Layer 1", false, { star }) }), { WANT }, 1e-6)
   CHECK(res4.objs[1] == star,
         "find by fps: the class rule holds even if IsSystemLayer cannot be read")
end

-- v1.15.0: the offset layer's colour depends on which engine is cutting.
--
-- On the BANDS path the offsets ARE the product -- displaced into the waste,
-- the line the tool follows, worth eyeing before a cut. That is why they are
-- orange, and why orange rather than magenta (Vectric's own selection
-- highlight). Nothing about that has changed.
--
-- On the ASPIRE path they are an exact clone lying ON the operator's own
-- vector, because Aspire's chamfer engine cuts the operator's own edge. There
-- is nothing to eye -- Tim, asked directly, does not ever need to look at one
-- -- and orange means the operator sees OUR line where THEIR line is. Black
-- makes the picture the truth: one line, where there is functionally one line.
--
-- The fall-through is ORANGE, which is released behaviour: an unrecognised
-- strategy must not silently repaint a bands job.
do
   CHECK(CO.OFFSET_COLOUR_BANDS == 0x008CFF,
         "the bands colour is still the orange v1.3.1 chose")
   CHECK(CO.OFFSET_COLOUR_ASPIRE == 0x000000,
         "the aspire colour is black")
   CHECK(CO.offset_layer_colour("bands") == CO.OFFSET_COLOUR_BANDS,
         "a bands run paints its offsets orange")
   CHECK(CO.offset_layer_colour("aspire") == CO.OFFSET_COLOUR_ASPIRE,
         "an aspire run paints its coincident copies black")
   CHECK(CO.offset_layer_colour(nil) == CO.OFFSET_COLOUR_BANDS,
         "no strategy at all falls through to orange, i.e. released behaviour")
   CHECK(CO.offset_layer_colour("something else") == CO.OFFSET_COLOUR_BANDS,
         "an unrecognised strategy falls through to orange, never to black")
end

-- v1.15.0: prepare unlocks and paints.
--
-- UNLOCK: main() locks these layers on the way out of every run, and they
-- survive save/close/reopen locked (measured 2026-08-07). So a rebuild always
-- arrives at a LOCKED layer and has to take the lock off before it can wipe and
-- draw. Doing it here, unconditionally, is what makes "can a locked layer be
-- emptied?" a question nobody has to answer.
--
-- PAINT: the fifth argument is the strategy, appended rather than inserted so
-- that every pre-existing caller keeps working and lands on orange.
do
   local function spy_layer()
      local L = { colours = {}, objs = {} }
      L.GetHeadPosition = function() return nil end
      L.GetNext         = function() return nil, nil end
      L.RemoveObject    = function() end
      L.SetColour       = function(_, c) L.colours[#L.colours + 1] = c end
      return L
   end
   local function job_with(L)
      return { LayerManager = {
         GetHeadPosition  = function() return nil end,
         GetLayerWithName = function() return L end,
      } }
   end

   local La = spy_layer()
   La.Locked = true                                   -- as a rebuild finds it
   CO.sdk_prepare_layers(job_with(La), 1, 1, false, "aspire")
   CHECK(La.Locked == false,
         "prepare takes the lock OFF, so the wipe and the drawing run unlocked")
   CHECK(#La.colours == 1 and La.colours[1] == CO.OFFSET_COLOUR_ASPIRE,
         "an aspire run paints its layer black, exactly once")

   local Lb = spy_layer()
   Lb.Locked = true
   CO.sdk_prepare_layers(job_with(Lb), 1, 1, false, "bands")
   CHECK(Lb.Locked == false, "a bands run unlocks too - one rule, both paths")
   CHECK(#Lb.colours == 1 and Lb.colours[1] == CO.OFFSET_COLOUR_BANDS,
         "a bands run still paints its offsets orange")

   -- A caller that passes no strategy at all gets released behaviour.
   local Lc = spy_layer()
   CO.sdk_prepare_layers(job_with(Lc), 1, 1, false)
   CHECK(#Lc.colours == 1 and Lc.colours[1] == CO.OFFSET_COLOUR_BANDS,
         "no strategy argument still paints orange")

   -- A layer that THROWS on the lock write must not take the run down with it.
   -- Failure here is silent and safe: the worst case is a layer left as it was
   -- found, which is today's behaviour.
   local Ld = spy_layer()
   setmetatable(Ld, { __newindex = function(_, k)
      if k == "Locked" then error("no such member") end
   end })
   local okd = pcall(CO.sdk_prepare_layers, job_with(Ld), 1, 1, false, "bands")
   CHECK(okd == true, "a throwing lock write does not abort the run")
end

-- v1.15.0: the unlock has to come BEFORE the wipe, and this is the check that
-- can tell the difference.
--
-- The spies above cannot. Their GetHeadPosition returns nil, so RemoveObject
-- never runs at all, and a check whose message says "so the wipe and the
-- drawing run unlocked" passes with the write in either position -- which is
-- exactly what let the write sit AFTER the wipe through a whole build with the
-- suite green. A pin that cannot fail is not a pin.
--
-- So: a spy that HOLDS an object, and whose RemoveObject records layer.Locked
-- at the moment it is called. It must already be false. If the unlock drifts
-- back below the wipe, every rebuild after the first calls RemoveObject on a
-- locked layer -- which either throws (RemoveObject is not pcall'd, so the
-- rebuild dies) or silently no-ops (the previous run's copies stay, and the
-- layer-restricted toolpath cuts them alongside the current ones). Neither is
-- visible from anywhere else offline.
do
   local function watching_layer(n_objs)
      local L = { seen = {}, objs = {} }
      for i = 1, n_objs do L.objs[i] = "obj-" .. i end
      L.GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end
      L.GetNext = function(self, pos)
         local nxt = pos + 1
         return self.objs[pos], (nxt <= #self.objs) and nxt or nil
      end
      L.RemoveObject = function(self, _)
         -- The value AT THE MOMENT OF THE CALL, not at the end of the run.
         self.seen[#self.seen + 1] = self.Locked
      end
      L.SetColour = function() end
      return L
   end

   -- The per-band loop.
   local Lp = watching_layer(2)
   Lp.Locked = true                                   -- as a rebuild finds it
   CO.sdk_prepare_layers({ LayerManager = {
      GetHeadPosition  = function() return nil end,
      GetLayerWithName = function() return Lp end,
   } }, 1, 1, false, "aspire")
   CHECK(#Lp.seen == 2,
         "the band layer's stale objects were actually removed (got "
         .. #Lp.seen .. " of 2)")
   CHECK(Lp.seen[1] == false and Lp.seen[2] == false,
         "the band layer was ALREADY UNLOCKED at every RemoveObject call")

   -- The doomed loop -- a band this rebuild no longer needs. It was locked by
   -- the run that created it and locked survives save/close/reopen, so it is
   -- found locked for exactly the same reason.
   local Ld2 = watching_layer(2)
   Ld2.Name   = CO.offset_layer_name(1, 2)            -- band 2, doomed at n = 1
   Ld2.Locked = true
   local fresh = watching_layer(0)
   local doomed_list = { Ld2 }
   local _, old_left = CO.sdk_prepare_layers({ LayerManager = {
      GetHeadPosition  = function() return 1 end,
      GetNext          = function(_, pos)
         local nxt = pos + 1
         return doomed_list[pos], (nxt <= #doomed_list) and nxt or nil
      end,
      GetLayerWithName = function() return fresh end,
      RemoveLayer      = function(_, layer) layer.removed = true end,
   } }, 1, 1, false, "bands")
   CHECK(#Ld2.seen == 2,
         "the doomed layer's objects were actually removed (got "
         .. #Ld2.seen .. " of 2)")
   CHECK(Ld2.seen[1] == false and Ld2.seen[2] == false,
         "the doomed layer was ALREADY UNLOCKED at every RemoveObject call")
   CHECK(Ld2.removed == true and old_left == false,
         "the emptied doomed layer is still removed and not reported as left")
end

-- main() has to hand prepare the strategy, or every aspire run paints orange
-- and the whole colour half is inert with the suite green.
do
   local f = assert(io.open("gadget/EdgeBreaker/EdgeBreaker.lua", "rb"))
   local src = f:read("*a"); f:close()
   CHECK(src:find("pcall(CO.sdk_prepare_layers, job, slot, n_passes, migrating, strategy)",
                  1, true) ~= nil,
         "main() passes the strategy through to prepare_layers")
end

-- ==================== Sweeping leftover offsets (2026-08-14) ====================
-- The sweep is destructive and aimed by slot, so the assertion that matters is
-- the negative one: a chamfer that still has its toolpath must come through
-- completely untouched, and so must the operator's own layers.
do
   -- Records the lock state at the moment each object is removed, which is the
   -- only way to catch an unlock that happens too late -- the same trap
   -- sdk_prepare_layers documents at length.
   local function spy_layer(name, objs)
      return {
         Name = name, objs = objs, Locked = true, wiped = 0,
         GetHeadPosition = function(self) return #self.objs > 0 and 1 or nil end,
         GetNext = function(self, pos)
            local nxt = pos + 1
            return self.objs[pos], (nxt <= #self.objs) and nxt or nil
         end,
         RemoveObject = function(self)
            self.wiped = self.wiped + 1
            self.locked_when_wiped = self.Locked
         end,
      }
   end
   local function job_of(layers, removable)
      return { LayerManager = {
         GetHeadPosition = function() return #layers > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return layers[pos], (nxt <= #layers) and nxt or nil
         end,
         RemoveLayer = function(_, layer)
            if not removable then error("this build has no RemoveLayer") end
            layer.removed = true
         end,
      } }
   end

   local dead1 = spy_layer(CO.offset_layer_name(3, 1), { "a", "b" })
   local dead2 = spy_layer(CO.offset_layer_name(3, 2), { "c" })
   local dead3 = spy_layer(CO.V112_LAYER_PREFIX .. "07", { "d" })
   local live  = spy_layer(CO.offset_layer_name(5, 1), { "e" })
   local mine  = spy_layer("Layer 1", { "f" })
   local job = job_of({ dead1, live, dead2, mine, dead3 }, true)

   local removed, stuck = CO.sdk_remove_leftovers(job, { 3, 7 })
   CHECK(removed == 3 and stuck == 0, "sweep: three layers removed, none stuck")
   CHECK(dead1.removed and dead2.removed and dead3.removed,
         "sweep: every band of a doomed chamfer goes, both name generations")
   CHECK(dead1.wiped == 2 and dead2.wiped == 1,
         "sweep: their vectors are removed first")
   CHECK(dead1.locked_when_wiped == false,
         "sweep: the lock comes OFF before the wipe, never after")
   CHECK(live.wiped == 0 and live.removed == nil and live.Locked == true,
         "sweep: a chamfer that still has its toolpath is not touched at all")
   CHECK(mine.wiped == 0 and mine.removed == nil and mine.Locked == true,
         "sweep: the operator's own layer is not touched at all")

   -- RemoveLayer is the one call here nobody has run in Aspire. If it refuses,
   -- the vectors are still gone and the run carries on -- and the count comes
   -- back so the operator can be told the truth rather than nothing.
   local s1 = spy_layer(CO.offset_layer_name(2, 1), { "a" })
   local rem2, stuck2 = CO.sdk_remove_leftovers(job_of({ s1 }, false), { 2 })
   CHECK(rem2 == 0 and stuck2 == 1, "sweep: a refused RemoveLayer is reported, not swallowed")
   CHECK(s1.wiped == 1, "sweep: and the wipe still stands")

   -- Nothing to do: no enumeration result may reach a doomed list, so no layer
   -- can be touched by an empty sweep.
   local s2 = spy_layer(CO.offset_layer_name(2, 1), { "a" })
   local rem3, stuck3 = CO.sdk_remove_leftovers(job_of({ s2 }, true), {})
   CHECK(rem3 == 0 and stuck3 == 0 and s2.wiped == 0,
         "sweep: an empty slot list touches nothing")

   -- A layer whose name cannot be read is skipped, not fatal: the sweep runs
   -- before the dialog and must never be the thing that stops a run.
   local bad = setmetatable({}, { __index = function(_, k)
      if k == "Name" then error("no such member") end
   end })
   local s3 = spy_layer(CO.offset_layer_name(2, 1), { "a" })
   local rem4 = CO.sdk_remove_leftovers(job_of({ bad, s3 }, true), { 2 })
   CHECK(rem4 == 1 and s3.removed == true,
         "sweep: an unreadable layer name is skipped and the rest still go")
end
