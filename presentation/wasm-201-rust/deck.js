// deck.js — "Server-Side WebAssembly in Rust" — 201.
// Deep-dive, complete vertical slice in Rust: authoring, correctness,
// interfaces, runtimes, Kubernetes, Rust-native deviations, and the final
// project's Rust half. Real code excerpts transcribed from examples/part2..7
// (the Rust crates). Red Hat house style, 16:9. Build: node deck.js
"use strict";

const H = require("./deck-helpers.js");
const {
  COLOR, FONT, W, PNG, ASSETS,
  newDeck, addFooter, addContentTitle, addBullets, addTwoColBullets,
  addStatusTable, addCaption, addDiagramSlide, addCodeSlide,
  addSectionDivider, addNotes,
} = H;

const OUT = "wasm-201-rust-r1.0.pptx";
const REV = "r1.0";

const pres = newDeck();
pres.title = "Server-Side WebAssembly in Rust — 201";
let pageNum = 0;

function S() { const s = pres.addSlide(); pageNum += 1; addFooter(s, pageNum); return s; }
function divider(code, title, subtitle, notes) {
  const s = pres.addSlide(); pageNum += 1; addSectionDivider(s, code, title, subtitle); addNotes(s, notes);
}

// ---- local helper: bold-lead bullets (bold subject run + normal text run) ----
function leadBullets(slide, items, opts = {}) {
  const x = opts.x ?? 0.62, y = opts.y ?? 1.95, w = opts.w ?? 12.09, h = opts.h ?? 4.7;
  const fontSize = opts.fontSize ?? 16;
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
      runs.push({ text: (b.sep === undefined ? " — " : b.sep) + b.text, options: { fontFace: FONT.body, fontSize: para.fontSize, color, breakLine: true } });
    } else {
      runs.push({ text: b.text, options: { ...para, color, breakLine: true } });
    }
  });
  slide.addText(runs, { x, y, w, h, valign: "top", margin: 0, lineSpacingMultiple: 1.12 });
}

function leadSlide(eyebrow, title, items, notes, opts) {
  const s = S(); addContentTitle(s, eyebrow, title); leadBullets(s, items, opts || {}); addNotes(s, notes); return s;
}

// ---- local helper: diagram left (~55%), bold-lead bullets right ----
function diagramBulletsSlide(eyebrow, title, png, items, notes) {
  const s = S();
  addContentTitle(s, eyebrow, title);
  const maxW = 6.55, maxH = 4.55, x0 = 0.62, y0 = 1.95;
  s.addImage({ path: `${PNG}/${png}.png`, x: x0, y: y0, w: maxW, h: maxH, sizing: { type: "contain", w: maxW, h: maxH } });
  const bx = x0 + maxW + 0.35;
  leadBullets(s, items, { x: bx, y: 2.0, w: W - 0.62 - bx, h: 4.55, fontSize: 14 });
  addNotes(s, notes);
  return s;
}

function codeSlide(eyebrow, title, lang, lines, caption, notes, opts) {
  const s = S(); addCodeSlide(s, eyebrow, title, lang, lines, caption, opts || {}); addNotes(s, notes); return s;
}

function tableSlide(eyebrow, title, rows, notes, opts = {}) {
  const s = S();
  addContentTitle(s, eyebrow, title);
  addStatusTable(s, rows, opts);
  addNotes(s, notes);
  return s;
}

// ===== COVER =================================================================
{
  const s = pres.addSlide(); pageNum += 1;
  s.background = { color: COLOR.white };
  try { s.addImage({ path: `${ASSETS}/cover-panel.png`, x: 0, y: 0, w: W, h: 7.5 }); } catch (e) {}
  s.addText("SERVER-SIDE WEBASSEMBLY · 201", { x: 6.00, y: 1.98, w: 6.90, h: 0.34,
    fontFace: FONT.title, fontSize: 14, bold: true, color: COLOR.red, charSpacing: 5, align: "left", valign: "middle" });
  s.addText([{ text: "Server-Side WebAssembly", options: { breakLine: true } },
             { text: "in Rust" }], {
    x: 5.95, y: 2.42, w: 6.95, h: 2.00, fontFace: FONT.title, fontSize: 44, bold: true, color: COLOR.ink, align: "left", valign: "top" });
  s.addText("A complete vertical slice in Rust: WIT bindings, components, wasmtime and wasmCloud, Kubernetes, and the Rust-native deviations — verified on minikube and OpenShift Local.",
    { x: 6.00, y: 4.45, w: 6.80, h: 1.15, fontFace: FONT.body, fontSize: 15, italic: true, color: COLOR.caption, align: "left", valign: "top" });
  s.addText(REV, { x: 11.85, y: 6.10, w: 0.95, h: 0.30, fontFace: FONT.mono, fontSize: 11, color: COLOR.caption, align: "right", valign: "middle" });
  try { s.addImage({ path: `${ASSETS}/logo-candidate-2.png`, x: 11.10, y: 6.78, w: 1.55, h: 0.37 }); } catch (e) {}
  addNotes(s, "This is the 201-rust deck, the deep-dive deck for the Rust implementation path through the book. It follows the whole arc: authoring a component with cargo-component, debugging and error handling at the component boundary, the three interface chapters (wasi-http, gRPC, sockets), the two runtimes (wasmtime embedding and wasmCloud's lattice), deploying on Kubernetes with both minikube and OpenShift Local verified live, the Rust-native deviations (Istio proxy-wasm and wasi-nn), and the Rust half of the final project. Every code slide is a real excerpt transcribed from the repository's Rust crates under examples/part2 through part7 — nothing here is invented. The 101 deck carries the concepts across both languages; the companion 201-go deck covers the identical ground in Go with TinyGo.");
}

// ===== AGENDA ================================================================
{
  const s = S();
  addContentTitle(s, "201-RUST · THE ARC", "What this deck covers");
  addTwoColBullets(s,
    [
      "Authoring in Rust — cargo-component, WIT bindings, the shared domain, composition",
      "Correctness — debugging layers, the two failure channels",
      "Interfaces — wasi-http, gRPC, sockets and reconnect resilience",
      "Runtimes — embedding wasmtime, the wasmCloud lattice",
    ],
    [
      "On Kubernetes — build/package/load/deploy, interposition, scaling, observability",
      "Rust-native deviations — Istio proxy-wasm, wasi-nn",
      "The final project's Rust half — one contract, two languages",
      "Verified on both cluster paths — minikube and OpenShift Local (CRC)",
    ],
    { y: 1.95, fontSize: 15 });
  addNotes(s, "The agenda follows the book's own order, read through the Rust implementation end to end. It opens with authoring — generating bindings from the shared WIT contract with cargo-component and composing components with wac. It covers correctness — the debugging layers available at the component boundary and the two distinct failure channels a Rust component exposes. It walks the three interface chapters: wasi-http, the gRPC bridge, and sockets with reconnect resilience. It covers both runtimes a Rust component actually runs on: an embedded wasmtime host and the wasmCloud lattice. It spends the most time on Kubernetes, since that's where most of the book's chapters live: building, packaging, loading, and deploying on both minikube and OpenShift Local, the interposition and ambassador patterns, HPA and KEDA scaling, and on-cluster observability. It closes with the two Rust-native deviations — Istio's proxy-wasm filter and wasi-nn inference — and the Rust half of the final project, which composes against the identical contract the Go implementation also satisfies.");
}

// ===== SECTION 1 — AUTHORING IN RUST =========================================
divider("1", "Authoring in Rust", "From a WIT world to a running component.",
  "Act one is authoring. We trace the WIT bindings pipeline that turns the shared patterncatalyst:cargo contract into generated Rust source, read the shipping domain the contract encodes, build the first Rust component with cargo-component, run it through a native wasmtime host, and compose it against a consumer with wac plug. The throughline: nothing here is hand-written marshaling — a toolchain generates every byte that crosses the component boundary from one WIT source both languages share.");

diagramBulletsSlide("AUTHORING · THE PIPELINE", "WIT in, bindings out, two toolchains", "03-wit-bindings-pipeline",
  [
    { lead: "Neither Rust nor Go reads WIT directly", text: "each toolchain generates source the language understands before any domain logic is written." },
    { lead: "cargo-component", text: "reads the WIT world a crate targets and generates a trait, one method per WIT function, that the crate implements." },
    { lead: "wasm-tools plus wit-bindgen-go", text: "play the identical role on the Go side, generating a Go interface and its supporting types." },
    { lead: "Generated, never hand-written", text: "a hand-maintained binding drifts the moment WIT changes without it; a generated one is produced fresh every build." },
  ],
  "Neither Rust nor Go understands WIT directly, so each toolchain runs a generation step first. On the Rust side cargo-component reads the WIT world a crate targets and generates a trait matching the interface's functions one for one, including the lowering of a Rust Result into the WIT result the boundary expects — the domain code writes ordinary Rust against ordinary Rust types. On the Go side wasm-tools paired with wit-bindgen-go generate a Go interface and the supporting types a package implements, with the same lowering handled by generated code. The reason this matters: a hand-maintained binding drifts from its WIT source the first time either changes without the other; a generated one cannot, because it is produced fresh from the file every build.");

diagramBulletsSlide("AUTHORING · WORLDS", "Exports face one way, imports the other", "03-world-imports-vs-exports",
  [
    { lead: "A world adds no new type", text: "it only states which direction each interface faces for one component." },
    { lead: "world cargo exports", text: "types, booking, and handling — the provider side a Rust or Go implementation targets." },
    { lead: "world cargo-consumer imports", text: "the identical three interfaces — the caller side an HTTP or gRPC adapter targets." },
    { lead: "The symmetry is checked, not assumed", text: "a provider's export and a consumer's import satisfy each other by construction, because both are built from the same WIT source." },
  ],
  "A world is WIT's answer to a question interfaces alone cannot answer: for a given component, which interfaces does it provide, and which does it need? world.wit declares two worlds over the identical three interfaces. cargo is the provider side — a Rust or Go component implementing booking and handling logic targets it and exports all three. cargo-consumer is the caller side — a component that needs to book cargo without implementing that logic itself targets it and imports the same three, declaring a dependency a composition step has to satisfy. A world introduces no new function signature; it is a direction applied to interfaces that already exist, which is why a toolchain can check that a provider's export and a consumer's import satisfy each other without ever running either component.");

diagramBulletsSlide("AUTHORING · THE DOMAIN", "One shipping domain, five protocol lenses", "05-cargo-domain",
  [
    { lead: "A shipper books cargo", text: "for transport between two ports; the carrier plans an itinerary built from one or more legs." },
    { lead: "Handling events record history", text: "received, loaded, unloaded, customs, claimed — each tied to a cargo's tracking id." },
    { lead: "The same glossary as the REST, gRPC, and WebSockets sites", text: "booking-id, cargo-id, price, and status mean exactly what they mean elsewhere in the series." },
    { lead: "Read through a fifth lens", text: "not a wire protocol at all — a component boundary, typed function calls the canonical ABI lowers and lifts." },
  ],
  "This domain is not new to the series: the REST, gRPC, GraphQL, and WebSockets sibling sites all tell the same shipping and cargo story from their own protocol's angle. This site reads the identical glossary through a fifth lens — not a wire format a client parses, but a typed component interface two languages compile against and call into directly. What travels between a caller and the cargo domain's implementation is a route-spec record and a result<booking, cargo-error>, values a compiler checks at build time rather than a schema a runtime validates after the fact. One domain noun from the gRPC site has no analog here — Operation, the async long-running-job pattern — because a component call is a function call inside a shared address space, with no network round trip to amortize by returning a handle a caller polls later.");

diagramBulletsSlide("AUTHORING · DOMAIN TO WIT", "Data in one interface, behavior in two", "05-domain-to-wit",
  [
    { lead: "types carries every record and enum", text: "plus the shared cargo-error variant — zero functions live here." },
    { lead: "booking owns the shipment lifecycle", text: "book-cargo, request-possible-routes, assign-route, get-cargo." },
    { lead: "handling owns everything once cargo moves", text: "register-handling-event, list-handling-events, and the cargo-tracker resource." },
    { lead: "Two conventions carried from the REST and gRPC sites", text: "money is a decimal string, never a float; location is a UN/LOCODE, never free text." },
  ],
  "Package patterncatalyst:cargo@0.1.0 splits into three interfaces along one question: does this thing carry data, or does it do something with data? types answers the first half and declares zero functions — location, money, cargo, route-spec, booking, leg, itinerary, handling-event, and the three enums plus the cargo-error variant. booking and handling answer the second half, each pulling in exactly the types it needs with a use statement rather than redeclaring anything. Two conventions transfer unchanged from the REST and gRPC sibling sites: money.amount is a decimal string because a binary float would drop cents over enough arithmetic, and location.unlocode is a UN/LOCODE because free text invites exactly the ambiguity a shipping system cannot afford. cargo-error is a variant, not an enum, because each of its four cases carries a string payload identifying what specifically failed.");

diagramBulletsSlide("AUTHORING · THE RUST BUILD", "cargo-component build, one command", "06-rust-build-pipeline",
  [
    { lead: "cargo component build --release", text: "folds WIT resolution, binding generation, the wasip1 compile, and the Preview 2 adapt step into one invocation." },
    { lead: "The artifact lands under wasm32-wasip1", text: "even though WASI Preview 2 is the API surface — cargo-component adapts the core module internally, inside that one command." },
    { lead: "[package.metadata.component.target]", text: "points target.path at ../../../contracts/wit and target.world at cargo — the crate never copies the WIT." },
    { lead: "wasm-tools component wit confirms the build", text: "printing export patterncatalyst:cargo/{types,booking,handling} straight from the compiled binary's own embedded type." },
  ],
  "With the Guest traits implemented, building is one command from the crate root: cargo component build --release. The artifact lands at target/wasm32-wasip1/release, not wasm32-wasip2, even though WASI Preview 2 is the whole site's target surface — cargo-component 0.21 compiles to a wasip1 core module as an internal step, then adapts it into a real Preview 2 component with a bundled adapter, inside that one invocation. Nothing in the crate's source or Cargo.toml names wasip1 anywhere. Cargo.toml's [package.metadata.component.target] points a relative path at the shared contracts/wit directory and names the cargo world, so the crate targets the shared contract directly rather than vendoring a copy. wasm-tools component wit against the built binary is the build's own proof that it satisfies world cargo's export list exactly — the same check a host or composition step performs before trusting the artifact, run here by hand.");

codeSlide("AUTHORING · THE GUEST TRAIT", "book-cargo, implemented", "rust · cargo-component",
  [
    "impl BookingGuest for Component {",
    "    fn book_cargo(spec: RouteSpec, weight_kg: f64) -> Result<Booking, CargoError> {",
    "        if spec.origin.unlocode.is_empty() || spec.destination.unlocode.is_empty() {",
    "            return Err(CargoError::InvalidLocation(",
    "                \"origin and destination must each have a UN/LOCODE\".to_string(),",
    "            ));",
    "        }",
    "        if weight_kg <= 0.0 {",
    "            return Err(CargoError::InvalidBooking(",
    "                \"weight-kg must be greater than zero\".to_string(),",
    "            ));",
    "        }",
    "        let tracking_id = tracking_id_for(&spec.origin, &spec.destination);",
    "        let booking_id = booking_id_for(&spec.origin, &spec.destination);",
    "        // ... construct Cargo + Booking, insert into thread-local STATE, Ok(booking)",
    "    }",
  ],
  "rust/src/lib.rs:84-99 — cargo-component generates BookingGuest from world cargo",
  "This is cargo-component's generated trait in use: BookingGuest's book_cargo signature was fixed by the WIT file before this implementation was written, taking a generated RouteSpec struct and an f64, returning a Result<Booking, CargoError>. The body is ordinary Rust — two validation guards returning domain-specific CargoError variants, then a deterministic tracking id and booking id derived from the two UN/LOCODEs, then a Cargo and a Booking constructed and inserted into a thread-local HashMap. A wasm component instance is single-threaded, so a RefCell is sufficient; no locking is needed anywhere in this file. The identical domain logic exists in the Go implementation against the same WIT world, and chapter 8's host asserts the two produce byte-for-byte-identical results from the identical scenario.");

diagramBulletsSlide("AUTHORING · THE HOST", "One host binary, two interchangeable components", "06-host-exercises-component",
  [
    { lead: "wasmtime::component::bindgen!", text: "reads the same WIT contract and generates the host's caller-side types, not cargo-component's implementer-side traits." },
    { lead: "Cargo::instantiate returns typed handles", text: "patterncatalyst_cargo_booking() and _handling() — every call reads like an ordinary method call." },
    { lead: "Two failure layers, kept visibly separate", text: "a .wc(...) wasmtime-level error for a trap, then a map_err for the WIT result's own Err arm." },
    { lead: "cargo-tracker crosses as a ResourceAny handle", text: "constructed, called against repeatedly, then explicitly dropped — the host never sees the component's own fields." },
  ],
  "host/src/main.rs is a native Rust binary, built independently of the component, using wasmtime's own bindgen! macro to get typed accessors for the world the component exports — the same WIT contract, read for the opposite purpose cargo-component reads it for. The host loads the component, builds a Linker with WASI support, instantiates it, and gets back typed handles for each interface: cargo.patterncatalyst_cargo_booking() and _handling(). From there every call — call_book_cargo, call_get_cargo, call_register_handling_event — reads like an ordinary method call even though each one crosses the component boundary into the .wasm binary's own linear memory and back. A double unwrap keeps two failure layers visibly separate: .wc(...) handles a wasmtime-level failure such as a trap, and the following map_err handles the WIT-level Err arm of a result the function can legitimately return as a successful call. The same host binary runs unmodified against either the Rust or the Go component.");

diagramBulletsSlide("AUTHORING · COMPOSITION", "A plug, a socket, one WIT identifier", "08-wac-plug-socket-and-plug",
  [
    { lead: "The provider is the --plug", text: "it supplies exports that satisfy someone else's unmet imports." },
    { lead: "The consumer is the socket", text: "an unresolved import for patterncatalyst:cargo/booking@0.1.0 and its sibling interfaces." },
    { lead: "wac resolves by interface identifier alone", text: "never by source language — by the time wac sees a .wasm file, the language is already gone." },
    { lead: "consumer-rust is a command, not a reactor", text: "a real fn main lets cargo-component synthesize wasi:cli/run, so wac plug's output is directly wasmtime run-able." },
  ],
  "wac plug takes exactly two components and one piece of vocabulary: the provider is the --plug argument because it supplies exports that satisfy someone else's unmet imports; the consumer is the positional socket because it has a socket-shaped hole — an unresolved import for patterncatalyst:cargo's three interfaces. wac resolves that plug entirely by matching WIT interface identifiers between what the consumer imports and what the provider exports; nothing inspects which language either binary was compiled from, because by the time wac sees either .wasm file the language is already gone. Chapters 6 and 7 both built reactor components with no main, instantiated once and called repeatedly by a host. consumer-rust is the opposite shape, a [[bin]] crate with an ordinary fn main, which is what makes wac plug's output directly runnable with nothing but wasmtime run — no native host required.");

// ===== SECTION 2 — CORRECTNESS ===============================================
divider("2", "Correctness", "Two tools, two failure channels.",
  "Act two is correctness. A component carries no debug information of its own, so we trace where DWARF actually lives and which tool answers which symptom, cheapest first. Then we draw the one distinction every Rust component has to get right: a recoverable domain result versus an unrecoverable trap, and the rule for choosing between them.");

diagramBulletsSlide("CORRECTNESS · DEBUG LAYERS", "No debug info crosses the boundary", "09-component-debug-layers",
  [
    { lead: "A component carries no DWARF of its own", text: "debug info, when present, lives inside exactly one of its wrapped core modules." },
    { lead: "cargo-component strips DWARF by default", text: "a release build carries no debug info unless the crate opts in with its own profile setting." },
    { lead: "TinyGo embeds DWARF by default", text: "roughly two-thirds of the Go core module's size is debug info the Rust build never produces." },
    { lead: "wasmtime always resolves function names", text: "from the core module's name section — file:line resolves only when that module's DWARF survived the build." },
  ],
  "A component itself has no concept of debug information; DWARF, when it exists, lives inside exactly one of the core modules the component wraps, never at the component or canonical-ABI layer. The two toolchains in this book make opposite default choices: cargo-component's release build strips DWARF unless a crate explicitly turns debug info on, while a plain TinyGo wasip1 build embeds a full DWARF set by default, more than two-thirds of the resulting core module's size. That split has a visible consequence at the one place both languages fail the same way: a wasmtime trap backtrace always resolves demangled function names, because wasmtime reads the name custom section regardless of DWARF, but it only resolves file and line number when DWARF is actually present — so an identical trap looks very different in a Rust backtrace versus a Go one, purely because of a default neither author set explicitly.");

diagramBulletsSlide("CORRECTNESS · SYMPTOM TO TOOL", "Five tools, ranked by cost", "09-symptom-to-tool",
  [
    { lead: "wasm-tools component wit", text: "the cheapest check — confirms the shape a component exports before it ever runs." },
    { lead: "wasm-tools objdump", text: "predicts whether a later trap's backtrace will resolve file:line, by checking for DWARF before anything fails." },
    { lead: "A trap backtrace, with WASMTIME_BACKTRACE_DETAILS=1", text: "one frame per call; named always, located only if DWARF survived the build." },
    { lead: "inherit_stderr() is the only logging channel", text: "a capability the host grants explicitly — not a default a guest can assume." },
    { lead: "A gdbstub is the last resort", text: "wasmtime's -g/--gdbstub attaches LLDB at the native/core level, with no WIT-aware source view yet." },
  ],
  "The chapter's symptom-to-tool table orders five tools by cost, cheapest first. Need the shape before running it: wasm-tools component wit, reading embedded types rather than .wit source on disk. Need to know whether a future trap will even resolve file and line: wasm-tools objdump, checking per-section sizes for DWARF before anything fails. The component trapped at runtime: wasmtime run or the host, with WASMTIME_BACKTRACE_DETAILS=1 set, one frame per call. Need what the component wrote on its way down: WasiCtxBuilder's inherit_stderr(), an opt-in capability the host grants, not a default the guest can assume, consistent with WASI's whole capability model. Need to pause and step through source: wasmtime's -g/--gdbstub flag attaches an LLDB gdbstub that sees wasm instructions and linear memory, not a WIT-aware per-interface view — reserved for when the first four tools can't localize the bug.");

diagramBulletsSlide("CORRECTNESS · TWO CHANNELS", "A result, or a trap — never both", "10-two-failure-channels",
  [
    { lead: "A call across the boundary fails exactly one of two ways", text: "a recoverable result<_, cargo-error>, or an unrecoverable trap — WIT has no representation for the second." },
    { lead: "A recoverable failure is still a successful call", text: "the host observes Ok(Err(cargo-error::not-found)) — the wasmtime call itself succeeded." },
    { lead: "A trap arrives as Err on the call", text: "with no domain value ever constructed — the function simply never returned." },
    { lead: "A trap poisons the whole Store instance", text: "no further export call is valid afterward, which is why the host runs its trap sentinel strictly last." },
  ],
  "Every call across a component boundary fails in exactly one of two ways. A recoverable failure returns a result<_, cargo-error> domain value — the wasmtime call itself succeeded, and the host sees Ok(Err(cargo-error::not-found)). An unrecoverable failure is a trap, which WIT has no representation for at all: a Rust panic! or a Go panic() unwinds to a trap at the component boundary, and the host sees Err on the call itself, with no domain value ever constructed. That matters operationally because a trap poisons the wasmtime Store's instance — no further export call is valid against it afterward — which is exactly why host/src/main.rs runs its deliberate trap-sentinel call strictly last, after every other assertion in the scenario has already passed.");

diagramBulletsSlide("CORRECTNESS · THE MAPPING RULE", "Expected failures earn a cargo-error", "10-error-mapping",
  [
    { lead: "Use cargo-error for anything a caller should expect", text: "an unknown id, a bad input, a conflicting state — and can be positioned to handle." },
    { lead: "Reserve a panic for a bug the component cannot recover from", text: "an invariant the component's own code assumed would hold, and did not." },
    { lead: "Rust's Result and Go's cm.Result both lower identically", text: "onto the same WIT result<_, cargo-error> — one four-case variant, defined once in contracts/wit." },
    { lead: "Mixing the two breaks the taxonomy in both directions", text: "an error for a real bug hides it; a panic on a routine missing lookup crashes work that should have failed gracefully." },
  ],
  "The chapter's decision rule is explicit: use cargo-error for anything a caller should reasonably expect and be positioned to handle — an unknown id, a bad input, a conflicting state — and reserve a panic for a bug the component cannot recover from, an invariant the component's own code assumed would hold and did not. Rust's Result<T, CargoError> and Go's generated cm.Result both lower onto the identical WIT result<_, cargo-error> shape, because the four-case cargo-error variant is defined exactly once in contracts/wit/types.wit and both languages' bindings generate matching constructors from it. Mixing the two rules breaks the taxonomy in opposite directions: returning an error for what is actually a bug hides the bug from whoever reads cargo-error's four cases expecting them to be exhaustive; panicking on a routine missing lookup crashes work that should have failed gracefully and returned to the caller.");

codeSlide("CORRECTNESS · ONE FUNCTION, TWO CHANNELS", "Result<T, CargoError> vs panic!", "rust · cargo-component",
  [
    "fn get_cargo(tracking_id: String) -> Result<Cargo, CargoError> {",
    "    if tracking_id == TRAP_SENTINEL {",
    "        // A panic unwinds to a wasm trap at the component boundary — the",
    "        // host observes an `Err` from the CALL itself, not an `Ok(Err(..))`",
    "        // domain result. This is the unrecoverable side of the taxonomy.",
    "        panic!(\"__TRAP__ sentinel: deliberate trap for the debugging/error chapter\");",
    "    }",
    "    STATE.with(|s| {",
    "        s.borrow()",
    "            .cargos",
    "            .get(&tracking_id)",
    "            .cloned()",
    "            .ok_or_else(|| CargoError::NotFound(format!(\"no cargo {tracking_id}\")))",
    "    })",
    "}",
  ],
  "rust/src/lib.rs:166-180 — the sentinel traps; every other miss returns CargoError::NotFound",
  "Both channels live in the same function. A tracking id of exactly __TRAP__ hits a deliberate panic!, which unwinds to a wasm trap the host observes as a failed call, never a domain value. Every other unknown tracking id falls through to the normal path: a HashMap lookup that returns None becomes CargoError::NotFound through ok_or_else, a recoverable result<_, cargo-error> the host sees as a perfectly successful call carrying a domain-level failure. The sentinel constant is documented and kept in lockstep with the Go implementation's own trap sentinel, and it is excluded from the main scenario fixture by design, so the cross-language byte-identical comparison chapter 8 relies on is unaffected by it — it exists only to give the debugging and error-handling chapters a real trap to show, on demand, without touching the rest of the test surface.");

// ===== SECTION 3 — INTERFACES ================================================
divider("3", "Interfaces", "wasi-http, gRPC, and sockets with reconnect resilience.",
  "Act three covers the three ways something outside the sandbox talks to this domain. wasi-http turns a component into an HTTP server with a single exported function. gRPC splits cleanly along its two halves: Protobuf's encoding runs fully inside a component, while gRPC's HTTP/2 transport needs a native bridge in front of it. Sockets closes the act with a component dialing out — a WASI capability grant, and a reconnect loop with exponential backoff and jitter.");

diagramBulletsSlide("INTERFACES · WASI-HTTP", "One function, no return value", "11-wasi-http-request-path",
  [
    { lead: "Guest::handle takes an outparam, not a return", text: "the response is delivered by writing into ResponseOutparam, never returned from handle." },
    { lead: "Routing is five lines", text: "a CARGO-{origin}-{destination} path books then reads; anything else falls straight to get-cargo." },
    { lead: "book-then-get in one request is deliberate", text: "wasmtime serve creates a fresh instance per HTTP request, so a cold get-cargo on an unbooked id always misses." },
    { lead: "Move-only resources force an ordering rule", text: "resp.body() has to be read before ResponseOutparam::set, which moves resp by value." },
  ],
  "handle's whole contract is one function with no return value: the response is delivered by writing into a ResponseOutparam, not returned. Routing is five lines — strip the /cargo/ prefix, split on hyphens; a CARGO-{origin}-{destination} shape triggers book-cargo then get-cargo, anything else falls straight to a get-cargo that legitimately misses. That book-then-get pairing is not redundant: wasmtime serve instantiates a fresh component per HTTP request, and the Part 2 provider keeps its state in that instance's own linear memory with no external store, so a cold lookup on an id nobody booked in this request always returns not-found. wasi:http's resources are move-only, which creates a real ordering rule the compiler enforces: resp.body() must be obtained before the resp value is moved into ResponseOutparam::set.");

diagramBulletsSlide("INTERFACES · PIPELINE", "wac plug, then wasmtime serve -S cli", "11-build-compose-serve-pipeline",
  [
    { lead: "cargo component build produces the HTTP adapter", text: "wit's include wasi:http/proxy pulls in a whole predefined world, not a single interface." },
    { lead: "wac plug wires the Part 2 provider underneath", text: "the same plug-is-the-exporter, socket-is-the-importer orientation chapter 8 already established." },
    { lead: "-S cli is not optional", text: "wasmtime serve's default proxy linker is narrower than the full WASI CLI environment the provider still imports." },
    { lead: "verify.sh proves two toolchains, one JSON", text: "Rust and Go HTTP adapters, composed against Rust and Go providers, all assert the identical response body." },
  ],
  "The HTTP adapter's WIT world does an include of wasi:http/proxy, pulling in a whole predefined world's imports and exports rather than naming one interface — the component exports wasi:http/incoming-handler and imports a narrow WASI slice alongside its own three patterncatalyst:cargo imports. Building it is the same cargo component build --release chapter 6 used; composing it is the same wac plug chapter 8 used, with the Part 2 provider as the --plug and the HTTP adapter as the socket. Serving it needs one flag most people miss: wasmtime serve's default proxy linker is narrower than the full WASI CLI environment, and both Rust's standard library shim and the unstripped Part 2 provider still import wasi:cli/environment and wasi:filesystem — without -S cli the failure doesn't appear at startup, it appears on the first request. verify.sh runs all four Rust/Go combinations and asserts the literal same JSON string from every one.");

diagramBulletsSlide("INTERFACES · GRPC", "One proto, two generators, one split", "12-encoding-vs-transport-split",
  [
    { lead: "prost-build generates messages only, inside the component", text: "protobuf-the-serialization runs fully server-side in the sandbox." },
    { lead: "tonic-prost-build generates full service stubs, inside the native bridge", text: "the one artifact that actually has to be a gRPC endpoint." },
    { lead: "The WIT boundary moves raw bytes, not records", text: "codec.get-cargo takes list<u8> and returns list<u8> — WIT has no concept of a protobuf message at all." },
    { lead: "gRPC's transport can't move into a component", text: "TCP accept, HTTP/2 negotiation, stream demux, and trailers-after-body have no wasi:http/incoming-handler equivalent today." },
  ],
  "One .proto file backs two artifacts generated by two different protoc plugins. prost-build, running inside the WIT-bound codec component, generates message structs only — a messages-only generator never even sees the service block. tonic-prost-build, running in the native bridge, generates the full CargoServiceServer and CargoServiceClient stubs, because the bridge is the one artifact that actually has to be a gRPC endpoint. The WIT boundary itself carries no protobuf vocabulary: codec.get-cargo's signature is list<u8> in, result<list<u8>, string> out, the same opaque-bytes primitive chapter 11's HTTP body used. gRPC's transport cannot follow the encoding into a component because wasi:http/incoming-handler is structurally a one-request/one-response contract — no long-lived stream, no trailer channel, no multiplexing — a gap in what wasi:* exposes today, not a bug to fix.");

diagramBulletsSlide("INTERFACES · GRPC", "Decode, dispatch over WIT, encode", "12-protobuf-in-component",
  [
    { lead: "protoc runs on the build host, never in the sandbox", text: "build.rs shells out to a pinned protoc before wasm32-wasip1 compilation even starts." },
    { lead: "The codec is a WIT consumer like any other", text: "it imports patterncatalyst:cargo/{types,booking} and is composed in with wac plug, exactly like chapter 8's consumers." },
    { lead: "Every step inside the sandbox is pure computation", text: "varint decode, a WIT call, length-delimited encode — none of it asks for a socket, a thread, or a clock." },
    { lead: "A 19-byte request produces a 91-byte response", text: "every field — tracking id, both UN/LOCODEs, weight, price — asserted and matching against a native test driver." },
  ],
  "The codec component's WIT world imports patterncatalyst:cargo/{types,booking} and exports a single codec interface with one function, get-cargo — composed against a real provider with wac plug exactly like chapter 8's consumers, protobuf changing nothing about how composition works. protoc itself runs on the build host via prost_build::Config::compile_protos, generating derived message structs before the wasm32-wasip1 compile ever starts; nothing protobuf-related runs at build time inside the sandbox. The handler's three steps — decode a request with prost's varint and length-delimited parsing, dispatch the resulting fields across the WIT boundary to book-cargo or get-cargo, encode the response back to bytes — are all pure computation on bytes already in hand, which is exactly the bar WASI Preview 2's capability model lets through without a single capability grant. A native proto-host test driver confirms a 19-byte request produces a 91-byte response with every field intact.");

diagramBulletsSlide("INTERFACES · GRPC", "The bridge is the gRPC server", "12-grpc-bridge-in-front",
  [
    { lead: "The component inside is unmodified", text: "the identical artifact chapter 6's cargo-component build produced — composed against nothing, changed for nothing." },
    { lead: "One Engine and Component, a fresh Store per RPC", text: "every RPC gets its own provider instance, so get-cargo books before it reads, mirroring the HTTP adapter's own pattern." },
    { lead: "spawn_blocking keeps the synchronous Wasm call off tonic's executor", text: "no async code ever touches a WIT call anywhere in this toolchain." },
    { lead: "Proof is a real round trip", text: "a tonic test binds a real TcpListener and drives GetCargo and BookCargo over real HTTP/2 — nothing mocked, nothing stubbed." },
  ],
  "The chapter's thesis is stated directly in the bridge's own file header: there is no gRPC server inside any component, the bridge is the artifact. The .wasm file it loads with wasmtime::component::Component::from_file is the identical binary chapter 6's cargo-component build produced — composed against nothing, modified for nothing. The bridge keeps one Engine, Component, and Linker shared across every RPC but builds a fresh Store per call, because the provider keeps domain state in instance memory; its do_get_cargo books the cargo before reading it back, the same pattern the HTTP adapter uses for the same reason. Every synchronous Wasm call moves onto tokio::task::spawn_blocking so tonic's async executor stays free — no async code touches a WIT call anywhere in this toolchain. The proof is a real end-to-end test: a bound TcpListener, a real tonic::Server, a real CargoServiceClient over real HTTP/2.");

codeSlide("INTERFACES · GRPC", "The bridge forwards to the component", "rust · tonic + wasmtime",
  [
    "#[tonic::async_trait]",
    "impl CargoService for Bridge {",
    "    async fn get_cargo(",
    "        &self,",
    "        request: Request<GetCargoRequest>,",
    "    ) -> Result<Response<GetCargoResponse>, Status> {",
    "        let this = self.clone();",
    "        let tracking_id = request.into_inner().tracking_id;",
    "        let resp = tokio::task::spawn_blocking(move || this.do_get_cargo(tracking_id))",
    "            .await",
    "            .map_err(|e| Status::internal(format!(\"join error: {e}\")))?",
    "            .map_err(Status::internal)?;",
    "        Ok(Response::new(resp))",
    "    }",
    "    // book_cargo follows the identical spawn_blocking shape",
    "}",
  ],
  "grpc-bridge/src/main.rs — do_get_cargo dispatches the WIT call on a blocking thread",
  "The tonic trait implementation is the whole bridge in miniature. get_cargo clones the bridge's shared Engine/Component/Linker handles, moves the request's tracking_id onto a blocking thread with spawn_blocking, and inside that closure do_get_cargo builds a fresh Store, instantiates the unmodified provider, gets the booking interface's typed handle, and calls call_get_cargo across the component boundary — the identical wasmtime calling convention chapter 6's native host used. Two error layers are kept distinct here too: a join error from the blocking task becomes an internal gRPC status, and a WIT-level error from the component becomes a separate internal status, so a caller debugging a failed RPC can tell a thread-pool problem apart from a domain-level one. book_cargo repeats the identical shape one function below this excerpt.");

diagramBulletsSlide("INTERFACES · SOCKETS", "Exponential backoff, with jitter", "13-reconnect-backoff-timeline",
  [
    { lead: "The connect dance is asynchronous under the hood", text: "start-connect returns immediately; a pollable is subscribed and blocked on until the attempt resolves." },
    { lead: "delay = base x 2^min(attempt-1, 5), plus jitter", text: "jitter up to 50% of the exponential delay, sourced from wasi:random — never ambient entropy." },
    { lead: "Jitter exists to prevent a thundering herd", text: "without it, every client that failed at the same moment retries in exact lockstep." },
    { lead: "connection-refused and access-denied are handled oppositely", text: "refused backs off and retries; denied fails fast — a captured run shows four refusals of growing backoff, then attempt five connects." },
  ],
  "A WASI socket's connect is asynchronous even though the calling code reads sequentially: start-connect returns immediately without connecting, and the caller subscribes to the socket's own pollable and blocks on it until the attempt actually resolves, then reads the result with finish-connect — the identical subscribe-and-block idiom the backoff sleep itself reuses for timing. The backoff formula is base times two to the power of the attempt count minus one, capped at a shift of five, plus a jitter of up to half that exponential delay drawn from wasi:random/random — a capability-scoped entropy source, never ambient access. Jitter exists specifically to prevent a thundering herd: without it every client that failed at the same instant would retry in exact lockstep. A captured real transcript with a listener binding 1.5 seconds late shows four refusals with backoffs of roughly 131, 269, 456, and 1031 milliseconds, then a fifth attempt connects.");

diagramBulletsSlide("INTERFACES · SOCKETS", "The denial happens before any socket call", "13-capability-boundary",
  [
    { lead: "wasmtime run grants zero network capability by default", text: "creating a socket resource succeeds; start-connect returns access-denied directly — no DNS lookup, no SYN packet, ever attempted." },
    { lead: "The grant is one host-side flag", text: "wasmtime run -S inherit-network — the identical .wasm, the identical WIT world, only the host's grant decision differs." },
    { lead: "access-denied is treated as unrecoverable, not retryable", text: "the loop exits immediately rather than burning attempts a host's grant decision will never change between invocations." },
    { lead: "Granted vs. denied is a precise line", text: "allocating a socket resource always succeeds; using it to reach outside the sandbox is what the capability actually gates." },
  ],
  "By default wasmtime run links zero network capability into a component instance. Allocating a socket resource with create-tcp-socket still succeeds — nothing about constructing a handle is restricted — but start-connect returns ErrorCode::AccessDenied directly, with no DNS lookup and no SYN packet ever attempted; the denial happens inside wasmtime's own wasi:sockets host implementation, before any kernel socket call runs. The grant is exactly one CLI flag on the host side, wasmtime run -S inherit-network, changing nothing about the component itself. The retry loop treats that denial as categorically different from a connection refusal: it calls std::process::exit(2) immediately with a message naming the fix, because retrying accomplishes nothing when the host's grant decision cannot change between invocations — the same distinction chapter 4 drew for a missing preopened directory, applied here to sockets.");

// ===== SECTION 4 — RUNTIMES ===================================================
divider("4", "Runtimes", "Embedding wasmtime, then the wasmCloud lattice.",
  "Act four covers the two runtimes a Rust component actually runs on in this book. An embedded wasmtime host gives fine-grained control over one Store at a time — fuel, epoch deadlines, a memory limiter. wasmCloud trades that single-process control for a lattice: a lattice of hosts connected over NATS, with wadm continuously reconciling a declarative manifest against what is actually running. The closing claim ties both together: the identical compiled bytes run, unmodified, under either one.");

diagramBulletsSlide("RUNTIMES · EMBEDDING", "Engine, Linker, Store — three lifetimes", "14-embedding-architecture",
  [
    { lead: "An Engine is expensive to build, cheap to clone", text: "it holds compiled code and the Config that produced it — this host builds one fresh Engine per Config variant it needs." },
    { lead: "A Linker resolves imports against host implementations", text: "built once per Engine, reused across every Store that Engine creates." },
    { lead: "A Store holds one component instance's actual state", text: "cheap enough to build fresh per scenario run — this host builds more than six across its own run." },
    { lead: "host-caps is a new import direction", text: "the guest imports host-quote and host-now, capabilities only the native host can supply — there is no other way for it to obtain either value." },
  ],
  "Three wasmtime types, three different lifetimes. An Engine is expensive to build but cheap to clone — it holds compiled code plus the Config that produced it, and because fuel and epoch interruption are Config-time decisions baked permanently into an Engine, this host builds a separate Engine per Config variant: default, fuel-enabled, epoch-enabled. A Linker<T> resolves a component's imports against host-supplied implementations, built once per Engine and reused across every Store that Engine subsequently creates. A Store<T> holds one component instance's actual runtime state — here, the WASI context plus a per-store memory limiter — and is cheap enough to build fresh for every scenario run. This chapter also introduces the opposite import direction from every earlier chapter: host-caps gives the guest something it structurally cannot produce itself, host-quote and host-now, values only the native host can supply.");

diagramBulletsSlide("RUNTIMES · STORE SAFETY", "Fuel, epoch, and a memory limiter", "14-store-safety-controls",
  [
    { lead: "Fuel counts abstract execution units", text: "Config::consume_fuel(true) turns it on; store.set_fuel(n) sets the budget — the instant it reaches zero, the call traps." },
    { lead: "Epoch interruption needs an external ticker", text: "nothing advances the clock automatically; the host spawns its own thread calling increment_epoch() on an interval." },
    { lead: "A ResourceLimiter gates memory, not CPU time", text: "StoreLimitsBuilder caps linear memory size — denial surfaces as a trap, not a tidy WIT-level result." },
    { lead: "Attach all three, because each gates something different", text: "fuel and epoch bound CPU time two different ways; the limiter is the only one of the three that bounds memory at all." },
  ],
  "Three independent controls, each proven with its own contrast pair in the host's test scenario. Fuel counts abstract execution units and traps the instant a budget hits zero, with no helper thread needed — the host asserts a generous 50-million-unit budget leaves most of its fuel unspent, and asserts Trap::OutOfFuel when a 100,000-unit budget races a spinning guest. Epoch interruption needs a ticker nothing provides automatically: the host spawns its own thread that calls increment_epoch() every five milliseconds, then sets a deadline far away for a clean run or one tick away to force Trap::Interrupt, stopping and joining that thread before any assertion runs so nothing leaks past main. A ResourceLimiter caps linear memory independently of either CPU control; denial doesn't surface as a WIT result at all, because the guest's own allocator aborts when memory.grow fails, which the chapter's own decision callout cites as the reason to always attach a limiter regardless of whether fuel or epoch interruption is also in use.");

codeSlide("RUNTIMES · STORE CONTROLS", "Three independent Store controls", "rust · wasmtime 50",
  [
    "// fuel — host/src/main.rs:219-233",
    "fuel_cfg.consume_fuel(true);",
    "let fuel_engine = Engine::new(&fuel_cfg)?;",
    "store.set_fuel(50_000_000).wc(\"set generous fuel\")?;",
    "",
    "// epoch interruption — lines 262-286, ticked by a separate thread",
    "epoch_cfg.epoch_interruption(true);",
    "let ticker_engine = epoch_engine.clone();",
    "thread::spawn(move || {",
    "    while !stop_t.load(Ordering::Relaxed) {",
    "        thread::sleep(Duration::from_millis(5));",
    "        ticker_engine.increment_epoch();",
    "    }",
    "});",
    "store.set_epoch_deadline(1_000_000); // far deadline, clean run",
    "",
    "// ResourceLimiter — lines 152-185, gates memory, not CPU time",
    "let capped = StoreLimitsBuilder::new().memory_size(8 * 1024 * 1024).build();",
    "store.limiter(|s| &mut s.limits);",
  ],
  "wasmtime-host/host/src/main.rs — three Store controls, each gating something different",
  "These three blocks come from the same host file and run against three separately configured Engines, because fuel and epoch interruption are Config-time switches an Engine bakes in permanently. Fuel is the simplest: turn it on, set a budget, and a trap arrives the instant the budget is exhausted. Epoch interruption needs the host to drive its own clock — a dedicated thread increments a shared counter every five milliseconds, and a Store's deadline is just a target value on that counter. The ResourceLimiter is orthogonal to both: it caps linear memory size independent of how much CPU time a call consumes, and the host's own test proves it with a contrast pair — the identical guest request to grow memory by 64 MiB is denied under an 8 MiB cap and succeeds under a 256 MiB one.");

diagramBulletsSlide("RUNTIMES · WASMCLOUD", "NATS, hosts, and a control plane", "15-lattice-architecture",
  [
    { lead: "NATS is the lattice's message bus", text: "every invocation, link, and status update travels over NATS subjects — any number of hosts can join the same subject space." },
    { lead: "The wasmcloud host runs components and providers as supervised processes", text: "and exposes lattice operations like wash get hosts and wash scale component." },
    { lead: "wadm is the control plane", text: "it watches actual lattice state over NATS and continuously reconciles it against a declarative OAM Application manifest." },
    { lead: "A capability provider is not a component", text: "httpserver is a native binary wasmCloud runs as its own process, specifically to hold a capability — an open TCP socket — a sandboxed component cannot hold itself." },
  ],
  "wash 0.43.0 bundles three separately versioned, pinned binaries: nats-server, wadm, and the wasmcloud host itself — wash 2.x, which folds the host into the CLI, is still RC-only and not what this book runs. NATS is the lattice's message bus: every component invocation, every link between a component and a provider, and every host-to-wadm status update travels over NATS subjects, and any number of hosts can join the same subject space, which is what makes it a lattice rather than a fixed cluster. The wasmcloud host actually runs components and capability providers as supervised OS processes and exposes lattice operations directly. wadm is the control plane that makes a declarative OAM manifest true, continuously comparing actual lattice state against it. A capability provider like httpserver is not a component by design: it is a native binary holding a capability — an open TCP listener — a sandboxed component structurally cannot hold on its own.");

diagramBulletsSlide("RUNTIMES · SELF-HEALING", "Reconciled, not restarted by hand", "15-wadm-self-heal-loop",
  [
    { lead: "wash scale component --max-instances 0 talks to the host directly", text: "no manifest involved — the host obeys immediately, imperatively." },
    { lead: "The provider's listener stays bound through the outage", text: "so the failure mode is HTTP 500 — the provider accepts the connection and finds no component instance to dispatch to." },
    { lead: "wadm compares desired state against actual state continuously", text: "spreadscaler instances: 1 in the manifest versus zero actually running — the instant it sees drift, it issues its own command." },
    { lead: "Recovery measured at two seconds", text: "with no second deploy and nobody touching the manifest — the same shape as a Kubernetes Deployment controller replacing a deleted pod." },
  ],
  "The outage is manufactured imperatively: wash scale component --max-instances 0 talks straight to the host, bypassing wadm entirely, and the host obeys immediately. The httpserver provider's TCP listener stays bound the whole time, because it is a separate process nothing told to stop, so the observed failure during the outage is a real HTTP 500 — the provider accepts the connection, tries to dispatch over wrpc, and finds no component instance to hand it to. wadm's reconcile loop is watching the identical NATS subjects the host publishes to, continuously comparing wadm.yaml's declared spreadscaler instance count against the actual count; the instant it sees drift it issues its own scale command, no human and no second deploy involved. A real capture shows recovery in two seconds, the same shape as a Kubernetes Deployment controller replacing a pod kubectl delete pod removed, just at the lattice layer instead of the cluster layer.");

diagramBulletsSlide("RUNTIMES · ONE ARTIFACT", "One app.wasm, two execution models", "16-same-bytes-two-runtimes",
  [
    { lead: "Built once, run twice", text: "wasmtime serve -S cli and the wasmCloud lattice both load the identical sha256 — no rebuild, no runtime-specific variant." },
    { lead: "Both sides assert the identical JSON and the identical 404", text: "on different ports, under two completely different execution models." },
    { lead: "One real gap, named rather than hidden", text: "wasmCloud silently ignores the exported cargo-tracker resource — a warning, not a failure — because the lattice has no resource-method invocation path." },
    { lead: "The choice is about ownership, not raw capability", text: "wasmtime owns a single process with no built-in restart; wasmCloud owns a lattice and trades more moving parts for self-healing and multi-host scale-out." },
  ],
  "app.wasm is built exactly once, by wac-plugging the Part 2 Rust provider under the Part 3 HTTP front door and validating the result, and the identical sha256 then runs under wasmtime serve -S cli on one side and inside the wasmCloud lattice via wadm on the other — no rebuild, no recompile, no runtime-specific variant anywhere in the pipeline. Two independent verification scripts hash the same file and assert the identical JSON body for a known cargo id and the identical 404 for an unknown one, on two completely different ports and execution models. One real functional gap is named rather than papered over: the wasmCloud host logs a warning and silently drops the exported cargo-tracker resource, because the lattice has no invocation path for calling a resource's methods across a link — harmless for this chapter's plain-function HTTP path, but a real constraint for any component whose domain logic depends on a caller invoking a resource directly through the lattice.");

// ===== SECTION 5 — ON KUBERNETES ==============================================
divider("5", "On Kubernetes", "Built once, deployed to two clusters — verified live.",
  "Act five is the longest, because this is where most of the book's chapters live. We build once and deploy the same bytes to minikube behind a real ingress and to OpenShift Local behind an edge-TLS Route on a restricted-v2 lattice. We splice components into a running call chain with interposition, adapter, and ambassador patterns, and watch the one substrate difference that actually matters: whether state survives between two calls in a request. We scale with a stock HPA, then with two different KEDA models, and close with what on-cluster observability actually proves about a Wasm workload versus what it merely looks like it proves.");

diagramBulletsSlide("KUBERNETES · BUILD TO DEPLOY", "Same bytes, scratch image, no registry", "18-build-package-load-deploy",
  [
    { lead: "The same app.wasm as every other runtime", text: "the Part 2 provider wac-plugged under the Part 3 HTTP front door — identical sha256, no rebuild." },
    { lead: "A scratch image, not a runtime image", text: "FROM scratch, one COPY, one ENTRYPOINT — no glibc, no shell, about 290 KiB total." },
    { lead: "--provenance=false is required on the build", text: "BuildKit's default attestation turns one image into a manifest list that breaks minikube image load's platform resolution." },
    { lead: "No registry anywhere in the loop", text: "minikube image load copies straight into the node's containerd store; the shim install must run before ingress is enabled, or its containerd restart bounces every Pod twice." },
  ],
  "Nothing about Kubernetes changes the artifact: the app.wasm deployed here is the identical binary chapter 16 ran under both wasmtime and wasmCloud, same sha256. The container image wrapping it is minimal by design — FROM scratch, one COPY, one ENTRYPOINT pointing at the Wasm file directly, no glibc and no shell, landing around 290 KiB total. Docker's BuildKit defaults to emitting a provenance attestation that turns a single image into a manifest list, which breaks minikube image load's platform resolution unless the build explicitly passes --provenance=false. There is no registry anywhere in this pipeline: minikube image load copies the built image straight into the node's own containerd store. Install order matters too — installing the Wasm-aware containerd shim restarts containerd, which bounces every Pod on the node, so doing that before enabling ingress avoids a second flaky reconciliation.");

diagramBulletsSlide("KUBERNETES · MINIKUBE", "Through the real ingress, never around it", "18-minikube-request-path",
  [
    { lead: "curl to a nip.io host, through ingress-nginx, to the Pod", text: "cargo.<minikube-ip>.nip.io resolves with zero DNS provisioning — no /etc/hosts edit, no tunnel, no NodePort." },
    { lead: "The Pod's runtimeClassName selects the shim", text: "RuntimeClass wasmtime routes the Pod to containerd-shim-wasmtime, not the ordinary runc path." },
    { lead: "Readiness is a real 200 behind a session-affinity cookie", text: "stamped only by the matched ingress rule — ingress-nginx's reload window can otherwise serve a 404 look-alike from its default backend." },
    { lead: "Verified live", text: "minikube v1.39.0 on the docker driver with the containerd runtime, Kubernetes v1.37.1, shim v0.6.1, ingress-nginx v1.15.1." },
  ],
  "The full live path is a curl to a nip.io hostname, through ingress-nginx, to a Service, to a Pod whose runtimeClassName of wasmtime routes it to containerd-shim-wasmtime instead of the ordinary runc path — a two-line RuntimeClass object is the entire mechanism. nip.io resolves <ip>.nip.io with zero DNS provisioning, so the whole path runs through the real ingress controller rather than around it with a tunnel or a NodePort. Readiness here means a real HTTP 200 behind a session-affinity cookie that only the matched ingress rule ever stamps, which matters because ingress-nginx's asynchronous config reload can otherwise serve a 404 look-alike from its own default backend during the reload window — a real failure mode this book's verification script had to account for, not a hypothetical one.");

diagramBulletsSlide("KUBERNETES · OPENSHIFT LOCAL", "An edge-TLS Route, CA-verified", "19-crc-request-path",
  [
    { lead: "curl --cacert, never -k, never port-forward", text: "OpenShift Local signs its router cert from the cluster's own ingress CA, appended to the system trust bundle first." },
    { lead: "The Service has no selector", text: "a hand-written EndpointSlice routes to the wasmCloud host Pod instead of label matching." },
    { lead: "Deleting the host Pod mid-request recovers with zero redeploy", text: "a Kubernetes-Deployment-level recreation — a different mechanism than wadm's own lattice-level self-healing." },
    { lead: "The provider trait must be daemonscaler, not spreadscaler", text: "only daemonscaler creates the Service a Route can target — skip it and wadm reports healthy with nothing to route to." },
  ],
  "The CRC path is CA-verified end to end: OpenShift Local signs its router certificate from the cluster's own ingress CA, pulled from a ConfigMap and appended to the system trust bundle, so every request runs with curl --cacert rather than -k, a port-forward, or a NodePort. The Service in front of the wasmCloud host has no selector at all — a hand-written EndpointSlice does the routing instead of label matching, because the operator's own reconciliation owns that wiring. A resilience test deletes the host Pod mid-script and the Kubernetes Deployment the operator manages recreates it with zero redeploy, a mechanism distinct from wadm's own roughly two-second lattice-level self-healing from the runtimes section — this one operates at the Kubernetes layer, underneath the lattice. One easy-to-miss requirement: the httpserver provider's trait must be daemonscaler, not spreadscaler, because only daemonscaler triggers Service creation at all.");

diagramBulletsSlide("KUBERNETES · OPENSHIFT LOCAL", "restricted-v2, one namespace, one UID", "19-operator-lattice-topology",
  [
    { lead: "Every Pod lands on the identical namespace-assigned UID", text: "NATS, wadm, both host replicas, and the operator — no anyuid anywhere, in a dedicated namespace, never default." },
    { lead: "One chart edit, not a broad exception", text: "null out wadm's hardcoded runAsUser and runAsGroup while keeping every other hardening the chart already ships with." },
    { lead: "A narrow RBAC grant, not an SCC exception", text: "the operator's EndpointSlice write needs its own ClusterRole for endpoints/restricted — found live, fixed without touching SCCs." },
    { lead: "WasmCloudHostConfig pins the host version explicitly", text: "1.9.1, not the chart's older bundled default — a version mismatch there produces a reachable-but-500 Route." },
  ],
  "The whole lattice runs under restricted-v2 with no exceptions: NATS, wadm, both host replicas, and the operator itself all land on the identical namespace-assigned UID from a dedicated project's UID range, never the default namespace, which runs under a permissive SCC that would prove nothing about this constraint. Only one chart edit was needed to get there — nulling out wadm's own hardcoded runAsUser and runAsGroup, which fall outside the namespace's assigned range, while leaving its other hardening, non-root, dropped capabilities, seccomp, untouched. A real RBAC gap surfaced live: the operator's hand-written EndpointSlice write was rejected until its ServiceAccount got a narrow ClusterRole for endpoints/restricted, fixed with RBAC rather than an SCC exception. The WasmCloudHostConfig custom resource pins the host version explicitly to 1.9.1 rather than trusting the chart's older bundled default, because a host/provider wRPC version mismatch produces a Route that answers but returns 500.");

diagramBulletsSlide("KUBERNETES · INTERPOSITION", "Import and export the same interfaces", "20-interposition-chain",
  [
    { lead: "A symmetric world is the whole mechanism", text: "importing and exporting the identical patterncatalyst:cargo interfaces is what lets a component splice into the middle of a call chain." },
    { lead: "Two type trees for one interface", text: "wit-bindgen generates a distinct import-side and export-side Rust type for the same logical shape — a hand-written conv module bridges them field by field." },
    { lead: "minikube composes at build time, CRC links at deploy time", text: "two wac plug calls produce one filtered binary; three wasmCloud components wired by link traits reroute calls with zero rebuild." },
    { lead: "The same policy, enforced identically on both substrates", text: "an embargoed destination returns 400 before reaching the provider; an unknown id returns the provider's own real 404." },
  ],
  "A component that both imports and exports the identical patterncatalyst:cargo interfaces is the entire interposition mechanism — that symmetric world is what lets wac plug or a wasmCloud link splice it into the middle of a call chain that otherwise runs straight from front door to provider. The mechanical cost is real: wit-bindgen generates a distinct Rust type tree for the import side and the export side of the same logical interface, so a filter needs a hand-written conversion module translating field by field between them, the single largest mechanical code block in any of this book's interposers. The two substrates wire the same filter in at different times — minikube composes it at build time with two wac plug calls into one filtered binary, CRC links three separate wasmCloud components together at deploy time with zero rebuild. Either way the policy is identical: an embargoed destination returns 400 before the real provider is ever called, and an unknown id still returns the provider's own 404.");

diagramBulletsSlide("KUBERNETES · STATE CONTRAST", "200 on one substrate, 404 on the other", "20-state-contrast",
  [
    { lead: "The identical request returns different answers", text: "a book-then-get round trip succeeds on minikube and misses on CRC — same code, same WIT world, same request." },
    { lead: "The provider keeps state in its own linear memory", text: "a thread-local HashMap that only survives within one component instance." },
    { lead: "minikube's wac-plug composite is one instance per request", text: "so a booking's write is visible to the read that follows it, within that same request." },
    { lead: "wasmCloud gives every invocation a fresh instance", text: "book-cargo runs on instance A, get-cargo on a brand-new instance B, whose state was never touched — stateless by design, not by accident." },
  ],
  "This is the single biggest substrate divergence in the whole book, and it shows up as the same request returning two different answers. The provider's state lives in a thread-local HashMap — ordinary process memory that only survives within one component instance. minikube's wac-plug composite runs as one component instance per HTTP request, so a booking written by book-cargo is visible to the get-cargo call that reads it back in the same request, and the response is a clean 200. wasmCloud's runtime links give every invocation a fresh instance with reset linear memory, by design — book-cargo runs on instance A, get-cargo runs on a brand-new instance B whose HashMap was never touched, and the result is the provider's own correct 404. Nothing is broken on either side; both substrates behave exactly as designed, which is precisely why this is worth a slide of its own rather than a footnote.");

diagramBulletsSlide("KUBERNETES · ADAPTER", "Flat fields in, structured records out", "21-adapter-shape-translation",
  [
    { lead: "The legacy shape has no structured location", text: "flat UN/LOCODE strings and renamed fields, plus a legacy-service-level enum the canonical model has no concept of at all." },
    { lead: "Two symmetric functions do the whole job", text: "to_legacy flattens a RouteSpec; from_legacy re-inflates it through a small lookup table." },
    { lead: "Every request round-trips through both functions", text: "canonical to legacy and back, before the real provider is ever called — proof the translation is lossless for every field the JSON surfaces." },
    { lead: "The same instance-per-request state rule applies here too", text: "the identical 404-not-200 split from the interposition chain reappears with the adapter sitting in the same slot." },
  ],
  "The adapter's legacy interface carries no structured location at all: flat UN/LOCODE strings under renamed fields, plus a legacy-service-level enum — economy or priority — the canonical model has nowhere to carry. Two symmetric functions do the entire job: to_legacy flattens a RouteSpec into that flat shape, defaulting service level to economy since canonical has no equivalent field, and from_legacy re-inflates it through a small lookup table mapping known UN/LOCODEs back to names and countries. Every request this adapter handles round-trips through both functions, canonical to legacy and back, before the real provider is ever called, which is the adapter's own proof that the translation is lossless for every field the cargo JSON actually surfaces. And because the adapter sits in the identical interposition slot as the filter, the identical state-contrast finding reappears here unchanged: 200 on minikube, the provider's own 404 on CRC.");

diagramBulletsSlide("KUBERNETES · AMBASSADOR", "Outbound calls, owned by one component", "21-ambassador-egress-grant",
  [
    { lead: "The ambassador reuses the sockets component unedited", text: "the same backoff-and-jitter retry loop from the interfaces section, now sitting in front of an outbound call." },
    { lead: "The grant is a link trait, not a code change", text: "the identical component behaves differently only because the host — or wasmCloud's link — decided to grant network access." },
    { lead: "A positive and a negative control, side by side", text: "with the link, an unreachable id still returns the provider's real 404; without it, the Service never gets an endpoint and the Route answers 500 for nobody." },
    { lead: "minikube's proof is a local smoke test, not a live Pod", text: "the raw shim exposes no outbound-network knob at all — a named real gap, not a workaround." },
  ],
  "The ambassador pattern here is literally the sockets component from the interfaces section, reused unedited, with its retry-and-backoff loop now sitting in front of an outbound call instead of a demo client. Nothing in the component changes between being denied network access and being granted it; the only difference is a wasmCloud link trait on CRC, or a host-side flag locally — the capability grant is entirely outside the compiled binary. CRC's proof runs a positive and a negative control side by side: with the link present, a request for an unreachable id still returns the provider's real 404, proving the outbound hop actually landed; with the link removed as a transient negative control, the front door's cargo import goes unsatisfied, the operator-created Service gets zero endpoints, and the edge Route answers 500 for nobody. minikube's own proof stays local rather than live, because the raw containerd shim exposes no outbound-network knob at all — named here as a real current gap, not quietly worked around.");

diagramBulletsSlide("KUBERNETES · SCALING", "A stock HPA works, unmodified", "22-hpa-two-substrates",
  [
    { lead: "A Wasm Pod is cgrouped exactly like a runc Pod", text: "the shim reports into the same cgroup hierarchy cAdvisor reads — no Wasm-specific controller is needed for CPU-based scaling to function." },
    { lead: "CRC has no per-component Kubernetes object to autoscale", text: "the operator exposes spreadscaler.instances on the wadm Application instead — scaling happens inside one host Pod, invisible to anything watching Kubernetes objects." },
    { lead: "The httpserver provider trait must stay daemonscaler", text: "even once the component itself switches to spreadscaler — only daemonscaler triggers the Service a Route can reach." },
    { lead: "Both substrates scale something real", text: "a Kubernetes Deployment's replica count on one side, a lattice's instance count on the other — neither is cosmetic." },
  ],
  "A plain autoscaling/v2 HPA works against the raw-shim Deployment with no Wasm-specific controller anywhere, because a Wasm Pod is cgrouped and metered by the kubelet exactly like an ordinary runc Pod — the shim reports into the same cgroup hierarchy cAdvisor reads, which metrics-server and the HPA controller consume unmodified. CRC has no equivalent Kubernetes object to point an HPA at: the wasmCloud operator exposes spreadscaler.instances on its own Application manifest instead, and scaling happens entirely inside one host Pod, invisible to anything watching Kubernetes objects from outside. One constraint carries over from the deploy chapters regardless of which scaler is in play: the httpserver provider's trait has to stay daemonscaler, because only daemonscaler ever creates the Service a Route can target. Both mechanisms scale something real — a Deployment's replica count, or a lattice's own instance count — neither is a cosmetic knob.");

diagramBulletsSlide("KUBERNETES · SCALING", "A stock HPA, but no CPU signal to scale on", "22-cold-start-scaling-math",
  [
    { lead: "The finding: HPA is correctly wired and never fires", text: "ScalingActive true, a valid metric found — and the Deployment holds at one replica regardless." },
    { lead: "Measured under real load, not assumed", text: "three load generators driving 192 concurrent request loops, and cargo-http still sits at about 2% of its CPU target." },
    { lead: "A cheap, stateless Wasm handler gives CPU no signal to react to", text: "the conclusion the chapter draws directly: this workload needs a concurrency-based trigger, not a CPU-based one." },
    { lead: "Kubernetes's default scale-down window assumes JVM-class warm-up", text: "a shim-hosted component starts serving within single-digit milliseconds, so the default 300-second window buys this workload nothing." },
  ],
  "This is the chapter's headline finding, stated directly rather than buried: the HPA is correctly wired — its conditions read ScalingActive true and a valid metric found — and it still holds at exactly one replica, because cargo-http's CPU usage never approaches its target under real measured load. Three load-generator Pods together drive 192 concurrent request loops and cargo-http still sits around two percent of its fifty-millicore target. The conclusion the chapter draws directly is that a cheap, stateless Wasm handler gives CPU-based autoscaling no signal to react to at all, and the fix is a concurrency-based trigger instead — exactly what the next chapter's KEDA HTTP add-on provides. A second mismatch compounds it: Kubernetes's default 300-second scale-down stabilization window is sized for JVM-class warm-up risk, and a shim-hosted component that starts serving within single-digit milliseconds gets nothing from that default except pure added latency.");

diagramBulletsSlide("KUBERNETES · KEDA", "Concurrency for HTTP, lag for Kafka", "23-two-keda-models",
  [
    { lead: "HTTPScaledObject scales the same raw-shim Deployment from zero", text: "a concurrency target of one request, KEDA's HTTP add-on fronting it through an ExternalName bridge." },
    { lead: "A plain ScaledObject scales a different Deployment entirely", text: "cargo-kafka-host, a native rdkafka consumer embedding wasmtime per message — the raw shim has no long-lived-subscription binding at all." },
    { lead: "Measured cold start: 4.414 seconds, zero to served", text: "dominated by Kubernetes scheduling, not by component startup — the earlier chapter's millisecond-class start is most of why this number is this low." },
    { lead: "The two CRD shapes don't share a field name", text: "HTTPScaledObject nests replica bounds under spec.replicas; the plain ScaledObject uses a top-level minReplicaCount — an easy cross-contamination mistake." },
  ],
  "Two distinct KEDA custom resources cover two different triggers. HTTPScaledObject, from KEDA's HTTP add-on, scales the identical raw-shim cargo-http Deployment from the scaling chapters by request concurrency, with a target of a single in-flight request and bounds of zero to five replicas; it needs a same-namespace ExternalName Service bridging to the add-on's interceptor, since an Ingress object can't cross namespaces on its own. A plain ScaledObject with a kafka trigger scales an entirely different Deployment, cargo-kafka-host, a native process embedding wasmtime and consuming Kafka directly, because the raw containerd shim has no binding for a long-lived message subscription at all. Measured cold start for the HTTP path is 4.414 seconds from zero replicas to a served response, dominated by Kubernetes scheduling rather than by the component itself. The two CRDs don't even share a field name for the same concept: watch for spec.replicas on one and a top-level minReplicaCount on the other.");

diagramBulletsSlide("KUBERNETES · KEDA", "Lag in, instances out, lag back to zero", "23-kafka-lag-flow",
  [
    { lead: "A burst of messages raises real consumer-group lag", text: "KEDA reads it directly and scales cargo-kafka-host from zero to several replicas — no second control plane in between." },
    { lead: "Each delivered message gets a fresh component instance", text: "a new wasmtime Store per message against the same handle-message export, with the offset committed only after the call returns." },
    { lead: "The component itself never imports Kafka at all", text: "kafka-app.wasm is wac-plugged against the Part 2 provider ahead of time — its only unresolved import at runtime is WASI." },
    { lead: "Drain-on-poison, not retry-forever", text: "a malformed message is committed past rather than wedging the whole consumer group — a dead-letter topic is named as the production follow-up, not built here." },
  ],
  "A burst of pipe-delimited messages lands on a six-partition Kafka topic and raises real consumer-group lag, which KEDA reads directly and uses to scale the cargo-kafka-host Deployment from zero to several replicas with no second control plane mediating the decision. Each delivered message drives a brand-new wasmtime Store and component instance against kafka-app.wasm's handle-message export, with the Kafka offset committed only after that call returns — at-least-once delivery, by design. The component itself has no idea Kafka exists: kafka-app.wasm is wac-plugged against the Part 2 cargo provider at build time, exactly like the interposition chapter's technique, so its only unresolved import at runtime is WASI, and the native rdkafka consumer owns the broker connection entirely outside the sandbox. A malformed message is committed past rather than retried forever, so one bad record can't wedge the whole consumer group; a dead-letter topic is named as the real production follow-up, not built in this chapter.");

diagramBulletsSlide("KUBERNETES · OBSERVABILITY", "The shim and the host, not the guest", "24-otel-two-emitters-pipeline",
  [
    { lead: "Neither substrate ever emits guest-authored telemetry", text: "wasi-otel is RC-only — every signal here describes the platform under the component, never the component's own domain logic." },
    { lead: "minikube's shim has emitted traces by default since runwasi v0.5.0", text: "no flag, no annotation — controlled entirely by OTEL_EXPORTER_OTLP_* env vars on the containerd process itself, a node-level change." },
    { lead: "CRC's wasmCloud host emits all three signals natively", text: "traces, metrics, and logs together, because the host process sees every RPC dispatch — configured directly on the WasmCloudHostConfig CR." },
    { lead: "A running shim does not pick up new env retroactively", text: "only a shim spawned after containerd restarts does, so the app Pod needs deleting and redeploying after enabling tracing." },
  ],
  "Neither substrate emits telemetry the guest component authored itself — wasi-otel remains RC-only and outside this book's pinned toolchain, so every signal describes the platform underneath the component, never its own domain logic. On minikube, containerd-shim-wasmtime has emitted OTel traces by default since runwasi v0.5.0, controlled by nothing in Kubernetes at all: purely OTEL_EXPORTER_OTLP_* environment variables set on the containerd process itself, a node-level systemd change, not a cluster-level one. On CRC, the wasmCloud host emits all three signal types natively and together, because the host process sits at every RPC dispatch boundary and exposes that directly through the WasmCloudHostConfig custom resource's own observability block. One operational gotcha carries real cost: a shim process that is already running does not pick up newly set environment variables, so enabling tracing requires restarting containerd and then deleting and redeploying the app Pod so a freshly spawned shim inherits the new settings.");

diagramBulletsSlide("KUBERNETES · OBSERVABILITY", "One real signal, not three", "24-signal-provenance",
  [
    { lead: "minikube's metrics and logs are not OTel at all", text: "still plain cgroup CPU via metrics-server and container stdout via kubelet — only the trace row is the shim's own signal." },
    { lead: "A green dashboard can still mislead", text: "the observability stack's own self-monitoring responds too — a reviewer skimming three checks could wrongly conclude three signals about the workload arrived." },
    { lead: "CRC's pipeline answers a different class of question", text: "link-layer behavior, like the book-then-get state contrast, is only actually observable — not just inferable from status codes — on the CRC pipeline." },
    { lead: "Treat the minikube trace as a liveness fact", text: "proof the Pod was scheduled and completed invocations, not a statement about what happened at the RPC level." },
  ],
  "On minikube, only one of the three observability signals is actually the shim's own: metrics still come from plain cgroup CPU through metrics-server, and logs still come from ordinary container stdout through the kubelet — neither one is OTel-emitted, only the trace row is. That distinction matters because a verification script hitting the stack's Prometheus and Loki endpoints gets real, green responses either way, since those describe the observability stack's own self-monitoring rather than the Wasm workload; a reviewer skimming three passing checks could wrongly conclude three real signals about the component arrived, when only one did. CRC's native pipeline answers a different class of question — link-layer behavior, like the book-then-get state contrast from earlier in this section, is only actually observable there, not merely inferable from an HTTP status code the way it is on minikube. The framing to keep: treat the minikube trace as proof a Pod was scheduled and completed invocations, not as a statement about what happened at the RPC level.");

// ===== SECTION 6 — RUST-NATIVE DEVIATIONS =====================================
divider("6", "Rust-native deviations", "Two unrelated 'wasm' technologies, one mesh.",
  "Act six covers two Rust-specific shapes the book treats as deviations from the Component Model mainline. Istio's proxy-wasm filter is a different Wasm technology entirely, with no WIT world and no component boundary, coexisting in the same mesh as the Component Model app it sits in front of. wasi-nn closes the act with a component that classifies an image through a host-provided inference backend, proving the same guest runs unmodified against any backend a host chooses to implement.");

diagramBulletsSlide("DEVIATIONS · ISTIO", "An ECDS push, not a Deployment", "25-wasmplugin-request-path",
  [
    { lead: "A WasmPlugin names an OCI image", text: "Istio's fetcher pulls it and reads /plugin.wasm — no Kubernetes scheduler involved at all." },
    { lead: "The selector targets the gateway's Envoy, not the app", text: "istio: ingressgateway, living in istio-system, never the cargo-http namespace." },
    { lead: "istiod pushes the filter directly to matching Envoys", text: "an Extension Config Discovery Service update, not a Pod rollout." },
    { lead: "Verified live on both clusters", text: "a missing x-cargo-tenant header returns 403; a present one returns 200 plus an x-cargo-filtered-by header and the real cargo JSON." },
  ],
  "A WasmPlugin custom resource names an OCI image, and Istio's own fetcher pulls it and reads a plugin.wasm file out of it — there is no Kubernetes Deployment, no scheduler, nothing resembling a Pod rollout in this mechanism at all. Its selector targets istio: ingressgateway, the mesh's own Envoy, and the resource lives in istio-system rather than in the cargo-http application namespace it ends up affecting. istiod watches WasmPlugin resources and pushes matching Envoys an Extension Config Discovery Service update directly, which is how the filter takes effect without touching a single application Pod. The whole path was verified live on both clusters: a request missing the x-cargo-tenant header gets a 403, and a request carrying it gets a 200 with an x-cargo-filtered-by header stamped on the response, alongside the real cargo JSON — minikube and OpenShift Service Mesh 3 both confirmed.");

diagramBulletsSlide("DEVIATIONS · ISTIO", "A core module and a component, two pods", "25-two-wasm-worlds-in-the-mesh",
  [
    { lead: "The proxy-wasm filter has no WIT world at all", text: "plain cargo build, crate proxy-wasm 0.2.5, no [package.metadata.component] — the crate's own traits are the ABI." },
    { lead: "It runs inside Envoy's own process", text: "the ingress gateway's proxy-wasm VM is the host — not a sidecar, not a separate Pod." },
    { lead: "The Component Model app is the unrelated technology next to it", text: "wasi:http/incoming-handler, hosted by containerd-shim-wasmtime under its own RuntimeClass, in its own Pod." },
    { lead: "One RuntimeClass Pod can't carry an injected sidecar", text: "a Pod running one container runtime for every container it holds can't also carry an Envoy sidecar needing the ordinary runc runtime." },
  ],
  "This slide names the thing a casual reading could blur: two unrelated technologies both called Wasm coexist in one mesh. The proxy-wasm filter has no WIT world, no bindgen output, no [package.metadata.component] block at all — a plain cargo build against the proxy-wasm 0.2.5 crate, where the crate's own traits are the entire ABI, running inside Envoy's own process as that process's embedded proxy-wasm VM, not as a sidecar and not as a separate Pod. The Component Model app sitting behind it is the unrelated technology: a wasi:http/incoming-handler component hosted by containerd-shim-wasmtime under its own RuntimeClass, in its own Pod. The two can't even share infrastructure if a team wanted them to — a Pod running one container runtime for every container it holds structurally cannot also carry an injected Envoy sidecar that needs the ordinary runc runtime, true on both minikube and CRC.");

codeSlide("DEVIATIONS · ISTIO", "The filter's whole policy, in one match", "rust · proxy-wasm 0.2.5",
  [
    "impl HttpContext for CargoFilter {",
    "    fn on_http_request_headers(&mut self, _n: usize, _eos: bool) -> Action {",
    "        match self.get_http_request_header(TENANT_HEADER) {",
    "            Some(tenant) => {",
    "                log(LogLevel::Info, &format!(\"allowing request for tenant '{tenant}'\")).ok();",
    "                Action::Continue",
    "            }",
    "            None => {",
    "                log(LogLevel::Warn, &format!(\"denying request missing '{TENANT_HEADER}'\")).ok();",
    "                self.send_http_response(403, vec![(\"content-type\", \"application/json\")],",
    "                    Some(DENY_BODY.as_bytes()));",
    "                Action::Pause",
    "            }",
    "        }",
    "    }",
    "    fn on_http_response_headers(&mut self, _n: usize, _eos: bool) -> Action {",
    "        self.set_http_response_header(FILTERED_BY_HEADER, Some(FILTER_NAME));",
    "        Action::Continue",
    "    }",
    "}",
  ],
  "istio-wasmfilter/src/lib.rs:59-89 — a proxy-wasm core module, not a Component",
  "The entire filter's policy fits in one match on a header lookup. A present x-cargo-tenant header logs who was allowed and returns Action::Continue, letting Envoy proceed to the upstream cluster. A missing header logs a warning, calls send_http_response directly from inside the filter to answer with a local 403 and a JSON body, and returns Action::Pause, which stops the request from ever reaching cargo-http. On the response path, on_http_response_headers stamps an x-cargo-filtered-by header naming the filter before letting the response continue back to the client — the signal a test or an operator uses to confirm the filter actually ran, not just that a 200 happened to come back. None of this is WIT-generated code; HttpContext is a plain trait from the proxy-wasm crate, implemented by hand.");

diagramBulletsSlide("DEVIATIONS · WASI-NN", "Load a graph, build a tensor, compute", "27-wasi-nn-inference-path",
  [
    { lead: "Four WIT interfaces, no cargo contract at all", text: "tensor, graph, inference, and errors from the vendored wasi:nn package — this component classifies a photo, not a booking." },
    { lead: "The guest builds the input tensor itself", text: "decode, resize to 224x224, reorder to BGR and NCHW layout, cast to f32 — all in pure Rust, since wasm32-wasip1 can't link a native codec." },
    { lead: "load-by-name resolves a host-registered graph", text: "the host pre-registers it with -S nn-graph=openvino::<dir>, named by the directory's own basename — a host convention, not a WIT guarantee." },
    { lead: "Verified live", text: "a 1001-way softmax, top-5 taken after dropping the background class — container ship classified at 0.910 confidence on the fixture photo." },
  ],
  "This component's WIT world imports exactly four interfaces from the vendored wasi:nn package — tensor, graph, inference, and errors — and nothing from patterncatalyst:cargo at all; it classifies a photo, not a booking, a different domain from everything earlier in this deck. The guest does its own preprocessing because wasm32-wasip1 cannot link a native image codec: a pure-Rust JPEG decoder, a resize to 224 by 224, a channel reorder from RGB to BGR, a layout change to NCHW, and a cast to f32 with no normalization in the guest at all, since normalization is baked into the model graph's own input layer. graph::load_by_name resolves a graph the host pre-registered with a command-line flag, named by that directory's own basename — a host-side naming convention the WIT itself never guarantees. Verified live, the fixture photo classifies as a container ship at 0.910 confidence after the guest drops the softmax's background class and sorts the remaining 1000.");

diagramBulletsSlide("DEVIATIONS · WASI-NN", "Same guest, same WIT, any backend", "27-wasi-nn-portability-map",
  [
    { lead: "Portability means the guest never changes", text: "only the host's compiled-in backend and its -S nn-graph invocation do — the WIT surface is backend-agnostic by design." },
    { lead: "graph-encoding names six backends in the WIT itself", text: "openvino, onnx, tensorflow, tensorflowlite, pytorch, and ggml — all legitimate alternatives behind the identical interface." },
    { lead: "This host is wasmtime built from source with --features wasi-nn", text: "binding a real local OpenVINO install — prebuilt wasmtime releases omit the feature entirely." },
    { lead: "In-process inference is a choice, not a mandate", text: "an external model server is still the right call when a model is large, shared, or scaled independently — the two are not mutually exclusive." },
  ],
  "Portability here means something precise: the identical compiled guest, with its identical wasi:nn WIT imports, runs unchanged against whatever backend a host happens to implement — only the host's compiled-in backend and its -S nn-graph invocation change, never the guest's own code or its WIT surface. The graph-encoding enum names six legitimate backends directly in the WIT itself — openvino, onnx, tensorflow, tensorflowlite, pytorch, and ggml — any of which a different wasi-nn host could implement behind the identical interface this chapter's guest already targets. This chapter's own host is a wasmtime built from source with the wasi-nn feature enabled, binding a real local OpenVINO installation's actual shared libraries, because prebuilt wasmtime releases omit that feature entirely. In-process inference is one legitimate choice among others, not a mandate: an external HTTP model server remains the right call when a model is large, shared across callers, or needs to scale independently of the component calling it.");

// ===== SECTION 7 — FINAL PROJECT ==============================================
divider("7", "Final project, Rust half", "One contract, two languages, one shared filter.",
  "The final project composes everything this deck has covered into one deployment: the Rust and Go composites side by side, fronted by the identical Istio proxy-wasm filter from the deviations section, verified byte-identical to each other on both minikube and OpenShift Local.");

diagramBulletsSlide("FINAL PROJECT · REQUEST PATH", "Two composites, one shared filter", "28-final-project-request-path",
  [
    { lead: "build.sh plugs the same Part 2 and 3 crates into two composites", text: "cargo-rust.wasm, byte-identical to Part 5's app.wasm, and cargo-go.wasm, assembled with the identical wac plug technique." },
    { lead: "Each composite deploys as its own Deployment", text: "runtimeClassName wasmtime, a TCP liveness probe on 8080 — the component has no / route to answer an HTTP probe with." },
    { lead: "Two ingress edges, both verified on minikube", text: "host-based ingress-nginx routing by subdomain, and an Istio Gateway sharing the identical ingressgateway workload chapter 25 already used." },
    { lead: "The same proxy-wasm filter redeploys byte-identical", text: "same name, same namespace, same OCI reference — it gates both languages' traffic with the identical 403/200 contract." },
  ],
  "build.sh plugs the identical Part 2 provider and Part 3 HTTP front door into two separate composites, one per language: cargo-rust.wasm, byte-identical to the app.wasm the runtimes section ran under both wasmtime and wasmCloud, and cargo-go.wasm, assembled with the same wac plug technique against the Go implementation. Each composite deploys as its own Deployment under runtimeClassName wasmtime, with a TCP liveness probe on port 8080 rather than an HTTP one, since this component has no / route to answer a probe with. minikube exposes both through two separate ingress edges at once: host-based ingress-nginx routing by subdomain, and an Istio Gateway sharing the exact ingressgateway workload the deviations section's filter already targets. That filter redeploys completely unchanged here — same name, same namespace, same OCI reference — gating both languages' traffic with the identical 403-without, 200-with contract.");

diagramBulletsSlide("FINAL PROJECT · ONE CONTRACT", "Proved by assembly, not by argument", "28-one-contract-two-languages",
  [
    { lead: "contracts/wit is read by two independent pipelines", text: "cargo-component for Rust, wit-bindgen-go plus TinyGo for Go — and written by neither." },
    { lead: "A build gate checks both composites before packaging", text: "must export wasi:http/incoming-handler, and zero non-wasi import may remain after composition." },
    { lead: "One parameterized Containerfile builds both languages", text: "FROM scratch, one ARG for the wasm path — no per-language Dockerfile fork anywhere." },
    { lead: "verify-minikube.sh asserts the two languages against each other", text: "byte-identical responses, not just each one separately matching an expected string — repeated again on CRC." },
  ],
  "The deck's closing claim is proved by assembly rather than argued in prose: contracts/wit is read by two completely independent build pipelines, cargo-component on the Rust side and wit-bindgen-go paired with TinyGo on the Go side, and is written by neither of them. A build gate runs against both composites before either becomes an OCI image, asserting each exports wasi:http/incoming-handler and that zero non-wasi import survives composition. One parameterized Containerfile, FROM scratch with a single ARG naming the wasm path, builds both language images — there is no per-language Dockerfile anywhere in this project. The verification script goes a step further than every earlier chapter's byte-for-byte checks: it asserts the Rust and Go responses are identical to each other directly, not merely that each separately matches an expected string, and the identical assertion runs again unchanged on CRC.");

// ===== APPENDIX ===============================================================
divider("8", "Appendix", "Reference — keep open in another window.",
  "The appendix is reference material: the commands this deck's code slides assume, the pinned stack versions behind every verified-live claim, and a short glossary of the vocabulary this deck leans on. It is not meant to be read front to back.");

{
  const s = S();
  addContentTitle(s, "APPENDIX · COMMANDS", "Command reference");
  addStatusTable(s, [
    { code: "cargo component build --release", name: "Build", purpose: "Resolves WIT, compiles to wasip1, adapts to a Preview 2 component — one command." },
    { code: "wasm-tools component wit <file>", name: "Inspect", purpose: "Prints the resolved WIT shape embedded in a built component or a package directory." },
    { code: "wasm-tools objdump <file>", name: "Inspect", purpose: "Per-section sizes — checks for DWARF before a trap ever happens." },
    { code: "wac plug --plug <provider> <consumer>", name: "Compose", purpose: "Wires one provider's exports to one consumer's imports by WIT identifier alone." },
    { code: "wasmtime run -S inherit-network <file>", name: "Run", purpose: "Grants the one capability a sandboxed component cannot assume by default." },
    { code: "wasmtime serve -S cli <file> --addr ...", name: "Run", purpose: "Serves a wasi:http/incoming-handler component; -S cli widens the default proxy linker." },
    { code: "wash up -d / wash app deploy <file>", name: "wasmCloud", purpose: "Starts a local lattice; deploys a declarative OAM Application manifest." },
    { code: "minikube image load <image>", name: "Kubernetes", purpose: "Loads a built image straight into the node's containerd store — no registry." },
  ], { colW: [3.70, 1.90, 6.49], rowH: 0.45 });
  addNotes(s, "A one-page map of the commands this deck's code and diagram slides assume a reader already has open in another terminal. cargo component build is the one command that folds WIT resolution, the wasip1 compile, and the Preview 2 adapt step together. wasm-tools component wit and objdump are the two cheapest debugging tools, read before anything fails. wac plug is the composition mechanism behind both chapter 8's consumers and every interposition pattern in the Kubernetes section. The two wasmtime invocations show the same binary behaving differently purely because of a host-side flag — inherit-network for sockets, -S cli for serving HTTP. wash covers the wasmCloud side, and minikube image load is the one Kubernetes command standing in for an entire registry push-and-pull most clusters would otherwise need.");
}

{
  const s = S();
  addContentTitle(s, "APPENDIX · STACK", "Pinned versions");
  addStatusTable(s, [
    { code: "cargo-component 0.21", name: "Rust toolchain", purpose: "WIT resolution, the wasip1 compile, and the Preview 2 adapt, in one command." },
    { code: "wasmtime 50", name: "Runtime", purpose: "Engine/Store/Linker embedding; the wasmtime serve and run CLIs." },
    { code: "wash 0.43.0", name: "wasmCloud", purpose: "Bundles nats-server 2.11.3, wadm 0.21.1, and the wasmcloud host 1.9.1." },
    { code: "minikube v1.39.0", name: "Cluster", purpose: "Docker driver, containerd v2.3.4 runtime, Kubernetes v1.37.1." },
    { code: "containerd-shim-wasmtime v0.6.1", name: "K8s runtime", purpose: "The runwasi project's shim; RuntimeClass handler name wasmtime." },
    { code: "OpenShift Local (CRC) 2.64.0", name: "Cluster", purpose: "OpenShift 4.22.14; wasmcloud-platform chart 0.1.2, operator 0.4.0." },
    { code: "Strimzi 1.3.0 / Kafka 4.3.1", name: "Kafka", purpose: "KRaft mode, a six-partition topic behind KEDA's lag trigger." },
    { code: "KEDA HTTP add-on 0.16.0", name: "Scaling", purpose: "HTTPScaledObject — concurrency-based, scale to zero." },
    { code: "OpenVINO 2026.4.1", name: "wasi-nn backend", purpose: "Bound by a wasmtime built from source with --features wasi-nn." },
  ], { colW: [3.70, 1.90, 6.49], rowH: 0.40 });
  addNotes(s, "The pinned versions behind every verified-live claim this deck makes — these drift, so re-check them against the repository before quoting them elsewhere. cargo-component and wasmtime 50 anchor the Rust authoring and embedding chapters. wash's own version number hides three separately pinned binaries underneath it, which matters when something in the lattice behaves differently than the wasmCloud documentation describes. minikube and the shim anchor every Kubernetes claim on that cluster path; OpenShift Local and the wasmcloud-platform chart anchor the restricted-v2 path. Strimzi and Kafka back the KEDA lag-based scaling chapter; the KEDA HTTP add-on backs its concurrency-based sibling. OpenVINO is the one dependency outside the wasi-nn WIT interface itself — a different backend would carry a different version here with nothing else on this page changing.");
}

leadSlide("APPENDIX · GLOSSARY", "Glossary",
  [
    { lead: "WIT world", text: "a named bundle of imports and exports a component targets at build time." },
    { lead: "Canonical ABI", text: "the mechanical lowering and lifting of a WIT value into and out of linear memory at a component call." },
    { lead: "Reactor vs. command", text: "a reactor exports functions and is called repeatedly; a command exports wasi:cli/run and runs once, like a CLI program." },
    { lead: "Trap", text: "an unrecoverable failure that unwinds the whole component instance — the host sees Err on the call itself, never a domain value." },
    { lead: "Capability", text: "a specific permission — network, filesystem, a clock — a host grants a component explicitly; nothing is ambient." },
    { lead: "Interposition", text: "a component that imports and exports the identical interfaces, spliced into a call chain between a provider and its caller." },
    { lead: "Lattice", text: "wasmCloud's NATS-connected mesh of hosts, with wadm reconciling declared state against actual state." },
    { lead: "RuntimeClass", text: "the Kubernetes object that routes a Pod to a non-default container runtime — here, the Wasm-aware containerd shim." },
  ],
  "A short glossary for the vocabulary this deck leans on repeatedly, aimed at someone comfortable with Rust and Kubernetes but newer to the Component Model. World and the Canonical ABI are the two terms that unlock everything in the authoring section. Reactor versus command explains why some components need a native host and others run directly under wasmtime run. Trap and capability are the two ideas the correctness and interfaces sections build their whole structure on. Interposition and lattice are the two mechanisms behind every Kubernetes pattern in this deck — one splicing a component into a call chain, the other describing wasmCloud's own deployment model. RuntimeClass is the one Kubernetes-native term doing all the work of routing a Pod to a Wasm-aware runtime instead of the default.");

// ===== CLOSING ================================================================
{
  const s = S();
  addContentTitle(s, "CLOSING", "Where to go deeper");
  leadBullets(s, [
    { lead: "The repository", text: "every snippet here is a real file under examples/part2 through part7 — the components, the hosts, the manifests, runnable on minikube and OpenShift Local." },
    { lead: "The book", text: "28 chapters plus a final project, each with a runnable example and a verification footer." },
    { lead: "The other decks", text: "the 101 for the concepts shared across both languages; the 201-go deck covers this identical ground in Go with TinyGo." },
    { lead: "Start at the contract", text: "contracts/wit/ is the one file neither language owns — read it first, and either implementation reads as a straightforward satisfaction of it." },
  ]);
  addNotes(s, "To close: everything in this deck is a real file in the repository, not pseudocode written for a slide — the components, the native hosts, the Kubernetes and wasmCloud manifests, all runnable on both minikube and OpenShift Local exactly as shown. The book carries the full narrative across 28 chapters and a final project, each with a runnable example and its own verification footer. The 101 deck carries the concepts that apply across both languages; the 201-go deck walks this identical arc in Go with TinyGo, which is worth reading specifically where this deck called out a real cross-language gap — TinyGo's reflection limits, its command-adapter startup ordering, its asyncify constraints on sockets. The single best place to start a deeper read is the one file neither language owns: contracts/wit/. Read it first, and every implementation in this repository becomes a straightforward satisfaction of a contract already in hand.");
}

pres.writeFile({ fileName: OUT }).then(() => {
  console.log(`Wrote ${OUT} (${pageNum} slides)`);
});
