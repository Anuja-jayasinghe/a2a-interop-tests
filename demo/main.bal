import ballerina/a2a;
import ballerina/io;
import ballerina/os;
import ballerina/uuid;

// Pick which agent to run this demo against: uncomment exactly one of the
// two `return` lines below (comment out the other), then `bal run` -- no
// env var needed. A2A_DEMO_SERVER_URL, if set, still overrides both, for
// scripting/CI use. The client's protocol-version auto-detection (below)
// makes this demo work identically either way, with no code branching on
// which dialect the server speaks.
isolated function serverUrl() returns string {
    string envUrl = os:getEnv("A2A_DEMO_SERVER_URL");
    if envUrl != "" {
        return envUrl;
    }

    return "http://127.0.0.1:9999";     // helloworld (v1.0)
    // return "http://localhost:10999"; // adk_currency_agent (v0.3)
}

public function main() returns error? {
    string url = serverUrl();

    io:println("=== Step 1: resolveAgentCard ===");
    a2a:AgentCard card = check a2a:resolveAgentCard(url);
    io:println("Name:        ", card.name);
    io:println("Description: ", card.description);
    io:println("Capabilities:");
    io:println("  streaming:         ", card.capabilities.streaming);
    io:println("  pushNotifications: ", card.capabilities.pushNotifications);
    io:println("  extendedAgentCard: ", card.capabilities.extendedAgentCard);
    io:println();

    // Passing the resolved card lets the Client auto-detect whether this
    // agent speaks A2A v1.0 or the older v0.3 dialect (see
    // ballerina/a2a's compat_v03.bal) and translate transparently --
    // everything below this line is identical regardless of which server
    // is configured.
    a2a:Client agentClient = check new (url, agentCard = card);

    io:println("=== Step 2: sendMessage ===");
    string firstText = "Say hello.";
    io:println("Outgoing message: ", firstText);
    a2a:Message plainMsg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        parts: [{text: firstText}]
    };
    a2a:Task|a2a:Message sendResult = check agentClient->sendMessage(plainMsg);
    if sendResult is a2a:Task {
        a2a:Task task = <a2a:Task>sendResult;
        io:println("Task id:     ", task.id);
        io:println("Task status: ", task.status.state);
        io:println("Artifact:    ", firstArtifactText(task) ?: "(no text artifact)");
    } else {
        a2a:Message reply = <a2a:Message>sendResult;
        io:println("Agent replied with a plain Message: ", firstPartText(reply.parts) ?: "(no text part)");
    }
    io:println();

    io:println("=== Step 3: sendMessageStream ===");
    check streamOneMessage(agentClient, "Say hello, streaming this time.");
    io:println();

    io:println("=== Step 4: interactive loop (type 'quit' to exit) ===");
    while true {
        string line = io:readln("> ");
        if line == "quit" {
            break;
        }
        error? streamErr = streamOneMessage(agentClient, line);
        if streamErr is error {
            io:println("  [failed] ", describeErrorType(streamErr), ": ", streamErr.message());
        }
    }

    io:println("Goodbye.");
}

# Sends one message via sendMessageStream and prints each event live as it
# arrives, rather than buffering the whole stream before printing anything.
#
# + agentClient - the client to send through
# + text - the message text to send
# + return - an error if the stream itself fails to open or errors mid-stream
function streamOneMessage(a2a:Client agentClient, string text) returns error? {
    io:println("Outgoing message: ", text);
    a2a:Message msg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        parts: [{text: text}]
    };

    stream<a2a:StreamResponse, error?> events = check agentClient->sendMessageStream(msg);

    while true {
        record {| a2a:StreamResponse value; |}|error? next = events.next();
        if next is () {
            io:println("  [stream closed]");
            break;
        }
        if next is error {
            io:println("  [stream error] ", describeErrorType(next), ": ", next.message());
            break;
        }
        printEvent(next.value);
    }
}

# Names the concrete A2AError subtype of an error, so a failure printed to
# the console says exactly what went wrong (e.g. UnsupportedOperationError)
# rather than just a message. Falls back to a generic label for anything
# that isn't a typed A2AError at all -- e.g. a raw Ballerina/http-layer
# failure (network unreachable, connection reset), which the library
# doesn't wrap.
#
# + err - the error to identify
# + return - the error's concrete A2AError subtype name, or a generic label
function describeErrorType(error err) returns string {
    if err is a2a:TaskNotFoundError {
        return "TaskNotFoundError";
    } else if err is a2a:TaskNotCancelableError {
        return "TaskNotCancelableError";
    } else if err is a2a:UnsupportedOperationError {
        return "UnsupportedOperationError";
    } else if err is a2a:ContentTypeNotSupportedError {
        return "ContentTypeNotSupportedError";
    } else if err is a2a:InvalidAgentResponseError {
        return "InvalidAgentResponseError";
    } else if err is a2a:VersionNotSupportedError {
        return "VersionNotSupportedError";
    } else if err is a2a:PushNotificationNotSupportedError {
        return "PushNotificationNotSupportedError";
    } else if err is a2a:A2AInternalError {
        return "A2AInternalError";
    } else if err is a2a:A2AError {
        return "A2AError (unrecognized subtype)";
    } else {
        return "error (not an A2AError -- likely a network/http-layer failure)";
    }
}

# + event - the stream event to print
function printEvent(a2a:StreamResponse event) {
    a2a:Task? task = event?.task;
    a2a:Message? message = event?.message;
    a2a:TaskStatusUpdateEvent? statusUpdate = event?.statusUpdate;
    a2a:TaskArtifactUpdateEvent? artifactUpdate = event?.artifactUpdate;

    if task is a2a:Task {
        io:println("  [task created] id=", task.id, " state=", task.status.state);
    } else if message is a2a:Message {
        io:println("  [message] ", firstPartText(message.parts) ?: "(no text part)");
    } else if statusUpdate is a2a:TaskStatusUpdateEvent {
        io:println("  [status] ", statusUpdate.status.state);
    } else if artifactUpdate is a2a:TaskArtifactUpdateEvent {
        io:println("  [artifact] ", firstPartText(artifactUpdate.artifact.parts) ?: "(no text part)");
    } else {
        io:println("  [unrecognized event] ", event.toJsonString());
    }
}

# + task - the task to extract the first artifact's text from
# + return - the first text part's content, if any
function firstArtifactText(a2a:Task task) returns string? {
    if task.artifacts.length() == 0 {
        return ();
    }
    return firstPartText(task.artifacts[0].parts);
}

# + parts - the parts to search for a text part
# + return - the first text part's content, if any
function firstPartText(a2a:Part[] parts) returns string? {
    foreach a2a:Part part in parts {
        string? text = part?.text;
        if text is string {
            return text;
        }
    }
    return ();
}
