# LEARNING_LOG

Interop-specific lessons only — not a duplicate of `a2a-ballerina`'s own
learning log.

## Reference implementations deviate from spec — verify everything

Testing against the real Python `helloworld` server turned up several
places where both an earlier reading of the spec *and* the official v1.0
migration guide's own illustrative examples were wrong about the actual
wire format (PascalCase method names, wrapped `SendMessage` responses,
streaming event key names). The lesson: for interop work, treat spec
documents and migration guides as hypotheses, not ground truth — confirm
every wire-format assumption against a real, running server before
encoding it into a test or a findings doc. See
`servers/helloworld/findings.md` for the specifics.

## A non-conforming server can still teach you something about your client

`subscribeToTask`'s terminal-task behavior on the real server is not
spec-conformant (wrong error code, wrong transport shape for a streaming
response). That's a server bug, not a client bug — but hitting it drove
a genuine client-side improvement (`openSseStream`'s Content-Type check)
that makes the client more robust to *any* server sending a non-streaming
200 in response to a streaming request, regardless of whose fault that
is on the wire. Non-conformance findings are worth fixing around even
when they're not "our bug."
