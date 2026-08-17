import ballerina/a2a;
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
    // Content blocks aren't always just one text block at index 0 -- a
    // "thinking" block (extended thinking) can precede it, with no "text"
    // field of its own. Find the first genuine text block instead of
    // assuming position.
    foreach json block in contentBlocks {
        map<json>|error blockMap = block.ensureType();
        if blockMap is error {
            continue;
        }
        if blockMap["type"] == "text" {
            string|error text = blockMap["text"].ensureType();
            if text is string {
                return text;
            }
        }
    }
    return error("Anthropic response had no text content block: " + responseJson.toJsonString());
}

# Strips any leading/trailing prose or Markdown code fences around a JSON
# object and returns just the outermost `{...}` slice, since models
# sometimes wrap a requested strict-JSON answer in explanation text.
#
# + text - raw model output expected to contain one JSON object
# + return - the outermost `{...}` substring, or an error if none is found
isolated function extractJsonObject(string text) returns string|error {
    int? startIdx = text.indexOf("{");
    int? endIdx = text.lastIndexOf("}");
    if startIdx is () || endIdx is () || endIdx < startIdx {
        return error("no JSON object found in model output: " + text);
    }
    return text.substring(startIdx, endIdx + 1);
}

# Best-effort JSON-object parse: strips prose/fences around the outermost
# `{...}` (via `extractJsonObject`), then parses it. Returns () rather than
# an error on any failure, so callers can fall back to a safe default per
# DEMO_AGENT_PLAN.md §6.8 instead of a parse failure crashing the demo.
#
# + text - raw model output expected to contain one JSON object
# + return - the parsed object, or () if it couldn't be parsed
isolated function parseJsonObject(string text) returns map<json>? {
    string|error jsonText = extractJsonObject(text);
    if jsonText is error {
        return ();
    }
    json|error parsed = jsonText.fromJsonString();
    if parsed is error {
        return ();
    }
    map<json>|error parsedMap = parsed.ensureType();
    if parsedMap is error {
        return ();
    }
    return parsedMap;
}

# Self-assessment: can the local agent answer a question from general
# knowledge, or does it need a live/tool-backed capability?
#
# + canAnswerLocally - true if no delegation is needed
# + answer - the answer itself, present only when `canAnswerLocally` is
#            true (asked for in the same call rather than a separate one,
#            to keep this design's Claude calls at four total -- see
#            DEMO_AGENT_PLAN.md §6.8)
# + reason - the model's stated reason, one short sentence
public type SelfAssessment record {|
    boolean canAnswerLocally;
    string? answer;
    string reason;
|};

# Agent-selection result: which discovered candidate (if any) should
# handle the question.
#
# + chosenBaseUrl - the chosen candidate's base URL, or () if none fit
# + skillId - the skill id that justified the choice, if any was chosen
# + reason - the model's stated reason, one short sentence
public type AgentSelection record {|
    string? chosenBaseUrl;
    string? skillId;
    string reason;
|};

# Claude call #1 (self-assess, DEMO_AGENT_PLAN.md §6.8): decide whether the
# question needs a live/tool-backed capability or can be answered from
# general knowledge. Falls back to "cannot answer locally" -- the safe
# default, since it only costs an extra discovery round rather than risking
# a fabricated answer -- if the model's reply can't be parsed as the
# requested strict JSON.
#
# + question - the user's question
# + return - the assessment, or an error only on a transport/auth failure
isolated function selfAssess(string question) returns SelfAssessment|error {
    string prompt = string `You are the reasoning layer of a client-side A2A agent. Decide whether you can answer the question below purely from your own general knowledge, or whether it needs a live/tool-backed capability that you cannot genuinely provide yourself: real-time or external-world data, an action in the world, genuine randomness, or ANY exact numeric computation or verification -- including primality checks, arithmetic, precise counting, no matter how small or seemingly trivial the numbers are. Always treat "is N prime?", "compute X", "how many..." style questions as needing tool-backed verification, even when you're confident you could mentally work out the right answer -- a real client-side agent delegates verifiable computation to a tool rather than passing off its own unverified reasoning as a checked result. Reserve "can answer locally" strictly for genuine general-knowledge questions with no computation or verification step at all (facts, definitions, explanations, opinions).

Question: ${question}

If, and only if, you can answer locally, also give the answer itself in the same response -- one or two natural sentences.

Respond with ONLY a strict JSON object, no prose, no code fences:
{"canAnswerLocally": true|false, "answer": "<your answer, only if canAnswerLocally is true; otherwise empty string>", "reason": "<one short sentence>"}`;

    string reply = check callClaude(prompt, 512);

    map<json>? parsedMap = parseJsonObject(reply);
    if parsedMap is () {
        return {canAnswerLocally: false, answer: (), reason: "could not parse self-assessment response; defaulting to needs-delegation"};
    }

    boolean canAnswerLocally = parsedMap["canAnswerLocally"] is boolean ? <boolean>parsedMap["canAnswerLocally"] : false;
    string reason = parsedMap["reason"] is string ? <string>parsedMap["reason"] : "(no reason given)";
    string? answer = ();
    if canAnswerLocally && parsedMap["answer"] is string && <string>parsedMap["answer"] != "" {
        answer = <string>parsedMap["answer"];
    }
    return {canAnswerLocally, answer, reason};
}

# Claude call #2 (select, DEMO_AGENT_PLAN.md §6.8): given the discovered
# catalog's real card/skill data, choose which agent (if any) should
# handle the question -- matching declared skills, never inventing
# capabilities. Falls back to "no suitable agent" (never a fabricated
# match) if the model's reply can't be parsed as the requested strict
# JSON, or if it names an agent that wasn't actually discovered.
#
# + question - the user's question
# + candidates - the discovered agents to choose among
# + return - the selection, or an error only on a transport/auth failure
isolated function selectAgent(string question, DiscoveredAgent[] candidates) returns AgentSelection|error {
    if candidates.length() == 0 {
        return {chosenBaseUrl: (), skillId: (), reason: "no agents were discovered"};
    }

    string catalog = "";
    foreach DiscoveredAgent candidate in candidates {
        catalog += string `- Agent "${candidate.card.name}" at ${candidate.baseUrl}: ${candidate.card.description}` + "\n";
        foreach a2a:AgentSkill skill in candidate.card.skills {
            catalog += string `    skill id="${skill.id}" name="${skill.name}" tags=${skill.tags.toString()}: ${skill.description}` + "\n";
        }
    }

    string prompt = string `You are the reasoning layer of a client-side A2A agent. You cannot answer the question below yourself; you must delegate it to one of the agents discovered below, chosen ONLY by matching the question to their declared skills. Do not invent capabilities an agent doesn't declare. If none of them genuinely fit, say so honestly.

Question: ${question}

Discovered agents:
${catalog}
Respond with ONLY a strict JSON object, no prose, no code fences:
{"chosenAgent": "<baseUrl>|none", "skillId": "<the matching skill id, or empty if none>", "reason": "<one short sentence>"}`;

    string reply = check callClaude(prompt, 300);

    map<json>? parsedMap = parseJsonObject(reply);
    if parsedMap is () {
        return {chosenBaseUrl: (), skillId: (), reason: "could not parse selection response; defaulting to no suitable agent"};
    }

    string chosen = parsedMap["chosenAgent"] is string ? <string>parsedMap["chosenAgent"] : "none";
    string skillId = parsedMap["skillId"] is string ? <string>parsedMap["skillId"] : "";
    string reason = parsedMap["reason"] is string ? <string>parsedMap["reason"] : "(no reason given)";

    if chosen == "none" || chosen == "" {
        return {chosenBaseUrl: (), skillId: (), reason};
    }

    // Guard against a hallucinated base URL: only accept a choice that
    // matches one of the actually-discovered candidates.
    boolean matches = false;
    foreach DiscoveredAgent candidate in candidates {
        if candidate.baseUrl == chosen {
            matches = true;
            break;
        }
    }
    if !matches {
        return {chosenBaseUrl: (), skillId: (), reason: "model chose an unrecognized agent (" + chosen + "); defaulting to no suitable agent"};
    }

    return {chosenBaseUrl: chosen, skillId: skillId == "" ? () : skillId, reason};
}

# Claude call #3 (synthesize, DEMO_AGENT_PLAN.md §6.7/§6.8): the local
# agent's own phrasing of the remote agent's verbatim reply, presented
# alongside that reply (never in place of it) so a viewer can see exactly
# what A2A delivered versus what the local model did with it. Explicitly
# instructed to preserve exact values -- numbers, rates, results -- rather
# than recompute or embellish them; this reduces, but doesn't eliminate,
# the distortion the side-by-side presentation exists to expose.
#
# + question - the original question
# + remoteReplyText - the remote agent's verbatim reply text
# + return - the synthesized answer, or an error on a transport/auth failure
isolated function synthesizeAnswer(string question, string remoteReplyText) returns string|error {
    string prompt = string `You are the reasoning layer of a client-side A2A agent, presenting an answer you obtained by delegating to another agent. Rephrase the remote agent's reply below as your own answer to the original question, in one or two natural sentences. Preserve every exact value from the reply -- numbers, rates, names, results -- verbatim; do not recompute, round differently, or embellish them. Do not add information the remote reply didn't provide.

Original question: ${question}
Remote agent's reply: ${remoteReplyText}

Respond with ONLY the synthesized answer text -- no prose about what you're doing, no surrounding quotation marks.`;

    return callClaude(prompt, 300);
}

# Claude call #4 (answer clarification, scripted mode only,
# DEMO_AGENT_PLAN.md §6.5): infer the missing detail from the original
# question plus the remote agent's clarification text, since no user is
# available to answer it themselves in scripted mode. Never fabricates --
# returns an error if the original question doesn't genuinely contain
# enough information to infer an answer, so the caller can abort that
# scenario cleanly instead of guessing.
#
# + originalQuestion - the user's original question
# + clarificationText - the remote agent's clarification request
# + return - the inferred reply text, or an error if none can be inferred
#            (including a transport/auth failure)
isolated function answerClarificationAsScripted(string originalQuestion, string clarificationText) returns string|error {
    string prompt = string `You are the reasoning layer of a client-side A2A agent running unattended -- no user is available to answer follow-up questions. A remote agent you delegated to has asked a clarifying question. Infer the missing detail from the original question alone, if it is genuinely present there (e.g. "What is 100 USD in EUR?" implies "to euros" for a "which currency?" clarification). Do not guess if the original question truly doesn't contain the answer.

Original question: ${originalQuestion}
Remote agent's clarification request: ${clarificationText}

Respond with ONLY a strict JSON object, no prose, no code fences:
{"canInfer": true|false, "reply": "<the inferred reply to send back, only if canInfer is true>"}`;

    string reply = check callClaude(prompt, 256);

    map<json>? parsedMap = parseJsonObject(reply);
    if parsedMap is () {
        return error("could not parse clarification-answer response");
    }
    boolean canInfer = parsedMap["canInfer"] is boolean ? <boolean>parsedMap["canInfer"] : false;
    if !canInfer {
        return error("could not infer the missing detail from the original question");
    }
    string? replyText = parsedMap["reply"] is string ? <string>parsedMap["reply"] : ();
    if replyText is () || replyText == "" {
        return error("model said it could infer a reply but gave none");
    }
    return replyText;
}
