# FINDINGS

Master index of agents tested so far. One line per agent, linking to its
full writeup.

| Agent | Language | Findings |
| :---- | :---- | :---- |
| helloworld | Python (`a2a-samples/samples/python/agents/helloworld`) | [servers/helloworld/findings.md](servers/helloworld/findings.md) — AgentCard.url omitted, PascalCase JSON-RPC methods, wrapped SendMessage response, subscribeToTask's two-fold non-conformance on terminal tasks |
| adk_currency_agent | Python/ADK (`a2a-samples/samples/python/agents/adk_currency_agent`) | [servers/adk_currency_agent/findings.md](servers/adk_currency_agent/findings.md) — genuinely speaks A2A protocol v0.3, not v1.0: legacy method names, unwrapped responses, lowercase enums. Motivated `ballerina/a2a`'s v0.3 client-compatibility work |
| langgraph currency agent | Python/LangGraph, on Claude (`a2a-samples/samples/python/agents/langgraph`) | [servers/langgraph_agent/findings.md](servers/langgraph_agent/findings.md) — first agent to genuinely exercise in-flight `cancelTask`/`subscribeToTask` and real push-notification CRUD (create/get/list); surfaced a real `a2a-sdk==0.3.0` JSON-RPC non-conformance on delete, plus three local bugs (Claude prefill incompatibility, a stale Frankfurter endpoint, and a blocking-event-loop cancellation bug) fixed in the sample itself |
| dice_agent | Java/Quarkus, on Claude via LangChain4j (`a2a-samples/samples/java/agents/dice_agent_multi_transport`) | [servers/dice_agent/findings.md](servers/dice_agent/findings.md) — the only reference agent that genuinely serves REST (HTTP+JSON) and gRPC, not just JSON-RPC; needed an `a2a-java-sdk` 0.3.2.Final→1.1.0.Final migration for a spec-correct `supportedInterfaces` field, a `protobuf-java-util` version pin, and two Ballerina-side fixes (`ballerina/http`/`ballerina/grpc` version skew, HTTP/2 vs h2c negotiation); with all of that and a real Anthropic key, all three transports **genuinely pass** with real Claude responses. Also the agent whose scheme-less GRPC interface url (`"localhost:11000"`, no `grpc://`/`http://` prefix) exposed a real `ballerina/a2a` client bug on 2026-08-13's re-verification — see §11 |

## REST (HTTP+JSON) transport binding — real-server coverage closed

`ballerina/a2a` added a REST/HTTP+JSON transport binding
(`feature/rest-transport-binding`, see that repo's
`docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md` and
`docs/superpowers/plans/2026-07-31-rest-transport-binding.md`). None of
`helloworld`, `adk_currency_agent`, or `langgraph` advertise an `HTTP+JSON`
entry in `supportedInterfaces` — `dice_agent` does, and closes this (below).

## gRPC transport binding — real-server coverage closed

`ballerina/a2a` added a gRPC transport binding (see that repo's
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md` and
`docs/superpowers/plans/2026-08-01-grpc-transport-binding.md`). Same
situation as the REST binding gap above, with one exception that predates
this round: the mandatory `Part.data` wire round-trip test (Task 3 of the
implementation plan) already exercised the real protobuf codec against a
Ballerina-hosted mock service, just not a third-party reference server.

**Status: closed.** `servers/dice_agent/` (Java/Quarkus, on Claude) is the
first reference agent in this repo whose `supportedInterfaces` genuinely
lists `GRPC` and `HTTP+JSON`, not just `JSONRPC` — see
[`servers/dice_agent/findings.md`](servers/dice_agent/findings.md) for the
full story. All three transports are verified end-to-end with a real
Anthropic key, both directly (gRPC via the sample's own Java `TestClient`,
REST and JSON-RPC via `curl`) and via `ballerina/a2a`'s own real `Client`
(`tests/dice_agent_interop_test.bal`, `bal test --sticky --groups interop`
— 3/3 passing, real dice-roll/prime-check responses, not mocked or
auth-gated). Getting there required five real fixes along the way, all
documented in `servers/dice_agent/findings.md` §1-2, §6-7, §9: an
`a2a-java-sdk` version migration for a spec-correct agent card, a
`protobuf-java`/`protobuf-java-util` version pin (twice — the second time
was a companion artifact left out of the first fix), a `ballerina/http`/
`ballerina/grpc` binary version skew in this repo's own build, and
Ballerina's default HTTP/2 client not negotiating h2c correctly against
Quarkus dev mode. Two things a mock genuinely cannot settle and a real
server can, per the gRPC design spec, remain open as follow-up items:
whether A2A servers populate `google.rpc.ErrorInfo` in their gRPC status
details, and whether `A2A-Version`/`A2A-Extensions` are honoured as gRPC
metadata by real implementations — both need a *second*, independent
gRPC-serving agent to answer generally (this one already does the former,
per `servers/dice_agent/findings.md` §9's curl evidence).
