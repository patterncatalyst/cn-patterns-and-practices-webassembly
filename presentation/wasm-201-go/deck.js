// deck.js — "Server-Side WebAssembly in Go (TinyGo)" — 201.
// Deep dive, a complete vertical slice in TinyGo/Go. Real code excerpts from
// the go/ examples throughout: part2 cargo provider, part3 http-go/proto-go/
// sockets-go front doors, the Go consumer, and the final-project composite.
// Red Hat house style, 16:9. Build: node deck.js

"use strict";

const H = require("./deck-helpers.js");
const {
  COLOR, FONT, W, PNG, ASSETS,
  newDeck, addFooter, addContentTitle, addBullets, addTwoColBullets,
  addStatusTable, addCodeSlide, addDiagramSlide, addSectionDivider, addNotes,
} = H;

const OUT = "wasm-201-go-r1.0.pptx";
const REV = "r1.0";

const pres = newDeck();
pres.title = "Server-Side WebAssembly in Go (TinyGo) — 201";
pres.author = "Robert Sedor";
pres.company = "Red Hat";
let pageNum = 0;

function S() { const s = pres.addSlide(); pageNum += 1; addFooter(s, pageNum); return s; }
function divider(code, title, subtitle, notes) {
  const s = pres.addSlide(); pageNum += 1; addSectionDivider(s, code, title, subtitle); addNotes(s, notes);
}
function content(eyebrow, title, bullets, notes, opts) {
  const s = S();
  addContentTitle(s, eyebrow, title);
  addBullets(s, bullets, opts || {});
  addNotes(s, notes);
  return s;
}
function diagram(eyebrow, title, png, caption, notes, opts) {
  const s = S();
  addDiagramSlide(s, eyebrow, title, png, caption, opts || {});
  addNotes(s, notes);
  return s;
}
function code(eyebrow, title, lang, lines, caption, notes, opts) {
  const s = S();
  addCodeSlide(s, eyebrow, title, lang, lines, caption, opts || {});
  addNotes(s, notes);
  return s;
}

// ===== COVER ==================================================================
{
  const s = pres.addSlide();
  pageNum += 1;
  s.background = { color: COLOR.white };
  try { s.addImage({ path: `${ASSETS}/cover-panel.png`, x: 0, y: 0, w: W, h: 7.5 }); } catch (e) {}
  s.addText("SERVER-SIDE WEBASSEMBLY · 201", { x: 6.00, y: 1.98, w: 6.90, h: 0.34,
    fontFace: FONT.title, fontSize: 14, bold: true, color: COLOR.red, charSpacing: 5, align: "left", valign: "middle" });
  s.addText([{ text: "Server-Side WebAssembly", options: { breakLine: true } },
             { text: "in Go (TinyGo)" }], {
    x: 5.95, y: 2.42, w: 6.95, h: 2.00, fontFace: FONT.title, fontSize: 44, bold: true, color: COLOR.ink, align: "left", valign: "top" });
  s.addText("A complete vertical slice in TinyGo/Go: WIT bindings, the cargo domain, HTTP/gRPC/sockets interfaces, wasmtime and wasmCloud, Kubernetes, and the final project's Go half.",
    { x: 6.00, y: 4.45, w: 6.80, h: 1.15, fontFace: FONT.body, fontSize: 16, italic: true, color: COLOR.caption, align: "left", valign: "top" });
  s.addText(REV, { x: 11.85, y: 6.10, w: 0.95, h: 0.30, fontFace: FONT.mono, fontSize: 11, color: COLOR.caption, align: "right", valign: "middle" });
  try { s.addImage({ path: `${ASSETS}/logo-candidate-2.png`, x: 11.10, y: 6.78, w: 1.55, h: 0.37 }); } catch (e) {}
  addNotes(s, "This is the 201-go deep dive, built for engineers who will write the Go side of this book's examples, not for an audience deciding whether to adopt WebAssembly at all. Every code slide in this deck is transcribed from the real go/ source tree under examples/ — part2's cargo provider, part3's http-go/proto-go/sockets-go front doors, the Go consumer, and the final project's cargo-go.wasm composite. The throughline is TinyGo: the standard Go compiler cannot emit a Component Model binary today, so every build recipe in this deck runs through TinyGo's wasm32 target instead, and this deck shows exactly where that boundary sits and what it costs. The arc: authoring in Go (bindings, the domain, the first component, composition), correctness (debugging and the two failure channels), the three protocol interfaces (HTTP, gRPC, sockets), the two runtimes (wasmtime and wasmCloud), Kubernetes (the shim, both cluster paths, interposition, scaling, observability), the Go-leaning Spin deviation, and the final project's Go half. Thirty-five to forty-five minutes, assumes the audience has the 101 deck's concepts already.");
}

// ===== AGENDA ==================================================================
{
  const s = S();
  addContentTitle(s, "201-GO · THE DEEP DIVE", "A complete vertical slice, Go side");
  addTwoColBullets(s,
    ["Authoring in Go — TinyGo vs. the standard compiler, WIT bindgen, the shared cargo domain, the first component, and wac plug composition",
     "Correctness — reading a component without running it, and the two failure channels a call across the boundary can produce",
     "Interfaces — wasi-http, Protobuf-in-a-component plus a native gRPC bridge, and capability-scoped outbound sockets"],
    ["Runtimes — wasmtime embedding and the wasmCloud lattice, the same portability story Part 2 already proved for Go",
     "On Kubernetes — the containerd shim, both cluster paths, interposition, HPA/KEDA scaling, and on-cluster observability",
     "A Go-leaning deviation (Spin/SpinKube), and the final project's Go half — one contract, two languages, side by side"]);
  addNotes(s, "Seven sections, roughly sixty slides. Authoring in Go opens with why the standard go build cannot finish this job today, then walks the full TinyGo pipeline: WIT bindgen, the cargo domain, the first component's exports, the cargo-tracker resource, and wac plug composition including the command-adapter trap the Go consumer hits that the Go provider never does. Correctness covers reading a component statically and the recoverable-error-versus-trap distinction, in Go's idiom (cm.Err/cm.OK versus a bare panic). Interfaces is three real protocol surfaces: wasi-http, where TinyGo's reflection-free protobuf wire codec earns its own slide because the standard library traps at runtime under TinyGo, and wasi:sockets, where the Go build validates but has no clean runtime path on TinyGo 0.43. Runtimes and Kubernetes carry forward the portability claim Part 2 already proved in Go: one WIT contract, byte-identical behavior, regardless of which runtime or substrate hosts it. The deviation section is Spin/SpinKube, and the final project closes on cargo-go.wasm serving the identical JSON as its Rust sibling through the same edge. Every code slide names its source file so this deck stays a tour of the real examples/ tree.");
}

// ===== SECTION 1 — AUTHORING IN GO =============================================
divider("1", "Authoring in Go", "TinyGo closes a gap the standard Go compiler leaves open.",
  "Opens the authoring section. The spine: why TinyGo is required rather than optional, how wit-bindgen-go turns the shared WIT contract into a Go Exports struct, how the cargo domain's records and enums land in that contract, how the first Go component wires its own implementation into those Exports, and how wac plug composes a Go provider or consumer against either language on the other side. Everything in this section is read from examples/part2-building-components/go and consumer-go, built and verified against the identical patterncatalyst:cargo WIT world the Rust side targets.");

content("AUTHORING IN GO · THE COMPILER GAP", "The standard compiler cannot finish this build",
  ["GOOS=wasip1 GOARCH=wasm go build rejects wit-bindgen-go's own generated bindings: a real, repeatable compiler diagnostic, not a hypothetical.",
   "The cause is pointer width, not a Go-language limitation — go:wasmexport refuses a pointer to a pointerful result or parameter type on Go's 64-bit-pointer Wasm target.",
   "Every WIT result, list, string, and record the Canonical ABI needs produces exactly that pointerful shape, and the rejected signatures live in generated code, not in hand-written main.go.",
   "TinyGo targets wasm32 natively, with none of that restriction, and compiles the identical source and the identical generated bindings unchanged."],
  "This is a precise, mechanical compiler limitation on go:wasmexport's pointer-width check, not a vague claim about relative toolchain maturity. The next slide shows the actual diagnostic text so the claim is verifiable, not asserted.");

code("AUTHORING IN GO · THE REAL DIAGNOSTIC", "go:wasmexport rejects wit-bindgen-go's own output",
  "go1.26.9 · GOARCH=wasm", [
    "$ GOOS=wasip1 GOARCH=wasm go build -o core.wasm .",
    "",
    "# example.com/cargo-go/internal/cargo/patterncatalyst/cargo/handling",
    "internal/.../handling/handling.wasm.go:52:6: go:wasmexport: unsupported",
    "  result type *cm.List[...types.HandlingEvent]",
    "internal/.../handling/handling.wasm.go:61:6: go:wasmexport: unsupported",
    "  result type *string",
    "internal/.../handling/handling.wasm.go:70:6: go:wasmexport: unsupported",
    "  result type *cm.Result[...types.CargoError,struct {},...types.CargoError]",
    "",
    "# example.com/cargo-go/internal/cargo/patterncatalyst/cargo/booking",
    "internal/.../booking/booking.wasm.go:14:6: go:wasmexport: unsupported",
    "  result type *cm.Result[...booking.BookingShape,...types.Booking,...types.CargoError]",
    "internal/.../booking/booking.wasm.go:33:6: go:wasmexport: unsupported",
    "  parameter type *types.Leg",
  ], "Captured verbatim against go1.26.9 — the diagnostics name files wit-bindgen-go generated, never main.go.",
  "Every flagged line sits in a file wit-bindgen-go generated, booking.wasm.go and handling.wasm.go, carrying the //go:wasmexport pragmas the Canonical ABI calls directly. GOOS=wasip1 GOARCH=wasm is Go's 64-bit-pointer Wasm target, and go:wasmexport refuses to accept or return a pointer to a type whose layout would not make sense as a 32-bit Canonical ABI value on the other side of the call. *cm.Result, *cm.List, *string, and *types.Leg are all pointers to pointerful, multi-word structures — exactly the ABI encoding WIT's result, list, string, and record types need for their generated lowering, and exactly what this target's wasmexport check rejects. The compiler's own text even names the fix in the abstract: these shapes would be legal on GOARCH=wasm32, but wasip1/wasm32 has no buildable buildmode on the installed Go, and there is no wasm32 GOEXPERIMENT to opt into. Nothing about rewriting main.go's domain logic would change this outcome — the rejected signatures are generated, not authored.");

diagram("AUTHORING IN GO · TOOLCHAIN", "Go build vs. TinyGo",
  "07-go-build-vs-tinygo",
  "Same source, two compilers: one rejects the pointerful wasmexport signatures, the other accepts them unchanged.",
  "This figure puts the previous slide's diagnostic side by side with its fix. The left panel is GOOS=wasip1 GOARCH=wasm go build, targeting 64-bit Wasm pointers and rejecting *cm.Result, *cm.List, *string, and *types.Leg — no core.wasm is produced. The right panel is tinygo build -target=wasip1, which targets wasm32 natively with no such pointer-width restriction, accepting the identical generated signatures and producing a reactor-mode core.wasm. The source in main.go, the generated bindings under internal/cargo/, and the cm package's own API are exactly the same Go either way — the difference is entirely which compiler turns that source into a wasip1 core module.");

code("AUTHORING IN GO · THE TINYGO BUILD", "A four-step pipeline: generate, compile, embed, adapt",
  "bash · build.sh", [
    "# examples/part2-building-components/go/build.sh",
    "wit-bindgen-go generate -o internal/cargo \\",
    "  -p example.com/cargo-go/internal/cargo \\",
    "  --world cargo \"$CONTRACT_DIR\"",
    "",
    "tinygo build -target=wasip1 -buildmode=c-shared -o core.wasm .",
    "",
    "wasm-tools component embed \"$CONTRACT_DIR\" --world cargo \\",
    "  core.wasm -o embedded.wasm",
    "",
    "wasm-tools component new embedded.wasm \\",
    "  --adapt \"wasi_snapshot_preview1=$ADAPTER\" \\",
    "  -o cargo-go.wasm",
    "",
    "wasm-tools validate cargo-go.wasm",
  ], "examples/part2-building-components/go/build.sh — tinygo 0.43.0, wit-bindgen-go v0.7.0, wasm-tools 1.262.0.",
  "Four steps, each with one job. wit-bindgen-go generate reads contracts/wit and writes a Go package tree under internal/cargo/patterncatalyst/cargo/, one subpackage per WIT interface. -buildmode=c-shared is the setting that makes this a reactor module (_initialize, callable exports, no main entry point run at startup) rather than a command — a cargo provider has to be a reactor because the host instantiates it once and calls book-cargo, get-cargo, and the rest repeatedly across the process's life. component embed attaches the cargo world's Canonical ABI metadata onto the otherwise flat-i32 core module; component new wraps it as a binary component, adapting wasip1 to wasip2 with the vendored reactor adapter — the reactor variant specifically, matched to -buildmode=c-shared, because pairing a reactor core with the wrong adapter is a silent trap, not a build failure.");

content("AUTHORING IN GO · CABI_REALLOC", "The one file Rust's toolchain supplies and Go's does not",
  ["wasm-tools component new requires the core module to export cabi_realloc — the Canonical ABI's own allocator for lifting and lowering strings and lists across the boundary.",
   "cargo-component's wit-bindgen crate provides this export built in; Go's binding generator and cm package currently do not.",
   "The provider's own cabi_realloc.go allocates through Go's make(), so the TinyGo runtime and its garbage collector own the memory the host reads from and writes into.",
   "This is a reactor-only convenience: Part 2's own consumer-go needs a different implementation entirely, covered two slides ahead."],
  "Twenty-six lines of hand-written Go close a gap neither wit-bindgen-go nor the cm package fills today. The function picks a slice element type matching the requested alignment and allocates through make, copying forward when the host asks for a larger buffer than the existing one. The reason this matters now, before composition, is that it sets up the contrast with consumer-go's own cabi_realloc: a reactor's cabi_realloc can safely call into the Go heap because _initialize always finishes before any export is ever called; a command's cannot, because its own _start calling convention invokes cabi_realloc from inside the command adapter before the TinyGo runtime has necessarily finished its own startup sequence — the exact trap the composition slides ahead will name.");

diagram("AUTHORING IN GO · WIT BINDINGS PIPELINE", "One contract, two independent toolchains",
  "03-wit-bindings-pipeline",
  "contracts/wit feeds cargo-component on the Rust side and wasm-tools plus wit-bindgen-go on the Go side, converging on the identical world cargo.",
  "Neither Rust nor Go understands WIT directly; each toolchain runs its own generation step before any domain logic is written. On the Go side, wasm-tools together with wit-bindgen-go generate a Go interface and the supporting types a package implements, with lowering handled by generated code rather than hand-written marshaling. The two toolchains never share a line of code, and they do not need to: wasm-tools component wit, run against either finished artifact, shows the identical three exports, patterncatalyst:cargo/types, /booking, and /handling, because both read from the same contracts/wit source.");

code("AUTHORING IN GO · GENERATED EXPORTS", "A struct of function-valued fields, not an interface",
  "go · generated", [
    "// internal/cargo/patterncatalyst/cargo/booking/booking.exports.go",
    "// Code generated by wit-bindgen-go. DO NOT EDIT.",
    "",
    "// Exports represents the caller-defined exports from",
    "// \"patterncatalyst:cargo/booking@0.1.0\".",
    "var Exports struct {",
    "\tBookCargo func(spec RouteSpec, weightKg float64) (",
    "\t\tresult cm.Result[BookingShape, Booking, CargoError])",
    "",
    "\tRequestPossibleRoutes func(bookingID string) (",
    "\t\tresult cm.Result[CargoErrorShape, cm.List[Itinerary], CargoError])",
    "",
    "\tAssignRoute func(bookingID string, itinerary Itinerary) (",
    "\t\tresult cm.Result[BookingShape, Booking, CargoError])",
    "",
    "\tGetCargo func(trackingID string) (",
    "\t\tresult cm.Result[CargoShape, Cargo, CargoError])",
    "}",
  ], "internal/cargo/patterncatalyst/cargo/booking/booking.exports.go — generated, read for what it produces, never hand-edited.",
  "Exports is not an interface a type implements; it is a package-level struct of function-valued fields, each initially nil. Domain code assigns a closure to each field — booking.Exports.BookCargo = func(...) {...} — and generated code elsewhere in the package wires each field to the actual //go:wasmexport-annotated function the host calls. cm.Result[BookingShape, Booking, CargoError] is wit-bindgen-go's rendering of WIT's result<booking, cargo-error>: a generic carrying either an Ok value or an Err value, with the Shape type used purely for the result's internal storage layout. This is the exact shape the next few slides implement against.");

diagram("AUTHORING IN GO · WORLDS", "Imports and exports, read in one direction",
  "03-world-imports-vs-exports",
  "world cargo exports the three interfaces; world cargo-consumer imports the identical three — same shape, opposite direction.",
  "A world is WIT's answer to one question: for a given component, which interfaces does it provide, and which does it need? world cargo exports types, booking, and handling — the provider side every Go component in Part 2's go/ directory targets. world cargo-consumer imports the identical three — the caller side consumer-go targets a few slides ahead. Neither Go nor Rust's binding generator needs its own copy of what money or cargo-error means; both worlds are built from the same types/booking/handling declarations, which is exactly why wac plug can satisfy one side's imports from the other's exports purely by matching WIT identifiers.");

diagram("AUTHORING IN GO · THE CARGO DOMAIN", "One domain, read through a component boundary",
  "05-cargo-domain",
  "A booking ties a cargo to a route-spec; an itinerary of legs satisfies it; a cargo-tracker resource follows its handling history.",
  "The domain every Go implementation in this book targets: a shipper books cargo for transport between two UN/LOCODE-identified ports, a carrier plans an itinerary of legs, and handling events record what happened as the cargo moves. Two conventions carry weight for the Go code ahead: money.amount is a decimal string, never a float, because WIT has no fixed-point type and a binary double would drop cents over enough arithmetic; and every enum (handling-event-type, routing-status, transport-status) puts an explicit unspecified case first, so an absent or malformed field reads as a visible absence rather than silently landing on the first real value. Both conventions show up unchanged in every Go struct this deck's code slides use.");

diagram("AUTHORING IN GO · DOMAIN TO WIT", "Three interfaces: one for data, two for behavior",
  "05-domain-to-wit",
  "types carries every record and enum with zero functions; booking and handling add behavior on top of it.",
  "types declares every record and enum the domain needs plus the shared cargo-error variant, and declares zero functions — vocabulary, not behavior. booking owns the shipment lifecycle (book-cargo, request-possible-routes, assign-route, get-cargo); handling owns everything once cargo is moving (register-handling-event, list-handling-events, and the cargo-tracker resource). Both Rust and Go implement this same split identically: the Go provider's main.go, two slides ahead, has one init() function wiring both interfaces' Exports fields against the same in-memory state.");

code("AUTHORING IN GO · BOOK-CARGO", "Ordinary Go: validation, derivation, a typed return",
  "go · part2/go", [
    "// examples/part2-building-components/go/main.go",
    "booking.Exports.BookCargo = func(spec types.RouteSpec, weightKg float64) bookingResult {",
    "\tif spec.Origin.Unlocode == \"\" || spec.Destination.Unlocode == \"\" {",
    "\t\treturn cm.Err[bookingResult](types.CargoErrorInvalidLocation(",
    "\t\t\t\"origin and destination must each have a UN/LOCODE\"))",
    "\t}",
    "\tif weightKg <= 0 {",
    "\t\treturn cm.Err[bookingResult](types.CargoErrorInvalidBooking(",
    "\t\t\t\"weight-kg must be greater than zero\"))",
    "\t}",
    "",
    "\ttrackingID := trackingIDFor(spec.Origin, spec.Destination)",
    "\tbookingID := bookingIDFor(spec.Origin, spec.Destination)",
    "\tcargos[trackingID] = types.Cargo{",
    "\t\tTrackingID: trackingID, Origin: spec.Origin,",
    "\t\tDestination: spec.Destination, WeightKg: weightKg,",
    "\t}",
    "\tb := types.Booking{BookingID: bookingID, CargoID: trackingID,",
    "\t\tRouteSpec: spec, Price: types.Money{Amount: priceAmount, Currency: priceCurrency},",
    "\t\tStatus: types.RoutingStatusNotRouted}",
    "\tbookings[bookingID] = b",
    "\treturn cm.OK[bookingResult](b)",
    "}",
  ], "examples/part2-building-components/go/main.go — nothing here touches cm.Rep, linear memory, or anything Wasm-specific beyond the return type.",
  "cm.Err and cm.OK are the cm package's two constructors for either side of a result; types.CargoErrorInvalidLocation and types.CargoErrorInvalidBooking are generated helpers building the matching cargo-error variant case from a message string. The deterministic trackingIDFor/bookingIDFor helpers and the fixed priceAmount/priceCurrency constants are not incidental — they are kept in lockstep, byte for byte, with the Rust implementation's own constants, because the host in examples/part2-building-components/host runs an identical scenario against both components and diffs the results. Nothing in this function is Wasm-aware; it is ordinary Go reading and writing two package-level maps.");

code("AUTHORING IN GO · THE CARGO-TRACKER RESOURCE", "A package-level table keyed by cm.Rep",
  "go · part2/go", [
    "// examples/part2-building-components/go/main.go",
    "type trackerState struct { trackingID string }",
    "",
    "var (",
    "\ttrackers           = map[cm.Rep]*trackerState{}",
    "\tnextTracker cm.Rep = 1",
    ")",
    "",
    "handling.Exports.CargoTracker.Constructor = func(trackingID string) handling.CargoTracker {",
    "\trep := nextTracker",
    "\tnextTracker++",
    "\ttrackers[rep] = &trackerState{trackingID: trackingID}",
    "\treturn handling.CargoTrackerResourceNew(rep)",
    "}",
    "",
    "handling.Exports.CargoTracker.CurrentStatus = func(self cm.Rep) types.TransportStatus {",
    "\tt, ok := trackers[self]",
    "\tif !ok { return types.TransportStatusUnspecified }",
    "\thistory := events[t.trackingID]",
    "\tif len(history) == 0 { return types.TransportStatusUnspecified }",
    "\treturn statusFromLastEvent(history[len(history)-1].EventType)",
    "}",
  ], "examples/part2-building-components/go/main.go — the resource's only private state is the tracking id; status is read live from shared events.",
  "cm.Rep is the Component Model's resource representation handle: an opaque value the host hands back on every method call, standing in for one specific cargo-tracker instance without the host and the component ever sharing a pointer across the sandbox boundary. The generated code expects the implementation to maintain whatever state that rep refers to on its own side — here, a package-level map plus a monotonically increasing counter. CurrentStatus re-reads the shared events map by tracking id on every call rather than caching a copy inside trackerState, so a tracker constructed before three handling events were recorded still reports the current status once they land. This is the one WIT construct with no equivalent in a stateless RPC call: a resource is a handle with identity, not a value copied across the boundary.");

diagram("AUTHORING IN GO · HOST AND COMPONENT", "One native host, two interchangeable components",
  "06-host-exercises-component",
  "The same Rust host runs rust/cargo_rust.wasm or go/cargo-go.wasm and asserts byte-identical results against a shared fixture.",
  "examples/part2-building-components/host is a native Rust binary built with wasmtime::component::bindgen! against world cargo. It loads a component by path — either language's artifact — links WASI support, and drives one deterministic scenario from fixtures/scenario.json: book USNYC to DEHAM, fetch the cargo back, request routes, assign one, register three handling events, list them, then construct a cargo-tracker and read its status and history. Run against the Go artifact with a go label and against the Rust artifact with a rust label, the two runs print byte-identical normalized JSON summaries. verify.sh diffs the two outputs as its final assertion — the proof, not just the claim, that two components built from the same WIT package by two independent toolchains are interchangeable from a host's point of view, with no knowledge of which language produced which side.");

diagram("AUTHORING IN GO · WAC PLUG", "The consumer is the socket; the provider is the plug",
  "08-wac-plug-socket-and-plug",
  "wac plug --plug provider consumer -o composed.wasm resolves by WIT identifier alone — never by source language.",
  "The provider is the --plug argument because it supplies exports that satisfy someone else's unmet imports; the consumer is the positional socket argument because it carries an unresolved import for patterncatalyst:cargo/booking and friends. wac resolves that plug entirely by matching WIT interface identifiers between what the consumer imports and what the provider exports — nothing inspects which language either binary was compiled from, because by the time wac sees either .wasm file, the language is already gone. consumer-go (this slide's Go side) targets world cargo-consumer with a wasi:cli/run export, and composing it against either language's provider produces a single self-contained artifact wasmtime run executes directly, no native host required.");

code("AUTHORING IN GO · THE COMMAND-ADAPTER TRAP", "A fresh cabi_realloc for a component with no warm heap",
  "go · consumer-go", [
    "// examples/part2-building-components/consumer-go/cabi_realloc.go",
    "const cabiArenaSize = 1 << 20",
    "",
    "var cabiArena [cabiArenaSize]byte",
    "var cabiOffset uintptr",
    "",
    "//export cabi_realloc",
    "func cabiRealloc(ptr unsafe.Pointer, size, align, newsize uintptr) unsafe.Pointer {",
    "\tif newsize == 0 {",
    "\t\treturn unsafe.Pointer(&cabiArena[0])",
    "\t}",
    "\tif align == 0 { align = 1 }",
    "\toff := (cabiOffset + align - 1) &^ (align - 1)",
    "\tif off+newsize > cabiArenaSize {",
    "\t\treturn nil",
    "\t}",
    "\tnewptr := unsafe.Pointer(&cabiArena[off])",
    "\tcabiOffset = off + newsize",
    "\tif ptr != nil && size > 0 {",
    "\t\tcopy(unsafe.Slice((*byte)(newptr), newsize), unsafe.Slice((*byte)(ptr), size))",
    "\t}",
    "\treturn newptr",
    "}",
  ], "examples/part2-building-components/consumer-go/cabi_realloc.go — a fixed 1 MiB bump arena, never freed, never touching the Go heap.",
  "The command adapter fetches the process's own argv by calling the module's exported cabi_realloc from inside _start, before the TinyGo runtime has finished its own startup sequence. The provider's heap-backed cabi_realloc (the earlier slide's version) is correct for a reactor, because _initialize always finishes before any export is called; a command has no such guarantee, and a heap-backed realloc re-entering make([]...) partway through TinyGo's own init sequence aborts with assertion failed at adapter line 2857 rather than running at all. The fix is a static bump-arena global that never touches the Go heap, so it is safe to call before the garbage collector is ready — TinyGo's non-moving collector keeps that global array exactly where it is while the host reads lifted strings and lists back out of it. The consumer runs its scenario once and exits, so never freeing the arena costs nothing.");

diagram("AUTHORING IN GO · THE POLYGLOT MATRIX", "Four compositions, two of them crossing a language boundary",
  "08-polyglot-composition-matrix",
  "rustC×rustP, rustC×goP, goC×rustP, goC×goP — all four print the identical normalized summary line.",
  "verify.sh's Step 8 runs the full two-by-two matrix: both consumers against both providers. All four compositions print the same line character for character, booking=BOOKING-USNYC-DEHAM through history=received@USNYC,loaded@USNYC,unloaded@DEHAM. The two cross-language pairs — a Go consumer plugged into the Rust provider, a Rust consumer plugged into the Go provider — are the headline, not the two same-language pairs: wac never asked which language built either half, because the only thing it had to match was a WIT identifier shared by all four binaries from the start. Composed-artifact bytes are not deterministic across runs (a known wac upstream issue), which is why verify.sh diffs wasmtime run's stdout rather than comparing .wasm files byte for byte — the check that actually answers whether the composition works.");

// ===== SECTION 2 — CORRECTNESS =================================================
divider("2", "Correctness", "Reading a component without running it, and the two ways a call can fail.",
  "Opens the correctness section. Two ideas: static inspection — wasm-tools component wit, objdump, and the DWARF question that predicts whether a future trap will resolve a file and line — and the two structurally distinct failure channels a call across the component boundary can produce, a recoverable cargo-error and an unrecoverable trap, with Go's cm.Err/cm.OK and a bare panic() implementing both sides of that fork identically to Rust's Result and panic!.");

diagram("CORRECTNESS · DEBUG LAYERS", "DWARF lives in exactly one core module, or it doesn't",
  "09-component-debug-layers",
  "TinyGo embeds full DWARF by default; cargo-component --release embeds none — a build decision made long before any trap.",
  "A component wraps one or more core modules, and debug information, when it exists, lives inside exactly one of them, never at the component layer itself — the canon lift/canon lower glue has no local variables and no call stack frames of its own to debug. wasm-tools objdump against the Go core module shows nearly 600 KB of .debug_info, .debug_line, .debug_str, and more, embedded by TinyGo's -target=wasip1 build by default. The Rust core module carries none, because a plain cargo-component build --release strips debug info the same way a native Rust release profile does. That single objdump check, run before anything traps, predicts exactly whether a later backtrace resolves a file and line number or stops at a function name — and for Go, the answer is yes, it resolves.");

diagram("CORRECTNESS · SYMPTOM TO TOOL", "The cheapest tool that answers the question you actually have",
  "09-symptom-to-tool",
  "wasm-tools component wit, then objdump, then a WASMTIME_BACKTRACE_DETAILS=1 backtrace, then inherit_stderr — in that order.",
  "Four tools cover nearly every failure this book's components produce. wasm-tools component wit reads a binary's own embedded type section — no running instance, no WASI, no fixture needed — and for the Go provider shows the identical three cargo exports the Rust provider shows, plus the WASI minor-version skew (wasi:cli@0.2.12 for Go versus @0.2.3 for Rust) that wasmtime's semver-compatible linking resolves transparently at composition time. A real Go trap backtrace, captured against the __TRAP__ sentinel, resolves main.go:166:9 directly — the exact line where the sentinel's panic call sits — because the previous slide's DWARF check already predicted it would. inherit_stderr() is most of what logging means for a component in this book: there is no structured logging framework wired into the guest, so a component's own stderr, piped through the host's WasiCtxBuilder, is the whole visibility story.");

diagram("CORRECTNESS · TWO FAILURE CHANNELS", "A result the caller must check, versus a trap that ends the instance",
  "10-two-failure-channels",
  "get-cargo(NO-SUCH-CARGO) returns Ok(Err(not-found)); get-cargo(__TRAP__) returns Err on the call itself — no domain value at all.",
  "The contract draws this line in WIT's own terms before either language's code adds anything: get-cargo returns result<cargo, cargo-error>, and a caller cannot forget to check, because there is no bare value and no null on failure. A trap is not data — nothing in the WIT signature describes it, because it is the Component Model's name for what happens when execution inside a component cannot continue and the host has to abandon it. From the host's point of view, a recoverable error surfaces as Ok(Err(cargo-error::not-found)) — the call itself succeeded — while a trap surfaces as Err on the call itself, with no cargo-error ever constructed. Both the Go and Rust providers implement a deliberate __TRAP__ sentinel tracking id, kept in lockstep between the two languages, precisely so the debugging chapter and this deck can show a real trap distinct from an ordinary domain miss.");

code("CORRECTNESS · GO'S TWO CHANNELS", "cm.Err/cm.OK for data; a bare panic for the other channel",
  "go · part2/go", [
    "// examples/part2-building-components/go/main.go",
    "const trapSentinel = \"__TRAP__\"",
    "",
    "booking.Exports.GetCargo = func(trackingID string) cargoResult {",
    "\tif trackingID == trapSentinel {",
    "\t\t// A panic unwinds to a wasm trap at the component boundary —",
    "\t\t// the host observes an error from the CALL itself, not an",
    "\t\t// Ok(Err(..)) domain result. This is the \"unrecoverable\" side.",
    "\t\tpanic(\"__TRAP__ sentinel: deliberate trap for the debugging/error chapter\")",
    "\t}",
    "\tc, ok := cargos[trackingID]",
    "\tif !ok {",
    "\t\treturn cm.Err[cargoResult](types.CargoErrorNotFound(\"no cargo \" + trackingID))",
    "\t}",
    "\treturn cm.OK[cargoResult](c)",
    "}",
  ], "examples/part2-building-components/go/main.go — one function, two channels: cm.Err/cm.OK return a cargoResult; panic never does.",
  "Structurally this is the identical fork Rust's Result<Cargo, CargoError> plus panic! implements, expressed with Go's own tools. cm.OK[cargoResult](c) and cm.Err[cargoResult](types.CargoErrorNotFound(...)) are both ordinary return statements producing a cargoResult value, exercising the normal Go call/return mechanism out through the generated export wiring. panic(\"__TRAP__ sentinel: ...\") does not produce a cargoResult at all — like Rust's panic!, it unwinds past the point where the function would have returned one, and TinyGo's wasm output turns that unwind into the same kind of wasm trap the Rust build produces. The comments in both language's source files are worded almost identically, because the two implementations are meant to be read side by side, byte for byte in intent if not in syntax.");

diagram("CORRECTNESS · ERROR MAPPING", "Rust's Result and Go's cm.Result both lower onto one WIT shape",
  "10-error-mapping",
  "Both panic paths skip the WIT result entirely — there is no WIT shape for a trap; it unwinds straight to the boundary.",
  "Neither implementation invented its own error vocabulary: both read not-found, invalid-booking, invalid-location, and conflict out of the identical contracts/wit/types.wit cargo-error variant, and each language's binding generator produced matching constructor names for its own idiom — CargoError::NotFound(...) in Rust, types.CargoErrorNotFound(...) in Go. The practical rule this whole chapter leaves behind: a new failure belongs in cargo-error only if a caller should reasonably expect it and be positioned to handle it — an unknown id, a bad input, a conflicting state. A panic or trap is reserved for the opposite case, an invariant the component's own code assumed would hold and did not, and it should stay rare and loud rather than get smuggled into the error variant as a vague case nobody can act on.");

// ===== SECTION 3 — INTERFACES ===================================================
divider("3", "Interfaces", "HTTP, Protobuf, and capability-scoped sockets, each read through the Go build.",
  "Opens the interfaces section. Three real protocol surfaces, each with its own Go-specific finding: wasi-http, where http-go's handler is a line-for-line match with the Rust front door; gRPC, where the standard reflection-based protobuf library compiles under TinyGo but traps at runtime, forcing a hand-written wire codec; and wasi:sockets, where a documented TinyGo 0.43 runtime gap means the component builds and validates but has no clean path to a live connect.");

diagram("INTERFACES · WASI-HTTP REQUEST PATH", "One WIT world, two toolchains, byte-identical JSON",
  "11-wasi-http-request-path",
  "curl through wasmtime serve, into the adapter's imported booking calls, back out as JSON — Rust and Go produce the identical response.",
  "include wasi:http/proxy@0.2.8 is a WIT include, not an import: it pulls an entire predefined world's imports and exports wholesale, so the component exports wasi:http/incoming-handler for wasmtime serve to drive directly, with no TCP listener written inside the component. http-go's world adds the three cargo imports on top of that include, the identical three interfaces the part2 provider exports — composition via wac plug is what turns the second job from a compile-time obligation into a runtime capability. wasmtime serve -S cli is required, not optional: the default proxy linker omits wasi:cli/environment and wasi:filesystem, which both the Go and Rust builds still import underneath their HTTP-specific surface, and omitting the flag fails at the first request with implementation is missing, not at startup.");

code("INTERFACES · THE HTTP-GO HANDLER", "Routing logic, line for line with the Rust front door",
  "go · http-go", [
    "// examples/part3-interfaces/http-go/main.go",
    "func handle(request httptypes.IncomingRequest, responseOut httptypes.ResponseOutparam) {",
    "\tpath := request.PathWithQuery().Value()",
    "\tif i := strings.IndexByte(path, '?'); i >= 0 { path = path[:i] }",
    "",
    "\tconst prefix = \"/cargo/\"",
    "\tif !strings.HasPrefix(path, prefix) || len(path) == len(prefix) {",
    "\t\tsend(responseOut, 404, []byte(`{\"error\":\"not found\",\"hint\":\"GET /cargo/{id}\"}`))",
    "\t\treturn",
    "\t}",
    "\tid := path[len(prefix):]",
    "\tparts := strings.SplitN(id, \"-\", 3)",
    "\tif len(parts) == 3 && parts[0] == \"CARGO\" {",
    "\t\tspec := cargotypes.RouteSpec{Origin: locationFor(parts[1]),",
    "\t\t\tDestination: locationFor(parts[2]), ArrivalDeadline: arrivalDeadline}",
    "\t\tb, bErr, isErr := booking.BookCargo(spec, defaultWeightKg).Result()",
    "\t\tif isErr { sendError(responseOut, bErr); return }",
    "\t\tcargo, cErr, isErr := booking.GetCargo(b.CargoID).Result()",
    "\t\tif isErr { sendError(responseOut, cErr); return }",
    "\t\t// ... build and send the 200 JSON body ...",
    "\t}",
    "}",
  ], "examples/part3-interfaces/http-go/main.go — book then get, within one request, because wasmtime serve gives every request a fresh instance.",
  "cm.Result's three-value .Result() method — (value, error, isErr) — carries both BookCargo and GetCargo across the boundary, the same Chapter 7 shape used throughout Part 2. Booking and reading within the same request looks redundant until the instance model is clear: wasmtime serve creates a fresh instance of the composed component for every single incoming request, and the provider keeps cargo state in that instance's own linear memory, not in any external store. A get-cargo call on a cold instance that nothing has booked yet always returns cargo-error::not-found, correctly, so booking first inside the same request is how this handler demonstrates a cross-component call that returns live data without pretending the provider has durable state it does not have.");

code("INTERFACES · THE ORDERING GOTCHA", "Obtain the body handle before the outparam consumes the response",
  "go · http-go", [
    "// examples/part3-interfaces/http-go/main.go",
    "func send(responseOut httptypes.ResponseOutparam, status uint16, body []byte) {",
    "\theaders := httptypes.NewFields()",
    "\tct := httptypes.FieldValue(cm.ToList([]byte(\"application/json\")))",
    "\theaders.Set(\"content-type\", cm.ToList([]httptypes.FieldValue{ct}))",
    "",
    "\tresp := httptypes.NewOutgoingResponse(headers)",
    "\tresp.SetStatusCode(httptypes.StatusCode(status))",
    "",
    "\t// Obtain the body handle before handing the response to the outparam:",
    "\t// the set call consumes the OutgoingResponse. OK() is a pointer method,",
    "\t// so the cm.Result must live in a local first.",
    "\tbodyRes := resp.Body()",
    "\toutBody := *bodyRes.OK()",
    "\tok := cm.OK[cm.Result[httptypes.ErrorCodeShape, httptypes.OutgoingResponse, httptypes.ErrorCode]](resp)",
    "\thttptypes.ResponseOutparamSet(responseOut, ok)",
    "",
    "\tstreamRes := outBody.Write()",
    "\tstream := *streamRes.OK()",
    "\tstream.BlockingWriteAndFlush(cm.ToList(body))",
    "}",
  ], "examples/part3-interfaces/http-go/main.go — wasi:http resources are move-only; Go has no borrow checker to catch the ordering mistake at compile time.",
  "wasi:http's resources are move-only the way every Component Model resource is: resp.Body() has to run before ResponseOutparamSet consumes resp by value. Rust's version of this exact ordering is a borrow-checker-enforced invariant the compiler catches; Go has no equivalent static check, so the comment in this source file is doing real work rather than merely documenting a convenience. Getting this wrong produces a resource-already-consumed failure at runtime, not a compile error — the one place in this chapter's HTTP front door where Go's lack of ownership tracking actually costs something beyond syntax.");

diagram("INTERFACES · BUILD, COMPOSE, SERVE", "Two toolchains, one wac recipe, byte-identical responses",
  "11-build-compose-serve-pipeline",
  "http-go builds through wit-bindgen-go plus TinyGo plus wasm-tools; wac plug composes it against either provider the same way.",
  "http-go's build pipeline is exactly Chapter 7's provider recipe, reused without modification — wit-bindgen-go generate, tinygo build -target=wasip1 -buildmode=c-shared, then wasm-tools component embed and component new with the reactor adapter — because incoming-handler is itself a reactor export. No new TinyGo limitation shows up building the front door; it inherits the identical build path the provider already established. wac plug --plug <PROVIDER> <HTTP-COMPONENT> -o composed.wasm is the same orientation Chapter 8 established: the provider that exports the cargo interfaces is the plug, the HTTP adapter that imports them is the positional socket. verify.sh's serve_assert helper runs this composition against both providers in a loop, asserting the identical EXPECTED_JSON string against each.");

content("INTERFACES · GRPC, FRAMED", "Protobuf runs inside a Go component; gRPC's transport does not — yet",
  ["Protobuf-the-encoding (varints, length-delimited fields, fixed64 doubles) is pure computation — it runs fully inside the sandbox, in both languages.",
   "gRPC-the-transport (HTTP/2 framing, trailers, stream multiplexing) needs a server role no wasi:* interface exposes from inside a component today.",
   "This book's answer is two artifacts sharing one .proto: a Wasm codec doing real protobuf work, and a native bridge terminating gRPC in front of an unchanged provider."],
  "Opens the gRPC-with-Wasm material inside the interfaces section. States the chapter's two-part finding up front before the code slides make it concrete: Protobuf-the-encoding and gRPC-the-transport are separable concerns with separate verdicts in today's Component Model, and the TinyGo-specific finding on the next slide — the standard protobuf library traps at runtime — sits entirely on the encoding side of that split.");

diagram("INTERFACES · ENCODING VS. TRANSPORT", "Two separable concerns, two different verdicts",
  "12-encoding-vs-transport-split",
  "Protobuf is pure computation and runs inside the sandbox; gRPC's HTTP/2 framing and trailers need a host outside it.",
  "gRPC bundles two logically independent things: a serialization format (Protobuf — varints, length-delimited fields, fixed64 doubles) and a transport contract (HTTP/2 framing, trailers carrying the final status after the body). The component model draws a sharp line between them. codec.get-cargo(list<u8>) -> result<list<u8>, string> moves opaque bytes across the WIT boundary in both directions — as far as the Canonical ABI is concerned, this is the same list<u8> primitive wasi:http's body already used. Decoding, dispatching over WIT, and re-encoding are all arithmetic and memory access on bytes already in hand; none of it asks for a socket, a thread, or a clock, which is exactly why Protobuf clears a bar gRPC's transport cannot.");

content("INTERFACES · THE TINYGO PROTO GOTCHA", "google.golang.org/protobuf compiles, then traps",
  ["proto.Marshal's reflection-based descriptor building bottoms out at reflect.Type.MethodByName — a call TinyGo's partial reflect package does not implement.",
   "The failure is compile-time-clean and runtime-broken: tinygo build succeeds with no warning, and the component traps with wasm unreachable the first time Marshal actually runs.",
   "The production-grade fix is vtprotobuf, a protoc plugin generating dedicated MarshalVT/UnmarshalVT methods with no runtime reflection at all.",
   "The example-scale fix, and what proto-go ships, is a hand-written reflection-free wire codec implementing the proto3 wire format directly."],
  "This is the chapter's sharpest TinyGo-specific finding, and it is stated as a fact about reflection depth, never as a defect narrative: TinyGo's reflect package covers a limited, statically analyzable subset of what ordinary Go programs use, not the dynamic method-table walking a general-purpose protobuf runtime needs to build its descriptor the first time a message type is marshaled. The type-checker sees nothing wrong, because reflect.Type.MethodByName exists as a symbol; it simply is not implemented. The lesson is not that TinyGo cannot do protobuf — the next two slides prove it demonstrably can, inside a Wasm sandbox — it is that the reflection-based mainstream library cannot be assumed to work merely because it compiles.");

code("INTERFACES · THE REFLECTION-FREE CODEC", "proto3's wire format, encoded and decoded by hand",
  "go · proto-go", [
    "// examples/part3-interfaces/proto-go/wire.go",
    "func appendVarint(b []byte, v uint64) []byte {",
    "\tfor v >= 0x80 {",
    "\t\tb = append(b, byte(v)|0x80)",
    "\t\tv >>= 7",
    "\t}",
    "\treturn append(b, byte(v))",
    "}",
    "",
    "func appendString(b []byte, field int, s string) []byte {",
    "\tif s == \"\" { return b }",
    "\tb = appendTag(b, field, 2) // length-delimited",
    "\tb = appendVarint(b, uint64(len(s)))",
    "\treturn append(b, s...)",
    "}",
    "",
    "func readVarint(b []byte, i int) (uint64, int, error) {",
    "\tvar v uint64",
    "\tvar shift uint",
    "\tfor {",
    "\t\tif i >= len(b) { return 0, 0, errors.New(\"varint truncated\") }",
    "\t\tc := b[i]; i++",
    "\t\tv |= uint64(c&0x7f) << shift",
    "\t\tif c < 0x80 { return v, i, nil }",
    "\t\tshift += 7",
    "\t}",
    "}",
  ], "examples/part3-interfaces/proto-go/wire.go — varints, length-delimited strings and messages, fixed64 doubles, with no reflection anywhere.",
  "Encoding mirrors decoding structurally: appendVarint and readVarint are inverses, appendTag packs a field number and wire type into one varint the same way the proto3 spec defines, and skipField lets the decoder tolerate unknown fields rather than rejecting them — a real protobuf consumer's forward-compatibility requirement, implemented by hand here instead of inherited from a library. Every message this chapter needs (Location, Money, Cargo, GetCargoResponse) is built from these primitives directly in encodeCargo and encodeGetCargoResponse. The result interoperates with the Rust prost side at the wire level because proto3's wire format is a precise specification both a generated encoder and a hand-written one can implement correctly.");

diagram("INTERFACES · PROTOBUF IN A COMPONENT", "91 bytes, byte-identical, Rust prost and TinyGo wire codec alike",
  "12-protobuf-in-component",
  "Decode, dispatch over WIT, encode — entirely inside the sandbox, no network, no gRPC transport, just bytes in and bytes out.",
  "The proof: the identical native host drives both the Rust proto-component and the Go proto-go artifact with no code change, only the composed .wasm path differs. Nineteen bytes of GetCargoRequest go in; ninety-one bytes of GetCargoResponse come back, byte-for-byte identical whether a Rust prost encoder or this chapter's TinyGo wire codec produced them. getCargo's Go handler runs the identical CARGO-{ORIGIN}-{DEST} parsing and book-then-get WIT dispatch as the Rust side — a line-for-line structural match, which is the whole point: the reflection-free codec changes nothing about the domain logic, only how the bytes at the edges get made.");

diagram("INTERFACES · THE GRPC BRIDGE", "gRPC in front of Wasm, never gRPC inside Wasm",
  "12-grpc-bridge-in-front",
  "A native tonic process terminates HTTP/2 and trailers, then dispatches each RPC over WIT into an unchanged provider component.",
  "No wasi:* interface today exposes an HTTP/2 server role from inside a component — wasi:http/incoming-handler answers one request with one response and has no trailer channel or stream multiplexing. The workaround is a native tonic process that owns the transport entirely: for each RPC it instantiates the unchanged Part 2 provider with wasmtime and makes the same WIT calls a native host always made. The provider component itself never changes to make this work — the .wasm file wasmtime::component::Component::from_file loads is the identical artifact cargo-component build --release always produced, composed against nothing, modified for nothing. This grpc-bridge is a Rust-hosted mechanism; the same unmodified shape works equally in front of the Go provider, because the bridge dispatches by WIT identifier, the same way wac plug does everywhere else in this deck.");

content("INTERFACES · SOCKETS, SCOPED", "Capability-scoped outbound TCP, with a documented TinyGo runtime gap",
  ["wasi:sockets makes the capability boundary visible the way wasi:http usually doesn't: the host decides, per invocation, whether a component's socket imports resolve to anything real.",
   "sockets-rust is this book's live, verified reconnect proof — denied without a grant, backing off and reconnecting with one.",
   "sockets-go builds and wasm-tools validates as a real, spec-valid component, but has no clean runtime path on TinyGo 0.43, for two independent, named reasons."],
  "Opens the sockets material inside the interfaces section. States the scope precisely before the capability-boundary slide ahead names both TinyGo-specific failure modes: this is a documented runtime gap on one toolchain combination, stated as a fact with its own upstream-tracked cause, never as a defect in the example or a reason to avoid wasi:sockets generally.");

diagram("INTERFACES · RECONNECT WITH BACKOFF", "delay = base × 2^min(attempt-1, 5), plus jitter",
  "13-reconnect-backoff-timeline",
  "Four connection-refused attempts, each backoff roughly doubling, then a fifth attempt connects once the delayed listener binds.",
  "Jitter de-synchronizes a population of retrying clients without requiring any of them to coordinate: a pure exponential backoff with no randomness has every client that failed at the same moment retry at the same moment again, the thundering-herd failure mode this formula exists to avoid. The shift caps at 5 (a 32x multiplier) so the window stops growing without bound no matter how many attempts a caller allows. sleep_ms and the connect's own subscribe/block idiom both depend on wasi:clocks and, on the Rust side, wasi:random — capability-scoped primitives a component has no ambient access to, the same way wasi:sockets itself is capability-scoped.");

code("INTERFACES · GO'S RECONNECT LOOP", "The identical shape, clock-derived jitter instead of wasi:random",
  "go · sockets-go", [
    "// examples/part3-interfaces/sockets-go/main.go",
    "func tryConnect(port uint16) (bool, network.ErrorCode) {",
    "\tnet := instancenetwork.InstanceNetwork()",
    "\tsocket, sErr, isErr := tcpcreate.CreateTCPSocket(network.IPAddressFamilyIPv4).Result()",
    "\tif isErr { return false, sErr }",
    "\tremote := network.IPSocketAddressIPv4(network.IPv4SocketAddress{",
    "\t\tPort: port, Address: network.IPv4Address{127, 0, 0, 1}})",
    "\tif _, cErr, isErr := socket.StartConnect(net, remote).Result(); isErr {",
    "\t\treturn false, cErr",
    "\t}",
    "\tpollable := socket.Subscribe()",
    "\tpollable.Block()",
    "\tif _, fErr, isErr := socket.FinishConnect().Result(); isErr {",
    "\t\treturn false, fErr",
    "\t}",
    "\treturn true, 0",
    "}",
    "",
    "// backoff: base * 2^min(attempt-1, 5) + jitter from the monotonic clock's",
    "// low bits (wasi:random is not imported here — keeps the import set minimal).",
    "func backoffMs(attempt uint32, baseMs uint64) uint64 {",
    "\tshift := attempt - 1",
    "\tif shift > 5 { shift = 5 }",
    "\texp := baseMs << shift",
    "\tjitter := uint64(clock.Now()) % (exp/2 + 1)",
    "\treturn exp + jitter",
    "}",
  ], "examples/part3-interfaces/sockets-go/main.go — create, start-connect, subscribe/block, finish-connect: the identical four-call dance as sockets-rust.",
  "tryConnect mirrors sockets-rust's try_connect call for call: create-tcp-socket, start-connect (which only starts the connect and returns immediately), subscribe/block to wait for the operation to resolve, then finish-connect to read the result. backoffMs trades wasi:random for the monotonic clock's own low bits as a jitter source, a deliberate choice to keep this component's import set minimal rather than a limitation — the formula and its shape are otherwise identical to the Rust version two slides back.");

diagram("INTERFACES · THE CAPABILITY BOUNDARY", "Denied before a packet moves — and, for Go, no clean runtime path yet",
  "13-capability-boundary",
  "wasmtime run denies every connect with access-denied; -S inherit-network lets the same binary reach a real socket. Go: build-validate only.",
  "sockets-go is a real, spec-valid component — wit-bindgen-go generate, tinygo build -target=wasip1 -buildmode=c-shared, wasm-tools component embed and new, wasm-tools validate all pass cleanly. What it does not have on TinyGo 0.43 is a clean path to a live connect, for two separate, documented reasons. As a command under wasmtime run, it traps at _start with an assertion failure in random_get: TinyGo's runtime seeds randomness during its own startup, before the wasip1-to-wasip2 command adapter's random_get implementation is ready to be called that early. Shipped instead as a reactor (exporting client.run-client, driven by a native sockets-host), the trap is avoided, but the connect dance hangs: TinyGo's asyncify-based pollable.block() does not resolve the wasi:sockets connect and timer pollables under a hand-rolled wasmtime-wasi embedding, tried against both the sync and async linker. verify.sh's own GATE D states the scope directly: Rust is the live sockets proof in this example; sockets-go is kept as a build-and-validate artifact. That is a fact about this specific TinyGo-plus-reactor-plus-hand-rolled-host combination, not a verdict on TinyGo's wasi:sockets support in general.");

// ===== SECTION 4 — RUNTIMES ======================================================
divider("4", "Runtimes", "wasmtime embedding and the wasmCloud lattice — the same portability claim Part 2 already proved.",
  "Opens the runtimes section. The example artifacts in Part 4 (examples/part4-runtimes) compose the Part 2 Rust provider under the Part 3 Rust http-rust front door, so the specific sha256 quoted in this section's figures is the Rust-built app.wasm. The claim is language-neutral by construction, not by assertion: Chapter 8 already proved a Go-built provider and a Go-built consumer compose and run identically to their Rust counterparts, so every runtime behavior in this section — embedding controls, the lattice, wadm's self-healing, the same-bytes proof — applies to a Go-built composite the same way, because wasmtime and wasmCloud both dispatch by WIT export, never by source language.");

diagram("RUNTIMES · EMBEDDING ARCHITECTURE", "Engine, Store, Linker — and a host-provided import by closure",
  "14-embedding-architecture",
  "A Linker closure is the whole of a guest's ambient authority; fuel, epoch interruption, and a ResourceLimiter cap what it can do with it.",
  "Every embedding starts with the same three wasmtime types at different lifetimes: an Engine holds compiled code and is cheap to clone; a Linker resolves a component's imports against host-supplied implementations, built once and reused across every Store; a Store holds one instance's actual runtime state and is cheap to build fresh per call. The wasmtime CLI (wasmtime run, wasmtime serve -S cli) covers everything this book's HTTP front doors need; the embedded crate becomes necessary the moment a component imports a capability beyond WASI that only the host process can supply — a host-caps interface here, the pattern any Go-built component with a custom import would need identically, since bindgen!'s generated add_to_linker function dispatches by WIT interface name regardless of which language exported the matching side.");

diagram("RUNTIMES · THE LATTICE", "A capability provider owns the socket; the component only ever sees a WIT call",
  "15-lattice-architecture",
  "NATS plus wadm outside the host; the httpserver provider and the component linked inside it, dispatching into app.wasm.",
  "wash up -d starts three things with distinct jobs: NATS, the lattice's message bus every invocation and link travels over; the wasmcloud host, the process that actually runs components and providers as supervised OS processes; and wadm, the control plane that continuously reconciles the lattice's actual state against a declared OAM manifest. The httpserver capability provider opens the real TCP listener and translates inbound HTTP into wasi:http/incoming-handler calls dispatched to whichever component a link names — the component itself never touches a socket. A link's source_config field passes the listen address to the provider at deploy time, not baked into the provider's own OCI image; the same provider image runs any linked component regardless of which language built it, Go included.");

diagram("RUNTIMES · WADM'S RECONCILE LOOP", "Scale to zero, watch it fail, watch wadm restore it — no redeploy",
  "15-wadm-self-heal-loop",
  "wash scale --max-instances 0 drops the component to zero; 500s for about two seconds, then wadm reconciles it back to one.",
  "wash scale component ... --max-instances 0 talks directly to the host, not wadm, telling it to run zero instances immediately — the httpserver provider's listener stays bound the whole time, which is exactly why the failure mode during the gap is a 500, not a connection refused: the provider accepts the connection, tries to dispatch over wrpc, finds no component instance, and the invoke itself fails. wadm's reconcile loop continuously compares the manifest's declared spreadscaler instances: 1 against the lattice's actual count over the same NATS subjects the host publishes to, and the moment it sees drift, it restores the instance with no human running a second command. Recovery took about two seconds in the book's captured run — the same mechanism a Kubernetes Deployment's own controller uses to replace a pod a kubectl delete removed, applied here to a WebAssembly component instead of a container.");

diagram("RUNTIMES · SAME BYTES, TWO RUNTIMES", "One build, two completely different execution models, one sha256",
  "16-same-bytes-two-runtimes",
  "wasmtime serve and the wasmCloud lattice both answer the identical JSON from the identical artifact — verified by sha256sum, not assumed.",
  "The proof is almost anticlimactic, which is the point: build.sh produces one file, app.wasm, and that one file is what prove-same-bytes.sh runs under wasmtime serve -S cli and what wadm.yaml deploys into the lattice via file://./app.wasm — not a rebuild, not a recompile with different flags, not a runtime-specific variant. Two runtimes, two completely different execution models, and the artifact crossing into both is the same file. That identity is the direct, mechanical consequence of the Component Model boundary from Chapter 3: a component's exports are defined by WIT, a runtime's job is to satisfy its imports and call its exports, and nothing about satisfying imports requires the runtime to see, let alone change, the component's own bytes — a claim that holds for a Go-built composite exactly as it holds for the Rust one quoted here.");

diagram("RUNTIMES · WHAT EACH ONE ASKS YOU TO OWN", "A process on one side, a lattice on the other",
  "16-single-process-vs-lattice-matrix",
  "wasmtime: one binary, no built-in restart. wasmCloud: NATS plus wadm plus a host, self-healing in about two seconds.",
  "wasmtime asks you to own a process: one binary, one thing to monitor, one thing to restart, with no lattice to bring up and no reconciliation loop watching instance counts. wasmCloud asks you to own a lattice instead, and gets something back for the extra surface: self-healing without an external restart policy, multi-host scale-out coordinated declaratively, and capability providers swappable underneath a component without touching or rebuilding it. Kubernetes in Part 5 is a third, orthogonal axis on top of this choice, not a resolution of it — a single-process wasmtime component scheduled onto a pod is still a single process with no lattice underneath it, and a wasmCloud lattice running across pods is still a lattice wadm reconciles, with Kubernetes also supervising the pods the hosts run in.");

// ===== SECTION 5 — ON KUBERNETES =================================================
divider("5", "On Kubernetes", "The containerd shim, both cluster paths, interposition, scaling, and observability.",
  "Opens the Kubernetes section, the largest in this deck. The arc: the four-project landscape and why this book uses the raw shim on minikube and the wasmCloud operator on CRC; both live request paths; interposition (a filter and an adapter spliced into the same request path, with the state-across-a-link finding that distinguishes the two substrates); scaling with a stock HPA and then KEDA to zero; and on-cluster observability, substrate-provided rather than guest-emitted on either cluster.");

diagram("ON KUBERNETES · THE LANDSCAPE", "Four projects, four differently scoped questions",
  "17-wasm-on-kubernetes-landscape",
  "containerd-shim-wasmtime is the generic floor; the wasmCloud operator, SpinKube, and Krustlet each answer a narrower or historical question.",
  "runwasi's containerd-shim-wasmtime is a generic containerd shim plus a RuntimeClass, running any component exporting wasi:http/proxy or wasi:cli/run with no framework-specific packaging — this book's primary minikube mechanism, verified against v0.6.1 with the go/no-go question (would the generic shim hit a known feature gap, runwasi issue #1004) resolving clean on the first run. The wasmCloud operator schedules an entire host as a pod rather than one component, and is the fallback this book actually uses on OpenShift Local, for reasons the next few slides make concrete. SpinKube is scoped to Spin-packaged applications specifically — this deck's own Go-leaning deviation section two chapters ahead. Krustlet predates runwasi entirely and is maintained by no one; it belongs on this map only so a reader who finds it in an older post knows it is not the mechanism this book or the current ecosystem uses.");

diagram("ON KUBERNETES · BUILD, PACKAGE, LOAD", "A FROM scratch image, loaded straight into the node's containerd store",
  "18-build-package-load-deploy",
  "No registry, no push, no pull — minikube image load copies the image directly into the node's local containerd image store.",
  "The Dockerfile is as thin as an OCI image gets: FROM scratch, one COPY, an ENTRYPOINT pointing at the component — no base layer, because a Wasm component never runs as a Linux process and needs no glibc, shell, or package manager underneath it. docker build --provenance=false keeps the build at a single manifest rather than a manifest list, because BuildKit's default provenance attestation complicates exactly the step that comes next: minikube image load's platform resolution expects one plain manifest, not a list to disambiguate. This same wac-plug-then-package pipeline is exactly how a Go-built composite would be deployed; nothing about the packaging step is Rust-specific.");

diagram("ON KUBERNETES · THE MINIKUBE REQUEST PATH", "Live, through a real nip.io Ingress — never a port-forward",
  "18-minikube-request-path",
  "host → ingress-nginx → Service → Pod with runtimeClassName wasmtime → containerd-shim-wasmtime → app.wasm's incoming-handler export.",
  "runtimeClassName: wasmtime routes a Pod to the installed shim instead of runc; the shim detects the wasi:http/proxy export and runs the component behind its own built-in hyper server on 0.0.0.0:8080 — identical behavior to wasmtime serve, invoked by the shim instead of a CLI command. The chapter's sharpest operational lesson: a rollout reporting Ready and an Ingress reporting a non-empty address are both necessary, not sufficient — ingress-nginx's asynchronous config reload can route a request to its own default-backend 404 that looks, to a plain curl, exactly like a legitimate response. The script instead polls for a session-affinity cookie this Ingress's own matched rule stamps and the default backend never does, and only trusts a subsequent 200 once that cookie confirms the real rule is live.");

diagram("ON KUBERNETES · THE CRC REQUEST PATH", "The wasmCloud operator, because restricted-v2 rules out node surgery",
  "19-crc-request-path",
  "An edge-TLS Route into a selector-less Service, whose EndpointSlice the operator writes by hand, into an ordinary restricted-v2 pod.",
  "OpenShift Local runs RHCOS nodes managed by the Machine Config Operator, not edited by hand — installing a new containerd runtime plugin there means a MachineConfig and a full node bounce, a disproportionate amount of surgery for one HTTP component and a direct conflict with the restricted-v2 posture this book's OpenShift path otherwise keeps intact. The wasmCloud operator sidesteps the question: the host that runs app.wasm is an ordinary Deployment, admitted like any other restricted-v2 pod, with zero node-level change. Two non-negotiables made this live: the httpserver provider must scale with a daemonscaler, not a spreadscaler, because Service creation is only implemented for the former; and the operator's hand-written EndpointSlice needs a narrow endpoints/restricted RBAC grant, never an anyuid or SCC exception.");

diagram("ON KUBERNETES · INTERPOSITION", "A component that imports and exports the identical interface — invisible to both neighbors",
  "20-interposition-chain",
  "minikube: one shared instance across a request, so a filter sees state survive. CRC: independent per-call instances, so it does not.",
  "A component becomes an interposer by importing and exporting the identical patterncatalyst:cargo interfaces — indistinguishable from the real provider to whatever calls it, indistinguishable from an ordinary caller to the real provider underneath. The filter's embargo policy and logging exist in this book as a Rust component, built the same import/export-symmetry way Chapter 7's Go provider demonstrates exports can be built against any world — the same technique composes a Go-authored interposer identically, because wac plug matches WIT identifiers, not source language. The chapter's headline finding is substrate, not policy: on minikube's wac-plug composite, book-cargo and get-cargo share one linear memory within a request and a valid id returns 200; on CRC's wasmCloud links, every invocation gets a fresh, reset instance, so the identical valid id returns the provider's own 404 — not a bug on either side, but the direct consequence of what each substrate guarantees about instance lifetime between two linked calls.");

diagram("ON KUBERNETES · THE ADAPTER", "A legacy shape, round-tripped losslessly, then the identical state finding",
  "21-adapter-shape-translation",
  "to_legacy then from_legacy is lossless either way; the valid-id 404 on CRC confirms the state finding applies to any interposer, not just a filter.",
  "The adapter interposer round-trips every booking through a flat, legacy-shaped request (origin-code, dest-code, cargo-weight, service-level) before calling the real provider, proving the translation adds zero information loss: the exact cargo JSON comes back on minikube, byte for byte identical to the uninterposed response. On CRC, the identical round trip runs across wadm links exactly as it does in-process — nothing about to_legacy/from_legacy depends on where the caller lives — but the same valid tracking id that returned 200 on minikube now returns the provider's own NotFound, confirming Chapter 20's per-invocation statelessness finding generalizes to any interposer, not merely a policy filter. The fix, when a pattern actually needs state to survive across a link, is to move that state out of component memory entirely — a capability provider backed by a real store, never a package-level map a stateless invocation model will reset on the next call.");

diagram("ON KUBERNETES · HPA ON TWO SUBSTRATES", "A correctly wired HPA that never finds a signal to scale on",
  "22-hpa-two-substrates",
  "cargo-http's own CPU holds at 2% of a 50m request under 192 concurrent request loops — ScalingActive is true, the signal is just wrong.",
  "A Pod with runtimeClassName: wasmtime is still cgrouped and metered by the kubelet exactly like a runc Pod, so a stock autoscaling/v2 HorizontalPodAutoscaler attaches with zero Wasm-specific code anywhere in the chain from cAdvisor to metrics-server to the controller. The live finding: three load-generator pods each saturating roughly 248m of CPU to drive the traffic, while the Wasm handler's own CPU sits at 1m, 2% of its 50m request, for the entire two-minute observation window — kubectl describe hpa shows ScalingActive=True and ValidMetricFound, proving the controller's math works correctly and arrives at exactly the right answer for the signal it was given. The lesson is not a broken HPA; it is that CPU utilization is the wrong signal for a cheap, stateless handler that does too little per request to ever approach a CPU target — precisely the gap the next chapter's concurrency-based scaling closes. On CRC, there is no per-component Kubernetes object for an HPA to target at all; the wadm spreadscaler's instances field is the correct, operator-aware lever instead.");

diagram("ON KUBERNETES · TWO KEDA MODELS", "Request concurrency and consumer-group lag, both patching a plain Deployment",
  "23-two-keda-models",
  "The HTTP add-on holds a cold request at an interceptor; the kafka ScaledObject reads lag directly — both end at spec.replicas.",
  "The HTTP half scales the identical raw-shim cargo-http Deployment to and from zero with an HTTPScaledObject's concurrency trigger, through an interceptor proxy an Ingress has to route to instead of the Service directly, because scale-to-zero and a direct route are mutually exclusive. The measured cold start on minikube was 4.414 seconds end to end, dominated by Kubernetes's own scheduling path rather than the component's own start — a Wasm component instantiates within single-digit milliseconds once its Pod is actually running, the same fast-start property that let Chapter 22 shorten its scale-down window. The Kafka half needs a different kind of workload entirely: the raw shim has no binding for a long-lived consumer-group subscription, so cargo-kafka-host is a plain Rust binary embedding wasmtime and calling a Wasm handler once per delivered message — the native-host-plus-embedded-runtime idiom Chapter 12's gRPC bridge already established, reused here for Kafka instead of gRPC.");

diagram("ON KUBERNETES · KAFKA LAG FLOW", "A message-handling Wasm component behind a native rdkafka host",
  "23-kafka-lag-flow",
  "A producer burst raises real consumer-group lag; KEDA scales cargo-kafka-host 0 to N; each pod drains and KEDA scales it back to zero.",
  "kafka-handler exports wasmcloud:messaging/handler@0.2.0 and imports the cargo domain's handling interface — a message-driven component that ensures the cargo is booked before registering each handling event, the same ensure-then-record pattern a Go-authored handler against the identical WIT world would implement unchanged, since the host dispatches by export name regardless of guest language. cargo-kafka-host joins the consumer group with rdkafka, gives every delivered message a fresh wasmtime Store (the same no-state-leak-across-invocations idiom the gRPC bridge uses), and commits the offset only after the handler call returns — committing past a handler error rather than retrying it forever, so one malformed message never wedges the whole consumer group. The live run: a 120-message burst, KEDA scaling the host from 0 to a peak of 4 replicas across the topic's six partitions, then back to 0 once the group's offset caught the log-end.");

diagram("ON KUBERNETES · TWO OTEL EMITTERS", "Neither cluster shows a span the Wasm guest itself emitted",
  "24-otel-two-emitters-pipeline",
  "The shim emits traces by default on minikube; the wasmCloud host emits traces, metrics, and logs natively on CRC — both substrate-provided.",
  "No Wasm guest component in this book, Go or Rust, emits its own span, metric, or log through an OpenTelemetry SDK: wasi-otel is still an RC-only proposal, not part of wasm32-wasip1, and no runtime in the pinned stack implements it. What exists instead is two different substrate stories. containerd-shim-wasmtime has emitted OTel traces by default since runwasi v0.5.0 — no shim flag, no Pod annotation, pure standard OTEL_EXPORTER_OTLP_* environment variables reaching the containerd process through a node-level systemd drop-in, because the shim inherits whatever environment its parent process has. The wasmCloud host's spec.observability block turns on traces, metrics, and logs together, natively, because the host process already mediates every RPC dispatch between components — a naturally richer vantage point than one container's lifecycle events.");

diagram("ON KUBERNETES · SIGNAL PROVENANCE", "A three-by-two matrix: what each substrate actually tells you",
  "24-signal-provenance",
  "minikube: traces only, shim-emitted. CRC: traces, metrics, and logs, all host-native — neither ever describes the guest's own domain logic.",
  "The minikube column is narrower than a first glance at the verify script suggests: Prometheus and Loki both return real data, but what they return is the otel-lgtm stack's own self-observability — the collector's ingestion counter, the bundled stack's own process logs — not a metric or log describing the Wasm Pod itself. The CRC column has no such asterisk: wasmcloud_host.handle_rpc_message.duration is the one metric to name specifically, because it exists precisely at the link boundary Chapter 20 and Chapter 21 already made the center of their state-contrast findings — an operator with this pipeline wired up can watch a valid tracking id's individual book-cargo and get-cargo invocations show up as separate durations, direct confirmation that each call landed on an independent instance rather than a shared one, for a Go-built composite exactly as for a Rust one.");

// ===== SECTION 6 — GO-LEANING DEVIATION ==========================================
divider("6", "A Go-Leaning Deviation", "Spin and SpinKube — a fourth project on the Kubernetes landscape, run live.",
  "Opens the Spin/SpinKube section. The app itself in this book's tree is authored against spin-sdk in Rust, but Spin's own framework and SDK ergonomics apply the same way in Go — the trigger model, spin.toml, and the dependencies!() composition macro all have a direct TinyGo-targeting equivalent in Fermyon's own Go SDK. The structural lesson — a containerd shim that embeds a specific framework runtime rather than a generic wasmtime embedding — is the point for this deck, independent of which language authored the handler.");

diagram("DEVIATION · SPINKUBE VS. CRC", "The same privileged-node constraint, a different substitute runtime",
  "26-spinkube-vs-crc-paths",
  "minikube runs the full SpinKube platform; CRC runs the Spin CLI itself inside a plain restricted-v2 container — no shim, no operator.",
  "containerd-shim-spin needs the identical kind of privileged RHCOS node install that pushed Chapter 19 off the raw wasmtime shim and onto the wasmCloud operator — a node-level containerd plugin and a MachineConfig restart, incompatible with restricted-v2. On CRC, the substitute is simpler than an operator, because Spin's own CLI is the whole runtime a cargo-spin.wasm component needs: spin up loads the component and serves its HTTP trigger directly, so an ordinary Deployment under restricted-v2 is enough, with no CRD and no controller at all. Both paths are verified live, serving the identical cargo JSON through two completely different mechanisms — the same constraint Chapter 19 established, now resolved a second way for a second framework.");

diagram("DEVIATION · THE BACKEND LANDSCAPE", "Four shims, four embedded runtimes, four app shapes",
  "26-wasm-backend-landscape",
  "containerd-shim-wasmtime is generic; containerd-shim-spin embeds the Spin runtime itself, scoped to spin.toml-packaged apps.",
  "SpinKube's containerd-shim-spin is runwasi-scaffolded exactly like the generic wasmtime shim, registered the identical way under a RuntimeClass — but it embeds the Spin runtime itself, so it only runs applications packaged Spin's way: a spin.toml manifest declaring triggers, components built against spin-sdk's ergonomic layer, and Spin's own OCI packaging. spin_sdk::dependencies!() is Spin's own answer to the same import-satisfaction problem wac plug solves everywhere else in this deck — a manifest table names the provider, spin build decodes its exports into a generated spin-dependencies.wit, and the macro bindgens it into ordinary functions at the crate root. The chapter's real teaching point is an ABI surprise worth carrying forward to any Spin SDK version: #[http_service] targets wasi:http@0.3.0, the wasip3 async world, not the 0.2.x incoming-handler every other HTTP example in this book exports — which is exactly why the shim version and the Spin CLI version both have to be new enough to understand it.");

// ===== SECTION 7 — FINAL PROJECT, GO HALF ========================================
divider("7", "Final Project, Go Half", "cargo-go.wasm: the same contract, the same JSON, a different language end to end.",
  "Opens the final project's Go half. build.sh does not write a new provider, a new front door, or a new line of contracts/wit — it rebuilds the Part 2 Go provider and the Part 3 http-go TinyGo front door with their own unedited recipes and wac plugs them into cargo-go.wasm, the identical assembly pattern Part 4's build.sh already used for the Rust side. Two different toolchains, two different language runtimes inside the component, one WIT contract, one JSON response.");

diagram("FINAL PROJECT · THE GO REQUEST PATH", "Two Pods, two languages, one shared edge",
  "28-final-project-request-path",
  "cargo-rust and cargo-go sit side by side under runtimeClassName wasmtime, both exporting incoming-handler, both answering the identical JSON.",
  "k8s/base/deployment-go.yaml is a straight copy of the Rust Deployment's shape — runtimeClassName: wasmtime, command: [\"/app.wasm\"], TCP probes on 8080, because the component answers GET / with 404 so a TCP probe is the correct liveness signal. One Ingress carries two host-based rules, cargo-rust and cargo-go, because both composites answer their own GET /cargo/{id} unprefixed. The Chapter 25 proxy-wasm WasmPlugin filter needs no change at all to gate both backends: it runs once in the shared istio-ingressgateway Envoy, ahead of either Service, so the x-cargo-tenant contract — 403 without the header, 200 plus x-cargo-filtered-by with it — applies identically to both languages, because the filter never inspects which composite it is in front of, only the request.");

diagram("FINAL PROJECT · ONE CONTRACT, TWO LANGUAGES", "Byte-identical JSON, asserted directly against each other",
  "28-one-contract-two-languages",
  "verify-minikube.sh asserts cargo-rust's body equals cargo-go's body, not merely that each separately matches the expected string.",
  "build.sh validates both composites identically before packaging either: wasm-tools component wit confirms each exports wasi:http/incoming-handler and that no patterncatalyst:* import survives composition, on both languages, and wasmtime serve -S cli smoke-tests each against the canonical and an unknown tracking id before either composite is allowed near an OCI image. The strongest assertion in this chapter is not that cargo-go matches an expected string — it is that cargo-rust's response body and cargo-go's response body are asserted equal to each other directly. On CRC, the same byte-for-byte cross-check runs through two separate edge-TLS Routes behind the wasmCloud operator, with no mesh and no shim trace, because restricted-v2 keeps the shim off that cluster entirely — a substrate boundary, not a gap in the proof. The two-language-one-contract thesis is proved by assembly: contracts/wit is read by two independent build pipelines and never written by either, and both outputs answer the identical JSON string through two different edges on two different clusters.");

// ===== APPENDIX ===================================================================
divider("A", "Appendix", "Command and pin reference for the Go toolchain this deck builds against.",
  "Opens the appendix. Reference material for anyone reproducing this deck's builds: the exact tool versions pinned throughout the Go examples, and a recap of every TinyGo-specific gotcha this deck named inline, gathered in one place for a lookup rather than a re-read.");

{
  const s = S();
  addContentTitle(s, "APPENDIX · TOOLCHAIN PINS", "Exact versions behind every Go build in this deck");
  addStatusTable(s, [
    { code: "go", name: "1.26.9", purpose: "Standard toolchain — cannot emit a wasip1/wasm component (see slide 5); used only to vet generated code." },
    { code: "tinygo", name: "0.43.0", purpose: "The required compiler for every Go component in this book; wasm32 native, no go:wasmexport pointer-width limit." },
    { code: "wit-bindgen-go", name: "v0.7.0", purpose: "Generates the Exports struct and cm types from contracts/wit for every world (cargo, cargo-consumer, cargo-http, etc.)." },
    { code: "wasm-tools", name: "1.262.0", purpose: "component embed / component new / component wit / objdump / validate across every build.sh in the Go tree." },
    { code: "wasmtime", name: "50", purpose: "wasmtime serve, the embedded Engine/Store/Linker API, and the native host in examples/part2.../host." },
    { code: "wac", name: "(pinned in lib.sh)", purpose: "wac plug composition for every provider/consumer, provider/HTTP, and interposer pairing in this deck." },
    { code: "wash", name: "v0.43.0", purpose: "wasmCloud CLI; bundles nats-server 2.11.3, wadm 0.21.1, wasmcloud host 1.9.1." },
  ], { colW: [1.75, 1.55, 8.79] });
  addNotes(s, "A single reference table for anyone reproducing this deck's examples from a clean checkout. The go row is listed specifically to reinforce the deck's opening claim with a version number: go1.26.9 is the exact release the real compiler diagnostic on slide 5 was captured against, not a hypothetical older toolchain. Every other row is the exact pin examples/part2-building-components/go/build.sh and its siblings across Parts 3 through 7 check for on PATH before running.");
}

content("APPENDIX · GO GOTCHAS, GATHERED", "Every TinyGo-specific finding in this deck, in one place",
  ["Standard go build rejects wit-bindgen-go's own pointerful wasmexport signatures on GOOS=wasip1 GOARCH=wasm — TinyGo's native wasm32 target has no such restriction.",
   "cabi_realloc is hand-written for Go (unlike Rust's wit-bindgen, which provides it): heap-backed for a reactor, a static bump arena for a command — using the wrong one traps at startup.",
   "google.golang.org/protobuf compiles under TinyGo 0.43 but traps at runtime on reflect.Type.MethodByName; proto-go ships a hand-written reflection-free wire codec instead.",
   "sockets-go builds and wasm-tools validates as a real component, but has no clean runtime path on TinyGo 0.43 — a command traps on an early random_get, a reactor's pollable.block() never resolves under a hand-rolled host."],
  "This slide exists purely as a lookup aid: every item here was explained in full, with the real diagnostic or the real transcript, earlier in this deck. Each is stated as a precise, versioned, mechanical fact — never as a defect or an apology — because every one of them is either a documented toolchain-maturity gap with a named upstream issue, or a real architectural property (cabi_realloc's reactor-versus-command split) that would apply to any language building this shape of component. None of these findings changes the headline claim: a Go-built provider, front door, or consumer composes and runs byte-identically alongside its Rust counterpart everywhere this deck's build-and-validate gates actually pass.");

pres.writeFile({ fileName: OUT })
  .then(p => console.log("WROTE", p, "slides:", pageNum))
  .catch(e => { console.error(e); process.exit(1); });
