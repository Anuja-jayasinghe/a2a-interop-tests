# langgraph currency agent reference server — setup

The LangGraph-based currency conversion agent, from `a2a-samples`
(`samples/python/agents/langgraph`) — a different sample from
`adk_currency_agent` (which is Google-ADK-based). Not vendored into this
repo — set it up from a checkout of `a2a-samples` alongside this one.

**Why this agent exists in the test matrix**: unlike `helloworld` and
`adk_currency_agent`, this agent processes every task asynchronously enough
(a real multi-second Claude call + a real tool-call round trip) that
`cancelTask`/`subscribeToTask` can be exercised against a task that is
*genuinely still running* — not just the terminal-task error path every
other reference agent here is limited to. It also genuinely wires
push-notification support (`capabilities.pushNotifications: true`, backed
by a real `InMemoryPushNotificationConfigStore` +
`BasePushNotificationSender`), which `helloworld` doesn't support at all.
Three local patches (see [`findings.md`](./findings.md) §1-3) make it run
on Claude and actually work; none of them are upstreamed.

## Prerequisites

- [`uv`](https://github.com/astral-sh/uv) package manager.
- An Anthropic API key with real (non-free-tier) billing — this repo's
  Gemini-based agents kept hitting free-tier quota walls; Claude sidesteps
  that entirely. See [`DEMO_GUIDE.md`](../../DEMO_GUIDE.md) §3's currency
  agent sections for the same key requirement and setup pattern.

## One-time local patches

Apply these three changes to your `a2a-samples` checkout before running —
they are not part of the sample as published. All three are also documented
with full reasoning in [`findings.md`](./findings.md).

1. **`pyproject.toml`** — add `langchain-anthropic>=0.3.0` to `dependencies`,
   then `uv sync`.
2. **`app/agent.py`** — add a third `model_source` branch:

   ```python
   from langchain_anthropic import ChatAnthropic
   # ...
   elif model_source == 'anthropic':
       # Sonnet 4.5, not a newer Opus — see findings.md §1: LangGraph's
       # response_format mechanism relies on assistant-message prefill,
       # which Claude Opus 4.6+ rejects outright.
       self.model = ChatAnthropic(model='claude-sonnet-4-5')
   ```

   Also fix the tool's stale API endpoint in the same file (findings.md §2):

   ```python
   # was: f'https://api.frankfurter.app/{currency_date}'
   #      params={'from': currency_from, 'to': currency_to}
   f'https://api.frankfurter.dev/v1/{currency_date}'
   # params={'base': currency_from, 'symbols': currency_to}
   ```
3. **`app/__main__.py`** — add the matching API-key check:

   ```python
   elif os.getenv('model_source') == 'anthropic':
       if not os.getenv('ANTHROPIC_API_KEY'):
           raise MissingAPIKeyError('ANTHROPIC_API_KEY environment variable not set.')
   ```
4. **`app/agent_executor.py`** — real cancellation support (findings.md §3
   has the full reasoning; the sample as published raises
   `UnsupportedOperationError` unconditionally). Track cancelled task IDs,
   check the flag mid-stream, *and* handle `asyncio.CancelledError`
   explicitly — the SDK hard-cancels the executor's coroutine directly, so
   catching only `Exception` never sees it:

   ```python
   import asyncio
   # ...
   def __init__(self):
       self.agent = CurrencyAgent()
       self._cancelled_tasks: set[str] = set()

   async def execute(self, context, event_queue):
       ...
       try:
           async for item in self.agent.stream(query, task.context_id):
               if task.id in self._cancelled_tasks:
                   await updater.update_status(TaskState.canceled, final=True)
                   return
               ...
       except asyncio.CancelledError:
           await updater.update_status(TaskState.canceled, final=True)
           raise
       except Exception as e:
           ...
       finally:
           self._cancelled_tasks.discard(task.id)

   async def cancel(self, context, event_queue):
       task = context.current_task
       if task is None:
           raise ServerError(error=UnsupportedOperationError())
       self._cancelled_tasks.add(task.id)
   ```

   Also, in `app/agent.py`'s `CurrencyAgent.stream()`: change
   `for item in self.graph.stream(...)` to
   `async for item in self.graph.astream(...)` — see findings.md §3 for why
   the synchronous form silently defeats cancellation entirely.

## Quick start

```bash
cd path/to/a2a-samples/samples/python/agents/langgraph
uv sync
model_source=anthropic ANTHROPIC_API_KEY=sk-ant-... uv run app
# Windows cmd.exe: set model_source=anthropic & set ANTHROPIC_API_KEY=sk-ant-... & uv run app
```

Listens on `http://localhost:10000` by default (`--port` to override).

## Using it with this repo

- **Card discovery**: `GET http://localhost:10000/.well-known/agent-card.json`
- **A2A endpoint**: `POST http://localhost:10000/`

**Like `adk_currency_agent`, this agent speaks A2A protocol v0.3, not
v1.0** (`a2a-sdk==0.3.0` pinned in its `uv.lock`) — `ballerina/a2a`'s
`Client` auto-detects and translates transparently, same as every other
v0.3 agent in this repo.

Run the interop tests against it:

```bash
# from repo root
set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
bal test --groups interop
```

Each conversion call makes a real Claude API call plus a live lookup
against the Frankfurter exchange-rate API — not a mock, and not free, though
inexpensive (a handful of cents for a full test run).
