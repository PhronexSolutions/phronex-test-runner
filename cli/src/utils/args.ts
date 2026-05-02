import { readFileSync } from "fs";
import { testCaseSchema, type TestCase } from "../types/test-case";
import z from "zod";
import { logger } from "./logger";
import { Command } from "commander";

interface CLIOptions {
    testsPath: string;
    resultsPath: string;
    verbose: boolean;
    maxTurns: number;
    screenshots: boolean;
    model?: string;
    runJourney?: string;
}

const program = new Command()
    .requiredOption("-t, --testsPath <path>", "Path to the tests file")
    .option("-o, --resultsPath <path>", "Path to the results file", `./results/${new Date().getMilliseconds()}`)
    .option("-v, --verbose", "Verbose output, including all Claude Code messages.")
    .option("-s, --screenshots", "Take screenshots of the browser at each step.")
    .option("--maxTurns <turns>", "Maximum number of turns Claude Code can take for each test case.", "30")
    .option("-m, --model <model>", "The model to use for the test run.")
    .option("--runJourney <id>", "Run only the journey with this id and its dependsOn ancestors")
    .parse(process.argv);

const args = program.opts<CLIOptions>();

// Read in the test file.
const testCasesJson = readFileSync(args.testsPath, "utf8");
let testCases: TestCase[];
try {
    testCases = z.array(testCaseSchema).parse(JSON.parse(testCasesJson));
} catch (error) {
    logger.error("Error parsing cases from tests file.", { error });
    process.exit(1);
}

if (args.runJourney) {
    const targetId = args.runJourney;
    const caseById = new Map(testCases.map(c => [c.id, c]));

    if (!caseById.has(targetId)) {
        logger.error(`--run-journey: journey '${targetId}' not found in tests file.`);
        process.exit(1);
    }

    // Walk the dependsOn chain from target up to root
    const chain: string[] = [];
    let current: string | undefined = targetId;
    while (current) {
        chain.unshift(current); // prepend so ancestors come first
        const node = caseById.get(current);
        current = node?.dependsOn && caseById.has(node.dependsOn) ? node.dependsOn : undefined;
    }

    testCases = testCases.filter(c => chain.includes(c.id));
    // Preserve chain order (ancestors first)
    testCases.sort((a, b) => chain.indexOf(a.id) - chain.indexOf(b.id));
}

const inputs: CLIOptions & { testCases: TestCase[] } = {
    ...args,
    testCases,
};

export { inputs };
