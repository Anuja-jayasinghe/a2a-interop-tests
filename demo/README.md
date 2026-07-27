# demo

An interactive, watchable walkthrough of `ballerina/a2a`'s `Client` against
a real A2A server. Not a test suite — this is for watching it work.

## Prerequisites

`demo` consumes `ballerina/a2a` from the local Ballerina package
repository, not a copy of the source. If the local `a2a` package isn't
already published there (or you've since changed `a2a-ballerina/a2a` and
want the demo to pick up the change), rebuild and republish it first:

```bash
cd ../../A2A_Project/a2a-ballerina/a2a
bal pack
bal push --repository=local
```

## Running the demo

1. Start the reference server — see
   [`../servers/helloworld/setup.md`](../servers/helloworld/setup.md) for
   venv/run instructions. Leave it running — it listens on
   `http://127.0.0.1:9999`.

2. In a separate terminal, run the demo:

   ```bash
   cd demo
   bal run
   ```

The demo will: resolve the agent card, send one plain message, send one
streaming message (printing each event live as it arrives), then drop
into an interactive loop — type a line and press Enter to send it as a
new streaming message, or type `quit` to exit.
