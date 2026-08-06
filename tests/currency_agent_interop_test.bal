// Real interop tests against the adk_currency_agent reference server —
// see servers/adk_currency_agent/setup.md to start it, and findings.md
// for why this needs v0.3 client support at all. Same no-op-unless-
// configured pattern as interop_test.bal: set
// A2A_CURRENCY_AGENT_URL=http://localhost:10999 to run for real.

import ballerina/a2a;
import ballerina/io;
import ballerina/os;
import ballerina/test;

isolated function isCurrencyAgentConfigured() returns boolean {
    return os:getEnv("A2A_CURRENCY_AGENT_URL") != "";
}

isolated function logCurrencyAgentSkip(string testName) {
    io:println(string `SKIPPED (A2A_CURRENCY_AGENT_URL not set): ${testName}`);
}

@test:Config {groups: ["interop"]}
function testCurrencyAgentSendMessage() returns error? {
    if !isCurrencyAgentConfigured() {
        logCurrencyAgentSkip("testCurrencyAgentSendMessage");
        return;
    }

    string baseUrl = os:getEnv("A2A_CURRENCY_AGENT_URL");
    a2a:Client c = check a2a:newClient(baseUrl);

    a2a:Message msg = {
        messageId: "currency-interop-send-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Convert 100 USD to EUR"}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the currency agent replies with a Task");
    a2a:Task task = <a2a:Task>result;
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
}

@test:Config {groups: ["interop"]}
function testCurrencyAgentSendMessageStream() returns error? {
    if !isCurrencyAgentConfigured() {
        logCurrencyAgentSkip("testCurrencyAgentSendMessageStream");
        return;
    }

    string baseUrl = os:getEnv("A2A_CURRENCY_AGENT_URL");
    a2a:Client c = check a2a:newClient(baseUrl, {timeout: 30});

    a2a:Message msg = {
        messageId: "currency-interop-stream-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Convert 50 GBP to JPY"}]
    };

    stream<a2a:StreamResponse, error?> events = check c->sendStreamingMessage(msg);

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
