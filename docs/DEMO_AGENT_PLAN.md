# Plan: add a real client-side agent demo (`demo_agent/`)

**Status:** FINAL — ready to execute. Written 2026-08-16 for execution in
a fresh session with **no prior context**. Everything needed is in this
file — paths, versions, API signatures, real captured data, and the known
landmines. Read it top to bottom before writing code.

### Decisions already made — do not re-litigate these

| Decision | Choice |
| :--- | :--- |
| `demo/` | **Keep exactly as is.** Untouched. `demo_agent/` is a new, separate package alongside it. |
| Delegation transport | **Streaming** (`sendStreamingMessage`) |
| Final answer | **Show both** the remote agent's verbatim reply *and* the local agent's synthesized version, clearly separated (§6.7) |
| Run modes | **Two separate commands** — interactive and scripted (§6.9) |
| Multi-turn clarification | **In scope** — handle `TASK_STATE_INPUT_REQUIRED` (§6.5) |

---

## 1. Why we're doing this

The existing interactive demo (`demo/main.bal`) drives `a2a:Client`
**directly from `main()`** — a human types a line, the demo forwards it
verbatim to a remote agent, and prints the reply. That's a protocol
walkthrough, not a use case.

Nobody deploys that. A2A exists so that **an agent on the client side**
can reach other agents when it hits the edge of what it can do itself.
The client-side agent is the whole point of the protocol, and it is
exactly the part no current demo shows. `demo/` keeps its own job —
showing the raw client API — and this new package sits alongside it.

**The new demo:** a real agent that
1. takes a question,
2. reasons about whether it can answer it itself,
3. if not, **discovers** candidate agents using the spec's discovery
   mechanism, reads their Agent Cards, and reasons about which one's
   declared skills fit the question,
4. constructs an `a2a:Client` for the one it picked, hands the question
   over,
5. takes the answer back and presents it as its own.

That is the real use case, and it doubles as the showcase for what user
code against `ballerina/a2a` actually looks like.

**Out of scope — do not touch:** the interop test suite under `tests/`,
the existing `demo/`, or `demo_tri_transport/`. All three stay exactly as
they are. This work is purely additive: one new package plus additive doc
updates.

---

## 2. Where everything lives

Three sibling checkouts. **None is nested inside another.**

> **Historical note:** when this plan was originally written, `a2a-ballerina`
> sat nested inside a cluttered `A2A_Project` folder that also held every
> reference/scratch resource, which was its own source of confusion ("split
> parent directories"). That's been cleaned up since: `a2a-ballerina` is now
> a proper top-level sibling, `a2a-samples`/`a2a-tck`/toolchain live under
> `a2a-resources`, and `.env` moved into this repo's own root (still
> git-ignored, never tracked). The table below reflects the current layout.

| What | Absolute path |
| :--- | :--- |
| The library (`ballerina/a2a`) | `C:\gitProject\a2a-ballerina\a2a` |
| Upstream reference agents | `C:\gitProject\a2a-resources\a2a-samples` |
| **This repo** (`a2a-interop-tests`) | `C:\gitProject\a2a-interop-tests` |
| Pinned A2A spec v1.0.0 | `C:\gitProject\a2a-resources\a2a-tck\specification\specification.md` |
| Authoritative proto | `C:\gitProject\a2a-resources\a2a-tck\specification\a2a.proto` |
| Anthropic API key | `C:\gitProject\a2a-interop-tests\.env` (`ANTHROPIC_API_KEY=...`) |

All three project checkouts (`a2a-ballerina`, `a2a-interop-tests`, and
`a2a-resources` for everything else) sit directly under `C:\gitProject\`,
as siblings. The `.env` is git-ignored in this repo, never tracked.

Existing packages in this repo:
- `demo/` — the existing low-level interactive demo (`org = anuja_j`,
  name `a2a_interop_demo`). **Leave alone** — it stays as the raw-protocol
  walkthrough. See §8.
- `demo_tri_transport/` — non-interactive, sends one request over gRPC /
  JSON-RPC / REST against `dice_agent`. **Leave alone**, it demonstrates
  something different and still valuable.
- `tests/` — the interop suite. **Leave alone.**

---

## 3. Environment prerequisites

### 3.1 Toolchain
Ballerina **2201.13.4** (`bal version`). On Windows, `bal` resolves as
`bal.bat`.

> **Landmine — exit codes lie.** `bal.bat` invoked through Git Bash on
> this machine reports **exit 0 even on genuine compile errors and test
> failures.** Verified by direct reproduction. Never gate on `$?` from
> Bash. Either grep the output for `error: compilation contains errors` /
> `error: there are test failures`, or run `bal` through the **PowerShell**
> tool where `$LASTEXITCODE` is accurate.

### 3.2 Publish the library locally
This repo consumes `ballerina/a2a` as a real packaged dependency, never
by copying source. Re-run after **any** library change:

```bash
cd "C:\gitProject\a2a-ballerina\a2a"
bal pack
bal push --repository=local
```

The library is currently at version **0.2.0** on `main`
(post-PR #36: AgentCard signature verification, AgentCard caching, gRPC
auth parity, mutation-testing infrastructure). No library changes are
expected for this work — this demo is pure *consumer* code. If you find
yourself editing the library, stop and reconsider; that's a signal the
public API is missing something, which is worth surfacing explicitly
rather than patching around.

### 3.3 Stand up the reference agents

Full detail: `END_TO_END_RUNBOOK.md` Phase 4. Short version — each needs
its own terminal, and three of the four need the Anthropic key:

| Agent | Port | Command (from its dir) |
| :--- | :--- | :--- |
| `helloworld` | 9999 | `.venv\Scripts\activate` then `python __main__.py` |
| `adk_currency_agent` | 10999 | `uv run currency_agent` |
| `langgraph` | 10000 | `model_source=anthropic uv run app` |
| `dice_agent` (Java) | 11000 | `mvn quarkus:dev` |

All under `C:\gitProject\a2a-resources\a2a-samples\samples\...` — venvs and
the Java build are already present from previous sessions.

> **Landmine — Quarkus hangs unattended.** `dice_agent`'s dev mode asks an
> interactive analytics question (`y/n`) on first run in a fresh terminal.
> With no TTY it blocks forever at `Listening for transport dt_socket`
> and never binds port 11000. Fix: pipe an answer in, e.g.
> `( printf "n\n"; sleep 300 ) | mvn quarkus:dev`.

Sanity check all four:
```bash
curl http://127.0.0.1:9999/.well-known/agent-card.json
curl http://localhost:10999/.well-known/agent-card.json
curl http://localhost:10000/.well-known/agent-card.json
curl http://localhost:11000/.well-known/agent-card.json
```

**You do not need all four.** `dice_agent` (11000) plus one currency
agent (10000 or 10999) is enough to demo delegation and routing. Fewer
running agents is a legitimate demo state — the agent should handle
unreachable candidates gracefully (see §6.4).

---

## 4. What the spec actually says about discovery

**Read this section carefully — it's the part most likely to be
faked, and the user specifically asked for genuine spec-backed
discovery.**

Spec §8.2 "Discovery Mechanisms" (`specification.md:1950`) defines
exactly three, verbatim:

> Clients can find Agent Cards through:
> - **Well-Known URI:** Accessing `https://{server_domain}/.well-known/agent-card.json`
> - **Registries/Catalogs:** Querying curated catalogs of agents
> - **Direct Configuration:** Pre-configured Agent Card URLs or content

And §8.1 (`specification.md:1946`):

> A2A Servers **MUST** make an Agent Card available. The Agent Card
> describes the server's identity, capabilities, skills, and interaction
> requirements. **Clients use this information for discovering suitable
> agents** and configuring interactions.

### What this licenses, and what it does not

✅ **Well-Known URI discovery is fully spec-defined** and is what we use
to fetch each candidate's card. `a2a:resolveAgentCard(baseUrl)` performs
exactly this GET against `/.well-known/agent-card.json`.

✅ **Skill-based selection is spec-enabled.** §8.1 states outright that
clients use card information to discover *suitable* agents, and
`AgentSkill` mandates `id`, `name`, `description`, and `tags` as
REQUIRED fields (`a2a.proto:430`) — they exist precisely so a client can
tell what an agent is for.

❌ **The spec defines NO registry wire protocol.** "Registries/Catalogs"
is named as a strategy, with zero normative detail — no endpoint, no
schema, no query semantics. **Do not invent one and present it as spec
compliance.** If you build a candidate list, it is the spec's *Direct
Configuration* bullet, and the code and docs must say so plainly.

❌ **The spec prescribes no matching algorithm.** How you rank skills
against a question is our design choice. Say so; don't dress it up as a
requirement.

**Therefore the honest architecture is:**
a **configured candidate pool** (= Direct Configuration) → **well-known
URI discovery per candidate** (= the spec's own mechanism, via
`resolveAgentCard`) → **LLM reasoning over the returned cards' skills**
(= our selection policy, enabled by spec-mandated skill fields).

Label each of those three steps as exactly that in both code comments and
demo output. The demo is more credible for being precise about which part
is protocol and which part is our policy.

---

## 5. The `ballerina/a2a` API you'll use

Verified against the current source. Signatures are exact.

```ballerina
// Well-known URI discovery -> parsed card. Bare `error` return, not a
// narrowed A2A union: raw http/JSON failures (connection refused,
// malformed body) propagate through as-is.
public isolated function resolveAgentCard(
        string agentBaseUrl,
        http:ClientConfiguration clientConfig = {},
        map<string> headers = {}) returns AgentCard|error;

// The client. Pass the already-resolved AgentCard (preferred here --
// avoids a second well-known fetch). It picks the transport binding from
// the card itself per spec 8.3.2 and auto-detects v1.0 vs v0.3 dialect.
public isolated client class Client {
    public isolated function init(
            AgentCard|string agent,
            http:ClientConfiguration clientConfig = {},
            map<string> headers = {},
            string? tenant = (),
            string[] requestedExtensions = [],
            int maxReconnectAttempts = 0) returns error?;

    isolated remote function sendMessage(
            Message message,
            SendMessageConfiguration? config = (),
            string? tenant = (),
            map<json>? metadata = ()) returns Task|Message|error;

    isolated remote function sendStreamingMessage(...)
            returns stream<StreamResponse, error?>|error;
}

public type AgentSkill record {|
    string id;
    string name;
    string description;
    string[] tags = [];
    string[] inputModes = [];
    string[] outputModes = [];
    string[] examples = [];
    SecurityRequirement[] securityRequirements = [];
    json...;
|};
```

`AgentCard` exposes `name`, `description`, `skills`, `capabilities`
(`.streaming`, `.pushNotifications`, `.extendedAgentCard`),
`supportedInterfaces`, and is an open record (`json...`).

**Note there is no `close()`** on `a2a:Client` — by design; Ballerina's
`http:Client` uses a process-wide pool and offers no teardown. Don't try
to call one.

`demo/main.bal` is a solid reference for the mechanical parts —
`sendMessage`/`sendStreamingMessage` handling, `Task` vs `Message`
returns, walking `StreamResponse` events, extracting text from
`Part[]`/artifacts, and the `describeErrorType` helper that names the
concrete `A2AError` subtype. **Reuse those helpers rather than rewriting
them.**

---

## 6. What to build

### 6.1 New package: `demo_agent/`

Create `C:\gitProject\a2a-interop-tests\demo_agent\` as a new Ballerina
package. Copy `demo/Ballerina.toml` and change only the package name:

```toml
[package]
org = "anuja_j"
name = "a2a_demo_agent"
version = "0.1.0"
distribution = "2201.13.4"

[build-options]
observabilityIncluded = true

[[dependency]]
org = "ballerina"
name = "a2a"
version = "0.2.0"
repository = "local"

# See http_version_pin.bal -- this pin is silently ignored without a
# direct http import in the package.
[[dependency]]
org = "ballerina"
name = "http"
version = "2.14.13"
```

> **Landmine — the http pin is load-bearing.** `ballerina/grpc` (pulled
> in transitively by a2a's gRPC binding) declares no Ballerina-level
> dependency on `http`; its native Java calls `HttpLogManager` directly.
> Without a **direct** `import ballerina/http` in the package, the
> `Ballerina.toml` pin is ignored, the resolver grabs the newest `http`
> from Central, and you get a runtime `IllegalAccessError` at grpc module
> init — not a build error. **Copy `demo/http_version_pin.bal` verbatim
> into `demo_agent/`** (it exists solely to create that direct import).
> And always run with **`--sticky`**.

### 6.2 Files

| File | Purpose |
| :--- | :--- |
| `Ballerina.toml` | above |
| `http_version_pin.bal` | verbatim copy from `demo/` |
| `main.bal` | entry point, arg dispatch between the two run modes, interactive loop |
| `scripted.bal` | the scripted scenario run (§6.6 table) |
| `reasoning.bal` | Claude calls: self-assess, agent selection, final synthesis |
| `discovery.bal` | candidate pool + well-known discovery + card/skill catalog |
| `delegation.bal` | build `a2a:Client`, stream the request, handle `INPUT_REQUIRED` |
| `README.md` | what it demonstrates and how to run it |

Splitting by responsibility (rather than one big `main.bal`) matters
here: **this file layout is itself part of the showcase** — it's the
reference for what user code against this library looks like.

### 6.3 The flow

```
question
   │
   ├─► [1] SELF-ASSESS  (Claude)
   │      "Can I answer this from general knowledge, or does it need a
   │       live/tool-backed capability?"
   │        └─ can answer ──► answer directly, print, done.  ← genuine branch
   │
   ├─► [2] DISCOVER  (spec §8.2)
   │      for each configured candidate base URL:      ← Direct Configuration
   │          a2a:resolveAgentCard(url)                ← Well-Known URI
   │      collect (baseUrl, card, skills); skip unreachable ones
   │
   ├─► [3] SELECT  (Claude, over real card+skill text)
   │      "Here are the discovered agents and their declared skills.
   │       Which — if any — should handle this? Why?"
   │        └─ none suitable ──► say so honestly, don't fabricate.  ← genuine branch
   │
   ├─► [4] DELEGATE  (a2a protocol, streaming)
   │      a2a:Client c = check new (chosenCard, AGENT_CLIENT_CONFIG);
   │      stream<a2a:StreamResponse, error?> s = check c->sendStreamingMessage(msg);
   │      print each event live; accumulate the reply text
   │        └─ TASK_STATE_INPUT_REQUIRED ──► clarification round-trip (§6.5)
   │
   └─► [5] PRESENT  (two clearly separated blocks -- see §6.7)
          [a] the remote agent's reply, VERBATIM
          [b] the local agent's synthesized answer (Claude)
          + attribution: which agent, which skill, why it was picked
```

Every step must print what it's doing and **why** — the reasoning trace
*is* the demo. A silent correct answer proves nothing to a viewer.

### 6.4 Behaviors that must work

- **Self-answer branch is real.** "What is the capital of France?" →
  answered locally, no delegation, no network call to any agent. If
  everything always delegates, step 1 is theatre.
- **Unreachable candidates degrade gracefully.** With only two of four
  agents up, discovery must skip the dead ones (connection refused) and
  proceed with what it found. Print `[unreachable]` per skipped
  candidate. This is normal, not an error state.
- **"No suitable agent" is a first-class outcome.** Ask something no
  discovered agent covers and no local knowledge answers — it must say
  so rather than force a bad match.
- **Delegation is genuine.** The chosen agent is chosen *from discovered
  card data*, never hardcoded per question.

### 6.5 Multi-turn clarification (in scope)

A remote agent can end a turn in `TASK_STATE_INPUT_REQUIRED` — a genuine,
model-driven request for missing information (e.g. "Convert 100 dollars"
→ *"to which currency?"*). This is real behavior, not hypothetical:
`tests/langgraph_agent_interop_test.bal`'s
`testLangGraphAgentInputRequiredThenMultiTurn` already proves the
`langgraph` agent does exactly this, and `demo/main.bal:86-106` is a
working reference for the continuation mechanics.

**The mechanics:** capture `taskId` and `contextId` off the
`TaskStatusUpdateEvent` (or `Task`) when the state is `INPUT_REQUIRED`,
then set **both** on the *next* outgoing `a2a:Message`. That continues
the same task instead of starting a fresh one. Any other terminal state
clears them.

**Behavior differs by run mode — this is the point of having both:**

- **Interactive:** print the clarification, prompt the user (`  ? `),
  send their reply back into the same task/context. The user is in the
  loop, exactly as a real deployment would have them.
- **Scripted:** no user available, so the *local agent* answers the
  clarification itself — give Claude the original question plus the
  clarification text and let it supply the missing detail (e.g. infers
  "to euros" from "What is 100 USD in EUR?"). If it can't, abort that
  scenario cleanly with a printed reason rather than hanging.

Cap the clarification rounds (2 is plenty) so a confused agent can't
loop forever.

### 6.6 Demo scenarios — grounded in really-captured skill data

Captured live from the four agents on 2026-08-16. Use these to design and
sanity-check routing; **re-fetch rather than trusting this table** if
behavior looks off, since upstream samples change.

| Agent | Port | Skill `id` | Tags | Example prompt from its own card |
| :--- | :--- | :--- | :--- | :--- |
| Hello World Agent | 9999 | `echo_bot` | `a2a`, `echo-example` | "hi" |
| Currency Conversion Agent | 10999 | `currency_conversion` | `currency`, `conversion` | "Helps with currency conversions" |
| Currency Agent | 10000 | `convert_currency` | `currency conversion`, `currency exchange` | "What is exchange rate between USD and GBP?" |
| Dice Agent | 11000 | `dice_roller` | `dice`, `games`, `random` | "Can you roll a 6-sided die?" |
| Dice Agent | 11000 | `prime_checker` | `math`, `prime`, `numbers` | "Is 17 a prime number?" |

Scripted demo run:

| # | Question | Expected path |
| :--- | :--- | :--- |
| 1 | "What is the capital of France?" | **self-answer**, no delegation |
| 2 | "Is 97 a prime number?" | → Dice Agent, `prime_checker` |
| 3 | "Roll a 20-sided die." | → Dice Agent, `dice_roller` |
| 4 | "What is 100 USD in EUR?" | → a Currency Agent |
| 5 | "Book me a flight to Tokyo." | **no suitable agent**, said honestly |
| 6 | "Convert 100 dollars." (deliberately underspecified) | → Currency Agent → `INPUT_REQUIRED` → clarification round-trip (§6.5) |

Note #2 and #3 hit the **same agent via different skills**, #4 has **two
plausible agents**, and #6 exercises multi-turn — all good things to
show. Scenario 6 needs the `langgraph` agent (port 10000), which is the
one proven to ask for clarification.

### 6.7 Presenting the answer — show both, clearly separated

**Print the remote agent's reply verbatim AND the local agent's
synthesized version, as two visually distinct blocks.** Not one or the
other. For example:

```
--- remote agent's reply (verbatim, exactly as received over A2A) ---
You rolled a 17.

--- local agent's answer (Claude-synthesized from the above) ---
I rolled a 20-sided die for you and got 17.

  [via] Dice Agent (http://localhost:11000), skill "dice_roller"
  [why] The question asked for a die roll; this agent's dice_roller
        skill declares tags dice/games/random.
```

The reason for showing both: the synthesis step is an LLM call, so its
output is **not deterministic and not under our control**. Putting the
raw protocol payload right next to it makes that visible and auditable —
a viewer can see exactly what A2A delivered versus what the local model
did with it. If the model ever distorts a value (rephrasing "17" into
something else), the demo shows it honestly instead of hiding it. That
transparency is a feature of this demo, not a caveat.

Label the blocks explicitly as "verbatim" and "synthesized" so nobody
mistakes model output for protocol output.

### 6.8 The reasoning layer — call Anthropic directly over `ballerina/http`

**Do not add `ballerinax/ai` or any other connector.** Reasons, in order:

1. Only the `ballerina` org is in this machine's package cache; any
   `ballerinax` package pulls fresh from Central.
2. This repo has a **documented, already-bitten** binary-incompatibility
   landmine around the `http` version pin (§6.1). A new connector
   dragging in its own `http`/`io` constraints is the single most likely
   way to re-trigger it.
3. `ballerina/http` is already a direct pinned dependency. A plain HTTPS
   POST costs one function and zero new resolution risk.

Anthropic Messages API:
- `POST https://api.anthropic.com/v1/messages`
- Headers: `x-api-key: <key>`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`
- Body: `{"model": "...", "max_tokens": N, "messages":[{"role":"user","content":"..."}]}`
- Reply: `{"content":[{"type":"text","text":"..."}], ...}` — read
  `content[0].text`.

Use model **`claude-sonnet-5`**. Read the key with
`os:getEnv("ANTHROPIC_API_KEY")`; fail with a clear, actionable message
if unset. **Never hardcode or log the key.**

There are **four** distinct Claude calls in this design. Keep each in its
own function with its own prompt:

| # | Purpose | Output shape |
| :--- | :--- | :--- |
| 1 | Self-assess: answerable locally, or needs a live/tool-backed capability? | strict JSON |
| 2 | Select an agent from the discovered catalog | strict JSON |
| 3 | Synthesize the final answer from the remote reply (§6.7) | free text |
| 4 | Answer a remote agent's clarification, scripted mode only (§6.5) | free text |

For the JSON ones, ask for **strict JSON** and parse it, e.g.
`{"canAnswerLocally": true, "reason": "..."}` and
`{"chosenAgent": "<baseUrl>|none", "skillId": "...", "reason": "..."}`.
Models sometimes wrap JSON in prose or fences — strip to the outermost
`{...}` before parsing, and on parse failure fall back to a safe default
(treat as "cannot answer locally" / "no suitable agent") rather than
crashing the demo.

For call 3, instruct the model plainly to **preserve exact values** from
the remote reply (numbers, rates, results) and not to recompute or
embellish them. It reduces — but does not eliminate — the distortion that
§6.7's side-by-side output exists to expose.

### 6.9 Two run commands

Single package, dispatched on a command-line argument, so the two modes
share the agent implementation instead of duplicating it:

```bash
cd "C:\gitProject\a2a-interop-tests\demo_agent"

# 1. Interactive -- type your own questions, `quit` to exit
bal run --sticky

# 2. Scripted -- runs all six scenarios in §6.6 unattended, then exits
bal run --sticky -- scripted
```

Give `main` the signature `public function main(string... args)` and
branch on `args`. Document **both** commands verbatim in
`demo_agent/README.md` and anywhere else the demo is referenced.

If you'd rather have two physically separate packages than two commands,
that's a small restructure (shared code moves into a module) — but ask
first, don't do it unilaterally.

### 6.10 HTTP config for the A2A calls

```ballerina
final http:ClientConfiguration AGENT_CLIENT_CONFIG = {httpVersion: http:HTTP_1_1};
```

> **Landmine — dice_agent and h2c.** Ballerina's HTTP client defaults to
> HTTP/2; Quarkus dev mode doesn't negotiate h2c correctly, surfacing as
> `Agent Card fetch failed with HTTP 400`. Pin HTTP/1.1. Harmless for the
> three Python agents, so apply it unconditionally and keep the code free
> of per-agent branching — same as `demo/main.bal:31`.

This config applies to the **A2A agent calls**. The Anthropic call is a
separate `http:Client` against `api.anthropic.com` and should use
defaults (it's real HTTPS to a real CDN — do not force HTTP/1.1 there).

---

## 7. Build order

Work in this sequence; each step is verifiable on its own. Don't write
all five files then run for the first time.

1. **Spike the Anthropic call first.** Package skeleton + one hardcoded
   Claude round-trip, printed. This is the only genuinely unproven piece
   — everything else is patterns already working in `demo/`. If it
   fights you, better to know at minute five.
2. **Discovery.** Candidate pool + `resolveAgentCard` loop + print the
   catalog (agent name, base URL, skills with tags). Verify against live
   agents, including one deliberately stopped to confirm graceful skip.
3. **Selection.** Feed the real catalog to Claude, print the choice and
   the reason. Verify scenarios 1-5 in §6.6 route correctly.
4. **Delegation (streaming).** Build `a2a:Client` from the chosen card,
   `sendStreamingMessage`, print events live, accumulate the reply text.
   Reuse `demo/main.bal`'s `Task`/`Message` and stream-walking handling.
   Verify with scenarios 2-4.
5. **Presentation.** The two-block verbatim + synthesized output of §6.6,
   with attribution.
6. **Interactive mode.** The `> ` prompt loop with `quit`.
7. **Multi-turn clarification (§6.5).** Interactive path first (prompt the
   user), then the scripted path (Claude answers it). Verify with
   scenario 6 against `langgraph`.
8. **Scripted mode.** All six scenarios end to end, unattended.
9. **README + docs.**

Verify after each: `bal run --sticky` from inside `demo_agent/`,
remembering §3.1 (exit codes lie — read the output).

---

## 8. Documentation to update

The current demo is referenced across the repo. A blind session **will**
miss some of these; grep before declaring done:

```bash
cd "C:\gitProject\a2a-interop-tests"
grep -rn "cd demo\|demo/main.bal\|a2a_interop_demo" --include=*.md .
```

Known referrers:
- `END_TO_END_RUNBOOK.md` — Phase 6 "Run the live demos"
- `DEMO_GUIDE.md`
- `DEMO_PRESENTATION_SCRIPT.md` — the non-technical walkthrough
- `REPO_MAP.md`
- `README.md`
- `demo/README.md`

**`demo/` is staying — decided.** Do **not** delete, move, or edit it.
Its existing docs and references stay valid exactly as they are.

The docs work is therefore purely **additive**: introduce `demo_agent/`
alongside `demo/`, and make the distinction clear wherever both appear:

- **`demo/`** — the low-level protocol walkthrough. What raw
  `a2a:Client` usage looks like: resolve a card, send a message, read the
  stream. A human drives it directly.
- **`demo_agent/`** — the real use case. An agent that reasons,
  discovers, delegates to another agent over A2A, and answers. This is
  the headline demo.

At minimum add `demo_agent/` to `END_TO_END_RUNBOOK.md` Phase 6,
`DEMO_GUIDE.md`, and `REPO_MAP.md`. `DEMO_PRESENTATION_SCRIPT.md` is the
non-technical walkthrough and is the strongest candidate for leading with
`demo_agent/` — but that's a rewrite of a presentation script, so ask
before reworking it wholesale.

---

## 9. Post-implementation: docs pass and full repo cleanup, both repos

**Do this only after the demo works end to end (§9 checklist green).**
It's the last phase of this plan, not a parallel task — cleaning up
while the design is still moving just creates more to redo.

### 9.1 Docs pass

Re-run the grep from §8 — it will now also catch anything the
implementation itself added:

```bash
cd "C:\gitProject\a2a-interop-tests"
grep -rln "cd demo\b" --include=*.md . | grep -v "cd demo_agent"
```

Update every hit so `demo/` and `demo_agent/` are both represented
wherever a reader would reasonably look for "how do I run the demo,"
per the distinction in §8. Don't just add a mention — check the
surrounding prose still makes sense with two demos instead of one (e.g.
`DEMO_GUIDE.md`'s intro paragraph, `REPO_MAP.md`'s repo diagram/prose).

### 9.2 Archive or delete deprecated docs — named candidates

These are real, already-identified as of 2026-08-16 — verify each is
still true before acting, since time will have passed:

**`a2a-interop-tests` (this repo):**
- `TEMP_ballerina_vs_python_sdk.md` and `TEMP_walkthrough_client_and_demo.md`
  at the repo root — both untracked, both self-labeled temporary
  (`TEMP_walkthrough_client_and_demo.md` literally says *"Delete it when
  you're done reading. Generated 2026-08-05."*). If their content isn't
  needed, `rm` them (they're untracked — nothing to revert). If something
  in them is worth keeping, fold it into a real doc first, then delete.
- Any doc whose content is now superseded by `demo_agent/`'s own README
  or by this plan having been executed — check `DEMO_PRESENTATION_SCRIPT.md`
  in particular once you know whether it got the `demo_agent/` rewrite
  mentioned in §8.
- Re-check for other `TEMP_*`/`*_OLD*`/`*_DRAFT*`-style files that may
  have accumulated since — `find . -maxdepth 2 -iname "TEMP*"` etc.

**`a2a-ballerina`:** no deprecated docs found as of this writing (its
`docs/API_PROVENANCE.md`, `docs/A2A_Technical_Design.md` are live and
current). Re-check rather than assume that's still true.

Prefer **delete** over **archive** for anything genuinely superseded and
still reachable in git history — an `archive/` folder that nobody
revisits is just deferred deletion with extra steps. Only keep something
findable outside git history if there's a real reason a future reader
would look for it by browsing the repo rather than `git log`.

### 9.3 Repo and branch cleanup — both repos

**`a2a-ballerina`:** as of 2026-08-16, these local branches are fully
merged into `main` (`git branch --merged main` confirms) — safe to
delete, both local and their `origin/*` counterparts, once you've
independently re-verified they're merged (branches move; re-check, don't
trust this list blindly):
`docs/api-provenance`, `docs/transport-specific-clients`,
`feature/client-delegator`, `feature/grpc-client`,
`feature/jsonrpc-client`, `feature/rest-client`,
`fix/robust-binding-selection`, `fix/v10-security-scheme-oneof`,
`refactor/demote-internal-helpers`, `refactor/extract-operation-logic`,
`refactor/merge-constructor`, `refactor/remove-non-spec-public-api`,
`refactor/spec-aligned-interface-selection`,
`refactor/unexport-internal-modules`, `test/whole-client-integration`.

```bash
cd "C:\gitProject\a2a-ballerina"
git branch -d <name>              # local, once merge is re-confirmed
git push origin --delete <name>   # remote — ask before doing this part,
                                   # it's a shared-visibility action
```

**`a2a-interop-tests`:** local branch `ci/interop-tests-workflow` is
**NOT a cleanup candidate** — it backs an **open PR (#13, opened
2026-08-02, "ci: build demo and tests packages against a2a-ballerina's
main on every push/PR")** that has been sitting unmerged for two weeks
as of this writing. Don't delete it or its branch. Flag it back to the
user as a real, still-open loose end needing a decision (merge, update,
or close) — it is out of scope for this plan to resolve unilaterally,
since it's unrelated CI work, not part of the demo_agent effort.

For both repos, also check and report (don't act on these without
asking — they're either destructive or ambiguous):
- Any other local branches with no matching PR, open or merged (rename
  drift, abandoned spikes)
- Stray build artifacts *not* already covered by `.gitignore`
  (`target/` in both repos is already ignored — verify new dirs like
  `demo_agent/target/` are covered by the same ignore pattern, not by
  their own literal entry)
- Any `.env`-shaped file that isn't already git-ignored (a real secret
  leak risk, not just tidiness — treat any hit here as urgent)

### 9.4 What "done" means for this phase

- [ ] Docs grep from §9.1 returns clean
- [ ] Both TEMP_*.md files resolved (deleted or folded in) — confirmed
      with the user first if anything in them seemed worth preserving
- [ ] Merged local branches in `a2a-ballerina` deleted (local at least;
      remote deletion only with explicit go-ahead)
- [ ] PR #13 in `a2a-interop-tests` reported to the user as still open —
      not touched
- [ ] No stray `.env`/secret-shaped files outside `.gitignore` in either
      repo
- [ ] Final `git status --short` on both repos is clean (or only shows
      intentional, explained state)

---

## 10. Definition of done (implementation phase)

This is the gate for "the demo works." §9's docs-pass and cleanup is a
separate, later checklist (§9.4) — do this one first.

- [ ] Both commands work: `bal run --sticky` and `bal run --sticky -- scripted`
- [ ] Scenario 1 answers locally with **no** delegation
- [ ] Scenarios 2 and 3 both route to `dice_agent`, via **different** skills
- [ ] Scenario 4 routes to a currency agent
- [ ] Scenario 5 honestly reports no suitable agent
- [ ] Scenario 6 completes a clarification round-trip in **both** modes —
      user-prompted when interactive, Claude-answered when scripted
- [ ] Delegation uses `sendStreamingMessage`; events print live as they arrive
- [ ] Every delegated answer shows **both** blocks — verbatim remote reply
      and synthesized local answer — explicitly labeled (§6.7)
- [ ] With an agent stopped, discovery skips it and continues
- [ ] Every step prints its reasoning — a viewer can follow the decision
- [ ] Discovery output states plainly which part is spec mechanism
      (well-known URI) and which is our policy (candidate pool, skill
      matching) — see §4
- [ ] No `ballerinax` dependency added; `http` pin + `http_version_pin.bal`
      present
- [ ] API key read from env, never hardcoded, never logged
- [ ] `demo/` untouched, `tests/` untouched — confirm with `git status`
- [ ] Docs updated additively per §8; `demo/`'s own docs left alone
- [ ] Interop suite still passes unchanged: `bal test --sticky --groups interop`
      → **15 passing, 1 failing** (the failure is the documented upstream
      `a2a-sdk==0.3.0` bug on `deleteTaskPushNotificationConfig` — expected,
      not a regression)

---

## 11. Repo conventions

From `a2a-ballerina/CLAUDE.md` and this repo's history — they apply here:

- **Never** add "Generated with Claude Code", a session link, or a
  `Co-Authored-By: Claude` line to commits, PRs, or docs. Authorship is
  Anuja's alone.
- Commit each unit as it's completed; don't batch.
- **Do not push, open a PR, or merge unless explicitly asked** — each of
  those is a separate request.
- Work on a feature branch, not `main` — every unit of work in both repos
  has gone through branch + PR.
- Ballerina style: doc comments (`#`) on public symbols with `+ param -`
  / `+ return -` lines; spec-facing records stay open (`json...`).
