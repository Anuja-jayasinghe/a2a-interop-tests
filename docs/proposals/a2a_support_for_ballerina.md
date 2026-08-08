# A2A Support for Ballerina — Client

- Author: Anuja Jayasinghe
- Reviewers: TBD
- Created: 2026-08-05
- Updated: 2026-08-06
- Issue: TBD
- Status: Implemented — `newClient` landed in `a2a-ballerina/a2a/client.bal`
  as proposed below, plus the `selectInterface` protocolVersion-ranking fix
  this doc's construction section describes. `new (serviceUrl, ...)` was kept
  fully public rather than deprecated, per a check against the A2A spec
  (silent on constructor API design) and both reference SDKs — Python's
  `a2a-sdk` keeps `BaseClient.__init__` public alongside `create_client`;
  Java's `ClientBuilder` is a complete public entry point in its own right.
  Neither collapses to one sole public constructor, so this SDK doesn't
  either.

## Summary

This proposal introduces full A2A protocol support for Ballerina, delivered in
two phases: a **client**, proposed here, and a **listener** (server side), to
follow in a separate proposal once the client foundation lands. `ballerina/a2a`
is a complete client implementation of the
[Agent2Agent (A2A) protocol](https://a2a-protocol.org), an open protocol that
lets independent AI agents discover each other's capabilities and exchange
tasks and messages over a common wire format. It lets any Ballerina service or
program act as an A2A client — discovering an agent, negotiating protocol
version and transport, and driving the full client-side operation set defined
by the spec, over JSON-RPC, REST (HTTP+JSON), or gRPC.

## Goals

- A single `Client` type that talks to any spec-compliant A2A agent,
  regardless of transport binding or protocol version (1.0, with a 0.3
  compatibility mode).
- Agent discovery via Agent Cards — fetching, caching, and verifying them —
  used to drive protocol/auth negotiation.
- Full coverage of the client-side operations defined by A2A 9.4: message
  send/stream, task lifecycle (get/cancel/list/subscribe), push-notification
  configuration, and extended card retrieval.
- Resilient streaming: Server-Sent Events with automatic reconnection on a
  dropped (non-terminal) stream.
- Lay the groundwork for a Ballerina service to also *host* an A2A agent —
  the client's types and error taxonomy are designed to be reused, not
  redesigned, by the listener proposal that follows this one.


## Motivation

Agent-to-agent interoperability is an emerging need for Ballerina's
integration-first audience: a Ballerina service is often the natural place to
call out to an external agent (or expose one, once the listener side exists).
No A2A client existed for Ballerina. Hand-rolling JSON-RPC/REST/gRPC calls
against the spec per project is repetitive and error-prone — particularly
around agent card parsing, protocol-version detection, and the small but real
differences between the 1.0 and 0.3 versions of the protocol. A single
idiomatic client, following the same shape as Ballerina's other generated and
hand-written clients (`http:Client`-style construction, `remote function`
calls), removes that repetition.

## Architecture Overview

### Transports

The A2A spec allows a server to expose JSON-RPC, REST, or gRPC bindings for
the same operation set. `Client` supports all three under one API — the
binding is chosen at construction (`binding = "JSONRPC" | "HTTP+JSON" |
"GRPC"`) and every `remote function` call dispatches internally:

```ballerina
if self.binding == "HTTP+JSON" { return self.restCall(method, params); }
if self.binding == "GRPC"      { return self.grpcCall(method, params); }
// else JSON-RPC
```

Streaming operations mirror this through a shared SSE/gRPC-stream event
generator.

### Agent Card resolution

```ballerina
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error;
```

`resolveAgentCard(url, ...)` fetches and parses `/.well-known/agent-card.json`.
Per spec §14.3, this well-known endpoint is public and unauthenticated by
design — `headers` above exists for signature/proxy use, not credentials.
Authentication only applies to the separate, authenticated extended card
(§3.1.11 `getExtendedAgentCard`, listed under Supported Operations below).
`resolveAgentCardCached(url, ..., previous)` adds ETag-aware conditional GET.
`verifyAgentCardSignature` checks a card's embedded JWS signature (RS256/ES256)
before it's trusted. Parsing also normalises legacy (pre-1.0) card shapes —
synthesising `supportedInterfaces` from the older `url` /
`preferredTransport` / `additionalInterfaces` fields — so an agent that only
declares a transport that way is still reachable. The resolved card drives
protocol-version detection (1.0 vs. 0.3) and, when credentials are supplied,
authentication.

### Client construction

Which of the two a caller has in hand — a URL or an already-resolved card —
varies by situation, so construction accepts either as a union, not just the
card:

```ballerina
public isolated function newClient(AgentCard|string agent, ...) returns Client|error;
```

```ballerina
// caller already resolved the card (e.g. for display, or reused across clients)
a2a:AgentCard card = check a2a:resolveAgentCard(url);
a2a:Client agentClient = check a2a:newClient(card);

// caller only has the URL — newClient resolves the card itself
a2a:Client agentClient = check a2a:newClient(url);
```

Either way, only one of URL or card is ever passed once — never both. When a
card is passed, its service URL is derived internally rather than re-supplied
by the caller; when a URL is passed, `newClient` resolves the card once and
proceeds identically from there.

The URL is derived via the interface `selectInterface(card, binding)` picks.
Selection prefers `protocolVersion 1.0`, then newer, then `0.3`+, then
unversioned — not just the first entry that matches the requested binding, so
the ordering of a card's `supportedInterfaces` can't silently downgrade the
protocol version used. If the selected interface declares a `tenant`, it's
read automatically instead of requiring the caller to copy it by hand; an
explicitly-passed `tenant` still wins.

The existing positional constructor, `new (serviceUrl, ..., agentCard = card)`,
remains available — not as a deprecated escape hatch superseded by
`newClient`, but as a fully supported, independently public low-level path
in its own right, for cases where the client genuinely needs to point at a
different URL than the one the card declares (proxies, tests, or a card with
several interfaces where a non-preferred one is wanted deliberately), or
where the caller has already resolved every argument itself and has no need
for `newClient`'s derivation logic at all. `newClient` is implemented in
terms of this constructor, not a replacement for it.

This two-entry-point shape was checked against the A2A spec and both
reference SDKs before settling on it, specifically to answer whether a
factory calling into an existing raw constructor is genuine layering or just
a patch on top of a gap-ridden API:

- **The A2A spec** (`specification.md` §8.2/§8.3) is silent on constructor/
  factory API design — that's implementation-defined — but its §8.3.2 client
  protocol-selection algorithm (parse `supportedInterfaces`, select a
  supported transport, prefer earlier entries, use that entry's URL) is
  exactly what `primaryUrl`/`selectInterface` already implement, confirming
  card→URL derivation as correct default behavior.
- **Python's `a2a-sdk`** keeps `BaseClient.__init__` — the raw,
  fully-resolved constructor — fully public alongside `ClientFactory.create`/
  `create_from_url` and the `create_client(agent: str | AgentCard, ...)`
  convenience function `newClient` mirrors almost exactly. Its own docstring
  frames the low-level path as intentional, not discouraged: *"For reusing a
  factory across multiple agents or registering custom transports, use
  `ClientFactory` directly instead."*
- **Java's SDK** makes the raw `Client` constructor package-private, but only
  because it's reached through `ClientBuilder` — itself a complete,
  independently public entry point (`Client.builder(card).withTransport(...)
  .build()`). Java's builder always requires an already-resolved `AgentCard`
  and has no bare-URL convenience or URL-override concept at all; resolving a
  card from a URL is a wholly separate public step (`A2A.getAgentCard(url)`).

Neither reference SDK collapses to a single sole public constructor, so
`ballerina/a2a` doesn't either — `new (...)` stays public.

## Design 

- **One params shape, three bindings.** Every operation builds a
  `map<json>` params value; JSON-RPC sends it as-is, REST translates it
  through path templates and query encoding, gRPC encodes it into generated
  stub messages. This keeps the three bindings provably equivalent without a
  transport abstraction layer.
- **Protocol version is a client-construction concern, not a per-call one.**
  The card (or an explicit override) fixes the client into 1.0 or 0.3 mode
  once; a compatibility layer translates method names and payload shapes for
  0.3 without duplicating the public API.
- **Auth resolved once, from the card.** If credentials are supplied,
  `Client` resolves them against the card's declared security schemes
  (API key, HTTP Basic/Bearer) at construction time and fails fast if they
  can't be satisfied, rather than failing on the first request.
- **A typed error taxonomy, independent of binding.** All three transports
  map their native errors (JSON-RPC codes, REST `ErrorInfo`, gRPC status) onto
  the same set of `A2AError` subtypes, so calling code doesn't need to know
  which binding it's talking over to handle failures.

## Supported Operations

| Category | Operations |
|---|---|
| Messaging | `sendMessage` (unary), `sendStreamingMessage` (SSE/gRPC stream) |
| Task lifecycle | `getTask`, `cancelTask`, `listTasks`, `subscribeToTask` |
| Push notification config | `createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`, `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig` |
| Discovery | `getExtendedAgentCard` |

All eleven map onto the same method names and return shapes regardless of the
chosen transport binding.

## Example Usage (Main Function)

```ballerina
import ballerina/a2a;
import ballerina/io;

public function main() returns error? {
    string url = "https://weather-agent.example.com";

    // newClient accepts either a URL or an already-resolved AgentCard —
    // pass whichever you have; only one is ever needed.
    a2a:Client agentClient = check a2a:newClient(url);

    // equivalent, if the card was already resolved for some other reason:
    // a2a:AgentCard card = check a2a:resolveAgentCard(url);
    // a2a:Client agentClient = check a2a:newClient(card);

    a2a:Message request = {
        role: "user",
        parts: [{text: "What's the forecast for Colombo tomorrow?"}]
    };

    a2a:Task|a2a:Message response = check agentClient->sendMessage(request);
    io:println(response);
}
```

## Conclusion

This proposal introduces the client half of A2A protocol support for
Ballerina, covering all client-side spec operations across three transport
bindings with a single, idiomatic API that constructs from either a URL or an
already-resolved card. It establishes the types, transports, and error model
a subsequent listener proposal will build on to complete A2A support for
Ballerina.
