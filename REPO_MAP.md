# Repo map & full guide

A complete reference for how `ballerina/a2a` (the library) and
`a2a-interop-tests` (this repo) fit together, what's in each, and how the
client actually works after the A2A protocol v0.3 compatibility work. Start
here for orientation; [`DEMO_GUIDE.md`](DEMO_GUIDE.md) is the
run-it-yourself companion for actually setting up and demoing everything
described below.

## 1. How the repos relate

```
a2aproject/a2a-samples  (upstream, not ours — reference server implementations)
        │
        │  each agent's servers/<agent>/setup.md here has the real,
        │  verified instructions for standing one up from a checkout
        ▼
┌────────────────────────┐
│  a2a-ballerina          │   the library: a Ballerina client
│  (the library)          │   implementation of the A2A protocol
└───────────┬─────────────┘
            │  bal pack && bal push --repository=local
            ▼
┌────────────────────────┐
│  local Ballerina        │
│  package repository     │
└───────────┬─────────────┘
            │  consumed as a normal [[dependency]],
            │  never by copying source
            ▼
┌────────────────────────┐
│  a2a-interop-tests       │   proves the library actually works
│  (this repo)             │   against real third-party servers,
└────────────────────────┘   not mocks — plus a watchable demo
```

**Why two repos instead of one:** `a2a-ballerina` is the thing being
shipped — its own test suite (mock-based, fast, deterministic) is what
gates every change to the library. `a2a-interop-tests` exists because
testing only against your own mocks validates your own misreadings of the
spec — the primary targets here are real, independently-built reference
servers. Keeping it separate also means this repo's dependency on
`ballerina/a2a` is a real external-package dependency, exactly like any
actual consumer of the library would have — if something only works
because it's sitting inside the library's own source tree, that's a
finding, not a convenience.

**Workflow in both repos:** nothing is committed directly to `main`. Every
unit of work gets its own branch, gets pushed, and goes through a PR —
held for review before merging, no exceptions.

## 2. `a2a-ballerina` — the library

Root: `C:\gitProject\A2A_Project\a2a-ballerina`. The actual Ballerina
package lives in the `a2a/` subdirectory.

| Path | What it is |
| :--- | :--- |
| `a2a/types.bal` | The data model: `Task`, `Message`, `Role`, `TaskState`, `Part`, `AgentCard`, `AgentInterface`, `SendMessageConfiguration`, etc. |
| `a2a/client.bal` | The public `Client` class — `sendMessage`, `sendMessageStream`, `getTask`, `cancelTask`, `subscribeToTask` — plus `resolveAgentCard`/`primaryUrl`. |
| `a2a/errors.bal` | The `A2AError` type hierarchy and the JSON-RPC error-code → typed-error mapping (`toA2AError`). |
| `a2a/sse.bal` | SSE stream decoding — `A2AStreamGenerator`, `readSseStream`, `isTerminalEvent`. |
| `a2a/compat_v03.bal` | **The v0.3 compatibility layer** (added this round, ~515 lines). Everything needed to detect and speak the older A2A v0.3 wire format — see §4 below. |
| `a2a/modules/transport/` | A separate Ballerina submodule: the low-level JSON-RPC envelope types (`JsonRpcRequest`/`JsonRpcResponse`/`JsonRpcError`). Split out specifically to avoid a cyclic module dependency with the root module. |
| `a2a/tests/` | The full mock-based unit suite: `client_test.bal`, `errors_test.bal`, `sse_test.bal`, `types_test.bal`, `compat_v03_test.bal`, `interop_test.bal` (real-server tests, no-op unless configured), and `testutil.bal` (the scripted mock A2A server every mock-based test drives). |
| `a2a/docs/A2A_Technical_Design.md` | The original design doc for the whole library — protocol mapping tables, type rationale, testing strategy. |
| `a2a/docs/superpowers/specs/` | Design specs for individual features, written before implementation: v0.3 client compat, remaining operations, security-scheme typing, REST transport binding, gRPC transport binding. |
| `a2a/docs/superpowers/plans/` | Task-by-task implementation plans, one per spec above, plus `2026-07-30-client-hardening.md` (extensions header, JWS verification, AgentCard caching, SSE auto-reconnect, automatic client-auth wiring). |
| `a2a/docs/archive/` | Superseded design drafts, kept for history — currently the original listener/service draft, moved out of `A2A_Technical_Design.md` once it was superseded. |
| `a2a/LEARNING_LOG.md` | This library's own accumulated lessons (distinct from this repo's `LEARNING_LOG.md`, which is interop-specific). |

**Current size:** 354 tests passing (351 in the `a2a` module, 3 in
`a2a.transport`) — 0 failing. `git log` in `a2a-ballerina` is the
authoritative source for exact current numbers; treat this figure as a
snapshot, not a live count.

## 3. `a2a-interop-tests` — this repo

Root: `C:\gitProject\a2a-interop-tests`.

| Path | What it is |
| :--- | :--- |
| `README.md` | Repo purpose and its relationship to the other two repos (this file expands on that). |
| `DEMO_GUIDE.md` | **Start here to actually run anything** — setup, testing, the interactive demo, and a suggested presentation order. |
| `FINDINGS.md` | Master index: one line per agent tested, linking to its full writeup. |
| `LEARNING_LOG.md` | Interop-specific lessons (e.g. "reference implementations deviate from spec, verify everything empirically"). |
| `tests/` | The real interop test suite (its own Ballerina project). `interop_test.bal` (5 tests against `helloworld`), `currency_agent_interop_test.bal` (2 tests against `adk_currency_agent`), `langgraph_agent_interop_test.bal` (5 tests against the langgraph currency agent — genuine in-flight cancel/subscribe, `INPUT_REQUIRED`/multi-turn, push-notification CRUD), `testutil.bal` (shared helpers — `getServerBaseUrl`, `assertValidTask`, `extractArtifactText`). Every test no-ops with a visible `SKIPPED` marker unless its env var is set — nothing here silently skips without saying so. |
| `demo/` | A separate Ballerina project: an interactive, watchable walkthrough of `Client` — discovery, one-shot `sendMessage`, streaming `sendMessageStream`, then a type-and-see interactive loop. Defaults to `helloworld` (v1.0), but reads `A2A_DEMO_SERVER_URL` and passes the resolved `AgentCard` into `Client`, so it works identically against `adk_currency_agent` (v0.3) too — same code, no branching. |
| `servers/helloworld/` | `setup.md` (venv/run instructions, no credentials needed) + `findings.md` (the v1.0 non-conformances found: missing `AgentCard.url`, PascalCase methods, wrapped `SendMessage` response, `subscribeToTask`'s two-fold non-conformance on terminal tasks). |
| `servers/adk_currency_agent/` | `setup.md` + `findings.md` (the discovery that this agent speaks **v0.3**, not v1.0 — raw wire evidence included) + `.env`/`.env.example` (Gemini or Anthropic API key, git-ignored — never committed). |
| `servers/langgraph_agent/` | `setup.md` (three local patches needed to run it on Claude) + `findings.md` (first agent to genuinely exercise in-flight `cancelTask`/`subscribeToTask` and real push-notification CRUD; surfaced a real `a2a-sdk==0.3.0` non-conformance on delete, plus a blocking-event-loop cancellation bug fixed in the sample). |

**All three reference servers are Python** (`a2a-samples`), run locally:
`helloworld` on `:9999` (no credentials), `adk_currency_agent` on `:10999`
(Gemini or Anthropic key — makes a real LLM call plus a live currency-rate
lookup per conversion), langgraph currency agent on `:10000` (Anthropic key
only in this repo — same real-call pattern, but processes asynchronously
enough to genuinely test in-flight cancel/subscribe and push notifications).

## 4. How the client actually works now

Before this round of work, `Client` only ever spoke A2A protocol **v1.0**:
PascalCase JSON-RPC method names (`SendMessage`), `SCREAMING_SNAKE_CASE`
enums (`ROLE_USER`, `TASK_STATE_COMPLETED`), and wrapped unary responses
(`{"task": {...}}`). Testing against `adk_currency_agent` proved it's built
on the older **v0.3** dialect entirely — lowercase, slash-separated methods
(`message/send`), lowercase enum values (`"user"`, `"completed"`), and
unwrapped, `"kind"`-tagged responses. Confirmed by direct wire probing
before any client code was written — see
[`servers/adk_currency_agent/findings.md`](servers/adk_currency_agent/findings.md).

**The fix, end to end:**

1. **Detection** — `Client.init` gained one new optional parameter,
   `AgentCard? agentCard`. Pass it the card you already got from
   `resolveAgentCard`, and `detectProtocolMode` reads
   `supportedInterfaces[0].protocolVersion` (or the legacy top-level
   `protocolVersion` field, for cards with no `supportedInterfaces` at
   all — exactly `adk_currency_agent`'s shape) to decide `V1_0` or `V0_3`.
   Omit `agentCard` entirely and the client behaves exactly as it always
   did — this is fully backward compatible, not a breaking change.

2. **Outbound translation** — when in `V0_3` mode, every method name gets
   translated (`SendMessage` → `message/send`, etc. — `v03MethodName`),
   and the request body itself gets re-encoded: `encodeV03Message` turns
   the caller's ordinary `Message` (built exactly the same way regardless
   of target dialect) into v0.3's lowercase-role, `"kind"`-tagged shape,
   `encodeV03Part` handles each content variant (text/file/data),
   and `encodeV03SendConfiguration` handles `SendMessageConfiguration`
   (including the inverted-sense `returnImmediately`/`blocking` rename).

3. **Inbound translation** — responses come back in v0.3's unwrapped,
   lowercase-enum shape and get parsed straight into the exact same
   `Task`/`Message`/`TaskState`/`StreamResponse` types the client already
   returns for v1.0 servers (`parseV03Task`, `parseV03Message`,
   `decodeV03SendResult`, `decodeV03StreamEvent`). The caller's code never
   branches on which dialect it's talking to — a `Task|Message` comes back
   either way, with the same field names and the same enum values.

4. **Streaming** — `sendMessageStream`/`subscribeToTask` thread the same
   detected mode through `A2AStreamGenerator`, so SSE events get decoded
   the same translated way, event by event.

**One deliberate simplification, verified not assumed:** v0.3 streaming
events carry a redundant `final: boolean` field alongside the actual task
`state`. The client ignores it entirely — confirmed against the actual
reference SDK's own conversion code that `final` is purely derived from
`state` and carries no independent signal, with a regression test proving
`final: true` paired with a non-terminal state doesn't close the stream.

## 5. Current status

- `a2a-ballerina` PR #2 (`feat: A2A protocol v0.3 client compatibility`) —
  **merged**. Also brought `origin/main` up to date with the entire
  library's history for the first time (it had only ever had the initial
  scaffold pushed before this).
- `a2a-interop-tests` PR #2 (`docs: add adk_currency_agent interop
  findings`) — **merged**.
- `a2a-interop-tests` PR #3 (`test: add real interop tests against
  adk_currency_agent`) — **merged**. Confirms the v0.3 compat layer works
  against the real running agent, not just mocks.
- All three reference servers can be run locally per §3 above; see
  [`DEMO_GUIDE.md`](DEMO_GUIDE.md) for the exact commands.

## 6. Known gaps / good next steps

Findings from the final review — resolved items are kept here as a
record of what was closed and how; the one genuine open item is #4.

1. ~~**`tenant` routing** was sent to v0.3 servers unconditionally.~~
   **Resolved** — `Client` now omits it in `V0_3` mode
   (`a2a-ballerina` `chore/close-v03-gaps`), with a regression test proving
   it's absent from the wire body.
2. ~~**The design spec predated the outbound-encoding half** of the
   work.~~ **Resolved** — the spec now documents `encodeV03Message`/
   `encodeV03Part`/`encodeV03SendConfiguration`/`encodeV03Role` alongside
   the inbound decode functions it already covered.
3. ~~**`TaskPushNotificationConfig`'s exact v0.3 field names were
   unverified against a live server.**~~ **Resolved** — the `langgraph`
   currency agent (`a2a-samples/samples/python/agents/langgraph`, running
   on Claude; see `servers/langgraph_agent/`) genuinely declares and wires
   `capabilities.pushNotifications: true`. `createTaskPushNotificationConfig`/
   `getTaskPushNotificationConfig`/`listTaskPushNotificationConfigs` all
   confirmed passing against it for real. `deleteTaskPushNotificationConfig`
   surfaced a genuine `a2a-sdk==0.3.0` non-conformance instead (a JSON-RPC
   response with neither `result` nor `error`) — correctly rejected by
   `Client` as `InvalidAgentResponseError`; see
   `servers/langgraph_agent/findings.md` §5. Getting a genuine in-flight
   `cancelTask`/`subscribeToTask` test working against the same agent also
   surfaced and fixed two real bugs in the sample (a blocking event loop,
   and a hard-cancellation path that never published a terminal status) —
   see the same findings doc §3.
4. **One wire-shape assumption remains unverified against a live server**
   — still open: whether `Message.referenceTaskIds`/`extensions`/
   `Artifact.extensions` carry identical field names on the wire. This
   extrapolates from the pattern every other field in this file follows;
   no reference agent in this repo exercises cross-task references or
   extensions, so closing this for real needs one that does.
5. ~~**`demo/` only targeted `helloworld`**.~~ **Resolved** —
   `demo/main.bal` now reads `A2A_DEMO_SERVER_URL` and always passes the
   resolved `AgentCard` into `Client`; verified interactively against both
   agents, same script, no branching. See
   [`DEMO_GUIDE.md`](DEMO_GUIDE.md) §4.
6. ~~**No round-trip property test** existed.~~ **Resolved** —
   `parseV03Message(check encodeV03Message(m)) == m`, covering every Part
   variant plus a minimal-message case, added to `compat_v03_test.bal`.
