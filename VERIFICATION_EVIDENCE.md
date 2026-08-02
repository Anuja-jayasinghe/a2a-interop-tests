# Verification evidence

Real, captured proof that every row in [`CLIENT_TEST_COVERAGE.md`](CLIENT_TEST_COVERAGE.md)
actually works — not just "the test is green," but the real request/response
content that came back from real, independently-built agents (three
Python, one Java), with real Anthropic-backed responses where an LLM was
involved. Captured in one sitting, all four reference servers running
simultaneously with real credentials.

**Run timestamp**: 2026-08-02, 18:42 local. Reproduce with the commands in
each section, or see [`END_TO_END_RUNBOOK.md`](END_TO_END_RUNBOOK.md) for
how to stand up all four servers from scratch first.

## 1. Full automated suite — real credentials, all four agents running

```
A2A_TEST_SERVER_URL=http://127.0.0.1:9999
A2A_CURRENCY_AGENT_URL=http://localhost:10999
A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
A2A_DICE_AGENT_URL=http://localhost:11000
bal test --sticky --groups interop
```

```
[pass] testCurrencyAgentSendMessage
[pass] testCurrencyAgentSendMessageStream
[pass] testDiceAgentSendMessageJsonRpc
[pass] testDiceAgentSendMessageRest
[pass] testDiceAgentSendMessageStreamGrpc
[pass] testInteropCancelTaskOnTerminalTask
[pass] testInteropGetExtendedAgentCard
[pass] testInteropGetTask
[pass] testInteropSendMessage
[pass] testInteropSendMessageStream
[pass] testInteropSubscribeToTaskOnTerminalTask
[pass] testLangGraphAgentGenuineInFlightCancel
[pass] testLangGraphAgentGenuineInFlightSubscribe
[pass] testLangGraphAgentInputRequiredThenMultiTurn
[pass] testLangGraphAgentSendMessage

[fail] testLangGraphAgentPushNotificationConfigCrud:
    error {ballerina/a2a:0}InvalidAgentResponseError&{ballerina/a2a:0}A2AError
    ("JSON-RPC response contained neither result nor error")

15 passing
1 failing
0 skipped
Test execution time : 59.923s
```

The one failure is not a client defect — it's `a2a-sdk==0.3.0`'s own
response to `deleteTaskPushNotificationConfig` genuinely omitting both
`result` and `error` from its JSON-RPC response, which `ballerina/a2a`
correctly rejects rather than silently treating as success. Full wire
evidence: [`servers/langgraph_agent/findings.md`](servers/langgraph_agent/findings.md)
§5. The *create/get/list* half of the same operation family — the part
that isn't blocked by that upstream bug — is proven working with real
output in §3 below.

## 2. Real conversations — live, typed, not scripted

Captured via `demo/main.bal`'s interactive loop (`cd demo && bal run --sticky`).

**Against `langgraph` (v0.3, Claude)** — genuine multi-turn: the agent asks
a real clarifying question, then correctly resumes the same conversation:
```
> Convert 100 dollars
  [status] TASK_STATE_INPUT_REQUIRED
> to euros
  [artifact] Based on the current exchange rate, here's your conversion:
  **100 USD = 87.07 EUR**
  The exchange rate is 1 USD = 0.8707 EUR (as of July 31, 2026).
  [status] TASK_STATE_COMPLETED
```

**Against `adk_currency_agent` (v0.3, different framework — Google ADK, not
LangGraph)** — same client code, zero branching, `A2A_DEMO_SERVER_URL=http://localhost:10999`:
```
> What is the exchange rate between USD and GBP?
  [artifact] The current exchange rate is 1 USD = 0.74508 GBP (as of 2026-07-31).
  [status] TASK_STATE_COMPLETED
```

## 3. Push-notification config CRUD — real JSON, create/get/list

Captured with a throwaway client script exercising exactly the same
`ballerina/a2a` API the automated test uses, against `langgraph`:

```
Task created: dc67b319-67bf-4f40-8d9d-1c8e47e4fe05 status=TASK_STATE_COMPLETED
CREATE -> {"url":"https://example.com/webhook", "id":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05", "taskId":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05"}
GET    -> {"url":"https://example.com/webhook", "id":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05", "taskId":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05"}
LIST   -> {"configs":[{"url":"https://example.com/webhook", "id":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05", "taskId":"dc67b319-67bf-4f40-8d9d-1c8e47e4fe05"}], "nextPageToken":""}
```

Server-assigned `id`, correctly echoed back on `GET`, correctly appearing
in `LIST` — a real store, not an in-memory stub returning canned data.

## 4. Genuine in-flight cancel/subscribe — not just terminal-task rejection

`testLangGraphAgentGenuineInFlightCancel`/`GenuineInFlightSubscribe`
(§1 above, both passing) race a `cancelTask`/`subscribeToTask` call against
a task that is **provably still running** — a real multi-second Claude
call plus a real Frankfurter exchange-rate lookup, not a synchronous agent
that's already terminal by the time the client sees it (which is all
`helloworld`/`adk_currency_agent` can ever offer — see
`CLIENT_TEST_COVERAGE.md` rows 6-7). The cancel is confirmed *durable* via
a separate follow-up `getTask` call, not just trusted from the cancel
response itself. Full mechanism and the two real agent-side bugs this
surfaced and fixed: [`servers/langgraph_agent/findings.md`](servers/langgraph_agent/findings.md) §3.

## 5. Three transport bindings, one agent, one question

Captured via `demo_tri_transport/main.bal` (`cd demo_tri_transport && bal run --sticky`)
against `dice_agent`, which is the only reference server here whose
`AgentCard.supportedInterfaces` genuinely lists all three:
```
$ curl http://localhost:11000/.well-known/agent-card.json
"supportedInterfaces":[
  {"protocolBinding":"GRPC","url":"localhost:11000","protocolVersion":"1.0"},
  {"protocolBinding":"JSONRPC","url":"http://localhost:11000","protocolVersion":"1.0"},
  {"protocolBinding":"HTTP+JSON","url":"http://localhost:11000","protocolVersion":"1.0"}
]
```
```
Sending the same request to the same agent, three different technical ways:
  "Can you roll a 6-sided die?"

  [gRPC     ] -> You rolled a **3**!
  [JSON-RPC ] -> You rolled a **5**!
  [REST     ] -> You rolled a **2**!

Same client, same agent, same question -- three different wire protocols, all working.
```
Three independently-rolled dice (not cached/identical), proving each call
genuinely reached the real Claude-backed agent through a distinct wire
protocol.

## 6. Independent conformance check — not just our own tests grading our own client

`a2aproject/a2a-tck` (the official A2A Technology Compatibility Kit) run
against `dice_agent`, `agent_card` category: **6/6** — confirming the
agent's discovery document is spec-correct independent of anything
`ballerina/a2a` itself asserts. Full report and the SDK bug this run
originally caught and got fixed: [`servers/dice_agent/findings.md`](servers/dice_agent/findings.md)
§1 and §5.

## 7. Protocol dialect auto-detection — v0.3 and v1.0, same code

`adk_currency_agent` and `langgraph` both speak the legacy v0.3 wire
dialect (`protocolVersion: "0.3.0"`, lowercase JSON-RPC methods like
`message/send`, unwrapped responses); `helloworld` and `dice_agent` speak
v1.0. Every test and demo run above uses the *identical* client
construction — `check new (url, agentCard = card)` — with no branching on
which dialect is active. The client detects it from the resolved
`AgentCard` and translates transparently. Side-by-side wire evidence of
the actual dialect difference: [`servers/adk_currency_agent/findings.md`](servers/adk_currency_agent/findings.md).

## Reproducing this evidence yourself

Every command above assumes all four servers already running. See
[`END_TO_END_RUNBOOK.md`](END_TO_END_RUNBOOK.md) for the complete,
from-scratch path to get there.
