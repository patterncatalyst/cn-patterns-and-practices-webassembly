---
title: "wasmCloud"
order: 15
part: "Runtimes: wasmtime & wasmCloud"
description: "Run the same component on wasmCloud's lattice, with a capability provider, a declarative OAM link and wadm's reconcile loop in place of a single wasmtime process."
duration: "17 min read"
---

## Learning objectives

By the end of this chapter you can:

- Name the three things `wash up -d` starts (NATS, a wasmcloud **host** and **wadm**) and say what each is responsible for.
- Read a wadm OAM manifest and identify its three parts: the **component**, the **capability provider** and the **link** that carries `wasi:http/incoming-handler` calls between them.
- Explain why the deployed `app.wasm` is the same artifact `wasmtime serve` runs.
- Deploy, and say why `wash app status: Deployed` does not prove the service answers.
- Read wadm's self-healing transcript and explain the SpreadScaler's reconcile loop.
- State the one runtime difference that matters here: wasmCloud ignores an exported component **resource**.
- Decide whether a lattice is worth its infrastructure over a single wasmtime process.

## Why this matters

`wasmtime serve` is one process. It opens a socket and drives the component directly, and when it dies nothing restarts it unless something outside wasmtime notices. wasmCloud treats "running a component" as a declarative statement to a platform. `wadm.yaml` does not say "start this process"; it says "this component has exactly one instance, linked to this provider on this interface," and a control plane keeps the lattice matching that statement.

The workload is the cargo HTTP front door, unmodified: a Rust `cargo` provider composed under the `http-rust` world with `wac plug` into one `app.wasm` that exports `wasi:http/incoming-handler`. `build.sh` rebuilds it from the same upstream crates and `contracts/wit` stays untouched. What is new is everything around it: a **lattice** (NATS connecting a host, wadm and the `wash` CLI), a **host** that runs the component and a **capability provider** beside it, and a **link** that dispatches the provider's inbound HTTP to this component on this interface.

The payoff is the reconcile loop. Scale the running component to zero by hand and traffic fails at once, because the provider's listener is open with nothing behind it. Within two seconds, with no second command, wadm sees the drift from the declared `instances: 1` and restores it.

{% include excalidraw.html file="15-lattice-architecture" alt="Outside the lattice, curl sends GET http://127.0.0.1:8000/cargo/id. Inside a band labeled lattice (everything wash up -d starts) sit NATS 2.11.3, the message bus, and wadm 0.21.1, which reconciles wadm.yaml against actual state. A larger band for wasmcloud host 1.9.1 contains the httpserver capability provider 0.27.0, which opens 0.0.0.0:8000 and translates inbound HTTP into wasi:http/incoming-handler calls, and below it the cargo-http component (file://./app.wasm, one instance, exporting wasi:http/incoming-handler@0.2.8). Between them a link box lists namespace wasi, package http, interface incoming-handler and source_config with address 0.0.0.0:8000. The component is the same app.wasm that runs under wasmtime serve. The provider owns the socket and the component only ever sees a WIT call." caption="Figure 15.1: the lattice for cargo-http, with NATS and wadm outside the host, the httpserver provider and the component linked inside it, and the same app.wasm that runs under wasmtime serve." %}

## The lattice: NATS, the host and wadm

One command, `wash up -d`, starts everything, where `wash` is wasmCloud's CLI. It bundles pinned versions of the three pieces:

```
$ wash --version
wash          v0.43.0
├ nats-server v2.11.3
├ wadm        v0.21.1
└ wasmcloud   v1.9.1
```

A ground-up rewrite of `wash` (2.x), with the host built into the CLI, is in release-candidate; the shipping 0.43 line is what applies here. The `-d` flag detaches the lattice as a background daemon. Each piece has a distinct job:

| Piece | Job |
|---|---|
| **NATS** | The lattice's message bus. Every invocation, link and host-to-wadm status update travels over NATS subjects. Any number of hosts can join the same subject space and see the same components and providers, which is why it is a lattice and not a cluster. |
| **wasmcloud host** | Runs components and supervises capability providers as OS processes. Exposes the lattice operations (`wash get hosts`, `wash get inventory`, `wash scale component`). |
| **wadm** | The control plane that makes a declarative manifest true. It watches actual state over NATS and continuously reconciles it against deployed OAM `Application` manifests. `wash app deploy` hands it a manifest and wadm keeps enforcing it afterward. |

A host is a separate OS process that `wash up` spawns, so it is not ready the moment the command returns. `capture-evidence.sh` polls `wash get hosts -o json` until one appears.

## The wadm manifest: component, provider and link

`wadm.yaml` is an OAM `core.oam.dev/v1beta1` `Application` for wadm 0.21.x, and it is the whole declarative description of what runs:

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
        # same bytes also run under `wasmtime serve`; see prove-same-bytes.sh.
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

The manifest names two kinds of thing that can run in the lattice:

- **A component** (`type: component`) is a WebAssembly component compiled to `.wasm` and run inside the host's wasmtime-based embedding. `image: file://./app.wasm` is a local file reference, not an OCI pull. **Local file references resolve against the deploy working directory, not the manifest's location.** The host's log records the absolute `file:///…/app.wasm` it resolved; a `wash app deploy` from another directory needs an absolute `file:///` reference or an OCI push. The `spreadscaler` trait with `instances: 1` is the desired instance count: not "start one instance" but "there is always exactly one," enforced continuously.
- **A capability provider** (`type: capability`) is not a WebAssembly component. It is a native binary wasmCloud starts as its own OS process to own a capability a sandboxed component cannot hold, here an open TCP listener. `ghcr.io/wasmcloud/http-server:0.27.0` is wasmCloud's maintained HTTP provider and the latest released semver tag; later tags are commit-SHA builds. It terminates HTTP on the socket and turns each request into a `wasi:http/incoming-handler` call on the linked component. This is the same split WASI draws between a capability a component imports and the host that satisfies it, now a separate, independently versioned process.

The **link** ties them together. `target: cargo-http` names the receiving component. `namespace`, `package` and `interfaces` name the WIT interface (a provider can expose several, and several links can target one component on different interfaces). `source_config` passes configuration to the provider: the address to bind is link-level configuration, not baked into the provider image. The component exports `wasi:http/incoming-handler@0.2.8` and the provider speaks `wasi:http` 0.2.x; wasmCloud links by interface name across compatible 0.2.x patch levels, so neither side needs the identical patch version.

## Deploying and verifying

With the lattice up, deployment is one command:

```
$ wash app deploy wadm.yaml

Deployed application "cargo-http", version "v0.0.1"
```

That is wadm accepting the manifest and beginning to reconcile. It does not mean the service answers yet. `capture-evidence.sh` gates on the real endpoint, polling for up to 90 seconds:

```bash
ready=0
for i in $(seq 1 90); do
  if [[ "$(curl_code "$BASE$VALID_PATH")" == "200" ]]; then
    echo "service answered 200 after ${i}s"; ready=1; break
  fi
  sleep 1
done
```

Once the deploy settles, `wash app status` reports every piece `Deployed`:

```
$ wash app status cargo-http

cargo-http@ - Deployed                                                                    
                                                                    
  Name                                     Kind           Status    
  cargo_http                               SpreadScaler   Deployed  
  httpserver -(wasi:http)-> cargo_http     LinkScaler     Deployed  
  httpserver                               SpreadScaler   Deployed  
                                                                    
```

The link is its own row, a `LinkScaler`: wadm reconciles the link's desired state as it does instance counts, not as a one-time wiring step. `wash get inventory` shows what runs on the host, by ID:

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

wasmCloud gives every host a random friendly name (`sparkling-sunset-0738`) beside its long ID. **`Deployed` means the desired state was accepted, not that the component is answering.** It is the same distinction as a pod `Running` before its readiness probe passes, so treat the HTTP response as the only readiness signal.

With the link live, the HTTP path matches the single-process runtime because it dispatches into the same component:

```
$ curl -s http://127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM
{"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}
$ curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8000/cargo/NOPE
404
```

The response is identical. What differs is everything upstream of the component: a native provider owns the socket instead of wasmtime's `wasi:http` proxy world, and the dispatch is a link described in YAML instead of a command-line flag.

## Resilience: wadm's self-healing loop

An in-component retry loop and the lattice's own supervision answer different resilience questions at different layers. To see the second one, remove the component from under a healthy application: not by redeploying or editing the manifest, but by telling the host to scale it to zero.

```
# before: service is healthy
GET /cargo/CARGO-USNYC-DEHAM -> 200  {"tracking_id":"CARGO-USNYC-DEHAM","origin":"USNYC","destination":"DEHAM","weight_kg":1200.5,"price":{"amount":"1500.00","currency":"USD"}}

# scale the component to 0 instances (provider/listener stays up)
$ wash scale component <host> file://<repo>/examples/part4-runtimes/wasmcloud/app.wasm cargo_http-cargo_http --max-instances 0
Component [cargo_http-cargo_http] (ref: [file://<repo>/examples/part4-runtimes/wasmcloud/app.wasm]) scaled on host [NCQR6FIQCONSILLUFUMAENAPFDCRP223B53PRVRR42HSOA4NYFW3SYPC] to 0 max concurrent instances

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

`wash scale component` talks to the host, not to wadm: an imperative "run zero instances" that the host obeys at once. The provider never hears about it, so its listener on `0.0.0.0:8000` stays bound. That is why the failure is a `500` and not a refused connection: the provider accepts the request, tries to dispatch over `wrpc` to a component instance, finds none, and the invoke fails. The capability boundary is intact; the thing on the other end of the link is gone.

wadm never stopped watching. It compares the declared `spreadscaler: instances: 1` with what the lattice reports over the same NATS subjects, sees 1 against 0, and issues its own command to bring the component back. A Kubernetes `Deployment` controller replaces a deleted pod the same way. Recovery took two seconds, with no second `wash app deploy` and no edit to `wadm.yaml`, and the healed service returns the same JSON because it runs the same `app.wasm`. Scaling to zero under a managed app is the intended way to see the loop on demand, as a chaos drill deletes a healthy pod to prove a controller replaces it.

{% include excalidraw.html file="15-wadm-self-heal-loop" alt="A five-step timeline. Step 1, healthy: GET returns 200 and the component has 1 instance. Step 2, wash scale --max-instances 0: the provider's listener stays up and the component drops to 0 instances. Step 3, traffic fails: GET returns 500 with failed to invoke wrpc:http/incoming-handler. Step 4, wadm reconciles: the SpreadScaler sees desired 1 and actual 0. Step 5, recovered: GET returns 200 about 2 seconds later with no redeploy. Below, a box describes the continuous loop: desired state is the manifest's instances 1, actual state is what the lattice reports now, and every drift is corrected automatically. A note says wash app status reporting Deployed does not mean step 3's 500s are not occurring." caption="Figure 15.2: wadm's SpreadScaler restoring the component to one instance after a manual scale-to-zero: 500s for about two seconds, then recovery with no redeploy." %}

## The one real gap: exported resources are ignored

Deploying `app.wasm` produces a host warning `wasmtime serve` never does:

> **`exported component resources are not supported in wasmCloud runtime and will be ignored`**

The `handling` interface exports a `cargo-tracker` **resource**, a stateful handle type with methods, beside the plain functions on `booking`. wasmCloud's component-loading path loads the plain function exports and ignores the resource export, logging a WARN instead of failing the deploy. The HTTP path calls only `booking`, so nothing here changes: the JSON is identical to the single-process response. But the difference is structural. A caller that needs `cargo-tracker`'s methods through wasmCloud would find them unreachable, with no error beyond a log line. When a caller depends on a resource's statefulness, move that state into a capability provider, the native-process boundary `httpserver` already demonstrates.

> **Decision**
>
> Use wasmCloud's lattice when you need what it provides by design: desired state that a control plane reconciles without anyone re-running a deploy (the SpreadScaler recovered the component in about two seconds), capabilities that run as separate, independently versioned, crash-isolated processes (the provider's socket survived a component crash), or components and providers addressable across hosts without hand-built distribution. Stay with one `wasmtime serve` process when none of that applies. One process under one restart policy (systemd, a container runtime, Kubernetes) has fewer moving parts and no link YAML to get wrong, and the request behavior is byte-identical. The lattice costs a NATS bus, a wadm process, an OAM manifest and a link that must be right before the first request succeeds. Pay that when the reconcile loop or the multi-host lattice is a requirement, not because it is available.

> **🤖 Explore with your agent**
>
> "In examples/part4-runtimes/wasmcloud, read wadm.yaml and explain which parts a lattice gives that `wasmtime serve -S cli app.wasm` does not. Then change the spreadscaler `instances` from 1 to 2, say what `wash get inventory` should show for the component's max count, and name what an exported component resource in the `handling` interface would do under wasmCloud."
>
> Check: after `wash app deploy wadm.yaml`, `wash get inventory` lists `cargo_http-cargo_http` with the max count you predicted, and `wash app status cargo-http` shows every row `Deployed`.

## Build, run, observe

```bash
cd examples/part4-runtimes/wasmcloud && export WASH_DISABLE_INTERACTIVE=1 && ./capture-evidence.sh
```

The script builds `app.wasm` with `build.sh`, brings up a local lattice with `wash up -d`, and deploys `wadm.yaml`. It polls `127.0.0.1:8000/cargo/CARGO-USNYC-DEHAM` until the service answers `200`, then records `wash app status` and `wash get inventory`, runs the scale-to-zero drill and records `sha256sum app.wasm`. A passing run writes transcripts under `evidence/<date>/` and exits zero. `teardown.sh` removes the application and stops the lattice, and the README has the full script table.

Experiments:

- Run `wash app deploy` from a directory other than the one holding `app.wasm`: the relative `file://./app.wasm` no longer resolves and the component does not start.
- Scale to zero and watch: `500`s for about two seconds, then `200` again with no redeploy.
- Check the host log for the `exported component resources ... will be ignored` WARN on every deploy of this component.

## For deeper coverage

- [wasmCloud documentation](https://wasmcloud.com/docs/): the lattice, host, capability providers and OAM application manifests.
- [wadm (WebAssembly Distributed Application Manager)](https://github.com/wasmCloud/wadm): the SpreadScaler and LinkScaler reconcile logic the resilience drill exercises.
- [wasmCloud httpserver provider](https://github.com/wasmCloud/capability-providers/tree/main/http-server): the `ghcr.io/wasmcloud/http-server` provider source linked at `0.27.0`.
- Danilo Chiarlone, *Server-Side WebAssembly* (Manning): the Component Model treatment of exported resources.
- Shashank Jain, *WebAssembly for Cloud* (Apress): wasmCloud's actor-and-lattice model and capability-provider architecture in more operational depth.
