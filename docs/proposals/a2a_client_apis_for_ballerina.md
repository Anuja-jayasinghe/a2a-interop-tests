# A2A Client APIs for Ballerina

- Author: Anuja Jayasinghe
- Reviewers: TBD
- Created: 2026-08-05
- Updated: 2026-08-05
- Issue: TBD
- Status: Draft

## Summary

`ballerina/a2a` is a client library for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org),
an open protocol that lets independent AI agents discover each other's
capabilities and exchange tasks and messages over a common wire format. This
proposal introduces a Ballerina client SDK that lets any Ballerina service or
program act as an A2A client — discovering an agent, negotiating protocol
version and transport, and driving the full client-side operation set defined
by the spec, over JSON-RPC, REST (HTTP+JSON), or gRPC.

## Goals

- A single `Client` type that talks to any spec-compliant A2A agent,
  regardless of transport binding or protocol version (1.0, with a 0.3
  compatibility mode).
- Agent discovery via Agent Cards — fetching, caching, and verifying them —
  used to drive protocol/auth negotiation.
- Full coverage of the client-side operations defined by A2A §9.4: message
  send/stream, task lifecycle (get/cancel/list/subscribe), push-notification
  configuration, and extended card retrieval.
- Resilient streaming: Server-Sent Events with automatic reconnection on a
  dropped (non-terminal) stream.

## Non-Goals

- Hosting an A2A agent (the server/listener side). This proposal is
  client-only; a listener is a separate future proposal.
- A transport/interceptor plugin system, or per-call request context — noted
  under Future Plans rather than designed here.

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

`resolveAgentCard(url, ...)` fetches and parses `/.well-known/agent-card.json`;
`resolveAgentCardCached(url, ..., previous)` adds ETag-aware conditional GET.
`verifyAgentCardSignature` checks a card's embedded JWS signature (RS256/ES256)
before it's trusted. Parsing also normalises legacy (pre-1.0) card shapes —
synthesising `supportedInterfaces` from the older `url` /
`preferredTransport` / `additionalInterfaces` fields — so an agent that only
declares a transport that way is still reachable. The resolved card drives
protocol-version detection (1.0 vs. 0.3) and, when credentials are supplied,
authentication.

### Client construction

The card is the primary input; the client is built directly from it rather
than requiring the caller to separately derive and pass its URL:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard(url);
a2a:Client agentClient = check a2a:newClientFromCard(card);

// or, when only the URL is known up front:
a2a:Client agentClient = check a2a:newClientFromUrl(url);
```

`newClientFromCard`/`newClientFromUrl` derive the service URL from the card
internally, via the interface `selectInterface(card, binding)` picks. Selection
prefers `protocolVersion 1.0`, then newer, then `0.3`+, then unversioned — not
just the first entry that matches the requested binding, so the ordering of a
card's `supportedInterfaces` can't silently downgrade the protocol version
used. If the selected interface declares a `tenant`, it's read automatically
instead of requiring the caller to copy it by hand; an explicitly-passed
`tenant` still wins.

The existing positional constructor, `new (serviceUrl, ..., agentCard = card)`,
remains available as an escape hatch for the cases where the client
genuinely needs to point at a different URL than the one the card declares —
proxies, tests, or a card with several interfaces where a non-preferred one is
wanted deliberately.

## Design Strategy

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

    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    a2a:Client agentClient = check a2a:newClientFromCard(card);

    a2a:Message request = {
        role: "user",
        parts: [{text: "What's the forecast for Colombo tomorrow?"}]
    };

    a2a:Task|a2a:Message response = check agentClient->sendMessage(request);
    io:println(response);
}
```

## Future Plans

- **Interceptor pipeline** — a `before`/`after` middleware seam for auth,
  tracing, and logging, akin to `httpx`-style interceptors. Currently
  `http:ClientConfiguration` (retry, circuit breaker, timeouts, pooling)
  covers most of what this would provide.
- **Per-call request context** — per-call timeout and headers, not just
  construction-time defaults.
- **RFC 8785 JCS canonicalization** for cross-implementation signature
  verification, so a card signed by another A2A implementation can be
  verified (today, only signatures over this library's own serialization
  verify).
- **Listener/server-side support**, once client-side coverage is stable —
  letting a Ballerina service host an A2A agent, not just call one.

## Conclusion

This proposal introduces the first Ballerina client for the A2A protocol,
covering all client-side spec operations across three transport bindings with
a single, idiomatic, card-first API. It intentionally scopes out server-side
support and a small set of larger design questions (interceptors, per-call
context, cross-implementation signature verification), tracked above as
follow-up work once this client foundation lands.
