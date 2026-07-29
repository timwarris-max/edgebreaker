// Dialog layout gate. Aspire's HTML_Dialog cannot resize itself, so the window
// size is chosen once in Lua and MUST fit the content on the first paint --
// there is no runtime correction. This renders the real EdgeBreakerDialog.htm in
// headless Chrome at Aspire's exact viewport and fails if anything overflows.
//
// This is only trustworthy because the dialog's fonts are declared in px, not
// pt: Trident multiplies pt by ~2.7 (Chrome does not), so a pt-sized dialog
// cannot be measured offline at all. Keep the stylesheet px-only.
//
//   node tests\check-dialog-layout.js
//
// Window size below is the DESIGN size -- CO.DESIGN_SIZE in EdgeBreaker.lua and
// DESIGN_W/H in EdgeBreakerDialog.htm. Machines with smaller screens open a smaller
// window (CO.SCREEN_SIZES) and the page scales the same layout down uniformly, so
// checking the design size checks them all: nothing can overflow at a smaller
// scale that fits here.

var fs = require("fs");
var os = require("os");
var path = require("path");
var cp = require("child_process");

var WIN_W = 1800, WIN_H = 1000;     // must match EdgeBreaker.lua
var FRAME_W = 2, FRAME_H = 50;      // measured cost of the window frame
var VIEW_W = WIN_W - FRAME_W, VIEW_H = WIN_H - FRAME_H;
var MIN_SLACK = 24;                 // safety margin for Trident vs Chrome

var CHROME = [
  process.env["ProgramFiles"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Google\\Chrome\\Application\\chrome.exe",
  process.env["ProgramFiles(x86)"] + "\\Microsoft\\Edge\\Application\\msedge.exe"
].filter(fs.existsSync)[0];

if (!CHROME) { console.error("No Chrome/Edge found - cannot verify layout."); process.exit(2); }

var SRC = path.join(__dirname, "..", "gadget", "EdgeBreaker", "EdgeBreakerDialog.htm");
var html = fs.readFileSync(SRC, "utf8");

// 1.1.0: the bit list is gone. The bit comes from Aspire's own tool library,
// chosen with the picker button in this dialog's own header, so the page just
// receives its name, angle and diameter.

// Worst case matters more than the default: a non-90 bit reveals the mode
// radios and their caption, which the 90 deg collapse hides. The SideRow
// (chamfer side radios) is unconditionally visible, so every case below
// measures it too.
var CASES = [
  { name: "90deg default (as opened)", bit: "1/4in 90deg V-bit", angle: "90", dia: "0.25", size: "0.020" },
  { name: "60deg (mode radios shown)", bit: "60deg V-bit",       angle: "60", dia: "0.5",  size: "0.030" },
  { name: "30deg (deepest flute)",     bit: "30deg V-bit",       angle: "30", dia: "0.5",  size: "0.030" },
  { name: "oversize (block message)",  bit: "1/4in 90deg V-bit", angle: "90", dia: "0.25", size: "0.120",
    noSection: true },
  // Task 8: mode radios + the HiddenNote sentence Lua sends when it silently
  // dropped bits (e.g. wrong-unit templates) -- both are unconditionally
  // visible in #Scroll, so this is the real worst case for overflow.
  { name: "60deg + hidden note (kitchen sink)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    note: "2 bits for a different job unit were hidden." },
  // FIX D follow-up: exercise the Units="mm" substitution path (bit-list
  // suffix and size labels switch to "mm") -- previously never lua-driven
  // in this gate, since no case set the Units field.
  { name: "60deg + mm units (unit substitution + warning)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    units: "mm", thickness: "0.25", expectWarn: "40% would fit, at 0.226 mm." },
  // 1.2.0 depth warning. Values verified against the shipped Lua math.
  // A shallow bit plunges a long way for a small chamfer: 12.4 deg wants
  // 0.8998in for a 0.020in setback, well past 3/4in stock.
  { name: "12.4deg + 3/4in stock (warning, 40% fits)", bit: "12.4deg V-bit",
    angle: "12.4", dia: "0.25", size: "0.020", thickness: "0.75",
    expectWarn: "40% would fit, at 0.6283 in." },
  // 3/8in stock used to have NO position that fits; 0% rescues it. Kept as the
  // case that proves the new preset reaches the advice, not just the buttons.
  { name: "12.4deg + 3/8in stock (only 0% fits)", bit: "12.4deg V-bit",
    angle: "12.4", dia: "0.25", size: "0.020", thickness: "0.375",
    expectWarn: "0% would fit, at 0.3567 in." },
  // Thin enough that even the shallowest position overruns -- different wording.
  { name: "12.4deg + 1/4in stock (nothing fits)", bit: "12.4deg V-bit",
    angle: "12.4", dia: "0.25", size: "0.020", thickness: "0.25",
    expectWarn: "even at 0%" },
  // The one case that opens ON the new preset: the buttons, the chart's red dot
  // and the summary all read currentPercent, and 0 is the value a truthiness
  // test anywhere on that path would drop back to the 80% default.
  { name: "0% selected (shallowest position)", bit: "60deg V-bit",
    angle: "60", dia: "0.5", size: "0.030", percent: "0",
    expectSelected: "0%" },
  // Ordinary job: depth 0.0978 in 0.75in stock. Must stay silent.
  { name: "90deg + ample stock (silent)", bit: "1/4in 90deg V-bit",
    angle: "90", dia: "0.25", size: "0.020", thickness: "0.75",
    expectWarn: "" },
  // The hard block already refuses this cut; two red messages must not compete.
  { name: "oversize + stock (block wins, silent)", bit: "1/4in 90deg V-bit",
    angle: "90", dia: "0.25", size: "0.120", thickness: "0.75",
    expectWarn: "", noSection: true },
  // The real layout worst case: everything visible AND the warning present.
  { name: "kitchen sink + warning (worst case)", bit: "60deg V-bit",
    angle: "60", dia: "0.5", size: "0.030", thickness: "0.25",
    note: "2 bits for a different job unit were hidden.",
    expectWarn: "40% would fit, at 0.226 in.",
    chamfers: "1|Chamfer 1 - 0.06 in|nomem||||;2|Chamfer 2 - offsets only|nomem||||;3|New chamfer (3)|new||||",
    slot: "2", facts: "sel=2;excluded=;mem=0" },
  // Task 4: exercises the Change dropdown alone, without the rest of the sink.
  { name: "many chamfers (dropdown populated)", bit: "60deg V-bit",
    angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in|differs|0.06|setback|auto|60;2|Chamfer 2 - 0.015 in|match|0.015|face|inside|40;3|Chamfer 3 - offsets only|nomem||||;4|New chamfer (4)|new||||",
    slot: "3", facts: "sel=3;excluded=;mem=0" },

  // v1.5.0: the banner is the dialog's whole point, and each state is a
  // DIFFERENT height (icon + headline + sub-line wrap differently). Every one
  // has to be rendered, not just the one a seeded field combination happens to
  // produce -- hence the __FORCE_STATE hook. Long labels and a long excluded
  // list are used deliberately: they are what pushes the sub-line onto a
  // third line, which is the only way this banner can overflow.
  { name: "banner: add (green)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in|differs|0.06|setback|auto|60;2|Chamfer 2 - 0.015 in|differs|0.015|face|inside|40;3|New chamfer (3)|new||||",
    slot: "3", kind: "add", facts: "sel=5;excluded=1:2,2:1;mem=0",
    force: "add", expectBanner: "Adding Chamfer 3" },
  { name: "banner: rebuild (blue)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in|match|0.06|setback|auto|60;2|New chamfer (2)|new||||",
    slot: "1", kind: "rebuild", facts: "sel=4;excluded=;mem=4",
    force: "rebuild", expectBanner: "Rebuilding Chamfer 1" },
  { name: "banner: teach (amber)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in - shapes missing or moved|nomem|0.06|setback|auto|60;2|New chamfer (2)|new||||",
    slot: "1", kind: "rebuild", facts: "sel=3;excluded=;mem=4",
    force: "teach", expectBanner: "I don't know which shapes" },
  { name: "banner: replace (red)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in|differs|0.06|setback|auto|60;2|Chamfer 2 - 0.015 in|differs|0.015|face|inside|40;3|New chamfer (3)|new||||",
    slot: "1", kind: "add", facts: "sel=3;excluded=;mem=4",
    force: "replace", expectBanner: "Replacing Chamfer 1" },
  // Nothing selected: the recall banner, and the only state whose counts come
  // from mem= rather than sel=.
  { name: "banner: recall (nothing selected)", bit: "60deg V-bit", angle: "60", dia: "0.5", size: "0.030",
    chamfers: "1|Chamfer 1 - 0.06 in|differs|0.06|setback|auto|60;2|New chamfer (2)|new||||",
    slot: "1", kind: "recall", facts: "sel=0;excluded=;mem=4",
    expectBanner: "nothing selected" },
  // v1.6.0. A start depth adds a row to the LEFT column and lengthens the
  // warning in the right one, and the warning wraps to two lines once it
  // names both numbers -- so this measures both columns at their tallest at
  // once, with the deepest banner and the hidden note as well.
  { name: "start depth + wrapped warning (v1.6.0 worst case)", bit: "12.4deg V-bit",
    angle: "12.4", dia: "0.25", size: "0.020", thickness: "0.375", start: "0.25",
    note: "2 bits for a different job unit were hidden.",
    chamfers: "1|Chamfer 1 - 0.06 in|differs|0.06|setback|auto|60;2|Chamfer 2 - 0.015 in|differs|0.015|face|inside|40;3|New chamfer (3)|new||||",
    slot: "1", kind: "add", facts: "sel=3;excluded=;mem=4", force: "replace",
    expectWarn: "Reaches 0.6067 in even at 0% — past your 0.375 in stock. Use a wider-angle bit, a smaller chamfer, or less start depth." },
  // Live 2026-07-27: a 0.25 start depth on 0.25 stock. Nothing about the BIT
  // can fix this, so the advice has to name the start depth instead.
  { name: "start depth alone reaches the stock (advice must change)", bit: "1/4in 90deg V-bit",
    angle: "90", dia: "0.25", size: "0.02", thickness: "0.25", start: "0.25",
    expectWarn: "The start depth alone already reaches it" },
  // v1.8.0: the size modes. Face and Leg are the two the caption has to explain
  // and the two no case exercised -- every case above runs at the `setback`
  // default. 90 deg has no mode row, so it must have no caption either.
  // expectEdge is [x1,y1,x2,y2] of the edge that must be the orange one, in the
  // inset's own coordinates (IX=898, IY=20, IW=36, IH=58 in the dialog): the
  // setback is the top edge, the leg the right edge, the face the slant.
  { name: "setback mode caption + inset", bit: "60deg V-bit", angle: "60", dia: "0.5",
    size: "0.030", mode: "setback",
    expectCaption: "across the top face", expectInset: "SETBACK",
    expectEdge: [898, 20, 934, 20] },
  { name: "face mode caption + inset", bit: "60deg V-bit", angle: "60", dia: "0.5",
    size: "0.030", mode: "face",
    expectCaption: "along the slanted bevel face", expectInset: "FACE",
    expectEdge: [898, 20, 934, 78] },
  { name: "leg mode caption + inset", bit: "12.4deg V-bit", angle: "12.4", dia: "0.25",
    size: "0.020", mode: "leg",
    expectCaption: "down the side face", expectInset: "LEG",
    expectEdge: [934, 20, 934, 78] },
  // At 90 deg setback and leg are the same quantity, the mode row is hidden,
  // and an inset would answer a question nobody asked. Absence is the assertion:
  // expectEdge null means no highlighted edge may exist at all.
  { name: "90deg has no mode row and no inset", bit: "1/4in 90deg V-bit", angle: "90",
    dia: "0.25", size: "0.020",
    expectCaption: "", expectInset: "", expectEdge: null },
  // An obtuse bit has the corner the other way round -- the setback is 1.73x the
  // leg at 120 deg, not 0.58x -- so the inset's width and height swap and its far
  // corner moves right, XC 934 -> 956. 120 and 140 deg marking V-bits are real
  // bits, and drawn unswapped this picture states the opposite of the truth while
  // every word on the dialog stays right.
  { name: "120deg obtuse (setback drawn longer than the leg)", bit: "120deg V-bit",
    angle: "120", dia: "0.5", size: "0.030", mode: "setback",
    expectCaption: "across the top face", expectInset: "SETBACK",
    expectEdge: [898, 20, 956, 20] },
  // The inset's number is sold as the one the operator typed, so it must not be
  // rounded: fnum reports a 1/32 chamfer as 0.0313.
  { name: "typed size drawn as typed (1/32, obtuse)", bit: "120deg V-bit",
    angle: "120", dia: "0.5", size: "0.03125", mode: "face",
    expectCaption: "along the slanted bevel face", expectInset: "FACE",
    expectInsetNum: "0.03125 in", expectEdge: [898, 20, 956, 56] },
  // The same case in MM is the real ink<=990 worst case: the box has already
  // swapped wider and moved right, the typed number is the longest label on it,
  // and "mm" is a wider suffix than "in" -- 972.4 against 961.4. Without this
  // the gate never renders its own worst case, because no other case combines
  // millimetres with a non-90 deg bit.
  { name: "widest the inset ever gets (1/32, obtuse, mm)", bit: "120deg V-bit",
    angle: "120", dia: "12", size: "0.03125", mode: "face", units: "mm",
    expectInset: "FACE", expectInsetNum: "0.03125 mm", expectEdge: [898, 20, 956, 56] },
  // The header is a fixed 88px box shared by a title, a badge that grows with
  // the bit's library name, and now a button. 45 characters is the longest name
  // spec 5 costed; it leaves the badge 928px wide.
  { name: "long bit name in the header", bit: "60deg V-bit", angle: "60", dia: "0.5",
    size: "0.030",
    badgeName: "V-Bit 60.0&deg; - 1/2\" - Amana 45771-K spoilboard" },
  // Nothing has ever been picked on this machine. Before the merge this state
  // could not exist -- the dialog could not open without a bit -- so the page's
  // currentAngle = 90 / currentDia = 0.25 defaults were harmless. They are a
  // hazard now: they draw a confident chart for a bit nobody chose.
  { name: "no bit yet (first run ever)", bit: "", angle: "", dia: "", size: "0.020",
    noSection: true, expectCaption: "", expectInset: "",
    expectBlock: "Choose a bit to see the cut." },
  // Opens on a 90 deg bit -- no mode row, no caption, no inset -- then the
  // operator picks a 30 deg 1/2in bit without the dialog closing. Everything
  // downstream of currentAngle has to follow, including the mode row, which
  // redraw() does not touch: only updateModeVisibility() can unhide it.
  { name: "picking a bit mid-dialog redraws the page", bit: "1/4in 90deg V-bit",
    angle: "90", dia: "0.25", size: "0.030", pick: "30.000000|0.500000",
    expectCaption: "across the top face", expectInset: "SETBACK" }
];

function seed(c) {
  var s = html;
  s = s.replace('id="BitName" name="BitName" value=""', 'id="BitName" name="BitName" value="' + c.bit + '"');
  // Simulates Aspire's buddy-label write. AddToolPicker resolves the seeded bit
  // into this span before the dialog is even shown (probe Q1), and the page is
  // forbidden to touch it, so seeding the SPAN -- not the BitName input -- is
  // what a real long library name actually looks like here.
  // The empty-state word lives in its own span now, so this one starts EMPTY.
  // A seed that no longer matches is the dangerous kind of wrong: the case
  // still renders, still passes, and proves nothing. Fail loudly instead.
  if (c.badgeName) {
    var before = s;
    s = s.replace('<b id="BitBadgeName"></b>',
                  '<b id="BitBadgeName">' + c.badgeName + '</b>');
    if (s === before)
      throw new Error("badgeName seed matched nothing - #BitBadgeName markup changed");
  }
  s = s.replace('id="ToolAngle" name="ToolAngle" value=""', 'id="ToolAngle" name="ToolAngle" value="' + c.angle + '"');
  s = s.replace('id="ToolDiameter" name="ToolDiameter" value=""', 'id="ToolDiameter" name="ToolDiameter" value="' + c.dia + '"');
  s = s.replace('id="Size" name="Size" value="0.020"', 'id="Size" name="Size" value="' + c.size + '"');
  if (c.start)
    s = s.replace('id="StartDepth" name="StartDepth" value="0"',
                  'id="StartDepth" name="StartDepth" value="' + c.start + '"');
  // The three size modes are a real branch in the dialog and every case above
  // runs at the `setback` default. initFromDefaults() reads this hidden field
  // into currentMode before initBit() calls updateModeVisibility(), so seeding
  // it is enough to open the dialog in any mode.
  // Same convention as Mode above: initFromDefaults() reads this hidden field
  // into currentPercent, so seeding it opens the dialog on that cut position.
  if (c.percent)
    s = s.replace('id="Percent" name="Percent" value="80"',
                  'id="Percent" name="Percent" value="' + c.percent + '"');
  if (c.mode)
    s = s.replace('id="Mode" name="Mode" value="setback"',
                  'id="Mode" name="Mode" value="' + c.mode + '"');
  if (c.note)
    s = s.replace('id="HiddenNote" name="HiddenNote" value=""', 'id="HiddenNote" name="HiddenNote" value="' + c.note + '"');
  if (c.units)
    s = s.replace('id="Units" name="Units" value=""', 'id="Units" name="Units" value="' + c.units + '"');
  if (c.thickness)
    s = s.replace('id="Thickness" name="Thickness" value=""',
                  'id="Thickness" name="Thickness" value="' + c.thickness + '"');
  if (c.chamfers) {
    s = s.replace('id="Chamfers" name="Chamfers" value=""',
                  'id="Chamfers" name="Chamfers" value="' + c.chamfers + '"');
    s = s.replace('id="Slot" name="Slot" value="1"',
                  'id="Slot" name="Slot" value="' + (c.slot || "1") + '"');
  }
  if (c.kind)
    s = s.replace('id="Kind" name="Kind" value="add"',
                  'id="Kind" name="Kind" value="' + c.kind + '"');
  if (c.facts)
    s = s.replace('id="BannerFacts" name="BannerFacts" value=""',
                  'id="BannerFacts" name="BannerFacts" value="' + c.facts + '"');
  // The only way to exercise the poll offline. UpdateLabelField sets this span's
  // text; so does this, at 700ms -- after the page's own init (which fires within
  // 250ms) and well before the 1500ms measurement.
  if (c.pick)
    s = s.replace("</body>", "<script>setTimeout(function(){" +
      "document.getElementById('BitGeom').innerHTML='" + c.pick + "';},700);</script></body>");
  // The banner state the dialog would compute is not always the one worth
  // measuring, so the page reads this test-only global when it is present.
  // It has to be set BEFORE the page script runs, hence the head injection.
  if (c.force)
    s = s.replace("</head>", "<script>window.__FORCE_STATE='" + c.force + "';</script></head>");
  // Pin the page to Aspire's real viewport. Headless Chrome's --window-size
  // does not map 1:1 to the viewport, and the answer must not depend on that.
  // body:relative makes #Scroll/#Bar resolve against this fixed box instead of
  // the browser viewport. In Aspire the two are identical (body is height:100%
  // of the viewport), so this changes nothing about what is measured.
  s = s.replace("</head>", "<style>html,body{height:" + VIEW_H + "px !important;" +
    "width:" + VIEW_W + "px !important;} body{position:relative !important;}</style></head>");
  // Report measurements through <title> so --dump-dom carries them out.
  s = s.replace("</body>", "<script>setTimeout(function(){" +
    "var sc=document.getElementById('Scroll'), bar=document.getElementById('Bar')," +
    "ok=document.getElementById('ButtonOK');" +
    // scrollHeight clamps to clientHeight once content fits, which hides how
    // much slack is left, so the children's own boxes are measured instead.
    // v1.5.0: the two columns sit SIDE BY SIDE, so the taller one decides --
    // taking the last child would measure whichever column happens to be
    // second and silently miss an overflow in the other.
    "var kids=sc.children, top=sc.getBoundingClientRect().top, low=0;" +
    "for(var i=0;i<kids.length;i++){var b=kids[i].getBoundingClientRect().bottom;" +
    "if(b>low)low=b;}" +
    "var real=Math.round(low-top)+16;" +
    "var over=real-sc.clientHeight;" +
    "var r=ok.getBoundingClientRect();" +
    // The section SVG is overflow="hidden", so anything drawn past the right
    // edge of its viewBox is CLIPPED -- it cannot change any scroll size and the
    // overflow measurement above can never see it. A label running off the end
    // renders as a truncated word and nothing else. getBBox() is used rather
    // than the drawn coordinates because it carries real font metrics, and the
    // inset's labels are text-anchor="middle" so they reach past their anchor.
    // An empty group (no bit, or the oversize block) reports 0, not -Infinity.
    "var sg=document.getElementById('SecG'), ink=0, kid=sg?sg.children:[];" +
    "for(var j=0;j<kid.length;j++){try{var bb=kid[j].getBBox();" +
    "if(bb.x+bb.width>ink)ink=bb.x+bb.width;}catch(e){}}" +
    // #Hdr has never been measured: the gate walks #Scroll's children and stops.
    // Putting the picker button up here means measuring up here, or the button's
    // height is unprotected. Three numbers, all relative to the header itself:
    // how far its ink reaches down, whether the two right-floated boxes touch,
    // and how much room is left before the version text.
    "var hd=document.getElementById('Hdr'), ht=hd.getBoundingClientRect();" +
    "var bb=document.getElementById('BitBadge').getBoundingClientRect();" +
    "var pk=document.getElementById('ToolChooseButton');" +
    "var pr=pk?pk.getBoundingClientRect():null;" +
    "var vr=hd.getElementsByClassName('ver')[0].getBoundingClientRect();" +
    "var hdrInk=Math.round(Math.max(bb.bottom,pr?pr.bottom:0)-ht.top);" +
    "var hdrPair=pr?Math.round(pr.left-bb.right):9999;" +
    "var hdrGap=Math.round(Math.min(bb.left,pr?pr.left:bb.left)-vr.right);" +
    "document.title='MEASURE over='+over+' content='+real+' avail='+sc.clientHeight+" +
    "' okBottom='+Math.round(r.bottom)+' viewH=" + VIEW_H + "'+" +
    "' ink='+(Math.round(ink*10)/10)+" +
    "' hdrInk='+hdrInk+' hdrPair='+hdrPair+' hdrGap='+hdrGap;" +
    "},1500);</script></body>");
  return s;
}

// Attributes by name, never by position. Chrome happens to serialize them in
// the order the page set them, but that is an implementation detail of the
// dumper -- a check that pattern-matches a fixed attribute order fails the day
// the drawing code sets one attribute earlier, which is a test bug wearing a
// product bug's clothes.
function attrsOf(tag) {
  var a = {}, re = /([\w-]+)="([^"]*)"/g, m;
  while ((m = re.exec(tag)) !== null) a[m[1]] = m[2];
  return a;
}

// Everything drawn into the section frame, section view and corner inset alike,
// lives in the #SecG group. Scoping to it keeps the flute chart's own orange
// leader lines out of the way.
function secG(out) {
  var m = /<g id="SecG">([\s\S]*?)<\/g>/.exec(out);
  return m ? m[1] : null;
}

// Every orange (highlighted) line in the corner inset, as [x1,y1,x2,y2].
//
// The section view highlights the real bevel facet in the SAME orange at the
// SAME width, so colour alone cannot tell the two apart. The inset is the only
// thing drawn right of x=800 (see the header comment above drawModeInset in
// EdgeBreakerDialog.htm: the frame is empty from 800 to 990 in every case), and
// the section's facet is drawn at x<=380, so the x range is what separates them.
function insetHighlights(out) {
  var g = secG(out);
  if (g === null) return null;
  var tags = g.match(/<line\b[^>]*>/g) || [], hits = [], i, a;
  for (i = 0; i < tags.length; i++) {
    a = attrsOf(tags[i]);
    if (a.stroke !== "#f76707") continue;
    if (!(+a.x1 >= 800) || !(+a.x2 >= 800)) continue;
    hits.push([+a.x1, +a.y1, +a.x2, +a.y2]);
  }
  return hits;
}

// The number drawn under the mode word, unit and all. Same x>=800 rule as
// insetHighlights -- every label the section view draws for itself sits left of
// that -- and the mode word carries no digit, so the inset's numeric label is
// the only text this can return.
function insetNumbers(out) {
  var g = secG(out);
  if (g === null) return null;
  var re = /<text\b([^>]*)>([^<]*)<\/text>/g, m, a, hits = [];
  while ((m = re.exec(g)) !== null) {
    a = attrsOf("<text " + m[1] + ">");
    if (+a.x >= 800 && /\d/.test(m[2])) hits.push(m[2]);
  }
  return hits;
}

// Did the SECTION's stock block draw? The inset appends two polygons of its own
// with the same two fills, so a bare polygon count is satisfied by the inset
// alone. The inset is a corner detail pinned to the right of the frame -- its
// leftmost ink is x=858 -- while the section's block spans the drawing from
// x=20, so a polygon with a point left of x=800 can only be the section's.
function sectionDrewStock(out) {
  var g = secG(out);
  if (g === null) return false;
  var tags = g.match(/<polygon\b[^>]*>/g) || [], i, re, m;
  for (i = 0; i < tags.length; i++) {
    re = /(-?[\d.]+)\s*,\s*(-?[\d.]+)/g;
    while ((m = re.exec(attrsOf(tags[i]).points || "")) !== null)
      if (parseFloat(m[1]) < 800) return true;
  }
  return false;
}

// Which cut-position button is lit, as its data-pct. Exactly one may be, and
// the whole dialog downstream -- chart, section, summary, the number that ends
// up on the toolpath -- follows the same currentPercent this reflects.
function selectedPreset(out) {
  var tags = out.match(/<div\b[^>]*class="seg[^"]*"[^>]*>/g) || [], hits = [], i, a;
  for (i = 0; i < tags.length; i++) {
    a = attrsOf(tags[i]);
    if (/(^|\s)sel(\s|$)/.test(a.class || "")) hits.push(a["data-pct"]);
  }
  return hits;
}

var tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dlg-"));
var failed = 0;

console.log("Viewport " + VIEW_W + "x" + VIEW_H + "  (window " + WIN_W + "x" + WIN_H + " less frame)\n");

CASES.forEach(function (c) {
  var f = path.join(tmp, c.name.replace(/[^a-z0-9]/gi, "_") + ".htm");
  fs.writeFileSync(f, seed(c));
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars",
    "--virtual-time-budget=4000",
    "--window-size=" + VIEW_W + "," + VIEW_H,
    "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 40 * 1024 * 1024 });

  var m = /MEASURE over=(-?\d+) content=(\d+) avail=(\d+) okBottom=(\d+) viewH=(\d+) ink=(-?[\d.]+) hdrInk=(-?\d+) hdrPair=(-?\d+) hdrGap=(-?\d+)/.exec(out);
  if (!m) { console.log("FAIL  " + c.name + "  (no measurement - page error?)"); failed++; return; }

  var over = +m[1], content = +m[2], avail = +m[3], okBottom = +m[4], viewH = +m[5], ink = +m[6];
  var hdrInk = +m[7], hdrPair = +m[8], hdrGap = +m[9];
  var bad = [];
  if (over > 0) bad.push("content overflows by " + over + "px");
  if (okBottom > viewH) bad.push("OK button below the fold");
  // The section's viewBox is 1000 wide and clipped, so this is the one
  // constraint on the drawing that the overflow measurement structurally cannot
  // enforce: ink past the edge is silently cut off instead of pushing anything.
  // 990 is the drawing's own margin. Today's worst is the inset's number on an
  // obtuse bit -- the box swaps wider and its labels move right with it -- in
  // MM, because "mm" is a wider suffix than "in": 972.4 for "0.03125 mm" against
  // 961.4 for the same size in inches. That is 17.6 units of real headroom, not
  // the 28.6 the inch case suggests, which is why the case below seeds mm.
  //
  // The number is now drawn AS TYPED, so its length is bounded by what a person
  // enters rather than by fnum's four decimals. Measured, it takes a 9-character
  // number in mm (10 in inches) before anything is lost, and the loss is a
  // truncated tail, not a wrong figure. 1/64 in (0.015625) and 1/32 in as mm
  // (0.79375) both clear it easily, so no length cap is worth the code.
  if (ink > 990) bad.push("section drawing runs to x=" + ink + ", past the 990 clip margin");
  // Trident is not pixel-identical to Chrome (form controls, zoom), so a
  // layout that only just fits here can still clip in Aspire.
  if (over <= 0 && (avail - content) < MIN_SLACK)
    bad.push("only " + (avail - content) + "px slack, want >= " + MIN_SLACK);

  // #Hdr is 88px tall with 14px of padding, so its ink may reach 74px from the
  // top of the box. Trident draws the real button 43px against Chrome's 42
  // (probe, 2026-07-28 Q4), so a Chrome-side number is a fair proxy -- but the
  // assertion is against the header's own box, never against 42.
  if (hdrInk > 74) bad.push("header ink reaches " + hdrInk + "px of its 74px box");
  // Both boxes float right, button outboard. A negative gap is the long-name
  // case running the badge under the button.
  if (hdrPair < 0) bad.push("badge and picker button overlap by " + (-hdrPair) + "px");
  if (hdrGap < MIN_SLACK)
    bad.push("only " + hdrGap + "px between the version text and the badge");

  // The warning is display-only, so assert rendered text rather than a
  // measurement. --dump-dom carries the post-JS DOM, so #DepthWarn's content is
  // already in `out`. Match an ASCII-only fragment: the message contains an
  // em-dash and character-encoding round-trips are not what this gate is for.
  if (c.expectWarn !== undefined) {
    var w = /id="DepthWarn"[^>]*>([^<]*)</.exec(out);
    var got = w ? w[1] : "(no #DepthWarn element)";
    if (c.expectWarn === "") {
      if (got !== "") bad.push("expected silence, got: " + got);
    } else if (got.indexOf(c.expectWarn) === -1) {
      bad.push("warning missing '" + c.expectWarn + "', got: " + got);
    }
  }

  // A lit button is the only thing that says which cut position OK will use, and
  // it is set by JavaScript from the field Lua seeded -- so it can be wrong while
  // every measurement on the page is right.
  if (c.expectSelected !== undefined) {
    var lit = selectedPreset(out);
    if (lit.length !== 1)
      bad.push("expected exactly 1 lit cut-position button, got " + lit.length +
               ": " + JSON.stringify(lit));
    else if (lit[0] + "%" !== c.expectSelected)
      bad.push("lit button expected " + c.expectSelected + ", got " + lit[0] + "%");
  }

  if (c.expectBlock !== undefined) {
    var bl = /id="BlockMsg"[^>]*>([\s\S]*?)<\/div>/.exec(out);
    var bt = bl ? bl[1].replace(/<[^>]*>/g, "") : "(no #BlockMsg element)";
    if (bt.indexOf(c.expectBlock) === -1)
      bad.push("block message missing '" + c.expectBlock + "', got: " + bt);
  }

  // The banner has to SAY the right thing, not merely fit: a state that
  // renders the wrong headline is a wrong-cut hazard, and it is the one part
  // of this dialog no Lua test can reach.
  if (c.expectBanner) {
    var bm = /id="BannerHead"[^>]*>([\s\S]*?)<\/span>/.exec(out);
    var bh = bm ? bm[1].replace(/<[^>]*>/g, "") : "(no #BannerHead element)";
    if (bh.indexOf(c.expectBanner) === -1)
      bad.push("banner missing '" + c.expectBanner + "', got: " + bh);
  }

  // The mode caption is the only explanation of Setback/Face/Leg when the
  // section cannot draw (no bit, invalid size, oversize block), so it has to
  // SAY the right thing rather than merely fit.
  if (c.expectCaption !== undefined) {
    var cm = /id="ModeCaption"[^>]*>([\s\S]*?)<\/span>/.exec(out);
    var ct = cm ? cm[1].replace(/<[^>]*>/g, "") : "(no #ModeCaption element)";
    if (c.expectCaption === "") {
      if (ct !== "") bad.push("expected no caption, got: " + ct);
    } else if (ct.indexOf(c.expectCaption) === -1) {
      bad.push("caption missing '" + c.expectCaption + "', got: " + ct);
    }
  }

  // The inset is the only thing on the dialog that says what Face and Leg
  // MEAN, and it is drawn rather than written -- so a case that measures fine
  // while drawing no inset is exactly the silent regression worth catching.
  if (c.expectInset !== undefined) {
    var iw = out.match(/>(SETBACK|FACE|LEG)</g) || [];
    var got = iw.length ? iw[0].slice(1, -1) : "";
    if (got !== c.expectInset)
      bad.push("inset word expected '" + (c.expectInset || "none") + "', got '" +
               (got || "none") + "'");
  }

  // The word above is only ever mode.toUpperCase(), so it is right by
  // construction and proves nothing about the DRAWING: which of the three edges
  // is the orange one is the entire message of the inset, and it can be wrong
  // while the word is right. Proved by mutation -- pinning the highlight to the
  // setback edge in all three modes, i.e. the feature completely broken, left
  // this gate reporting "All layouts fit."
  if (c.expectEdge !== undefined) {
    var hits = insetHighlights(out);
    if (hits === null) {
      bad.push("no #SecG group in the DOM");
    } else if (!c.expectEdge) {
      if (hits.length)
        bad.push("expected no highlighted inset edge, got " + hits.length +
                 ": " + JSON.stringify(hits));
    } else if (hits.length !== 1) {
      // Two highlights are as wrong as none: the inset answers a which-one
      // question, so it has to name exactly one edge.
      bad.push("expected exactly 1 highlighted inset edge, got " + hits.length +
               ": " + JSON.stringify(hits));
    } else if (hits[0].join(",") !== c.expectEdge.join(",")) {
      bad.push("inset highlights the wrong edge: expected [" + c.expectEdge.join(",") +
               "], got [" + hits[0].join(",") + "]");
    }
  }

  // The inset says this number is the one you typed, so a rounded one is a
  // broken promise, not a cosmetic difference: 0.03125 is a real 1/32 chamfer
  // and fnum() turns it into 0.0313.
  if (c.expectInsetNum !== undefined) {
    var nums = insetNumbers(out);
    if (nums === null) bad.push("no #SecG group in the DOM");
    else if (nums.length !== 1)
      bad.push("expected exactly 1 numeric inset label, got " + nums.length +
               ": " + JSON.stringify(nums));
    else if (nums[0] !== c.expectInsetNum)
      bad.push("inset number expected '" + c.expectInsetNum + "', got '" + nums[0] + "'");
  }

  // v1.7.0: the section view is drawn, not written, so a case that measures
  // fine while drawing nothing is the failure worth catching -- exactly the
  // class the receipt's own top-view check existed for. It has to identify the
  // SECTION's stock block specifically: the corner inset appends two polygons
  // with the same two fills, so counting polygons would leave this passing on
  // the inset alone the moment the inset stops being gated on the section
  // having drawn.
  if (!c.noSection) {
    if (!sectionDrewStock(out)) bad.push("section view drew nothing");
  }

  console.log((bad.length ? "FAIL  " : "ok    ") + c.name +
    "  content " + content + " / " + avail + " avail, slack " + (avail - content) + "px" +
    (bad.length ? "  <-- " + bad.join("; ") : ""));
  if (bad.length) failed++;
});

// ---- MessageDialog.htm ---------------------------------------------------
// A second page with its own viewport. Message windows are 900 wide and come
// in two heights, chosen in Lua by whether the message carries rows, so each
// case declares which one it opens at. The failure this block exists to catch
// is a message too tall for its window: the operator would have to scroll a
// message to finish reading it, which is worse than the plain box this
// replaces.
var MSG_SRC = path.join(__dirname, "..", "gadget", "EdgeBreaker", "MessageDialog.htm");
var msgHtml = fs.readFileSync(MSG_SRC, "utf8");
// WINDOW sizes, exactly like WIN_W/WIN_H above -- must match CO.MESSAGE_SIZE_*
// in EdgeBreaker.lua. The frame comes off before anything is measured, the same
// FRAME_W/FRAME_H the setup dialog uses and the deleted receipt used before it.
//
// This block originally rendered at MSG_W x MSG_H raw, i.e. it measured 50px of
// height Aspire never gives: HTML_Dialog's height is the OUTER window, and
// session 023 measured an 1800x1000 window reporting body.clientHeight 950. Two
// message states fitted here and did not fit in Aspire -- the longest body over
// by 9px, and the ordinary post-run report with 43px of its note behind the
// button bar. Found by rendering to PNG, 2026-07-28.
var MSG_W = 900;
var MSG_H_SHORT = 500, MSG_H_TALL = 700;
var MSG_VW = MSG_W - FRAME_W;

var MSG_CASES = [
  { name: "msg: error, one line", kind: "m-error", tall: false,
    head: "Chamfer size must be a positive number" },

  { name: "msg: headline only, nothing else (shortest)", kind: "m-error", tall: false,
    head: "Nothing was changed" },

  // The tallest bodied message in the gadget: line 2156, three paragraphs.
  // If this one does not fit, the short window is too small - raise it. Do not
  // let a message scroll.
  { name: "msg: longest body (pick a bit first)", kind: "m-error", tall: false,
    head: "Nothing was changed",
    body: "Pick a bit first \u2014 the Choose bit button is at the top right.\n\n" +
          "If Aspire's Select button stayed GREYED with a bit highlighted, that bit " +
          "has no feeds and speeds for the machine shown at the top of that dialog. " +
          "Press Copy under 'Copy Settings From', then Apply." },

  { name: "msg: warn", kind: "m-warn", tall: false,
    head: "Start depth cannot be negative",
    body: "It's how far below the top of the stock the edge sits. Use 0 for an edge at the top." },

  // The post-run report at its fullest: every row including start depth, plus
  // a note.
  { name: "msg: full report (done, all rows + note)", kind: "m-done", tall: true,
    head: "Chamfer 2 rebuilt from memory",
    rows: "Offset=1 vector, outward;G=0.0403 in;Plunge D=0.0803 in;" +
          "Standoff=0.0403 in;Start depth=0.0500 in (total reach 0.1303 in);" +
          "Layer=EdgeBreaker - Offset 02",
    note: "Ignored 1 selected vector that is EdgeBreaker's own offset." },

  // mm is the wider unit suffix and 99 is the longest layer name.
  { name: "msg: report in mm, longest layer name", kind: "m-done", tall: true,
    head: "Chamfer 99 added",
    rows: "Offset=12 vectors, 8 outward and 4 inward;G=1.0236 mm;" +
          "Plunge D=2.0409 mm;Standoff=1.0236 mm;Layer=EdgeBreaker - Offset 99" },

  { name: "msg: note long enough to wrap", kind: "m-warn", tall: true,
    head: "Chamfer 1 rebuilt",
    rows: "Offset=3 vectors, outward;G=0.0295 in",
    note: "Ignored 4 selected vectors that are EdgeBreaker's own offsets, and " +
          "skipped 2 shapes that Aspire's offset collapsed to nothing because they " +
          "are narrower than the chamfer at this cut position." },

  // The whole point of writing with innerText. If any of this reaches the page
  // as markup the assertion below fails and the <b> renders instead.
  { name: "msg: a value that looks like markup stays text", kind: "m-done", tall: true,
    head: "Chamfer 1 added",
    rows: "Layer=Bob's <b>bold</b> & co",
    expectLiteral: "&lt;b&gt;bold&lt;/b&gt;" },

  // Task 4 review, Finding 2: an error can carry rows too -- the "nothing wide
  // enough to chamfer" refusal keeps its numbers as rows instead of losing them
  // when its first sentence was dropped from the body. New state: error + rows,
  // so it opens tall even though its body is short.
  { name: "msg: error with rows (nothing wide enough to chamfer)", kind: "m-error", tall: true,
    head: "Nothing was wide enough to chamfer",
    body: "No offset vectors were drawn and no toolpath was created. The previous " +
          "run's offset vectors were already cleared.\n\n" +
          "Try a smaller chamfer size, or a cut position nearer the tip.",
    rows: "Selected=4 vector(s);G=0.0403 in" },

  // Task 5, found by rendering: the state closest to the FLOOR of a real
  // report, and the one this gate had no case for -- which is exactly why
  // nothing caught the frame error. toolpath_note is assigned on every path
  // through the success block and note_text always appends it, so EVERY report
  // carries that 3-line note; should_report then only fires when sel_notes is
  // non-empty or something went wrong, so something is always stacked on top of
  // it. The "full report" case above, whose note is one short line, is not a
  // state the Lua can produce.
  //
  // Seeded exactly as EdgeBreaker.lua ~2723 builds note_text: sel_notes with
  // its leading break stripped, then "\n\n", then toolpath_note (which carries
  // a "\n" of its own before the tool name). Entities rather than literal
  // characters for the degree sign and the inch mark -- MessageDialog.htm
  // declares no charset, so a UTF-8 byte in a seeded file would render as
  // mojibake here and wrap differently than it does in Aspire, where the value
  // arrives through AddTextField and never passes through the file at all.
  { name: "msg: report with both a selection note and a toolpath note",
    kind: "m-warn", tall: true,
    head: "Chamfer 2 rebuilt",
    rows: "Offset=3 vectors (3 outward, 0 inward);G=0.0403 in;Plunge D=0.0803 in;" +
          "Standoff=0.0403 in;Layer=EdgeBreaker - Offset 02",
    note: "Note: ignored 1 selected vector(s) that are EdgeBreaker's own offsets.\n\n" +
          "Toolpath 'Chamfer 2 - 0.06 in [EdgeBreaker 02]' created and calculated " +
          "(Profile On, depth 0.0803 in)\nusing V-Bit 60.0&deg; - 1/2&quot;." }
];

function msgSeed(c, viewH) {
  var s = msgHtml;
  function put(id, v) {
    var before = s;
    s = s.replace('id="' + id + '"    name="' + id + '"    value=""',
                  'id="' + id + '"    name="' + id + '"    value="' + v + '"');
    if (s === before) {
      // A seed that matches nothing renders, passes, and proves nothing.
      s = s.replace('id="' + id + '" name="' + id + '" value=""',
                    'id="' + id + '" name="' + id + '" value="' + v + '"');
    }
    if (s === before) throw new Error(id + " seed matched nothing - hidden field markup changed");
  }
  put("MKind", c.kind);
  put("MHead", c.head);
  if (c.body) put("MBody", c.body.replace(/\n/g, "&#10;"));
  if (c.rows) put("MRows", c.rows);
  // Same &#10; encoding MBody uses: a note can carry \n\n too (the post-run
  // report's note is a selection note and a toolpath note joined by one), and
  // an unencoded newline inside an attribute is not worth relying on.
  if (c.note) put("MNote", c.note.replace(/\n/g, "&#10;"));
  put("MVersion", "v1.8.0");
  s = s.replace("</head>", "<style>html,body{height:" + viewH + "px !important;" +
    "width:" + MSG_VW + "px !important;} body{position:relative !important;}</style></head>");
  s = s.replace("</body>", "<script>setTimeout(function(){" +
    "var sc=document.getElementById('Scroll'), ok=document.getElementById('ButtonOK');" +
    "var kids=sc.children, top=sc.getBoundingClientRect().top, low=0;" +
    "for(var i=0;i<kids.length;i++){var b=kids[i].getBoundingClientRect();" +
    "if(b.height>0&&b.bottom>low)low=b.bottom;}" +
    "var real=Math.round(low-top)+20;" +
    "var over=real-sc.clientHeight;" +
    "var r=ok.getBoundingClientRect();" +
    "document.title='MSG over='+over+' content='+real+' avail='+sc.clientHeight+" +
    "' okBottom='+Math.round(r.bottom)+' viewH=" + viewH + "';" +
    "},1200);</script></body>");
  return s;
}

MSG_CASES.forEach(function (c) {
  var viewH = (c.tall ? MSG_H_TALL : MSG_H_SHORT) - FRAME_H;
  var f = path.join(tmp, "msg_" + c.name.replace(/[^a-z0-9]/gi, "_") + ".htm");
  fs.writeFileSync(f, msgSeed(c, viewH));
  var out = cp.execFileSync(CHROME, [
    "--headless=new", "--disable-gpu", "--hide-scrollbars",
    "--virtual-time-budget=4000",
    "--window-size=" + MSG_VW + "," + viewH,
    "--dump-dom", "file:///" + f.replace(/\\/g, "/")
  ], { encoding: "utf8", maxBuffer: 40 * 1024 * 1024 });

  var m = /MSG over=(-?\d+) content=(\d+) avail=(\d+) okBottom=(\d+) viewH=(\d+)/.exec(out);
  if (!m) { console.log("FAIL  " + c.name + "  (no measurement - page error?)"); failed++; return; }

  var over = +m[1], content = +m[2], avail = +m[3], okBottom = +m[4], viewH2 = +m[5];
  var bad = [];
  if (over > 0) bad.push("message overflows its window by " + over + "px");
  if (okBottom > viewH2) bad.push("OK button below the fold");
  if (over <= 0 && (avail - content) < MIN_SLACK)
    bad.push("only " + (avail - content) + "px slack, want >= " + MIN_SLACK);

  // The banner must actually be wearing the class Lua sent. A message coloured
  // as a success when the run died is the one defect here that a person would
  // not notice was a defect.
  if (out.indexOf('id="Ban" class="' + c.kind + '"') === -1)
    bad.push("banner is not wearing class " + c.kind);

  // innerText, not innerHTML. If this fails the page is interpreting Lua's
  // strings as markup and an Aspire error string could break the layout.
  // Scoped to #RowsBody, not the whole dump: the seed hidden field's own
  // value="" attribute is always HTML-escaped by Chrome's serializer
  // regardless of what cellText does with it downstream, so a whole-page
  // search finds the escaped text there even when the row cell itself
  // renders real markup -- caught by Step 4's mutation check, which this
  // scoping was added to make actually fail.
  if (c.expectLiteral) {
    var rb = /<tbody id="RowsBody">([\s\S]*?)<\/tbody>/.exec(out);
    var rowsOut = rb ? rb[1] : "";
    if (rowsOut.indexOf(c.expectLiteral) === -1)
      bad.push("expected the literal text " + c.expectLiteral + " - the page treated it as markup");
  }

  console.log((bad.length ? "FAIL  " : "ok    ") + c.name +
    "  content " + content + " / " + avail + " avail, slack " + (avail - content) + "px" +
    (bad.length ? "  <-- " + bad.join("; ") : ""));
  if (bad.length) failed++;
});

// ---- Source check: every <svg> is clipped, and sized in pixels -----------
// Neither rule can be measured here, only read, because Chrome gets both right
// and Trident does not.
//
// overflow="hidden" is the PROVEN one (setup dialog, live 2026-07-27): Trident
// does not clip SVG text to the viewport and counts the unclipped extent in the
// ancestor's scrollWidth/Height, so two chart labels sitting near the edges made
// #Scroll measure 2520x785 inside a 1781x749 box -- both scrollbars, in a dialog
// where every rendered case here passed. Chrome clips SVG by default, which is
// exactly why no amount of new rendered cases can catch this class.
//
// Pixel width is belt-and-braces rather than a proven cause: it was the first
// suspect and made no difference to the measurement either way. Kept because
// Trident's SVG sizing is not worth trusting once it has been caught out.
console.log("");
["EdgeBreakerDialog.htm", "MessageDialog.htm"].forEach(function (name) {
  var src = fs.readFileSync(path.join(__dirname, "..", "gadget", "EdgeBreaker", name), "utf8");
  var svgs = src.match(/<svg\b[^>]*>/g) || [];
  var pct = svgs.filter(function (t) { return /\bwidth\s*=\s*"[^"]*%"/.test(t); });
  var open = svgs.filter(function (t) { return !/\boverflow\s*=\s*"hidden"/.test(t); });
  if (pct.length || open.length) {
    if (pct.length) console.log("FAIL  " + name + "  percentage width on <svg>: " + pct.join(" "));
    if (open.length) console.log("FAIL  " + name + "  <svg> without overflow=\"hidden\": " + open.join(" "));
    failed++;
  } else {
    console.log("ok    " + name + "  " + svgs.length + " svg(s), all clipped and pixel-width");
  }
});

console.log("");
if (failed) { console.log(failed + " layout failure(s)."); process.exit(1); }
console.log("All layouts fit.");
