// Live demo: sends the exact same request to the exact same agent three
// different technical ways -- gRPC, JSON-RPC, and REST (HTTP+JSON) -- and
// prints each real answer clearly labeled as it comes back. Built for
// presenting to a non-technical audience: no stack traces, no test
// framework output, just three short, real, differing answers proving the
// same client genuinely speaks all three wire protocols against a real
// server. See DEMO_GUIDE.md and servers/dice_agent/findings.md for the
// full technical story behind why this matters.

import ballerina/a2a;
import ballerina/http;
import ballerina/io;
import ballerina/os;
import ballerina/uuid;

isolated function agentUrl() returns string {
    string envUrl = os:getEnv("A2A_DICE_AGENT_URL");
    return envUrl != "" ? envUrl : "http://localhost:11000";
}

// dice_agent's Quarkus dev-mode server doesn't negotiate h2c correctly
// with Ballerina's default HTTP/2 client -- see
// servers/dice_agent/findings.md #7.
final http:ClientConfiguration DEMO_CLIENT_CONFIG = {httpVersion: http:HTTP_1_1};

public function main() returns error? {
    string url = agentUrl();
    string question = "Can you roll a 6-sided die?";

    io:println("Sending the same request to the same agent, three different technical ways:");
    io:println(string `  "${question}"`);
    io:println();

    check askOverTransport(url, "GRPC", "gRPC     ", question);
    check askOverTransport(url, "JSONRPC", "JSON-RPC ", question);
    check askOverTransport(url, "HTTP+JSON", "REST     ", question);

    io:println();
    io:println("Same client, same agent, same question -- three different wire protocols, all working.");
}

function askOverTransport(string url, a2a:TransportBinding binding, string label, string question) returns error? {
    a2a:Client agentClient = check a2a:newClient(url, clientConfig = DEMO_CLIENT_CONFIG, binding = binding);

    a2a:Message msg = {
        messageId: uuid:createType4AsString(),
        role: a2a:ROLE_USER,
        parts: [{text: question}]
    };

    a2a:Task|a2a:Message result = check agentClient->sendMessage(msg);

    string answer = "(no text answer)";
    if result is a2a:Task {
        string? text = firstArtifactText(result);
        if text is string {
            answer = text;
        }
    } else {
        a2a:Message reply = <a2a:Message>result;
        string? text = firstPartText(reply.parts);
        if text is string {
            answer = text;
        }
    }

    io:println(string `  [${label}] -> ${answer}`);
}

isolated function firstArtifactText(a2a:Task task) returns string? {
    if task.artifacts.length() == 0 {
        return ();
    }
    return firstPartText(task.artifacts[0].parts);
}

isolated function firstPartText(a2a:Part[] parts) returns string? {
    foreach a2a:Part part in parts {
        string? text = part?.text;
        if text is string {
            return text;
        }
    }
    return ();
}
