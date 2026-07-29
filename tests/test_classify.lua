-- Selection classification -- the spec 2 decision table. The selection (bbox
-- fingerprints) plus the job's chamfer list decides what a run means: add a
-- new chamfer, rebuild the one that owns the selection, recall the newest
-- remembered one on an empty selection, or refuse. Pure halves only; the SDK
-- scan that builds the chamfer list is exercised in test_sdk_offset.lua.
local CO = EdgeBreaker

local fpA = { cx = 1, cy = 1, xlen = 2, ylen = 2 }
local fpB = { cx = 9, cy = 1, xlen = 2, ylen = 1 }
local fpC = { cx = 5, cy = 8, xlen = 3, ylen = 3 }
local ch = function(slot, mem_fps) return { slot = slot, origin = "new",
   memory = mem_fps and { fps = mem_fps, size = 0.02, mode = "setback",
                          side = "auto", percent = 80 } or nil } end
local EPS = 1e-6

-- row: all free -> add
local r = CO.classify_selection({fpA, fpB}, {}, 1, EPS)
CHECK(r.kind == "add" and r.slot == 1 and #r.free_idx == 2, "all free -> add next_slot")
-- row: all owned by one -> rebuild, selection wins (subset too)
r = CO.classify_selection({fpA}, { ch(2, {fpA, fpB}) }, 3, EPS)
CHECK(r.kind == "rebuild" and r.slot == 2, "subset of one owner -> rebuild it")
-- row: mix -> add, owned excluded
r = CO.classify_selection({fpA, fpC}, { ch(1, {fpA}) }, 2, EPS)
CHECK(r.kind == "add" and r.slot == 2 and #r.free_idx == 1
      and r.excluded[1].slot == 1 and r.excluded[1].count == 1, "mix -> add, exclude owned")
-- row: owned by 2+ chamfers, none free -> refuse
r = CO.classify_selection({fpA, fpB}, { ch(1, {fpA}), ch(2, {fpB}) }, 3, EPS)
CHECK(r.kind == "refuse_multi", "two owners, no free -> refuse")
-- row: empty selection, newest WITH memory recalled
r = CO.classify_selection({}, { ch(1, {fpA}), ch(2, {fpB}) }, 3, EPS)
CHECK(r.kind == "recall" and r.slot == 2, "empty -> recall newest with memory")
-- edge (spec 8): empty and newest has NO memory -> recall skips to one that has
r = CO.classify_selection({}, { ch(1, {fpA}), ch(2, nil) }, 3, EPS)
CHECK(r.kind == "recall" and r.slot == 1, "memory-less newest skipped for recall")
-- edge: empty, NO chamfer has memory -> refuse_empty
r = CO.classify_selection({}, { ch(2, nil) }, 3, EPS)
CHECK(r.kind == "refuse_empty", "empty + no memory anywhere -> refuse")
-- row: empty job entirely
r = CO.classify_selection({}, {}, 1, EPS)
CHECK(r.kind == "refuse_empty", "empty + no chamfers -> refuse")
-- relations for the dropdown
CHECK(CO.chamfer_relation({fpA}, ch(1, {fpA}), EPS) == "match", "relation match")
CHECK(CO.chamfer_relation({fpC}, ch(1, {fpA}), EPS) == "differs", "relation differs")
CHECK(CO.chamfer_relation({fpC}, ch(1, nil), EPS) == "nomem", "relation nomem")

-- ==================== scan merge (adoption clash rule) ====================
-- A slot can appear under BOTH name generations at once -- a v1.4.x chamfer
-- half-rebuilt by v1.5.0, or a hand-copied layer. The new-name entry wins the
-- slot and the old one is reported as legacy: adopting both would give one
-- chamfer two layers and two toolpaths under one number.
local merged, leg = CO.merge_scan({ [3] = { origin = "new" } },
                                  { [3] = true, [5] = true })
CHECK(merged[3].origin == "new" and leg == true, "clash: new wins, legacy flagged")
CHECK(merged[5].origin == "old", "old-only slot adopted")
-- No clash, no legacy note: adoption alone is not a problem worth reporting.
local m2, leg2 = CO.merge_scan({ [1] = { origin = "new" } }, { [2] = true })
CHECK(m2[1].origin == "new" and m2[2].origin == "old", "both generations kept")
CHECK(leg2 == false, "adoption without a clash raises no legacy note")

-- ============ highlighted toolpath as tie-breaker (spec 2a) ============
-- Highlighting a chamfer's toolpath and running the gadget means "modify that
-- one" -- but only when no shapes are selected. A stale highlight must never
-- silently re-aim a run that has a real selection.
local hint = 1
-- selection present: the hint is ignored entirely
r = CO.classify_selection({fpB}, { ch(1, {fpA}), ch(2, {fpB}) }, 3, EPS, hint)
CHECK(r.kind == "rebuild" and r.slot == 2, "selection outranks the highlighted toolpath")
r = CO.classify_selection({fpC}, { ch(1, {fpA}) }, 2, EPS, hint)
CHECK(r.kind == "add" and r.slot == 2, "free shapes still add, highlight ignored")
-- empty selection: the hint picks the chamfer, instead of "newest with memory"
r = CO.classify_selection({}, { ch(1, {fpA}), ch(2, {fpB}) }, 3, EPS, hint)
CHECK(r.kind == "recall" and r.slot == 1, "empty + highlight recalls the highlighted one")
-- a highlight naming no chamfer is ignored, not an error
r = CO.classify_selection({}, { ch(1, {fpA}), ch(2, {fpB}) }, 3, EPS, 9)
CHECK(r.kind == "recall" and r.slot == 2, "highlight of a non-chamfer falls back to newest")
-- highlighted chamfer has no memory: refuse and NAME it, rather than silently
-- rebuilding some other chamfer the user did not point at
r = CO.classify_selection({}, { ch(1, {fpA}), ch(2, nil) }, 3, EPS, 2)
CHECK(r.kind == "refuse_empty" and r.slot == 2, "memory-less highlight refuses, naming it")
