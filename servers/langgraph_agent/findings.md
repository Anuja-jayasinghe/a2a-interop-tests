# langgraph currency agent reference server — interop findings

Testing `ballerina/a2a`'s `Client` against the LangGraph-based currency
conversion agent (`a2a-samples/samples/python/agents/langgraph`), modified
to run on Claude, closed the last major real-server gaps this repo had:
genuine in-flight `cancelTask`/`subscribeToTask` (every other reference
agent here processes tasks synchronously, so those operations could only
ever be tested against an already-terminal task), and genuine
push-notification config CRUD (`helloworld` doesn't declare the capability
at all). Getting there surfaced three real bugs in the sample agent itself
— none in `ballerina/a2a`'s client — plus one genuine spec non-conformance
in `a2a-sdk==0.3.0`. All verified empirically, both via direct JSON-RPC
probing and by running the real `ballerina/a2a` client against it
(`tests/langgraph_agent_interop_test.bal`).

## 1. LangGraph's structured-output mechanism breaks on Claude Opus 4.6+

The agent's `create_react_agent(..., response_format=(instruction,
ResponseFormat))` forces a final structured reply via an
assistant-message-prefill technique. Claude Opus 4.6 and later reject that
outright:

```
Error code: 400 - {'type': 'error', 'error': {'type': 'invalid_request_error',
'message': 'This model does not support assistant message prefill. The
conversation must end with a user message.'}}
```

This happened with `model='claude-opus-4-8'`. Confirmed against the model
migration notes: assistant prefill was removed starting with Opus 4.6 and
Sonnet 4.6. **Fix**: use `claude-sonnet-4-5` (the newest model that still
supports prefill) for this agent specifically — not a `ballerina/a2a` issue,
purely a LangGraph/model-generation compatibility question.

## 2. Stale Frankfurter API endpoint and parameter names

The tool's `get_exchange_rate` called `https://api.frankfurter.app/{date}`
with `{'from': ..., 'to': ...}` params. That domain now permanently
redirects (`301 Moved Permanently`), and `httpx.get()` doesn't follow
redirects by default — so the tool silently received an unusable response
instead of erroring, and the model gracefully (but incorrectly) reported
"technical difficulties accessing the exchange rate service."

```
INFO:httpx:HTTP Request: GET https://api.frankfurter.app/latest?from=USD&to=GBP "HTTP/1.1 301 Moved Permanently"
```

**Fix**: point at `https://api.frankfurter.dev/v1/{date}` with
`{'base': ..., 'symbols': ...}` params — the same domain and param names
`adk_currency_agent`'s tools already use. After the fix, real conversions
succeed:

```
INFO:httpx:HTTP Request: GET https://api.frankfurter.dev/v1/latest?base=USD&symbols=GBP "HTTP/1.1 200 OK"
```

```json
{"result": {"artifacts":[{"artifactId":"...", "name":"conversion_result",
"parts":[{"kind":"text","text":"The current exchange rate between USD and GBP is 1 USD = 0.7525 GBP (as of July 29, 2026)."}]}],
"status":{"state":"completed", ...}}}
```

## 3. Real in-flight cancellation needed two separate fixes

**3a. The executor blocked the entire event loop during each Claude/tool
call.** `CurrencyAgent.stream()` did `for item in self.graph.stream(...)`
— LangGraph's **synchronous** `.stream()` — inside an `async def`. Since
each step makes a real, several-second network call via a synchronous
HTTP client, the single-threaded asyncio event loop was fully blocked for
the duration of every step. A concurrent `tasks/cancel` HTTP request
physically could not be serviced until the whole task finished — proven by
racing a cancel against an in-flight task and watching it arrive (and get
logged) only *after* the task had already completed:

```
INFO:httpx:HTTP Request: POST https://api.anthropic.com/v1/messages "HTTP/1.1 200 OK"
INFO:httpx:HTTP Request: GET https://api.frankfurter.dev/v1/latest?base=USD&symbols=NOK "HTTP/1.1 200 OK"
INFO:httpx:HTTP Request: POST https://api.anthropic.com/v1/messages "HTTP/1.1 200 OK"
INFO:httpx:HTTP Request: POST https://api.anthropic.com/v1/messages "HTTP/1.1 200 OK"
INFO:app.agent_executor:Cancellation requested for task eb99fe68-fe21-4acd-810b-f0a0d057364f.
```

(the cancel log line arrives *last*, after every real network call the
task needed had already completed). **Fix**: switch to
`async for item in self.graph.astream(...)` so each step is genuinely
awaited, letting the event loop interleave the cancel request.

**3b. Even with the loop interleaving correctly, the cancelled task never
reached a terminal state.** `DefaultRequestHandler.on_cancel_task` (in
`a2a-sdk`) does two things: calls the executor's own `cancel()` method,
*and* directly calls `producer_task.cancel()` on the asyncio `Task` backing
the executor's `execute()` coroutine — a hard cancellation, not a
cooperative one. That interrupts whichever `await` the executor happened
to be in (usually mid network read to Anthropic), raising
`asyncio.CancelledError` *inside* `execute()`, immediately, regardless of
our own cooperative "check a flag between loop iterations" logic — which
never gets a turn to run:

```
  File ".../httpcore/_backends/anyio.py", line 35, in read
    return await self._stream.receive(max_bytes=max_bytes)
  ...
asyncio.exceptions.CancelledError
```

The task was left stuck at `TASK_STATE_SUBMITTED` forever — `cancel()` had
recorded the request, but no code path ever published a
`TASK_STATE_CANCELED` status update, because `except Exception` doesn't
catch `CancelledError` (it derives from `BaseException`, not `Exception`,
specifically so it isn't accidentally swallowed). **Fix**: add a dedicated
`except asyncio.CancelledError:` clause that publishes
`TASK_STATE_CANCELED` before re-raising. After both fixes, a genuine
in-flight cancel is reflected correctly and durably:

```json
// cancelTask response
{"result":{"status":{"state":"canceled", ...}, ...}}
// separate, later tasks/get — confirms it's persisted, not just the cancel response
{"result":{"status":{"state":"canceled", ...}, ...}}
```

And a genuine `subscribeToTask` against the same kind of still-running task
receives real, live `TASK_STATE_WORKING` updates — not a terminal-task
error, which is all `helloworld` can ever produce:

```json
{"result":{"kind":"status-update","status":{"state":"working", "message":{"parts":[{"text":"Looking up the exchange rates..."}]}}, ...}}
```

## 4. Genuine `INPUT_REQUIRED` and multi-turn continuation

Sending an incomplete request ("Convert 100 USD", no target currency)
genuinely produces a model-driven clarification, not a scripted one:

```json
{"result":{"status":{"state":"input-required",
"message":{"parts":[{"text":"I'd be happy to help you convert 100 USD! However, I need to know which currency you'd like to convert it to. ..."}]}}}}
```

Continuing with the same `taskId`/`contextId` and just `"EUR"` correctly
resumes and completes the *same* task:

```json
{"result":{"artifacts":[{"parts":[{"text":"I've converted 100 USD to EUR for you!\n\n**100 USD = 87.87 EUR**..."}]}],
"status":{"state":"completed"}}}
```

## 5. Genuine push-notification config CRUD — create/get/list succeed, delete surfaces a real `a2a-sdk` non-conformance

`createTaskPushNotificationConfig`, `getTaskPushNotificationConfig`, and
`listTaskPushNotificationConfigs` all work correctly against this agent's
real (non-short-circuited) push-notification store — the first genuine
success-path verification in this repo, since `helloworld` doesn't declare
the capability at all:

```json
// create
{"result":{"pushNotificationConfig":{"id":"0a305e07-...","url":"https://example.com/webhook"},"taskId":"0a305e07-..."}}
// get — same shape
// list
{"result":[{"pushNotificationConfig":{"id":"0a305e07-...","url":"..."},"taskId":"0a305e07-..."}]}
```

`deleteTaskPushNotificationConfig`, however, gets back:

```json
{"id":"5","jsonrpc":"2.0"}
```

— a response with **neither `result` nor `error`**, which is invalid per
JSON-RPC 2.0 (every response must carry exactly one of the two).
`ballerina/a2a`'s `Client` correctly rejects this as
`InvalidAgentResponseError` rather than silently treating it as success.
This is almost certainly `a2a-sdk==0.3.0`'s own response serialization
dropping `"result": null` entirely (a delete operation legitimately returns
nothing) via Pydantic's `exclude_none` behavior on serialization, rather
than encoding the explicit `null` a valid JSON-RPC success response
requires. **Not fixed here** — this is a real non-conformance in the
upstream reference SDK, and the client's strict rejection of it is the
correct, spec-compliant behavior, not a bug to route around.

## 6. Transient tool-call timeouts under concurrent load surface as `INPUT_REQUIRED`, not `FAILED`

Running the full interop suite (5 langgraph tests, each making a real
Claude + Frankfurter round trip, plus a preceding manual cancel demo against
the same server process) occasionally produced two unexpected failures:
`testLangGraphAgentSendMessage` and
`testLangGraphAgentInputRequiredThenMultiTurn` asserted
`TASK_STATE_COMPLETED` but got `TASK_STATE_INPUT_REQUIRED` for a plain,
unambiguous "What is the exchange rate between USD and GBP?" query.

Reproducing the exact request directly (bypassing the test framework)
showed the model's real reply was not a clarification at all:

```json
{"result":{"status":{"state":"input-required","message":{"parts":[{"text":
"I apologize, but I'm currently unable to retrieve the exchange rate
between USD and GBP due to a technical issue with the exchange rate
service (connection timeout). ..."}]}}}}
```

`get_exchange_rate`'s `httpx.get()` call had no explicit timeout (httpx's
bare 5s default applied) and no retry, so a transient delay against the
live Frankfurter API — plausible under the concurrent load of five real
tests hitting the same single-threaded event loop back to back — surfaced
as a tool error. Separately, `agent.py`'s `get_agent_response` maps
`ResponseFormat.status == 'error'` to the exact same `require_user_input:
True` branch as `'input_required'` (there's no distinct `TaskState.failed`
path in `agent_executor.py` either), so *any* transient tool failure is
indistinguishable from a genuine clarification request to the A2A client.
Direct probing (a single request, then 5 concurrent requests) against the
live Frankfurter API and through the agent both succeeded reliably outside
the full test run, confirming the API itself isn't unreliable — this is
about the tool call's own timeout/retry margin being too thin.

**Fix**: give `get_exchange_rate` an explicit 10s timeout and one retry
before giving up. Re-running the full interop suite afterward passed
cleanly (12 passing, 1 failing — the already-documented §5 delete
non-conformance, nothing else). The `status == 'error'` → `INPUT_REQUIRED`
mapping itself was left as-is — that's the sample's existing (if
debatable) design choice for how the agent recovers conversationally from
tool errors, not a bug introduced by this repo's patches, and not
something to route around here.

## 7. Confirmed via the real `ballerina/a2a` client, not just curl

`tests/langgraph_agent_interop_test.bal`, run with
`A2A_LANGGRAPH_AGENT_URL=http://localhost:10000`:

```
[pass] testLangGraphAgentSendMessage
[pass] testLangGraphAgentInputRequiredThenMultiTurn
[pass] testLangGraphAgentGenuineInFlightCancel
[pass] testLangGraphAgentGenuineInFlightSubscribe
[fail] testLangGraphAgentPushNotificationConfigCrud   -- fails at delete, per §5, on the agent's non-conformance, not the client

12 passing, 1 failing (of the full interop suite across all reference agents)
```
