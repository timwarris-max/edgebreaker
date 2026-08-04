// Corner gate. Proves that EdgeBreaker's own pass arithmetic, nested, leaves
// nothing standing at a corner -- and that the model can still SEE a defect,
// which is the half a one-sided gate would quietly lose.
//
// What this does and does not prove:
//   this gate    the arithmetic is NESTABLE
//   a source pin the product NESTS (tests/test_release.lua)
//   the sitting  ASPIRE nests (ContourGroup:Offset behaves as deduced)
// All three, or none of them mean anything.
//
// Run from the repo root:  node tests/check-corners.js

const { spawnSync } = require('child_process');
const path = require('path');

const LUA = path.join(process.env.LOCALAPPDATA, 'Programs', 'Lua', 'bin', 'lua.exe');

let passed = 0;
const failures = [];

// Never through a shell: the pass table is JSON and PowerShell strips its
// quotes, which is a silent JSON.parse death rather than a clean error.
function passTable(mode, size, incl, dia, percent, side) {
   const r = spawnSync(LUA, ['tests/corner-passes.lua', mode, String(size),
                             String(incl), String(dia), String(percent), side],
                       { encoding: 'utf8' });
   if (r.status !== 0) {
      const stderr = (r.stderr || '').trim();
      const err = new Error(`corner-passes failed for ${size}/${incl}/${dia}/${side}: ${stderr}`);
      // corner-passes.lua signals a legitimate "the product refuses this
      // combination outright" with error("refused: " .. reason), so that
      // literal is how the caller tells a real refusal apart from a genuine
      // bug (nil dereference, typo) further down in CO.evaluate or
      // CO.pass_geometry -- which must never be swallowed as a skip, or a
      // regression there could narrow the sweep to nothing while the gate
      // still reports green.
      err.refused = stderr.includes('refused:');
      err.stderr = stderr;
      throw err;
   }
   return r.stdout.trim();
}

function verdict(json, betaDeg, feature, mode) {
   const r = spawnSync(process.execPath,
                       ['tests/corner-model.js', json, String(betaDeg), feature, '', mode],
                       { encoding: 'utf8' });
   if (r.status !== 0) {
      throw new Error(`corner-model failed: ${(r.stderr || '').trim()}`);
   }
   const line = (r.stdout || '').split(/\r?\n/)
      .find(l => /^(CLEAN|RIDGE|DETACHED)/.test(l));
   if (!line) throw new Error('corner-model printed no verdict line');
   return { kind: line.split(/\s+/)[0], line: line.trim() };
}

function check(cond, label) {
   if (cond) passed++;
   else failures.push(label);
}

// --- the model's own self-test -------------------------------------------
// Without this a model that always answered CLEAN would pass the sweep below
// and prove nothing at all. The number is the live failure, re-measured
// 2026-08-03: inside, W 0.12, 1/4in 90 deg bit, 40%, star tip at beta 24 deg.
{
   const j = passTable('setback', 0.12, 90, 0.25, 40, 'inside');
   const v = verdict(j, 24, 'tip', 'as-built');
   check(v.kind === 'RIDGE', `as-built must still be seen as RIDGE (got ${v.kind})`);
   const m = v.line.match(/stands ([0-9.]+) proud/);
   const h = m ? parseFloat(m[1]) : NaN;
   check(Math.abs(h - 0.0233) < 0.0002,
         `as-built ridge height 0.0233 (got ${h})`);
}
// The outside run recorded as "clean" at the sitting, which was defective at
// its VALLEYS. Pinned so nobody re-learns that lesson.
{
   const j = passTable('setback', 0.25, 90, 0.25, 40, 'outside');
   const v = verdict(j, 24, 'valley', 'as-built');
   check(v.kind === 'RIDGE', `as-built outside valley must be RIDGE (got ${v.kind})`);
   const t = verdict(j, 24, 'tip', 'as-built');
   check(t.kind === 'CLEAN', `as-built outside TIP was always clean (got ${t.kind})`);
}

// --- the sweep: nesting is clean everywhere ------------------------------
// Sides x features x bits x corner half-angles x sizes. The sizes are chosen
// to span the pass counts the product can produce on a 1/4in bit: 0.09 is one
// pass, 0.60 is near the MAX_PASSES ceiling.
//
// 0.90 IS DELIBERATELY PAST THE CEILING -- leave it in. A 1/4in bit cannot
// reach it in any number of passes, so all six of its combinations (2 sides x
// 3 bits) are refused by the product on every run. That is the only thing
// that drives a REAL refusal through the skip branch below, which is how the
// "refused:" literal in corner-passes.lua gets its round trip exercised. Take
// 0.90 out and the skip path goes untested again: the day that literal
// changes, every genuine refusal would start looking like a real failure and
// nothing here would have noticed.
const SIDES    = ['inside', 'outside'];
const FEATURES = ['tip', 'valley'];
const BITS     = [60, 90, 120];
const BETAS    = [15, 24, 45, 54, 75];
const SIZES    = [0.09, 0.12, 0.25, 0.40, 0.60, 0.90];
const PERCENT  = 40;

// What a whole sweep looks like, written out rather than derived from the
// lists above -- a number computed from the lists would shrink along with
// them and confirm whatever it was handed. 2 sides x 3 bits x 5 reachable
// sizes = 30 pass tables, each checked at 2 features x 5 half-angles = 300;
// the sixth size refuses on all 2 x 3 = 6.
const EXPECT_SWEPT   = 300;
const EXPECT_SKIPPED = 6;

let swept = 0, skipped = [];
for (const side of SIDES) {
   for (const incl of BITS) {
      for (const size of SIZES) {
         let j;
         try {
            j = passTable('setback', size, incl, 0.25, PERCENT, side);
         } catch (e) {
            if (e.refused) {
               // The product refuses some size/bit pairs outright (past
               // MAX_PASSES). A refusal is not a corner defect -- but say so
               // rather than let the sweep look wider than it is.
               skipped.push(`${side} ${incl}deg ${size}: refused by the product`);
               continue;
            }
            // Anything without the "refused:" literal is a real failure, not
            // a declined combination -- report it loudly and fail the gate,
            // rather than let it vanish into the skip list.
            failures.push(`corner-passes real failure for ${side} ${incl}deg ${size}: ${e.stderr}`);
            continue;
         }
         for (const feature of FEATURES) {
            for (const beta of BETAS) {
               const v = verdict(j, beta, feature, 'nest');
               swept++;
               check(v.kind === 'CLEAN',
                     `nest ${side} ${incl}deg W${size} ${feature} beta${beta}: ${v.line}`);
            }
         }
      }
   }
}

for (const s of skipped) console.log(`skipped: ${s}`);

// Count the sweep itself, or the gate can report green on a fraction of it.
// Proved, not supposed: dropping CO.MAX_PASSES 8 -> 4 in the product makes the
// 0.40 and 0.60 sizes refuse too -- 120 of the 300 checks quietly vanish --
// and before these two lines existed the headline still read "0 failed".
// Every skip is expected and named above, so any NEW one is a narrowed sweep.
check(skipped.length === EXPECT_SKIPPED,
      `exactly the ${EXPECT_SKIPPED} over-ceiling combinations are refused (got ${skipped.length})`);
check(swept === EXPECT_SWEPT,
      `the whole sweep ran: ${EXPECT_SWEPT} nested combinations (got ${swept})`);

console.log(`\n${swept} nested combinations swept, ${passed} checks passed, ` +
            `${failures.length} failed`);
if (failures.length) {
   for (const f of failures) console.log(`FAIL ${f}`);
   process.exit(1);
}
