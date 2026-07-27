# helloworld reference server — setup

The official Python A2A reference server, from `a2a-samples`
(`samples/python/agents/helloworld`). Not vendored into this repo — set it
up from a checkout of `a2a-samples` alongside this one.

## Prerequisites

- **Python**: Version 3.10 or higher.

## Quick Start

1. **Set up a virtual environment and install dependencies**

   ```bash
   cd path/to/a2a-samples/samples/python/agents/helloworld
   python -m venv .venv
   source .venv/bin/activate      # on Windows: .venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. **Start the server**

   Runs the A2A agent server locally on port `9999`:

   ```bash
   python __main__.py
   ```

3. **(Optional) Run the bundled test client**

   In a separate terminal, activate the virtual environment and run the
   sample client to sanity-check communication with the agent before
   pointing this repo's tests/demo at it:

   ```bash
   source .venv/bin/activate
   python test_client.py
   ```

## Using it with this repo

- **Interop tests**: from `tests/`, run
  `A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --groups interop`.
- **Demo**: from `demo/`, run `bal run` — it talks to
  `http://127.0.0.1:9999` directly.

Leave the server running in its own terminal for either.

See [`findings.md`](./findings.md) for the spec non-conformances this
server exhibits and how the client works around them.
