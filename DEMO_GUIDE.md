# Demo & testing guide

A practical, run-it-yourself guide to this repo's scenario: `ballerina/a2a`'s
`Client` talking to two real, independently-built A2A reference agents that
speak **two different protocol dialects** — and never noticing the
difference, because the client auto-detects and translates transparently.

| Agent | Protocol | What it proves |
| :---- | :---- | :---- |
| `helloworld` (Python, `a2a-samples`) | v1.0 | The client's native dialect — full round trip: discovery, `sendMessage`, `sendMessageStream`, `getTask`, `cancelTask`, `subscribeToTask` |
| `adk_currency_agent` (Python/Google ADK, `a2a-samples`) | **v0.3** | The client detects the older dialect from the agent's card and transparently re-encodes/decodes every request and response — same client code, no special-casing by the caller |

If you only run one of these, run `adk_currency_agent` — it's the one that
actually demonstrates the point of this repo's v0.3 compatibility work.
`helloworld` is the simpler, faster baseline to sanity-check first.

## 1. Prerequisites

- **Ballerina** 2201.13.4 (`bal version` to check) — needed for everything.
- **Python 3.10+** and **[`uv`](https://github.com/astral-sh/uv)** — needed
  to run either reference agent locally.
- **A Google API key with Gemini access** — needed *only* for
  `adk_currency_agent` (it makes a real LLM call per conversion, plus a live
  lookup against the Frankfurter exchange-rate API). `helloworld` needs no
  external credentials at all.
- A local checkout of
  [`a2a-samples`](https://github.com/a2aproject/a2a-samples) alongside this
  repo — neither reference agent is vendored in here.
- `ballerina/a2a` packed and pushed to your local Ballerina repository (see
  step 2 below) — this repo consumes it as a dependency, not a copy of the
  source.

## 2. One-time setup: pack `ballerina/a2a` locally

Every time you change (or pull a new version of) `ballerina/a2a`, rebuild
and republish it to the local Ballerina package repository so this repo
picks up the change:

```bash
cd path/to/a2a-ballerina/a2a
bal pack
bal push --repository=local
```

Both `tests/Ballerina.toml` and `demo/Ballerina.toml` already declare
`ballerina/a2a` as a `repository = "local"` dependency — no further config
needed on this repo's side.

## 3. Set up each agent

### `helloworld` (v1.0, no credentials needed)

```bash
cd path/to/a2a-samples/samples/python/agents/helloworld
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python __main__.py
```

Listens on `http://127.0.0.1:9999`. Leave it running in its own terminal.
Full details: [`servers/helloworld/setup.md`](servers/helloworld/setup.md).

### `adk_currency_agent` (v0.3, needs a Gemini API key)

```bash
cd servers/adk_currency_agent
cp .env.example .env
# edit .env, set GOOGLE_API_KEY to a real key with Gemini access

cd path/to/a2a-samples/samples/python/agents/adk_currency_agent
uv sync
set -a && source path/to/a2a-interop-tests/servers/adk_currency_agent/.env && set +a
uv run currency_agent
```

Listens on `http://localhost:10999`. Leave it running in its own terminal.
The `.env` file is git-ignored — your key never gets committed. Full
details: [`servers/adk_currency_agent/setup.md`](servers/adk_currency_agent/setup.md).

**Sanity-check both are up** before moving on:

```bash
curl -s http://127.0.0.1:9999/.well-known/agent-card.json
curl -s http://localhost:10999/.well-known/agent-card.json
```

The second response's `"protocolVersion":"0.3.0"` (no `supportedInterfaces`
array) is the tell — that's the whole reason this repo's `ballerina/a2a`
work exists. See
[`servers/adk_currency_agent/findings.md`](servers/adk_currency_agent/findings.md)
for the full wire-level evidence.

## 4. Run the real interop tests

With both servers running, from `tests/`:

```bash
# helloworld (v1.0) — 5 tests, full operation coverage
A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --groups interop

# adk_currency_agent (v0.3) — 2 tests, proves auto-detection + translation
A2A_CURRENCY_AGENT_URL=http://localhost:10999 bal test --groups interop
```

You can set both env vars at once to run all 7 interop tests in a single
`bal test --groups interop` invocation. Expect the currency-agent tests to
take noticeably longer (10-30+ seconds each) — every call is a real Gemini
round trip plus a live rate lookup, not a mock.

A plain `bal test` (no env vars) runs the full mock-based unit suite from
`ballerina/a2a` unaffected — these interop tests no-op with a visible
`SKIPPED` marker rather than silently passing when unconfigured.

## 5. Run the interactive demo

```bash
cd demo
bal run
```

This walks through `resolveAgentCard`, one `sendMessage`, one
`sendMessageStream` (printing events live), then an interactive loop —
type a line, press Enter, see it streamed back; `quit` to exit.

**Note on scope**: `demo/main.bal` currently points at `helloworld`
(`http://127.0.0.1:9999`) and doesn't pass an `AgentCard` into the `Client`,
so it always runs in v1.0 mode. It demonstrates the client's core
capabilities, not the v0.3 compatibility layer specifically — that's what
step 4's `adk_currency_agent` interop tests are for. If you want to *watch*
the v0.3 path work interactively rather than just see it pass in a test
runner, that's a natural follow-up: point a copy of `demo/main.bal` at
`http://localhost:10999` and pass `agentCard = check a2a:resolveAgentCard(SERVER_URL)`
into the `Client` constructor (mirroring what
`tests/currency_agent_interop_test.bal` already does) — the same demo
script would then work against either agent unmodified everywhere else.

## 6. Suggested demo narrative

If you're presenting this rather than just running it yourself, this order
tells the actual story:

1. **Show `helloworld` working** (`bal run` in `demo/`, or the interop
   tests) — this is the client's home turf, v1.0, nothing surprising.
2. **Show the raw wire mismatch** — `curl` both agent cards side by side;
   point at `adk_currency_agent`'s `"protocolVersion":"0.3.0"` and missing
   `supportedInterfaces`. Optionally replay the raw `curl` probes from
   `servers/adk_currency_agent/findings.md` showing `SendMessage` failing
   with `-32601 Method not found` while `message/send` succeeds — this is
   the "why does this need special handling at all" moment.
3. **Run `testCurrencyAgentSendMessage`/`testCurrencyAgentSendMessageStream`**
   (step 4 above) — same `a2a:Client` type, same `sendMessage`/
   `sendMessageStream` calls as the `helloworld` demo, just constructed
   with `agentCard = check a2a:resolveAgentCard(baseUrl)` this time. That
   one extra argument is the entire caller-visible difference between
   talking to a v1.0 and a v0.3 server.
4. **Point at the findings docs** — `servers/adk_currency_agent/findings.md`
   for the evidence, and `a2a-ballerina`'s
   `a2a/docs/superpowers/specs/2026-07-28-v03-client-compat-design.md` for
   how the translation actually works under the hood, if the audience wants
   to go deeper.

## 7. Troubleshooting

- **Currency agent exits immediately** — `GOOGLE_API_KEY` isn't set. Check
  `.env` has a real key and step 3's `source .env` actually ran in the same
  shell before `uv run currency_agent`.
- **Interop test against the currency agent times out** — Gemini + a live
  rate lookup routinely takes several seconds; a stock `bal test` timeout
  may not be enough under load. The tests already set a longer
  `http:ClientConfiguration.timeout` where needed
  (`testCurrencyAgentSendMessageStream` uses 30s) — if you still see
  timeouts, it's more likely API latency or quota than a bug.
- **`bal push` says the package already exists** — that's fine, it means
  you already published this exact version; re-run `bal pack` after making
  a change and it'll produce a fresh `.bala` to push.
- **Port already in use (9999 or 10999)** — a previous run's server is
  still alive in the background; find and stop it before starting a new
  one (both processes log which port they bind to on startup).
