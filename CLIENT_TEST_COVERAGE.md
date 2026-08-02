# Client functionality & test coverage

A checklist of every operation `ballerina/a2a`'s `Client` exposes, mapped to
the A2A protocol specification (https://a2a-protocol.org/latest/specification/),
with what's actually been exercised against real reference servers and what
hasn't. Update this file whenever a new operation is added to the client or
a new interop test is written — it's the answer to "have we tested this
yet?" so it shouldn't need re-deriving from scratch each time.

Reference servers used: `helloworld` (v1.0, no credentials) on `:9999`,
`adk_currency_agent` (v0.3) on `:10999`, `langgraph` currency agent (v0.3)
on `:10000`, `dice_agent` (v1.0, Java/Quarkus, REST+gRPC+JSON-RPC) on
`:11000`. `adk_currency_agent` runs on Gemini by default but has also
been verified running on Claude (`google.adk.models.anthropic_llm.AnthropicLlm`)
— see DEMO_GUIDE.md §3's "Optional: run `adk_currency_agent` on Claude
instead of Gemini" for the 3-line swap (plus a real ADK bug it uncovered
and worked around: tool functions must return `{"result": ...}`, not a bare
dict, or Claude silently gets an empty tool result). The `langgraph` and
`dice_agent` agents run **only** on Claude in this repo
(`langchain_anthropic.ChatAnthropic` and `quarkus-langchain4j-anthropic`
respectively) — see `servers/langgraph_agent/setup.md` and
`servers/dice_agent/setup.md` for the local patches each needed. Every
backend exercises the identical A2A surface — the client only speaks A2A
protocol to the agent's endpoint, so which LLM answers behind it is
invisible to every row below. Setup and run instructions:
[`DEMO_GUIDE.md`](DEMO_GUIDE.md).

## Checklist

| # | Spec operation | Client method(s) | Tested against | Automated test? | Status |
| :- | :-- | :-- | :-- | :-- | :-- |
| 1 | Agent discovery | `resolveAgentCard`, `primaryUrl` | helloworld | via `demo/main.bal` only | ✅ verified — card fields and `capabilities` flags read correctly |
| 2 | Send Message (sync) | `sendMessage` | helloworld, adk_currency_agent (v0.3) | `interop_test.bal::testInteropSendMessage`, `currency_agent_interop_test.bal::testCurrencyAgentSendMessage` | ✅ passing |
| 3 | Send Streaming Message (SSE) | `sendMessageStream` | helloworld, adk_currency_agent (v0.3) | `interop_test.bal::testInteropSendMessageStream`, `currency_agent_interop_test.bal::testCurrencyAgentSendMessageStream` | ✅ passing — full event sequence: task created (`SUBMITTED`) → `WORKING` status → artifact update → `COMPLETED` status → clean stream close |
| 4 | Get Task | `getTask` | helloworld | `interop_test.bal::testInteropGetTask` | ✅ passing |
| 5 | List Tasks | `listTasks` | helloworld | none checked in — ad hoc probe only | ✅ verified manually (returned 38 tasks, no error); **no permanent automated test exists yet** |
| 6 | Cancel Task | `cancelTask` | helloworld (terminal-task path), langgraph agent (**genuine in-flight**) | `interop_test.bal::testInteropCancelTaskOnTerminalTask`, `langgraph_agent_interop_test.bal::testLangGraphAgentGenuineInFlightCancel` | ✅ passing on both. helloworld: terminal task → correctly maps to `TaskNotCancelableError`. langgraph agent: a real still-running task (genuine Claude+tool latency) is cancelled mid-flight, and the cancellation is confirmed durable via a follow-up `getTask` — not just the cancel response. Closing this required two real bugs to be fixed in the sample agent — see `servers/langgraph_agent/findings.md` §3 |
| 7 | Subscribe to Task / resubscribe | `subscribeToTask` | helloworld (terminal-task path), langgraph agent (**genuine in-flight**) | `interop_test.bal::testInteropSubscribeToTaskOnTerminalTask`, `langgraph_agent_interop_test.bal::testLangGraphAgentGenuineInFlightSubscribe` | ✅ passing on both. helloworld: terminal task → non-SSE 200 JSON-RPC error (`-32602`) maps to `A2AInternalError` — a known, already-reported mismatch against design-doc §6.5 (expected `UnsupportedOperationError`). langgraph agent: reconnecting to a genuinely still-running task delivers a real live `TASK_STATE_WORKING` status update, not an error |
| 8 | Create/Get/List/Delete Push Notification Config | `createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`, `listTaskPushNotificationConfigs`, `deleteTaskPushNotificationConfig` | helloworld (capability absent), langgraph agent (**genuine success path**) | `langgraph_agent_interop_test.bal::testLangGraphAgentPushNotificationConfigCrud` | ⚠️ mostly passing — helloworld correctly short-circuits client-side with `PushNotificationNotSupportedError` (`capabilities.pushNotifications: false`). Against the langgraph agent (v0.3, `capabilities.pushNotifications: true`, real store wired): create/get/list all pass — the first genuine success-path verification in this repo, closing the v0.3 field-name assumption previously flagged in `REPO_MAP.md` §6. **Delete fails** — not a client bug: the agent's `a2a-sdk==0.3.0` returns a JSON-RPC response with neither `result` nor `error`, which `Client` correctly rejects as `InvalidAgentResponseError`. See `servers/langgraph_agent/findings.md` §5 |
| 9 | Get (Authenticated) Extended Agent Card | `getExtendedAgentCard` | helloworld | `interop_test.bal::testInteropGetExtendedAgentCard` | ✅ passing — confirmed genuinely implemented, not just declared (`capabilities.extendedAgentCard: true`); returns a distinct card named "Hello World Agent - Extended Edition" |
| 10 | Artifacts | (returned as part of #2–#3, #5) | helloworld, langgraph agent | covered by the tests above | ✅ verified — correct text-part content in both the sync `Task.artifacts[0]` and the streaming `TaskArtifactUpdateEvent` |
| 11 | Task lifecycle / states | (observed across #2–#3, #6-7) | helloworld, langgraph agent | covered by the tests above | ✅ verified states: `SUBMITTED` → `WORKING` → `COMPLETED` (helloworld, langgraph agent), `CANCELED` (langgraph agent, genuine), `INPUT_REQUIRED` (langgraph agent, genuine — see #13). `FAILED`, `REJECTED`, `AUTH_REQUIRED` remain unexercised |
| 12 | Protocol v0.3 auto-detection & translation | all of the above, transparently, when `Client` is constructed with `agentCard` | adk_currency_agent (both Gemini- and Claude-backed), langgraph agent (Claude-backed) | `currency_agent_interop_test.bal` (2 tests), `langgraph_agent_interop_test.bal` (5 tests) | ✅ passing on all three — real LLM call + live rate lookup, same client code as v1.0, no caller-visible branching |
| 13 | `INPUT_REQUIRED` state + multi-turn continuation via `taskId`/`contextId` | `sendMessage` (follow-up carrying the same `taskId`/`contextId`) | langgraph agent | `langgraph_agent_interop_test.bal::testLangGraphAgentInputRequiredThenMultiTurn`, plus `demo/main.bal`'s interactive loop (live-typed, not automated) | ✅ passing — genuinely model-driven: an incomplete request ("Convert 100 USD", no target currency) gets a real clarifying question, and a follow-up message continuing the same task with just the missing info correctly completes the *same* task (confirmed by matching `task.id`). Also confirmed interactively: typing "Convert 100 dollars" then "to euros" in `demo/main.bal` correctly resumes the same conversation |
| 14 | Transport bindings — REST (HTTP+JSON) and gRPC, not just JSON-RPC (spec §5) | `Client.init(..., binding = "HTTP+JSON"\|"GRPC")`, `sendMessage`, `sendMessageStream` | dice_agent (the only reference server here that genuinely advertises all three in `supportedInterfaces`) | `dice_agent_interop_test.bal::testDiceAgentSendMessageJsonRpc/Rest/StreamGrpc` | ✅ passing on all three — same message, same client, three different wire protocols, real Claude responses on each. Getting here required 5 real fixes (an `a2a-java-sdk` version migration for a spec-correct agent card, two protobuf version pins, a `ballerina/http`/`ballerina/grpc` version skew, and an HTTP/2-vs-h2c negotiation fix) — full story in `servers/dice_agent/findings.md` |

## What the client can do that has zero test coverage (real or mock-adjacent)

Closed since the last pass (kept here as a record, not because they're
still open): **genuine in-flight cancel/resubscribe**, **push-notification
config success path**, and **multi-turn `contextId` continuation +
`INPUT_REQUIRED`** — all closed by the `langgraph` currency agent (see
`servers/langgraph_agent/findings.md`). **REST and gRPC transport
bindings** — closed by `dice_agent` (see `servers/dice_agent/findings.md`
and row 14 above). Still genuinely open:

- **`listTasks` filtering/pagination** — only the no-filter call path was
  tried. `ListTasksFilter`'s `contextId`, `status`, `pageSize`, `pageToken`,
  `historyLength`, `statusTimestampAfter`, `includeArtifacts` fields are
  all untested against a real server.
- **`deleteTaskPushNotificationConfig`'s actual success path** — blocked by
  the `a2a-sdk==0.3.0` non-conformance in #8 above, not by anything on the
  client side. Would need either a fixed/different v0.3 server, or a v1.0
  server that supports push notifications (none in this repo do currently
  — `helloworld` doesn't declare the capability).
- **`tenant` parameter** on any remote call — no reference server here uses
  multi-tenant `AgentInterface` entries, so this is only covered by
  `a2a-ballerina`'s own mock-based unit tests, not here.
- **Non-text `Part` variants** (`file`, `data`) in either direction — every
  reference agent here only ever exchanges plain text.
- **Message-level `referenceTaskIds`/`extensions`, `Artifact.extensions`** —
  present in the type model, never sent or received by any agent here.

## How to re-run everything in this table

```bash
# from repo root -- --sticky is required now that grpc is a transitive
# dependency (ballerina/http must stay pinned; see Ballerina.toml)
A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --sticky --groups interop
A2A_CURRENCY_AGENT_URL=http://localhost:10999 bal test --sticky --groups interop
A2A_LANGGRAPH_AGENT_URL=http://localhost:10000 bal test --sticky --groups interop
A2A_DICE_AGENT_URL=http://localhost:11000 bal test --sticky --groups interop

# or all four at once, in one cmd window, once all four servers are running:
set A2A_TEST_SERVER_URL=http://127.0.0.1:9999
set A2A_CURRENCY_AGENT_URL=http://localhost:10999
set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
set A2A_DICE_AGENT_URL=http://localhost:11000
bal test --sticky --groups interop

# interactive discovery + sendMessage + sendMessageStream + multi-turn walkthrough
cd demo && bal run --sticky

# same request over gRPC, JSON-RPC, and REST against dice_agent
cd demo_tri_transport && bal run --sticky
```

Full setup steps: [`DEMO_GUIDE.md`](DEMO_GUIDE.md) and
[`END_TO_END_RUNBOOK.md`](END_TO_END_RUNBOOK.md) (a from-scratch,
zero-context walkthrough). Real captured evidence from the latest full run:
[`VERIFICATION_EVIDENCE.md`](VERIFICATION_EVIDENCE.md).
