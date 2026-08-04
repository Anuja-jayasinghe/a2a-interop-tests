// Real interop tests against the langgraph currency agent
// (a2a-samples/samples/python/agents/langgraph), running on Claude
// (model_source=anthropic) rather than its default Gemini/OpenAI backends —
// see DEMO_GUIDE.md for the setup. Unlike adk_currency_agent and
// helloworld, this agent genuinely exercises the operations neither of
// those can: real in-flight cancelTask/subscribeToTask (the model's real
// multi-second Claude+tool latency gives a real cancellation window,
// unlike helloworld's synchronous instant-complete agent), real
// INPUT_REQUIRED + multi-turn continuation via taskId, and genuine
// push-notification config CRUD (helloworld doesn't support the
// capability at all). Same no-op-unless-configured pattern as the other
// interop test files: set A2A_LANGGRAPH_AGENT_URL=http://localhost:10000
// to run for real.

import ballerina/a2a;
import ballerina/io;
import ballerina/os;
import ballerina/test;

isolated function isLangGraphAgentConfigured() returns boolean {
    return os:getEnv("A2A_LANGGRAPH_AGENT_URL") != "";
}

isolated function logLangGraphSkip(string testName) {
    io:println(string `SKIPPED (A2A_LANGGRAPH_AGENT_URL not set): ${testName}`);
}

@test:Config {groups: ["interop"]}
function testLangGraphAgentSendMessage() returns error? {
    if !isLangGraphAgentConfigured() {
        logLangGraphSkip("testLangGraphAgentSendMessage");
        return;
    }
    string baseUrl = os:getEnv("A2A_LANGGRAPH_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, {timeout: 30}, agentCard = card);

    a2a:Message msg = {
        messageId: "langgraph-send-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and GBP?"}]
    };

    a2a:Task|a2a:Message result = check c->sendMessage(msg);

    test:assertTrue(result is a2a:Task, "the langgraph agent replies with a Task");
    a2a:Task task = <a2a:Task>result;
    test:assertEquals(task.status.state, a2a:TASK_STATE_COMPLETED);
    test:assertTrue(task.artifacts.length() > 0, "a completed conversion should include an artifact");
}

@test:Config {groups: ["interop"]}
function testLangGraphAgentInputRequiredThenMultiTurn() returns error? {
    if !isLangGraphAgentConfigured() {
        logLangGraphSkip("testLangGraphAgentInputRequiredThenMultiTurn");
        return;
    }
    string baseUrl = os:getEnv("A2A_LANGGRAPH_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, {timeout: 30}, agentCard = card);

    // Deliberately omit the target currency so the agent must ask for it —
    // a genuine, model-driven INPUT_REQUIRED, not a scripted one.
    a2a:Message initial = {
        messageId: "langgraph-multiturn-1",
        role: a2a:ROLE_USER,
        parts: [{text: "Convert 100 USD"}]
    };
    a2a:Task|a2a:Message firstResult = check c->sendMessage(initial);
    test:assertTrue(firstResult is a2a:Task, "expected a Task back even for the clarification turn");
    a2a:Task firstTask = <a2a:Task>firstResult;
    test:assertEquals(firstTask.status.state, a2a:TASK_STATE_INPUT_REQUIRED);

    // Continue the SAME task/context with the missing information.
    a2a:Message followUp = {
        messageId: "langgraph-multiturn-2",
        taskId: firstTask.id,
        contextId: firstTask?.contextId,
        role: a2a:ROLE_USER,
        parts: [{text: "EUR"}]
    };
    a2a:Task|a2a:Message secondResult = check c->sendMessage(followUp);
    test:assertTrue(secondResult is a2a:Task, "expected a Task back for the completed conversion");
    a2a:Task secondTask = <a2a:Task>secondResult;
    test:assertEquals(secondTask.id, firstTask.id, "the follow-up should continue the same task");
    test:assertEquals(secondTask.status.state, a2a:TASK_STATE_COMPLETED);
    test:assertTrue(secondTask.artifacts.length() > 0, "the completed follow-up should include an artifact");
}

@test:Config {groups: ["interop"]}
function testLangGraphAgentGenuineInFlightCancel() returns error? {
    if !isLangGraphAgentConfigured() {
        logLangGraphSkip("testLangGraphAgentGenuineInFlightCancel");
        return;
    }
    string baseUrl = os:getEnv("A2A_LANGGRAPH_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, {timeout: 30}, agentCard = card);

    a2a:Message msg = {
        messageId: "langgraph-cancel-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and NOK?"}]
    };
    stream<a2a:StreamResponse, error?> events = check c->sendStreamingMessage(msg);

    // The "task created" event arrives immediately (before the real
    // Claude/tool round trip starts), giving a real window to cancel a
    // task that is genuinely still running -- unlike helloworld, where
    // every task is already COMPLETED by the time the client sees it.
    a2a:StreamResponse first = check expectValue(events.next());
    test:assertTrue(first?.task is a2a:Task, "first event should be the newly created task");
    a2a:Task createdTask = <a2a:Task>first?.task;
    test:assertEquals(createdTask.status.state, a2a:TASK_STATE_SUBMITTED);

    a2a:Task canceled = check c->cancelTask(createdTask.id);
    test:assertEquals(canceled.status.state, a2a:TASK_STATE_CANCELED);

    a2a:Task confirmed = check c->getTask(createdTask.id);
    test:assertEquals(confirmed.status.state, a2a:TASK_STATE_CANCELED,
            "the cancellation should be durably reflected in the task store, not just the cancel response");
}

@test:Config {groups: ["interop"]}
function testLangGraphAgentGenuineInFlightSubscribe() returns error? {
    if !isLangGraphAgentConfigured() {
        logLangGraphSkip("testLangGraphAgentGenuineInFlightSubscribe");
        return;
    }
    string baseUrl = os:getEnv("A2A_LANGGRAPH_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    a2a:Client c = check new (baseUrl, {timeout: 30}, agentCard = card);

    a2a:Message msg = {
        messageId: "langgraph-subscribe-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and PLN?"}]
    };
    stream<a2a:StreamResponse, error?> firstStream = check c->sendStreamingMessage(msg);

    a2a:StreamResponse first = check expectValue(firstStream.next());
    a2a:Task createdTask = <a2a:Task>first?.task;

    // Reconnect to the SAME task while it is still genuinely running.
    stream<a2a:StreamResponse, error?> resubscribed = check c->subscribeToTask(createdTask.id);
    a2a:StreamResponse update = check expectValue(resubscribed.next());
    a2a:TaskStatusUpdateEvent? statusUpdate = update?.statusUpdate;
    test:assertTrue(statusUpdate is a2a:TaskStatusUpdateEvent,
            "resubscribing to a genuinely active task should deliver a real status update, not an error");
    test:assertEquals((<a2a:TaskStatusUpdateEvent>statusUpdate).status.state, a2a:TASK_STATE_WORKING);
}

@test:Config {groups: ["interop"]}
function testLangGraphAgentPushNotificationConfigCrud() returns error? {
    if !isLangGraphAgentConfigured() {
        logLangGraphSkip("testLangGraphAgentPushNotificationConfigCrud");
        return;
    }
    string baseUrl = os:getEnv("A2A_LANGGRAPH_AGENT_URL");
    a2a:AgentCard card = check a2a:resolveAgentCard(baseUrl);
    test:assertTrue(card.capabilities.pushNotifications == true,
            "this agent must genuinely declare push notification support for this test to be meaningful");
    a2a:Client c = check new (baseUrl, {timeout: 30}, agentCard = card);

    a2a:Message msg = {
        messageId: "langgraph-push-1",
        role: a2a:ROLE_USER,
        parts: [{text: "What is the exchange rate between USD and CAD?"}]
    };
    a2a:Task|a2a:Message sendResult = check c->sendMessage(msg);
    test:assertTrue(sendResult is a2a:Task, "sendMessage should return a Task to attach a config to");
    a2a:Task created = <a2a:Task>sendResult;

    a2a:TaskPushNotificationConfig config = {
        url: "https://example.com/webhook",
        taskId: created.id
    };
    a2a:TaskPushNotificationConfig createResult = check c->createTaskPushNotificationConfig(config);
    string? configId = createResult?.id;
    test:assertTrue(configId is string, "the server should assign a config id on create");
    string id = <string>configId;

    a2a:TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig(created.id, id);
    test:assertEquals(fetched.url, "https://example.com/webhook");

    a2a:ListTaskPushNotificationConfigsResult listResult = check c->listTaskPushNotificationConfigs(created.id);
    test:assertTrue(listResult.configs.length() > 0, "the config just created should show up in the list");

    check c->deleteTaskPushNotificationConfig(created.id, id);
}
