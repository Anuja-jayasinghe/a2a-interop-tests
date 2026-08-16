import ballerina/http;
import ballerina/os;

// Anthropic Messages API, called directly over ballerina/http rather than
// through ballerinax/ai -- see DEMO_AGENT_PLAN.md §6.8 for why: only the
// `ballerina` org is warmed in this machine's local package cache, and this
// package already carries a documented http-version-pin landmine (see
// http_version_pin.bal) that a new connector's own http/io constraints
// would be the likeliest thing to re-trigger.
const string ANTHROPIC_API_BASE = "https://api.anthropic.com";
const string CLAUDE_MODEL = "claude-sonnet-5";
const string ANTHROPIC_VERSION = "2023-06-01";

final http:Client anthropicClient = check new (ANTHROPIC_API_BASE);

# Reads the Anthropic API key from the environment. Never hardcoded, never
# logged.
#
# + return - the key, or an actionable error if it isn't set
isolated function anthropicApiKey() returns string|error {
    string key = os:getEnv("ANTHROPIC_API_KEY");
    if key == "" {
        return error("ANTHROPIC_API_KEY is not set. Export it before running demo_agent " +
                "(see the .env at the A2A_Project root, outside every git repo on purpose).");
    }
    return key;
}

# Makes one call to the Anthropic Messages API with a single user-turn
# prompt and returns the reply's text.
#
# + prompt - the user-turn prompt text
# + maxTokens - the max_tokens budget for the reply
# + return - the reply text, or an error on a transport/auth/parse failure
isolated function callClaude(string prompt, int maxTokens = 1024) returns string|error {
    string apiKey = check anthropicApiKey();

    json requestBody = {
        model: CLAUDE_MODEL,
        max_tokens: maxTokens,
        messages: [{role: "user", content: prompt}]
    };

    http:Response response = check anthropicClient->post(
        "/v1/messages",
        requestBody,
        headers = {
            "x-api-key": apiKey,
            "anthropic-version": ANTHROPIC_VERSION,
            "content-type": "application/json"
        }
    );

    json responseJson = check response.getJsonPayload();
    map<json> responseMap = check responseJson.ensureType();

    if response.statusCode != 200 {
        json errorField = responseMap["error"] ?: responseJson;
        return error("Anthropic API returned HTTP " + response.statusCode.toString() + ": " + errorField.toJsonString());
    }

    json[] contentBlocks = check responseMap["content"].ensureType();
    if contentBlocks.length() == 0 {
        return error("Anthropic response had no content blocks: " + responseJson.toJsonString());
    }
    map<json> firstBlock = check contentBlocks[0].ensureType();
    string text = check firstBlock["text"].ensureType();
    return text;
}
