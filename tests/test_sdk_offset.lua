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
   local job = { LayerManager = { GetLayerWithName = function(_, name)
      asked[#asked + 1] = name; return layer
   end } }
   local got = CO.sdk_prepare_layer(job, 2)
   CHECK(asked[1] == CO.offset_layer_name(2), "prepare_layer asks for THIS slot's layer")
   CHECK(#wiped == 2, "prepare_layer still wipes the layer it prepared")
   CHECK(got == layer, "prepare_layer returns the layer")
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
   local got, old_left = CO.sdk_prepare_layer({ LayerManager = lm }, 2, true)
   CHECK(got == new_layer, "migration still returns the new layer to draw on")
   CHECK(new_layer.wiped == 1, "the new layer is wiped as always")
   CHECK(old2.wiped == 2, "the old layer's offsets are wiped too")
   CHECK(old2.removed == true, "the emptied old layer is removed")
   CHECK(old3.wiped == nil and old3.removed == nil,
         "another chamfer's old layer is left completely alone")
   CHECK(old_left == false, "a removed old layer is not reported as left behind")

   -- Not asked to migrate: the old layer must not be touched at all.
   local old2b = fake_layer({ "old-a" })
   local nl2, lm2 = fake_lm({ ["ChamferOffset - Offset 02"] = old2b }, true)
   CO.sdk_prepare_layer({ LayerManager = lm2 }, 2, false)
   CHECK(old2b.wiped == nil and old2b.removed == nil,
         "without the migrate flag the old layer is untouched")

   -- RemoveLayer is the one call here we have never run in Aspire. If it is
   -- absent the wipe still stands and the run continues -- an empty leftover
   -- layer is cosmetic, a failed run is not.
   local old2c = fake_layer({ "old-a" })
   local nl3, lm3 = fake_lm({ ["ChamferOffset - Offset 02"] = old2c }, false)
   local got3, left3 = CO.sdk_prepare_layer({ LayerManager = lm3 }, 2, true)
   CHECK(got3 == nl3, "a failed RemoveLayer still returns the new layer")
   CHECK(old2c.wiped == 1, "a failed RemoveLayer still leaves the old layer emptied")
   CHECK(left3 == true, "an old layer that could not be removed is reported")

   -- Nothing to migrate (the adopted chamfer was a toolpath with no layer).
   local nl4, lm4 = fake_lm({ ["Layer 1"] = fake_layer({}) }, true)
   local got4, left4 = CO.sdk_prepare_layer({ LayerManager = lm4 }, 2, true)
   CHECK(got4 == nl4 and left4 == false, "migrating with no old layer is a no-op")
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
