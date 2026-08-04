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
| SendStreamingMessage | `sendStreamingMessage` (client.bal:356) | ✅ v1.0 + v0.3 |
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
`sendStreamingMessage` are confirmed passing over all three against a real server
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

## 4. Client-side gaps — status as of this pass (corrected; this section was stale)

**This section previously listed six items as unimplemented that have since actually been
built** (in later work sessions, each with its own design spec under
`a2a-ballerina/a2a/docs/superpowers/specs/`) — this file just was never updated to match.
Verified directly against current source below, not just against the design doc's own
claims. Only one item here is a genuine, still-open gap (#6, mTLS).

1. ~~**`A2A-Extensions` header not implemented at all.**~~ **Resolved.** The client sends
   `A2A-Extensions` on requests that declare extensions and captures the server's granted
   extensions from the response header — `captureGrantedExtensions` (JSON-RPC/REST,
   `client.bal:535`) and `captureGrantedExtensionsFromGrpc` (gRPC metadata,
   `client.bal:775`).
2. ~~**JSON-RPC only — no gRPC or REST transport binding.**~~ **Resolved.**
   `Client.init`'s `binding` parameter speaks all three (`"JSONRPC"`, `"HTTP+JSON"`,
   `"GRPC"`), satisfying spec §5's functional-equivalence requirement, and all three are
   verified end-to-end against a real server (`servers/dice_agent/`) — see punch-list
   item 2 below and `servers/dice_agent/findings.md` for the full evidence.
3. ~~**AgentCard signature (JWS) is captured but never cryptographically verified.**~~
   **Resolved, with one documented, real limitation.** `verifyAgentCardSignature`
   (`signature.bal:92`, RFC 7515, RS256/ES256) is implemented and fail-closed — a
   forged/tampered card is never falsely accepted. **The limitation**: it does not perform
   RFC 8785 JSON Canonicalization (JCS), which spec §8.4.1 requires before computing the
   signing input, so it only verifies signatures computed over Ballerina's own
   `toJsonString()` serialization — not signatures from a real external signer (e.g. a
   Python or Java reference implementation using a proper JCS canonicalizer). Deliberately
   not implemented yet: doing JCS correctly (recursive Unicode-code-point key sorting,
   ECMAScript-compatible number formatting, ECMA-262 string escaping) is intricate enough,
   especially with `AgentCard`'s open `json...` fields able to carry arbitrary data, that a
   partial/incorrect implementation risked silently wrong verification results — judged
   worse than the current, honestly-documented gap. This is the one item on this list
   that's genuinely still incomplete, not fully closed.
4. ~~**No AgentCard caching.**~~ **Resolved, as an opt-in.** `resolveAgentCardCached`
   respects HTTP caching headers (ETag/If-None-Match, Cache-Control/max-age) and reuses
   the cached body on a `304`. `resolveAgentCard` itself is unchanged and still fetches
   fresh every call — intentional, for callers who always want the latest card.
5. ~~**No automatic SSE reconnection.**~~ **Resolved, as an opt-in.**
   `subscribeToTask`/`sendStreamingMessage` take a `maxReconnectAttempts` parameter
   (default `0`, preserving old behavior exactly); set positive, the client detects a
   dropped stream and resubscribes on the caller's behalf up to that many times before
   surfacing the error.
6. ~~**No automatic client-auth wiring from a parsed AgentCard.**~~ **Resolved for the
   schemes that can be.** `buildAuthFromCard` (`auth.bal:41`) goes
   `card.securityRequirements` → working `http:ClientConfiguration.auth`/headers
   automatically, but **deliberately scoped to `ApiKeySecurityScheme` and
   `HttpAuthSecurityScheme` only** — both reduce to "one credential string the caller
   already has." OAuth2 and OpenID Connect need a token-acquisition flow, and mutual TLS
   needs a client certificate; none of those reduce to a single string, so a caller still
   wires those through `clientConfig` directly, same as before — not an oversight, a
   real scope boundary (a helper that pretends to auto-handle a multi-step OAuth flow
   would be worse than no helper). Also only reads `card.securityRequirements`
   (top-level) — a card that declares security only at the per-`AgentSkill` level isn't
   auto-wired yet; a real, narrower remaining gap.
7. **mTLS is a reserved-but-stubbed interface — still genuinely open.** Explicitly
   deferred pending a security review before implementing, per the design doc. This is
   the real reason, not a placeholder excuse: client-certificate handling (where the
   cert/key material comes from, how it's validated, what mutual-auth failure should look
   like to a caller) has actual security consequences if gotten wrong, and nobody with
   the right expertise has done that review yet. Unlike the JWS/auth-wiring items above,
   there's no interim "does most of the job, one documented edge case" version here —
   it's all-or-nothing, so it stays a hard stub until that review happens.

## 5. Test coverage gaps (already tracked in `CLIENT_TEST_COVERAGE.md` — listed here only for completeness, don't re-derive)

`listTasks` filtering/pagination untested live; `deleteTaskPushNotificationConfig`
success path blocked by a real `a2a-sdk==0.3.0` server-side bug (not a client bug);
`tenant` param untested live; non-text `Part` variants (file/data) untested;
`Message.referenceTaskIds`/`extensions`, `Artifact.extensions` untested; `FAILED`/
`REJECTED`/`AUTH_REQUIRED` states never exercised against a live server.

## 6. Documentation gap — resolved

~~`A2A_Technical_Design.md` appends a large superseded draft...~~ **Resolved.** The
superseded listener/service draft (listener/service design, skills-authoring guide,
worked weather-agent example) has been moved out to its own file —
`a2a-ballerina/a2a/docs/archive/A2A_Technical_Design_superseded_listener_draft.md` — and
`A2A_Technical_Design.md` itself is now a clean, current-only client design doc (776
lines, ends at §12 with no dangling draft content). Verified directly against source, not
assumed. One separate, smaller documentation issue found while re-verifying this: parts
of `A2A_Technical_Design.md` §3's `securitySchemes` note still describe an earlier,
pre-typed state (`map<json>`) that the actual `types.bal` has since superseded with a
real discriminated union — a targeted stale passage, not a structural problem like the
one this section used to describe.

## Client-hardening punch list — status (most of this round's original scope is now done)

Originally ranked by how much each blocks a developer trusting this client to reliably
discover and call other A2A agents in production. Kept here as a record of what was
tracked and closed, not as a current to-do list — only #6 and #7 remain genuinely open
(#8 is also now closed).

1. ~~**`A2A-Extensions` header support**~~ — **closed**, see §4.1 above.
2. ~~**REST and gRPC transport bindings**~~ — **closed**, see §4.2 above and
   `servers/dice_agent/findings.md` for the real-server evidence (`bal test --sticky
   --groups interop`, 3/3 passing on `dice_agent`, real Anthropic responses on all three
   transports).
3. ~~**AgentCard signature (JWS) verification**~~ — **closed, with one documented
   limitation** (no JCS canonicalization yet), see §4.3 above.
4. ~~**Automatic client-auth wiring from `AgentCard.securitySchemes`**~~ — **closed for
   API-key/HTTP-auth schemes**, see §4.6 above. OAuth2/OIDC/mTLS remain caller-wired by
   design, not by omission.
5. ~~**Automatic SSE reconnection**~~ — **closed, opt-in** (`maxReconnectAttempts`), see
   §4.5 above.
6. **AgentCard caching** — mostly closed (§4.4 above, `resolveAgentCardCached`), but
   `resolveAgentCard` — the function every test and demo in this repo actually calls —
   still always fetches fresh. Genuinely open **as a default-path optimization**: nothing
   currently in this repo exercises `resolveAgentCardCached` at all, so switching callers
   over (or at least demonstrating it works against a real server) is real remaining work.
7. **Close the achievable test-coverage gaps** (§5 above) — the ones that don't require a
   live third-party server: file/data `Part` variant round-tripping, `FAILED`/`REJECTED`/
   `AUTH_REQUIRED` state handling, `listTasks` filter-parameter encoding. (`listTasks`
   live pagination, `tenant` live, and the delete-push-config success path stay blocked on
   external servers — out of scope for this round.)
8. ~~**Clean up `A2A_Technical_Design.md`**~~ — **closed**, see §6 above. The superseded
   draft is archived out to its own file; the main design doc is now clean.

**Genuinely still open, in priority order**: mTLS (§4.7 — blocked on a security review,
not effort), JWS's JCS canonicalization gap (§4.3 — blocked on doing it correctly rather
than partially), item 6 above (AgentCard caching adoption), item 7 (achievable test gaps),
item 8 (doc cleanup), and the narrower scope edges called out inline in §4 (skill-level
`securityRequirements` auto-wiring, full `SecurityScheme` typing beyond the current
discriminated union).

## Bottom line

Client-side, against the official spec: solid, and considerably more complete than this
file used to claim. All 11 operations exist over all three transport bindings the spec
requires (JSON-RPC/REST/gRPC), the data model and error codes are complete and correctly
typed, the v0.3 legacy dialect is handled transparently, and five of the seven items this
file previously listed as outright missing (`A2A-Extensions`, JWS verification, AgentCard
caching, SSE auto-reconnection, automatic client-auth wiring) are actually implemented —
this report simply hadn't been updated to match `a2a-ballerina`'s own progress. The two
genuinely open items (mTLS, JWS's JCS canonicalization) are both blocked for real,
specific reasons, not lack of effort: mTLS's data model is fully typed
(`MutualTlsSecurityScheme`) but a client certificate isn't a single credential string the
way API-key/HTTP-auth are, so it's deliberately left caller-wired rather than half-automated;
JWS's gap is a correctness-risk judgment call — a partial/incorrect JCS implementation was
judged worse than the current, honestly-documented limitation. See
`docs/superpowers/plans/2026-07-30-client-hardening.md` in `a2a-ballerina` for the
original task breakdown, and each feature's own doc comment (`auth.bal`, `signature.bal`,
`client.bal`) for the most current, authoritative status — this file should be treated as
a snapshot, not a live source of truth, and re-verified against source before being
trusted for anything high-stakes.

Server/listener support (letting a Ballerina program *be* an A2A agent) is intentionally
out of scope for this round and will be scoped separately once the client above is done.
