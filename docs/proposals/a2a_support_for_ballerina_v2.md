# A2A Support for Ballerina — Client (Alternative: Transport-Specific Clients)

- Author: Anuja Jayasinghe
- Reviewers: TBD
- Created: 2026-08-10
- Updated: 2026-08-10
- Issue: TBD
- Status: Draft — alternative architecture, for side-by-side comparison
  against [`a2a_support_for_ballerina.md`](./a2a_support_for_ballerina.md).
  Not implemented.
- Relationship to the other proposal: everything here is identical to
  the sibling proposal **except** the Client architecture (Architecture
  Overview → Transports, and the Client section under Design). The
  constructor-merge decision (`newClient` folded into `init`) is shared
  by both proposals unchanged — it isn't part of what's being compared
  here. This doc exists to weigh one specific architectural question:
  one `Client` type with internal per-call transport branching (the
  sibling proposal, matching what's currently implemented) versus
  separate types per transport binding (this doc). Whichever is chosen,
  the losing variant is dropped before this lands.
- Naming note: `JsonRpcClient`/`RestClient`/`GrpcClient` and `AgentClient`
  below are placeholders, not final — naming wasn't settled as of this
  draft.

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

- A common, auto-detecting entry point that talks to any spec-compliant
  A2A agent regardless of transport binding or protocol version (1.0,
  with a 0.3 compatibility mode) — and, for callers who want it, direct
  access to a binding-specific client without going through auto-detection.
  A shared interface type keeps binding-agnostic code possible either way.
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
the same operation set. Rather than one `Client` type with a `binding`
field and an `if self.binding == ...` branch inside every `remote
function` (the sibling proposal's approach), this design gives each
binding its own concrete client type — `JsonRpcClient`, `RestClient`,
`GrpcClient` — plus a common `Client` that picks one automatically:

```ballerina
public type AgentClient isolated client object {
    isolated remote function sendMessage(Message message, ...) returns Task|Message|error;
    isolated remote function sendStreamingMessage(Message message, ...) returns stream<StreamResponse, error?>|error;
    isolated remote function getTask(string taskId, ...) returns Task|error;
    // ...remainder of the operation set, same as the sibling proposal's Client
    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error;
};
```

`JsonRpcClient`, `RestClient`, and `GrpcClient` each implement
`AgentClient` — each is a complete, independent client for exactly one
binding, with no internal branching on a `binding` field, since which
class you instantiated already says which transport it speaks. The
common `Client` also implements `AgentClient`, so code written against
the interface type works identically whether it holds the auto-detecting
common client or a binding-specific one directly.

**How the common `Client` picks one:** it resolves the Agent Card from
whatever it's given (fetches if a URL, uses it directly if already a
card — see Agent Card resolution and Client construction below), reads
the card's preferred transport binding, and constructs the matching
concrete client, handing it the already-resolved card so it isn't
fetched twice. `Client` then holds that concrete instance as a private
field and every one of its own remote functions is a one-line delegate
call to it — construction-time selection, not per-call branching.

**Skipping the common client:** a caller who already knows which
binding they want can construct `JsonRpcClient`/`RestClient`/`GrpcClient`
directly, bypassing `Client` and its auto-detection entirely:

```ballerina
a2a:GrpcClient agentClient = check new (url);
```

Because there's no common client upstream to have resolved anything for
it in this path, each concrete client type is independently capable of
resolving an Agent Card itself — reading its capabilities, protocol
version (1.0 vs. 0.3), security schemes, and tenant — to finish
constructing itself correctly, exactly as the common client's delegate
would have. Whether a concrete client's card came from `Client` or from
resolving it itself, the rest of construction proceeds identically.

Streaming operations mirror this: each concrete client implements its
own SSE/gRPC-stream event generator; `Client` delegates streaming calls
to its chosen concrete instance the same way as unary ones.

**What's still shared internally.** The sibling proposal's Design pillar
("one `map<json>` params shape, three bindings, no transport abstraction
layer") doesn't survive unchanged here — three public client types *is*
a transport abstraction at the API surface. But the per-binding request/
response marshaling logic (building a JSON-RPC envelope, REST path
templating, gRPC stub encoding) doesn't need tripling: each concrete
client can still call the same internal helper functions the sibling
proposal's `rpcCall`/`restCall`/`grpcCall` already are. Only the public
class boundary multiplies from one to four; the marshaling code itself
can stay a shared internal implementation detail.

### Agent Card resolution

```ballerina
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error;
```

`resolveAgentCard(url, ...)` fetches and parses `/.well-known/agent-card.json`.
Per spec 14.3, this well-known endpoint is public and unauthenticated by
design — `headers` above exists for signature/proxy use, not credentials.
Authentication only applies to the separate, authenticated extended card
(3.1.11 `getExtendedAgentCard`, listed under Supported Operations below).
`resolveAgentCardCached(url, ..., previous)` adds ETag-aware conditional GET.

> Signature verification is a separate, explicit step — `resolveAgentCard`
> does not call it automatically, since not every card is signed and the
> caller must supply the verifying key out-of-band:
>
> ```ballerina
> public isolated function verifyAgentCardSignature(
>         AgentCard card,
>         crypto:PublicKey publicKey,
>         int signatureIndex = 0) returns boolean|SignatureVerificationError|UnsupportedSignatureAlgorithmError;
> ```
>
> ```ballerina
> a2a:AgentCard card = check a2a:resolveAgentCard(url);
> boolean|error valid = a2a:verifyAgentCardSignature(card, publicKey);
> ```
>
> The spec mandates the *procedure* here, not a named API: 8.4.3 states
> clients verifying Agent Card signatures **MUST** follow its six-step
> canonicalize-and-verify sequence, and **SHOULD** verify at least one
> signature before trusting a card — but it stops there, and neither
> reference SDK (Python `a2a-sdk`, Java) ships an equivalent helper;
> callers are left to hand-roll it. `verifyAgentCardSignature` is
> `ballerina/a2a` implementing that MUST-behavior as a convenience function
> the reference SDKs don't provide, not a spec-defined method being wrapped.
>
> `verifyAgentCardSignature` checks the card's embedded JWS signature
> (RS256/ES256) against the given key, returning `false` — not an error — for
> a mismatched or tampered signature; only a malformed JWS or an unsupported
> algorithm returns an error. Parsing also normalises legacy (pre-1.0) card shapes —
> synthesising `supportedInterfaces` from the older `url` /
> `preferredTransport` / `additionalInterfaces` fields — so an agent that only
> declares a transport that way is still reachable. The resolved card drives
> protocol-version detection (1.0 vs. 0.3) and, when credentials are supplied,
> authentication.

### Client construction

A caller may have either a URL or an already-resolved card in hand,
depending on the situation, so construction accepts either as a union,
directly in the constructor — there is no separate factory function.
This part is identical to the sibling proposal and is shared by all four
client types; the only difference between them is that the three
concrete clients don't take a `binding` parameter, since which one you
instantiated already says which transport it speaks:

```ballerina
// a2a:Client (common, auto-detecting)
public isolated function init(
        AgentCard|string agent,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        map<string> credentials = {},
        int maxReconnectAttempts = 0,
        TransportBinding binding = "JSONRPC") returns error?;

// a2a:JsonRpcClient / a2a:RestClient / a2a:GrpcClient — identical, minus binding
public isolated function init(
        AgentCard|string agent,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        string[] requestedExtensions = [],
        map<string> credentials = {},
        int maxReconnectAttempts = 0) returns error?;
```

```ballerina
// via the common client — auto-detects the binding from the card
a2a:AgentCard card = check a2a:resolveAgentCard(url);
a2a:Client agentClient = check new (card);
a2a:Client agentClient = check new (url);

// direct construction — skips auto-detection entirely
a2a:GrpcClient agentClient = check new (url);
```

Either way, only one of URL or card is ever passed once — never both. When a
card is passed, its service URL is derived internally rather than
re-supplied by the caller. When a URL is passed, the constructor **always**
resolves the card first — a plain `new (url)` never skips straight to a
fetch-free construction, since the card is what the constructor needs to
detect protocol version, derive the URL, and resolve auth. This holds for
all four types: the common client resolves once and hands the result to
whichever concrete client it constructs; a directly-constructed concrete
client resolves it itself, since there's no common client upstream to
have done it already.

Ballerina object constructors can already accept a union type and branch
on it internally, so `newClient` never needed to exist as a separate
function purely to accept `AgentCard|string` — that part of the earlier
design was achievable in `init` directly. An earlier version of this
proposal kept `newClient` and the raw constructor as two separate public
entry points, citing spec silence on constructor design and both
reference SDKs (Python's `a2a-sdk`, Java's `ClientBuilder`) keeping a
low-level constructor public alongside a convenience factory. That
precedent is real, but nothing built on this client has shipped
externally yet, so the extra API surface it bought — a second public
entry point, and the "is this genuine layering or just a patch on a
gap-ridden API" question that came with it — is not worth carrying
forward for a v1. This drops one thing the raw constructor's `agentCard`
parameter allowed — pointing the client at a URL other than the one the
card declares (proxies, tests, a deliberately non-preferred interface).
That's a deliberate scope decision, not an oversight: the URL a client
dials should come from what the Agent Card declares and nowhere else,
since resolving (and optionally verifying) the card exists to establish
where it's safe to send requests and credentials in the first place — an
unchecked override parameter reintroduces exactly the redirection
surface that resolving the card was meant to close off, for no
spec-required or reference-SDK-precedented reason (neither Python's
`a2a-sdk` nor Java's SDK exposes an equivalent). This applies identically
to all four client types — the common `Client` and the three concrete
ones. Whether to add a narrower, deliberately-scoped override later is a
separate decision — it isn't a breaking change to add on top of this —
but it needs its own justification and sign-off, not a default inclusion
because it seemed convenient. Until then, code needing to point at a URL
other than a card's own declared interfaces (including this library's
own tests) constructs an `AgentCard` whose declared interfaces already
point where it needs to go, rather than the constructor accepting an
override.

The URL is derived via the matching interface:

```ballerina
public isolated function selectInterface(
        AgentCard card,
        TransportBinding preferredBinding = "JSONRPC") returns AgentInterface|error;
```

`selectInterface` returns the best-ranked `supportedInterfaces` entry for the
requested binding — preferring the highest protocol version declared, not
just the first matching entry — so the ordering of a card's
`supportedInterfaces` can't silently downgrade the protocol version used; it
errors if no entry matches the binding. If the selected interface declares a
`tenant`, it's read automatically instead of requiring the caller to copy it
by hand; an explicitly-passed `tenant` still wins. This matches the A2A
spec's own client protocol-selection algorithm (8.3.2: parse
`supportedInterfaces`, select a supported transport, prefer earlier
entries, use that entry's URL) — the spec itself is silent on
constructor/factory API design, so that part is this proposal's own call.

## Design 

- **One type per binding, one shared interface.** `JsonRpcClient`,
  `RestClient`, and `GrpcClient` each own their transport's request/response
  marshaling with no internal `binding` branch; `AgentClient` is the
  interface all four types (including the common `Client`) implement, so
  code that doesn't care which binding it's talking over can still be
  written against one type. The per-binding marshaling itself can still be
  shared internal helper functions, same as today — only the public class
  boundary multiplies, not the marshaling logic.
- **Binding selection is a one-time, construction-time decision, made by
  whichever client gets constructed.** The common `Client` makes it by
  reading the card's preferred transport; a directly-constructed concrete
  client makes it implicitly, by virtue of being the type it is. Either
  way there's no per-call dispatch left to do.
- **Protocol version is a client-construction concern, not a per-call one.**
  The card (or an explicit override) fixes the client into 1.0 or 0.3 mode
  once; a compatibility layer translates method names and payload shapes for
  0.3 without duplicating the public API. This is unchanged from the
  sibling proposal and applies identically to all four types.
- **Auth resolved once, from the card.** If credentials are supplied, the
  constructing client resolves them against the card's declared security
  schemes (API key, HTTP Basic/Bearer) at construction time and fails fast
  if they can't be satisfied, rather than failing on the first request.
- **A typed error taxonomy, independent of binding.** All three transports
  map their native errors (JSON-RPC codes, REST `ErrorInfo`, gRPC status) onto
  the same set of `A2AError` subtypes, so calling code doesn't need to know
  which binding it's talking over — or which of the four client types it
  holds — to handle failures.

### Public Types

Every spec-facing type is an **open** record (`json...;` rest field), so a
newer protocol revision adding fields doesn't break parsing of existing
ones.

**Messaging and task types:**

```ballerina
public enum Role {
    ROLE_UNSPECIFIED,
    ROLE_USER,
    ROLE_AGENT
}

// Exactly one of text/raw/url/data is set (variant by field presence, no
// discriminator — v1.0 dropped the old `kind` tag).
public type Part record {|
    string? text?;
    byte[]? raw?;             // inline file bytes; base64 on the wire
    string? url?;             // file by reference
    json? data?;               // arbitrary structured data
    string? filename?;         // applies to file variants (raw/url)
    string? mediaType?;        // MIME type; applies to all variants
    map<json>? metadata?;
    json...;
|};

public type Message record {|
    string messageId;          // required; caller generates a UUID
    Role role;                 // ROLE_USER for outbound messages
    Part[] parts;
    string? contextId?;        // groups related tasks and messages
    string? taskId?;           // set when continuing an existing task
    string[] referenceTaskIds = [];
    string[] extensions = [];
    map<json>? metadata?;
    json...;
|};

public enum TaskState {
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_SUBMITTED,
    TASK_STATE_WORKING,
    TASK_STATE_COMPLETED,       // terminal
    TASK_STATE_FAILED,          // terminal
    TASK_STATE_CANCELED,        // terminal
    TASK_STATE_REJECTED,        // terminal
    TASK_STATE_INPUT_REQUIRED,  // interrupted — resumable via follow-up message
    TASK_STATE_AUTH_REQUIRED    // interrupted — resumable via follow-up message
}

public type TaskStatus record {|
    TaskState state;
    Message? message?;         // rich, not a plain string
    string? timestamp?;        // ISO 8601
    json...;
|};

public type Artifact record {|
    string artifactId;         // unique within the task; the identifier
    string? name?;
    string? description?;
    Part[] parts;               // must contain at least one part
    map<json>? metadata?;
    string[] extensions = [];
    json...;
|};

public type Task record {|
    string id;                  // server-generated; clients never create this
    string? contextId?;
    TaskStatus status;
    Message[] history = [];
    Artifact[] artifacts = [];
    map<json>? metadata?;
    json...;
|};

// Delivered over a stream on a lifecycle transition.
public type TaskStatusUpdateEvent record {|
    string taskId;
    string contextId;
    TaskStatus status;
    map<json>? metadata?;
    json...;
|};

// Delivered over a stream; supports chunked delivery via append/lastChunk.
public type TaskArtifactUpdateEvent record {|
    string taskId;
    string contextId;
    Artifact artifact;
    boolean append = false;
    boolean lastChunk = false;
    map<json>? metadata?;
    json...;
|};

// Wrapper delivered by streaming operations; exactly one field is
// non-nil per event (spec 3.2.3).
public type StreamResponse record {|
    Task? task?;
    Message? message?;
    TaskStatusUpdateEvent? statusUpdate?;
    TaskArtifactUpdateEvent? artifactUpdate?;
    json...;
|};

// Wrapper returned by a unary sendMessage call — a narrower sibling of
// StreamResponse, since a non-streaming reply can only ever be a Task or
// a Message (spec 3.1.1).
public type SendMessageResult record {|
    Task? task?;
    Message? message?;
    json...;
|};
```

**Agent Card types:**

```ballerina
public type AgentProvider record {|
    string organization;
    string url;
    string? contactEmail?;
    json...;
|};

public type AgentExtension record {|
    string uri;
    string? description?;
    boolean required = false;
    map<json>? params?;
    json...;
|};

public type AgentCapabilities record {|
    boolean streaming = false;
    boolean pushNotifications = false;
    boolean extendedAgentCard = false;
    AgentExtension[] extensions = [];
    json...;
|};

public type AgentSkill record {|
    string id;                  // unique within the agent
    string name;
    string description;
    string[] tags = [];
    string[] inputModes = [];
    string[] outputModes = [];
    string[] examples = [];
    SecurityRequirement[] securityRequirements = [];
    json...;
|};

// One transport binding an agent is reachable on.
public type AgentInterface record {|
    string url;
    string protocolBinding;     // e.g. "JSONRPC", "GRPC", "HTTP+JSON"
    string? protocolVersion?;   // if it differs from the card's default
    string? tenant?;            // must be echoed on every subsequent call
    json...;
|};

// A JWS (RFC 7515) computed over an AgentCard; verify with
// verifyAgentCardSignature.
public type AgentCardSignature record {|
    map<json>? header?;
    string protected;
    string signature;
    json...;
|};

public type AgentCard record {|
    string name;
    string description;
    string version;             // agent's own version, not the protocol version
    string? protocolVersion?;   // legacy pre-1.0 field; see primaryUrl
    string? url?;                // legacy primary URL; use primaryUrl(card)
    AgentProvider? provider?;
    string? documentationUrl?;
    string? iconUrl?;
    AgentCapabilities capabilities;
    AgentInterface[] supportedInterfaces = [];
    map<SecurityScheme> securitySchemes = {};
    SecurityRequirement[] securityRequirements = [];
    string[] defaultInputModes = ["text"];
    string[] defaultOutputModes = ["text"];
    AgentSkill[] skills;
    AgentCardSignature[] signatures = [];
    json...;
|};
```

**Security types**, per OpenAPI 3.0's Security Scheme Object:

```ballerina
public type ApiKeySecurityScheme record {|
    string? description?;
    "query"|"header"|"cookie" 'in;   // where the API key is sent
    string name;                     // the header/query/cookie parameter name
    "apiKey" 'type = "apiKey";
    json...;
|};

public type HttpAuthSecurityScheme record {|
    string? description?;
    string scheme;                   // IANA HTTP Authentication Scheme, e.g. "Bearer"
    string? bearerFormat?;           // hint, e.g. "JWT"
    "http" 'type = "http";
    json...;
|};

public type OAuth2SecurityScheme record {|
    string? description?;
    OAuthFlows flows;
    string? oauth2MetadataUrl?;      // RFC 8414 metadata URL
    "oauth2" 'type = "oauth2";
    json...;
|};

public type OpenIdConnectSecurityScheme record {|
    string? description?;
    string openIdConnectUrl;         // OIDC Discovery URL
    "openIdConnect" 'type = "openIdConnect";
    json...;
|};

public type MutualTlsSecurityScheme record {|
    string? description?;
    "mutualTLS" 'type = "mutualTLS";
    json...;
|};

// Discriminated by the `type` field's literal value.
public type SecurityScheme ApiKeySecurityScheme|HttpAuthSecurityScheme|OAuth2SecurityScheme
    |OpenIdConnectSecurityScheme|MutualTlsSecurityScheme;

// A set of scheme names that must all be satisfied together (an AND).
// AgentCard/AgentSkill express a list of these — an OR across the list.
public type SecurityRequirement map<string[]>;

public type OAuthFlows record {|
    AuthorizationCodeOAuthFlow? authorizationCode?;
    ClientCredentialsOAuthFlow? clientCredentials?;
    ImplicitOAuthFlow? implicit?;
    PasswordOAuthFlow? password?;
    json...;
|};

public type AuthorizationCodeOAuthFlow record {|
    string authorizationUrl;
    string? refreshUrl?;
    map<string> scopes;              // scope name to human-readable description
    string tokenUrl;
    json...;
|};

public type ClientCredentialsOAuthFlow record {|
    string? refreshUrl?;
    map<string> scopes;
    string tokenUrl;
    json...;
|};

public type ImplicitOAuthFlow record {|
    string authorizationUrl;
    string? refreshUrl?;
    map<string> scopes;
    json...;
|};

public type PasswordOAuthFlow record {|
    string? refreshUrl?;
    map<string> scopes;
    string tokenUrl;
    json...;
|};
```

**Request/response and push-notification types:**

```ballerina
public type SendMessageConfiguration record {|
    string[] acceptedOutputModes = ["text"];
    int? historyLength = ();         // unset = no limit; 0 = omit history entirely
    boolean returnImmediately = false;
    TaskPushNotificationConfig? taskPushNotificationConfig = ();
    json...;
|};

public type ListTasksFilter record {|
    string? contextId?;
    TaskState? status?;
    int? pageSize?;
    string? pageToken?;              // opaque cursor from a previous call
    int? historyLength?;
    string? statusTimestampAfter?;   // ISO 8601
    boolean? includeArtifacts?;
    json...;
|};

public type ListTasksResult record {|
    Task[] tasks;
    string nextPageToken;            // empty when there are no more results
    int pageSize;
    int totalSize;
    json...;
|};

// Credentials the client presents to a push-notification webhook it registers.
public type AuthenticationInfo record {|
    string scheme;                   // IANA HTTP auth scheme, e.g. "Bearer"
    string? credentials?;
    json...;
|};

// A webhook the server will POST task updates to.
public type TaskPushNotificationConfig record {|
    string url;
    string? id?;
    string? taskId?;                 // leave unset in a sendMessage request
    string? token?;                  // opaque, echoed back on each push
    AuthenticationInfo? authentication?;
    string? tenant?;                 // must match the selected AgentInterface's tenant
    json...;
|};

public type ListTaskPushNotificationConfigsResult record {|
    TaskPushNotificationConfig[] configs;
    string nextPageToken;
    json...;
|};
```

### Client

The full client-side operation set is declared once, as an interface —
`AgentClient` — that every concrete client type implements identically.
This is the same operation set the sibling proposal's single `Client`
class exposes; only where it lives has changed:

```ballerina
public type AgentClient isolated client object {

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error;

    isolated remote function sendStreamingMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns stream<StreamResponse, error?>|error;

    isolated remote function getTask(
            string taskId,
            int? historyLength = (),
            string? tenant = ()) returns Task|error;

    isolated remote function cancelTask(
            string taskId,
            map<json>? metadata = (),
            string? tenant = ()) returns Task|error;

    isolated remote function subscribeToTask(
            string taskId,
            string? tenant = ()) returns stream<StreamResponse, error?>|error;

    isolated remote function listTasks(
            ListTasksFilter? filter = (),
            string? tenant = ()) returns ListTasksResult|error;

    isolated remote function createTaskPushNotificationConfig(
            TaskPushNotificationConfig config,
            string? tenant = ()) returns TaskPushNotificationConfig|error;

    isolated remote function getTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns TaskPushNotificationConfig|error;

    isolated remote function listTaskPushNotificationConfigs(
            string taskId,
            int? pageSize = (),
            string? pageToken = (),
            string? tenant = ()) returns ListTaskPushNotificationConfigsResult|error;

    isolated remote function deleteTaskPushNotificationConfig(
            string taskId,
            string id,
            string? tenant = ()) returns error?;

    isolated remote function getExtendedAgentCard(string? tenant = ()) returns AgentCard|error;
};
```

**The common client** implements `AgentClient` by resolving the card,
picking a binding, constructing the matching concrete client, and
delegating every call to it:

```ballerina
public isolated client class Client {
    *AgentClient;

    private final AgentClient delegate;

    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            map<string> credentials = {},
            int maxReconnectAttempts = 0,
            TransportBinding binding = "JSONRPC") returns error?;
        // Resolves `agent` to an AgentCard (fetching if it's a string),
        // reads the card's preferred binding, and constructs the matching
        // JsonRpcClient/RestClient/GrpcClient with that already-resolved
        // card — no re-fetch — storing it as `self.delegate`.

    isolated remote function sendMessage(Message message, ...) returns Task|Message|error {
        return self.delegate->sendMessage(message, ...);
    }
    // ...every other AgentClient function is the same one-line delegate call.
}
```

**Each transport-specific client** implements `AgentClient` directly,
with no delegate and no `binding` parameter — the binding is fixed by
which type it is:

```ballerina
public isolated client class GrpcClient {
    *AgentClient;

    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            map<string> credentials = {},
            int maxReconnectAttempts = 0) returns error?;
        // Resolves `agent` itself if given a string (no common client
        // upstream to have done it), reads capabilities/protocol
        // version/tenant/security schemes from the resolved card, and
        // finishes constructing — same responsibility the common
        // client's delegate construction step relies on.

    isolated remote function sendMessage(Message message, ...) returns Task|Message|error {
        // gRPC-specific marshaling — may still call a shared internal
        // helper, same as the sibling proposal's grpcCall.
    }
    // ...remainder of AgentClient, implemented via this binding only.
}
```

`JsonRpcClient` and `RestClient` are structurally identical to
`GrpcClient` above — same constructor shape, same `AgentClient`
implementation — differing only in which transport's marshaling their
remote functions call internally.

Every `tenant` parameter overrides the value read automatically from the
selected `AgentInterface` (see Client construction, above) for that one
call only.

### Error Taxonomy

```ballerina
// Attached to every A2AError.
public type A2AErrorDetail record {|
    int code?;      // originating JSON-RPC code, preserved for diagnostics
    string message?;
    json data?;      // structured error details from the server
    json...;
|};

// distinct so `is A2AError` reliably matches any subtype below, and each
// subtype is in turn distinguishable from its siblings via `is`.
public type A2AError distinct error<A2AErrorDetail>;

public type TaskNotFoundError distinct A2AError;
public type TaskNotCancelableError distinct A2AError;
public type UnsupportedOperationError distinct A2AError;
public type ContentTypeNotSupportedError distinct A2AError;
public type InvalidAgentResponseError distinct A2AError;
public type VersionNotSupportedError distinct A2AError;
public type PushNotificationNotSupportedError distinct A2AError;
public type ExtendedAgentCardNotConfiguredError distinct A2AError;
public type ExtensionSupportRequiredError distinct A2AError;
public type A2AInternalError distinct A2AError;         // catch-all / unrecognized code

// Returned by the constructor/buildAuthFromCard when a card's declared
// security requirements can't be automatically resolved from the given
// credentials.
public type AuthResolutionError distinct A2AError;

// Returned by verifyAgentCardSignature for an out-of-range signatureIndex,
// or an underlying crypto verification failure.
public type SignatureVerificationError distinct A2AError;

// Returned by verifyAgentCardSignature when a signature's JWS `alg` isn't
// RS256 or ES256 — the only algorithms ballerina/crypto can verify.
public type UnsupportedSignatureAlgorithmError distinct A2AError;
```

All three transports map their native errors onto this same hierarchy:
JSON-RPC error codes map directly (`-32001` → `TaskNotFoundError`, etc.);
REST disambiguates via the `reason` field of a `google.rpc.ErrorInfo` entry
(HTTP status alone can't — seven distinct A2A errors all return 400); gRPC
maps by status code alone, since `ballerina/grpc` exposes no status details
to disambiguate further.

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

    // Common client: resolves the card, auto-detects the binding, and
    // constructs whichever concrete client matches — caller doesn't
    // need to know or care which one it got.
    a2a:AgentClient agentClient = check new a2a:Client(url);

    a2a:Message request = {
        role: "user",
        parts: [{text: "What's the forecast for Colombo tomorrow?"}]
    };

    a2a:Task|a2a:Message response = check agentClient->sendMessage(request);
    io:println(response);
}
```

```ballerina
// Skipping the common client: the caller already knows this agent only
// speaks gRPC, so there's no reason to pay for auto-detection.
a2a:GrpcClient agentClient = check new (url);
a2a:Task|a2a:Message response = check agentClient->sendMessage(request);
```

## Conclusion

This proposal introduces the client half of A2A protocol support for
Ballerina, covering all client-side spec operations across three transport
bindings — each with its own concrete client type (`JsonRpcClient`,
`RestClient`, `GrpcClient`) implementing a shared `AgentClient` interface,
plus a common `Client` that auto-detects and delegates to whichever one a
resolved Agent Card prefers. It's an alternative to the architecture in
[`a2a_support_for_ballerina.md`](./a2a_support_for_ballerina.md) — one
`Client` type with internal per-call transport branching — proposed
side-by-side so the two can be weighed against each other before either
is built. It establishes the types, transports, and error model a
subsequent listener proposal will build on to complete A2A support for
Ballerina.
