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
| `a2a/docs/superpowers/specs/` | Design specs for individual features, written before implementation. Currently: `2026-07-28-v03-client-compat-design.md`. |
| `a2a/docs/superpowers/plans/` | Task-by-task implementation plans. Currently: `2026-07-28-a2a-v03-client-compat.md`. |
| `a2a/LEARNING_LOG.md` | This library's own accumulated lessons (distinct from this repo's `LEARNING_LOG.md`, which is interop-specific). |

**Current size:** 136 tests passing in the `a2a` module, 3 in
`a2a.transport` — 0 failing.

## 3. `a2a-interop-tests` — this repo

Root: `C:\gitProject\a2a-interop-tests`.

| Path | What it is |
| :--- | :--- |
| `README.md` | Repo purpose and its relationship to the other two repos (this file expands on that). |
| `DEMO_GUIDE.md` | **Start here to actually run anything** — setup, testing, the interactive demo, and a suggested presentation order. |
| `FINDINGS.md` | Master index: one line per agent tested, linking to its full writeup. |
| `LEARNING_LOG.md` | Interop-specific lessons (e.g. "reference implementations deviate from spec, verify everything empirically"). |
| `tests/` | The real interop test suite (its own Ballerina project). `interop_test.bal` (5 tests against `helloworld`), `currency_agent_interop_test.bal` (2 tests against `adk_currency_agent`), `testutil.bal` (shared helpers — `getServerBaseUrl`, `assertValidTask`, `extractArtifactText`). Every test no-ops with a visible `SKIPPED` marker unless its env var is set — nothing here silently skips without saying so. |
| `demo/` | A separate Ballerina project: an interactive, watchable walkthrough of `Client` — discovery, one-shot `sendMessage`, streaming `sendMessageStream`, then a type-and-see interactive loop. Currently wired to `helloworld` (v1.0) only. |
| `servers/helloworld/` | `setup.md` (venv/run instructions, no credentials needed) + `findings.md` (the v1.0 non-conformances found: missing `AgentCard.url`, PascalCase methods, wrapped `SendMessage` response, `subscribeToTask`'s two-fold non-conformance on terminal tasks). |
| `servers/adk_currency_agent/` | `setup.md` + `findings.md` (the discovery that this agent speaks **v0.3**, not v1.0 — raw wire evidence included) + `.env`/`.env.example` (Gemini API key, git-ignored — never committed). |

**Both reference servers are Python** (`a2a-samples`), run locally:
`helloworld` on `:9999` (no credentials), `adk_currency_agent` on `:10999`
(needs a Google API key with Gemini access — it makes a real LLM call plus
a live currency-rate lookup per conversion).

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
- Both reference servers can be run locally per §3 above; see
  [`DEMO_GUIDE.md`](DEMO_GUIDE.md) for the exact commands.

## 6. Known gaps / good next steps

Real, deliberately-deferred findings from the final review — none block
what's already merged, but worth knowing about:

1. **`tenant` routing** is still sent to v0.3 servers unconditionally.
   It's a v1.0-only concept; harmless against lenient servers, a possible
   400 against a strict one.
2. **The design spec predates the outbound-encoding half** of the work —
   it documents inbound decoding thoroughly (that's all the original plan
   covered) but the encode functions were added later, in response to what
   the live interop test surfaced, and the spec was never updated to match.
3. **Two wire-shape assumptions remain unverified against a live server**:
   `TaskPushNotificationConfig`'s exact v0.3 field names, and whether
   `Message.referenceTaskIds`/`extensions`/`Artifact.extensions` carry
   identical field names on the wire. Both extrapolate from the pattern
   every other field in this file follows; neither has been exercised by
   an actual server response.
4. **`demo/` only targets `helloworld`** — pointing a copy of it at
   `adk_currency_agent` (passing `agentCard` into the `Client`
   constructor, mirroring `tests/currency_agent_interop_test.bal`) would
   let the v0.3 path be watched interactively, not just proven by a test
   runner.
5. **No round-trip property test** (`parseV03Message(encodeV03Message(m))
   == m` across all field combinations) exists yet — the cheapest ongoing
   guard against the encode and decode halves silently drifting apart as
   either one changes in the future.
