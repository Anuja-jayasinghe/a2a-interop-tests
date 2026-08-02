import ballerina/a2a;
import ballerina/http;
import ballerina/os;
import ballerina/test;

# Exists solely to make this package declare a *direct* dependency on
# ballerina/http, so its version can be pinned in Ballerina.toml.
# ballerina/grpc (pulled in transitively via ballerina/a2a's gRPC binding)
# doesn't declare a Ballerina-level dependency on http at all -- its native
# Java code calls http's HttpLogManager directly -- so without this,
# Ballerina.toml's http version pin is silently ignored and the resolver
# picks whatever's newest on central, which can be binary-incompatible
# with the grpc module's compiled Java code. See Ballerina.toml's comment
# on the http [[dependency]] entry.
#
# + return - an empty http:ClientConfiguration; never actually called
isolated function unusedHttpVersionPinAnchor() returns http:ClientConfiguration {
    return {};
}

# Base URL for the interop tests. Reads A2A_TEST_SERVER_URL so tests can
# point at a real reference server; falls back to a placeholder localhost
# URL when unset -- harmless since every interop test no-ops via
# isRealServerConfigured() before it would ever connect.
#
# + return - the base URL to run tests against
public isolated function getServerBaseUrl() returns string {
    string envUrl = os:getEnv("A2A_TEST_SERVER_URL");
    if envUrl != "" {
        return envUrl;
    }
    return "http://localhost:19199";
}

# Unwraps a stream.next() result, failing the test immediately if the
# stream ended or returned an error where a value was expected.
#
# + result - the raw return value of a StreamResponse stream's next()
# + return - the decoded StreamResponse, or an error
public isolated function expectValue(record {| a2a:StreamResponse value; |}|error? result) returns a2a:StreamResponse|error {
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

# + task - the task to sanity-check
public isolated function assertValidTask(a2a:Task task) {
    test:assertTrue(task.id.length() > 0, "Task.id should be non-empty");
}

# + artifact - the artifact to extract text from
# + return - the first non-nil text part's content, if any
public isolated function extractArtifactText(a2a:Artifact artifact) returns string? {
    foreach a2a:Part part in artifact.parts {
        string? text = part?.text;
        if text is string {
            return text;
        }
    }
    return ();
}
