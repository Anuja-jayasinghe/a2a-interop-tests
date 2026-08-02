# A2A spec compliance audit & wrap-up plan

Full audit of `ballerina/a2a` (`https://github.com/Anuja-jayasinghe/a2a-ballerina/tree/main/a2a`) against
the official A2A protocol specification (https://a2a-protocol.org/latest/specification/,
current release v1.0.0), done from the outside — real reference servers, the published
spec, and the library's own source — not from the library's internal docs alone.
Goal: identify what's non-conformant or missing, and lay out what's left before a
Ballerina developer can pick this library up and (a) call other A2A agents, and
(b) expose their own agent as A2A-compatible, both with confidence.

## Scope for this round

Current phase is client-only, deliberately: get the client rock-solid and give
developers a reliable way to discover and call other A2A agents before starting on the
server/listener side (which lets a Ballerina program *be* an A2A agent). That's real,
separate, future work — not covered here.

Everything below is a client-side conformance/completeness audit.

## 1. JSON-RPC method coverage — all 11 spec operations (spec §9.4)

| Spec method | Client method | Status |
|---|---|---|
| SendMessage | `sendMessage` (client.bal:236) | ✅ v1.0 + v0.3 |
| SendStreamingMessage | `sendMessageStream` (client.bal:356) | ✅ v1.0 + v0.3 |
| GetTask | `getTask` (client.bal:392) | ✅ v1.0 + v0.3 |
| CancelTask | `cancelTask` (client.bal:421) | ✅ v1.0 + v0.3 |
| SubscribeToTask | `subscribeToTask` (client.bal:455) | ✅ v1.0 + v0.3 |
| ListTasks | `listTasks` (client.bal:480) | ✅ v1.0; v0.3 has no wire equivalent, so the client raises a client-side `VersionNotSupportedError` instead of guessing — correct behavior, confirmed against the `a2a-sdk` migration table |
| CreateTaskPushNotificationConfig | `createTaskPushNotificationConfig` (client.bal:540) | ✅ v1.0 + v0.3 |
| GetTaskPushNotificationConfig | `getTaskPushNotificationConfig` (client.bal:567) | ✅ v1.0 + v0.3 |
| ListTaskPushNotificationConfigs | `listTaskPushNotificationConfigs` (client.bal:599) | ✅ v1.0 + v0.3 |
| DeleteTaskPushNotificationConfig | `deleteTaskPushNotificationConfig` (client.bal:640) | ✅ v1.0 + v0.3 |
| GetExtendedAgentCard | `getExtendedAgentCard` (client.bal:673) | ✅ v1.0 + v0.3 |

All 11 methods exist. This closes out what used to be a real gap: git history shows only
5 of 11 existed before `feature/a2a-remaining-operations` (PR #5) and
`feature/security-scheme-typing` (PR #6). Per-operation *live-server test* status (as
opposed to "does the code exist") is already tracked accurately in this repo's
`CLIENT_TEST_COVERAGE.md` — see that file rather than duplicating it here.

**Not JSON-RPC-only despite the table header** — every method above is reachable over
all three spec §5 transport bindings (`Client.init`'s `binding` param:
`"JSONRPC"`/`"HTTP+JSON"`/`"GRPC"`), not just JSON-RPC. `sendMessage` and
`sendMessageStream` are confirmed passing over all three against a real server
(`servers/dice_agent/`, see `CLIENT_TEST_COVERAGE.md` row 14); the other 9 methods are
confirmed passing over JSON-RPC only so far — the transport binding itself is
protocol-agnostic (same request/response encoding logic regardless of method), so this is
a coverage-breadth gap, not a suspected functional one.

## 2. Data model vs. spec

- `Task`, `TaskStatus`, `Message`, `Part`, `Artifact`, `TaskStatusUpdateEvent`,
  `TaskArtifactUpdateEvent`, `StreamResponse`, `SendMessageResult`, `TaskState` (all 9
  values incl. `AUTH_REQUIRED`), `Role` — field names and required/optional-ness match
  the spec.
- `SecurityScheme` discriminated union (API key / HTTP auth / OAuth2 / OpenID Connect /
  mTLS), `OAuthFlows`, `SecurityRequirement`, `AgentCardSignature` — fully typed as of
  PR #6, cross-checked against the installed `a2a-sdk 0.3.23` Python reference
  implementation as the tie-breaker source (the spec's own HTML page renders lossily
  through automated fetching — a real quirk of the spec site, not a library defect;
  the design doc's methodology of verifying against `a2a.proto` directly is the right
  call here).
- **One genuinely open, previously-flagged item** (not new — see `REPO_MAP.md` §6):
  whether `Message.referenceTaskIds`/`extensions` and `Artifact.extensions` use identical
  field names on the wire in v0.3. No reference agent in this repo exercises cross-task
  references or extensions, so this can't be closed without a fourth reference server (or
  a synthetic/mock one built specifically to exercise it).

## 3. Error codes (errors.bal) — complete

All 9 spec-defined A2A error codes (-32001…-32009: `TaskNotFound`, `TaskNotCancelable`,
`PushNotificationNotSupported`, `UnsupportedOperation`, `ContentTypeNotSupported`,
`InvalidAgentResponse`, `ExtendedAgentCardNotConfigured`, `ExtensionSupportRequired`,
`VersionNotSupported`) map 1:1 to typed `A2AError` subtypes, with an `A2AInternalError`
fallback that preserves the original code for anything unrecognized. No gaps.

## 4. Confirmed client-side gaps (the library's own design doc is honest about these — §12.1)

1. **`A2A-Extensions` header not implemented at all.** Extension negotiation
   (advertise/request via that header) is a real spec mechanism with zero code behind it.
2. ~~**JSON-RPC only — no gRPC or REST transport binding.**~~ **Resolved.**
   `Client.init`'s `binding` parameter now speaks all three (`"JSONRPC"`,
   `"HTTP+JSON"`, `"GRPC"`), satisfying spec §5's functional-equivalence
   requirement, and all three are verified end-to-end against a real
   server (`servers/dice_agent/`) — see punch-list item 2 below and
   `servers/dice_agent/findings.md` for the full evidence.
3. **AgentCard signature (JWS) is captured but never cryptographically verified.** A
   forged/compromised card would go undetected. Explicitly deferred pending a security
   review.
4. **No AgentCard caching** — `resolveAgentCard` re-fetches every call, ignoring HTTP
   cache headers. Low severity.
5. **No automatic SSE reconnection** — `subscribeToTask` supports manual reconnect, but
   the client won't detect a dropped stream and retry on its own.
6. **No automatic client-auth wiring from a parsed AgentCard** — a developer has to read
   `card.securitySchemes` themselves and hand-build `http:ClientConfiguration.auth`; no
   helper goes scheme → working auth config automatically.
7. **mTLS is a reserved-but-stubbed interface** — explicitly "out of scope, needs a
   security review before implementing" per the design doc.

## 5. Test coverage gaps (already tracked in `CLIENT_TEST_COVERAGE.md` — listed here only for completeness, don't re-derive)

`listTasks` filtering/pagination untested live; `deleteTaskPushNotificationConfig`
success path blocked by a real `a2a-sdk==0.3.0` server-side bug (not a client bug);
`tenant` param untested live; non-text `Part` variants (file/data) untested;
`Message.referenceTaskIds`/`extensions`, `Artifact.extensions` untested; `FAILED`/
`REJECTED`/`AUTH_REQUIRED` states never exercised against a live server.

## 6. Documentation gap

`A2A_Technical_Design.md` appends a large superseded draft (the listener/service design,
skills-authoring guide, worked weather-agent example) below the current, correct client
design. It's marked `⚠️ SUPERSEDED` but a new contributor skimming top-to-bottom could
still copy dead/incorrect patterns from it (it contains field names the doc itself flags
as wrong, e.g. a phantom `TaskArtifactUpdateEvent.index`). Purely an organizational issue
— worth deleting or moving to an archive file, not a code defect.

## Client-hardening punch list (this round's scope)

Ranked by how much each blocks a developer trusting this client to reliably discover and
call other A2A agents in production:

1. **`A2A-Extensions` header support** — real spec mechanism (advertise/request via the
   header), currently zero code.
2. **REST and gRPC transport bindings — closed.** Client-side code for both exists
   (`Client.init`'s `binding` parameter accepts `"HTTP+JSON"`/`"GRPC"`; spec §5's
   functional-equivalence requirement is implemented), and what was missing — a real,
   independently-built REST/gRPC-serving agent to test against, rather than only mocks —
   is now `servers/dice_agent/` (Java/Quarkus, on Claude); see `FINDINGS.md`'s coverage-gap
   sections and `servers/dice_agent/findings.md` for full status. `ballerina/a2a`'s real
   `Client` confirmed passing end-to-end over all three transports against this agent, with
   a real Anthropic key and genuine dice-roll/prime-check responses
   (`bal test --sticky --groups interop`, 3/3 passing). No longer mock-only.
3. **AgentCard signature (JWS) verification** — captured (`AgentCardSignature`,
   `types.bal:503`), never cryptographically verified. A forged/compromised card would go
   undetected.
4. **Automatic client-auth wiring from `AgentCard.securitySchemes`** — a developer
   currently has to read `card.securitySchemes` (`types.bal:159`) themselves and
   hand-build `http:ClientConfiguration.auth`; no helper goes scheme → working auth
   config automatically.
5. **Automatic SSE reconnection** — `subscribeToTask`/`sendMessageStream` support manual
   reconnect only; the client won't detect a dropped stream and retry itself.
6. **AgentCard caching** — `resolveAgentCard` re-fetches every call, ignoring HTTP cache
   headers.
7. **Close the achievable test-coverage gaps** (§5) — the ones that don't require a live
   third-party server: file/data `Part` variant round-tripping, `FAILED`/`REJECTED`/
   `AUTH_REQUIRED` state handling, `listTasks` filter-parameter encoding. (`listTasks`
   live pagination, `tenant` live, and the delete-push-config success path stay blocked on
   external servers — out of scope for this round.)
8. **Clean up `A2A_Technical_Design.md`** — remove/archive the superseded
   listener/service draft so new contributors can't mistake it for current guidance.

## Bottom line

Client-side, against the official spec: solid. All 11 operations exist over all three
transport bindings the spec requires (JSON-RPC/REST/gRPC), the data model and error codes
are complete and correctly typed, and the v0.3 legacy dialect is handled transparently.
The gaps that remain (#1, #3-8 above — #2 is now closed) are real but are
hardening/completeness work on an already-working client, not missing core
functionality. See `docs/superpowers/plans/2026-07-30-client-hardening.md` in
`a2a-ballerina` for the task breakdown to close them.

Server/listener support (letting a Ballerina program *be* an A2A agent) is intentionally
out of scope for this round and will be scoped separately once the client above is done.
