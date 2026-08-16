import ballerina/io;

// Spike (DEMO_AGENT_PLAN.md §7 step 1): one hardcoded Claude round-trip,
// printed, to prove the Anthropic call works before building anything else
// on top of it.
public function main() returns error? {
    string prompt = "In one short sentence, what is the A2A (Agent2Agent) protocol?";
    io:println("Prompt: ", prompt);
    string reply = check callClaude(prompt);
    io:println("Reply:  ", reply);
}
