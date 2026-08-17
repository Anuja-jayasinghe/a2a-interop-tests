import ballerina/a2a;
import ballerina/io;

const int MAX_CLARIFICATION_ROUNDS = 2;

// Two run commands (DEMO_AGENT_PLAN.md §6.9), dispatched on a
// command-line argument so both modes share this package's agent
// implementation instead of duplicating it:
//   bal run --sticky              -- interactive
//   bal run --sticky -- scripted  -- all six §6.6 scenarios, unattended
public function main(string... args) returns error? {
    if args.length() > 0 && args[0] == "scripted" {
        check runScripted();
        return;
    }

    io:println("demo_agent -- interactive mode. Type a question, or 'quit' to exit.");
    while true {
        string line = io:readln("> ");
        if line == "quit" {
            break;
        }
        if line.trim() == "" {
            continue;
        }
        error? result = handleQuestion(line, interactiveClarificationHandler);
        if result is error {
            io:println("  [failed] ", result.message());
        }
        io:println();
    }
    io:println("Goodbye.");
}

# How a remote agent's clarification request (§6.5) gets answered: prompt
# the user (interactive mode) or have Claude infer the missing detail from
# the original question (scripted mode, no user available).
#
# + originalQuestion - the user's original question
# + clarificationText - the remote agent's clarification request
# + return - the reply text to send back, or an error if none can be
#            obtained (aborts that turn cleanly rather than hanging or
#            guessing)
type ClarificationHandler function (string originalQuestion, string clarificationText) returns string|error;

# Interactive-mode clarification handler: prints the remote agent's
# clarification question and prompts the user for the answer directly --
# the user is in the loop, exactly as a real deployment would have them.
#
# + originalQuestion - unused; the prompt to the user only needs the
#                       clarification text itself
# + clarificationText - the remote agent's clarification request
# + return - the user's typed reply
function interactiveClarificationHandler(string originalQuestion, string clarificationText) returns string|error {
    return io:readln("  ? ");
}

# Runs the full flow (DEMO_AGENT_PLAN.md §6.3) for one fresh question:
# self-assess, and if that alone doesn't answer it, discover + select +
# delegate + present. Shared by both run modes (§6.9) so the agent logic
# isn't duplicated between them. If delegation leaves the task in
# `TASK_STATE_INPUT_REQUIRED`, resolves the clarification via
# `answerClarification` and continues the same task/context (§6.5),
# capped at `MAX_CLARIFICATION_ROUNDS` rounds so a confused agent can't
# loop forever.
#
# + question - the user's question
# + answerClarification - how to resolve a mid-delegation clarification
# + return - an error only on a transport/auth failure; routing outcomes
#            (self-answered, no suitable agent, delegation not completed,
#            clarification round cap reached) are printed, not raised
function handleQuestion(string question, ClarificationHandler answerClarification) returns error? {
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

    string turnText = question;
    string? taskId = ();
    string? contextId = ();
    int round = 0;

    while true {
        DelegationResult result = check delegate(agent.card, turnText, taskId, contextId);

        if result.state == a2a:TASK_STATE_INPUT_REQUIRED {
            string? clarification = result.clarificationText;
            if clarification is () {
                io:println("  -> agent requested clarification but sent no message text; aborting");
                return;
            }
            round += 1;
            if round > MAX_CLARIFICATION_ROUNDS {
                io:println("  -> clarification round cap (", MAX_CLARIFICATION_ROUNDS, ") reached; aborting");
                return;
            }
            string|error reply = answerClarification(question, clarification);
            if reply is error {
                io:println("  -> could not answer clarification: ", reply.message());
                return;
            }
            turnText = reply;
            taskId = result.taskId;
            contextId = result.contextId;
            continue;
        }

        if result.state != a2a:TASK_STATE_COMPLETED {
            io:println("  -> delegation ended in state=", result.state ?: "(none)", "; no final answer to present");
            return;
        }

        string synthesized = check synthesizeAnswer(question, result.replyText);
        presentAnswer(agent, selection.skillId ?: "?", selection.reason, result.replyText, synthesized);
        return;
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
}
