# Learning Log

One entry per implementation unit — what it does, why it's shaped that way, what surprised me.

## Cyclic module dependency between `a2a` and `a2a.transport`

The design doc's own sample code has `modules/transport/jsonrpc.bal` and
`sse.bal` importing the root `ballerina/a2a` module (to construct
`A2AError`/`StreamResponse` values), while `client.bal` (root) imports
`ballerina/a2a.transport` (for the JSON-RPC envelope types and
`readSseStream`). That's a cycle: `a2a -> a2a.transport -> a2a`.
Ballerina forbids cyclic module dependencies within a package and
`bal build` rejects it outright — this went undetected through Phase 3
because `client.bal` was still an empty stub, so the root module never
actually imported `transport` until Phase 4 started.

Fix: `modules/transport/` is now a pure wire-format leaf module —
`JsonRpcRequest`/`JsonRpcResponse`/`JsonRpcError` only, zero dependency on
`a2a`. Everything that needs to construct root `a2a` types moved to the
root module: `toA2AError` lives in `errors.bal`, and
`A2AStreamGenerator`/`readSseStream`/`isTerminalEvent` moved from
`modules/transport/sse.bal` to a new root-level `sse.bal`. The root module
still freely imports `a2a.transport` (one direction only, which Ballerina
allows). Also surprising: `bal build`'s cyclic-import check considers
*test-scope* imports too, not just production source — a stray
`import ballerina/a2a;` in a transport-module test file was enough to
keep the cycle error alive after the production code was already fixed.
