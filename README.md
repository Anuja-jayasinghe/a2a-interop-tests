# a2a-interop-tests

Cross-agent interoperability testing and demo work for `ballerina/a2a`,
run against real third-party A2A servers rather than mocks.

## Relationship to other repos

- **`a2a-ballerina`** — the library itself. This repo consumes
  `ballerina/a2a` as a real external package, published to the local
  Ballerina package repository (`bal pack && bal push
  --repository=local` from `a2a-ballerina`), not by copying or
  importing its source. That's deliberate: if the interop tests or demo
  can't run against a packed, external `ballerina/a2a`, that's itself a
  finding about the library's public API.
- **`a2a-samples`** — vendored reference server implementations (Python,
  Go, etc.), maintained upstream. Not copied into this repo — each
  agent's `servers/<agent>/setup.md` here has the real, verified
  instructions for standing one up locally from a checkout of
  `a2a-samples`.

## Layout

- **[`REPO_MAP.md`](REPO_MAP.md)** — full guide to how this repo and
  `a2a-ballerina` relate, what's in each, and how the client's A2A v0.3
  compatibility actually works end to end. Read this for orientation.
- **[`DEMO_GUIDE.md`](DEMO_GUIDE.md)** — start here to actually run and
  demo this repo's scenario end to end: setting up both reference agents,
  running the real interop tests, running the interactive demo, and a
  suggested narrative for presenting it.
- `tests/` — the interop test suite (Ballerina project at repo root),
  run with a real server via `A2A_TEST_SERVER_URL`.
- `demo/` — an interactive, watchable walkthrough of the `Client` against
  a real server (own Ballerina project). The raw-protocol view: a human
  drives `a2a:Client` directly.
- `demo_agent/` — the headline demo: a real client-side A2A agent that
  reasons about a question, discovers and selects another agent via the
  spec's own mechanism, delegates to it, and presents both the remote
  reply and its own synthesized answer (own Ballerina project, see
  `demo_agent/README.md`).
- `servers/<agent>/` — per-agent `setup.md` (how to run it) and
  `findings.md` (spec non-conformances found, and how the client works
  around them).
- `FINDINGS.md` — master index across all agents tested so far.
- `LEARNING_LOG.md` — interop-specific lessons (not a duplicate of
  `a2a-ballerina`'s own learning log).

## Workflow

Nothing is committed directly to `main`. Each agent (or unit of work)
gets its own branch, pushed and opened as a PR for review — same
standing practice as `a2a-ballerina`.
