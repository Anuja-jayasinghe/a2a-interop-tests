// Real interop tests against the dice_agent_multi_transport reference
// server -- see servers/dice_agent/setup.md to start it, and findings.md
// for why it exists at all: it's the only reference agent in this repo
// whose AgentCard.supportedInterfaces genuinely lists GRPC and HTTP+JSON
// alongside JSONRPC, closing FINDINGS.md's "mock-verified only" gap for
// those two transport bindings. Same no-op-unless-configured pattern as
// interop_test.bal: set A2A_DICE_AGENT_URL=http://localhost:11000 to run
// for real.
//
// Unlike every other interop test file here, these three tests construct
// three separate a2a:Client instances against the *same* running agent --
// one per transport binding -- to directly prove the same request/response
// shapes round-trip correctly over gRPC, JSON-RPC, and REST, not just that
// each binding works in isolation against a different server.

import ballerina/a2a;
import ballerina/http;
import ballerina/io;
import ballerina/os;
import ballerina/test;

// dice_agent's Quarkus dev-mode server doesn't negotiate h2c (HTTP/2
// cleartext) correctly with Ballerina's http:Client, which defaults to
// HTTP/2 -- every request, including plain agent-card discovery, comes
// back "400 Bad Request" with nothing logged server-side (confirmed: the
// request never reaches Quarkus's own routing/logging at all). Forcing
// HTTP/1.1 fixes it outright. Not a ballerina/a2a bug -- recorded in
// servers/dice_agent/findings.md.
final http:ClientConfiguration DICE_AGENT_CLIENT_CONFIG = {httpVersion: http:HTTP_1_1};

isolated function isDiceAgentConfigured() returns boolean {
    return os:getEnv("A2A_DICE_AGENT_URL") != "";
}

isolated function logDiceAgentSkip(string testName) {
    io:println(string `SKIPPED (A2A_DICE_AGENT_URL not set): ${testName}`);
}

@test:Config {groups: ["interop"]}
function testDiceAgentSendMessageJsonRpc() returns error? {
    if !isDiceAgentConfigured() {
        logDiceAgentSkip("testDiceAgentSendMessageJsonRpc");
        return;
    }

    string baseUrl = os:getEnv("A2A_DICE_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl, DICE_AGENT_CLIENT_CONFIG);
    a2a:Client c = check new (baseUrl, clientConfig = DICE_AGENT_CLIENT_CONFIG, agentCard = card, binding = "JSONRPC");

    a2a:Message msg = {
        messageId: "dice-interop-jsonrpc-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Can you roll a 6-sided die?"}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the dice agent replies with a Task");
    a2a:Task task = <a2a:Task>result;
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
}

# Exercises ballerina/a2a's REST (HTTP+JSON) transport binding client-side
# code against a real REST-serving agent for the first time in this repo --
# every other interop test here uses the JSONRPC binding, since none of the
# other three reference agents advertise an HTTP+JSON interface at all
# (FINDINGS.md's REST coverage-gap section).
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testDiceAgentSendMessageRest() returns error? {
    if !isDiceAgentConfigured() {
        logDiceAgentSkip("testDiceAgentSendMessageRest");
        return;
    }

    string baseUrl = os:getEnv("A2A_DICE_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl, DICE_AGENT_CLIENT_CONFIG);
    a2a:Client c = check new (baseUrl, clientConfig = DICE_AGENT_CLIENT_CONFIG, agentCard = card, binding = "HTTP+JSON");

    a2a:Message msg = {
        messageId: "dice-interop-rest-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Is 17 a prime number?"}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the dice agent replies with a Task");
    a2a:Task task = <a2a:Task>result;
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
}

# Exercises ballerina/a2a's gRPC transport binding client-side code
# (a2a.grpcstub) against a real gRPC-serving agent for the first time in
# this repo -- FINDINGS.md's gRPC coverage-gap section notes the only prior
# gRPC coverage was a mock-based wire round-trip test, never a real
# third-party server. This is that closure.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testDiceAgentSendMessageStreamGrpc() returns error? {
    if !isDiceAgentConfigured() {
        logDiceAgentSkip("testDiceAgentSendMessageStreamGrpc");
        return;
    }

    string baseUrl = os:getEnv("A2A_DICE_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl, DICE_AGENT_CLIENT_CONFIG);
    // Note: DICE_AGENT_CLIENT_CONFIG's httpVersion only affects this
    // Client's internal (unused, in GRPC mode) plain http:Client -- the
    // actual gRPC stub always speaks HTTP/2 regardless, since
    // projectToGrpcClientConfig only ever projects .auth, never httpVersion.
    a2a:Client c = check new (baseUrl, clientConfig = DICE_AGENT_CLIENT_CONFIG, agentCard = card, binding = "GRPC");

    a2a:Message msg = {
        messageId: "dice-interop-grpc-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Can you roll a 20-sided die and check if the result is prime?"}]
    };

    stream<a2a:StreamResponse, error?> events = check c->sendMessageStream(msg);

    boolean sawCompletion = false;
    record {| a2a:StreamResponse value; |}|error? next = events.next();
    while next is record {| a2a:StreamResponse value; |} {
        a2a:TaskStatusUpdateEvent? statusUpdate = next.value?.statusUpdate;
        if statusUpdate is a2a:TaskStatusUpdateEvent && statusUpdate.status.state == a2a:TASK_STATE_COMPLETED {
            sawCompletion = true;
        }
        next = events.next();
    }
    if next is error {
        test:assertFail("stream ended with an error: " + next.message());
    }

    test:assertTrue(sawCompletion, "stream should deliver a COMPLETED status update before closing");
}
