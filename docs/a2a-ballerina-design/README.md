# a2a-ballerina design history

Design documentation and build history for the [`a2a-ballerina`](https://github.com/Anuja-jayasinghe/a2a-ballerina)
client library, moved here to keep it out of that package's own release
surface (see its `docs/` folder for the two current, shipped docs:
`A2A_Technical_Design.md`'s successor content and `API_PROVENANCE.md` now
live only here going forward). Kept separate from this repo's own
top-level `docs/` files, which document `a2a-interop-tests` itself.

- `A2A_Technical_Design.md` — the library's full technical design: data
  model, client methods, transport layer, error mapping, known-gaps list.
- `API_PROVENANCE.md` — classifies every public symbol in `ballerina/a2a`
  as spec-mandated, borrowed from a reference SDK convention, or invented,
  with the justification for the latter two.
- `LEARNING_LOG.md` — accumulated lessons from building the library.
- `archive/` — superseded design drafts, kept for historical reference
  only; each is explicitly marked "do not implement from this."
- `superpowers/plans/`, `superpowers/specs/` — the phase-by-phase
  implementation plans and design specs written while building each
  feature (v0.3 compat, REST/gRPC bindings, security-scheme typing,
  client hardening, the per-transport client split).
