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

-- Box-selecting a whole job to build chamfer 3 sweeps in chamfers 1 and 2's
-- orange offsets. partition_loops drops them only if they were fingerprinted,
-- so this scan must cover EVERY chamfer layer -- not just the one being built,
-- or the gadget offsets its own offsets and cuts them.
do
   local function obj(id)
      return { ClassName = "vcCadContour",
               GetBoundingBox = function()
                  -- bbox_fingerprint reads Centre.x/y and XLength/YLength (not
                  -- Min/Max corners) -- match that shape so these come back
                  -- readable instead of tripping the unknown-count guard.
                  return { IsInvalid = false, Centre = { x = id, y = id }, XLength = 1, YLength = 1 }
               end }
   end
   local function layer_of(objs)
      return {
         GetHeadPosition = function() return #objs > 0 and 1 or nil end,
         GetNext = function(_, pos)
            local nxt = pos + 1
            return objs[pos], (nxt <= #objs) and nxt or nil
         end,
      }
   end
   local layers = {
      { Name = "Layer 1",                    objs = { obj(90) } },
      { Name = CO.offset_layer_name(1),      objs = { obj(1) } },
      { Name = CO.offset_layer_name(2),      objs = { obj(2), obj(3) } },
      { Name = CO.LEGACY_OFFSET_LAYER,       objs = { obj(4) } },
   }
   for _, L in ipairs(layers) do
      local inner = layer_of(L.objs)
      L.GetHeadPosition = inner.GetHeadPosition
      L.GetNext = inner.GetNext
   end
   local job = { LayerManager = {
      GetHeadPosition = function() return 1 end,
      GetNext = function(_, pos)
         local nxt = pos + 1
         return layers[pos], (nxt <= #layers) and nxt or nil
      end,
   } }
   local fps, unknown = CO.sdk_offset_layer_fingerprints(job)
   CHECK(#fps == 4, "every chamfer layer is fingerprinted, plus the legacy one")
   CHECK(unknown == 0, "readable bounding boxes are not counted as unknown")
end

do
   -- A layer whose name cannot be read might be one of ours. Fail closed:
   -- count it unknown so main() refuses rather than guessing.
   local job = { LayerManager = {
      GetHeadPosition = function() return 1 end,
      GetNext = function(_, pos)
         return setmetatable({}, { __index = function() error("no name") end }), nil
      end,
   } }
   local ok, fps, unknown = pcall(CO.sdk_offset_layer_fingerprints, job)
   CHECK(ok and unknown and unknown > 0,
         "an unreadable layer name counts as unknown, not as 'not ours'")
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
