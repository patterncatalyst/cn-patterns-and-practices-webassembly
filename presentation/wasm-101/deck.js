// deck.js: "Server-Side WebAssembly" 101 (the ideas).
// Concept/why/landscape deck. Lead headline: the Component Model + WIT as the
// contract spine. No deep code; that's the 201s (wasm-201-rust, wasm-201-go).
// Red Hat house style, 16:9. Build: node deck.js
"use strict";

const H = require("./deck-helpers.js");
const {
  COLOR, FONT, W, PNG, ASSETS,
  newDeck, addFooter, addContentTitle, addBullets,
  addStatusTable, addCaption,
  addDiagramSlide, addSectionDivider, addNotes,
} = H;

const OUT = "wasm-101-r1.1.pptx";
const REV = "r1.1";

const pres = newDeck();
pres.title = "Server-Side WebAssembly: 101 (the ideas)";
let pageNum = 0;
let notesCount = 0;

function S() { const s = pres.addSlide(); pageNum += 1; addFooter(s, pageNum); return s; }
function divider(code, title, subtitle, notes) {
  const s = pres.addSlide(); pageNum += 1; addSectionDivider(s, code, title, subtitle); addNotes(s, notes); notesCount += 1;
}
function notes(slide, text) { addNotes(slide, text); notesCount += 1; }

// ---- local helper: bold-lead bullets (bold subject run + normal text run) ----
function leadBullets(slide, items, opts = {}) {
  const x = opts.x ?? 0.62, y = opts.y ?? 1.95, w = opts.w ?? 12.09, h = opts.h ?? 4.7;
  const fontSize = opts.fontSize ?? 17;
  const runs = [];
  items.forEach((b) => {
    const lvl = b.lvl || 0;
    const para = {
      fontFace: FONT.body, fontSize: lvl ? fontSize - 1 : fontSize,
      bullet: { code: lvl ? "25E6" : "25CF", indent: 18 }, indentLevel: lvl,
      paraSpaceBefore: lvl ? 0 : 4, paraSpaceAfter: lvl ? 7 : 13,
    };
    const color = b.color || (lvl ? COLOR.caption : COLOR.body);
    if (b.lead) {
      runs.push({ text: b.lead, options: { ...para, bold: true, color: COLOR.ink } });
      runs.push({ text: (b.sep === undefined ? ": " : b.sep) + b.text, options: { fontFace: FONT.body, fontSize: para.fontSize, color, breakLine: true } });
    } else {
      runs.push({ text: b.text, options: { ...para, color, breakLine: true } });
    }
  });
  slide.addText(runs, { x, y, w, h, valign: "top", margin: 0, lineSpacingMultiple: 1.12 });
}

// Claim-bearing subtitle under a short noun-phrase title.
function addSubtitle(slide, text, opts = {}) {
  slide.addText(text, {
    x: opts.x ?? 0.62, y: opts.y ?? 1.42, w: opts.w ?? 12.09, h: opts.h ?? 0.46,
    fontFace: FONT.body, fontSize: 15, italic: true, color: COLOR.caption,
    align: "left", valign: "top",
  });
}

// A content slide: short noun-phrase title + claim subtitle + bold-lead bullets.
function titledSlide(eyebrow, title, subtitle, items, slideNotes, opts) {
  const s = S();
  addContentTitle(s, eyebrow, title, { h: 0.62 });
  addSubtitle(s, subtitle);
  leadBullets(s, items, { y: 1.98, h: 4.55, ...(opts || {}) });
  notes(s, slideNotes);
  return s;
}

// A pure diagram slide: title + subtitle + centered figure + caption.
function diagSlide(eyebrow, title, subtitle, png, caption, slideNotes, opts = {}) {
  const s = S();
  addContentTitle(s, eyebrow, title, { h: 0.62 });
  addSubtitle(s, subtitle);
  const x = opts.x ?? 1.80, y = opts.y ?? 2.05, w = opts.w ?? 9.74, h = opts.h ?? 4.45;
  s.addImage({ path: `${PNG}/${png}.png`, x, y, w, h, sizing: { type: "contain", w, h } });
  if (caption) addCaption(s, caption);
  notes(s, slideNotes);
  return s;
}

// Diagram left (~50%), bold-lead framing bullets right: for figures that need narration.
function diagBulletsSlide(eyebrow, title, subtitle, png, items, slideNotes) {
  const s = S();
  addContentTitle(s, eyebrow, title, { h: 0.62 });
  addSubtitle(s, subtitle);
  const maxW = 6.15, maxH = 4.40, x0 = 0.62, y0 = 2.05;
  s.addImage({ path: `${PNG}/${png}.png`, x: x0, y: y0, w: maxW, h: maxH, sizing: { type: "contain", w: maxW, h: maxH } });
  const bx = x0 + maxW + 0.35;
  leadBullets(s, items, { x: bx, y: y0 + 0.05, w: W - 0.62 - bx, h: maxH, fontSize: 14 });
  notes(s, slideNotes);
  return s;
}

// Two-column bold-lead bullets, no diagram: for the glossary.
function twoColLeadSlide(eyebrow, title, left, right, slideNotes) {
  const s = S();
  addContentTitle(s, eyebrow, title, { h: 0.62 });
  leadBullets(s, left, { x: 0.62, y: 1.60, w: 5.90, h: 5.00, fontSize: 15 });
  leadBullets(s, right, { x: 6.80, y: 1.60, w: 5.90, h: 5.00, fontSize: 15 });
  notes(s, slideNotes);
  return s;
}

// A reference table slide (version/pin matrix); no subtitle, data speaks for itself.
function tableSlide(eyebrow, title, rows, slideNotes, opts = {}) {
  const s = S();
  addContentTitle(s, eyebrow, title);
  addStatusTable(s, rows, { y: 1.55, rowH: 0.42, colW: [1.55, 3.10, 7.44], ...opts });
  notes(s, slideNotes);
  return s;
}

// ===== COVER =================================================================
{
  const s = pres.addSlide(); pageNum += 1;
  s.background = { color: COLOR.white };
  try { s.addImage({ path: `${ASSETS}/cover-panel.png`, x: 0, y: 0, w: W, h: 7.5 }); } catch (e) {}
  s.addText("SERVER-SIDE WEBASSEMBLY · 101", { x: 6.00, y: 1.98, w: 6.90, h: 0.34,
    fontFace: FONT.title, fontSize: 14, bold: true, color: COLOR.red, charSpacing: 5, align: "left", valign: "middle" });
  s.addText([{ text: "Server-Side", options: { breakLine: true } },
             { text: "WebAssembly" }], {
    x: 5.95, y: 2.42, w: 6.95, h: 2.00, fontFace: FONT.title, fontSize: 50, bold: true, color: COLOR.ink, align: "left", valign: "top" });
  s.addText("The Component Model and WIT as the contract spine: one package, two languages, two runtimes, two verified clusters.",
    { x: 6.00, y: 4.55, w: 6.80, h: 1.25, fontFace: FONT.body, fontSize: 16, italic: true, color: COLOR.caption, align: "left", valign: "top" });
  s.addText(REV, { x: 11.85, y: 6.10, w: 0.95, h: 0.30, fontFace: FONT.mono, fontSize: 11, color: COLOR.caption, align: "right", valign: "middle" });
  try { s.addImage({ path: `${ASSETS}/logo-candidate-2.png`, x: 11.10, y: 6.78, w: 1.55, h: 0.37 }); } catch (e) {}
  notes(s, "This is the 101, the ideas deck for server-side WebAssembly. The headline claim is that a WIT contract, not a protocol or a cloud provider's SDK, is what makes a component portable: the same patterncatalyst:cargo package, implemented once in Rust and once in Go, runs unmodified under wasmtime, under a wasmCloud lattice, and on two Kubernetes clusters. This deck stays at the concept level: the case for a component over a container, the Component Model and WIT, capabilities in place of ambient authority, and the runtime and cluster landscape. The code that makes each of those claims concrete lives in the two 201 decks, one per language. What to show: hold on the cover title for a beat before moving to the agenda. If presenting without slides, open by stating the one-sentence claim in the subtitle verbatim; it previews every section that follows.");
}

// ===== AGENDA ================================================================
{
  const s = S();
  addContentTitle(s, "101 · THE IDEAS", "Five Acts, One Appendix");
  leadBullets(s, [
    { lead: "The Case", text: "why a component, not another container, on cold start, density, isolation, and where it loses." },
    { lead: "The Contract Spine", text: "the Component Model and WIT, covering worlds, interfaces, and capability-scoped WASI." },
    { lead: "One Contract, Two Languages", text: "Rust and TinyGo compiling the identical world into interchangeable components." },
    { lead: "The Substrates", text: "wasmtime, wasmCloud, and Kubernetes, three ways to run the same bytes." },
    { lead: "Deviations and the Final Project", text: "three substitutions on the stack, then both languages proven at once." },
    { lead: "Appendix", text: "the version matrix, a glossary, and reference links, kept open in another window." },
  ], { y: 1.95, h: 4.7, fontSize: 16 });
  notes(s, "The agenda runs in five acts plus an appendix. The case opens with why server-side Wasm is worth comparing to a container at all. The contract spine is the headline act: the Component Model and WIT are what every later claim about portability and safety rests on. One Contract, Two Languages proves that claim with Rust and TinyGo. The Substrates section walks wasmtime, wasmCloud, and the Kubernetes landscape as three ways to run the identical artifact. Deviations and the Final Project close with three stack substitutions and both languages running at once, behind one edge. What to show: point at the six-item list and note that the appendix is reference material, not narrative; it's there to keep open during Q&A, not to present live. If the room is short on time, the contract spine and the substrates sections carry the whole argument.");
}

// ===== SECTION 0: THE CASE ===================================================
divider("0", "The Case", "Why a Wasm component, not another container.",
  "This divider opens the case for server-side Wasm. A component does not replace a container everywhere: it wins on three specific properties (cold start, density, and the shape of its default isolation) and loses on three specific limits (heavy native dependencies, long-lived state, and a full POSIX surface). The following slides make both halves of that claim concrete before the deck reaches the Component Model. What to show: let the divider sit for a moment: it's the first of five section breaks and sets the pattern (title plus one-line claim) the audience will see four more times. If running short on time, this section can compress to the isolation-spectrum diagram and the restraint slide alone.");

titledSlide("THE CASE · THE PITCH", "Server-Side WebAssembly",
  "Four properties make the comparison to a container worth having at all.",
  [
    { lead: "Cold start", text: "a compiled module instantiates in single-digit milliseconds; allocate memory, resolve imports, run. No JIT warm-up, no interpreter boot." },
    { lead: "Density", text: "an instance is closer to a heap allocation than a process; a wasmtime host runs hundreds of instances in the footprint of a handful of containers." },
    { lead: "Isolation", text: "a component has no ambient authority to the host at all; deny-by-default, where a container is allow-by-default-minus-namespacing." },
    { lead: "Polyglot composition", text: "a WIT world removes the byte-layout guesswork; two components in different languages call each other's exports directly." },
  ],
  "The pitch rests on four properties, not a vague speed claim. Cold start and density both follow from the same mechanics: a module is already compiled, so instantiation is mostly memory allocation and import resolution, not another pass over bytecode. Isolation is the property easiest to misstate: a container is isolated by the kernel and still makes real syscalls into a kernel it shares with the host; a component has no instruction in its set that opens a file or a socket unless the host explicitly wires that capability in. Polyglot composition is unique to the Component Model rather than to Wasm generally; it's what lets this site build the same domain twice, once in Rust and once in Go, and treat the two as drop-in replacements. What to show: the four bold leads in sequence. If asked for a number, cite single-digit milliseconds for cold start and single-digit megabytes for image size; both come from the book's own comparison table.");

diagSlide("THE CASE · ISOLATION", "Isolation Spectrum",
  "A VM, a container, and a component default to three different starting positions.",
  "01-isolation-spectrum",
  "VM, container, and Wasm component on isolation mechanism, image size, and cold-start time.",
  "This figure lines up three isolation mechanisms side by side: a VM isolates at the hypervisor boundary with gigabyte images and multi-second cold starts; a container isolates at the kernel boundary with namespaces and cgroups, tens-of-megabytes images, and hundreds-of-milliseconds starts; a Wasm component sandboxes at the runtime level with no ambient syscalls at all, single-digit-megabyte images, and single-digit-millisecond starts. The point is that the component's isolation mechanism is structurally different, beyond being faster. What to show: trace left to right across the three bands, pausing on the component band's 'deny by default' label. If the diagram doesn't render, describe the three bands verbally in the same left-to-right order (VM, container, component), each one step tighter on isolation and smaller on footprint.");

diagSlide("THE CASE · THE PATH", "The Request Path",
  "The same WIT contract, two execution shapes: a container pod and a wasmtime-hosted component.",
  "01-request-path",
  "A cluster request splitting across a container pod and a wasmtime-hosted component, both exposing the same WIT interface.",
  "This figure is the chapter's concrete proof that isolation isn't abstract: a request enters a cluster and can be routed to a container pod running under runc with namespace and cgroup isolation reaching a shared host kernel, or to a wasmtime host where a booking.wasm component only reaches WASI Preview 2 through explicitly granted capabilities. Both paths expose the identical WIT interface for booking and handling: the contract doesn't change, only the execution shape underneath it does, which is the portability claim this whole deck builds toward. What to show: point out that both nodes answer the same booking/handling interface; that's the detail that makes the comparison fair rather than a strawman. If the diagram doesn't render, state the one-line version: same contract, one side a scheduled OS process, the other an instantiated sandbox.");

titledSlide("THE CASE · RESTRAINT", "Where It Doesn't Win",
  "Three real limits keep this from being a universal replacement for a container.",
  [
    { lead: "Heavy native dependencies", text: "a GPU-accelerated library or a decades-old C codec usually has no path to wasm32-wasip2 at all." },
    { lead: "Long-lived stateful processes", text: "an instance is cheap to create and cheap to discard, backwards from a process holding a warmed-up cache." },
    { lead: "A full POSIX surface", text: "no fork, no signals, no ptrace, no real process table; software assuming POSIX doesn't compile to a component today." },
    { lead: "Most systems use both", text: "components run as sidecars and ambassadors next to ordinary container workloads, not as a wholesale replacement for them." },
  ],
  "Restraint matters as much as the pitch. A service linking a mature native library has no realistic path to a wasm32-wasip2 target, and porting it is not a weekend's work. A long-lived process holding gigabytes of warmed-up state is exactly backwards from what a cheap, short-lived component instance wants. WASI Preview 2 does not expose a full POSIX surface by design; that's not a gap to be filled, it's the sandbox's value proposition. The decision this chapter closes with is concrete: reach for a component when the workload is short-lived or bursty, when the code is untrusted enough that deny-by-default is worth the narrower default access, or when the same logic has to run unmodified across architectures. Stay with a container otherwise. What to show: the fourth bullet: most real systems in this book run both side by side, which previews the sidecar and ambassador chapters this deck doesn't cover in depth.");

// ===== SECTION 1: THE CONTRACT SPINE =========================================
divider("1", "The Contract Spine", "A WIT world is the whole agreement, checked before either side's code exists.",
  "This is the headline act of the deck. Every later claim about portability, safety, and polyglot composition traces back to one mechanism: a WIT world names exactly what a component imports and exports, in a file a toolchain reads before either side's implementation exists. The next eight slides walk from the raw module's numbers-only boundary, through the Component Model's typed interfaces, through WASI's capability-scoped grants, to the actual shipping-and-cargo domain this site builds against. What to show: this is the section to slow down on if time is limited elsewhere; it's the one every other section depends on. If compressing the deck, keep WIT Worlds and the Capabilities slide at minimum.");

diagBulletsSlide("THE CONTRACT SPINE · MODULES", "The Component Model",
  "A raw module exchanges only numbers; the Component Model adds a typed interface on top.",
  "02-module-structure",
  [
    { lead: "A module is a static artifact", text: "types, imports, functions, memory, exports; a binary, not a running thing." },
    { lead: "Instantiation produces a live instance", text: "its own linear memory, its own table, its own resolved imports." },
    { lead: "Only numbers cross the boundary", text: "i32, i64, f32, f64; no strings, no structs, no pointers in the native sense." },
  ],
  "A core WebAssembly module's exported functions take and return numbers and nothing else; a module that wants to hand another module a string or a record has to agree out of band on a memory layout and pass a pointer and a length as two integers. Nothing in the module format describes the shape of what crossed the boundary: the signature (i32, i32) -> i32 is true of a string argument and equally true of two unrelated numbers. The Component Model exists to close exactly that gap, which is where the next few slides go. What to show: the module-to-instance arrow in the diagram, then the bullet on numbers-only boundaries; that's the problem WIT solves on the next slide.");

diagBulletsSlide("THE CONTRACT SPINE · COMPOSITION", "Composing Components",
  "Composition links by interface identifier, not by source language.",
  "03-component-composition",
  [
    { lead: "A provider exports an interface", text: "a component built against world cargo, in any language with a WIT toolchain." },
    { lead: "A consumer imports the same interface", text: "its imports are unmet obligations until something satisfies them." },
    { lead: "The match is by WIT identifier", text: "patterncatalyst:cargo@0.1.0/booking; not by Rust, not by Go, not by anything about either toolchain." },
  ],
  "A single component built against a consumer world cannot run on its own: its imports are unmet obligations a runtime refuses to instantiate against. Composition closes that gap by wiring one component's export to another's matching import, and the match happens entirely by package-and-interface identifier. A cargo-service.wasm component built in Rust and a gateway.wasm component built in Go compose exactly as validly as two components from the same language, because the WIT identifiers are what composition checks, not the source. What to show: trace the arrow from the provider's export to the consumer's import, and name the identifier out loud, patterncatalyst:cargo@0.1.0/booking, to make the cross-language claim concrete rather than abstract.");

diagSlide("THE CONTRACT SPINE · THE PACKAGE", "One Package, Three Interfaces",
  "One shared types interface; booking and handling add behavior over it.",
  "03-wit-package-structure",
  "Package patterncatalyst:cargo: a types interface holding every record and enum, with booking and handling each using types.{...} for the shapes their functions need.",
  "The patterncatalyst:cargo package splits along one question: does this carry data, or does it do something with data? The types interface holds every record, enum, and the shared cargo-error variant, and declares zero functions. booking and handling each open with a use statement naming exactly the types members they need, so a reader auditing one interface never has to scan the whole package to find what's relevant. What to show: point out that types has no functions at all; that's the discipline that keeps a future interface from duplicating a shape that already exists. If the diagram doesn't render, state the rule verbally: one interface for vocabulary, two for behavior, and neither behavior interface redeclares a shape the other also needs.");

diagBulletsSlide("THE CONTRACT SPINE · DIRECTION", "WIT Worlds",
  "A world names no new type: only which direction each interface faces.",
  "03-world-imports-vs-exports",
  [
    { lead: "World cargo exports", text: "types, booking, and handling; the provider side, implemented once in Rust and once in Go." },
    { lead: "World cargo-consumer imports", text: "the identical three interfaces; the caller side, an HTTP adapter or a gRPC gateway." },
    { lead: "Same shape, opposite direction", text: "a toolchain checks the two sides satisfy each other by construction, before either component is built." },
  ],
  "A world answers a question none of the interfaces alone can answer: for a given component, which interfaces does it provide, and which does it need? Cargo and cargo-consumer declare opposite answers over the identical three interfaces: no new type, no new function, just a direction applied to interfaces that already exist. If a provider built against cargo exports book-cargo with a given signature, and a consumer built against cargo-consumer imports that same signature, the two satisfy each other by construction, with no serialization mismatch to debug at runtime. What to show: the dashed bidirectional arrow between the two worlds; 'same shape, opposite direction' is the whole idea in four words.");

diagBulletsSlide("THE CONTRACT SPINE · WASI", "Capabilities, Not Ambient Authority",
  "WASI capabilities are granted, not requested: the host decides before the guest runs.",
  "04-capability-grant",
  [
    { lead: "Ambient authority asks the kernel directly", text: "a process either has a user's rights broadly, or it doesn't; coarse by construction." },
    { lead: "A capability is an unforgeable handle", text: "it already points at one specific resource; there's no path from 'code is running' to 'open any file.'" },
    { lead: "The host decides at instantiation", text: "a component importing wasi:filesystem is declaring intent, not granting itself access." },
  ],
  "Every general-purpose OS runs on ambient authority: a library pulled in by a package manager inherits the same rights as the rest of the program. A capability-based model inverts that: a process holds or doesn't hold an unforgeable handle pointing at one specific resource, and the only operations available are the ones that handle's type supports. A component with no filesystem capability in its import set cannot open a file no matter how its own code is written, because opening a file isn't an operation its instruction set can express without a host function doing it on its behalf. What to show: the crossed-out dashed arrow from the guest straight to the kernel; 'the guest cannot ask for what the host didn't hand it' is the line to land on.");

diagSlide("THE CONTRACT SPINE · THE FAMILY", "The WASI World Map",
  "A component's world imports a chosen subset of WASI, never the whole family.",
  "04-wasi-world-map",
  "WASI Preview 2's interfaces split into a Foundations band (io, cli, clocks, filesystem, random) and a later band (http, sockets, nn), with a world importing a chosen subset of either.",
  "WASI is a family of interfaces, each a self-contained WIT package covering one category of host resource: io and cli and clocks and filesystem and random form the base nearly every component needs, while http, sockets, and nn are larger surfaces each component opts into individually. A world's import list is the complete, auditable answer to what a component can reach: a reviewer doesn't need to read the Rust or Go source to know a component with no sockets import cannot open a raw TCP connection. What to show: the dashed arrows from a subset of both bands down into 'this component's world'; the point is that nothing is granted by default, not even from within the WASI family itself.");

diagSlide("THE CONTRACT SPINE · THE DOMAIN", "The Shared Cargo Domain",
  "One domain, five protocol lenses: this site's lens is a component boundary.",
  "05-cargo-domain",
  "Route-spec and cargo feeding into booking, booking producing an itinerary of legs, and a cargo-tracker resource built from handling history.",
  "This is the same shipping-and-cargo domain the REST, gRPC, GraphQL, and WebSockets sibling sites tell from their own protocol's angle: one glossary, five lenses. A shipper books cargo for transport between two ports, the carrier plans an itinerary of legs, and the system records handling events as the cargo moves: received, loaded, unloaded, customs, claimed. What travels between a caller and this domain's implementation here is not bytes on a socket but a typed value the Component Model's canonical ABI lowers into linear memory and lifts back out, checked at build time, not validated by a runtime schema after the fact. What to show: the cargo-tracker resource at the bottom; it's the one piece of this domain that's inherently stateful, and it gets its own construct in WIT, covered on the next slide.");

diagSlide("THE CONTRACT SPINE · MAPPED", "Domain to WIT",
  "Three interfaces, two worlds, and which side a Rust, Go, or consumer component targets.",
  "05-domain-to-wit",
  "Domain concepts landing in the types, booking, and handling interfaces, with cargo and cargo-consumer each targeted by a different kind of component.",
  "This figure closes the loop between the domain and the contract: location and money sit in types as shared value types; booking owns book-cargo, request-possible-routes, assign-route, and get-cargo; handling owns the event functions plus the cargo-tracker resource. A Rust component and a Go component both target world cargo and export all three interfaces; an HTTP or gRPC adapter targets cargo-consumer and imports the same three. Every record name and every function signature on this slide is copied verbatim from the contract in the book's repository; nothing here is illustrative. What to show: trace one function, book-cargo, from the domain box on the left through to the booking interface band; that's the whole chapter in one line of sight.");

// ===== SECTION 2: ONE CONTRACT, TWO LANGUAGES ================================
divider("2", "One Contract, Two Languages", "Rust and TinyGo compile the identical WIT world into interchangeable components.",
  "This section proves the Component Model's headline claim with real binaries rather than a diagram: two toolchains, two generated binding sets, one WIT source of truth, and a 2x2 composition matrix where two of the four pairings cross a language boundary and print byte-identical output. The section closes with the same claim proven across runtimes as well as across languages: one app.wasm, one sha256, under both wasmtime and a wasmCloud lattice. What to show: this section is short by design; three or four slides carry the whole proof. If time is tight, the polyglot-composition-matrix diagram alone makes the point.");

titledSlide("ONE CONTRACT · TWO TOOLCHAINS", "Rust and TinyGo, Same World",
  "Two toolchains, two generated binding sets, one WIT source of truth.",
  [
    { lead: "cargo-component generates Rust bindings", text: "a trait matching the interface's functions one for one, from the WIT world directly." },
    { lead: "wasm-tools and wit-bindgen-go generate Go bindings", text: "compiled with TinyGo; the same lowering and lifting, handled by generated code, not hand-written marshaling." },
    { lead: "Neither hand-writes the boundary", text: "a hand-maintained binding drifts the first time one side changes without the other; a generated one cannot." },
    { lead: "Either implementation is a drop-in replacement", text: "both target world cargo and export the identical three interfaces; a caller can't tell which language answered." },
  ],
  "Neither Rust nor Go understands WIT directly; each toolchain runs a generation step before any domain logic gets written. On the Rust side, cargo-component reads the WIT world a crate targets and generates a trait the crate implements, handling the lowering of a Rust Result into the WIT result the boundary expects. On the Go side, wasm-tools paired with wit-bindgen-go play the same role for a TinyGo build, producing Go types and function signatures from the identical WIT source. The payoff is that a Rust-built provider and a Go-built provider are interchangeable from any caller's point of view, which is exactly what the next slide's composition matrix demonstrates with running code. What to show: the parallel structure in the four bullets: two toolchains, one contract, zero hand-written marshaling on either side.");

diagSlide("ONE CONTRACT · THE MATRIX", "Polyglot Composition",
  "Two providers, two consumers, four pairings: two of them crossing a language boundary.",
  "08-polyglot-composition-matrix",
  "A 2x2 grid of Rust and Go providers against Rust and Go consumers, all four pairings printing an identical normalized summary line.",
  "Two consumers and two providers produce four possible pairings, and all four are run in this book's own verification step: Rust consumer with Rust provider, Rust consumer with Go provider, Go consumer with Rust provider, Go consumer with Go provider. All four print the identical normalized summary line character for character. The two cross-language pairs are the headline, not the two same-language pairs, because wac never asks which language built either half; it only matches the WIT identifier both sides share. What to show: the two diagonal cells in the grid, rustC x goP and goC x rustP, and note that they behave exactly like the two same-language cells, which is the entire point of building the contract this way.");

diagSlide("ONE CONTRACT · THE MECHANISM", "Socket and Plug",
  "The consumer is the socket; the provider is the plug; wac matches by WIT identifier.",
  "08-wac-plug-socket-and-plug",
  "A consumer (socket, imports cargo) and a provider (plug, exports cargo) composed by wac plug into a self-contained component wasmtime runs directly.",
  "wac plug takes exactly two components and one piece of vocabulary: the provider is the plug, because it supplies exports that satisfy someone else's unmet imports; the consumer is the socket, because it has a socket-shaped hole in it: an unresolved import the WIT package identifier alone describes, independent of who happens to fill it. The composed result needs no native host at all; wasmtime runs it directly, with WASI itself satisfied by wasmtime's own built-in implementation at instantiation, regardless of which minor WASI version each half happened to name. What to show: the single arrow crossing from plug to socket, then the composed.wasm box labeled self-contained; that's the artifact a cluster deploys, which is where the next section picks up.");

diagSlide("ONE CONTRACT · ACROSS RUNTIMES", "Same Bytes, Two Runtimes",
  "One app.wasm, byte-identical, under wasmtime and under a wasmCloud lattice.",
  "16-same-bytes-two-runtimes",
  "One app.wasm artifact, sha256 eff7f5ee..., running identical JSON and status codes under wasmtime serve and under a wasmCloud lattice.",
  "This is the proof that closes the loop between the Component Model's boundary and the two runtime substrates covered next: the identical app.wasm file, sha256 recorded once, runs under wasmtime serve as a single process and is deployed into a wasmCloud lattice through a declarative manifest, and the two sides answer the identical JSON and the identical 404 for an unknown cargo ID. The sha256 match is the mechanical consequence of a component's exports being defined by WIT, not a coincidence pointed out after the fact: a runtime's only job is to satisfy imports and call exports, never to see or change the component's own bytes. What to show: the single artifact box at the top fanning down into two bands, and the shared banner at the bottom: one build, two runtimes, no rebuild in between.");

// ===== SECTION 3: THE SUBSTRATES ==============================================
divider("3", "The Substrates", "One component, three ways to run it: a process, a lattice, or a cluster.",
  "The substrates section walks the three places this book runs the cargo component: a single wasmtime process you embed and control directly, a wasmCloud lattice that treats running a component as a declarative statement a control plane keeps true, and Kubernetes, which schedules either of the first two as a workload through a containerd shim and a RuntimeClass. None of these substrates change the component; Part 4 of the book proves that with a matching sha256, covered in the previous section. What to show: this is the longest section in the deck; if compressing, keep wasmtime embedding, the wasmCloud lattice, and the Kubernetes landscape diagram, and drop the two secondary diagrams (Store Safety Controls, wadm's Self-Healing Loop).");

diagBulletsSlide("THE SUBSTRATES · WASMTIME", "Embedding with wasmtime",
  "Engine, Store, and Linker: the host decides every capability a guest holds.",
  "14-embedding-architecture",
  [
    { lead: "Engine", text: "expensive to build, cheap to clone; holds compiled code and the Config that produced it." },
    { lead: "Linker", text: "resolves a component's imports against host-supplied implementations, built once and reused." },
    { lead: "Store", text: "one instance's actual runtime state; WASI context, memory limits, host-capability bookkeeping." },
  ],
  "Every wasmtime embedding starts with the same three types. An Engine holds compiled code and configuration decisions like fuel and epoch metering, baked in once. A Linker resolves a component's imports against host-supplied implementations: wasmtime_wasi's own WASI wiring plus any host-provided capability a Rust closure satisfies. A Store holds one instance's live state and is cheap enough to build fresh per run. The host-provided-import pattern is the mechanism by which a host hands a guest ambient authority explicitly: a guest can call exactly the functions the host's Linker resolved, and nothing it wasn't handed. What to show: the arrow from instantiate into the guest's run export, then the return arrow showing a guest call reaching back into the host's own capability implementation.");

diagSlide("THE SUBSTRATES · STORE CONTROLS", "Store Safety Controls",
  "Fuel, epoch interruption, and a memory cap: three ways to stop a guest that won't stop itself.",
  "14-store-safety-controls",
  "Fuel, epoch interruption, and a ResourceLimiter each gating the same guest, contrasted against a clean run that succeeds under a generous budget.",
  "A host that grants a guest capabilities also needs a way to bound what a misbehaving guest can do with them. Fuel counts down an abstract budget of execution units and traps the instant it hits zero, with no helper thread needed. Epoch interruption counts wall-clock time instead, driven by a ticker thread incrementing a shared counter the engine checks cooperatively. A ResourceLimiter caps linear memory directly, independent of both; a guest that respects its fuel budget can still try to claim unbounded memory in that same budget. Each control is proven by a contrast pair: the same guest, same request, succeeding under a generous budget and trapping under a tight one. What to show: any one of the three columns' contrast rows: the pairing, not the trap name, is the actual proof a control fired.");

diagBulletsSlide("THE SUBSTRATES · WASMCLOUD", "The wasmCloud Lattice",
  "NATS, a host, and wadm: a declarative statement a control plane keeps true.",
  "15-lattice-architecture",
  [
    { lead: "NATS", text: "the lattice's message bus; every invocation, link, and status update travels over it." },
    { lead: "A capability provider", text: "a native process owning what a sandboxed component can't hold itself, like an open TCP socket." },
    { lead: "wadm", text: "reconciles the lattice's actual state against a declared manifest, continuously, not once at deploy time." },
  ],
  "wadm.yaml doesn't say 'start this process'; it says 'this component should have exactly one instance, linked to this provider, forever,' and wadm continuously makes the lattice's actual state match that statement. The httpserver capability provider owns the one thing a sandboxed component structurally cannot hold itself, an open listening socket, and the link between provider and component is itself a reconciled object, not a one-time wiring step. Deployed status meaning 'accepted' rather than 'answering' is the same distinction a Kubernetes reader already knows from a pod reporting Running before its readiness probe passes. What to show: the LINK box between the provider and the component: namespace, package, interface, and source_config are each doing real work, not boilerplate.");

diagSlide("THE SUBSTRATES · SELF-HEALING", "wadm's Self-Healing Loop",
  "Scale a component to zero and watch the reconcile loop bring it back, unassisted.",
  "15-wadm-self-heal-loop",
  "A five-step timeline: healthy, scaled to zero, traffic fails with 500s, wadm reconciles, recovered in about two seconds: with no redeploy.",
  "This is captured live, not simulated: scale the running component to zero instances by hand, which leaves the provider's listener open but with nothing behind it, so traffic fails loudly with a 500 rather than a connection refused. wadm's reconcile loop compares the manifest's declared instance count against the lattice's actual count over the same NATS subjects the host publishes to, and the moment it sees drift, it restores the component; recovery took about two seconds in this book's own capture, with nobody running a second deploy command. That's the exact mechanism a Kubernetes Deployment's controller uses to replace a pod a kubectl delete removed out from under it, applied here to a WebAssembly component instead. What to show: step 4 in the timeline, the reconcile: that's the moment worth narrating slowly, since it's the payoff for the lattice's added complexity.");

diagSlide("THE SUBSTRATES · CHOOSING", "Choosing a Runtime",
  "A process is the simplest correct choice until the lattice's properties are the requirement.",
  "16-single-process-vs-lattice-matrix",
  "A comparison matrix across control, operational surface, resilience, and scale, with Kubernetes named as a third, orthogonal axis.",
  "wasmtime asks you to own a process: the smallest operational surface possible, one binary, one thing to monitor, no lattice to bring up. wasmCloud asks you to own a lattice instead, and gets something back for the extra surface: self-healing without an external restart policy, multi-host scale-out coordinated declaratively, and capability providers swappable without rebuilding the component. Neither column is the default; pick the row that matches what a given deployment needs to own. Kubernetes, covered next, is a third axis on top of this one: it schedules either runtime as a pod, which is a packaging decision, not a resolution of this choice. What to show: the closing banner across both columns: the runtime choice and the Kubernetes scheduling choice compose, they don't substitute for each other.");

diagSlide("THE SUBSTRATES · KUBERNETES", "Wasm on Kubernetes",
  "Four projects, four scopes: pick by what you're deploying and what you control.",
  "17-wasm-on-kubernetes-landscape",
  "Four projects on one map: the generic containerd shim, SpinKube, the wasmCloud operator, and Krustlet (archived), each with a different scope and status.",
  "Kubernetes itself knows nothing about WebAssembly; it schedules pods and hands each one's spec to the node's container runtime, and whether that runtime produces a Linux container or a Wasm component execution is entirely a property of which plugin the runtime resolves. Four projects answer that resolution differently: the generic containerd-shim-wasmtime runs any component exporting a WASI world the shim understands, with the smallest operational footprint on this map. SpinKube is scoped to applications packaged Spin's way. The wasmCloud operator schedules an entire lattice host as a pod. Krustlet predates all of this and is archived, maintained by no one. What to show: row one and row three: the generic shim this book's own minikube deploy uses, and the wasmCloud-operator fallback the CRC appendix needs.");

diagSlide("THE SUBSTRATES · THE MECHANISM", "One Pod Field, Two Runtimes",
  "One Pod-spec field forks the same node onto runc or the Wasm shim.",
  "17-shim-and-runtimeclass-layering",
  "The same kubelet and containerd node forked by one Pod-spec field: no runtimeClassName resolves to runc, runtimeClassName: wasmtime resolves to the shim.",
  "A containerd shim is the actual process containerd forks to run a workload, not a sidecar or a webhook, in the same lifecycle slot runc normally occupies. A RuntimeClass object gives a Pod a name to reference instead of hard-coding a containerd runtime string, and a Pod that sets runtimeClassName: wasmtime is scheduled onto the shim instead of runc, with nothing else about the Deployment, Service, or Ingress objects needing to be Wasm-specific. Installing the shim requires restarting containerd on the node, which bounces every running pod there, so it belongs before other cluster add-ons, not after. What to show: the one Pod-spec field difference between the two columns: runtimeClassName is the entire mechanism, stated as one YAML line.");

diagSlide("THE SUBSTRATES · THE LANDSCAPE", "The Backend Landscape",
  "The shim, the wasmCloud operator, SpinKube, and WasmEdge: pick by what the app is already built against.",
  "26-wasm-backend-landscape",
  "Four rows on one landscape: the generic shim, the wasmCloud operator, SpinKube, and WasmEdge-style shims, each scoped to a different app shape.",
  "None of these four projects compete head-on; each answers a differently scoped question. The generic shim fits a team that built directly against a WIT contract and wants nothing more than a way to schedule it. The wasmCloud operator fits a workload that already wants lattice properties on top of running in Kubernetes. SpinKube fits a team standardized on the Spin framework's trigger model and SDK ergonomics. A WasmEdge-style shim fits a component that needs a specific host-function extension a stock wasmtime embedding doesn't carry. The choice is about what the app is already built against, not about preference. What to show: the footer band across all four rows; it states the rule in one sentence.");

// ===== SECTION 4: DEVIATIONS AND THE FINAL PROJECT ============================
divider("4", "Deviations and the Final Project", "Three substitutions on the stack, then both languages proven at once.",
  "The book's three deviation chapters get a glance here (Istio's mesh-layer filter, Fermyon Spin's own framework packaging, and wasi-nn's portable inference) before landing on the final project, where the two-language-one-contract claim this deck has been building stops being an assertion about one component's portability and becomes a visible property of a running system: two pods, two source languages, one answer, behind one edge. What to show: this section closes the argument; don't rush the final-project request-path diagram, since it's the slide that ties every earlier section together.");

diagSlide("DEVIATIONS", "Three Deviations",
  "Istio's gateway filter, Spin's framework packaging, and wasi-nn's portable inference.",
  "wasm-deviation-stack",
  "Three substitutions on the core stack: a proxy-wasm filter at the Istio gateway, a Spin-framework component under SpinKube or a container, and a wasi-nn inference path.",
  "Each deviation swaps exactly one layer of the stack this deck has walked through, without touching the contract underneath it. Istio and WebAssembly puts a proxy-wasm filter directly in the mesh's own Envoy gateway, authorizing traffic ahead of either backend with no sidecar on the component pods themselves. WebAssembly for Other Backend Architectures runs the identical cargo domain as a Fermyon Spin application, which surfaces a real ABI fact: Spin's SDK targets the newer wasip3 HTTP world, not the 0.2.x world every other HTTP example in this book exports. wasi-nn carries portable inference as the one native-dependency-heavy domain with an emerging WASI story. What to show: the three bands in the stack image: each one is a chapter in the book's Part 6, and none of them required rewriting contracts/wit.");

diagSlide("THE FINAL PROJECT · THE CONTRACT", "One Contract, Two Languages",
  "Two providers, two front doors, one WIT package neither writes to.",
  "28-one-contract-two-languages",
  "The same contracts/wit package feeding a Rust provider and a Go provider, each composed with its own HTTP front door into a separate wasi:http/incoming-handler artifact.",
  "The final project doesn't write a new provider, a new front door, or a new line of WIT; it rebuilds the Rust provider and front door with their own unedited recipes into cargo-rust.wasm, and does the identical thing on the Go side into cargo-go.wasm. cargo-rust.wasm is the same bytes this deck already named by sha256 in the substrates section. cargo-go.wasm is the TinyGo counterpart, assembled from the same two unedited recipes. Two different toolchains, two different language runtimes inside the component, one WIT contract, one identical JSON response. What to show: the two columns converging into the shared band at the bottom: four deploy targets this book already built, now exercised by both languages at once.");

diagSlide("THE FINAL PROJECT · THE PATH", "One Contract, Two Languages, One Trace",
  "Two pods, one shared gateway filter, one shim-level trace.",
  "28-final-project-request-path",
  "Two pods on the containerd shim behind two edges (ingress-nginx and the Istio gateway's proxy-wasm filter), with both shims emitting spans into a shared OTel pipeline.",
  "The Istio gateway's proxy-wasm filter from the deviations chapter needs no change at all to gate two backends instead of one: it runs once in the shared ingress gateway's Envoy, ahead of either Service, so the same header contract (403 without the tenant header, 200 plus a filtered-by header with it) applies identically to the Rust and the Go pod. The shim's OTel export is node-level, not per-pod, so both languages' shims report the same service name in the trace backend; what's provable is shim liveness under the combined workload, not a per-language label or a single stitched trace through either guest's domain logic. What to show: the lower band in the diagram, with its scope note; it states precisely what the trace does and doesn't prove, and is worth reading verbatim.");

titledSlide("WHERE TO GO DEEP", "Where To Go Deep",
  "The 201s carry the code this deck only pointed at.",
  [
    { lead: "The Rust toolchain", text: "cargo-component's generated bindings and the Engine/Store/Linker controls; fuel, epoch interruption, a memory cap." },
    { lead: "The TinyGo toolchain", text: "the command-adapter cabi_realloc trap at startup, and the static bump-arena allocator that fixes it." },
    { lead: "Wiring a lattice", text: "a real wadm manifest, a capability provider, and the link that ties them together." },
    { lead: "Deploying behind a RuntimeClass", text: "the node install, the one changed Pod-spec field, and the live request path on a real cluster." },
  ],
  "Everything in this deck named a concept; the 201s show the running code behind each one. wasm-201-rust walks cargo-component's generated trait, the host-provided import pattern, and the three Store-level safety controls in depth. wasm-201-go walks the TinyGo build pipeline and a specific, hard-to-predict finding: a command component's adapter calling cabi_realloc before the Go runtime has finished its own startup sequence, fixed with a static arena that never touches the heap. Both decks carry the wasmCloud manifest and the Kubernetes deploy end to end, on real clusters, with committed evidence. What to show: name the two deck files by title, not by chapter number, so the reference stands on its own outside this room.");

// ===== CLOSE ==================================================================
{
  const s = S();
  addContentTitle(s, "101 · CLOSE", "One contract, two runtimes, one cluster story");
  leadBullets(s, [
    { lead: "The WIT contract is the spine", text: "one package, two languages, every binding generated from the same source file." },
    { lead: "Capabilities replace ambient authority", text: "a guest holds exactly what the host handed it at instantiation, and nothing more." },
    { lead: "One component runs unmodified everywhere", text: "the same bytes ran under wasmtime, under a wasmCloud lattice, and on two Kubernetes clusters." },
    { lead: "The 201s carry the code", text: "wasm-201-rust and wasm-201-go build every artifact this deck only pointed at." },
  ]);
  notes(s, "To close, bring the deck back to the one claim: a WIT contract, not a protocol and not a cloud vendor's SDK, is what makes a server-side Wasm component portable across languages, runtimes, and clusters. Capability-based security is the other half of that claim: a component's authority is exactly its resolved imports, decided once by the host, never expanded from inside the sandbox. Every runtime and every cluster in this book ran the identical bytes, proven by a matching sha256, not asserted by prose. For the code behind every one of these ideas, point the room at the two 201 decks. What to show: hold on the third bullet longest; 'runs unmodified everywhere' is the sentence that ties the contract-spine section to the substrates section, which is the whole arc of this deck.");
}

// ===== APPENDIX ================================================================
divider("A", "Appendix", "Pins, glossary, and references: keep this open in another window.",
  "The appendix is reference material, not narrative: a version and pin matrix for every tool named in this deck, a short glossary of the vocabulary introduced in the contract-spine section, and a list of primary sources. None of these three slides need to be presented line by line; they exist to answer a question from the floor without breaking the flow of the main deck. What to show: skip straight to whichever appendix slide answers the question asked; there's no need to present the appendix in order.");

tableSlide("APPENDIX · PINS", "Version and Pin Matrix", [
  { code: "Pre-1.0", name: "Component Model", purpose: "W3C CG phase 2/3; wasmtime, cargo-component, and wit-bindgen-go all implement the same canonical ABI." },
  { code: "50.0.0", name: "wasmtime", purpose: "Component-model runtime: the embedding crate and the wasmtime serve/run CLI." },
  { code: "0.21.1", name: "cargo-component", purpose: "Generates Rust bindings from WIT directly; targets wasm32-wasip2." },
  { code: "1.99.1", name: "Rust toolchain", purpose: "Stable channel targets wasm32-wasip2 with no nightly toolchain required." },
  { code: "0.43", name: "TinyGo", purpose: "wasip1 plus wasm-tools component embed/adapt; the one-shot wasip2 flag is not yet reliable." },
  { code: "0.2.12", name: "WASI Preview 2", purpose: "Current stable interface line (2026-06-02): filesystem, sockets, clocks, HTTP." },
  { code: "0.3.2", name: "WASI 0.3", purpose: "Native-async line (2026-10-13); neither this site's Rust nor Go toolchain targets it yet." },
  { code: "0.43.0", name: "wash CLI", purpose: "Bundles nats-server 2.11.3, wadm 0.21.1, and the wasmcloud host 1.9.1." },
  { code: "0.27.0", name: "httpserver provider", purpose: "wasmCloud's maintained HTTP capability provider (ghcr.io/wasmcloud/http-server)." },
  { code: "v0.6.1", name: "containerd-shim-wasmtime", purpose: "runwasi shim: verified against minikube v1.39.0, Kubernetes v1.37.1, containerd v2.3.4." },
  { code: "v0.26.0", name: "containerd-shim-spin", purpose: "Embeds Spin 4.1+; required for spin-sdk 7.0.0's wasi:http@0.3.0 export." },
  { code: "v4.2.4", name: "Spin CLI", purpose: "Pinned runtime for the OpenShift Local container path; spin up serves the trigger directly." },
], "This table is the single reference point for every version this deck named without a citation on the slide itself. Two rows matter most for a technical audience: WASI sits on two live lines at once, 0.2.12 stable and 0.3.2 async, and this book's own toolchain targets only the stable line as of this writing. And containerd-shim-spin's version is pinned specifically because spin-sdk 7.0.0 emits an ABI only a Spin 4.1-or-newer runtime understands; an older shim would fail to resolve the export, not silently degrade. What to show: whichever row answers the question from the floor; this slide is not meant to be read top to bottom in a talk.");

twoColLeadSlide("APPENDIX · GLOSSARY", "Glossary",
  [
    { lead: "Component", text: "a Wasm binary with a typed WIT interface instead of raw numeric exports; the unit this site builds and composes." },
    { lead: "Module", text: "a core WebAssembly binary: linear memory, a function table, and signatures built only from numeric value types." },
    { lead: "World", text: "a named bundle of imports and exports a single component targets; states direction, never introduces a new type." },
    { lead: "World import", text: "an interface a world declares it needs, satisfied by composition (wac plug) or by a host at instantiation." },
  ],
  [
    { lead: "Capability", text: "an unforgeable, scoped handle to one resource, granted by the host at instantiation; never requested by the guest." },
    { lead: "Lattice", text: "wasmCloud's NATS-connected mesh of hosts, providers, and components, reconciled continuously by wadm." },
    { lead: "Shim", text: "a containerd plugin (containerd-shim-wasmtime) that runs a component's bytes in the Pod-lifecycle slot runc normally occupies." },
    { lead: "RuntimeClass", text: "the Kubernetes object naming a containerd runtime handler; a Pod's runtimeClassName routes it to that shim." },
  ],
  "Eight terms, each one introduced earlier in the deck and collected here for a quick look-up rather than a re-explanation. The two most likely to get confused with each other are component and module: a module is the raw, numbers-only binary from the execution-model section, and a component is what the Component Model layers on top of it with a typed WIT boundary. The other pair worth distinguishing on request is capability and world import: a world import is a declaration checked at build time, while a capability is what a host decides to grant at instantiation; the gap between the two is the entire subject of the WASI section. What to show: whichever pair of terms the question names; there's no presentation order here.");

{
  const s = S();
  addContentTitle(s, "APPENDIX · REFERENCES", "Reference Links");
  addBullets(s, [
    "WebAssembly Component Model documentation: component-model.bytecodealliance.org",
    "WASI documentation and the Preview 2 specification repository: wasi.dev",
    "wasmCloud documentation and wadm: wasmcloud.com/docs, github.com/wasmCloud/wadm",
    "runwasi and containerd-shim-wasmtime (Bytecode Alliance): github.com/containerd/runwasi",
    "SpinKube documentation and Spin documentation: spinkube.dev, spinframework.dev",
    "Danilo Chiarlone, Server-Side WebAssembly (Manning)",
    "Shashank Jain, WebAssembly for Cloud (Apress)",
    "Companion decks: wasm-201-rust and wasm-201-go, for every runnable example this deck pointed at",
  ]);
  notes(s, "These are the primary sources behind every claim in this deck: the Component Model and WASI specifications for the contract-spine section, the wasmCloud and runwasi documentation for the substrates section, and SpinKube and Spin's own documentation for the deviations section. The two books are general background reading, not sources for any specific number quoted in this deck; every number here traces to this book's own chapters and their committed, live-verified evidence. The two companion 201 decks are the most useful next stop for anyone in the room who wants to see the code. What to show: this is a closing reference slide; leave it on screen during open Q&A rather than narrating it line by line.");
}


/* --- Scan to explore (QR codes) --- */
{
  const s = S();
  addContentTitle(s, "SCAN TO EXPLORE", "Take it with you");

  // Left QR: the site
  s.addImage({ path: `${ASSETS}/qr-webassembly-site.png`, x: 2.30, y: 1.78, w: 3.10, h: 3.10 });
  s.addText("The site", { x: 1.55, y: 4.98, w: 4.60, h: 0.40,
    fontFace: FONT.title, fontSize: 18, bold: true, color: COLOR.ink, align: "center", valign: "middle" });
  s.addText("Chapters, the WIT interfaces, and runnable Rust & TinyGo examples", { x: 1.45, y: 5.40, w: 4.80, h: 0.72,
    fontFace: FONT.body, fontSize: 13, italic: true, color: COLOR.caption, align: "center", valign: "top" });
  s.addText("patterncatalyst.github.io/cn-patterns-and-practices-webassembly", { x: 1.45, y: 6.12, w: 4.80, h: 0.32,
    fontFace: FONT.mono, fontSize: 10, color: COLOR.red, align: "center", valign: "middle" });

  // Right QR: the hub
  s.addImage({ path: `${ASSETS}/qr-hub.png`, x: 7.93, y: 1.78, w: 3.10, h: 3.10 });
  s.addText("Workshops & Tutorials", { x: 7.18, y: 4.98, w: 4.60, h: 0.40,
    fontFace: FONT.title, fontSize: 18, bold: true, color: COLOR.ink, align: "center", valign: "middle" });
  s.addText("The whole series: every workshop, tutorial, and deck in one place", { x: 7.08, y: 5.40, w: 4.80, h: 0.72,
    fontFace: FONT.body, fontSize: 13, italic: true, color: COLOR.caption, align: "center", valign: "top" });
  s.addText("patterncatalyst.github.io/patterncatalyst-workshops-tutorials-list", { x: 7.08, y: 6.12, w: 4.80, h: 0.32,
    fontFace: FONT.mono, fontSize: 9, color: COLOR.red, align: "center", valign: "middle" });

  notes(s, "This is the 101 concepts deck, so the two codes point where the ideas live and where the whole series lives. On the left, the site: the chapters, the WIT interfaces, and the runnable Rust and TinyGo examples, all public. On the right, the Workshops and Tutorials hub: every workshop, tutorial, and deck in the series in one place. Scan whichever is useful; both are on the Pattern Catalyst GitHub organization.");
}


pres.writeFile({ fileName: OUT })
  .then(() => {
    console.log(`Wrote ${OUT}; slides: ${pageNum}, notes: ${notesCount}`);
    if (pageNum !== notesCount) {
      console.error(`MISMATCH: slide count (${pageNum}) != notes count (${notesCount})`);
      process.exit(1);
    }
  })
  .catch((e) => { console.error(e); process.exit(1); });
