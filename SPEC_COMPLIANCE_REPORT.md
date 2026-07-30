# A2A spec compliance audit & wrap-up plan

Full audit of `ballerina/a2a` (`C:\gitProject\A2A_Project\a2a-ballerina\a2a`) against
the official A2A protocol specification (https://a2a-protocol.org/latest/specification/,
current release v1.0.0), done from the outside — real reference servers, the published
spec, and the library's own source — not from the library's internal docs alone.
Goal: identify what's non-conformant or missing, and lay out what's left before a
Ballerina developer can pick this library up and (a) call other A2A agents, and
(b) expose their own agent as A2A-compatible, both with confidence.

## Headline finding

**The library is client-only.** It lets a Ballerina program call other A2A agents.
It has **no supported way to let a Ballerina program *be* an A2A agent** — no
listener/service contract, no task-handler pattern, no `TaskStore`, no push-notification
webhook receiver, no server-side SSE emitter. A grep across the entire `a2a/` module for
`server|AgentExecutor|RequestHandler|listener|http:Service` turns up nothing but comments
and design-doc prose.

This matters because it's exactly the second half of what was asked for: "make their
Ballerina agents A2A-compatible" implies *exposing* an agent, not just consuming one.
Today that's simply not possible with this library. The library's own design doc
(`A2A_Technical_Design.md`) has a large "Listener & service design" / "Agent Card and
Skills — developer guide" / worked "weather agent" section (~lines 766–1404) that reads
like exactly this feature — but it's explicitly flagged `⚠️ SUPERSEDED — do not implement
from this section`, describes an earlier unversioned draft, and none of it exists in code.

Everything else below is a client-side conformance/completeness audit, which is generally
in good shape — but it's worth being clear that closing every item below still leaves the
library only half of the way to the stated goal.

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
2. **JSON-RPC only — no gRPC or REST transport binding.** Spec §5 requires all three
   bindings be functionally equivalent; this client can only reach an agent's JSON-RPC
   endpoint. `AgentInterface.protocolBinding` is captured in the data model (so
   `primaryUrl` can at least detect and fail clearly on a gRPC-only card), but there's no
   way to actually speak gRPC or REST.
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

## Punch list, ranked by how much each blocks "developers can easily make their Ballerina agents A2A-compatible"

1. **Build the server/listener side.** Currently 0% implemented. This is the actual gap
   between what exists (an A2A client) and the stated goal (A2A-compatible Ballerina
   *agents*). Needs: a service/listener contract, a task-handler pattern, a `TaskStore`
   abstraction (with an in-memory default), a push-notification webhook receiver, and a
   server-side SSE emitter. The superseded draft in the design doc is a reasonable start
   for scoping this but should be treated as inspiration only, not a spec to implement
   from verbatim — it's already flagged as containing wrong field names.
2. **`A2A-Extensions` header support** — real spec mechanism, currently absent client-side
   and (once built) will need to exist server-side too.
3. **REST/gRPC transport bindings** — only bites if a target agent doesn't expose
   JSON-RPC. JSON-RPC is the dominant binding in the current ecosystem (every reference
   server here uses it), so this is lower urgency than #1–2 but is a real conformance gap
   against spec §5.
4. **AgentCard signature verification + automatic auth-from-scheme wiring** — security-
   relevant; currently manual/absent.
5. **Automatic SSE reconnection** — quality-of-life, not a conformance gap (manual
   reconnect already works today).
6. **Close remaining live-server test gaps** (§5) — needs either a fourth reference
   server or fixes upstream to bugs already identified in the existing ones (e.g. the
   `a2a-sdk==0.3.0` delete-config non-conformance).
7. **Clean up `A2A_Technical_Design.md`** — remove/archive the superseded section so new
   contributors can't mistake it for current guidance.

## Bottom line

Client-side, against the official spec: solid. All 11 operations exist, the data model
and error codes are complete and correctly typed, and the v0.3 legacy dialect is handled
transparently. The gaps that remain there (extensions header, alternate transports,
signature verification, auth ergonomics, reconnection) are real but secondary polish.

The one item that actually blocks the stated end goal is #1: there is currently no way
to turn a Ballerina program into an A2A agent that other clients (including this same
library) can call. Closing that is a separate, substantial feature, not a bug fix — it's
the next major phase of work, not a wrap-up item.
