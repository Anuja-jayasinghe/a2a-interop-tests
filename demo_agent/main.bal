import ballerina/io;

// Build order step 2 (DEMO_AGENT_PLAN.md §7): discovery, verified against
// live agents before selection/delegation are wired on top of it.
public function main() returns error? {
    DiscoveredAgent[] discovered = discoverAgents();
    io:println();
    io:println("Discovered ", discovered.length(), " agent(s).");
}
