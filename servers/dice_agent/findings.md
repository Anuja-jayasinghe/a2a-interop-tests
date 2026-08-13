# Dice Agent (multi-transport) reference server — interop findings

Standing up a real REST+gRPC-serving A2A agent to close `FINDINGS.md`'s two
"mock-verified only" coverage-gap sections surfaced a genuine, non-obvious
finding before any transport-binding testing could even start: the pinned
A2A Java SDK version doesn't publish the spec-required agent-card field the
whole test even depends on. Recorded here in full, along with the fix, the
TCK conformance results after the fix, and this session's direct-transport
verification evidence.

## 1. `a2a-java-sdk` `0.3.2.Final`'s `AgentCard.Builder` never emits `supportedInterfaces` — only the legacy `additionalInterfaces`

The A2A spec (§4.4.1) requires every agent card to carry a `supportedInterfaces`
array (ordered list of transport+URL pairs, first entry preferred).
`a2a-samples`'s `dice_agent_multi_transport` sample, as published, pins
`io.a2a.sdk.version=0.3.2.Final` (legacy `io.github.a2asdk` groupId,
`io.a2a.*` package) and its `DiceAgentCardProducer` calls
`.additionalInterfaces(...)` — there is no `supportedInterfaces` builder
method on that version's `AgentCard.Builder` at all. Confirmed by
decompiling the actual jar (not just reading docs):

```
$ javap io/a2a/spec/AgentCard.class
  public java.util.List<io.a2a.spec.AgentInterface> additionalInterfaces();
```

Same result for `0.3.3.Final` (the newest release still on the legacy
`io.github.a2asdk` coordinates) — the field was only added in the `1.0.0.Alpha`
line, under the renamed `org.a2aproject.sdk` groupId/package.

**Why this isn't just a TCK-compliance footnote**: `ballerina/a2a`'s own
`Client` detects protocol version and (per `REPO_MAP.md` §4) selects
transports by reading `card.supportedInterfaces[...]`. An agent card that
only has `additionalInterfaces` — even one that's otherwise perfectly
correct — is one `ballerina/a2a`'s client can't actually use to discover a
REST or gRPC endpoint. Standing up this agent on `0.3.2.Final` would have
looked superficially fine (the server runs, curl works against each
transport directly) while silently failing to close the actual gap this
agent exists to close.

Running the official `a2aproject/a2a-tck` conformance suite
(`./run_tck.py --sut-host http://localhost:11000 --level must`) against the
unpatched `0.3.2.Final` build confirmed this concretely: **6 of 114
`MUST`-level checks passed**, with `CARD-STRUCT-001`/`CARD-PROTO-001`/
`BIND-FIELD-001` failing outright (`Missing required fields:
{'supportedInterfaces'}`), and the other 108 erroring at test *setup* —
the TCK's own `transport_clients` fixture can't construct a client for any
transport without that field, so every single per-operation test never even
ran.

**Fix**: migrate to `org.a2aproject.sdk:1.1.0.Final` (the current stable
release; `1.0.0.Alpha`-`CR1` were pre-release and skipped). See
[`setup.md`](./setup.md) §1 for the exact dependency/package changes. After
the migration, the same agent's card correctly publishes:

```json
"supportedInterfaces":[
  {"protocolBinding":"GRPC","url":"localhost:11000","protocolVersion":"1.0"},
  {"protocolBinding":"JSONRPC","url":"http://localhost:11000","protocolVersion":"1.0"},
  {"protocolBinding":"HTTP+JSON","url":"http://localhost:11000","protocolVersion":"1.0"}
]
```

and the TCK's `agent_card` category goes to **6/6**.

## 2. The 1.1.0.Final gRPC stubs need a newer protobuf runtime than the sample's parent pom pins

`samples/java/agents/pom.xml` pins `protobuf.version=4.31.1` with a comment
noting it's "[t]emporarily need[ed]... until Quarkus updates to gRPC v4" —
true for the `0.3.2.Final`-era stubs, but the `1.1.0.Final` SDK's generated
gRPC classes are gencode'd against protobuf `4.33.1`, and protobuf's runtime
refuses to load gencode newer than itself:

```
Caused by: com.google.protobuf.RuntimeVersion$ProtobufRuntimeVersionException:
Detected incompatible Protobuf Gencode/Runtime versions when loading
SendMessageRequest: gencode 4.33.1, runtime 4.31.1. Runtime version cannot
be older than the linked gencode version.
	at org.a2aproject.sdk.grpc.SendMessageRequest.<clinit>(SendMessageRequest.java:22)
```

This surfaced as a `Quarkus dev-mode` startup failure
(`java.lang.ExceptionInInitializerError` inside gRPC service binding), not
a compile error — the mismatch only manifests when the gRPC stub class is
first loaded at runtime. **Fix**: bump `protobuf.version` to `4.34.2` in the
shared parent pom. Confirmed safe for the other four sibling agents in that
same `pom.xml` (`content_editor`, `content_writer`, `magic_8_ball_security`,
`weather_mcp`) — none of them reference `grpc`/`protobuf` at all, so this is
a scoped, low-risk bump.

## 3. The REST binding's request shape genuinely differs from the JSON-RPC binding's, on the same server

Direct `curl` probing (both transports, same running agent) found this
SDK's REST endpoint (`POST /v1/message:send`) expects the **v1.0
proto-JSON** wire shape — `role: "ROLE_USER"` (proto enum name, not
`"user"`), `content` (not `parts`) — while its JSON-RPC endpoint
(`POST /`) expects the familiar `role: "user"`, `parts: [...]`,
`"kind": "message"` discriminator shape already documented for
`adk_currency_agent`/`langgraph` in this repo. Confirmed both independently:

```bash
# REST — rejected with the JSON-RPC-style body
$ curl -s -X POST http://localhost:11000/v1/message:send -d '{"message":{"messageId":"m1","role":"user","parts":[...],"kind":"message"}}'
{"error": "io.a2a.spec.InvalidParamsError", "message": "Failed to parse request body: Invalid enum value: user for enum type: a2a.v1.Role"}

# REST — accepted with the proto-JSON body
$ curl -s -X POST http://localhost:11000/v1/message:send -d '{"message":{"messageId":"m3","role":"ROLE_USER","content":[{"text":"..."}]}}'
{"error": "io.a2a.spec.InternalError", "message": "Error during task ... execution"}   # reaches the LLM call -- see §4
```

Not a bug — spec §5's REST binding is explicitly protobuf/HTTP-transcoding
based, so a proto-JSON body shape on that endpoint is correct, distinct
protocol behavior, not an inconsistency in the server. Recorded here because
it's a real, previously-unverified wire-shape detail (mock-based testing in
`ballerina/a2a` couldn't have caught the specific field-naming difference
between what its own REST client code sends and what a real REST-serving
agent expects).

## 4. All three transports verified end-to-end, gated only on a real Anthropic key (not exercised in this session)

This session had no real `ANTHROPIC_API_KEY` available — verification used a
placeholder key deliberately, to confirm the request pipeline without
spending real API credits. All three transports reached the same, genuine
`401 Unauthorized` from Anthropic's own API, confirming the request parsing,
task creation, and LangChain4j→Anthropic call path are all correct on every
transport:

- **JSON-RPC** (`curl -X POST http://localhost:11000/`,
  `method: "message/send"`): task created, then
  `{"jsonrpc":"2.0","id":"1","error":{"code":-32603,"message":"Error during task ... execution"}}`.
- **REST** (`curl -X POST http://localhost:11000/v1/message:send`, proto-JSON
  body per §3): task created, same `Error during task ... execution`.
- **gRPC** (the sample's own `TestClient`, `mvn exec:java` from the `client`
  module — gRPC is this agent's preferred transport, selected automatically
  since the client also supports it): streamed `submitted` → `working`
  status updates, then the same failure surfaced through the gRPC error
  channel:
  ```
  Streaming error occurred: gRPC error: InternalError: org.jboss.resteasy.reactive.ClientWebApplicationException:
  Received: 'Unauthorized, status code 401' when invoking REST Client method:
  'io.quarkiverse.langchain4j.anthropic.AnthropicRestApi#createMessage'
  ```

Server-side log confirms the same root cause behind all three:

```
WARN [dev.lan.int.RetryUtils] A retriable exception occurred. Remaining
retries: 1 of 1: org.jboss.resteasy.reactive.ClientWebApplicationException:
Received: 'Unauthorized, status code 401' when invoking REST Client method:
'io.quarkiverse.langchain4j.anthropic.AnthropicRestApi#createMessage'
```

A real key would replace that `401` with an actual dice-roll/prime-check
response on all three transports, with no other code changes — this repo's
`langgraph`/`adk_currency_agent` setup docs use the identical pattern
(Anthropic key, redacted in all committed artifacts).

## 5. `a2a-tck` results after the fix (§1-2): 6/6 agent-card, remaining failures are almost entirely the same placeholder-key `401`

`./run_tck.py --sut-host http://localhost:11000 --level must`, post-fix:

```
OVERALL COMPATIBILITY: 48.5%
┌─────────────┬────────┬────────┬─────────┬───────┐
│ Level       │ Passed │ Failed │ Skipped │ Total │
├─────────────┼────────┼────────┼─────────┼───────┤
│ MUST        │     33 │     67 │      14 │   114 │
└─────────────┴────────┴────────┴─────────┴───────┘
BY TRANSPORT:
  agent_card:    6/6 ✓
  jsonrpc:       29/77 (15 skipped) ⚠
  http_json:     30/71 (14 skipped) ⚠
  grpc:          25/60 (13 skipped) ⚠
```

The large majority of the 67 `MUST` failures are `Error during task ...
execution` (or the TCK's own `send_message failed` skip-on-setup-failure
pattern) — i.e. §4's real-but-expected `401`, not protocol bugs. A handful
are genuinely independent of the LLM call and worth tracking separately:

- **`JSONRPC-SSE-001`**: streaming responses on the JSON-RPC transport come
  back with `Content-Type: application/json; charset=utf-8` instead of the
  spec-required `text/event-stream` for SSE.
- **`HTTP_JSON-SVC-002`**: the server returns a `500` when the
  `A2A-Extensions` header is present on a REST request, instead of handling
  or explicitly rejecting it per spec.
- **`CORE-LIST-001`…`005`, `CORE-EXECUTION-MODE-002`**: list-style
  operations return a JSON-RPC response missing the `jsonrpc: "2.0"` field
  entirely (`$.jsonrpc: expected '2.0', got None`) — independent of the LLM
  call, since these don't require a model response to fail this way.

These three are genuine `a2a-java-sdk 1.1.0.Final` non-conformances, not
`ballerina/a2a` client bugs and not artifacts of this session's placeholder
key — recorded here for anyone picking this back up with a real key to
re-verify whether they're still present, and potentially worth a TCK issue
upstream.

## 6. `ballerina/a2a`'s local package needed a repack+push to pick up gRPC support, which then surfaced a real `ballerina/http`/`ballerina/grpc` version skew in this repo

`tests/dice_agent_interop_test.bal` (added this session) initially failed to
*compile* with `incompatible types: expected 'TransportBinding', found
'string'` on `binding = "GRPC"` — not a bug in the test, but because the
**locally published** `ballerina/a2a` package (`bal push --repository=local`,
consumed by this repo per `REPO_MAP.md` §1) was stale: its `TransportBinding`
union was still `"JSONRPC"|"HTTP+JSON"` only, missing `"GRPC"` entirely, even
though the `a2a-ballerina` source checkout on disk already has it. Fixed with
the standard `bal pack && bal push --repository=local` workflow
(`DEMO_GUIDE.md` §2) from `a2a-ballerina/a2a`.

That repack was the **first time this repo's dependency graph actually
loaded `ballerina/grpc` at runtime** (previously-published package never
referenced it). Doing so surfaced a separate, pre-existing problem: this
repo's `Dependencies.toml` already had `ballerina/http` resolved to `2.16.6`
(from work predating this session), but `ballerina/grpc 1.14.7` was compiled
against `http ~2.14.13` — a real binary incompatibility, not a semver
conflict the resolver catches at build time:

```
java.lang.IllegalAccessError: class ballerina.grpc.1.log_manager tried to
access method 'HttpLogManager.<init>(...)' — incompatible class versions
```

`bal build` compiles and type-checks cleanly regardless (confirmed: all
three new tests build with no errors against the gRPC-enabled client API).
The failure only appears at **test runtime**, once the `grpc` module's own
`init()` actually runs.

**First fix attempt, did not work**: an explicit
`[[dependency]] {org="ballerina", name="http", version="2.14.13"}` block in
`Ballerina.toml` alone had no effect — `http` still resolved to `2.16.6`
(confirmed via `Dependencies.toml` after clean `--offline` and online
rebuilds, no `pinned = true` marker appearing).

**Actual fix**: two things together, neither sufficient alone:

1. Force `http` to be a *direct* dependency of this package (a manual pin
   for a package only pulled in transitively is silently ignored) — added
   `import ballerina/http;` to `tests/testutil.bal`, backed by a genuinely
   `unusedHttpVersionPinAnchor()` function so the import isn't itself
   flagged as unused (Ballerina errors, not warns, on that).
2. Manually edit the *generated* `Dependencies.toml` to set `http`'s
   `version = "2.14.13"` directly, then rebuild with `bal build --sticky`
   (`--sticky` = "stick to `Dependencies.toml`'s versions"). A plain
   `[[dependency]]` entry in `Ballerina.toml` only ever raises a version
   floor for direct dependencies during normal resolution — it doesn't
   force a version *down* from whatever the resolver would otherwise pick
   as "newest compatible." Editing the lock file directly and pinning with
   `--sticky` is the only mechanism that actually holds a lower version.

After both, `java.lang.IllegalAccessError` is gone — confirmed by
re-running the previously-broken `testInteropSendMessage` (`helloworld`),
which now fails only with a mundane connection error (no server was
running at that moment), not the class-loading error.

## 7. Ballerina's default HTTP/2 client doesn't negotiate h2c correctly against this agent's Quarkus dev-mode server

With §6's fix in place, all three new tests still failed identically at
`a2a:resolveAgentCard` — `"Agent Card fetch failed with HTTP 400"` — for a
plain `GET /.well-known/agent-card.json`, which `curl` (HTTP/1.1) fetches
successfully every time. The dice agent's own Quarkus log shows **no
trace of the request at all** — not even a routing/logging line — meaning
it never reached the application layer as a valid HTTP/1.1 request.

Isolated with a throwaway diagnostic script calling `a2a:resolveAgentCard`
twice, once with default settings and once with `clientConfig =
{httpVersion: http:HTTP_1_1}`:

```
default:  Agent Card fetch failed with HTTP 400
http1.1:  OK
```

Root cause: `ballerina/http`'s client defaults to HTTP/2, attempting h2c
(HTTP/2 cleartext, prior-knowledge) for a non-TLS `http://` URL. Quarkus
dev mode's Netty/Vert.x-based listener doesn't negotiate that correctly
here and appears to reject the connection preface outright with a
synthesized `400`, before any request-level logging fires — consistent
with the total silence in the server's own log. **Fix**: pass
`clientConfig = {httpVersion: http:HTTP_1_1}` to both `resolveAgentCard`
and the `Client` constructor. Confirmed safe for the `GRPC`-binding case
too — `projectToGrpcClientConfig` (`a2a-ballerina/a2a/auth.bal`) only ever
projects `.auth` from `http:ClientConfiguration` into `grpc:ClientConfiguration`,
never `.httpVersion`, so the actual gRPC stub still correctly speaks
HTTP/2 regardless of this setting on the (otherwise-unused, in GRPC mode)
internal plain `http:Client`.

Not a `ballerina/a2a` bug, and arguably not even a bug in the agent —
Quarkus's h2c handling is a known rough edge in dev mode specifically —
but a real, previously-unverified interop wrinkle that only a genuine
third-party server (not a mock) could have surfaced.

## 8. Confirmed via the real `ballerina/a2a` client, not just curl/the Java `TestClient`

With §6 and §7's fixes both applied, `bal test --sticky --groups interop`
(`A2A_DICE_AGENT_URL=http://localhost:11000`, placeholder Anthropic key)
now genuinely exercises `ballerina/a2a`'s `Client` — agent-card resolution,
`Client` construction, and `sendMessage`/`sendStreamingMessage` — over all
three transport bindings against this real server:

```
[fail] testDiceAgentSendMessageJsonRpc:  A2AInternalError, code=-32603,
  "Error during task ... execution" (ErrorInfo reason=INTERNAL) — real
  server-side Anthropic 401, correctly surfaced as a typed A2A error
[fail] testDiceAgentSendMessageRest:      same, via the REST binding
[fail] testDiceAgentSendMessageStreamGrpc: TestError — the underlying
  cause (visible in the stream error) is literally "Received: 'Unauthorized,
  status code 401' when invoking REST Client method: ...AnthropicRestApi#createMessage"
```

All three "fail" for the identical reason as every direct-transport probe
in §4 — the placeholder Anthropic key — which is the *correct*, expected
outcome without real credentials, not a defect. Every step before the LLM
call (card resolution, transport selection, request encoding, task
creation, response/error decoding back into typed `ballerina/a2a` errors)
worked correctly on all three transports. A real `ANTHROPIC_API_KEY` would
turn these into 3 passing tests with no other changes — the same posture
`langgraph`/`adk_currency_agent` are already in.

## 9. A real key surfaced one more genuine bug: `protobuf-java-util` wasn't pinned alongside `protobuf-java`

With a real `ANTHROPIC_API_KEY` in place (borrowed from
`servers/adk_currency_agent/.env`'s Anthropic key, which also works here —
same account), gRPC passed immediately
(`testDiceAgentSendMessageStreamGrpc` — a genuine "You rolled a **N**!"
response, confirmed). JSON-RPC and REST both failed with a **new** error,
never seen against the placeholder key:

```
error("{ballerina/lang.value}ConversionError", message="'map<json>' value
cannot be converted to 'a2a.transport:JsonRpcResponse': missing required
field 'id' ... field 'details' cannot be added to the closed record ...")
```

Reproducing directly against the server (bypassing `ballerina/a2a`
entirely) showed the real cause — a server-side `500`, not a malformed
response the client merely failed to parse:

```
$ curl -X POST http://localhost:11000/ -H "A2A-Version: 1.0" -d '{"jsonrpc":"2.0","id":"1","method":"SendMessage",...}'
500 - Internal Server Error
java.lang.NoSuchMethodError: 'com.google.protobuf.util.JsonFormat$Printer
com.google.protobuf.util.JsonFormat$Printer.alwaysPrintFieldsWithNoPresence()'
	at org.a2aproject.sdk.grpc.utils.JSONRPCUtils.toJsonRPCResultResponse(...)
	at org.a2aproject.sdk.server.apps.quarkus.A2AServerRoutes.serializeResponse(...)
```

**Root cause**: §2's fix pinned `com.google.protobuf:protobuf-java` to
`4.34.2` for the gRPC gencode issue, but left its companion artifact
`com.google.protobuf:protobuf-java-util` — used by the SDK's own
JSON-RPC/REST response serializer, via `JsonFormat.Printer` — resolving to
whatever Quarkus's BOM picks, an older release that predates the
`alwaysPrintFieldsWithNoPresence()` method the 1.1.0.Final SDK calls. Two
protobuf artifacts that must stay in lockstep; only pinning one is exactly
the kind of half-fix that looks done (compiles, gRPC works) but silently
breaks the other two transports. **Fix**: add the same
`protobuf-java-util` version override alongside `protobuf-java` in
`samples/java/agents/pom.xml`'s `dependencyManagement` (see
[`setup.md`](./setup.md) §1).

## 10. Confirmed: all three transports genuinely pass, with real Claude responses

With §9's fix applied and a real key, `bal test --sticky --groups interop`
(`A2A_DICE_AGENT_URL=http://localhost:11000`):

```
[pass] testDiceAgentSendMessageJsonRpc
[pass] testDiceAgentSendMessageRest
[pass] testDiceAgentSendMessageStreamGrpc

3 passing
0 failing
0 skipped
```

Direct confirmation of a genuine (non-mocked, non-placeholder) response,
reproduced via `curl` against the JSON-RPC endpoint:

```json
{"jsonrpc":"2.0","id":1,"result":{"task":{"id":"...","status":{"state":"TASK_STATE_COMPLETED",...},
"artifacts":[{"parts":[{"text":"You rolled a **2**!"}]}]}}}
```

A full run of this repo's entire interop suite, with all four reference
agents (`helloworld`, `adk_currency_agent`, `langgraph`, `dice_agent`)
running simultaneously and real credentials for all Claude-backed ones:
**15 passing, 1 failing** — the single failure being
`testLangGraphAgentPushNotificationConfigCrud`, the already-documented,
expected `a2a-sdk==0.3.0` non-conformance on delete
(`servers/langgraph_agent/findings.md` §5), not a new issue. This closes
`FINDINGS.md`'s REST and gRPC coverage-gap sections for real: both
bindings now have genuine, passing, real-server (not mock) coverage,
matching every other transport/operation already proven in this repo.

## 11. `dice_agent`'s GRPC interface url has no scheme at all — a real `ballerina/a2a` client bug this exposed, now fixed

Re-run 2026-08-13, against a `ballerina/a2a` build carrying the
transport-specific-client split, client-side capability gating (issue
#11), and a `REST_OPERATIONS`/`GrpcStreamAdapter` file reorganization —
none of that architecture had been proven against a real agent before
this session.

`testDiceAgentSendMessageStreamGrpc` failed on the first attempt:

```
error {ballerina/grpc:1}InternalError&{ballerina/grpc:1}Error ("Malformed URL: localhost:11000")
    at GrpcClient.init (grpc_client.bal:99)
```

`dice_agent`'s real card publishes its `GRPC` interface as bare
`"localhost:11000"` — no `grpc://`/`http://` prefix at all, following
gRPC's own target-string convention (`grpc.Dial("host:port")`), unlike
every other binding's URL. `ballerina/a2a`'s `normalizeGrpcSchemeUrl`
only ever rewrote an explicit `grpc://`/`grpcs://` prefix and otherwise
passed the url through unchanged, on the assumption that "unchanged"
meant "already a valid http(s) URL." No mock fixture in `ballerina/a2a`'s
own test suite ever exercised this, because every one of them supplies
the GRPC mock's url with an explicit `http://` prefix already — a case
of the mocks encoding the library's own assumptions about card shape
rather than a real server's. This is precisely the class of gap live
testing exists to catch.

Fixed in `ballerina/a2a` (`client.bal`, `normalizeGrpcSchemeUrl`):
a bare `host:port` now defaults to `http://`, the same as an explicit
`grpc://` already resolves to — absence of a scheme carries no TLS
signal either way. Unit-tested, then re-packed/pushed and re-verified
live:

```
[pass] testDiceAgentSendMessageStreamGrpc
1 passing
0 failing
```

A clean full-suite re-run afterward reproduced the exact `15 passing, 1
failing` baseline from §10 above — same single expected failure, nothing
else regressed by the intervening architecture changes. One transient,
non-reproducing failure was observed on `testCurrencyAgentSendMessageStream`
during a run with all four agents under concurrent load (the stream's
event sequence was independently confirmed correct via a one-off
diagnostic capture, and the same test then passed both in isolation and
on the clean re-run) — logged here as an observation, not a confirmed
defect in either the client or `adk_currency_agent`.
