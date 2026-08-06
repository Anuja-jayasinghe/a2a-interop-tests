# `a2a-ballerina` — complete repo walkthrough

> **Note**: this document describes the **official `ballerina/a2a` client library
> repo** (`a2a-ballerina`) — a separate repository from this one
> (`a2a-interop-tests`). It's kept here, in this repo's `docs/`, as reference
> material for anyone who needs a full orientation to that repo's codebase
> without cloning and reading it file by file. If the library changes
> substantially, re-verify the specifics below against its actual current
> source rather than trusting this as a live source of truth — see
> `SPEC_COMPLIANCE_REPORT.md` in this repo for a cautionary example of what
> happens when a document like this isn't kept in sync.

## What this is, in one paragraph

A Ballerina client library (org `ballerina`, package `a2a`) for the Agent2Agent (A2A) protocol. Given any A2A-compliant agent's URL, it discovers the agent's capabilities (`resolveAgentCard`) and then lets you call it — send messages, stream responses, manage tasks, configure push notifications — over whichever of the three spec-defined wire protocols (JSON-RPC, REST, gRPC) that agent speaks, in either of the two protocol dialects in the wild (current v1.0, legacy v0.3), all through one uniform `Client` API that doesn't change based on any of that. It's **client-only** by deliberate scope — nothing here lets a Ballerina program *be* an A2A agent (that's an explicitly deferred Phase 2).

## Layout at a glance

```
a2a/
├── types.bal              data model (records/enums, spec §3-4)
├── client.bal              the Client class + newClient/resolveAgentCard (the whole public API surface)
├── errors.bal              A2AError hierarchy + per-transport error mapping
├── sse.bal                 SSE stream decoding + auto-reconnect
├── compat_v03.bal          legacy v0.3 wire-dialect translation
├── grpc_binding.bal        gRPC ⇄ domain-type conversion layer
├── grpc_stream.bal         gRPC streaming adapter
├── auth.bal                AgentCard → http:ClientConfiguration.auth automation
├── signature.bal           AgentCard JWS signature verification
├── main.bal                dead `bal new` scaffold stub, unused
├── modules/
│   ├── transport/jsonrpc.bal   pure JSON-RPC envelope types (its own submodule — see why below)
│   └── grpcstub/                generated gRPC stub (its own submodule — see why below)
├── proto/                  vendored, hand-trimmed a2a.proto + provenance record
├── scripts/regen-grpc-stub.sh   regenerates modules/grpcstub/ from proto/, with guardrails
├── tests/                  359 mock-based unit tests (this package's own CI gate)
└── docs/
    ├── A2A_Technical_Design.md      the living design doc (data model, methods, error mapping, known gaps)
    ├── archive/                     superseded drafts, kept for history
    └── superpowers/{specs,plans}/   one spec+plan pair per feature, written before implementation
```

---

## The data model — `types.bal` (761 lines)

Every spec-defined shape as a Ballerina `record {| ... |}` or `enum`: `Message`, `Part`, `Task`, `TaskStatus`, `Artifact`, the two streaming update events, `AgentCard` and its sub-shapes, the five-way `SecurityScheme` discriminated union, `AgentCardSignature`. A few decisions worth knowing:

- **Every record ends in `json...;`** — an *open* record, deliberately. The spec evolves and real servers already send fields this library doesn't model yet; an open record means an unrecognized field is preserved rather than causing a parse failure or silently vanishing.
- **`Part` has no `kind` discriminator field.** v1.0 dropped it — which variant (`text`/`raw`/`url`/`data`) is determined by which field is actually present, not a tag. `parseSecuritySchemes`/`parseSecurityRequirements`/`parseAgentCardSignatures` all follow the same "drop the one malformed entry, don't fail the whole card" philosophy for the same forward-compatibility reason.
- **`encodeRawBytesForWire`/`decodeRawBytesFromWire`** are the most surprising code in this file: Ballerina's default `byte[]` JSON serialization produces an integer array (`[72, 101, ...]`), but every real A2A server expects base64 (the protobuf-JSON convention for bytes fields). These two functions walk a `Message`/`Task`/etc. tree *after* `toJson()` and *before* `cloneWithType()` respectively, converting just `Part.raw` — and only `Part.raw`, via a hand-maintained allow-list of exactly which container keys (`history`, `artifacts`, `parts`, etc.) can actually hold a `Part` — so a `metadata` field that happens to contain an unrelated key literally named `"raw"` is never touched. Structure-aware, not key-name-driven, on purpose.

## The client — `client.bal` (1520 lines, the whole public surface)

One `isolated class Client` with all 11 spec operations as `isolated remote function`s (`sendMessage`, `sendStreamingMessage`, `getTask`, `cancelTask`, `subscribeToTask`, `listTasks`, the four push-notification-config CRUD methods, `getExtendedAgentCard`), plus module-level `newClient`/`resolveAgentCard`/`resolveAgentCardCached`/`primaryUrl`/`selectInterface`.

- **Two public ways to construct a `Client`, both first-class.** `new (serviceUrl, ..., agentCard?)` is the low-level constructor — a concrete URL is mandatory, `agentCard` is an independent optional hint never used to derive the URL. `newClient(AgentCard|string agent, ...)` is the recommended factory for the common case: pass a URL (it resolves the card itself via `resolveAgentCard`) or an already-resolved `AgentCard` (it derives the URL via `primaryUrl`/`selectInterface`) — never both — and it auto-wires `tenant` from the selected `AgentInterface` when the caller doesn't pass one explicitly. `newClient` is implemented in terms of `new (...)`, not a replacement for it; both constructors' doc comments say so explicitly, citing the same precedent below.
- **This mirrors the reference SDKs, verified directly against them, not assumed.** Python's `a2a-sdk` keeps `BaseClient.__init__` fully public alongside its `create_client`/`ClientFactory` convenience layer (its own docstring: *"for reusing a factory... use `ClientFactory` directly instead"* — the low-level path is framed as intentional, not deprecated). Java's SDK keeps its raw `Client` constructor package-private, but only because it's reached through `ClientBuilder`, itself a complete, independently public entry point. Neither reference implementation collapses to one sole public constructor, which is why `new (...)` stays public here too rather than being hidden behind `newClient`.
- **One `binding` parameter picks the transport** (`"JSONRPC"` default, `"HTTP+JSON"`, `"GRPC"`) at construction time. Every remote function funnels through one internal dispatcher (`rpcCall`) that branches on `self.binding` and calls the matching encode/decode path — `buildRestRequest` maps each of the 11 operations onto its REST method/path/query/body shape; the gRPC path defers to `grpc_binding.bal`'s `encodeGrpcRequest`/`decodeGrpcResponse`. A caller's own code never branches on transport.
- **`resolveAgentCard` always fetches fresh**; `resolveAgentCardCached` is the newer, opt-in ETag/`304`-aware sibling — kept deliberately separate rather than replacing the original, so existing callers who always want the latest card see no behavior change.
- **`primaryUrl`/`selectInterface`** exist because v1.0 moved an agent's primary URL from a single top-level `AgentCard.url` field to `supportedInterfaces[0].url`, but plenty of real servers still send the legacy field, some send neither in the expected shape, and a card can list several interfaces. `primaryUrl` applies the correct precedence once, so nothing else in the codebase has to re-derive it. `selectInterface` now ranks candidate interfaces by `protocolVersion` (exactly `1.0` highest, then newer, then `0.x`, then unversioned lowest) rather than taking the first `supportedInterfaces` entry matching the requested binding — a card that happens to list an older interface before a newer one no longer silently picks the older protocol. Per spec §8.3.2 vs. the Python reference's `_find_best_interface`: the spec's plain-text "prefer earlier entries" describes choosing *which transport* among several a client supports; version-preference among several entries *of the same transport* is a finer-grained rule the spec text doesn't spell out, filled in here to match Python's actual behavior.
- **`normalizeGrpcSchemeUrl`** rewrites a `grpc://`/`grpcs://` URL to `http://`/`https://` before constructing the underlying `http:Client`/`grpc:Client` — cosmetic-looking, but without it a caller who copies a `grpc://` URL straight from an `AgentInterface` gets a confusing low-level connection error instead of just working.

## Error handling — `errors.bal` (285 lines)

One `distinct error<A2AErrorDetail>` base type (`A2AError`), ten `distinct` subtypes below it (one per spec error code, plus internal ones for auth-resolution/signature-verification failures) — adding a new spec error later is a one-line addition here, nothing else changes. Three separate mapping functions, one per transport, because **the three transports don't carry equivalent error information**:

- `toA2AError` — JSON-RPC's numeric code (`-32001`…`-32009`) maps 1:1.
- `toA2AErrorFromRest` — REST's HTTP status alone can't disambiguate (seven different A2A errors can all return `400`), so it reads a `google.rpc.ErrorInfo.reason` string out of the error body's `details` array instead, falling back to status-code-only heuristics if that's absent.
- `toA2AErrorFromGrpc` — coarsest of the three: `ballerina/grpc:1.14.7` exposes only gRPC status *codes*, no status details/trailing metadata, so five different A2A errors that all map to `FAILED_PRECONDITION` genuinely cannot be told apart here. Documented as a known, real limitation rather than worked around with something unreliable (matching on status-message text was considered and explicitly rejected).

## Streaming — `sse.bal` (234 lines)

`A2AStreamGenerator` decodes each SSE event's JSON-RPC (or bare REST) envelope into a `StreamResponse`, closing the stream itself once a terminal task state is reached (a `TaskArtifactUpdateEvent` never closes it; `INPUT_REQUIRED`/`AUTH_REQUIRED` don't either — spec §8.1). `ReconnectingStreamGenerator` wraps that with opt-in auto-reconnect (`maxReconnectAttempts`) — worth knowing: it deliberately calls a *raw* internal resubscribe helper rather than the public `subscribeToTask`, because going through the public method would wrap each reconnect attempt in a *brand-new* `ReconnectingStreamGenerator` with a fresh attempt budget, silently defeating the whole point of a retry limit against a persistently-failing agent.

## Legacy dialect support — `compat_v03.bal` (693 lines)

The single largest source file's worth of translation: v0.3 used lowercase, slash-separated JSON-RPC method names (`message/send` vs. v1.0's `SendMessage`), lowercase enum values, and unwrapped responses instead of v1.0's `{"task": {...}}` wrapping. `detectProtocolModeForBinding` reads the resolved `AgentCard`'s `protocolVersion` (per-interface if present, legacy top-level field as fallback) to decide which dialect a given server speaks — once, at `Client` construction — and every remote method then transparently encodes/decodes through the right dialect with zero caller-visible branching. This is the layer that made testing against `adk_currency_agent` and `langgraph` (both genuinely v0.3 under the hood) possible without two separate client implementations.

## gRPC — `grpc_binding.bal` (1100 lines) + `grpc_stream.bal` (50 lines)

`grpc_binding.bal` is a pure conversion layer between the *generated* protobuf stub types (`grpcstub:*` — snake_case fields, closed records, protobuf's map-as-key/value-array shape, `google.protobuf.Timestamp` as a Ballerina `time:Utc` tuple) and this library's own `types.bal` domain types — structurally incompatible enough that no amount of `cloneWithType` bridges the gap, so every field gets an explicit `encodeGrpc*`/`decodeGrpc*` function. `grpc_stream.bal`'s `GrpcStreamAdapter` is `sse.bal`'s per-element analogue for gRPC streams — simpler at the stream layer (no envelope, no mid-stream error frame to special-case) but needs the full decode machinery above for every element.

## Automatic security wiring — `auth.bal` (148 lines) + `signature.bal` (170 lines)

- **`auth.bal`**'s `buildAuthFromCard` turns a parsed `AgentCard`'s `securityRequirements` into a working `http:ClientConfiguration.auth`/header map automatically — but *only* for `ApiKeySecurityScheme`/`HttpAuthSecurityScheme`, the two scheme types that reduce to "one credential string the caller already has." OAuth2/OpenID Connect need a token-acquisition flow and mutual TLS needs a client certificate; neither reduces to a string, so both stay caller-wired by design, documented in the file's own module comment as a real scope boundary, not an oversight.
- **`signature.bal`**'s `verifyAgentCardSignature` does real RFC 7515 JWS verification (RS256/ES256, fail-closed — a tampered card is never falsely accepted) with one honest, documented limitation: it doesn't perform RFC 8785 JSON Canonicalization (JCS) before computing the signing input, so it only reliably verifies signatures computed over this library's own JSON serialization, not a real external signer's. The doc comment explains why this wasn't attempted anyway: JCS done *partially or incorrectly* would silently produce wrong verification results — judged worse than the current, clearly-documented gap.

## The two submodules — and why they're submodules at all

Both `modules/transport/` (JSON-RPC envelope types) and `modules/grpcstub/` (generated gRPC stub) exist as separate submodules for **module-boundary reasons specific to Ballerina**, documented in `LEARNING_LOG.md`'s very first entry:

- `modules/transport/jsonrpc.bal` must not import the root `a2a` module, because the root module already imports `a2a.transport` — Ballerina forbids cyclic module dependencies, and this bit the project once already (undetected for a while because `client.bal` was still an empty stub when the cycle was first introduced). Anything that needs to *construct* root `a2a` types (error mapping, SSE decoding) lives in the root module instead (`errors.bal`, `sse.bal`), even though conceptually it's "transport code."
- `modules/grpcstub/` is separate because the *generated* type names collide with `types.bal`'s own domain type names (both have a `Task`, a `Message`, etc.) — putting them in the same module wouldn't compile.

`modules/grpcstub/a2a_pb.bal` (1405 lines) is machine-generated by `bal grpc` from `proto/a2a.proto` and should never be hand-edited beyond two narrow, scripted rewrites. The regeneration story is fully documented in `proto/PROVENANCE.md`: the vendored `.proto` is upstream's `a2aproject/A2A` spec file with only HTTP-transcoding/documentation annotations stripped (four specific things, enumerated exactly), and the generated stub needs two post-processing patches applied by `scripts/regen-grpc-stub.sh` — one because `bal grpc` has no mapping for `google.protobuf.Value` at all, one because the tool never resolves `Struct`'s nested dependency, causing a real runtime failure (`fileDescriptor is null`) without the fix. The script **fails loudly with a diff** if regenerating would produce anything different from what's checked in, rather than silently drifting — you have to consciously pass `--apply` to accept a change. `modules/grpcstub/wellknown_desc.bal` is the one hand-maintained exception, holding a protobuf well-known-type descriptor the generator can't produce; it tracks protobuf's own well-known types, not the A2A spec, so it doesn't need touching when the spec moves.

## Tooling metadata

- **`Ballerina.toml`** pins `ballerina/http` to `2.14.13` with an unusually long, precise comment explaining exactly why: `ballerina/grpc:1.14.7` bundles its own native logging jar built against that specific `http` version, and a newer `http` (confirmed with `2.16.6`) causes a `java.lang.IllegalAccessError` at gRPC listener startup — a real upstream ABI-coupling bug, cross-referenced to `ballerina-platform/ballerina-library#2496`. This is the same root cause `a2a-interop-tests` independently rediscovered and had to work around this session, in its own `Dependencies.toml`.
- **`CLAUDE.md`** — the internal AI-agent guardrail file (this repo's counterpart to `a2a-interop-tests`' own): states Phase 1's client-only scope explicitly ("Server-side (Listener) is Phase 2 — do not implement it yet") and points to the design doc as the actual source of truth.
- **`main.bal`** is the unmodified 5-line `bal new` scaffold stub (`io:println("Hello, World!")`) — dead weight, never used since this package is a library, not an executable. Harmless but worth knowing it's not meaningful code.

## Tests — `tests/` (359 passing, 0 failing)

One file per production concern (`client_test.bal`, `errors_test.bal`, `sse_test.bal`, `types_test.bal`, `auth_test.bal`, `signature_test.bal`, `compat_v03_test.bal`, four `grpc_*_test.bal` files, `equivalence_test.bal`), all mock-based and deterministic — `testutil.bal` and `grpcmock_service.bal`/`grpcmock_scripting.bal` provide the scripted mock A2A servers every test drives. `equivalence_test.bal` specifically asserts that JSON-RPC and gRPC produce equivalent results for the same logical call — a direct cross-transport consistency check, not just "does each transport work in isolation." This suite is this repo's own CI gate; real-server proof (that the mocks aren't just validating the library's own misreadings of the spec) lives entirely in the companion `a2a-interop-tests` repo, deliberately kept separate.

## Documentation — `docs/`

- **`A2A_Technical_Design.md`** — the living design doc: scope, data model rationale, every client method's design (with the exact wire mapping), the transport layer, error-code mapping, and §12's "known gaps" — treat this section as a snapshot to re-verify against source, not gospel; parts of it (a stale note about `securitySchemes` being untyped, for instance) still describe an earlier state the actual code has since moved past.
- **`docs/archive/`** — one file, the original listener/service draft that used to be appended to the bottom of the main design doc; moved out once superseded, so a new reader skimming the main doc top-to-bottom can't accidentally copy dead patterns from it.
- **`docs/superpowers/{specs,plans}/`** — one spec+plan pair per feature that's actually been built: v0.3 compat, remaining operations, security-scheme typing, REST transport binding, gRPC transport binding, plus a client-hardening plan covering extensions/JWS/caching/reconnect/auth-wiring together. This is the real paper trail for *why* something is shaped the way it is.

---

**Bottom line**: this is a client-only library, deliberately and explicitly (checked in three separate places — `CLAUDE.md`, the design doc's §1.2, and `README.md`'s Roadmap section), with all 11 spec operations working over all three transport bindings and both wire dialects, backed by 359 passing unit tests plus real-server proof in the companion repo. The two genuinely open items (mTLS auto-wiring, JWS's JCS canonicalization) are both documented, deliberate scope boundaries with a stated reason, not unfinished work someone forgot about.

---

## Appendix: which real agents prove which features (from `a2a-interop-tests`)

This library's own 359 tests are mock-based, by design — they gate every
change fast and deterministically, but only prove the code does what *this
library* thinks the spec says. Real proof that it works against
independently-built servers lives entirely in the companion
`a2a-interop-tests` repo. Reproduced here for one-stop reference (source of
truth: that repo's `CLIENT_TEST_COVERAGE.md`, keep this copy in sync with
it, not the other way around):

| Agent | Language / framework | Port | Protocol version | Transport(s) advertised (`supportedInterfaces`/`preferredTransport`) | `capabilities` | LLM backend | What only this agent proves |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `helloworld` | Python (`a2a-samples`) | `9999` | **v1.0** (native) | `JSONRPC` only | `streaming: true`, `extendedAgentCard: true`, `pushNotifications: false` | none (no LLM call at all) | The client's home-turf dialect, fastest sanity check; the only agent here with `getExtendedAgentCard` genuinely wired to a distinct card, not just declared |
| `adk_currency_agent` | Python / Google ADK | `10999` | **v0.3** (legacy card shape — top-level `protocolVersion`, no `supportedInterfaces` array at all) | `JSONRPC` (`preferredTransport` only; v0.3 cards predate `supportedInterfaces`) | `streaming: true`, `pushNotifications: false` | Claude (`AnthropicLlm`) by default in this repo, Gemini also supported | A **second, independently-built** v0.3 implementation (different framework than `langgraph`) — proves the client's v0.3 auto-detection/translation isn't accidentally tuned to one specific agent's quirks |
| `langgraph` currency agent | Python / LangGraph | `10000` | **v0.3** | `JSONRPC` (`preferredTransport` only) | `streaming: true`, `pushNotifications: true` | Claude only, in this repo | The richest agent here: processes tasks slowly enough (real multi-second Claude + tool call) to genuinely exercise **in-flight** `cancelTask`/`subscribeToTask` — every other agent is already terminal by the time the client sees it — plus genuine `INPUT_REQUIRED` multi-turn and real push-notification config CRUD |
| `dice_agent` | Java / Quarkus (`a2a-java-sdk` 1.1.0.Final) | `11000` | **v1.0**, on all three interfaces | `GRPC`, `JSONRPC`, **and** `HTTP+JSON` — the only agent here whose card genuinely lists all three | `streaming: true`, `pushNotifications: false`, `extendedAgentCard: false` | Claude only (LangChain4j `quarkus-langchain4j-anthropic`) | The **only** agent that can test the REST and gRPC transport bindings at all — every other agent here is JSON-RPC-only, so this closes what was otherwise a mock-only gap in *this* library. See `a2a-interop-tests`' `servers/dice_agent/findings.md` for the SDK migration this needed to get a spec-correct card in the first place |

Every agent runs on the same single `ANTHROPIC_API_KEY` where an LLM is
involved at all (`helloworld` needs no credentials) — one key covers the
entire matrix.
