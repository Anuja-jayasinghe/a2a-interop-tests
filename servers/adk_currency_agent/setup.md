# adk_currency_agent reference server — setup

The Google ADK-based currency conversion agent, from `a2a-samples`
(`samples/python/agents/adk_currency_agent`). Not vendored into this repo —
set it up from a checkout of `a2a-samples` alongside this one.

## Prerequisites

- [`uv`](https://github.com/astral-sh/uv) package manager.
- A valid Google API Key with access to Gemini models. The server refuses to
  start without one (`GOOGLE_API_KEY` unset exits immediately).

## Quick start

```bash
cd path/to/a2a-samples/samples/python/agents/adk_currency_agent
uv sync
export ENV=development
export GOOGLE_API_KEY="your-google-api-key"
uv run currency_agent
```

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
