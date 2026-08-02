# FINDINGS

Master index of agents tested so far. One line per agent, linking to its
full writeup.

| Agent | Language | Findings |
| :---- | :---- | :---- |
| helloworld | Python (`a2a-samples/samples/python/agents/helloworld`) | [servers/helloworld/findings.md](servers/helloworld/findings.md) — AgentCard.url omitted, PascalCase JSON-RPC methods, wrapped SendMessage response, subscribeToTask's two-fold non-conformance on terminal tasks |
| adk_currency_agent | Python/ADK (`a2a-samples/samples/python/agents/adk_currency_agent`) | [servers/adk_currency_agent/findings.md](servers/adk_currency_agent/findings.md) — genuinely speaks A2A protocol v0.3, not v1.0: legacy method names, unwrapped responses, lowercase enums. Motivated `ballerina/a2a`'s v0.3 client-compatibility work |
| langgraph currency agent | Python/LangGraph, on Claude (`a2a-samples/samples/python/agents/langgraph`) | [servers/langgraph_agent/findings.md](servers/langgraph_agent/findings.md) — first agent to genuinely exercise in-flight `cancelTask`/`subscribeToTask` and real push-notification CRUD (create/get/list); surfaced a real `a2a-sdk==0.3.0` JSON-RPC non-conformance on delete, plus three local bugs (Claude prefill incompatibility, a stale Frankfurter endpoint, and a blocking-event-loop cancellation bug) fixed in the sample itself |

## REST (HTTP+JSON) transport binding — known coverage gap

`ballerina/a2a` added a REST/HTTP+JSON transport binding
(`feature/rest-transport-binding`, see that repo's
`docs/superpowers/specs/2026-07-30-rest-transport-binding-design.md` and
`docs/superpowers/plans/2026-07-31-rest-transport-binding.md`). None of
the three reference agents above advertise an `HTTP+JSON` entry in
`supportedInterfaces` — `helloworld` and `langgraph` publish only a
`JSONRPC` interface, and `adk_currency_agent` predates
`supportedInterfaces` entirely (legacy v0.3 card shape, top-level `url`
only). So, like the push-notification-config delete gap recorded above
for `langgraph`, the REST binding is currently **mock-verified only** —
a strictly weaker position than the JSON-RPC binding, which has real
reference-server coverage on every operation. Closing this needs either
a REST-serving A2A agent added to this repo's server set, or one of the
existing reference implementations upgraded to publish an `HTTP+JSON`
interface.

## gRPC transport binding — known coverage gap

`ballerina/a2a` added a gRPC transport binding (see that repo's
`docs/superpowers/specs/2026-07-30-grpc-transport-binding-design.md` and
`docs/superpowers/plans/2026-08-01-grpc-transport-binding.md`). None of
the three reference agents above advertise a `GRPC` entry in
`supportedInterfaces` — same situation as the REST binding gap recorded
above. So the gRPC binding is currently **mock-verified only**, with the
one exception of the mandatory `Part.data` wire round-trip test (Task 3 of
the implementation plan), which does exercise the real protobuf codec
against a Ballerina-hosted mock service, just not a third-party reference
server. Two things a mock genuinely cannot settle and a real server can,
per the design spec: whether A2A servers populate
`google.rpc.ErrorInfo` in their gRPC status details at all (which decides
how much the binding's error-fidelity limitation actually costs in
practice), and whether `A2A-Version`/`A2A-Extensions` are honoured as gRPC
metadata by real implementations. Closing this needs either a
gRPC-serving A2A agent added to this repo's server set, or one of the
existing reference implementations upgraded to publish a `GRPC` interface.
