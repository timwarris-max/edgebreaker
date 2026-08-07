# EdgeBreaker

Break an edge with a V-bit: select closed vectors, pick a bit, enter a
chamfer size, choose where on the flute to cut. The gadget draws offset vectors
into the waste and creates a Profile "On" toolpath at the exact depth — the
tip and its flat ride in air beside the wall instead of dragging through your cut.

**Runs in Aspire and VCarve Pro.** I built and tested it in Aspire 12, and
someone's now run it in VCarve Pro 12.5. There's nothing in it that needs either
one in particular — it draws vectors, offsets them and makes a Profile toolpath —
so older versions should be fine too. I just haven't tried them. Tell me how you
get on and I'll say so here.

> Through v1.4.x this gadget was called **ChamferOffset**. Same gadget, new name.
> Jobs built with the old version still work — see
> [Chamfers from older versions](#chamfers-from-older-versions).

## Quick start (60 seconds)

1. Double-click `EdgeBreaker-v*.vgadget` to install, then restart Aspire or VCarve.
   Windows may warn you about the file when you download it. That's only because
   it's new and not many people have it yet — choose Keep, then open it.
2. Open a job, select the closed vector(s) to chamfer.
3. Gadgets menu → EdgeBreaker. The dialog opens with a coloured banner telling you
   what it's about to do. **Choose your V-bit** (it opens on the bit you used last),
   enter the chamfer size, pick a cut position, press OK.
4. The gadget draws orange offset vectors and creates a calculated
   `Chamfer ... [EdgeBreaker 01]` toolpath. A clean run shows you nothing at
   all — the toolpath in the Toolpaths panel and the orange offsets on the
   canvas are the confirmation. You only get a message when there is something
   to act on: a shape too narrow to chamfer, a vector skipped, a remembered
   shape that has gone, or a toolpath that could not be created.
5. Not what you wanted? Just run it again. Your vectors are still selected, so
   the banner says **Rebuilding Chamfer 1** and that chamfer's settings are
   already loaded.

**Stuck at the machine?** The **Help** button at the bottom of the dialog opens this
guide in a browser window. It's a copy that ships with the gadget, so it works with
no internet.

## Updating

Same as installing. Download the latest `EdgeBreaker.vgadget`, double-click it,
restart Aspire or VCarve. It installs over the old copy — there's nothing to
uninstall first.

Your work is untouched. Existing chamfers live in the job file and come back
exactly as they were, and your last-used settings are kept.

The gadget doesn't check for updates, so it stays on the version you installed
until you do this. **The version is printed at the top of the dialog**, next to
the name — that's how to tell what you're on.

## How it decides what to build

**The selection decides.** Before it asks you anything, EdgeBreaker looks at what
you have selected and opens ready to do the obvious thing. The banner at the top
of the dialog names it, in colour, and the OK button repeats it — so a run that
would destroy something says so before you press anything.

| What you have selected | Banner | What OK does |
|---|---|---|
| Shapes no chamfer uses | **Green — Adding Chamfer N** | Creates a new chamfer. Nothing existing is touched. |
| Shapes an existing chamfer was built from | **Blue — Rebuilding Chamfer K** | Rebuilds K, with K's own size, side and cut position already loaded. Selecting *some* of its shapes is enough. |
| Nothing | **Blue — Rebuilding Chamfer K, nothing selected** | Rebuilds K from the shapes it remembers. |
| Shapes a chamfer *should* know but doesn't | **Amber — I don't know which shapes** | Rebuilds it on your selection, and this run teaches it. |
| A chamfer you picked by hand, holding different shapes | **Red — Replacing Chamfer K's shapes** | Removes K's offsets and toolpath and rebuilds them on the new shapes. Cannot be undone. |

Two more things it works out on its own:

- **A mixed selection** — some free shapes, some already owned by another
  chamfer — adds a new chamfer from the free ones and says how many it left out.
- **Your own orange offsets** caught up in a box-select are ignored, not refused.
  Box-selecting everything and re-running is the natural way to adjust a chamfer,
  and it works.

You are never stuck with its guess: the **Change** dropdown in the banner picks
any chamfer in the job (or "New chamfer"), and the banner re-colours to match.

**With nothing selected**, EdgeBreaker rebuilds the newest chamfer — unless you
single-click a chamfer's toolpath in the Toolpaths list first, which names the
one you mean. A selection always outranks a highlighted toolpath.

## Where on the flute you cut

EdgeBreaker doesn't cut on your line. It draws a new line a little way out into
the waste and cuts that one — and **`G` is how far out**. The dialog calls it the
standoff.

That gap is the whole trick. Push the cut further into the waste and the V-bit has
to go deeper before its slanted face reaches your edge. Same chamfer, deeper
plunge, and a higher spot on the flute doing the work.

That's what the **0%–100%** buttons pick. **0%** is the smallest gap — the cut sits
low, just clear of the tip. **100%** is the largest — up near the top of the flute.
Cutting high uses fresh, wide flute instead of the tip, which is a point that
barely cuts and wears out first. You pay for it in depth, and each button shows the
depth it needs, so take the highest one your bit and your stock can reach.

Both ends of the range are there to keep the cut off the two spots a V-bit cuts
badly: the tip, and the shoulder where the flute runs out. A chamfer eats into the
top of that range, so past a certain size there's nothing left in between and the
bit can't take it in one go. So it takes it in several.

## Big chamfers

Ask for a chamfer bigger than the bit can manage in one bite and EdgeBreaker cuts
it in more than one pass rather than refusing. You type the size you want; it works
out how many passes that takes. The dialog says how many, and how much flute each
one uses, and draws the earlier passes ghosted into the section view.

**Cut them in order, top down.** They come out named `pass 1 of 3`, `pass 2 of 3`
and so on, in that order in the Toolpaths panel, and the order isn't a preference.
Every pass but the last cuts with the tool sitting out over the part, and what
keeps its flute clear is the material the pass above has already taken off. Run
them backwards and you're burying the bit again, which is the thing the extra
passes are there to avoid.

That's also why a thin rib or a narrow neck can't take a big chamfer at all —
there's nothing there for the upper passes to sit over. Those get skipped and
counted, same as always.

You may see faint lines across the face where the passes meet, one fewer than the
number of passes. They sand out. A bigger bit does the whole thing in one pass with
none, so if you have one, use it.

Each pass draws on its own layer: `EdgeBreaker Offset 01-1`, `01-2`, `01-3` for a
three-pass Chamfer 1, cleared and redrawn every run like any other.

Eight passes is the ceiling. Past that it won't build, and says instead what the
biggest chamfer this bit will take is, and the smallest bit that would cut the one
you asked for.

## Start depth

**Start depth is how far below the top of the stock the edge sits** — a pocket
floor, a second level, a top you have already skimmed. Leave it at **0** for an
edge at the top of the material, which is the usual case.

It does not change the chamfer itself. The size, the cut position and the bit
geometry all describe the bit against the edge, and that relationship is the same
wherever the edge happens to sit — a start depth simply moves the whole cut down.
So the machine reaches **start depth + cut depth** into the material, and that
total is what the depth-vs-stock warning measures and what the section view draws.

Each chamfer remembers its **own** start depth, and a **new** chamfer always opens
at 0. Unlike the chamfer size, it is deliberately not carried over from your last
run: a leftover 0.25 in from yesterday's pocket applied to today's flat job would
cut a quarter inch too deep without looking wrong on screen.

## Sharp corners

A chamfer's corners normally come out rounded — at one depth, the bit can only
get so far into a corner. Tick **Sharp corners** and the bit rises as it drives
into each corner, so the two edges meet in a crisp point.

There's a depth limit on it: the machine won't sharpen deeper than the bit's
cutting edge. If your chamfer is close to that, EdgeBreaker drops the cut
position lower to make it fit — and says so under the cut position buttons. Too
big for even that and the box greys out: use a smaller chamfer, or a bigger bit.

- It works on any Chamfer side. Past the point where the bit runs out, Aspire's
  own chamfer engine takes over, and if you've picked shapes that sit inside
  other shapes — letters with counters, a part with holes — it works out each
  side for itself and the Side buttons grey out. Pick shapes with nothing inside
  each other and Side is yours as usual.
- **Chamfering a pocket? Set Side to Inside.** A pocket and a raised shape look
  the same to EdgeBreaker — one closed line either way — so Auto assumes the
  material is *inside* your line. Right for letters and islands, wrong for a
  hole. If a chamfer comes out with a step in it, that's the first thing to
  check.
- Raised letters are one chamfer now: select the lot, leave Side on **Auto**, tick
  the box. It works out which way each shape goes — outward round the outlines,
  inward into the counters — and the corners come out sharp on both.
- Two chamfers is still how you do it when you want the outlines and the counters
  cut *differently*. It's a choice now, not a workaround.
- On an **Outside** chamfer the guide line is drawn inside the shape, so anything
  narrower than two chamfers gets skipped and counted with the other too-narrow
  ones. Go smaller and it fits.
- Each chamfer remembers its own setting, so a rebuild keeps what you chose —
  whether you select its shapes or rebuild with nothing selected. The one time
  it can't is when the shapes sit inside each other, like an outline and its
  hole: Aspire picks the side there, and the run tells you when that happens.
- The corner moves cut closer to the bit's tip than the position you picked —
  that's the only way into a corner, and it's a tiny share of the cut.
- The orange line sits a touch over on the material side of your edge on
  purpose: that's the line the machine steers by, not the cut. The cut still
  lands exactly where it always does.

## Big sharp chamfers

Sharp corners used to stop working past what the bit could sharpen in one flat
pass. Now they don't stop - past that point EdgeBreaker hands the cut to
Aspire's own chamfer engine, which runs the tip of the bit down the corner line.
The trade: you give up the cut-position buttons for that chamfer, because the
cut has to come off the tip. The dialog greys them and says so. Smaller
chamfers keep working exactly as before, cut position and all.

## What a chamfer remembers

Each chamfer stores, on its own toolpath, the shapes it was built from and the
settings that built them — size, mode, side, cut position, start depth and units.
That is what
makes the table above work: recognising your selection, reloading the right
numbers, rebuilding from memory when nothing is selected.

- It travels **inside the job file**, so it survives save/close/reopen and moves
  with the job to another machine. **Save the job** to keep it.
- Delete a chamfer's toolpath and it is forgotten — which is also how you free
  its number for reuse.
- Edit or move a remembered shape and the gadget stops recognising it (shapes are
  matched by size and position). You get the amber "teach me" banner; rebuilding
  from your selection fixes it.
- **The bit is the exception.** There's no way to store a tool identity in
  text, so each chamfer's bit is remembered in the software's own settings **on
  this PC**, not in the job. Open the same job on another machine and the picker
  offers the last bit you used there, not that chamfer's. Everything else travels.

## The section view

The right-hand side of the setup dialog draws the cut you are about to make, in
section, and redraws it as you type: the stock, the bevel it will leave, the
V-bit that cuts it, and the four numbers that describe it — `W` the chamfer
width, `D` the plunge depth, `G` the standoff, and `S` the start depth when the
edge sits below the top of the stock.

The stock is schematic, not to scale. Drawing a 0.02 in chamfer against 0.75 in
of real stock would make the chamfer 3% of the picture and tell you nothing;
whether the cut is too deep for the material is answered in words by the warning
directly above the drawing.

On any bit that isn't 90°, a small corner detail sits at the right-hand end of the
drawing. It's the corner blown up, with the edge you're sizing picked out in orange
and named underneath — `SETBACK` across the top face, `FACE` along the slant, `LEG`
down the side — and the number you typed below that.

It's a sketch, not a scale drawing. At the main drawing's scale your chamfer is a
sliver a few percent of the bit's reach, so all three edges land on top of each other
with nowhere to put a label. The true angle and every real number are on the drawing
right beside it.

A 90° bit doesn't get one — at 90° the setback and the leg are the same measurement,
so there's no choice to explain.

## More than one chamfer in a job

A job can hold up to 99 chamfers, each with its own bit, size and cut position —
a fine chamfer on the lettering and a heavier one on the outline, say.

Each chamfer keeps its own offset layers (`EdgeBreaker Offset 01-1`, `02-1`, …) and
its own toolpath marker (`[EdgeBreaker 01]`). A run clears and rebuilds **only its
own number**; every other chamfer is left exactly as it was, and the banner says
which ones those are before you press OK.

## Chamfers from older versions

Chamfers built by **ChamferOffset v1.4.x** are adopted. They keep their number and
their size, but not their shapes — nothing recorded them at the time — so the first
time you rebuild one you get the amber "teach me" banner and your selection becomes
its shapes. That rebuild also renames its layer and toolpath to the EdgeBreaker
names, and removes the old ones.

Chamfers from **before v1.4.0** (the unnumbered `ChamferOffset - Offset` layer, or a
toolpath tagged plain `[ChamferOffset]`) are *not* adopted. The gadget says once
that it found one and then leaves it alone entirely — never listed, never replaced,
never deleted. Remove it by hand if you don't want it.

## Bits come from your tool database

There is nothing to add to this gadget. Any V-bit defined in your tool
database is offered, and its angle, diameter, **feeds, speeds and tool number
are used exactly as the database has them** — so a chamfer is cut with the same
numbers as the rest of your job, and you change them in one place.

A bit in millimetres is fine in an inch job (and vice versa); the diameter is
converted.

**If Select is greyed out** with a bit highlighted, that bit has no feeds and
speeds for the machine named at the top of the tool database dialog. Press
**Copy** under "Copy Settings From", then **Apply**. This is the software refusing to
hand over a tool it has no cutting data for — not a gadget fault.

## The strategy template

The gadget ships one file, `EdgeBreaker.ToolpathTemplate`, which supplies only
the *strategy*: Profile, **Machine Vectors: On**, restricted to the layer
`EdgeBreaker - Offset 01`. It exists because the software will not accept a template
this gadget wrote itself. The bit inside it is irrelevant — it is swapped for
the one you picked, and so is the depth.

So is the layer: building Chamfer 3 rewrites the restriction to
`EdgeBreaker Offset 03-1`, and again for each further pass, before the template is
loaded. The new name is exactly as long as the one it replaces, so it goes in
place and nothing else in the file moves. The gadget then reads the name back out
to confirm it before handing it over, and refuses to build rather than cut a layer
it did not aim at.

You should never need to touch this file. If you do re-create it, it must be
restricted to **`EdgeBreaker - Offset 01`** — the whole name matters, because that
is the text the gadget finds and rewrites. The **Selector ...** step is not
optional either: without it the toolpath gets bound to whatever is selected when
it recalculates, and loops silently drop out. The job's units don't matter —
inch or metric, the gadget converts.

## Notes

- The layers `EdgeBreaker Offset 01-1`, `02-1`, … are gadget-owned. Building a
  chamfer clears **its own** layer and no other, and gadget deletions cannot be
  undone — never keep your own work on one.
- Vectors must be **closed**. Outer boundaries offset outward, holes inward,
  automatically.
- A feature too narrow to chamfer at the size you asked for is **skipped**, not
  approximated: the offset collapses it to nothing, and it comes back with no
  orange offset beside it. A skip is one of the things that breaks the silence —
  you get a message naming the count. Ask for a smaller chamfer, or cut nearer
  the tip, and more of them will fit. Before v1.3.0 these came back inside-out and
  cut a slot down the middle of the feature.
- One vector can produce **more than one** offset vector. Where an inward offset
  pinches a neck closed, the offset cuts the loop at the crossing and the valid
  pieces come back as separate closed loops — so the drawn count need not match
  what you selected.
- The gadget owns every toolpath whose name contains `[EdgeBreaker NN]`, and a
  run only touches its own number: building Chamfer 2 deletes and recreates
  `[EdgeBreaker 02]` and leaves `[EdgeBreaker 01]` alone.
  **Toolpath deletions cannot be undone.** To keep a chamfer toolpath forever,
  rename it so the marker is gone — the gadget will never touch it again, and it
  also forgets everything that chamfer remembered.
  Renaming it to a *different* number hands it to that chamfer instead.
- The gadget calculates its own toolpath and leaves your other toolpaths
  alone. If the software refuses the single-toolpath calculation, the message says
  so — then open the toolpath and click Calculate yourself.
- A chamfer with no memory of its own falls back to your **last run's** entries,
  kept in `%APPDATA%\EdgeBreaker-settings.txt` (a `ChamferOffset-settings.txt`
  left by an older version is still read). Anything that no longer applies falls
  back to the default — a size from an inch job when the open job is metric.
  Delete the file to start fresh.
- **Size the window how you like.** Drag a corner — EdgeBreaker remembers it, so
  it opens that size again next time. It keeps one size for your main screen and
  a separate one for a second monitor, so moving Aspire between them never
  messes up either.
- **Depth warning.** A shallow-angle V-bit plunges a long way for a small
  chamfer — a 12.4° bit needs 0.90 in of depth for a 0.020 in chamfer. If the
  cut would go deeper than the stock thickness in Job Setup, the dialog says so
  and names the flute position that fits. It warns, it does not block, and it
  stays quiet when Job Setup has no thickness.

**"Chamfer's too big for this artwork"**

Your chamfer takes a bite out of both sides of every wall, so a thin stroke or
a tight junction can get cut away completely. EdgeBreaker checks before it cuts
and stops if that would happen — and tells you the biggest size that fits.

Older versions cut it anyway and said nothing.

One thing it can't see: a thin arm that stays attached. That comes out as a
sharp ridge rather than a flat, and the check won't catch it.
