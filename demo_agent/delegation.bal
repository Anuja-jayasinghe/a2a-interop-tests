import ballerina/a2a;
import ballerina/io;
import ballerina/uuid;

# The result of one delegated turn: the accumulated verbatim reply text
# plus the task/context state needed to continue a clarification round
# (DEMO_AGENT_PLAN.md §6.5).
#
# + replyText - the concatenated text from this turn's message/artifact
#               events -- the actual answer content, never includes
#               `clarificationText` (kept separate so a clarification
#               prompt is never mistaken for a final answer)
# + clarificationText - the remote agent's clarification question, present
#                        only when `state` is `TASK_STATE_INPUT_REQUIRED`
# + taskId - the task this turn ended on, if any
# + contextId - the matching context for taskId
# + state - the task's lifecycle state at the end of this turn
public type DelegationResult record {|
    string replyText;
    string? clarificationText;
    string? taskId;
    string? contextId;
    a2a:TaskState? state;
|};

# Sends one message to the chosen agent via `sendStreamingMessage`,
# printing each event live as it arrives (rather than buffering the whole
# stream before printing anything) and accumulating the reply's text.
# Threads `taskId`/`contextId` into the outgoing message when continuing a
# task left in `TASK_STATE_INPUT_REQUIRED` by a previous call (§6.5); any
# other terminal state means the caller should pass `()` for both on the
# next call.
#
# + card - the chosen agent's AgentCard, used to build the client (spec
#          §8.3.2 -- the client picks its transport binding from the card)
# + text - the message text to send
# + taskId - the task to continue, if this is a follow-up to a clarification
# + contextId - the matching context for taskId
# + return - the delegation result, or an error if the stream itself fails
#            to open or errors mid-stream
function delegate(a2a:AgentCard card, string text, string? taskId = (), string? contextId = ()) returns DelegationResult|error {
    a2a:Client agentClient = check new (card, clientConfig = AGENT_CLIENT_CONFIG);

    io:println("=== [4] DELEGATE ===");
    io:println("  -> ", card.name, ": ", text);
    a2a:Message msg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        parts: [{text: text}],
        taskId: taskId,
        contextId: contextId
    };

    stream<a2a:StreamResponse, error?> events = check agentClient->sendStreamingMessage(msg);

    string replyText = "";
    string? clarificationText = ();
    string? lastTaskId = taskId;
    string? lastContextId = contextId;
    a2a:TaskState? lastState = ();

    while true {
        record {| a2a:StreamResponse value; |}|error? next = events.next();
        if next is () {
            io:println("  [stream closed]");
            break;
        }
        if next is error {
            io:println("  [stream error] ", describeErrorType(next), ": ", next.message());
            return next;
        }
        a2a:StreamResponse event = next.value;

        a2a:Task? task = event?.task;
        a2a:Message? message = event?.message;
        a2a:TaskStatusUpdateEvent? statusUpdate = event?.statusUpdate;
        a2a:TaskArtifactUpdateEvent? artifactUpdate = event?.artifactUpdate;

        if task is a2a:Task {
            io:println("  [task] id=", task.id, " state=", task.status.state);
            lastTaskId = task.id;
            lastContextId = task?.contextId;
            lastState = task.status.state;
            if task.status.state == a2a:TASK_STATE_INPUT_REQUIRED {
                clarificationText = firstMessagePartText(task.status?.message);
            } else {
                string? artifactText = firstArtifactText(task);
                if artifactText is string {
                    replyText += artifactText;
                }
            }
        } else if message is a2a:Message {
            string? text2 = firstPartText(message.parts);
            io:println("  [message] ", text2 ?: "(no text part)");
            if text2 is string {
                replyText += text2;
            }
        } else if statusUpdate is a2a:TaskStatusUpdateEvent {
            io:println("  [status] ", statusUpdate.status.state);
            lastTaskId = statusUpdate.taskId;
            lastContextId = statusUpdate.contextId;
            lastState = statusUpdate.status.state;
            // Only INPUT_REQUIRED's status.message is a genuine
            // clarification prompt to surface. Other terminal states'
            // status.message (if any) tends to restate the same content
            // the artifact event already carried -- capturing it here too
            // would double the reply text (see DEMO_AGENT_PLAN.md §6.5).
            if statusUpdate.status.state == a2a:TASK_STATE_INPUT_REQUIRED {
                clarificationText = firstMessagePartText(statusUpdate.status?.message);
            }
        } else if artifactUpdate is a2a:TaskArtifactUpdateEvent {
            string? text2 = firstPartText(artifactUpdate.artifact.parts);
            io:println("  [artifact] ", text2 ?: "(no text part)");
            if text2 is string {
                replyText += text2;
            }
        } else {
            io:println("  [unrecognized event] ", event.toJsonString());
        }
    }

    if clarificationText is string {
        io:println("  [clarification requested] ", clarificationText);
    }

    return {replyText, clarificationText, taskId: lastTaskId, contextId: lastContextId, state: lastState};
}

# Names the concrete A2AError subtype of an error, so a failure printed to
# the console says exactly what went wrong (e.g. UnsupportedOperationError)
# rather than just a message. Falls back to a generic label for anything
# that isn't a typed A2AError at all -- e.g. a raw Ballerina/http-layer
# failure (network unreachable, connection reset), which the library
# doesn't wrap. Reused pattern from demo/main.bal.
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

# + task - the task to extract the first artifact's text from
# + return - the first text part's content, if any
function firstArtifactText(a2a:Task task) returns string? {
    if task.artifacts.length() == 0 {
        return ();
    }
    return firstPartText(task.artifacts[0].parts);
}

# + message - the status message to extract text from, if any
# + return - the first text part's content, if any
function firstMessagePartText(a2a:Message? message) returns string? {
    if message is () {
        return ();
    }
    return firstPartText(message.parts);
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
