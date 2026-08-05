# Client Robustness Improvements for `ballerina/a2a`

- Authors
  - Anuja Jayasinghe
- Reviewed by
  - (none yet)
- Created date
  - 2026-08-05
- State
  - Draft

## Summary

`ballerina/a2a` is a client-only implementation of the A2A protocol. A
part-by-part comparison against the Python reference client (`a2a-sdk`)
surfaced four concrete gaps between the two: the Ballerina client requires the
caller to derive a service URL that the Agent Card already encodes, doesn't
auto-wire tenant routing from the card, picks an ambiguous interface when a
card lists more than one for the same binding, and drops legacy card fields
that a v1.0-only client needs to reach older endpoints. This proposal closes
all four gaps without changing any existing public signature.

## Goals

- Let a caller construct a `Client` directly from an already-resolved
  `AgentCard`, without manually deriving and re-passing its URL.
- Auto-wire the `tenant` routing id from the card when one isn't supplied
  explicitly.
- Make interface selection prefer the highest supported protocol version
  instead of whichever entry appears first in the card.
- Normalise legacy (pre-1.0) card shapes into `supportedInterfaces` at parse
  time, so endpoints that only exist under `additionalInterfaces` or the
  legacy `url` field become reachable.

## Motivation

`ballerina/a2a`'s `Client.init` takes `serviceUrl` as a required positional
parameter and `agentCard` as an optional hint. In practice, resolving an agent
almost always starts with fetching its card — `demo/main.bal` does exactly
this: `resolveAgentCard(url, ...)` to get the card for display, then
`primaryUrl(card, "JSONRPC")` to get the URL, then `new
(primaryUrl(card), agentCard = card)` to build the client. The card is passed
twice — once implicitly via the derived URL, once explicitly — even though
`client.bal` already exports the two functions (`selectInterface`,
`primaryUrl`) that do this derivation. What's missing is only the
composition.

The same card-in-hand-but-underused pattern shows up in tenant routing and
interface selection. `Client.init`'s doc comment states that when the selected
`AgentInterface` declares a tenant value, "that value must be supplied here"
— by the caller, by hand, even though the card the caller already has
contains it. And `selectInterface` returns the first `supportedInterfaces`
entry matching the requested binding, so a card that happens to list
`JSONRPC@0.3` before `JSONRPC@1.0` silently downgrades the client's protocol
mode based on array order, not intent.

Finally, card parsing today only rewrites the v0.3 `security` field into
`securityRequirements`. It does not synthesise `supportedInterfaces` from the
legacy `url` / `preferredTransport` / `additionalInterfaces` fields, so a v0.3
card that advertises a gRPC or REST endpoint only through
`additionalInterfaces` has that endpoint land, uninterpreted, in the parsed
card's open-record rest fields — `primaryUrl` and `selectInterface` never see
it.

None of these are wire-protocol changes. All four are client-side ergonomics
and correctness fixes, additive to the existing API surface. Larger open
designs from the same comparison — a Python-style interceptor pipeline,
per-call context (timeout/headers), and RFC 8785 JCS canonicalization for
cross-implementation signature verification — involve real API trade-offs and
are left for a separate follow-up proposal.

## Design

The changes below are grouped by the function(s) they touch. All are
additive — no existing public function signature changes, and no existing
call site needs to change to keep compiling.

### 1. Card-first client construction

Add two new module-level factory functions alongside the existing `init`,
composing `resolveAgentCard`, `selectInterface`, and `primaryUrl` — all
already public in `client.bal`:

```ballerina
# Constructs a Client directly from an already-resolved AgentCard, deriving
# the service URL via `primaryUrl(card, binding)` instead of requiring the
# caller to pass it separately.
public isolated function newClientFromCard(
        AgentCard card,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        map<string> credentials = {},
        int maxReconnectAttempts = 0,
        TransportBinding binding = "JSONRPC") returns Client|error;

# Resolves the AgentCard at `url` and delegates to `newClientFromCard`.
public isolated function newClientFromUrl(
        string url,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        map<string> credentials = {},
        int maxReconnectAttempts = 0,
        TransportBinding binding = "JSONRPC") returns Client|error;
```

`newClientFromCard` is a thin wrapper: `check primaryUrl(card, binding)` for
the URL, then delegates to the existing `init(...)` with `agentCard = card`.
`newClientFromUrl` resolves the card first, then calls `newClientFromCard`.
The existing `init(serviceUrl, ...)` constructor is unchanged and remains the
right choice whenever the caller needs to point at a URL other than the one
the card declares (proxies, testing, multi-interface cards where a specific
interface is wanted over the preferred one).

### 2. Tenant auto-wiring from the selected interface

When `agentCard` is supplied (to `init`, or transitively via
`newClientFromCard`/`newClientFromUrl`) and `tenant` is left unset, read it
off the `AgentInterface` selected by `selectInterface(card, binding)` instead
of requiring the caller to copy it manually:

```ballerina
// today: the caller must know to do this
a2a:Client c = check a2a:newClientFromCard(card, tenant = someInterface.tenant);

// proposed: read automatically when tenant is omitted
a2a:Client c = check a2a:newClientFromCard(card);
```

An explicitly-passed `tenant` always wins — this only fills in the value when
the caller hasn't set one, so it can't override an intentional per-call or
construction-time choice.

### 3. protocolVersion-preferring interface selection

Change `selectInterface(card, binding)` from "first entry matching the
binding" to a preference order over `protocolVersion`: exactly `"1.0"` first,
then any `>1.0`, then `>=0.3`, then unversioned entries — evaluated only among
entries that already match the requested `binding`:

```ballerina
// current: first match wins, order-dependent
public isolated function selectInterface(
        AgentCard card, TransportBinding binding) returns AgentInterface|error {
    foreach AgentInterface iface in card.supportedInterfaces {
        if bindingMatches(iface, binding) {
            return iface;
        }
    }
    return error("no matching interface for binding");
}

// proposed: prefer protocolVersion 1.0, then newer, then 0.3+, then unversioned
public isolated function selectInterface(
        AgentCard card, TransportBinding binding) returns AgentInterface|error {
    AgentInterface[] candidates = from AgentInterface iface in card.supportedInterfaces
                                  where bindingMatches(iface, binding)
                                  select iface;
    return pickByVersionPreference(candidates)
        ?: error("no matching interface for binding");
}
```

This removes the dependency on card-author-controlled array ordering: a card
listing `JSONRPC@0.3` before `JSONRPC@1.0` now yields the v1.0 interface,
matching what the Python reference client's `_find_best_interface` already
does.

### 4. Legacy-card normalisation on ingest

Extend `parseAgentCardBody` to synthesise `supportedInterfaces` from legacy
top-level fields when the card doesn't declare them directly, before the card
is returned to the caller:

```ballerina
// proposed addition inside parseAgentCardBody, after the existing
// renameV03SecurityField step
if card.supportedInterfaces.length() == 0 {
    card.supportedInterfaces = synthesizeInterfacesFromLegacyFields(
        legacyUrl = card.url,
        preferredTransport = card.preferredTransport,
        additionalInterfaces = card.additionalInterfaces);
}
if card.hasKey("supportsAuthenticatedExtendedCard") {
    card.capabilities.extendedAgentCard =
        <boolean>card["supportsAuthenticatedExtendedCard"];
}
```

`synthesizeInterfacesFromLegacyFields` builds one `AgentInterface` per legacy
transport declaration (the primary `url`/`preferredTransport` pair, plus one
per `additionalInterfaces` entry), stamping a `protocolVersion` of `"0.3"` on
each so downstream v0.3 compatibility handling (`compat_v03.bal`) still
applies correctly. This makes non-JSONRPC endpoints on legacy cards visible to
`selectInterface` and `primaryUrl` for the first time; it does not change
behavior for any card that already declares `supportedInterfaces` directly.

### Card-First Construction Example

Before — the demo's current double-pass:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard(url, cfg);
io:println("Connected to: ", card.name);

string baseUrl = check a2a:primaryUrl(card, "JSONRPC");
a2a:Client agentClient = check new (baseUrl, clientConfig = cfg, agentCard = card);
```

After — card-first construction, tenant and interface selection handled
automatically:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard(url, cfg);
io:println("Connected to: ", card.name);

a2a:Client agentClient = check a2a:newClientFromCard(card, clientConfig = cfg);
```

Or, when only the URL is known up front:

```ballerina
a2a:Client agentClient = check a2a:newClientFromUrl(url, clientConfig = cfg);
```
