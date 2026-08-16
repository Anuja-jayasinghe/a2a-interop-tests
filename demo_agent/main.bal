import ballerina/io;

// Build order step 4 (DEMO_AGENT_PLAN.md §7): delegation (streaming),
// verified against scenarios 2-4 from §6.6.
public function main() returns error? {
    string[] scenarios = [
        "Is 97 a prime number?",
        "Roll a 20-sided die.",
        "What is 100 USD in EUR?"
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
        string? chosenUrl = selection.chosenBaseUrl;
        if chosenUrl is () {
            io:println("  -> no suitable agent: ", selection.reason);
            continue;
        }
        io:println("  -> chose ", chosenUrl, " skill=", selection.skillId ?: "?", " reason=", selection.reason);

        DiscoveredAgent? chosenAgent = ();
        foreach DiscoveredAgent candidate in discovered {
            if candidate.baseUrl == chosenUrl {
                chosenAgent = candidate;
                break;
            }
        }
        if chosenAgent is () {
            io:println("  -> internal error: chosen agent not found among discovered candidates");
            continue;
        }

        DelegationResult result = check delegate(chosenAgent.card, question);
        io:println("  reply text: ", result.replyText);
        io:println("  final state: ", result.state ?: "(none)");
        io:println();
    }
}
