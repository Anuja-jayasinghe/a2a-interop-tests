import ballerina/a2a;
import ballerina/io;

// Build order step 5 (DEMO_AGENT_PLAN.md §7): presentation, verified
// against scenarios 2-4 from §6.6.
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
        DiscoveredAgent agent = <DiscoveredAgent>chosenAgent;

        DelegationResult result = check delegate(agent.card, question);
        if result.state != a2a:TASK_STATE_COMPLETED {
            io:println("  -> delegation did not complete (state=", result.state ?: "(none)", "); skipping presentation");
            continue;
        }

        string synthesized = check synthesizeAnswer(question, result.replyText);
        presentAnswer(agent, selection.skillId ?: "?", selection.reason, result.replyText, synthesized);
    }
}

# Prints the two-block, clearly-labeled presentation from §6.7: the remote
# agent's reply verbatim, then the local agent's synthesized version, then
# attribution (which agent, which skill, why it was picked).
#
# + agent - the agent delegated to
# + skillId - the skill id that justified the choice
# + reason - why that agent/skill was chosen
# + verbatimReply - the remote agent's reply text, exactly as received
# + synthesized - the local agent's Claude-synthesized version
function presentAnswer(DiscoveredAgent agent, string skillId, string reason, string verbatimReply, string synthesized) {
    io:println("=== [5] PRESENT ===");
    io:println("--- remote agent's reply (verbatim, exactly as received over A2A) ---");
    io:println(verbatimReply);
    io:println();
    io:println("--- local agent's answer (Claude-synthesized from the above) ---");
    io:println(synthesized);
    io:println();
    io:println("  [via] ", agent.card.name, " (", agent.baseUrl, "), skill \"", skillId, "\"");
    io:println("  [why] ", reason);
    io:println();
}
