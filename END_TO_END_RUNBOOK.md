# End-to-end runbook

A single, self-contained walkthrough: zero prior context assumed, start to
finish, from an empty machine to all four reference agents running and
every capability verified with real evidence. If you already have some of
the prerequisites installed, skip ahead to the relevant phase.

This runbook consolidates and supersedes jumping between
[`DEMO_GUIDE.md`](DEMO_GUIDE.md) and each `servers/<agent>/setup.md` for a
first-time, top-to-bottom run — those files remain the authoritative
per-agent reference if something here goes stale.

**What you'll have at the end**: four independently-built A2A reference
agents running locally (three Python, one Java), all reachable through
`ballerina/a2a`'s client, an automated test suite proving every client
capability against them, and two live demo scripts you can run and watch.

---

## Phase 0 — What you need before starting

- **An Anthropic API key** (console.anthropic.com) — every LLM-backed agent
  in this walkthrough runs on Claude. One key covers all of them.
- **~30-45 minutes** for a first-time run (mostly dependency downloads).
- **Windows `cmd.exe`** is what every command below is written for (this
  repo's actual day-to-day environment). Git Bash/WSL/macOS/Linux: the same
  steps work with the obvious POSIX equivalents (`export VAR=value` instead
  of `set VAR=value`, `source` instead of `activate.bat`, etc.).

## Phase 1 — Install the toolchain

Check what you already have first — skip any step whose check already
succeeds.

| Tool | Check | If missing |
| :--- | :--- | :--- |
| **Ballerina 2201.13.4** | `bal version` | Install from [ballerina.io/downloads](https://ballerina.io/downloads/) |
| **Python 3.10+** | `python --version` | Install from [python.org](https://python.org), or via your OS package manager |
| **[`uv`](https://github.com/astral-sh/uv)** | `uv --version` | `powershell -c "irm https://astral.sh/uv/install.ps1 | iex"` (Windows) or `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| **JDK 17+** | `java -version` | See below |
| **Maven** | `mvn -version` | See below |
| **`git`** | `git --version` | [git-scm.com](https://git-scm.com) |
| **GitHub CLI** (optional, for PR workflow) | `gh --version` | [cli.github.com](https://cli.github.com) |

**JDK/Maven, no-admin-rights fallback**: if you can't run an installer
(locked-down machine, no admin), use portable zip distributions instead —
no install, no PATH pollution beyond your own session:

```bat
mkdir C:\tools & cd C:\tools
curl -L -o jdk.zip "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12%2B8/OpenJDK21U-jdk_x64_windows_hotspot_21.0.12_8.zip"
tar -xf jdk.zip
curl -L -o maven.zip "https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.zip"
tar -xf maven.zip
set JAVA_HOME=C:\tools\jdk-21.0.12+8
set PATH=%JAVA_HOME%\bin;C:\tools\apache-maven-3.9.16\bin;%PATH%
```
(`set`/`PATH` only last for the current `cmd` window — re-run before each
new session, or add to your profile if you'll use this regularly.)

## Phase 2 — Check out the three repos, as siblings

`ballerina/a2a` (the library), `a2a-samples` (upstream reference agents,
not vendored), and `a2a-interop-tests` (this repo) are three separate
checkouts. `a2a-ballerina` sits top-level, a sibling of `a2a-interop-tests`;
`a2a-samples` and everything else that isn't part of either project
(toolchain, spec checkout, one-off scratch tools) lives under a third
folder, `a2a-resources`, kept separate so it doesn't clutter either repo:

```bat
:: the library -- top-level, sibling to a2a-interop-tests
cd C:\gitProject
git clone <your-a2a-ballerina-repo-url> a2a-ballerina

:: everything else -- reference agents, toolchain, spec checkout
mkdir C:\gitProject\a2a-resources & cd C:\gitProject\a2a-resources
git clone https://github.com/a2aproject/a2a-samples.git
:: a2a-interop-tests is presumably already checked out if you're reading this file
```

## Phase 3 — Pack and publish `ballerina/a2a` locally

This repo consumes `ballerina/a2a` as a real external package dependency
(via a local Ballerina package repository), not by copying source. Every
time the library changes, repeat this step:

```bat
cd C:\gitProject\a2a-ballerina
bal pack
bal push --repository=local
```

## Phase 4 — Stand up all four reference agents

Each agent runs in its own terminal window and stays running for the rest
of this walkthrough. Full per-agent reasoning and troubleshooting:
`servers/<agent>/setup.md` in this repo.

### 4a. `helloworld` — no credentials, fastest sanity check

```bat
cd C:\gitProject\a2a-resources\a2a-samples\samples\python\agents\helloworld
python -m venv .venv
.venv\Scripts\activate.bat
pip install -r requirements.txt
python __main__.py
```
Listens on `http://127.0.0.1:9999`. Verify: `curl http://127.0.0.1:9999/.well-known/agent-card.json`

### 4b. `adk_currency_agent` — Google ADK, on Claude

```bat
cd C:\gitProject\a2a-resources\a2a-samples\samples\python\agents\adk_currency_agent
uv sync
set ANTHROPIC_API_KEY=sk-ant-...
uv run currency_agent
```
Needs local patches first (model set to `AnthropicLlm`, a tool-result-wrapping
fix for a real ADK bug, and an API-key-check fix) — full details and exact
diffs: `servers/adk_currency_agent/setup.md`. Listens on `http://localhost:10999`.
Verify: `curl http://localhost:10999/.well-known/agent-card.json`

### 4c. `langgraph` currency agent — richest agent, on Claude

```bat
cd C:\gitProject\a2a-resources\a2a-samples\samples\python\agents\langgraph
uv sync
set model_source=anthropic
set ANTHROPIC_API_KEY=sk-ant-...
uv run app
```
Needs four local patches first (Claude model swap, a stale API endpoint
fix, async cancellation fix, timeout/retry hardening) — full details:
`servers/langgraph_agent/setup.md`. Listens on `http://localhost:10000`.
Verify: `curl http://localhost:10000/.well-known/agent-card.json`

### 4d. `dice_agent` — Java/Quarkus, the only REST+gRPC-serving agent, on Claude

```bat
cd C:\gitProject\a2a-resources\a2a-samples\samples\java\agents\dice_agent_multi_transport\server
set ANTHROPIC_API_KEY=sk-ant-...
mvn quarkus:dev
```
Needs the SDK migrated to `org.a2aproject.sdk:1.1.0.Final` (not the
sample's published `0.3.2.Final` — the older version never emits a
spec-correct agent card), plus two protobuf version pins and a Claude
swap in `pom.xml` — full details and exact diffs: `servers/dice_agent/setup.md`.
Listens on `http://localhost:11000`. Verify:
```bat
curl http://localhost:11000/.well-known/agent-card.json
```
Confirm `supportedInterfaces` lists all three of `GRPC`, `JSONRPC`, and
`HTTP+JSON` — that field is the entire point of this agent.

### Sanity-check all four at once

```bat
curl http://127.0.0.1:9999/.well-known/agent-card.json
curl http://localhost:10999/.well-known/agent-card.json
curl http://localhost:10000/.well-known/agent-card.json
curl http://localhost:11000/.well-known/agent-card.json
```
All four should return `200` with a JSON agent card. If any hangs or
returns nothing, see Phase 7 (troubleshooting) before continuing.

## Phase 5 — Run the automated test suite (proof, all 15+ operations)

From this repo's root (not from inside `tests\` — it's not its own
package):

```bat
set A2A_TEST_SERVER_URL=http://127.0.0.1:9999
set A2A_CURRENCY_AGENT_URL=http://localhost:10999
set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
set A2A_DICE_AGENT_URL=http://localhost:11000
bal test --sticky --groups interop
```

**`--sticky` is required**, not optional — see Phase 7 if you omit it and
hit an `IllegalAccessError`. Expected result: **15 passing, 1 failing**
(`testLangGraphAgentPushNotificationConfigCrud`, a documented, expected
upstream `a2a-sdk==0.3.0` non-conformance on delete — not a bug in this
client; see `servers/langgraph_agent/findings.md` §5). Every test that
no-ops because its env var isn't set prints a visible `SKIPPED` marker
rather than silently passing — if all four vars above are set, nothing
should skip.

This is the checklist in [`CLIENT_TEST_COVERAGE.md`](CLIENT_TEST_COVERAGE.md)
being proven live, row by row.

## Phase 6 — Run the live demos

**Interactive conversation + genuine multi-turn** (defaults to `langgraph`):
```bat
cd demo
bal run --sticky
```
Walks through discovery → `sendMessage` → `sendStreamingMessage`, then drops
into an interactive loop — type a question, get a real answer. Try leaving
out required information (e.g. "Convert 100 dollars" with no target
currency) to see a genuine model-driven clarification, then answer it
("to euros") to see the same conversation resume correctly.

To point it at a different agent without editing the file:
```bat
set A2A_DEMO_SERVER_URL=http://localhost:10999
bal run --sticky
```

**Same request, three transport bindings, one agent**:
```bat
cd demo_tri_transport
set A2A_DICE_AGENT_URL=http://localhost:11000
bal run --sticky
```
Sends "Can you roll a 6-sided die?" over gRPC, then JSON-RPC, then REST,
printing each real, independently-generated answer.

**The headline demo -- a real client-side agent** (`demo/` above drives
`a2a:Client` directly; this one is the actual use case, an agent that
decides for itself):
```bat
cd demo_agent
bal run --sticky
```
Give it a question. It self-assesses whether it can answer locally, and
if not, discovers candidate agents via the spec's well-known-URI
mechanism, picks one by reasoning over its declared skills, delegates
over streaming, and presents both the remote agent's verbatim reply and
its own synthesized answer, side by side. Needs `ANTHROPIC_API_KEY` set
and at least one reference agent running. For an unattended run through
six fixed scenarios instead:
```bat
bal run --sticky -- scripted
```
See `demo_agent/README.md` for the full design.

## Phase 7 — Troubleshooting

- **`IllegalAccessError: class ballerina.grpc.1.log_manager tried to
  access method ...`** — you ran `bal test`/`bal build`/`bal run` without
  `--sticky`. This repo pins `ballerina/http` to a version compatible with
  `ballerina/grpc` (needed for the gRPC transport binding) in
  `Dependencies.toml`; without `--sticky`, the resolver ignores that pin
  and picks a newer, binary-incompatible `http`. Always pass `--sticky`.
  Full diagnosis: `servers/dice_agent/findings.md` §6.
- **`Agent Card fetch failed with HTTP 400` against `dice_agent`
  specifically** — Ballerina's HTTP client defaults to HTTP/2, and Quarkus
  dev mode doesn't negotiate that (h2c) correctly. Already fixed in this
  repo's own test/demo code (`clientConfig = {httpVersion: http:HTTP_1_1}`);
  if you're writing new code against `dice_agent`, you'll need the same
  fix. Full diagnosis: `servers/dice_agent/findings.md` §7.
- **`bal push` says the package already exists** — harmless, means you
  already published this exact version; `bal pack` again after a real
  source change to get a fresh `.bala`.
- **Currency agent (`adk_currency_agent` or `langgraph`) returns
  `TASK_STATE_FAILED` with no useful client-side detail** — the executor
  swallows the real exception; check that agent's own terminal/console
  output, not the A2A client side, for the actual error. Often just a
  stale process from an earlier session — restart it.
- **A server is "up" (port listening) but every request hangs/times
  out** — a stuck process from an earlier run. Find and kill it:
  ```bat
  netstat -ano | findstr :<port>
  taskkill /PID <pid> /F
  ```
  then restart the agent fresh.
- **`dice_agent` returns a `500` with `NoSuchMethodError` on
  `JsonFormat.Printer`** — `protobuf-java-util` isn't pinned alongside
  `protobuf-java` in `samples/java/agents/pom.xml`. Should already be fixed
  if you're on a current checkout; see `servers/dice_agent/findings.md` §9
  if you're debugging a regression.
- **Port already in use (`9999`/`10999`/`10000`/`11000`)** — a previous
  run's server is still alive. `netstat -ano | findstr :<port>`, then
  `taskkill /PID <pid> /F`.

## Where to go next

- **[`CLIENT_TEST_COVERAGE.md`](CLIENT_TEST_COVERAGE.md)** — the full
  feature checklist: every spec operation, which client method implements
  it, which agent(s) it's been proven against, and current status.
- **[`SPEC_COMPLIANCE_REPORT.md`](SPEC_COMPLIANCE_REPORT.md)** — the full
  audit against the official A2A specification, method by method, plus the
  honest remaining-gaps list (extension headers, JWS signature
  verification, automatic SSE reconnection, etc. — hardening work, not
  missing core functionality).
- **[`VERIFICATION_EVIDENCE.md`](VERIFICATION_EVIDENCE.md)** — real
  captured request/response evidence for every capability above, from an
  actual run.
- **[`FINDINGS.md`](FINDINGS.md)** — the master index of every real,
  independently-built agent tested here and what was found testing against
  it (real bugs, real spec deviations — in both this client and the
  reference servers).
- **[`DEMO_PRESENTATION_SCRIPT.md`](DEMO_PRESENTATION_SCRIPT.md)** — a
  live-presentation script for a non-technical audience, built on exactly
  the demos in Phase 6 above.
