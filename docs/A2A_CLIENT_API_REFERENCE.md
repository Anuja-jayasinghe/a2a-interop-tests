# `ballerina/a2a` Client API Reference

Complete list of every public discovery function and `Client` operation in
`ballerina/a2a` (`C:\gitProject\a2a-ballerina\client.bal`),
with exact signatures, wire mappings, and the constraints each operation
enforces. Companion to
[`A2A_CLIENT_LISTENER_LIFECYCLE.md`](./A2A_CLIENT_LISTENER_LIFECYCLE.md) (how
these calls behave on the wire) and
[`A2A_PROTOCOL_SCOPE_AND_BALLERINA_SDK.md`](./A2A_PROTOCOL_SCOPE_AND_BALLERINA_SDK.md)
(why the protocol is shaped this way).

---

## 1. Discovery — module-level functions, no `Client` required

| Function | Signature | Purpose |
|---|---|---|
| `resolveAgentCard` | `(string agentBaseUrl, http:ClientConfiguration clientConfig = {}, map<string> headers = {}) returns AgentCard\|error` | Fetch + parse the Agent Card. Unconditional GET every call; discards the ETag. |
| `resolveAgentCardCached` | `(string agentBaseUrl, http:ClientConfiguration clientConfig = {}, map<string> headers = {}, CachedAgentCard? previous = ()) returns CachedAgentCard\|error` | Same fetch, but ETag-aware — pass back a previously-returned `CachedAgentCard` to get a cheap `304` when nothing changed. |
| `primaryUrl` | `(AgentCard card) returns string\|error` | Resolves the correct base URL to construct a `Client` against, from `card.supportedInterfaces` (falls back to the legacy top-level `url` field, errors if neither is set). |

Both `resolveAgentCard*` functions call `GET /.well-known/agent-card.json`
with a mandatory `A2A-Version: 1.0` header, and tolerantly parse
`securitySchemes`/`securityRequirements`/`signatures`/per-skill
`securityRequirements` so one malformed field doesn't fail the whole card.

## 2. Client construction

```ballerina
public isolated function init(
        string serviceUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {},
        string? tenant = (),
        AgentCard? agentCard = (),
        string[] requestedExtensions = [],
        map<string> credentials = {},
        int maxReconnectAttempts = 0,
        TransportBinding binding = "JSONRPC") returns error?
```

| Parameter | Effect |
|---|---|
| `serviceUrl` | Base URL the client talks to. Not derived from `agentCard` automatically — pass `primaryUrl(card)` yourself if they might differ. |
| `clientConfig` | Full `http:ClientConfiguration` — auth, TLS, retry, circuit breaker, proxy, pooling. |
| `headers` | Default headers merged into every request (e.g. custom API-key header names). |
| `tenant` | Default multi-tenant routing id, used when a call doesn't override it. v1.0-only concept. |
| `agentCard` | **Only** consumed for protocol-mode detection (`V1_0`/`V0_3`) and, if `credentials` is non-empty, auth auto-wiring. Not stored on the `Client` afterward. |
| `requestedExtensions` | A2A extension URIs to request; sent as `A2A-Extensions` header on every call. |
| `credentials` | Credential strings keyed by security-scheme name from `agentCard.securitySchemes`; auto-resolved into auth config. No-op (not an error) if `agentCard` is unset. |
| `maxReconnectAttempts` | `0` (default) = manual reconnect only. `>0` = `sendStreamingMessage`/`subscribeToTask` auto-resubscribe on a dropped (non-terminal) stream, up to this many attempts. |
| `binding` | `"JSONRPC"` (default) \| `"HTTP+JSON"` \| `"GRPC"`. Rejected combos: `HTTP+JSON`/`GRPC` with a card that resolves to v0.3 (`VersionNotSupportedError`) — neither has a v0.3 wire equivalent. |

Construction never performs network I/O — it only reads `agentCard` in memory (if given) and builds an internal `http:Client`/gRPC stub.

## 3. The 11 spec operations (`§9.4`)

All are `isolated remote function`s on `Client`, called as `agentClient->methodName(...)`.

| # | Method | Signature | JSON-RPC method | REST route (`HTTP+JSON` binding) |
|---|---|---|---|---|
| 1 | `sendMessage` | `(Message message, SendMessageConfiguration? config = (), string? tenant = (), map<json>? metadata = ()) returns Task\|Message\|error` | `SendMessage` | `POST /message:send` |
| 2 | `sendStreamingMessage` | `(Message message, SendMessageConfiguration? config = (), string? tenant = (), map<json>? metadata = ()) returns stream<StreamResponse, error?>\|error` | `SendStreamingMessage` | `POST /message:stream` (SSE) |
| 3 | `getTask` | `(string taskId, int? historyLength = (), string? tenant = ()) returns Task\|error` | `GetTask` | `GET /tasks/{id}` |
| 4 | `cancelTask` | `(string taskId, map<json>? metadata = (), string? tenant = ()) returns Task\|error` | `CancelTask` | `POST /tasks/{id}:cancel` |
| 5 | `subscribeToTask` | `(string taskId, string? tenant = ()) returns stream<StreamResponse, error?>\|error` | `SubscribeToTask` | `GET /tasks/{id}:subscribe` (SSE) |
| 6 | `listTasks` | `(ListTasksFilter? filter = (), string? tenant = ()) returns ListTasksResult\|error` | `ListTasks` | `GET /tasks` |
| 7 | `createTaskPushNotificationConfig` | `(TaskPushNotificationConfig config, string? tenant = ()) returns TaskPushNotificationConfig\|error` | `CreateTaskPushNotificationConfig` | `POST /tasks/{taskId}/pushNotificationConfigs` |
| 8 | `getTaskPushNotificationConfig` | `(string taskId, string id, string? tenant = ()) returns TaskPushNotificationConfig\|error` | `GetTaskPushNotificationConfig` | `GET /tasks/{taskId}/pushNotificationConfigs/{id}` |
| 9 | `listTaskPushNotificationConfigs` | `(string taskId, int? pageSize = (), string? pageToken = (), string? tenant = ()) returns ListTaskPushNotificationConfigsResult\|error` | `ListTaskPushNotificationConfigs` | `GET /tasks/{taskId}/pushNotificationConfigs` |
| 10 | `deleteTaskPushNotificationConfig` | `(string taskId, string id, string? tenant = ()) returns error?` | `DeleteTaskPushNotificationConfig` | `DELETE /tasks/{taskId}/pushNotificationConfigs/{id}` |
| 11 | `getExtendedAgentCard` | `(string? tenant = ()) returns AgentCard\|error` | `GetExtendedAgentCard` | `GET /extendedAgentCard` |

The `GRPC` binding dispatches the same 11 operations through generated
`*Context` stub methods (protobuf wire shape) instead of JSON-RPC/REST — same
Ballerina-facing method names and return types regardless of binding.

### Per-operation constraints

| Operation | Constraint | Failure mode |
|---|---|---|
| `listTasks` | v1.0-only, no v0.3 equivalent | `VersionNotSupportedError`, thrown client-side before any request is sent |
| `sendStreamingMessage`, `subscribeToTask` | Requires `capabilities.streaming` | `UnsupportedOperationError` (server-side) |
| `createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`, `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig` | Requires `capabilities.pushNotifications` | `PushNotificationNotSupportedError` (server-side) |
| `getExtendedAgentCard` | Requires `capabilities.extendedAgentCard` | `UnsupportedOperationError` or `ExtendedAgentCardNotConfiguredError` (server-side) |
| `cancelTask` | Task must not already be terminal | `TaskNotCancelableError` (server-side) |
| `sendMessage`, `sendStreamingMessage` with a terminal `taskId` | Terminal tasks are immutable | `UnsupportedOperationError` (server-side) |
| `deleteTaskPushNotificationConfig` | None — explicitly idempotent per spec §3.1.10 | Deleting an already-deleted/nonexistent config is not an error |

Every operation accepts an optional per-call `tenant` override, falling back
to the `Client`-level default set at construction.

## 4. Error taxonomy (`errors.bal`)

`A2AError` (`distinct error<A2AErrorDetail>`) with 12 named subtypes, mapped
from the server's response regardless of binding (JSON-RPC error codes
`-32001`…`-32009`, REST `google.rpc.ErrorInfo.reason`, or gRPC status code):

`TaskNotFoundError`, `TaskNotCancelableError`, `UnsupportedOperationError`,
`ContentTypeNotSupportedError`, `InvalidAgentResponseError`,
`VersionNotSupportedError`, `PushNotificationNotSupportedError`,
`ExtendedAgentCardNotConfiguredError`, `ExtensionSupportRequiredError`,
`A2AInternalError`, `AuthResolutionError`, `SignatureVerificationError`,
`UnsupportedSignatureAlgorithmError`.

## 5. Supporting record/enum types (`types.bal`)

`Message`, `AgentCard`, `AgentCapabilities`, `AgentSkill`, `AgentInterface`,
`TaskState` (enum), `Task`, `TaskStatusUpdateEvent`,
`TaskArtifactUpdateEvent`, `StreamResponse`, `SendMessageResult`,
`SendMessageConfiguration`, `TaskPushNotificationConfig`,
`ListTasksFilter`/`ListTasksResult`,
`ListTaskPushNotificationConfigsResult`, `SecurityScheme` (5-way union),
`SecurityRequirement`, `AgentCardSignature`, `CachedAgentCard`. All records
are open (`json...;` trailing field) for forward compatibility.

## 6. Other public functions worth knowing

| Function | Purpose |
|---|---|
| `verifyAgentCardSignature` (`signature.bal`) | RFC 7515 JWS verification of a card's `signatures` field (RS256/ES256), fail-closed. Known gap: no RFC 8785 JSON Canonicalization yet, so only verifies signatures over this library's own serialization. |
| `buildAuthFromCard` (`auth.bal`) | Turns a parsed card's API-key/HTTP-auth security scheme into working `http:ClientConfiguration` — what `credentials` on `Client.init` uses internally. |
