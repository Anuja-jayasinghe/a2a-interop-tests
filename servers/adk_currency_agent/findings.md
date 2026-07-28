# adk_currency_agent reference server — interop findings

Testing `ballerina/a2a`'s `Client` against the ADK-based currency conversion
agent (`a2a-samples/samples/python/agents/adk_currency_agent`) surfaced a
protocol-version mismatch, not merely a vendor-specific non-conformance like
`helloworld`'s: this agent genuinely only speaks A2A protocol **v0.3**,
while the client (as of this writing) only speaks **v1.0**. Verified
empirically, both via direct JSON-RPC probing and by running the real
`ballerina/a2a` client against it.

## 1. AgentCard declares protocol v0.3.0

```bash
$ curl -s http://127.0.0.1:10999/.well-known/agent-card.json
```

```json
{"capabilities":{"streaming":true},"defaultInputModes":["text","text/plain","application/json"],"defaultOutputModes":["text","text/plain","application/json"],"description":"Currency Conversion Agent","name":"Currency Conversion Agent","preferredTransport":"JSONRPC","protocolVersion":"0.3.0","provider":{"organization":"Example org","url":"http://example.com"},"skills":[{"description":"Helps with Currency conversions","examples":["Helps with currency conversions"],"id":"currency_conversion","name":"Perform Currency Conversion","tags":["currency","conversion"]}],"url":"http://localhost:10999","version":"1.0.0"}
```

Note `"protocolVersion":"0.3.0"` at the card's top level, and no
`supportedInterfaces` array at all — just the legacy top-level `url`. Per
the A2A v1.0 migration guide, `protocolVersion` moved from the card's top
level into each `AgentInterface.protocolVersion` in v1.0; a card with no
`supportedInterfaces` is the legacy (v0.3) card shape. `ballerina/a2a`'s
`primaryUrl()` already handles the missing-`supportedInterfaces` case
correctly (falls back to the legacy `url` field), so card discovery and
`resolveAgentCard` succeed without any changes.

## 2. `SendMessage` (v1.0 method name) fails

```bash
$ curl -s -X POST http://127.0.0.1:10999/ -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": "probe-1",
  "method": "SendMessage",
  "params": {
    "message": {
      "messageId": "probe-msg-1",
      "role": "ROLE_USER",
      "parts": [{"text": "Convert 100 USD to EUR"}]
    }
  }
}'
```

```json
{"error":{"code":-32601,"message":"Method not found"},"id":"probe-1","jsonrpc":"2.0"}
```

This is exactly what `ballerina/a2a`'s `Client` sends today — confirmed
below by running the actual client, not just this raw probe.

## 3. `message/send` (v0.3 method name) succeeds — full raw exchange

```bash
$ curl -s -X POST http://127.0.0.1:10999/ -H "Content-Type: application/json" -d '{
  "jsonrpc": "2.0",
  "id": "probe-2",
  "method": "message/send",
  "params": {
    "message": {
      "messageId": "probe-msg-2",
      "role": "user",
      "parts": [{"kind": "text", "text": "Convert 100 USD to EUR"}],
      "kind": "message"
    }
  }
}'
```

Full raw response (pretty-printed here; wire response is compact JSON):

```json
{
  "id": "probe-2",
  "jsonrpc": "2.0",
  "result": {
    "artifacts": [
      {
        "artifactId": "d9d3ff03-bf6c-4c68-ac46-b56a3088349c",
        "name": "conversion_result",
        "parts": [
          {"kind": "text", "text": "100 USD is equal to 87.80 EUR."}
        ]
      }
    ],
    "contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684",
    "history": [
      {
        "contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684",
        "kind": "message",
        "messageId": "probe-msg-2",
        "parts": [
          {"kind": "text", "text": "Convert 100 USD to EUR"}
        ],
        "role": "user",
        "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"
      }
    ],
    "id": "6ea25505-6764-4b29-9932-0227e2cf7e3e",
    "kind": "task",
    "status": {
      "message": {
        "contextId": "1b4188cb-0bc7-48ea-a3e6-177fa50f1684",
        "kind": "message",
        "messageId": "e754dd1e-61b7-4968-a36f-7c4ea0ec14fa",
        "parts": [
          {"kind": "text", "text": "100 USD is equal to 87.80 EUR."}
        ],
        "role": "agent",
        "taskId": "6ea25505-6764-4b29-9932-0227e2cf7e3e"
      },
      "state": "completed",
      "timestamp": "2026-07-28T03:18:13.954298+00:00"
    }
  }
}
```

Observations directly from this exchange, confirming the design doc's wire
mapping table against a real response rather than just the SDK source:

- Method name is lowercase, slash-form: `message/send`.
- The result **is** the task directly — `"kind":"task"` at the top level of
  `result`, not `{"task": {...}}`.
- `role` is plain lowercase: `"user"`, `"agent"`.
- `state` is plain lowercase: `"completed"`.
- Every `Part` carries an explicit `"kind":"text"` discriminator.
- Field names (`contextId`, `messageId`, `taskId`) are already camelCase on
  the wire, matching `ballerina/a2a`'s existing `Task`/`Message` field
  names directly — only the `role`/`state` *values* and the response
  wrapping need translation, not the field names themselves.

## 4. Confirmed via the real `ballerina/a2a` client, not just curl

Running the actual `a2a:Client` (a throwaway probe project, not part of the
tracked demo) against this server:

```
=== resolveAgentCard ===
Name: Currency Conversion Agent
Capabilities: {"streaming":true, "pushNotifications":false, "stateTransitionHistory":false, "extendedAgentCard":false, "extensions":[]}
Skills: [{"id":"currency_conversion", "name":"Perform Currency Conversion", "description":"Helps with Currency conversions", "tags":["currency", "conversion"], "inputModes":[], "outputModes":[], "examples":["Helps with currency conversions"]}]

=== sendMessage: Convert 100 USD to EUR ===
  [failed] Method not found
  [error type] typedesc a2a:A2AInternalError
```

Card discovery succeeds; `sendMessage` fails exactly as predicted, mapped to
`A2AInternalError` since `-32601` has no dedicated subtype (same
default-case pattern documented in `servers/helloworld/findings.md` for
`-32602`).

## 5. What this means for the client

See `a2a-ballerina`'s design spec,
`a2a/docs/superpowers/specs/2026-07-28-v03-client-compat-design.md`, for
the full compatibility design. Summary: `ballerina/a2a`'s `Client` is being
extended to auto-detect a server's protocol version from its `AgentCard`
and translate v0.3 wire shapes into the same `Task`/`Message`/`Role`/
`TaskState`/`StreamResponse` types it already returns for v1.0 servers —
callers write identical code either way.
