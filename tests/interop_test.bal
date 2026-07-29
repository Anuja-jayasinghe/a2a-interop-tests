// Real interop tests against an actual A2A reference server, not a mock.
// Every test here returns early (a trivial pass -- ballerina/test has no
// runtime "skip" primitive, only compile-time enable/groups filtering)
// unless A2A_TEST_SERVER_URL is set, rather than falling through to
// getServerBaseUrl()'s local-mock default -- there is no mock in this repo,
// and a silent fallback here would produce misleading pass/fail results
// for these specific assertions. Run for real with:
//
//   A2A_TEST_SERVER_URL=http://127.0.0.1:9999 bal test --groups interop
//
// against a running samples/python/agents/helloworld server (see
// a2a-samples on GitHub, and servers/helloworld/setup.md in this repo). A
// plain `bal test` run leaves these as no-ops.

import ballerina/a2a;
import ballerina/io;
import ballerina/os;
import ballerina/test;

# + return - true if A2A_TEST_SERVER_URL is set, meaning a real server is
#            configured to run these tests against
isolated function isRealServerConfigured() returns boolean {
    return os:getEnv("A2A_TEST_SERVER_URL") != "";
}

# Prints a visible marker for the no-op case, so a plain `bal test` run
# doesn't show these as indistinguishable green passes from tests that
# actually exercised anything -- a silent early return here would make
# green look the same whether these tests did real work or not.
#
# + testName - the name of the test that's about to no-op
isolated function logSkip(string testName) {
    io:println(string `SKIPPED (A2A_TEST_SERVER_URL not set): ${testName}`);
}

@test:Config {groups: ["interop"]}
function testInteropSendMessage() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropSendMessage");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl());
    a2a:Message msg = {
        messageId: "interop-send-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Say hello."}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the reference server replies with a Task for this sample agent");
    a2a:Task task = <a2a:Task>result;
    assertValidTask(task);
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
    test:assertEquals(extractArtifactText(task.artifacts[0]), "Hello, World! I have received your request (Say hello.)");
}

# Exercises the full sendMessageStream lifecycle through the real
# A2AStreamGenerator/readSseStream pipeline: task creation, a WORKING
# status update, an artifact update, a COMPLETED status update, then a
# clean stream close. Confirmed once by hand against the real server
# before this test was written -- this pins that result down.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testInteropSendMessageStream() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropSendMessageStream");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl());
    a2a:Message msg = {
        messageId: "interop-stream-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Say hello."}]
    };

    stream<a2a:StreamResponse, error?> events = check c->sendMessageStream(msg);

    a2a:StreamResponse first = check expectValue(events.next());
    test:assertTrue(first?.task is a2a:Task, "the first event should be the newly created task");
    a2a:Task createdTask = <a2a:Task>first?.task;
    test:assertEquals(createdTask.status.state, a2a:TASK_STATE_SUBMITTED);

    a2a:StreamResponse second = check expectValue(events.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>second?.statusUpdate).status.state, a2a:TASK_STATE_WORKING);

    a2a:StreamResponse third = check expectValue(events.next());
    a2a:TaskArtifactUpdateEvent artifactEvent = <a2a:TaskArtifactUpdateEvent>third?.artifactUpdate;
    test:assertEquals(extractArtifactText(artifactEvent.artifact), "Hello, World! I have received your request (Say hello.)");

    a2a:StreamResponse fourth = check expectValue(events.next());
    test:assertEquals((<a2a:TaskStatusUpdateEvent>fourth?.statusUpdate).status.state, a2a:TASK_STATE_COMPLETED);

    record {| a2a:StreamResponse value; |}|error? fifth = events.next();
    test:assertTrue(fifth is (), "stream should close after the terminal status");
}

@test:Config {groups: ["interop"]}
function testInteropGetTask() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropGetTask");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl());
    a2a:Message msg = {
        messageId: "interop-gettask-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Say hello."}]
    };
    a2a:Task|a2a:Message sendResult = check c->sendMessage(msg);
    test:assertTrue(sendResult is a2a:Task, "sendMessage should return a Task to fetch");
    a2a:Task created = <a2a:Task>sendResult;

    a2a:Task fetched = check c->getTask(created.id);

    test:assertEquals(fetched.id, created.id);
    test:assertEquals(fetched.status.state, a2a:TASK_STATE_COMPLETED);
}

# Coverage limitation: this sample agent (samples/python/agents/helloworld)
# processes every task synchronously -- SendMessage already returns
# TASK_STATE_COMPLETED by the time the HTTP response arrives, so there is
# no in-flight window in which to genuinely cancel a running task. The
# only reachable case against this agent is canceling an already-terminal
# task, which the real server correctly rejects with TASK_NOT_CANCELABLE.
# That's still a useful confirmation that cancelTask's error mapping works
# end to end against a real server -- it just isn't a "successful cancel"
# path, because this agent never leaves one open.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testInteropCancelTaskOnTerminalTask() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropCancelTaskOnTerminalTask");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl());
    a2a:Message msg = {
        messageId: "interop-cancel-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Say hello."}]
    };
    a2a:Task|a2a:Message sendResult = check c->sendMessage(msg);
    test:assertTrue(sendResult is a2a:Task, "sendMessage should return a Task to cancel");
    a2a:Task created = <a2a:Task>sendResult;

    a2a:Task|error canceled = c->cancelTask(created.id);

    test:assertTrue(canceled is error, "canceling an already-terminal task should fail");
    test:assertTrue(canceled is a2a:TaskNotCancelableError, "should map to TaskNotCancelableError, matching the design doc");
}

# Coverage limitation, worse than cancelTask's: this sample agent never
# leaves a task in-flight (see testInteropCancelTaskOnTerminalTask), so a
# genuine reconnect-and-replay via subscribeToTask can't be exercised
# against it either. Confirmed by hand against the real server: calling
# SubscribeToTask on an already-terminal task returns HTTP 200 with a
# plain application/json error body (code -32602, reason INVALID_PARAMS)
# -- not an SSE-framed stream at all. openSseStream now checks the
# response Content-Type before handing it to readSseStream/
# getSseEventStream: a non-SSE 200 is parsed as a JSON-RPC error and
# routed through the same toA2AError mapping rpcCall uses, rather than
# leaking Ballerina's raw "invalid payload target type" http-layer error.
# -32602 has no dedicated A2AError subtype, so it maps to A2AInternalError
# (see errors.bal's default case) -- NOT UnsupportedOperationError, despite
# design doc §6.5 claiming exactly that for a terminal-state subscribe.
# That's a separate, already-reported doc mismatch, not fixed here.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testInteropSubscribeToTaskOnTerminalTask() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropSubscribeToTaskOnTerminalTask");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl(), {timeout: 10});
    a2a:Message msg = {
        messageId: "interop-subscribe-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Say hello."}]
    };
    a2a:Task|a2a:Message sendResult = check c->sendMessage(msg);
    test:assertTrue(sendResult is a2a:Task, "sendMessage should return a Task to subscribe to");
    a2a:Task created = <a2a:Task>sendResult;

    stream<a2a:StreamResponse, error?>|error subscribed = c->subscribeToTask(created.id);

    test:assertTrue(subscribed is error, "subscribing to an already-terminal task should fail to open");
    test:assertTrue(subscribed is a2a:A2AError, "should now be a typed A2AError, not a raw http-layer error");
    test:assertTrue(subscribed is a2a:A2AInternalError, "code -32602 has no dedicated subtype, so it maps to A2AInternalError");
}

# Determines empirically whether helloworld's capabilities.extendedAgentCard
# flag (observed true in earlier interop work) means getExtendedAgentCard
# is genuinely implemented, or just declared. See findings.md for the
# result either way -- this is exploratory verification, not a test with a
# single predetermined correct outcome.
#
# + return - an error if any step other than the assertions themselves fails
@test:Config {groups: ["interop"]}
function testInteropGetExtendedAgentCard() returns error? {
    if !isRealServerConfigured() {
        logSkip("testInteropGetExtendedAgentCard");
        return;
    }

    a2a:Client c = check new (getServerBaseUrl());

    a2a:AgentCard|error result = c->getExtendedAgentCard();

    if result is error {
        io:println("  [getExtendedAgentCard] not supported by this server: ", result.message());
        return;
    }

    a2a:AgentCard card = result;
    io:println("  [getExtendedAgentCard] supported — name: ", card.name);
    test:assertTrue(card.name.length() > 0, "an extended card, if returned, should at least have a name");
}
