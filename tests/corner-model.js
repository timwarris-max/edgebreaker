// Offline reproduction of the multi-pass corner hook.
//
// Models ONE corner of a shape as a wedge (two rays from a vertex, half-angle
// beta). A star tip and a star valley are the same wedge with the shape's
// inside and outside swapped, so this covers both.
//
// It takes the REAL pass table emitted by passes.lua (EdgeBreaker's own
// arithmetic) and works out what the V-bit actually leaves behind:
//
//   depth(p) = max over passes k of  Dk - distance(p, path_k) / tan(a)
//
// which is just "the cone the tool sweeps", and is exactly what Aspire's
// preview draws.
//
// The offset paths use the corner rules observed live on 2026-08-02:
//   offsetting AWAY from a convex corner rounds it (arc centred on the vertex)
//   offsetting INTO   a convex corner keeps it sharp (miter on the bisector)
//
// WIRED IN: tests/check-corners.js is the gate. It sweeps `nest` across sides,
// features, bits, corner angles and sizes, and pins `as-built` at the live
// failure's measured ridge height so a model that lost the ability to SEE a
// defect cannot pass. This file stays runnable by hand for diagnosis -- that is
// what it was built for -- and its PNG output is the fastest way to look at a
// corner that has gone wrong.
//
// Usage, from the repo root:
//   lua tests\corner-passes.lua setback 0.12 90 0.25 40 inside     > pass table
//   node tests\corner-model.js '<that json>' <beta_deg> <tip|valley> [out.png] [as-built|nest]

const fs = require('fs');
const zlib = require('zlib');

const [jsonArg, betaArg, featureArg, outArg, modeArg] = process.argv.slice(2);
// 'as-built' : every pass offsets the ORIGINAL loop (what v1.13.0 ships)
// 'nest'     : the relief passes offset the FINAL pass's loop instead, so their
//              corner arcs are centred on its miter and can never reach past it
const MODE = modeArg || 'as-built';
const P = JSON.parse(jsonArg);
const beta = (parseFloat(betaArg) * Math.PI) / 180;
const feature = featureArg || 'tip';
const tanA = P.tan_a;

const sinB = Math.sin(beta), cosB = Math.cos(beta);
const RAY = 4.0;          // how far to run the wedge legs, in inches
const ARC_SEGS = 480;

// --- the wedge -------------------------------------------------------------
// Narrow wedge N: apex at the origin, opening toward -y, half-angle beta.
// Its legs point along u+ and u-.
const uP = [sinB, -cosB], uM = [-sinB, -cosB];

// `dist` is EdgeBreaker's canvas convention: + grows the selected loop.
// Convert it to m = "offset measured from the narrow wedge, + = outside it".
function toWedgeOffset(dist) {
   return feature === 'tip' ? dist : -dist;
}

// Path of one pass, as line segments.
//   m       where the straight legs sit: perpendicular distance from the wall,
//           + = outside the narrow wedge
//   cy      y of the point the corner turns about (0 = the vertex itself)
// The legs are always at m. Only the corner treatment changes: a round join of
// whatever radius keeps it tangent to both legs, or -- when the turning point
// lies further out than the legs -- the sharp miter where they cross.
function pathSegments(m, cy) {
   cy = cy || 0;
   const segs = [];
   // distance from the turning point to each leg line
   const R = m - cy * sinB;
   if (R >= 0) {
      // round join, radius R, centred on (0, cy); the legs are tangent to it
      const c = [0, cy];
      const aP = [c[0] + R * cosB, c[1] + R * sinB];
      const aM = [c[0] - R * cosB, c[1] + R * sinB];
      segs.push([aP, [aP[0] + RAY * uP[0], aP[1] + RAY * uP[1]]]);
      segs.push([aM, [aM[0] + RAY * uM[0], aM[1] + RAY * uM[1]]]);
      const a0 = beta, a1 = Math.PI - beta;    // through +y, the outside
      let prev = null;
      for (let i = 0; i <= ARC_SEGS; i++) {
         const t = a0 + ((a1 - a0) * i) / ARC_SEGS;
         const pt = [c[0] + R * Math.cos(t), c[1] + R * Math.sin(t)];
         if (prev) segs.push([prev, pt]);
         prev = pt;
      }
   } else {
      // legs sit inside the turning point: they cross, giving a sharp miter
      const mit = [0, m / sinB];
      segs.push([mit, [mit[0] + RAY * uP[0], mit[1] + RAY * uP[1]]]);
      segs.push([mit, [mit[0] + RAY * uM[0], mit[1] + RAY * uM[1]]]);
   }
   return segs;
}

function distToSegs(x, y, segs) {
   let best = Infinity;
   for (let i = 0; i < segs.length; i++) {
      const s = segs[i], ax = s[0][0], ay = s[0][1], bx = s[1][0], by = s[1][1];
      const vx = bx - ax, vy = by - ay;
      const wx = x - ax, wy = y - ay;
      const vv = vx * vx + vy * vy;
      let t = vv > 0 ? (wx * vx + wy * vy) / vv : 0;
      if (t < 0) t = 0; else if (t > 1) t = 1;
      const dx = wx - t * vx, dy = wy - t * vy;
      const dd = dx * dx + dy * dy;
      if (dd < best) best = dd;
   }
   return Math.sqrt(best);
}

// Where the FINAL pass turns its corner. When it miters, that point sits out in
// the waste at m/sin(beta) -- and under 'nest' every relief pass turns about the
// same point, which is what offsetting them from the final pass's loop would do.
const mFinal = toWedgeOffset(P.passes[P.n - 1].dist);
const turnY = MODE === 'nest' && mFinal < 0 ? mFinal / sinB : 0;

const PASSES = P.passes.map((p) => {
   const m = toWedgeOffset(p.dist);
   const cy = p.k === P.n ? 0 : turnY;
   return { k: p.k, depth: p.depth, m, cy, segs: pathSegments(m, cy) };
});

function cutDepth(x, y) {
   let z = 0;
   for (let i = 0; i < PASSES.length; i++) {
      const p = PASSES[i];
      const v = p.depth - distToSegs(x, y, p.segs) / tanA;
      if (v > z) z = v;
   }
   return z;
}

// --- the bisector profile: the whole defect in one dimension ---------------
// t measured from the vertex along the bisector. Positive = away from the
// narrow wedge (into whatever lies on the wide side), negative = into it.
function bisector(t) {
   return [0, t];               // the bisector is the y axis; +t is +y
}

const REACH = Math.max(...P.passes.map((p) => p.depth)) * tanA
            + Math.max(...P.passes.map((p) => Math.abs(p.dist)));
const T0 = -(REACH * 1.6), T1 = REACH * 1.6;
const STEP = REACH / 800;

const prof = [];
for (let t = T0; t <= T1 + 1e-12; t += STEP) {
   const pt = bisector(t);
   prof.push({ t, z: cutDepth(pt[0], pt[1]) });
}

// A correct chamfer's floor rises steadily from its deepest point out to the
// surface. A ridge -- material standing proud between two deeper cuts -- is a
// local minimum of the cut depth with cut on both sides. That is the hook.
let deepestI = 0;
for (let i = 0; i < prof.length; i++) if (prof[i].z > prof[deepestI].z) deepestI = i;
// Scan the WHOLE profile, both sides of the deepest point: a ridge anywhere is
// a ridge. (Which side it lands on depends on the corner and the side of the
// run, so looking only outward misses half the cases.)
const ridges = [];
for (let i = 1; i < prof.length - 1; i++) {
   if (!(prof[i].z <= prof[i - 1].z && prof[i + 1].z > prof[i].z + 1e-9)) continue;
   let lo = i; while (lo > 0 && prof[lo - 1].z >= prof[lo].z) lo--;
   let hi = i; while (hi < prof.length - 1 && prof[hi + 1].z >= prof[hi].z) hi++;
   const left = prof[lo].z, right = prof[hi].z, floor = prof[i].z;
   const proud = Math.min(left, right) - floor;
   if (proud > 1e-6) {
      ridges.push({ at: prof[i].t, floor, left, leftAt: prof[lo].t,
                    right, rightAt: prof[hi].t, proud, detached: floor <= 1e-9 });
   }
}
const ridge = ridges[0] || null;

const f = (x) => x.toFixed(4);
console.log(`# ${P.side} ${P.size} ${P.mode}, ${P.n} pass(es), ${feature}, beta=${betaArg} deg [${MODE}]`);
console.log(`#   W=${f(P.W)} G=${f(P.g)} D=${f(P.d)} band=${f(P.band)}`);
PASSES.forEach((p) =>
   console.log(`#   pass ${p.k}: canvas dist ${f(P.passes[p.k - 1].dist)}`
      + ` -> legs at ${f(p.m)}, corner ${p.m - p.cy * sinB >= 0
            ? 'round r=' + f(p.m - p.cy * sinB) + ' about y=' + f(p.cy)
            : 'SHARP miter'}, depth ${f(p.depth)}`));
if (!ridges.length) {
   console.log('CLEAN     one unbroken cut, floor falling away from a single deepest point');
} else {
   ridges.forEach((rg) => console.log(
      `${rg.detached ? 'DETACHED' : 'RIDGE   '} at t=${f(rg.at)} floor ${f(rg.floor)}`
      + `  between ${f(rg.left)} deep at t=${f(rg.leftAt)} and ${f(rg.right)} deep at t=${f(rg.rightAt)}`
      + `  -> stands ${f(rg.proud)} proud`));
}

console.log('\n  t (from vertex)   cut depth');
for (let i = 0; i < prof.length; i += Math.ceil(prof.length / 34)) {
   const p = prof[i];
   const bar = '#'.repeat(Math.round((p.z / prof[deepestI].z) * 46));
   console.log(`  ${p.t >= 0 ? ' ' : ''}${f(p.t)}          ${f(p.z)}  ${bar}`);
}

// --- render ----------------------------------------------------------------
if (outArg) {
   const SIZE = 620;
   const span = REACH * 2.9;
   const sc = SIZE / span;
   const cx = 0, cy = -REACH * 0.35;
   const px = (i) => cx + (i - SIZE / 2) / sc;
   const py = (j) => cy - (j - SIZE / 2) / sc;

   const z = new Float64Array(SIZE * SIZE);
   for (let j = 0; j < SIZE; j++)
      for (let i = 0; i < SIZE; i++) z[j * SIZE + i] = cutDepth(px(i), py(j));

   // hillshade, light from the upper left, the way Aspire's preview lights it
   const raw = Buffer.alloc(SIZE * (SIZE + 1));
   const LX = -0.55, LY = 0.55, LZ = 0.63;
   const cell = 1 / sc;
   for (let j = 0; j < SIZE; j++) {
      raw[j * (SIZE + 1)] = 0;
      for (let i = 0; i < SIZE; i++) {
         const l = z[j * SIZE + Math.max(i - 1, 0)], r = z[j * SIZE + Math.min(i + 1, SIZE - 1)];
         const u = z[Math.max(j - 1, 0) * SIZE + i], d = z[Math.min(j + 1, SIZE - 1) * SIZE + i];
         // height = -depth; x right, y up (j grows downward)
         const gx = -(r - l) / (2 * cell), gy = -(u - d) / (2 * cell);
         const n = Math.hypot(gx, gy, 1);
         let s = (-gx * LX - gy * LY + LZ) / n;
         s = 0.30 + 0.70 * Math.max(0, Math.min(1, s));
         raw[j * (SIZE + 1) + 1 + i] = Math.round(255 * s);
      }
   }

   const chunk = (type, data) => {
      const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
      const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
      const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0, 0);
      return Buffer.concat([len, td, crc]);
   };
   let TBL = null;
   function crc32(buf) {
      if (!TBL) {
         TBL = new Int32Array(256);
         for (let n = 0; n < 256; n++) {
            let c = n;
            for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
            TBL[n] = c;
         }
      }
      let c = -1;
      for (let i = 0; i < buf.length; i++) c = TBL[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
      return c ^ -1;
   }
   const ihdr = Buffer.alloc(13);
   ihdr.writeUInt32BE(SIZE, 0); ihdr.writeUInt32BE(SIZE, 4);
   ihdr[8] = 8; ihdr[9] = 0; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
   fs.writeFileSync(outArg, Buffer.concat([
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      chunk('IHDR', ihdr),
      chunk('IDAT', zlib.deflateSync(raw)),
      chunk('IEND', Buffer.alloc(0)),
   ]));
   console.log(`\nwrote ${outArg}`);
}
