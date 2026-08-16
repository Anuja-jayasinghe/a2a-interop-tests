import ballerina/io;

// Build order step 3 (DEMO_AGENT_PLAN.md §7): selection, verified against
// scenarios 1-5 from §6.6 before delegation is wired on top.
public function main() returns error? {
    string[] scenarios = [
        "What is the capital of France?",
        "Is 97 a prime number?",
        "Roll a 20-sided die.",
        "What is 100 USD in EUR?",
        "Book me a flight to Tokyo."
    ];

    foreach string question in scenarios {
        io:println("================================================================");
        io:println("Question: ", question);

        io:println("=== [1] SELF-ASSESS ===");
        SelfAssessment assessment = check selfAssess(question);
        io:println("  canAnswerLocally=", assessment.canAnswerLocally, " reason=", assessment.reason);
        if assessment.canAnswerLocally {
            io:println("  -> self-answer branch (no delegation)");
            continue;
        }

        DiscoveredAgent[] discovered = discoverAgents();

        io:println("=== [3] SELECT ===");
        AgentSelection selection = check selectAgent(question, discovered);
        string? chosen = selection.chosenBaseUrl;
        if chosen is string {
            io:println("  -> chose ", chosen, " skill=", selection.skillId ?: "?", " reason=", selection.reason);
        } else {
            io:println("  -> no suitable agent: ", selection.reason);
        }
        io:println();
    }
}
