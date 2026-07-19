import { mkdirSync, readFileSync, existsSync } from "fs";
import { dirname, resolve, basename } from "path";
import { MCPStateServer } from "./mcp/test-state/server";
import { inputs } from "./utils/args";
import { startTest, resolveParams } from "./prompts/start-test";
import { logger } from "./utils/logger";
import { TestReporter } from "./utils/test-reporter";
import type { TestCase } from "./types/test-case";
import { readControlSignal, cleanupTransientState, clearControlSignal } from "./control";

// Identifier for this run's pause/kill control file. Explicit --controlId is
// preferred (run-journeyhawk.sh passes the product slug); falls back to a
// sanitized resultsPath basename so ad-hoc invocations still work.
const controlId = inputs.controlId ?? basename(inputs.resultsPath).replace(/[^A-Za-z0-9_-]/g, "-");

// Start the MCP state server.
// This manages the state for the active test case.
// Pass resultsPath so the server can flush step-outcomes.json after each
// update_test_step call — gives pipeline visibility into real step outcomes
// even when a journey hits the turn limit before saveResults() is called.
const server = new MCPStateServer(inputs.statePort, inputs.resultsPath);
await server.start();

const reporter = new TestReporter(inputs.resultsPath);

logger.info(`Detected ${inputs.testCases.length} test cases.`);

// 1. State capture map: journeyId → saved state file path
const capturedStates = new Map<string, string>();

// 1b. Entity capture map: journeyId → recorded-entity sidecar file path.
// capturedEntities mirrors capturedStates, but the child inherits DATA (merged
// into params for {{var}} templating) rather than a browser session — which is
// why a dependent journey stays anonymous (D-05/D-10).
const capturedEntities = new Map<string, string>();

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
    parentEntities: string | null,
): Promise<void> {
    const startTime = new Date();
    logger.info("Starting test case", { test_id: testCase.id });
    server.clearState();

    // Merge the parent's recorded-entity sidecar into this journey's params BEFORE
    // templating, so {{key}} substitution resolves the runtime value the parent
    // recorded (D-07c). resolveParams itself is unchanged.
    let mergedParams: Record<string, unknown> = { ...(testCase.params ?? {}) };
    if (parentEntities && existsSync(parentEntities)) {
        try {
            const parsed = JSON.parse(readFileSync(parentEntities, "utf-8"));
            if (parsed && typeof parsed === "object") {
                mergedParams = { ...mergedParams, ...(parsed as Record<string, unknown>) };
            }
        } catch (entityErr) {
            logger.warn("parent_entities_read_failed", {
                test_id: testCase.id,
                parentEntities,
                entityErr: String(entityErr),
            });
        }
    }

    // Resolve params before setting state — Claude sees substituted step text
    const resolvedSteps = resolveParams(testCase.steps, mergedParams);

    // Pre-mark SKIP=PASS steps as passed before Claude sees them.
    // Steps whose description starts with "SKIP=PASS" are out-of-scope or
    // have a known infra gap — auto-passing them prevents the oracle LLM from
    // overriding the instruction by reporting what it actually observes.
    const autoPassedSteps = resolvedSteps.map(step =>
        step.description.trimStart().startsWith("SKIP=PASS")
            ? { ...step, status: "passed" as const }
            : step
    );

    // Any node with stateOutputPath: append a synthetic step instructing Claude
    // to save browser storage state (cookies + localStorage) so child nodes can
    // load it via --storage-state.  Both trunks (isSharedRoot) and branches need
    // this — leaves that dependsOn a branch need the branch's navigated-page state.
    const steps = (testCase.stateOutputPath)
        ? [
            ...autoPassedSteps,
            {
                id: autoPassedSteps.length + 1,
                description: `IMPORTANT — Save browser session: Call the mcp__cctr-playwright__browser_storage_state tool with filename set to "${resolve(testCase.stateOutputPath)}" to save cookies and localStorage for downstream test nodes. This step is critical — without it, dependent journeys will fail.`,
                status: "pending" as const,
            },
        ]
        : autoPassedSteps;

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
    const succeeded = testState.steps.every((step) => step.status === "passed");
    logger.info("completed_test_case", { ...testState, succeeded });

    // Real-time verdict sink — fire-and-forget, never blocks the runner.
    const sinkUrl = process.env.JOURNEYHAWK_VERDICT_SINK_URL;
    if (sinkUrl) {
        fetch(`${sinkUrl}/verdict`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                journey_id: testCase.id,
                succeeded,
                steps: testState.steps.map((s) => ({
                    id: s.id,
                    status: s.status ?? "pending",
                    error: s.error ?? null,
                })),
            }),
        }).catch(() => {}); // non-fatal: sink down = no real-time verdict, batch still runs
    }
}

// 4. Pre-create directories for state output paths
for (const tc of inputs.testCases) {
    if (tc.stateOutputPath) {
        mkdirSync(dirname(resolve(tc.stateOutputPath)), { recursive: true });
    }
    if (tc.entityOutputPath) {
        mkdirSync(dirname(resolve(tc.entityOutputPath)), { recursive: true });
    }
}

// 5. Main loop — topo-sorted so parents always run before children
const orderedCases = topoSort(inputs.testCases);
for (const testCase of orderedCases) {
    // Resolve parent state: if parent captured a state file, pass it down
    const parentStatePath = testCase.dependsOn
        ? (capturedStates.get(testCase.dependsOn) ?? null)
        : null;

    // Resolve parent entities: if parent recorded an entity sidecar, pass it down.
    // B consumes automatically when B.dependsOn === A.id AND A declared
    // entityOutputPath — no opt-in field on B (Open Question 2 / D-05).
    const parentEntities = testCase.dependsOn
        ? (capturedEntities.get(testCase.dependsOn) ?? null)
        : null;

    await runJourney(testCase, server, reporter, parentStatePath, parentEntities);

    // Record output state path for downstream nodes
    if (testCase.stateOutputPath) {
        capturedStates.set(testCase.id, testCase.stateOutputPath);
    }

    // Record output entity sidecar path for downstream nodes
    if (testCase.entityOutputPath) {
        capturedEntities.set(testCase.id, testCase.entityOutputPath);
    }

    // Pause/kill control check — evaluated ONLY between journeys, never
    // mid-journey, so a signal always takes effect after the current
    // journey's execution finishes cleanly.
    const signal = readControlSignal(controlId);
    if (signal === "KILL") {
        logger.warn("control_signal_kill", {
            after_journey: testCase.id,
            remaining: orderedCases.length - (orderedCases.indexOf(testCase) + 1),
        });
        reporter.saveResults(inputs.resultsPath);
        cleanupTransientState(controlId, inputs.testCases);
        server.stop();
        process.exit(2);
    }
    if (signal === "PAUSE") {
        logger.warn("control_signal_pause", {
            after_journey: testCase.id,
            remaining: orderedCases.length - (orderedCases.indexOf(testCase) + 1),
        });
        // Save progress but leave storageState/entity sidecars intact —
        // resuming re-invokes the same run with --skip-passed, which relies
        // on the already-recorded phronex_qa verdicts, not these files, but
        // deleting them would force every dependent journey to re-authenticate
        // from scratch on resume for no benefit.
        reporter.saveResults(inputs.resultsPath);
        server.stop();
        process.exit(3);
    }
}

// Generate and save test reports
reporter.saveResults(inputs.resultsPath);
clearControlSignal(controlId); // clean completion — never leak a stale signal into the next run

server.stop();
