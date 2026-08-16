import ballerina/io;

// Build order step 8 (DEMO_AGENT_PLAN.md §7): the scripted scenario run,
// all six scenarios from §6.6, unattended.

# Runs all six demo scenarios from §6.6 end to end, unattended.
# Clarification requests (scenario 6) are answered by Claude inferring the
# missing detail from the original question (§6.5's scripted path), since
# no user is available to answer them.
function runScripted() returns error? {
    string[] scenarios = [
        "What is the capital of France?", // 1: self-answer, no delegation
        "Is 97 a prime number?", // 2: -> Dice Agent, prime_checker
        "Roll a 20-sided die.", // 3: -> Dice Agent, dice_roller
        "What is 100 USD in EUR?", // 4: -> a currency agent
        "Book me a flight to Tokyo.", // 5: no suitable agent
        "Convert 100 dollars." // 6: -> currency agent -> INPUT_REQUIRED -> clarification
    ];

    foreach int i in 0 ..< scenarios.length() {
        string question = scenarios[i];
        io:println("################################################################");
        io:println("Scenario ", i + 1, ": ", question);
        io:println("################################################################");
        error? result = handleQuestion(question, answerClarificationAsScripted);
        if result is error {
            io:println("  [failed] ", result.message());
        }
        io:println();
    }
}
