import ballerina/a2a;
import ballerina/io;

// Build order step 6 (DEMO_AGENT_PLAN.md §7): interactive mode. Dispatch
// on args comes in step 8 (scripted mode); for now this package only runs
// interactively.
public function main(string... args) returns error? {
    io:println("demo_agent -- interactive mode. Type a question, or 'quit' to exit.");
    while true {
        string line = io:readln("> ");
        if line == "quit" {
            break;
        }
        if line.trim() == "" {
            continue;
        }
        error? result = handleQuestion(line);
        if result is error {
            io:println("  [failed] ", result.message());
        }
        io:println();
    }
    io:println("Goodbye.");
}

# Runs the full flow (DEMO_AGENT_PLAN.md §6.3) for one fresh question:
# self-assess, and if that alone doesn't answer it, discover + select +
# delegate + present. Shared by both run modes (§6.9) so the agent logic
# isn't duplicated between them.
#
# + question - the user's question
# + return - an error only on a transport/auth failure; routing outcomes
#            (self-answered, no suitable agent, delegation not completed)
#            are printed, not raised
function handleQuestion(string question) returns error? {
    io:println("=== [1] SELF-ASSESS ===");
    SelfAssessment assessment = check selfAssess(question);
    io:println("  canAnswerLocally=", assessment.canAnswerLocally, " reason=", assessment.reason);
    if assessment.canAnswerLocally {
        io:println("=== [5] PRESENT (self-answer, no delegation) ===");
        io:println(assessment.answer ?: "(no answer provided)");
        return;
    }

    DiscoveredAgent[] discovered = discoverAgents();

    io:println("=== [3] SELECT ===");
    AgentSelection selection = check selectAgent(question, discovered);
    string? chosenUrl = selection.chosenBaseUrl;
    if chosenUrl is () {
        io:println("  -> no suitable agent: ", selection.reason);
        return;
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
        return;
    }
    DiscoveredAgent agent = <DiscoveredAgent>chosenAgent;

    DelegationResult result = check delegate(agent.card, question);
    if result.state != a2a:TASK_STATE_COMPLETED {
        io:println("  -> delegation ended in state=", result.state ?: "(none)", "; no final answer to present");
        return;
    }

    string synthesized = check synthesizeAnswer(question, result.replyText);
    presentAnswer(agent, selection.skillId ?: "?", selection.reason, result.replyText, synthesized);
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
}
