import ballerina/a2a;
import ballerina/http;
import ballerina/io;

# One discovered candidate: its base URL plus the Agent Card fetched from
# it via well-known URI discovery.
#
# + baseUrl - the candidate's base URL, from the configured pool
# + card - the AgentCard fetched from `baseUrl`
public type DiscoveredAgent record {|
    string baseUrl;
    a2a:AgentCard card;
|};

// This pool is the spec's *Direct Configuration* bullet (§8.2, third
// bullet) -- the spec defines no registry wire protocol ("Registries/
// Catalogs" is named with zero normative detail), so a hardcoded list of
// base URLs is the honest label for how these candidates were selected.
// It is NOT the spec mechanism itself; that's the resolveAgentCard step
// below. See DEMO_AGENT_PLAN.md §4.
final string[] CANDIDATE_AGENT_URLS = [
    "http://127.0.0.1:9999", // Hello World Agent
    "http://localhost:10999", // Currency Conversion Agent (ADK)
    "http://localhost:10000", // Currency Agent (LangGraph)
    "http://localhost:11000" // Dice Agent
];

// dice_agent's Quarkus dev server doesn't negotiate h2c (HTTP/2 cleartext)
// correctly with Ballerina's default HTTP/2 client, surfacing as "Agent
// Card fetch failed with HTTP 400". Harmless for the three Python agents,
// so applied unconditionally to keep this file free of per-agent
// branching -- same as demo/main.bal.
final http:ClientConfiguration AGENT_CLIENT_CONFIG = {httpVersion: http:HTTP_1_1};

# Resolves the Agent Card of every candidate in the configured pool via
# well-known URI discovery (spec §8.2, first bullet -- `a2a:resolveAgentCard`
# performs exactly the GET against `/.well-known/agent-card.json` that
# bullet describes). Unreachable candidates are skipped, not fatal: this is
# a normal demo state (see DEMO_AGENT_PLAN.md §6.4), not an error state.
# Prints the discovered catalog -- agent name, base URL, and each skill's
# id/name/tags -- as it goes, since the reasoning trace is the demo.
#
# + return - the discovered agents; possibly fewer than the configured pool
function discoverAgents() returns DiscoveredAgent[] {
    io:println("=== [2] DISCOVER ===");
    io:println("  candidate pool (Direct Configuration, spec section 8.2): ", CANDIDATE_AGENT_URLS.length(), " configured base URL(s)");

    DiscoveredAgent[] discovered = [];
    foreach string url in CANDIDATE_AGENT_URLS {
        a2a:AgentCard|error card = a2a:resolveAgentCard(url, AGENT_CLIENT_CONFIG);
        if card is error {
            io:println("  [unreachable] ", url, " -- ", card.message());
            continue;
        }

        io:println("  [found] ", card.name, " @ ", url, " (well-known URI discovery, spec section 8.2)");
        foreach a2a:AgentSkill skill in card.skills {
            io:println("      skill \"", skill.id, "\" (", skill.name, ") tags=", skill.tags.toString());
        }
        discovered.push({baseUrl: url, card});
    }

    io:println("  discovered ", discovered.length(), " of ", CANDIDATE_AGENT_URLS.length(), " candidate(s)");
    return discovered;
}
