import ballerina/a2a;
import ballerina/os;
import ballerina/test;

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
