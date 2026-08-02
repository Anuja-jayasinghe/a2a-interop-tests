# FINDINGS

Master index of agents tested so far. One line per agent, linking to its
full writeup.

| Agent | Language | Findings |
| :---- | :---- | :---- |
| helloworld | Python (`a2a-samples/samples/python/agents/helloworld`) | [servers/helloworld/findings.md](servers/helloworld/findings.md) — AgentCard.url omitted, PascalCase JSON-RPC methods, wrapped SendMessage response, subscribeToTask's two-fold non-conformance on terminal tasks |
| adk_currency_agent | Python/ADK (`a2a-samples/samples/python/agents/adk_currency_agent`) | [servers/adk_currency_agent/findings.md](servers/adk_currency_agent/findings.md) — genuinely speaks A2A protocol v0.3, not v1.0: legacy method names, unwrapped responses, lowercase enums. Motivated `ballerina/a2a`'s v0.3 client-compatibility work |
| langgraph currency agent | Python/LangGraph, on Claude (`a2a-samples/samples/python/agents/langgraph`) | [servers/langgraph_agent/findings.md](servers/langgraph_agent/findings.md) — first agent to genuinely exercise in-flight `cancelTask`/`subscribeToTask` and real push-notification CRUD (create/get/list); surfaced a real `a2a-sdk==0.3.0` JSON-RPC non-conformance on delete, plus three local bugs (Claude prefill incompatibility, a stale Frankfurter endpoint, and a blocking-event-loop cancellation bug) fixed in the sample itself |
| dice_agent | Java/Quarkus, on Claude via LangChain4j (`a2a-samples/samples/java/agents/dice_agent_multi_transport`) | [servers/dice_agent/findings.md](servers/dice_agent/findings.md) — the only reference agent that genuinely serves REST (HTTP+JSON) and gRPC, not just JSON-RPC; needed an `a2a-java-sdk` 0.3.2.Final→1.1.0.Final migration to get a spec-correct `supportedInterfaces` card field at all; all three transports verified end-to-end up to a real (placeholder-key) Anthropic 401; a `ballerina/http`/`ballerina/grpc` version skew currently blocks running this repo's own tests live |

## REST (HTTP+JSON) transport binding — coverage gap, now in progress

`ballerina/a2a` added a REST/HTTP+JSON transport binding
(`feature/rest-transport-binding`, see that repo's
`docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md` and
`docs/superpowers/plans/2026-07-31-rest-transport-binding.md`). None of
`helloworld`, `adk_currency_agent`, or `langgraph` advertise an `HTTP+JSON`
entry in `supportedInterfaces` — see below for how `dice_agent` closes this.

## gRPC transport binding — coverage gap, now in progress

`ballerina/a2a` added a gRPC transport binding (see that repo's
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md` and
`docs/superpowers/plans/2026-08-01-grpc-transport-binding.md`). Same
situation as the REST binding gap above, with one exception: the mandatory
`Part.data` wire round-trip test (Task 3 of the implementation plan) does
exercise the real protobuf codec against a Ballerina-hosted mock service,
just not a third-party reference server.

**Status**: `servers/dice_agent/` (Java/Quarkus, on Claude) is the first
reference agent in this repo whose `supportedInterfaces` genuinely lists
`GRPC` and `HTTP+JSON`, not just `JSONRPC` — see
[`servers/dice_agent/findings.md`](servers/dice_agent/findings.md) for the
full story. All three transports were verified end-to-end directly
(gRPC via the sample's own Java `TestClient`, REST and JSON-RPC via raw
`curl`) up to a genuine `401` from a placeholder Anthropic key — confirming
the request/task-creation pipeline is correct on every transport. Not yet
closed for real: `ballerina/a2a`'s own `Client` against this agent, via
`tests/dice_agent_interop_test.bal` — those tests are written and
type-check correctly against the gRPC-enabled client API, but a
`ballerina/http`/`ballerina/grpc` version skew currently blocks running
`bal test` at all in this repo's environment (`servers/dice_agent/findings.md`
§6), and no real `ANTHROPIC_API_KEY` was available this session to confirm
an actual successful (non-401) response on any transport. Two things a mock
genuinely cannot settle and a real server can, per the gRPC design spec,
also remain open: whether A2A servers populate `google.rpc.ErrorInfo` in
their gRPC status details, and whether `A2A-Version`/`A2A-Extensions` are
honoured as gRPC metadata by real implementations.
