# Stakeholder demo — presentation script & runbook

A live-presentation script for a non-technical audience: people who know
what "A2A" (Agent2Agent protocol) means conceptually, but have never seen
this client work. Assume zero Ballerina/protocol-internals knowledge. No
slide full of test output — every beat is either a live conversation or a
plain-English before/after. For the technical run-it-yourself instructions
this script assumes, see [`DEMO_GUIDE.md`](DEMO_GUIDE.md).

**Total time**: ~15-18 min live + buffer for questions.

---

## The one-sentence pitch (say this first, verbatim-ish)

> "A2A lets AI agents built by completely different teams, in completely
> different languages, talk to each other over a shared protocol. What
> we've built is a Ballerina client for that protocol — and I'm going to
> prove it actually works, live, against real agents we didn't build,
> speaking three different 'dialects' of the wire format, not just the one
> that was easiest."

Everything below is in service of proving that sentence, piece by piece,
live.

---

## Beat 1 — "It's a real conversation" (4 min)

**Goal**: make the abstraction concrete before anything else. Non-technical
people connect with *a chat*, not a protocol diagram.

**Setup beforehand**: `langgraph` currency agent running on `:10000` with a
real Anthropic key (this is the richest agent — genuine multi-turn).
`demo/main.bal` defaults to this agent already (no env var needed).

**Do this**:
```
cd demo
bal run --sticky
```
Let it run through the scripted `sendMessage`/`sendStreamingMessage` steps,
then when it drops into the interactive loop, **type live, in front of
them**, as two separate lines:
```
Convert 100 dollars
```
The agent will genuinely ask which currency — a real, model-driven
clarification, not scripted. Then type:
```
to euros
```
and it correctly resumes the *same* conversation and gives the real
converted amount. Rehearsed and confirmed working live — exact transcript:
```
> Convert 100 dollars
  [status] TASK_STATE_INPUT_REQUIRED
> to euros
  [artifact] Based on the latest exchange rate (as of July 31, 2026):
  **100 USD = 87.07 EUR**
  [status] TASK_STATE_COMPLETED
```

**Say**: "This isn't a script replaying canned text — it's a live call to
Claude and a live currency lookup, going through our client to a real
agent someone else built entirely in Python. Watch — I'll leave out the
currency on purpose." *(type "Convert 100 dollars")* "...and it asks me,
just like a person would." *(type "to euros")* "...and it remembers what
we were talking about."

**Do not** explain JSON-RPC, tasks, or streaming here. Just let it talk.

---

## Beat 2 — "Same client, different agent, zero code changes" (3 min)

**Goal**: the interoperability promise — this isn't hand-tuned to one
partner.

**Say**: "Now watch — I'm going to point the exact same program at a
*completely different* agent, one that doesn't even speak the same version
of the protocol under the hood, and change nothing but one line."

**Do this**: quit the demo (`quit`), then instead of editing the file, just
set the override env var live (faster, no editor needed) and run again:
```
set A2A_DEMO_SERVER_URL=http://localhost:10999
bal run --sticky
```
Type live: `What is the exchange rate between USD and GBP?` — rehearsed and
confirmed working, real answer: `"The current exchange rate is 1 USD =
0.74508 GBP (as of 2026-07-31)."` Point out out loud: "Same code path — the
client detected it was talking to an older dialect and translated
automatically. I didn't have to know that in advance and neither did you."
Then unset the override before Beat 3: `set A2A_DEMO_SERVER_URL=`

*(If time is short, skip this beat — Beat 1 already lands the core point.
Keep it if the room seems engaged and wants "prove it's not one-off.")*

---

## Beat 3 — "Same message, three different technical roads" (6-7 min) — the centerpiece

**Goal**: this is the actual news — REST and gRPC now genuinely work, not
just JSON-RPC. Explained without the words "REST" or "gRPC" doing any
heavy lifting on their own.

**Say, as framing** (use a plain analogy, not protocol names first):

> "Every agent publishes an address, but there isn't just one way to
> physically reach it — think phone call vs. text vs. email: different
> channel, same person on the other end, same conversation possible on
> any of them. Most agents out there only answer one of these channels.
> We built one — this dice-rolling agent — that answers all three, and
> I'm going to send it the exact same request three different ways and
> show you the client handles all of them, live, with real answers each
> time."

**Pre-req**: `dice_agent` running (`:11000`) with the real key,
`A2A_DICE_AGENT_URL=http://localhost:11000` set.

**Live action — three short, visibly-distinct moments**, not a test run:

1. **Show the agent's "business card"** — `curl
   http://localhost:11000/.well-known/agent-card.json` (or open it in a
   browser tab pre-loaded). Point at the three entries under
   `supportedInterfaces`: `GRPC`, `JSONRPC`, `HTTP+JSON`. Say: "This is the
   agent telling the world 'reach me any of these three ways.'"
2. **Run the tri-transport demo**:
   ```
   cd demo_tri_transport
   set A2A_DICE_AGENT_URL=http://localhost:11000
   bal run --sticky
   ```
   It sends `"Can you roll a 6-sided die?"` over gRPC, then JSON-RPC, then
   REST, printing each real result clearly labeled. Built and rehearsed,
   confirmed working — real transcript:
   ```
   Sending the same request to the same agent, three different technical ways:
     "Can you roll a 6-sided die?"

     [gRPC     ] -> You rolled a **5**!
     [JSON-RPC ] -> You rolled a **5**!
     [REST     ] -> You rolled a **2**!

   Same client, same agent, same question -- three different wire protocols, all working.
   ```
   Real, independently-rolled dice each time (proves it's not
   cached/faked) — call this out explicitly if the numbers differ, which
   they usually will.
3. **Say the payoff line**: "Until recently, if an agent only spoke one of
   these three, our client simply couldn't reach it. Now it can reach all
   three, and we've proven that against a real server, not just our own
   test mocks."

*(If someone asks "why does this matter" — one line, ready: "Because we
don't control which of the three formats a partner's agent will speak.
Now it doesn't matter.")*

---

## Beat 4 — "We didn't just build it, we broke it on purpose" (2 min, optional/if time)

**Goal**: credibility — shows rigor, not just a demo that happens to work.

**Say**: "Getting here wasn't just writing code and hoping — we tested
against agents nobody on this team built, in Python and Java, from
different vendors, and that process found real bugs. Some in our client,
some in *their* servers." Give one concrete, retellable example, e.g.:

> "One reference agent's own SDK had a bug where deleting a
> notification setting returned a technically-invalid response — our
> client correctly caught that and refused to silently treat it as
> success. That's the kind of thing you only find by testing against the
> real world, not your own assumptions."

Keep this to one anecdote. Do not open `FINDINGS.md` live — too much text,
kills momentum. Mention it exists as a paper trail if anyone wants depth
after.

---

## Close (1 min)

> "So: real conversations, with real agents we didn't build, over every
> technical channel an agent might use to answer — verified, not assumed.
> Happy to go deeper with anyone after, or take questions now."

---

## Before you present — final checklist

1. **Start all four servers fresh**, with real keys, in their own
   terminals, and confirm each with a quick agent-card `curl` before
   walking in:
   - `helloworld` — `cd path/to/a2a-samples/samples/python/agents/helloworld && python __main__.py` (port `9999`, no key needed)
   - `adk_currency_agent` — per `servers/adk_currency_agent/setup.md` (port `10999`)
   - `langgraph` — per `servers/langgraph_agent/setup.md` (port `10000`)
   - `dice_agent` — `cd path/to/a2a-samples/samples/java/agents/dice_agent_multi_transport/server && set ANTHROPIC_API_KEY=... && mvn quarkus:dev` (port `11000`)
2. **One more full dry run**, start to finish, on the actual
   machine/screen/projector you'll present from — terminal fonts and
   projector color contrast can hide bugs a laptop screen doesn't.
3. **Terminal font size** — bump it before starting; back row needs to
   read it.
4. **Close background noise** — no other `bal test` windows with old
   stack traces visible, no leftover terminal clutter.
5. **Know the two commands by heart**:
   - Beat 1/2: `cd demo && bal run --sticky` (optionally
     `set A2A_DEMO_SERVER_URL=...` first for Beat 2)
   - Beat 3: `cd demo_tri_transport && set A2A_DICE_AGENT_URL=http://localhost:11000 && bal run --sticky`
