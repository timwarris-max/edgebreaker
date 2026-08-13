// Scene agreement gate.
//
// The instrument dialog's whole premise is that the drawing DISPLAYS what the
// gadget would cut and never decides anything itself. That premise has one
// place it can break: the handles run the arithmetic BACKWARDS -- a pointer
// position becomes a size or a cut position -- and an inverse that does not
// match the forward function is a picture quietly disagreeing with the toolpath.
//
// So this drives the real EdgeBreakerDialog.htm in headless Chrome, grabs each
// handle at known points, and checks the values that come back against the
// page's own solve()/passCount()/displayMaxSize(). It is deliberately NOT a
// second implementation of the geometry: every expectation is computed by
// calling the same functions the dialog calls, so the two cannot drift apart.
//
//   node tests\check-scene.js
//
// Same head-injection and report-through-<title> trick as
// tests\check-dialog-layout.js, for the same reason: no browser-driver
// dependency, and the page under test is the shipped file, not a copy.

var fs = require("fs");
var os = require("os");
var path = require("path");
var cp = require("child_process");

var DIALOG = path.join(__dirname, "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");
var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe"
].filter(function (p) { try { return fs.existsSync(p); } catch (e) { return false; } })[0];

if (!CHROME) {
  console.log("SKIP  no Chrome found - scene gate not run");
  process.exit(0);
}

// The bits worth pinning: the 90 deg half of the shop's work, a shallow bit
// where the plunge is long, a steep one, and a quarter-inch bit where the safe
// band is small enough that the stops crowd together.
var CASES = [
  { ang: 90, dia: 0.5,  size: 0.058, pct: 80 },
  { ang: 60, dia: 0.5,  size: 0.120, pct: 60 },
  { ang: 45, dia: 0.5,  size: 0.090, pct: 40 },
  { ang: 90, dia: 0.25, size: 0.040, pct: 20 }
];

// Everything below runs INSIDE the page. It reports one line per case through
// document.title, which --dump-dom carries back out.
var PROBE = function () {
  var out = [];
  function say(name, ok, detail) { out.push((ok ? "ok" : "FAIL") + "|" + name + "|" + (detail || "")); }

  var a = halfAngle(currentAngle);
  var size = parseFloat(el("Size").value);
  var W = wFromSize(currentMode, size, a);
  var passes = passCount(currentDia, W, a);
  var bw = bandWidth(W, passes);

  // 1. The drawing exists and knows where its handles are.
  say("scene-live", SCENE.live === true && SCENE.orange !== null, "live=" + SCENE.live);

  // 2. The chamfer dimension on the drawing is the SIZE THE BOX HOLDS, not the
  //    picture's rounded version of it. This is the one number an operator can
  //    read off the drawing and type into the box, so they must agree exactly.
  //    Found by id, not by ink: the legend heading is the same colour and the
  //    same weight, and a search by appearance quietly measured that instead.
  var dim = el("SceneSizeDim");
  var dimText = dim ? dim.textContent : null;
  say("dimension-matches-box", dimText === f4(W), "drawn=" + dimText + " want=" + f4(W));

  // 3. Every cut position the blue dot can produce is one Lua will accept.
  //    Lua looks the percentage up in its own preset list and refuses the run
  //    with "No preset matched" if it is not there, so a free slide would be a
  //    dialog that cheerfully builds a refusal.
  var allInPresets = true, seen = {};
  for (var y = 0; y <= 380; y += 7) {
    for (var x = 200; x <= 700; x += 25) {
      var p = percentFromPoint({ x: x, y: y });
      if (p === null) continue;
      seen[p] = 1;
      var found = false;
      for (var k = 0; k < PRESETS.length; k++) if (PRESETS[k] === p) found = true;
      if (!found) allInPresets = false;
    }
  }
  // Only the first few offenders: an unsnapped inverse produces one distinct
  // value per sampled point, and the whole list buried the failure in five
  // thousand numbers the first time this caught anything.
  var offenders = [];
  for (var s in seen) if (seen.hasOwnProperty(s)) {
    var isStop = false;
    for (var z = 0; z < PRESETS.length; z++) if (String(PRESETS[z]) === s) isStop = true;
    if (!isStop && offenders.length < 5) offenders.push(s);
  }
  say("position-lands-on-a-stop", allInPresets,
      allInPresets ? "" : ("off-stop: " + offenders.join(",") + " ..."));

  // 4. The gauge's own ends round-trip: a grab at the tip end of the engaged
  //    band reads 0, a grab at the shoulder end reads 100. Computed from
  //    safeBand(), not from pixels counted off a screenshot.
  var band = safeBand(currentDia, bw, a), tanH = Math.tan(a);
  function pointFor(pct) {
    var g = band.g_lo + (pct / 100) * (band.g_hi - band.g_lo);
    var S = g * SCENE.u / tanH;
    var Wu = Math.max(6, Math.round(W * SCENE.u)), Wd = Wu / tanH;
    var St = Math.round((parseFloat(el("StartDepth").value) || 0) * SCENE.u);
    // The inverse takes the mean of the two projections, so feed it a point
    // that is consistent in both: straight down the axis from the tip.
    return { x: 330 + S * tanH, y: 150 + St + Wd + S };
  }
  say("round-trip-0", percentFromPoint(pointFor(0)) === 0, "got=" + percentFromPoint(pointFor(0)));
  say("round-trip-100", percentFromPoint(pointFor(100)) === 100, "got=" + percentFromPoint(pointFor(100)));
  say("round-trip-mid", percentFromPoint(pointFor(60)) === 60, "got=" + percentFromPoint(pointFor(60)));

  // 5. The size handle can never write a size the gadget would refuse. Dragged
  //    hard to the right, it must stop at displayMaxSize -- the same ceiling
  //    the too-big message quotes -- and never below zero on the way back.
  // v1.16: the orange dot rides the face's LOWER end and drags VERTICALLY --
  // down for a bigger chamfer. The old horizontal drag is gone with the axis
  // lock that used to disambiguate it, so these grabs move in y, not x.
  var cap = displayMaxSize(currentMode, currentAngle, currentDia);
  var before = el("Size").value;
  function grabOrange() {
    dragKind = "size";
    dragFrom = { x: SCENE.orange.x, y: SCENE.orange.y, size: size,
                 start: parseFloat(el("StartDepth").value) || 0 };
  }
  grabOrange();
  sceneMove({ clientX: sceneClientX(SCENE.orange.x), clientY: 100000 });
  var big = parseFloat(el("Size").value);
  say("size-clamped-to-ceiling", cap === null || big <= cap + 1e-9,
      "dragged=" + big + " cap=" + cap);
  grabOrange();
  sceneMove({ clientX: sceneClientX(SCENE.orange.x), clientY: -100000 });
  var small = parseFloat(el("Size").value);
  say("size-stays-positive", small > 0, "dragged=" + small);
  sceneUp();
  el("Size").value = before;
  redraw();

  // 6. And the size that comes back is one passCount() will still build.
  var aNow = halfAngle(currentAngle);
  say("clamped-size-is-buildable",
      passCount(currentDia, wFromSize(currentMode, big, aNow), aNow) !== null,
      "size=" + big);

  // 7. THE SPLIT. Start depth is its own handle now, on its own axis, and the
  //    two must not leak into each other. The old single dot carried both
  //    quantities behind a 5-unit axis lock; with the lock gone, a handler that
  //    still read dx anywhere would pass every vertical test above and fail
  //    exactly here.
  say("yellow-handle-exists", SCENE.yellow != null,
      SCENE.yellow ? ("at " + SCENE.yellow.x + "," + SCENE.yellow.y) : "missing");
  if (SCENE.yellow) {
    var sizeBefore = el("Size").value;
    // u is read at the moment of the move and the redraw that follows RESCALES
    // it, so the expectation has to be computed from the value in force during
    // the drag, not from the one left afterwards.
    var u0 = SCENE.u, travel = 40;
    dragKind = "start";
    dragFrom = { x: SCENE.yellow.x, y: SCENE.yellow.y, size: parseFloat(sizeBefore), start: 0 };
    sceneMove({ clientX: sceneClientX(SCENE.yellow.x),
                clientY: sceneClientY(SCENE.yellow.y + travel) });
    var gotStart = parseFloat(el("StartDepth").value);
    var wantStart = travel / u0;
    say("start-depth-follows-the-yellow-handle", Math.abs(gotStart - wantStart) < 0.002,
        "got=" + gotStart + " want=" + wantStart.toFixed(4));
    say("start-drag-leaves-size-alone",
        parseFloat(el("Size").value) === parseFloat(sizeBefore),
        "size " + sizeBefore + " -> " + el("Size").value);
    sceneUp();
    el("StartDepth").value = "0";
    redraw();

    // 7b. Sideways only. Neither handle may respond to horizontal movement.
    var s0 = el("Size").value;
    dragKind = "size";
    dragFrom = { x: SCENE.orange.x, y: SCENE.orange.y, size: parseFloat(s0), start: 0 };
    sceneMove({ clientX: sceneClientX(SCENE.orange.x + 60), clientY: sceneClientY(SCENE.orange.y) });
    // Compared as NUMBERS. A pure sideways drag still runs the size handler,
    // which rewrites the box through f4 -- so "0.058" comes back as "0.0580"
    // with nothing having changed, and a string compare calls that a failure.
    say("orange-ignores-sideways", parseFloat(el("Size").value) === parseFloat(s0),
        "size " + s0 + " -> " + el("Size").value);
    sceneUp();
    el("Size").value = s0;
    redraw();

    var d0 = el("StartDepth").value;
    dragKind = "start";
    dragFrom = { x: SCENE.yellow.x, y: SCENE.yellow.y, size: parseFloat(el("Size").value), start: 0 };
    sceneMove({ clientX: sceneClientX(SCENE.yellow.x - 60), clientY: sceneClientY(SCENE.yellow.y) });
    say("yellow-ignores-sideways", parseFloat(el("StartDepth").value) === parseFloat(d0),
        "start " + d0 + " -> " + el("StartDepth").value);
    sceneUp();
    el("StartDepth").value = d0;
    redraw();

    // 8. THE RAIL'S PICTURE HOLDS STILL WHILE A HANDLE IS HELD.
    //    It is driven by Side and Sharp alone, neither of which can change
    //    mid-gesture, and rebuilding it per frame was a third of the elements a
    //    drag threw away plus a getBBox() that forces a full page layout. That
    //    is the flicker Tim reported in Aspire on 2026-08-12; Chrome is far too
    //    fast to show it, so nothing here can measure the flicker itself. What
    //    it CAN measure is the cause: that the call does not happen.
    //
    //    "rail-redrawn-on-drop" is the control, and it is not decoration. If the
    //    wrapper below failed to take -- a strict-mode page, a renamed function,
    //    a build where redraw() captured the original -- the count would read 0
    //    in both places and the during-drag check would pass having measured
    //    nothing at all. One of the two must move.
    var railCalls = 0;
    var realRail = drawRailSpec;
    drawRailSpec = function () { railCalls++; return realRail.apply(null, arguments); };
    dragKind = "size";
    dragFrom = { x: SCENE.orange.x, y: SCENE.orange.y,
                 size: parseFloat(el("Size").value), start: 0 };
    sceneMove({ clientX: sceneClientX(SCENE.orange.x), clientY: sceneClientY(SCENE.orange.y + 12) });
    sceneMove({ clientX: sceneClientX(SCENE.orange.x), clientY: sceneClientY(SCENE.orange.y + 24) });
    var during = railCalls;
    sceneUp();
    var afterDrop = railCalls;
    drawRailSpec = realRail;
    say("rail-holds-still-during-drag", during === 0, "calls during 2 moves=" + during);
    say("rail-redrawn-on-drop", afterDrop === 1, "calls after mouse-up=" + afterDrop);
    el("Size").value = s0;
    el("StartDepth").value = d0;
    redraw();
  }

  return out.join(" ~ ");
};

// The page maps a client point back into drawing units by subtracting the
// letterbox margin, so a test that wants to hit a known drawing point has to
// go the other way. Injected beside the probe rather than written into the
// dialog: the product has no reason to carry it.
var HELPER = function sceneClientY(uy) {
  var r = document.getElementById("Scene").getBoundingClientRect();
  var w = r.right - r.left, h = r.bottom - r.top;
  var k = Math.min(w / VBW, h / VBH);
  return r.top + (h - VBH * k) / 2 + uy * k;
};

// The x half of the same mapping. Needed from v1.16: with the handles split
// onto two vertical axes, a grab has to be placed at the handle's own x rather
// than swept to a screen edge, and "sideways only" has to be a real horizontal
// move rather than an absence of one.
var HELPER_X = function sceneClientX(ux) {
  var r = document.getElementById("Scene").getBoundingClientRect();
  var w = r.right - r.left, h = r.bottom - r.top;
  var k = Math.min(w / VBW, h / VBH);
  return r.left + (w - VBW * k) / 2 + ux * k;
};

function run(c) {
  var html = fs.readFileSync(DIALOG, "utf8");
  function seed(id, v) {
    var re = new RegExp('(id="' + id + '"[^>]*value=")[^"]*(")');
    html = html.replace(re, "$1" + v + "$2");
  }
  seed("Units", "in");
  seed("ToolAngle", c.ang);
  seed("ToolDiameter", c.dia);
  seed("BitName", c.ang + " V-Bit");
  seed("Size", c.size);
  seed("StartDepth", "0");
  seed("Percent", c.pct);
  seed("Kind", "add");
  seed("Sharp", "0");
  html = html.replace('<span id="BitGeom" style="display:none"></span>',
                      '<span id="BitGeom" style="display:none">' + c.ang + "|" + c.dia + "</span>");

  html = html.replace("</body>",
    "<script>" + HELPER.toString() + ";" + HELPER_X.toString() + ";" +
    "setTimeout(function(){try{document.title='SCENE '+(" + PROBE.toString() + ")();}" +
    "catch(e){document.title='SCENE FAIL|threw|'+e.message;}},1200);" +
    "</script></body>");

  var f = path.join(os.tmpdir(), "eb-scene-" + c.ang + "-" + String(c.dia).replace(".", "") + ".html");
  fs.writeFileSync(f, html);
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--virtual-time-budget=6000",
    "--window-size=1798,950", "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

  var m = /<title>SCENE ([^<]*)<\/title>/.exec(out);
  if (!m) return [{ ok: false, name: "probe-ran", detail: "no SCENE line in the dumped page" }];
  return m[1].split(" ~ ").map(function (line) {
    var p = line.split("|");
    return { ok: p[0] === "ok", name: p[1], detail: p[2] };
  });
}

var failed = 0;
CASES.forEach(function (c) {
  var label = c.ang + " deg x " + c.dia + ", size " + c.size + " @ " + c.pct + "%";
  var rows = run(c);
  rows.forEach(function (r) {
    if (!r.ok) { failed++; console.log("FAIL  " + label + "  " + r.name + "  " + r.detail); }
  });
  var bad = rows.filter(function (r) { return !r.ok; }).length;
  if (!bad) console.log("ok    " + label + "  " + rows.length + " checks");
});

console.log("");
if (failed) { console.log(failed + " scene check(s) failed"); process.exit(1); }
console.log("The drawing agrees with the arithmetic behind it.");
