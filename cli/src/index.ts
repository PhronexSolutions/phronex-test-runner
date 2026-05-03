import { mkdirSync } from "fs";
import { dirname, resolve } from "path";
import { MCPStateServer } from "./mcp/test-state/server";
import { inputs } from "./utils/args";
import { startTest, resolveParams } from "./prompts/start-test";
import { logger } from "./utils/logger";
import { TestReporter } from "./utils/test-reporter";
import type { TestCase } from "./types/test-case";

// Start the MCP state server.
// This manages the state for the active test case.
// Pass resultsPath so the server can flush step-outcomes.json after each
// update_test_step call — gives pipeline visibility into real step outcomes
// even when a journey hits the turn limit before saveResults() is called.
const server = new MCPStateServer(3001, inputs.resultsPath);
await server.start();

const reporter = new TestReporter(inputs.resultsPath);

logger.info(`Detected ${inputs.testCases.length} test cases.`);

// 1. State capture map: journeyId → saved state file path
const capturedStates = new Map<string, string>();

// 2. Kahn's topological sort — parents before children
function topoSort(cases: TestCase[]): TestCase[] {
    const idSet = new Set(cases.map(c => c.id));
    const inDegree = new Map<string, number>();
    const children = new Map<string, string[]>();
    for (const c of cases) {
        inDegree.set(c.id, 0);
        children.set(c.id, []);
    }
    for (const c of cases) {
        if (c.dependsOn && idSet.has(c.dependsOn)) {
            inDegree.set(c.id, (inDegree.get(c.id) ?? 0) + 1);
            children.get(c.dependsOn)!.push(c.id);
        }
    }
    const queue: string[] = [];
    for (const [id, deg] of inDegree) {
        if (deg === 0) queue.push(id);
    }
    const order: TestCase[] = [];
    const caseById = new Map(cases.map(c => [c.id, c]));
    while (queue.length > 0) {
        const id = queue.shift()!;
        order.push(caseById.get(id)!);
        for (const child of children.get(id) ?? []) {
            const newDeg = (inDegree.get(child) ?? 1) - 1;
            inDegree.set(child, newDeg);
            if (newDeg === 0) queue.push(child);
        }
    }
    // Cycle detection fallback — shouldn't happen with well-formed input
    for (const c of cases) {
        if (!order.includes(c)) {
            logger.warn("topoSort_cycle_fallback", { test_id: c.id });
            order.push(c);
        }
    }
    return order;
}

// 3. runJourney helper
async function runJourney(
    testCase: TestCase,
    server: MCPStateServer,
    reporter: TestReporter,
    parentStatePath: string | null,
): Promise<void> {
    const startTime = new Date();
    logger.info("Starting test case", { test_id: testCase.id });
    server.clearState();

    // Resolve params before setting state — Claude sees substituted step text
    const resolvedSteps = resolveParams(testCase.steps, testCase.params ?? {});

    // Shared roots: append a synthetic step instructing Claude to save browser
    // storage state (cookies + localStorage) so child nodes can load it via
    // --storage-state.  The step uses the Playwright MCP browser_storage_state
    // tool which writes the state JSON to a specified filename.
    const steps = (testCase.isSharedRoot && testCase.stateOutputPath)
        ? [
            ...resolvedSteps,
            {
                id: resolvedSteps.length + 1,
                description: `IMPORTANT — Save browser session: Call the mcp__cctr-playwright__browser_storage_state tool with filename set to "${resolve(testCase.stateOutputPath)}" to save cookies and localStorage for downstream test nodes. This step is critical — without it, dependent journeys will fail.`,
                status: "pending" as const,
            },
        ]
        : resolvedSteps;

    const resolvedTestCase = { ...testCase, steps };
    server.setTestState(resolvedTestCase);

    for await (const message of startTest(resolvedTestCase, parentStatePath)) {
        logger.debug("Received Claude Code message", {
            test_id: testCase.id,
            message: JSON.stringify(message),
        });
    }

    const testState = server.getState();
    if (!testState) {
        logger.error("test_state_not_found", { test_id: testCase.id });
        throw new Error(`Test state not found for '${testCase.id}'`);
    }

    const endTime = new Date();
    reporter.addTestResult(testState, startTime, endTime);
    logger.info("completed_test_case", {
        ...testState,
        succeeded: testState?.steps.every((step) => step.status === "passed"),
    });
}

// 4. Pre-create directories for state output paths
for (const tc of inputs.testCases) {
    if (tc.stateOutputPath) {
        mkdirSync(dirname(resolve(tc.stateOutputPath)), { recursive: true });
    }
}

// 5. Main loop — topo-sorted so parents always run before children
const orderedCases = topoSort(inputs.testCases);
for (const testCase of orderedCases) {
    // Resolve parent state: if parent captured a state file, pass it down
    const parentStatePath = testCase.dependsOn
        ? (capturedStates.get(testCase.dependsOn) ?? null)
        : null;

    await runJourney(testCase, server, reporter, parentStatePath);

    // Record output state path for downstream nodes
    if (testCase.stateOutputPath) {
        capturedStates.set(testCase.id, testCase.stateOutputPath);
    }
}

// Generate and save test reports
reporter.saveResults(inputs.resultsPath);

server.stop();
