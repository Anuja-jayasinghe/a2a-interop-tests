# adk_currency_agent reference server — setup

The Google ADK-based currency conversion agent, from `a2a-samples`
(`samples/python/agents/adk_currency_agent`). Not vendored into this repo —
set it up from a checkout of `a2a-samples` alongside this one.

## Prerequisites

- [`uv`](https://github.com/astral-sh/uv) package manager.
- This repo runs the agent on **Claude by default** (an Anthropic API key)
  rather than Gemini, to sidestep Gemini's free-tier quota walls — see
  DEMO_GUIDE.md §3 for the three `agent.py` patches that make that work,
  plus a fourth in `main.py` (below). Gemini (`GOOGLE_API_KEY`) still works
  if you revert those patches — see DEMO_GUIDE.md §3's "Using Gemini
  instead".
- `main.py`'s startup check originally required `GOOGLE_API_KEY`
  unconditionally, even when the agent is configured to run on Claude —
  see [`findings.md`](./findings.md) §7. Patch it to accept either key:

  ```python
  if not os.getenv('ANTHROPIC_API_KEY') and not os.getenv('GOOGLE_API_KEY'):
      logger.error('ANTHROPIC_API_KEY (or GOOGLE_API_KEY, if using Gemini) must be set')
      sys.exit(1)
  ```

## Quick start

1. Copy the env template and fill in your key (this file, `.env`, is
   git-ignored — it never gets committed):

   ```bash
   cd servers/adk_currency_agent
   cp .env.example .env
   # edit .env, set ANTHROPIC_API_KEY (or GOOGLE_API_KEY, for Gemini)
   ```

2. Install dependencies and run the server, loading `.env`:

   ```bash
   cd path/to/a2a-samples/samples/python/agents/adk_currency_agent
   uv sync
   set -a && source path/to/a2a-interop-tests/servers/adk_currency_agent/.env && set +a
   uv run currency_agent
   ```

   (`set -a` exports every variable `source` picks up, so `ENV` and
   `ANTHROPIC_API_KEY`/`GOOGLE_API_KEY` both land in the process
   environment without editing the file's syntax — it's a plain
   `KEY=value` file, not a shell script.)

Listens on `http://localhost:10999`.

## Using it with this repo

- **Card discovery**: `GET http://localhost:10999/.well-known/agent-card.json`
- **A2A endpoint**: `POST http://localhost:10999/`

**Important — this agent speaks A2A protocol v0.3, not v1.0.** Its
`AgentCard` declares `"protocolVersion": "0.3.0"` at the top level (no
`supportedInterfaces`), and its JSON-RPC endpoint only accepts legacy method
names (`message/send`, not `SendMessage`). See
[`findings.md`](./findings.md) for the full evidence and what it means for
`ballerina/a2a`'s `Client`.

Each conversion call makes a real Gemini API call plus a live lookup against
the Frankfurter exchange-rate API, so responses take several seconds and
consume API quota — this is not a free-standing mock.
