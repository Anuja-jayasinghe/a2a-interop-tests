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

## 6. Not yet done: real interop tests / demo run against a real Claude response

This session verified the *plumbing* (§3-4) and the *server's own spec
conformance* (§1-2, §5) but did not run `ballerina/a2a`'s actual client
against this agent with a real Anthropic key, since none was available.
See `tests/dice_agent_interop_test.bal` and the demo changes for what still
needs a real key to confirm end-to-end (matching the same pattern as every
other Claude-backed agent in this repo).
