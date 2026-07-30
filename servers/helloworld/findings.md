# helloworld reference server — interop findings

Testing `ballerina/a2a`'s `Client` against the official Python A2A
reference server (`a2a-sdk`, `a2a-samples/samples/python/agents/helloworld`)
surfaced several places where the real server's wire format differs from
what an earlier reading of the A2A v1.0 spec (and the official migration
guide's own examples) suggested. This document is pulled from
`a2a-ballerina`'s `docs/A2A_Technical_Design.md` §7.3 and its git history
(commits `de94bed`, `612c66f`, `f27bfbb`, `6b594eb`) — verified against the
live server, not assumed from documentation.

## 1. `AgentCard.url` is never sent

v1.0 removed `AgentCard.url` as a required field — the primary endpoint
now lives at `supportedInterfaces[0].url`. The real reference server
confirms this isn't just a spec technicality: it never sends `url` at
all, only `supportedInterfaces`.

Client-side fix: a `primaryUrl(card)` helper (`client.bal`) that resolves
`supportedInterfaces[0].url` first, falls back to the legacy `url` field
if that's unset but present, and errors if neither is set. Callers should
use `primaryUrl(card)` rather than reading either field directly.

## 2. PascalCase JSON-RPC method names

The server only accepts PascalCase method names — `SendMessage`,
`SendStreamingMessage`, `GetTask`, `CancelTask`, `SubscribeToTask` — not
the v0.3-style `message/send`, `tasks/get`, etc. that an earlier draft of
the design doc assumed.

## 3. `SendMessage` response is wrapped

The response to a `SendMessage` call wraps its payload —
`{"task": {...}}` or `{"message": {...}}` — rather than returning a flat
`Task` or `Message`. This motivated a dedicated `SendMessageResult` type
on the client side (a narrower sibling of `StreamResponse`: a unary reply
can only ever be a `Task` or `Message`, never a status/artifact update),
rather than reusing `StreamResponse` and risking a reply's static type
carrying fields that can never actually be present.

### Example wire exchange (verified against the live server)

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "role": "ROLE_USER",
      "parts": [{"text": "What is the weather in Colombo?"}]
    },
    "configuration": {
      "acceptedOutputModes": ["text"],
      "returnImmediately": false
    },
    "tenant": "acme-corp"
  }
}
```

**Successful response:**
```json
{
  "jsonrpc": "2.0",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "result": {
    "task": {
      "id": "task-7f3a9b2c",
      "contextId": "ctx-4e8d1a6f",
      "status": {
        "state": "TASK_STATE_COMPLETED",
        "timestamp": "2026-07-20T14:32:11.412967Z"
      },
      "artifacts": [{
        "artifactId": "art-9c2e",
        "parts": [{"text": "29 degrees Celsius and partly cloudy."}]
      }]
    }
  }
}
```

**Error response:**
```json
{
  "jsonrpc": "2.0",
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "error": {
    "code": -32001,
    "message": "Task not found",
    "data": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "TASK_NOT_FOUND", "domain": "a2a-protocol.org", "metadata": {}}]
  }
}
```

## 4. `subscribeToTask`'s two-fold non-conformance on a terminal task

The spec says `subscribeToTask` against a task already in a terminal
state should return `UnsupportedOperationError`. The real server gets
this wrong in **two separate ways**:

1. **Wrong error code/type** — it returns JSON-RPC code `-32602`
   (`Invalid params`) instead of the spec-mandated code for
   `UnsupportedOperationError`. Since `-32602` has no dedicated
   `A2AError` subtype, the client maps it to `A2AInternalError` via the
   default case — **not** `UnsupportedOperationError`, despite design
   doc §6.5 claiming exactly that for a terminal-state subscribe. This is
   a distinct, already-reported doc/server mismatch, not something the
   client papers over.
2. **Wrong transport shape** — the response comes back as `HTTP 200` with
   a plain `application/json` error body (`{"error": {...}}`), not any
   SSE-framed response at all, despite `subscribeToTask` being a
   streaming operation.

Coverage limitation: this sample agent processes every task
synchronously, so there's no in-flight window to genuinely
resubscribe to a still-running task — the only reachable case against it
is subscribing to an already-terminal task, which is what's tested here.

## 5. The `openSseStream` Content-Type fix

Finding #4's transport-shape issue is the concrete evidence behind a
client-side fix: `openSseStream` (`client.bal`) now checks the response
`Content-Type` before handing it to `readSseStream`/`getSseEventStream`.
Before this fix, a non-SSE `200` caused `resp.getSseEventStream()` to
fail with a raw, untyped Ballerina error (`"invalid payload target
type..."`) instead of surfacing the underlying JSON-RPC error as a typed
`A2AError`. Now, a non-SSE `200` is parsed as a JSON-RPC error and routed
through the same `toA2AError` mapping `rpcCall` uses for unary calls.

This applies generally, not just to this one test case: a server sending
a non-streaming `200` in response to a streaming request — for any
reason, spec-conforming or not — is something a real implementation does
in practice, so the client has to handle it regardless of whose fault it
is on the wire.

## 6. The v1.0 migration guide's own examples are also wrong

Separately from the server's behavior: the official A2A v1.0 migration
guide's illustrative JSON examples for streaming events use
`taskStatusUpdate`/`taskArtifactUpdate` keys and claim an `index` field
on artifact updates. Neither matches the real server's actual wire
format, which uses `statusUpdate`/`artifactUpdate` with no `index`
field. Where the design doc and the migration guide disagree on
streaming event shape, the design doc (and this client) side with what
the live server actually sends — the guide's examples are the imprecise
ones here.

## 7. `getExtendedAgentCard` is genuinely supported, not just declared

The server's agent card declares `capabilities.extendedAgentCard: true`.
Rather than assuming that flag is accurate, `testInteropGetExtendedAgentCard`
(`tests/interop_test.bal`) calls `getExtendedAgentCard` against the live
server to check. Result: it is genuinely implemented, not just declared —
the call succeeds and returns a real, distinct `AgentCard` named
`"Hello World Agent - Extended Edition"` (as opposed to the public card's
plain `"Hello World Agent"`). Confirmed by running:

```
A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --groups interop
```

with the console output showing:

```
  [getExtendedAgentCard] supported — name: Hello World Agent - Extended Edition
```

This is the only one of the six operations added alongside this test
(`getExtendedAgentCard`, the four push-notification-config CRUD methods,
and `listTasks`) with a real reference agent to verify against; the
other five remain unverified against any live server.

## Operation-to-wire mapping (as verified)

| Client method | JSON-RPC method | HTTP | Response type |
| :---- | :---- | :---- | :---- |
| resolveAgentCard | none | GET /.well-known/agent-card.json | application/json |
| sendMessage | SendMessage | POST | application/json |
| sendMessageStream | SendStreamingMessage | POST | text/event-stream |
| getTask | GetTask | POST | application/json |
| cancelTask | CancelTask | POST | application/json |
| subscribeToTask | SubscribeToTask | POST | text/event-stream |
| getExtendedAgentCard | GetExtendedAgentCard | POST | application/json |
