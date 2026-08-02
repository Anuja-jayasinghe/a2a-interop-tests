# Dice Agent (multi-transport) reference server — setup

A Java/Quarkus agent from `a2a-samples`
(`samples/java/agents/dice_agent_multi_transport`), built on the A2A Java SDK
and LangChain4j. Not vendored into this repo — set it up from a checkout of
`a2a-samples` alongside this one, same as every other reference server here.

**Why this agent exists in the test matrix**: `FINDINGS.md` records that
`ballerina/a2a`'s REST (HTTP+JSON) and gRPC transport bindings were, until
now, **mock-verified only** — none of the three Python reference agents
(`helloworld`, `adk_currency_agent`, `langgraph`) advertise anything but a
`JSONRPC` interface. This is the agent that closes that gap: its
`AgentCard.supportedInterfaces` genuinely lists `GRPC`, `JSONRPC`, and
`HTTP+JSON`, all served from one Quarkus process on one port. It runs on
Claude (LangChain4j's Anthropic integration), matching this repo's existing
"one Anthropic key covers everything" pattern from `langgraph`/
`adk_currency_agent`.

Two local patches (see [`findings.md`](./findings.md) §1-2) make it publish
a spec-correct agent card and run on Claude; neither is upstreamed.

## Prerequisites

- **JDK 17+** and **Maven** (this repo's own checkout was set up with a
  portable Temurin 21 + Maven 3.9.16 extract — no system-wide install
  required; see §5 if you hit the same "no Java/Maven on PATH" situation).
- **An Anthropic API key** — same `ANTHROPIC_API_KEY` env var this repo
  already uses for `langgraph`/`adk_currency_agent`.

## One-time local patches

Apply these to your `a2a-samples` checkout's
`samples/java/agents/dice_agent_multi_transport/` directory before running.
Full reasoning in [`findings.md`](./findings.md) §1-2.

1. **Upgrade the A2A SDK from `io.github.a2asdk:0.3.2.Final` to
   `org.a2aproject.sdk:1.1.0.Final`** across `server/pom.xml`,
   `client/pom.xml`, and the parent `samples/java/agents/pom.xml` (which
   also needs `protobuf.version` bumped from `4.31.1` to `4.34.2` — the
   1.1.0.Final gRPC stubs are gencode'd against a newer protobuf runtime).
   The pinned `0.3.2.Final` SDK's `AgentCard.Builder` only ever emits the
   legacy `additionalInterfaces` field, never the spec-required
   `supportedInterfaces` — see findings.md §1 for the full wire evidence and
   why this genuinely blocks `ballerina/a2a`'s own transport discovery, not
   just TCK conformance.
   - This is a real package/API migration, not just a version bump:
     `io.a2a.*` → `org.a2aproject.sdk.*`, `new AgentCard.Builder()` →
     `AgentCard.builder()`, `EventQueue`/`TaskUpdater` → `AgentEmitter`,
     `JSONRPCError` → `A2AError`, `TaskState.CANCELED` →
     `TaskState.TASK_STATE_CANCELED`. See the diff in this repo's copy of
     `DiceAgentCardProducer.java`/`DiceAgentExecutorProducer.java`/
     `TestClient.java` for the exact before/after (not vendored here, but
     the same changes apply 1:1 to a fresh `a2a-samples` checkout).
2. **Swap the LLM backend from Gemini to Claude** in `server/pom.xml` and
   `server/src/main/resources/application.properties`:
   - Replace the `quarkus-langchain4j-ai-gemini` dependency with
     `quarkus-langchain4j-anthropic` (same `quarkus.langchain4j.version`).
   - Replace the Gemini config block with:
     ```properties
     quarkus.langchain4j.anthropic.api-key=${ANTHROPIC_API_KEY:}
     quarkus.langchain4j.anthropic.timeout=40000
     quarkus.langchain4j.anthropic.chat-model.model-name=claude-sonnet-4-5
     ```
   - No change needed to `DiceAgent.java` itself — LangChain4j's
     `@RegisterAiService` picks up whichever chat-model extension is on the
     classpath automatically.
3. **Add the REST reference module** to `server/pom.xml`
   (`a2a-java-sdk-reference-rest`, same `${a2a.sdk.v1.version}`) and add a
   third `AgentInterface` (`TransportProtocol.HTTP_JSON`) to
   `DiceAgentCardProducer.java`'s `supportedInterfaces` list — the sample as
   published only advertises `GRPC`+`JSONRPC`.
4. *(Optional, cosmetic)* `client/pom.xml`'s `exec-maven-plugin` config has a
   real bug — `<mainClass>com.samples.a2a.TestClient</mainClass>` is missing
   the `.client.` package segment the class actually lives in
   (`com.samples.a2a.client.TestClient`). Fix it if you want
   `mvn exec:java` to work without an explicit `-Dexec.mainClass` override.

## Quick start

```bash
cd path/to/a2a-samples/samples/java/agents/dice_agent_multi_transport/server
set ANTHROPIC_API_KEY=sk-ant-...
mvn quarkus:dev
```

Listens on `http://localhost:11000` by default (`-Dquarkus.http.port=...`
to override) — gRPC and HTTP share the one port
(`quarkus.grpc.server.use-separate-server=false`).

## Using it with this repo

- **Card discovery**: `GET http://localhost:11000/.well-known/agent-card.json`
  — confirm `supportedInterfaces` lists all three of `GRPC`, `JSONRPC`, and
  `HTTP+JSON` before trusting any test result against this agent (that field
  is the actual thing this agent exists to prove; see findings.md §1).
- **JSON-RPC endpoint**: `POST http://localhost:11000/`
- **REST endpoint**: `POST http://localhost:11000/v1/message:send` (and the
  rest of the `/v1/...` surface — see findings.md §3 for its proto-JSON
  request shape, which differs from the JSON-RPC endpoint's).
- **gRPC endpoint**: `localhost:11000`, plaintext (no TLS in dev mode).

This agent speaks A2A protocol **v1.0** (`protocolVersion: "1.0"` on every
`supportedInterfaces` entry) — `ballerina/a2a`'s `Client` needs no v0.3
compatibility handling here, unlike `adk_currency_agent`/`langgraph`.

Run the interop tests against it:

```bash
# from repo root
set A2A_DICE_AGENT_URL=http://localhost:11000
bal test --groups interop
```

Each call makes a real Claude API call — not a mock, and not free, though
inexpensive (dice-roll/prime-check questions are short).

## A note on this session's verification

This agent was verified end-to-end in this repo's own environment using a
**placeholder** `ANTHROPIC_API_KEY`, deliberately, to confirm the plumbing
without spending real API credits: all three transports (gRPC via the
sample's own `TestClient`, JSON-RPC and REST via raw `curl`) correctly
parsed the request, created a task, and reached a genuine
`401 Unauthorized` from Anthropic's own API — proving the request pipeline
is correct up to the LLM call boundary on every transport. Swap in a real
key to see actual dice-roll/prime-check responses; see findings.md §4 for
the exact evidence from this session.
