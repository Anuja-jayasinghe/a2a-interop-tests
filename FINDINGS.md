# FINDINGS

Master index of agents tested so far. One line per agent, linking to its
full writeup.

| Agent | Language | Findings |
| :---- | :---- | :---- |
| helloworld | Python (`a2a-samples/samples/python/agents/helloworld`) | [servers/helloworld/findings.md](servers/helloworld/findings.md) — AgentCard.url omitted, PascalCase JSON-RPC methods, wrapped SendMessage response, subscribeToTask's two-fold non-conformance on terminal tasks |
| adk_currency_agent | Python/ADK (`a2a-samples/samples/python/agents/adk_currency_agent`) | [servers/adk_currency_agent/findings.md](servers/adk_currency_agent/findings.md) — genuinely speaks A2A protocol v0.3, not v1.0: legacy method names, unwrapped responses, lowercase enums. Motivated `ballerina/a2a`'s v0.3 client-compatibility work |
| langgraph currency agent | Python/LangGraph, on Claude (`a2a-samples/samples/python/agents/langgraph`) | [servers/langgraph_agent/findings.md](servers/langgraph_agent/findings.md) — first agent to genuinely exercise in-flight `cancelTask`/`subscribeToTask` and real push-notification CRUD (create/get/list); surfaced a real `a2a-sdk==0.3.0` JSON-RPC non-conformance on delete, plus three local bugs (Claude prefill incompatibility, a stale Frankfurter endpoint, and a blocking-event-loop cancellation bug) fixed in the sample itself |
