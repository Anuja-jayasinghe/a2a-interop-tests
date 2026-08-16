# demo_agent

A real client-side A2A agent, built on `ballerina/a2a`. Given a question,
it decides for itself whether it can answer from general knowledge or
needs to delegate; if it delegates, it **discovers** candidate agents
using the spec's well-known URI mechanism, reads their Agent Cards,
reasons over their declared skills to pick one, hands the question over,
and presents both the remote agent's verbatim reply and its own
synthesized answer, clearly labeled and separated.

This is the headline demo — the actual A2A use case (an agent reaching
another agent). `../demo/` stays as the low-level protocol walkthrough: it
drives `a2a:Client` directly from a human-typed line, showing what raw
`sendMessage`/`sendStreamingMessage` usage looks like. `demo_agent/` is
what user code against this library looks like when an agent, not a
human, is the one deciding what to send and to whom.

## What it demonstrates

```
question
   │
   ├─► [1] SELF-ASSESS  (Claude)         -- can this be answered locally?
   ├─► [2] DISCOVER     (spec §8.2)      -- well-known URI card resolution
   ├─► [3] SELECT       (Claude)         -- match declared skills to the question
   ├─► [4] DELEGATE     (a2a, streaming) -- sendStreamingMessage, live events
   └─► [5] PRESENT                       -- verbatim reply + synthesized answer
```

Every step prints what it's doing and why — the reasoning trace is the
demo, not an afterthought. See `DEMO_AGENT_PLAN.md` (this repo's `docs/`)
for the full design rationale, including exactly which parts of the flow
are A2A spec mechanism versus this demo's own policy (§4).

**Discovery is genuinely spec-backed, and says so.** The candidate pool
(a hardcoded set of base URLs) is the spec's *Direct Configuration*
bullet (§8.2) — the spec defines no registry wire protocol, so this is
labeled as configuration, not a spec mechanism. Resolving each
candidate's Agent Card via `a2a:resolveAgentCard` **is** the spec's
Well-Known URI mechanism. Matching the question against the returned
cards' declared skills is this demo's own policy, enabled but not
prescribed by the spec's `AgentSkill` fields.

**Multi-turn clarification is real, not staged.** If a remote agent ends
a turn in `TASK_STATE_INPUT_REQUIRED` (a genuine model-driven request for
missing information), the demo continues the same task/context rather
than starting over. In interactive mode, it prompts you for the missing
detail. In scripted mode, no user is available, so Claude tries to infer
the missing detail from the original question alone — and honestly
declines (aborting that scenario, not guessing) when the question
genuinely doesn't contain enough information to infer it.

## Prerequisites

- `ballerina/a2a` published to the local package repository (see
  `../demo/README.md`'s prerequisites — same command, same version).
- `ANTHROPIC_API_KEY` set in your environment — this demo calls the
  Anthropic Messages API directly over `ballerina/http` (no
  `ballerinax/ai` dependency; see `docs/DEMO_AGENT_PLAN.md` §6.8 for why).
- At least one reference agent running, so there's something to
  discover and delegate to. See `../servers/*/setup.md` for each of the
  four:

  | Agent | Port |
  | :--- | :--- |
  | `helloworld` | 9999 |
  | `adk_currency_agent` | 10999 |
  | `langgraph` (currency agent) | 10000 |
  | `dice_agent` | 11000 |

  You don't need all four — `dice_agent` plus one currency agent is
  enough to see delegation, skill-based routing, and multi-turn
  clarification. Discovery skips unreachable candidates gracefully and
  prints `[unreachable]` for each.

## Running it

Two commands, one package — both share the same agent logic:

```bash
cd demo_agent

# Interactive -- type your own questions, 'quit' to exit
bal run --sticky

# Scripted -- runs six fixed scenarios unattended, then exits
bal run --sticky -- scripted
```

`--sticky` matters: without it, dependency resolution can drift onto an
`http` version binary-incompatible with `ballerina/grpc`'s compiled Java
code (see `http_version_pin.bal`'s comment for the full landmine).

The six scripted scenarios (grounded in each agent's real declared
skills — see `docs/DEMO_AGENT_PLAN.md` §6.6):

| # | Question | Expected path |
| :--- | :--- | :--- |
| 1 | "What is the capital of France?" | self-answer, no delegation |
| 2 | "Is 97 a prime number?" | → Dice Agent, `prime_checker` |
| 3 | "Roll a 20-sided die." | → Dice Agent, `dice_roller` |
| 4 | "What is 100 USD in EUR?" | → a currency agent |
| 5 | "Book me a flight to Tokyo." | no suitable agent, said honestly |
| 6 | "Convert 100 dollars." | → currency agent → clarification round-trip |

## Files

| File | Purpose |
| :--- | :--- |
| `Ballerina.toml` | package manifest |
| `http_version_pin.bal` | forces a direct `http` import so the version pin holds (see above) |
| `main.bal` | entry point, mode dispatch, interactive loop, the shared `handleQuestion` flow |
| `scripted.bal` | the six-scenario unattended run |
| `reasoning.bal` | the four Claude calls: self-assess, select, synthesize, answer-clarification |
| `discovery.bal` | candidate pool + well-known URI discovery + skill catalog |
| `delegation.bal` | builds `a2a:Client`, streams the request, handles `INPUT_REQUIRED` |

Split by responsibility rather than one large `main.bal` on purpose —
this layout is itself part of the showcase for what user code against
`ballerina/a2a` looks like.
