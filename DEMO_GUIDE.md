# Demo & testing guide

A practical, run-it-yourself guide to this repo's scenario: `ballerina/a2a`'s
`Client` talking to real, independently-built A2A reference agents — some
speaking a different protocol dialect than the client's native one, and
one that genuinely exercises the operations the others can't (in-flight
cancel/subscribe, push notifications, multi-turn) — never noticing any of
it, because the client auto-detects and translates transparently.

**Everything in this guide is written and tested for Windows `cmd.exe`**
(that's how this repo is actually run day to day). If you're on Git Bash or
WSL instead, the same steps work with the obvious POSIX equivalents
(`source .venv/bin/activate`, `export VAR=value`, `cp` instead of `copy`,
etc.) — see the note at the end of §1.

## Which agent should I run?

**Start with the `langgraph` currency agent — it's the one to reach for
first.** It's the only agent in this repo that genuinely exercises the
*entire* client surface in one place: real conversions, genuine
`INPUT_REQUIRED` + multi-turn, genuine in-flight `cancelTask`/
`subscribeToTask` (not just against an already-terminal task, which is all
the other two can ever offer), and genuine push-notification config CRUD.
If you only have time to stand up one agent before a demo or a release
check, this is it.

| Agent | Protocol | Port | Credentials | What it proves |
| :---- | :---- | :--- | :--- | :---- |
| **`langgraph` currency agent** (Python/LangGraph, `a2a-samples`, on Claude) | v0.3 | `:10000` | Anthropic API key | **Recommended — full-coverage agent.** Genuine in-flight `cancelTask`/`subscribeToTask`, genuine `INPUT_REQUIRED` + multi-turn continuation, genuine push-notification config CRUD, plus everything the other two prove |
| `helloworld` (Python, `a2a-samples`) | v1.0 | `:9999` | none | The client's native dialect, simplest/fastest sanity check — discovery, `sendMessage`, `sendMessageStream`, `getTask`, `getExtendedAgentCard` |
| `adk_currency_agent` (Python/Google ADK, `a2a-samples`) | v0.3 | `:10999` | Google or Anthropic API key | A second, independent v0.3 dialect example — proves the client's auto-detection/translation isn't tuned to one specific agent |

Run `helloworld` first if you just want the fastest possible sanity check
that the client works at all (no credentials, no LLM latency). Run
`adk_currency_agent` if you specifically want to show the v0.3-dialect
story with a second, differently-built agent. Run the `langgraph` agent
for everything else — it is the one this guide leads with below.

## 1. Prerequisites

- **Ballerina** 2201.13.4 (`bal version` to check) — needed for everything.
- **Python 3.10+** and **[`uv`](https://github.com/astral-sh/uv)** — needed
  to run any of the reference agents locally.
- **An Anthropic API key** (get one at
  https://console.anthropic.com/settings/keys) — needed for the `langgraph`
  agent (the recommended one) and optionally for `adk_currency_agent`.
  **A Google API key with Gemini access** is an alternative for
  `adk_currency_agent` only, but its free tier is easy to exhaust (see §7)
  — Anthropic billing sidesteps that. `helloworld` needs no external
  credentials at all.
- A local checkout of
  [`a2a-samples`](https://github.com/a2aproject/a2a-samples) alongside this
  repo — none of the reference agents are vendored in here.
- `ballerina/a2a` packed and pushed to your local Ballerina repository (see
  step 2 below) — this repo consumes it as a dependency, not a copy of the
  source.

All commands below are written for **Windows `cmd.exe`**, since that's how
this repo is actually run day to day. If you're on Git Bash or WSL instead,
the same steps work with the obvious POSIX equivalents (`source
.venv/bin/activate`, `export VAR=value`, `cp` instead of `copy`, etc.).

## 2. One-time setup: pack `ballerina/a2a` locally

Every time you change (or pull a new version of) `ballerina/a2a`, rebuild
and republish it to the local Ballerina package repository so this repo
picks up the change:

```bat
cd path\to\a2a-ballerina\a2a
bal pack
bal push --repository=local
```

Both `tests/Ballerina.toml` and `demo/Ballerina.toml` already declare
`ballerina/a2a` as a `repository = "local"` dependency — no further config
needed on this repo's side.

## 3. Set up each agent

### `langgraph` currency agent (v0.3, on Claude) — recommended, start here

`helloworld` and `adk_currency_agent` both process every task
synchronously — by the time the client sees a task at all, it's already
`COMPLETED`. That means `cancelTask`/`subscribeToTask` against either of
them can only ever be tested against an already-terminal task, and neither
supports push notifications at all. The `langgraph` currency agent
(`a2a-samples/samples/python/agents/langgraph` — a different sample from
`adk_currency_agent`, built on LangGraph rather than Google ADK) makes a
real, several-second Claude call plus a real tool call per turn, which is
enough time for a `cancelTask` or `subscribeToTask` sent immediately after
to hit a task that is genuinely still running. It also genuinely wires
push-notification support (`capabilities.pushNotifications: true`, a real
`InMemoryPushNotificationConfigStore` + `BasePushNotificationSender`), and
genuinely produces `INPUT_REQUIRED` + multi-turn continuation. This is the
one agent that exercises the client's full feature surface in one place.

**This agent needs three local patches to `a2a-samples` before it'll run
on Claude at all**, plus a fourth for genuine cancellation — none of them
upstreamed. Full reasoning for each: `servers/langgraph_agent/findings.md`.
Full instructions: `servers/langgraph_agent/setup.md`. Summary:

```bat
cd path\to\a2a-samples\samples\python\agents\langgraph
```

1. `pyproject.toml` — add `langchain-anthropic>=0.3.0` to `dependencies`.
2. `app/agent.py` — add an `anthropic` branch to the `model_source` switch
   using `ChatAnthropic(model='claude-sonnet-4-5')` — **not** a newer Opus;
   LangGraph's `response_format` mechanism relies on assistant-message
   prefill, which Opus 4.6+ rejects outright. Also fix the tool's stale
   `frankfurter.app` endpoint/param names to match the current `.dev` API
   (same fix `adk_currency_agent`'s tools already needed).
3. `app/__main__.py` — add the matching `ANTHROPIC_API_KEY` check to the
   startup validation.
4. `app/agent_executor.py` (+ one line in `agent.py`) — real cancellation:
   switch `self.graph.stream(...)` to `self.graph.astream(...)` (the sync
   form blocks the entire event loop during each real network call, so a
   concurrent `cancelTask` request physically can't be serviced until the
   whole task finishes), track cancelled task IDs, and — critically — add
   a dedicated `except asyncio.CancelledError:` clause that publishes
   `TASK_STATE_CANCELED` before re-raising. The SDK hard-cancels the
   executor's coroutine directly (not just a cooperative flag), which
   otherwise leaves the task stuck at `SUBMITTED` forever since
   `except Exception` never sees a `CancelledError` (it's a
   `BaseException`, deliberately not caught by that clause).

Then bring it up:

```bat
uv sync
set model_source=anthropic
set ANTHROPIC_API_KEY=sk-ant-...
uv run app
```

Listens on `http://localhost:10000` by default. Leave it running in its
own terminal (same `set`-in-this-window-only caveat as every other agent
here — see §7 if a fresh window can't find your key). Sanity-check it's up:

```bat
curl -s http://localhost:10000/.well-known/agent-card.json
```

Run its interop tests:

```bat
:: from repo root
set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
bal test --groups interop
```

`tests/langgraph_agent_interop_test.bal` covers: a real conversion, genuine
`INPUT_REQUIRED` + multi-turn continuation (ask for "Convert 100 USD" with
no target currency, then complete the same task with a follow-up), a
genuine in-flight `cancelTask` (confirmed durable via a follow-up
`getTask`, not just the cancel response), a genuine in-flight
`subscribeToTask`, and push-notification config create/get/list/delete.
One of those — delete — is expected to fail: `a2a-sdk==0.3.0`'s response
for that operation has neither `result` nor `error`, which `Client`
correctly rejects as `InvalidAgentResponseError`. See
`servers/langgraph_agent/findings.md` §5 — that's a real non-conformance
in the reference SDK, not a bug in this repo's client or a test to "fix."

### `helloworld` (v1.0, no credentials needed)

```bat
cd path\to\a2a-samples\samples\python\agents\helloworld
python -m venv .venv
.venv\Scripts\activate.bat
pip install -r requirements.txt
python __main__.py
```

Listens on `http://127.0.0.1:9999`. Leave it running in its own terminal
(`activate.bat` only changes that `cmd` window's `PATH`/prompt — nothing
persists to other windows or reboots).

If you'd rather not activate the venv at all, you can skip straight to the
venv's own `python.exe` without touching `PATH`:

```bat
cd path\to\a2a-samples\samples\python\agents\helloworld
.venv\Scripts\python.exe __main__.py
```

Full details: [`servers/helloworld/setup.md`](servers/helloworld/setup.md).

### `adk_currency_agent` (v0.3, needs a Gemini API key)

```bat
cd servers\adk_currency_agent
copy .env.example .env
notepad .env
:: set GOOGLE_API_KEY to a real key with Gemini access, save, close

cd path\to\a2a-samples\samples\python\agents\adk_currency_agent
uv sync
set GOOGLE_API_KEY=<paste the same key you put in .env>
uv run currency_agent
```

`cmd.exe` has no `source`/`.env`-loading built in, so the key has to be set
directly with `set` in the same window before `uv run` — copy the value out
of `.env` by hand. (If you're scripting this instead of typing it
interactively, a one-liner that reads `.env` for you:
`for /f "tokens=1,2 delims==" %A in (servers\adk_currency_agent\.env) do set %A=%B`
— run from this repo's root, and skip lines starting with `#` if you add
comments to the file.)

Listens on `http://localhost:10999`. Leave it running in its own terminal.
The `.env` file is git-ignored — your key never gets committed. Full
details: [`servers/adk_currency_agent/setup.md`](servers/adk_currency_agent/setup.md).

**Sanity-check both are up** before moving on:

```bat
curl -s http://127.0.0.1:9999/.well-known/agent-card.json
curl -s http://localhost:10999/.well-known/agent-card.json
```

The second response's `"protocolVersion":"0.3.0"` (no `supportedInterfaces`
array) is the tell — that's the whole reason this repo's `ballerina/a2a`
work exists. See
[`servers/adk_currency_agent/findings.md`](servers/adk_currency_agent/findings.md)
for the full wire-level evidence.

### Optional: run `adk_currency_agent` on Claude instead of Gemini

The agent doesn't have to run on Gemini — Google ADK (which it's built on)
has pluggable model backends, and this repo has actually verified an
Anthropic-backed run end to end. This is useful when Gemini's free tier is
exhausted (see §7's troubleshooting entry) or you just want to compare
providers; the A2A client and every test/demo in this guide work completely
unchanged either way, since the client only ever speaks A2A protocol to the
agent's HTTP endpoint — which LLM answers behind that endpoint is invisible
to it.

To switch, three changes to
`path\to\a2a-samples\samples\python\agents\adk_currency_agent`:

1. Add `anthropic` to `pyproject.toml`'s `dependencies`, then `uv sync`.
2. In `src/currency_agent/agent.py`, swap the model:

   ```python
   from google.adk.models.anthropic_llm import AnthropicLlm
   # ...
   model=AnthropicLlm(model='claude-opus-4-8'),   # was: model='gemini-2.0-flash'
   ```

   **Use `AnthropicLlm`, not the similarly-named `Claude` class** — `Claude`
   is the Vertex-AI-hosted variant and requires `GOOGLE_CLOUD_PROJECT`/
   `GOOGLE_CLOUD_LOCATION`; it will raise `ValueError: GOOGLE_CLOUD_PROJECT
   and GOOGLE_CLOUD_LOCATION must be set for using Anthropic on Vertex.`
   if you reach for it by mistake. `AnthropicLlm` is the direct-API class —
   it just needs `ANTHROPIC_API_KEY`.
3. **Known ADK bug — wrap every tool's return value in `{"result": ...}`.**
   ADK's Anthropic tool-result serializer
   (`google/adk/models/anthropic_llm.py`, around line 100) only extracts
   content when the tool's return dict has a top-level `"content"` or
   `"result"` key — that's Gemini/ADK's own function-response convention.
   `get_latest_rates` and the other tools in `agent.py` return the raw
   Frankfurter JSON dict (`{"amount": ..., "rates": {...}}`) with neither
   key, so Claude silently receives an **empty** tool result every time,
   retries a few times, then gives up claiming "the rate service isn't
   returning data" — even though the log shows the HTTP call to Frankfurter
   succeeding (`200 OK`) on every attempt. Fix: change each tool's final
   `return response.json()` to `return {'result': response.json()}`. This
   is harmless on the Gemini path too — Gemini's serializer doesn't care
   about the wrapper key.
4. Also add a system instruction enforcing the exact JSON response shape.
   ADK passes `output_schema=AgentResponse` through to Gemini as an
   enforced schema, but **not** to Claude — `anthropic_llm.py` has no
   `response_schema`/`output_schema` handling at all, so without an
   explicit instruction Claude has no schema pressure and could
   occasionally reply with something `AgentResponse.model_validate_json`
   can't parse (which `agent_executor.py` then reports as
   `TASK_STATE_FAILED`). Append to the agent's `instruction`:

   ```python
   ' Always respond with ONLY a JSON object matching this exact shape, no other text: '
   '{"message": "<your reply text>", "status": "completed" | "input-required" | "failed"}. '
   'Use "completed" once the conversion has been answered, "input-required" when you need '
   'the user to supply more information (e.g. a missing target currency), and "failed" only '
   'if a tool call errored.'
   ```

Then add `ANTHROPIC_API_KEY=sk-ant-...` to
`servers/adk_currency_agent/.env` alongside `GOOGLE_API_KEY` (get a key at
https://console.anthropic.com/settings/keys — no free tier, but the cost of
running this repo's tests/demo against it is a handful of cents), restart
the server the normal way (§7 — Python doesn't hot-reload), and everything
downstream — the demo, `bal test --groups interop`, this whole guide — works
identically to the Gemini path, all 8 interop tests passing with real
conversions.

## 4. Run the real interop tests

With whichever servers you've started running, from the repo root (this
is a single Ballerina package — `tests/` is not its own package, so run
`bal test` from here, not from inside `tests\`):

```bat
:: langgraph currency agent (v0.3, Claude) — 5 tests: genuine in-flight
:: cancel/subscribe, INPUT_REQUIRED + multi-turn, push-notification CRUD.
:: Run this one if you only run one.
set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
bal test --groups interop

:: helloworld (v1.0) — 5 tests, full operation coverage
set A2A_TEST_SERVER_URL=http://127.0.0.1:9999
bal test --groups interop

:: adk_currency_agent (v0.3) — 2 tests, proves auto-detection + translation
set A2A_CURRENCY_AGENT_URL=http://localhost:10999
bal test --groups interop
```

Unlike a POSIX shell, `cmd`'s `set` persists for the rest of that window, so
once all three are set you can run `bal test --groups interop` once and get
all 12 interop tests in a single invocation. Expect the currency-agent
tests to take noticeably longer (10-30+ seconds each) — every call is a
real LLM round trip plus a live rate lookup, not a mock.

To unset a var for a later run in the same window: `set A2A_TEST_SERVER_URL=`
(setting it to nothing removes it).

A plain `bal test` (no env vars) runs the full mock-based unit suite from
`ballerina/a2a` unaffected — these interop tests no-op with a visible
`SKIPPED` marker rather than silently passing when unconfigured.

## 5. Run the interactive demo

```bat
cd demo
bal run
```

This walks through `resolveAgentCard`, one `sendMessage`, one
`sendMessageStream` (printing events live), then an interactive loop —
type a line, press Enter, see it streamed back; `quit` to exit.

**Works against either agent, unmodified.** `demo/main.bal`'s `serverUrl()`
function has one `return` line active and one commented out — to switch
which agent the demo targets, open `demo/main.bal`, comment out the
active line and uncomment the other, then just `bal run` again:

```ballerina
return "http://127.0.0.1:9999";     // helloworld (v1.0)
// return "http://localhost:10999"; // adk_currency_agent (v0.3)
```

The demo always passes the resolved `AgentCard` into the `Client`
constructor, so protocol-version auto-detection just happens, the same
way it does in `tests/currency_agent_interop_test.bal` — same script,
same output format, no code branching, regardless of which line is
active.

`A2A_DEMO_SERVER_URL`, if set, still overrides whichever line is active —
useful for scripting or CI without editing the file, and it's how you
point the demo at the `langgraph` agent, since that agent isn't one of
`serverUrl()`'s two hardcoded lines:

```bat
cd demo
set A2A_DEMO_SERVER_URL=http://localhost:10000
bal run
```

```bat
:: or against adk_currency_agent, without editing the file
cd demo
set A2A_DEMO_SERVER_URL=http://localhost:10999
bal run
```

## 6. Suggested demo narrative

If you're presenting this rather than just running it yourself, this order
tells the actual story:

1. **Run the `langgraph` agent through the demo first**
   (`A2A_DEMO_SERVER_URL=http://localhost:10000`, or its interop tests) —
   this is the one agent that proves the client's full feature surface:
   real conversions, genuine `INPUT_REQUIRED` + follow-up, and (via its
   dedicated tests, not the demo script) genuine in-flight cancel/
   subscribe and push notifications. Lead with this; everything else is
   supporting evidence for the v0.3-dialect story specifically.
2. **Show `helloworld` working** (`bal run` in `demo/`, or the interop
   tests) — this is the client's home turf, v1.0, nothing surprising, and
   the fastest sanity check if something seems off.
3. **Show the raw wire mismatch** — `curl` both `adk_currency_agent`'s and
   `helloworld`'s agent cards side by side; point at
   `adk_currency_agent`'s `"protocolVersion":"0.3.0"` and missing
   `supportedInterfaces`. Optionally replay the raw `curl` probes from
   `servers/adk_currency_agent/findings.md` showing `SendMessage` failing
   with `-32601 Method not found` while `message/send` succeeds — this is
   the "why does this need special handling at all" moment.
4. **Run `testCurrencyAgentSendMessage`/`testCurrencyAgentSendMessageStream`**
   (§4 above) — same `a2a:Client` type, same `sendMessage`/
   `sendMessageStream` calls as the `helloworld` demo, just constructed
   with `agentCard = check a2a:resolveAgentCard(baseUrl)` this time. That
   one extra argument is the entire caller-visible difference between
   talking to a v1.0 and a v0.3 server.
5. **Point at the findings docs** — `servers/adk_currency_agent/findings.md`
   and `servers/langgraph_agent/findings.md` for the evidence, and
   `a2a-ballerina`'s
   `a2a/docs/superpowers/specs/2026-07-28-v03-client-compat-design.md` for
   how the translation actually works under the hood, if the audience wants
   to go deeper.

## 7. Troubleshooting

- **Currency agent exits immediately** — `GOOGLE_API_KEY` (or
  `ANTHROPIC_API_KEY`, for the `langgraph` agent or a Claude-backed
  `adk_currency_agent`) isn't set. Check `.env` has a real key and that the
  `set VAR=...` actually ran in the *same* `cmd` window, right before
  `uv run ...` — `set` only affects the window it's typed in, so a fresh
  window (or one where you set it before switching directories with
  `cd /d`) won't have it. Confirm with `echo %GOOGLE_API_KEY%` /
  `echo %ANTHROPIC_API_KEY%` before running.
- **Interop test against the currency agent times out** — Gemini + a live
  rate lookup routinely takes several seconds; a stock `bal test` timeout
  may not be enough under load. The tests already set a longer
  `http:ClientConfiguration.timeout` where needed
  (`testCurrencyAgentSendMessageStream` uses 30s) — if you still see
  timeouts, it's more likely API latency or quota than a bug.
- **Currency agent suddenly returns `TASK_STATE_FAILED` with no artifact
  (or hangs, then times out)** — `agent_executor.py` catches *any*
  exception from the ADK runner and unconditionally marks the task
  `failed`; it never surfaces the real Gemini error to the A2A client, so
  "failed, no artifact" is the only client-visible symptom no matter what
  actually went wrong server-side. **Check the currency agent's own
  console/log output first** — the real exception (with the Gemini error
  body) is printed there, not on the A2A client side.

  Two distinct causes look the same from the client but need different
  fixes:
  - **`limit: 0` in the error body** (e.g. `Quota exceeded for metric:
    generate_content_free_tier_requests, limit: 0, model: ...`) — this is
    **not** "you used up your quota," it's "this API key's project has
    *zero* free-tier quota allocated," and it applies across models, not
    just one. Switching `agent.py`'s `model=` to a different model will
    **not** fix this — confirmed by testing (`gemini-3-flash-preview` →
    `gemini-2.0-flash` still hit `limit: 0` after a full server restart).
    The fix is a different key: go to
    [Google AI Studio](https://aistudio.google.com/apikey) → "Create API
    key" → **create it in a new project**, not an existing/older Cloud
    project — free-tier eligibility is a project-level setting, not a
    per-request thing. If a fresh-project key still shows `limit: 0`, the
    free tier likely isn't available at all for that account/region, and
    you'd need billing enabled for paid-tier access instead.
  - **A numeric per-minute/per-day quota actually being exceeded** (the
    error names a real number, not `0`, or you've been sending many
    requests in quick succession) — this is genuine usage-based
    exhaustion. `agent.py` combines `tools=[...]` with
    `output_schema=AgentResponse` in ADK's `LlmAgent`, so each user turn
    costs **1 Gemini call** for a message that doesn't need a tool (e.g.
    "Say hello") and **2 calls** for an actual conversion request (one to
    decide to invoke `get_latest_rates`, a second to produce the final
    structured response after the tool result) — one
    `bal test --groups interop` run with `A2A_CURRENCY_AGENT_URL` set
    costs ~4 calls, since both tests send real conversions. Wait for the
    quota window to reset (daily quotas typically reset at midnight
    Pacific), or budget your runs — skip the currency-agent leg entirely
    when you're only checking something unrelated to v0.3;
    `A2A_TEST_SERVER_URL` alone against `helloworld` costs zero Gemini
    calls.

  Either way, check https://ai.dev/rate-limit — that's the only
  authoritative source of what limit you actually hit. **Remember to
  restart the currency agent process after editing `.env` or `agent.py`**
  — Python doesn't hot-reload; a running server keeps its old key/model in
  memory until you stop and re-launch it (§3's `uv run currency_agent` or
  the equivalent `.venv\Scripts\currency_agent.exe`).

  If Gemini quota keeps being a blocker, §3's "Optional: run
  `adk_currency_agent` on Claude instead of Gemini" is a verified working
  alternative — same agent, same tests, no Gemini dependency at all.
- **`bal push` says the package already exists** — that's fine, it means
  you already published this exact version; re-run `bal pack` after making
  a change and it'll produce a fresh `.bala` to push.
- **Port already in use (9999, 10999, or 10000)** — a previous run's
  server is still alive in the background. Find and stop it:

  ```bat
  netstat -ano | findstr :10000
  :: note the PID in the last column, then:
  taskkill /PID <pid> /F
  ```
