---
title: "wasmCloud"
order: 15
part: "Runtimes: wasmtime & wasmCloud"
description: "Move the same component onto wasmCloud's lattice, with a capability provider, a declarative OAM link, and wadm's reconcile loop replacing a single wasmtime process."
duration: "21 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the three things `wash up -d` starts in a local **lattice** (NATS the message bus, a wasmcloud **host**, and **wadm**) and explain what each one is responsible for.
- Read a wadm OAM manifest (`wadm.yaml`) and identify its three moving parts: the **component** (`cargo-http`, a local `file://./app.wasm` reference), the **capability provider** (`httpserver`, an OCI image), and the **link** that wires the provider's `wasi:http/incoming-handler` calls to the component, carrying the listen address as `source_config`.
- Explain why the deployed `app.wasm` is the identical artifact Chapter 14 runs under `wasmtime serve`, and why that matters for the "same component, different runtime" claim this Part makes.
- Walk the real deploy sequence (`wash up -d`, then `wash app deploy wadm.yaml`, then a live `curl` against `127.0.0.1:8000`) and state why `wash app status: Deployed` is not, by itself, proof the service answers.
- Read wadm's self-healing transcript (scale the component to zero, watch traffic fail, watch wadm restore it without a redeploy) and explain the SpreadScaler's reconcile loop in your own words.
- State the one real difference this runtime introduces versus `wasmtime serve`: wasmCloud ignores an exported component **resource**, and the WARN wording the host emits when it does.
- Decide, for a given component, whether a lattice's links and self-healing earn their operational weight over a single wasmtime process, or whether that process is the simpler and equally correct choice.

## Why this matters

Chapter 14 ran `app.wasm` as one process: `wasmtime serve` opened a socket, drove the component directly, and when that process died, nothing restarted it unless something outside wasmtime noticed and acted. wasmCloud takes the same component and asks a different question: what if "running a component" were a declarative statement to a platform instead of an invocation of a binary? `wadm.yaml` doesn't say "start this process"; it says "this component should have exactly one instance, linked to this capability provider, on this interface, forever," and a control plane (wadm) continuously makes the lattice's actual state match that statement. Chapter 13 drew a hard boundary around this exact question and left it unanswered: its closing section named wasmCloud's lattice as "a different resilience question (link availability across a distributed runtime) answered at a different layer," and deferred the proof to this chapter. This is where that proof lands.

The example is the same cargo HTTP front door from Part 3, unmodified: the Part 2 Rust `cargo` provider, composed under the Part 3 `http-rust` world via `wac plug`, producing one `app.wasm` that exports `wasi:http/incoming-handler`. `examples/part4-runtimes/wasmcloud/build.sh` rebuilds it from the same upstream crates: nothing here forks or edits the component, and `contracts/wit` stays untouched. What's new is everything around it: a **lattice** (NATS-based messaging connecting a host, wadm, and the `wash` CLI), a **host** that actually runs the component and a **capability provider** alongside it, and a **link**, a declarative statement in the OAM manifest that the provider's inbound HTTP calls should be dispatched to this specific component on this specific interface. None of that infrastructure existed in Chapter 14; all of it is live, in this example, captured end to end on 2026-10-21.

The payoff for sitting through that added machinery is the second half of this chapter: wasmCloud's wadm is not just a deployer, it's a continuous reconciler. Scale the running component to zero instances by hand (simulating a crash, an OOM-kill, anything that silently removes it) and traffic fails immediately, because the provider's listener is still open but has nothing behind it. Within two seconds, with nobody running a second command, wadm notices the drift between the manifest's declared `instances: 1` and the lattice's actual `0`, and restores it. That self-healing loop, not the deploy step, is the reason a lattice earns a chapter of its own instead of being a footnote to "wasmtime, but distributed."

{% include excalidraw.html file="15-lattice-architecture" alt="A lattice diagram. Outside the lattice, curl sends GET http://127.0.0.1:8000/cargo/id. Inside a light band labeled lattice: everything wash up -d starts, two boxes on the left: NATS 2.11.3 (the lattice message bus wash, wadm, and the host all talk over) and wadm 0.21.1 (reconciles wadm.yaml against actual lattice state). A larger amber band on the right labeled wasmcloud host 1.9.1 contains two boxes: the httpserver capability provider 0.27.0 (image ghcr.io/wasmcloud/http-server:0.27.0, opens 0.0.0.0:8000, translates inbound HTTP into wasi:http/incoming-handler calls) above, and the cargo-http component (image file://./app.wasm, spreadscaler instances 1, exports wasi:http/incoming-handler@0.2.8) below, with a ghost box noting this is the same app.wasm Chapter 14 runs under wasmtime serve. Between the provider and the component, an ink box labeled the LINK lists namespace wasi, package http, interfaces incoming-handler, source_config cargo-http-listen, address 0.0.0.0:8000. Arrows: curl into the provider; a dashed arrow from wadm into the host labeled deploys/reconciles; an amber arrow from the provider through the link labeled link; an amber arrow from the link down into the component labeled wrpc:http/incoming-handler. A caption notes the provider owns the socket and the component only ever sees a WIT call." caption="Figure 15.1 — the wasmCloud lattice for cargo-http: NATS + wadm outside the host, the httpserver provider and the component linked inside it, dispatching the same app.wasm Chapter 14 runs under wasmtime serve." %}

## The lattice: NATS, the host, and wadm, all from one command

Everything in this chapter runs behind a single command, `wash up -d`, where `wash` is wasmCloud's CLI (`wash` itself is the tool; the host, NATS server, and wadm it launches are separate bundled binaries). The real version output, captured first:

```
$ wash --version
wash          v0.43.0
├ nats-server v2.11.3
├ wadm        v0.21.1
└ wasmcloud   v1.9.1
```

`wash 0.43.0` is the current stable CLI, and it bundles three specific pinned versions underneath it: `nats-server 2.11.3`, `wadm 0.21.1`, and the `wasmcloud` host itself at `1.9.1`. (A ground-up rewrite of `wash`, version 2.x, with the host built directly into the CLI instead of launched as a separate bundled binary, is in release-candidate as this is written. It isn't the shipping tool yet, so this chapter teaches what `wash 0.43.0` actually does today, not what the 2.x line is expected to simplify later.)

`wash up -d` starts the lattice **detached** (the `-d` is what makes it a background daemon instead of a foreground process this chapter would otherwise have to leave running in its own terminal) and the real transcript shows exactly what comes up:

```
$ wash up -d
👀 Found nats-server version on the disk: nats-server: v2.11.3
✅ Using nats-server version [v2.11.3]
ℹ️  NATS server successfully started, using config @ [/home/rsedor/.local/share/wash/downloads/nats.conf]
ℹ️  NATS server logs written to [/home/rsedor/.local/share/wash/downloads/nats.log]
👀 Found wadm version on the disk: wadm 0.21.1

🛁 wash up completed successfully
🕸  NATS is running in the background at 127.0.0.1:4222
📜 Logs for the host are being written to /home/rsedor/.local/share/wash/downloads/wasmcloud.log

⬇️  To stop wasmCloud, run "wash down"
```

Three things are now running, and each has a distinct job:

- **NATS** is the lattice's message bus. Every component invocation, every link, every host-to-wadm status update travels over NATS subjects; it's the wire the lattice is built on, the same way a service mesh's sidecar proxies are built on a shared data plane. A component or provider never talks to NATS directly, the host mediates that, but NATS is what makes "lattice" the right word instead of "cluster": any number of hosts can join the same NATS subject space and see the same components and providers, regardless of which machine they're physically running on.
- **The wasmcloud host** (`1.9.1` here) is the thing that actually runs components and capability providers as OS processes it supervises, and exposes the lattice-level operations (`wash get hosts`, `wash get inventory`, `wash scale component`) this chapter uses below. `wash get hosts` confirms exactly one host came up:

  ```
  $ wash get hosts

                                                                                                           
    Host ID                                                      Friendly name           Uptime (seconds)  
    NCQR6FIQCONSILLUFUMAENAPFDCRP223B53PRVRR42HSOA4NYFW3SYPC     sparkling-sunset-0738   2                 
                                                                                                           
  ```

  wasmCloud assigns every host a random, human-pronounceable friendly name (`sparkling-sunset-0738` here) alongside the long host ID, purely so a person reading `wash` output has something easier to say out loud than the ID string.
- **wadm** (`0.21.1`) is the control plane that makes a declarative manifest true. It watches the lattice's actual state over NATS and continuously reconciles it against whatever OAM `Application` manifests have been deployed. `wash app deploy` hands wadm a manifest; wadm is what keeps enforcing it afterward, which is the entire reason the resilience section later in this chapter works without a second deploy.

`capture-evidence.sh` polls `wash get hosts -o json` in a loop until a host appears before doing anything else: a host is a separate OS process `wash up` spawns, and the script doesn't assume it's instantly ready the moment the `wash up -d` command returns.

## The wadm manifest: components, a capability provider, and the link

`examples/part4-runtimes/wasmcloud/wadm.yaml` is a `wadm 0.21.x` / OAM `core.oam.dev/v1beta1` `Application`, and it is the entire declarative description of what should run:

```yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: cargo-http
  annotations:
    version: v0.0.1
    description: "Cargo HTTP front door (Part 2 provider composed under the Part 3 http-rust world) on wasmCloud"
spec:
  components:
    - name: cargo-http
      type: component
      properties:
        # Local build output (build.sh writes it next to this manifest). The
        # same bytes also run under `wasmtime serve` — see ch16 / prove-same-bytes.sh.
        image: file://./app.wasm
      traits:
        # Keep one instance of the component running.
        - type: spreadscaler
          properties:
            instances: 1

    - name: httpserver
      type: capability
      properties:
        # Latest released HTTP server provider; speaks wasi:http 0.2.x and is
        # compatible with the wasmcloud host 1.9.1 bundled in wash 0.43.
        image: ghcr.io/wasmcloud/http-server:0.27.0
      traits:
        # The provider (source) is linked to the component (target) on
        # wasi:http/incoming-handler. source_config supplies the listen address.
        - type: link
          properties:
            target: cargo-http
            namespace: wasi
            package: http
            interfaces:
              - incoming-handler
            source_config:
              - name: cargo-http-listen
                properties:
                  address: 0.0.0.0:8000
```

wasmCloud's OAM spec distinguishes two kinds of things that can run in the lattice, and the manifest names both:

- **A component** (`type: component`) is a WebAssembly component, exactly the kind of artifact this site has built since Chapter 6, compiled to a `.wasm` file and run inside the host's wasmtime-based embedding. `cargo-http`'s `image: file://./app.wasm` is a *local file reference*, not an OCI pull: `build.sh` writes `app.wasm` next to `wadm.yaml`, and because every `wash` command in this example runs from that same directory, the relative path resolves. **Local file refs resolve against the deploy CWD, not the manifest's location**: the host's own log records the path it actually resolved as an absolute `file:///…/app.wasm`, and a `wash app deploy` run from any other directory would need an absolute `file:///` reference (or a real OCI push) instead. The `spreadscaler` trait with `instances: 1` is the declarative instance count this chapter's whole resilience section depends on: it's not "start one instance," it's "there should always be exactly one instance," enforced continuously.
- **A capability provider** (`type: capability`) is *not* a WebAssembly component. It's a native binary wasmCloud starts as its own OS process, specifically to own a capability a sandboxed component structurally cannot hold itself: in this case, an open TCP listening socket. `httpserver`'s `image: ghcr.io/wasmcloud/http-server:0.27.0` pulls wasmCloud's own maintained HTTP server provider from GitHub Container Registry: the latest released semver tag at the time of this capture (the only tags published past it are commit-SHA builds, not releases). The provider opens `0.0.0.0:8000`, terminates real HTTP on that socket, and for every inbound request, translates it into a `wasi:http/incoming-handler` call dispatched into whichever component is linked to it. This is the same provider/component split Chapter 4 drew in the abstract between a capability a component imports and the host implementation that satisfies it, now running as an actually separate, independently versioned process instead of code linked into wasmtime's embedding API.

The **link** is the trait that ties the two together, and it's worth reading field by field because every one of them does real work: `target: cargo-http` says which component receives the calls; `namespace: wasi` / `package: http` / `interfaces: [incoming-handler]` names the exact WIT interface this link is for (a provider can expose more than one capability, and more than one link can target the same component on different interfaces); and `source_config` passes configuration *to the provider*: here, the one thing the httpserver provider needs to know that isn't in its image at all, which address and port to bind. The provider is generic; the address it listens on is link-level configuration, not something baked into `ghcr.io/wasmcloud/http-server:0.27.0` itself. Our `app.wasm` exports `wasi:http/incoming-handler@0.2.8`; the provider speaks `wasi:http` at the 0.2.x line in general, and wasmCloud links by interface name across compatible 0.2.x patch levels, so the link is satisfied without either side needing to pin an identical patch version.

## Deploying it: wash up, wash app deploy, a real 200

With the lattice up, deployment is one command:

```
$ wash app deploy wadm.yaml

Deployed application "cargo-http", version "v0.0.1"
```

That output is wadm accepting the manifest and beginning to reconcile toward it; it is not proof the service is answering requests yet. `capture-evidence.sh` treats the gap between "accepted" and "answering" as the thing to gate on, polling `curl` against the real endpoint for up to 90 seconds before doing anything else:

```bash
ready=0
for i in $(seq 1 90); do
  if [[ "$(curl_code "$BASE$VALID_PATH")" == "200" ]]; then
    echo "service answered 200 after ${i}s"; ready=1; break
  fi
  sleep 1
done
```

Only after that loop exits does the script check `wash app status`, which, once the deploy settles, reports every piece as `Deployed`:

```
$ wash app status cargo-http

cargo-http@ - Deployed                                                                    
                                                                    
  Name                                     Kind           Status    
  cargo_http                               SpreadScaler   Deployed  
  httpserver -(wasi:http)-> cargo_http     LinkScaler     Deployed  
  httpserver                               SpreadScaler   Deployed  
                                                                    
```

Notice the link itself shows up as its own row (`httpserver -(wasi:http)-> cargo_http`, a `LinkScaler`) alongside the two `SpreadScaler` rows for the provider and the component. wadm tracks the link's desired state exactly the same way it tracks instance counts: as something to continuously reconcile, not a one-time wiring step. `wash get inventory` confirms what's actually running on the host, by ID:

```
$ wash get inventory

                                                                                        
  Host ID                                                      Friendly name            
  NCQR6FIQCONSILLUFUMAENAPFDCRP223B53PRVRR42HSOA4NYFW3SYPC     sparkling-sunset-0738    
                                                                                        
  Host labels                                                                           
  hostcore.arch                 x86_64                                                  
  hostcore.os                   linux                                                   
  hostcore.osfamily             unix                                                    
                                                                                        
  Component ID                  Name                           Max count                
  cargo_http-cargo_http         N/A                            1                        
                                                                                        
  Provider ID                   Name                                                    
  cargo_http-httpserver         http-server-provider                                    
                                                                                        
                                                                                        
```

**`wash app status: Deployed` means the desired state was accepted; it does not by itself mean the component is answering.** This is the same distinction a Kubernetes reader already knows from `kubectl get pods` showing `Running` before a readiness probe passes: wadm's status reflects what it has reconciled to, not a live health check of the HTTP path. The capture script treats the actual HTTP response as the only acceptable readiness signal, exactly as its Kubernetes counterparts in Part 5 will.

With the link live, the HTTP path behaves identically to Chapter 14's `wasmtime serve`, because it's dispatching into the identical component:

```
$ curl -s http://127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8000/cargo/NOPE
404
```

Same tracking ID, same JSON shape, same 404 on a cargo ID that doesn't exist. The difference from Chapter 14 isn't in the response; it's everything upstream of the component that produced it: a native capability provider owning the socket instead of wasmtime's own `wasi:http` proxy world, dispatching over a lattice link described in YAML instead of a command-line flag.

## Resilience: wadm's self-healing reconcile loop

Chapter 13 drew a hard line between an in-component retry loop and "the lattice's own supervision" as a different resilience question at a different layer, and deferred it to this chapter. Here it is, captured live. The test: remove the running component out from under a healthy, serving application, not by redeploying, not by editing the manifest, just by telling the host directly to scale it to zero, and watch what wadm does next.

```
# before: service is healthy
GET /cargo/CARGO-USNYC-DEHAM -> 200  {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}

# scale the component to 0 instances (provider/listener stays up)
$ wash scale component <host> file:///home/rsedor/Dev/cn-patterns-and-practices-webassembly/examples/part4-runtimes/wasmcloud/app.wasm cargo_http-cargo_http --max-instances 0
Component [cargo_http-cargo_http] (ref: [file:///home/rsedor/Dev/cn-patterns-and-practices-webassembly/examples/part4-runtimes/wasmcloud/app.wasm]) scaled on host [NCQR6FIQCONSILLUFUMAENAPFDCRP223B53PRVRR42HSOA4NYFW3SYPC] to 0 max concurrent instances

# burst while the component is gone: the provider answers but the
# invoke fails (no component to handle it) -> non-200
500 
fail_observed=1

# wadm reconciles the SpreadScaler back to 1 instance; poll to recovery
recovered after 2s

# after: service healthy again
GET /cargo/CARGO-USNYC-DEHAM -> 200  {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
fail_observed=1 recovered=1
```

Walk the sequence against what each layer does. `wash scale component ... --max-instances 0` talks directly to the host, not to wadm: it's an imperative command that tells the host "run zero instances of this component," and the host obeys immediately, no manifest involved. The httpserver provider never hears about this at all: its TCP listener on `0.0.0.0:8000` stays bound and accepting connections the entire time, because the provider is a separate process from the component and nothing told *it* to stop. That's exactly why the failure mode is a `500`, not a connection refused: the provider accepts the connection, tries to dispatch the `wasi:http/incoming-handler` call over `wrpc` to a component instance, finds none running, and the invoke itself fails: a different failure shape than Chapter 13's `access-denied` or `connection-refused`, because the capability boundary here is intact; it's the thing on the other end of the link that's temporarily gone.

wadm, meanwhile, has never stopped watching. Its reconcile loop continuously compares `wadm.yaml`'s declared state (`spreadscaler: instances: 1`) against what the lattice actually reports, over the same NATS subjects the host publishes its state to. The moment `wash scale` drops the actual count to zero, wadm sees drift between desired (1) and actual (0), and issues its own command to bring the component back: the exact mechanism a Kubernetes `Deployment`'s controller uses to replace a pod a `kubectl delete pod` removed out from under it, applied here to a WebAssembly component instead of a container. Recovery took two seconds in this capture, with no `wash app deploy` run a second time and nobody touching `wadm.yaml`. The healed service answers with the exact same JSON as before the scale-to-zero, because it's running the exact same `app.wasm` wadm already had on file.

{% include excalidraw.html file="15-wadm-self-heal-loop" alt="A five-step timeline. Step 1, healthy: GET returns 200, component has 1 instance. Step 2, wash scale --max-instances 0: the provider's listener stays up, component instance count drops to 0, shown in an ink box. Step 3, traffic fails: GET returns 500, failed to invoke wrpc:http/incoming-handler, no component, shown in a dashed ghost box. Step 4, wadm reconciles: an amber box showing the SpreadScaler sees desired=1, actual=0. Step 5, recovered: GET returns 200 again, about 2 seconds later, no redeploy. Below the timeline, a wide box describes wadm's continuous reconcile loop: desired state is wadm.yaml's spreadscaler instances 1 always, actual state is what the lattice reports right now, every drift gets corrected automatically, no human ran wash start component to bring it back. A dashed arrow points from step 4 down into this explanation box labeled reconcile fires here. A top caption cites the real evidence file and the recovered-after-2s timing; a bottom caption notes wash app status: deployed already happened back at step 2 and does not mean step 3's 500s aren't occurring." caption="Figure 15.2 — wadm's SpreadScaler reconciling the component back to one instance after a manual scale-to-zero: 500s for about two seconds, then recovery, with no redeploy." %}

`wash scale` fighting wadm like this is the intended use of the command, not a misuse of it: it's the cleanest way to *see* self-healing without waiting for a real crash. Scaling a component to zero under an app wadm is actively managing is exactly how the reconcile loop becomes visible on demand, the same way a chaos-engineering drill deletes a healthy pod to prove a Kubernetes controller replaces it rather than waiting for a real node failure to find out.

## The one real gap: exported component resources are ignored

Deploying `app.wasm` under wasmCloud surfaces a host warning Chapter 14's `wasmtime serve` never produces, because the two runtimes handle one part of the Component Model differently:

> **`exported component resources are not supported in wasmCloud runtime and will be ignored`**

Our `handling` interface (the same WIT interface Chapter 5 and Chapter 8 built the cargo domain against) exports a `cargo-tracker` **resource**, a stateful handle type with its own methods, alongside the plain functions on `booking`. The wasmCloud host's component-loading path does not support exported resources at all: it loads the plain function exports it understands and silently ignores the resource export, logging a WARN rather than failing the deploy. This example's HTTP path only ever calls through `booking`, which is all plain functions, so the ignored `cargo-tracker` resource has zero effect on anything this chapter demonstrates: the cargo JSON comes back identical to Chapter 14's. But it is a real, structural difference between the two runtimes, not a cosmetic one: a component that *did* depend on a caller using `cargo-tracker`'s resource methods through wasmCloud's host would find those methods simply unreachable, with no error beyond a log line a reader has to go looking for. Chapter 16 revisits this gap directly when it runs the identical `app.wasm` under both runtimes side by side; the fix, when a caller actually depends on a resource's statefulness, is to move that shape into a capability provider instead, which is exactly the kind of native-process boundary `httpserver` already demonstrates.

## When the lattice earns its weight

<div class="callout callout--safe"><p class="callout__title">Decision</p><p>Reach for wasmCloud's lattice when a deployment needs the properties this chapter demonstrated as a byproduct of its architecture, not as something bolted on afterward: a declarative desired state that a control plane continuously reconciles without a human or a cron job re-running a deploy command (wadm's SpreadScaler, shown recovering the component in ~2s with zero extra automation), capabilities that must run as actually separate, independently versioned, independently crash-isolated processes from the components that use them (the httpserver provider's socket survives a component crash that would take down an in-process HTTP stack entirely), or a topology where components and providers need to be addressable across more than one host without hand-rolling that distribution (the lattice's whole reason to exist). Stay with a single `wasmtime serve` process, as Chapter 14 does, when none of that is true yet: one process, one restart policy from whatever supervises it (systemd, a container runtime, Kubernetes itself in Part 5), is simpler to reason about, has fewer moving parts to misconfigure (there is no link YAML to get wrong), and loses nothing in request-handling behavior: the cargo JSON this chapter returned is byte-identical to Chapter 14's. The lattice's cost is real: a NATS bus, a wadm process, an OAM manifest, and a link to get right before the first request succeeds. Pay that cost when the reconcile loop or the multi-host lattice is a requirement, not a chapter's worth of infrastructure adopted because it was available.</p></div>

### Verified live (2026-10-21, wash 0.43.0 / wasmcloud host 1.9.1)

Every transcript in this chapter is quoted verbatim from `examples/part4-runtimes/wasmcloud/evidence/2026-10-21/`: `00-wash-version.txt`, `01-wash-up.txt`, `01b-wash-hosts.txt`, `03-deploy.txt`, `03b-app-status.txt`, `03c-inventory.txt`, `04-http.txt`, and `05-resilience.txt`. `capture-evidence.sh` ran the full sequence headlessly: `wash up -d`, `./build.sh`, `wash app deploy wadm.yaml` (gated on a real 200, not just `Deployed` status), the HTTP assertions, the scale-to-zero/self-heal resilience drill, and a `sha256sum app.wasm` recorded for Chapter 16's same-bytes proof (`eff7f5ee81db5f9fd4c444470d385f46e8d0aaba3302759028be90cb4c9909b3`), with every assertion backed by `set -e` and a secret scrub confirming zero credential material landed in the committed evidence.

## For deeper coverage

- [wasmCloud documentation](https://wasmcloud.com/docs/) — the authoritative treatment of the lattice, the host, capability providers, and OAM application manifests this chapter builds a single worked example against.
- [wadm (WebAssembly Distributed Application Manager)](https://github.com/wasmCloud/wadm) — the SpreadScaler and LinkScaler reconcile logic this chapter's resilience section exercises directly.
- [wasmCloud httpserver provider](https://github.com/wasmCloud/capability-providers/tree/main/http-server) — the `ghcr.io/wasmcloud/http-server` provider source this chapter links against at `0.27.0`.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning) — the Component Model treatment of exported resources this chapter's "ignored resource" gotcha depends on.
- Shashank Jain, *WebAssembly for Cloud* (Apress) — wasmCloud's actor-and-lattice model and capability-provider architecture covered in more operational depth than this chapter's single-app walkthrough.
- Chapter 5, "The Shared Cargo Domain as Components" — where the `handling` interface's `cargo-tracker` resource was defined; this chapter is the first place its export is silently ignored by a runtime.
- Chapter 13, "Networking, Reconnect, and Resilience" — the chapter that deferred lattice-level resilience to this one, and the in-component retry loop this chapter's platform-level self-healing sits one layer above.
- Chapter 14, "wasmtime" — the single-process baseline this chapter's lattice, provider, and link all exist to replace or complement.
- Chapter 16, "wasmtime and wasmCloud Together" — where the identical `app.wasm` (same sha256) runs under both runtimes side by side, and the exported-resource gap this chapter names gets a direct comparison.
- Part 5, "Deploying to Kubernetes" — where this chapter's lattice-level self-healing gets compared directly against a Kubernetes `Deployment` controller's own reconcile loop, the pattern wadm's SpreadScaler mirrors.
