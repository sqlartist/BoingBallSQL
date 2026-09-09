# The Day My Database Learned Physics

## Putting the Amiga Boing ball inside SQL Server, and what broke when I added a second one

I've spent the last few months putting things inside SQL Server that have no business being there. Doom renders E1M1 from a database. Elite generates its galaxy, flies its ships and docks at a Coriolis station in T-SQL. Daley Thompson's Decathlon runs on a Z80 emulator I wrote in stored procedures, loading from a real Microdrive image.

So when I turned to the Amiga Boing ball, I assumed it'd be the easy one. A bouncing checkered sphere. No BSP tree, no galaxy generator, no cycle-accurate anything.

It was the easy one. Right up until I added a second ball, at which point it taught me something about SQL that four bigger projects hadn't.

---

## Three ways to do it, and why I picked the middle one

The first decision was which version of "the Boing ball" I was actually building, because there are three, and they're wildly different jobs.

The most faithful option is to emulate a 68000 and the Amiga chipset and boot the original demo from its bootblock. Having just written a Z80 core, I knew roughly what that costs, and it's an order of magnitude more: a much heavier instruction set, plus the Copper and the Blitter, before a single pixel appears. That's a project, not a weekend.

The most historically honest option is stranger. The 1984 demo doesn't render a 3D ball at all. Dale Luck and RJ Mical drew one static checkered sphere and made it appear to spin by cycling the colour registers. The bitmap never changes. Only the palette does.

I loved that, because it's already a database idea. Rotation isn't animation, it's a lookup against a different row set. They were doing a join in 1984; they just didn't have anywhere to put it.

But I picked the third option: render the thing honestly, analytically, from scratch. Not because it's more authentic — it's less — but because it plays to what SQL is actually good at, and I wanted to see how far that went.

Here's the thing about a sphere. It's a closed-form intersection. Under orthographic projection you don't need a discriminant, you don't need clipping, you don't need to rasterise a polygon. You need `d² = dx² + dy²`, and if that's inside the radius, you've hit it. Everything else is a normal, two rotations and a checkerboard.

That's pure arithmetic on a grid of pixels. Which is to say: it's a `SELECT`.

---

## The bit I was pleased with

The ball's motion is also closed form. Position is a function of the frame number — a triangle wave for the horizontal sweep, a parabola for the bounce, and spin proportional to how far it's travelled, which means the spin reverses at the walls on its own without me writing any logic for it.

No state. Nothing depends on the previous frame.

So frames aren't a loop. Frames are just another dimension of the cross product.

The entire animation — 64 frames, 320×256, five and a bit million pixels — comes out of one `INSERT ... SELECT`. No recursive CTE, no `WHILE`, no cursor, no temp table. A chain of `CROSS APPLY`s you read top to bottom like a shader.

I sat looking at that for a while. It's the most SQL-shaped thing I've built in this whole series. Doom needed a client and a game loop. Elite needed a flight model with state. This is one query that produces a cartoon.

Two things bit me on the way, both worth knowing.

T-SQL has no float modulo. `%` is integer only, so every wrap has to be written out longhand as `a - FLOOR(a/m)*m`. Mildly annoying, easily forgotten.

The other one is nastier and I'll be carrying it back into my day job. I guarded a `SQRT` with a `CASE` so it'd never see a negative argument. It threw anyway. SQL Server doesn't promise to short-circuit `CASE` — the optimiser can evaluate the expression before the predicate that was supposed to protect it. The fix is to make the maths unconditionally safe with an `ABS` and throw the result away later. That's a genuine production trap dressed up as a toy problem, and I'd never have found it writing normal queries.

---

## Then: two balls

This is where it got interesting, and where I learned the actual lesson.

Add a second ball and it's still one query. Add *collision* between them and the whole edifice comes down.

Not because the physics is hard. It's the easiest physics there is — equal masses, elastic, exchange the normal component of velocity and push them apart if they've overlapped. Twenty lines in any language.

It comes down because collision response depends on the *previous step*. Where ball one is at frame 40 depends on whether it hit ball two at frame 39. Position is no longer a function of the frame number, and the moment that's true, frames stop being a dimension you can join to and start being a sequence you have to walk.

One collision. That's all it took to destroy the property the entire design rested on.

I found that genuinely instructive, and it's the reason I'm writing this up rather than the bigger projects. Every SQL developer gets told "think in sets, not loops" and nobody ever shows them the boundary. Here's the boundary, and it's razor thin. Closed form: one statement, five million rows, no loop. Add one dependency on prior state: nothing survives.

---

## Not fighting it

The decision I'm happiest with is that I stopped trying to be clever.

My first instinct was to keep everything declarative with a recursive CTE. That's the party trick, and it nearly works. But the recursive member can only reference the CTE once, and pairwise collision needs a self-join. You can dodge it by cramming both balls into a single wide row — and then you've hard-coded it to exactly two balls forever, and because subqueries and `APPLY` aren't allowed in there either, every intermediate term has to be re-expanded inline. Distance computed eight times over. Unreadable, unmaintainable, and permanently stuck at two.

So I split the thing along the line where the two halves genuinely differ.

Simulation is sequential, and I stopped pretending otherwise. It's a `WHILE` loop. It's also tiny — a handful of rows and a few hundred substeps — so it costs nothing. Four set-based statements per step: gravity and integration, wall reflection, then a pairwise contact resolution written as a self-join with the impulses summed per ball.

Rendering stayed set-based. It's still one statement. It just no longer works out where the balls are; it joins to where the simulator says they were.

That's the whole architecture, and I think it's the right one. The worse SQL made the better artefact.

Because the collision is written pairwise rather than as a special case for two, it takes any number of balls. I added a third by inserting a row. That's it. One row in a table, and three balls bounce off each other and off the walls with correct depth ordering, because two spheres at the same depth with the same radius resolve trivially — whichever pixel is deeper into its own silhouette is the one in front.

Getting that for free was the moment the design decision paid for itself.

---

## So what's it actually for?

Let me be straight: it isn't a production technique. Nobody should render anything in a database. If that's the bar, this is all a waste of time.

It's useful for three other things, and I think they're real.

It's the best teaching device for set-based thinking I've come across. Not the concept — everyone's heard the concept — but the *edge* of it. Boing is a perfect miniature. Here's a closed-form problem, and it's one beautiful statement. Here's the same problem with one sequential dependency, and it's a loop. Nothing else I've built shows that transition so cleanly, because in a real system the two are always tangled together.

It finds engine behaviour that ordinary work never will. The `CASE` short-circuit trap is going straight into my mental checklist. Pushing an engine into a shape it was never designed for is how you learn where its real edges are, and those edges show up later in queries that matter.

And it's a learning challenge in the oldest sense. There's no spec, no acceptance criteria, and nobody's asking for it. You just have to work out whether the thing is possible and then find out.

There's a wider ambition behind it too. If you can emulate a machine inside a database, you can put the games in as data — cartridge images in `varbinary`, the machine as stored procedures — and you've got an archive that runs what it stores. A shelf of 1980s software living inside the same engine that's serving your reports. I don't know yet whether that's a good idea. I know it's a good problem.

---

## Where the limit is

People keep asking whether the ceiling is Quake or a C64. I think that's the wrong axis.

The real question is the ratio of *wide* work to *deep* work. Wide work — per pixel, per vertex, per entity — is what SQL is extraordinary at. Deep work, where each step depends on the last, is what it's terrible at. Everything I've built lands somewhere on that spectrum, and where it lands predicts how well it goes far better than what decade the game came from.

By that measure Quake isn't the wall people assume. Its renderer is overwhelmingly wide work. Emulating a 68000 with a full custom chipset is almost entirely deep work, and that's where it dies.

Boing is the extreme wide case, which is why it came out as one query. And the second I introduced a single dependency on prior state, it stopped being one.

Two balls taught me more than Doom did.
