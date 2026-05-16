import { which } from "bun";
import { spawn } from "child_process";
import { createInterface } from "readline";
import { dirname, resolve as pathResolve } from "path";
import { writeFileSync, unlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { systemPrompt } from "./system";
import { inputs } from "../utils/args";
import type { TestCase } from "../types/test-case";
import { logger } from "../utils/logger";

/**
 * Absolute filesystem path to the @playwright/mcp CLI script.
 *
 * The package's `exports` field intentionally does not export `cli.js`, so
 * `require.resolve("@playwright/mcp/cli.js")` throws ERR_PACKAGE_PATH_NOT_EXPORTED.
 * Resolve via the always-exported `package.json` instead, then read the
 * declared `bin.playwright-mcp` entry point and join.
 */
const playwrightMcpCliPath = (): string => {
    const pkgPath = require.resolve("@playwright/mcp/package.json");
    const pkg = require("@playwright/mcp/package.json");
    const binEntry =
        typeof pkg.bin === "string"
            ? pkg.bin
            : pkg.bin?.["playwright-mcp"] ?? Object.values(pkg.bin ?? {})[0];
    if (!binEntry) {
        throw new Error(
            "@playwright/mcp package.json has no usable `bin` entry; " +
                "did you run `bun add @playwright/mcp`?",
        );
    }
    return pathResolve(dirname(pkgPath), binEntry);
};

/**
 * Substitute {{paramName}} placeholders in step descriptions with values from params.
 * Unknown keys are left as-is (e.g. {{unknownKey}} stays unchanged).
 */
export function resolveParams(steps: TestCase["steps"], params: Record<string, unknown>): TestCase["steps"] {
    return steps.map(step => ({
        ...step,
        description: step.description.replace(/\{\{(\w+)\}\}/g, (_, key) =>
            key in params ? String(params[key]) : `{{${key}}}`
        ),
    }));
}

export async function* startTest(testCase: TestCase, storageStatePath: string | null = null): AsyncGenerator<unknown> {
    const claudePath = which("claude");
    if (!claudePath) {
        throw new Error("Claude CLI not found on PATH. Is Claude Code installed?");
    }

    const needsStorageCaps = !!testCase.stateOutputPath || storageStatePath !== null;
    const playwrightArgs: string[] = [
        playwrightMcpCliPath(),
        "--output-dir",
        `${inputs.resultsPath}/${testCase.id}/playwright`,
        "--image-responses",
        "omit",
        "--isolated",
        ...(needsStorageCaps ? ["--caps", "storage"] : []),
    ];
    if (storageStatePath !== null) {
        playwrightArgs.push("--storage-state", storageStatePath);
    }

    const mcpConfig = {
        mcpServers: {
            "cctr-playwright": {
                type: "stdio",
                command: "node",
                args: playwrightArgs,
            },
            "cctr-state": {
                type: "http",
                url: `http://localhost:${inputs.statePort}/`,
                headers: {
                    "Content-Type": "application/json",
                },
            },
        },
    };

    const mcpConfigPath = join(tmpdir(), `ptr-mcp-${testCase.id}-${Date.now()}.json`);
    writeFileSync(mcpConfigPath, JSON.stringify(mcpConfig));

    const allowedTools = [
        "mcp__cctr-playwright__browser_close",
        "mcp__cctr-playwright__browser_resize",
        "mcp__cctr-playwright__browser_console_messages",
        "mcp__cctr-playwright__browser_handle_dialog",
        "mcp__cctr-playwright__browser_evaluate",
        "mcp__cctr-playwright__browser_file_upload",
        "mcp__cctr-playwright__browser_install",
        "mcp__cctr-playwright__browser_press_key",
        "mcp__cctr-playwright__browser_type",
        "mcp__cctr-playwright__browser_navigate",
        "mcp__cctr-playwright__browser_navigate_back",
        "mcp__cctr-playwright__browser_navigate_forward",
        "mcp__cctr-playwright__browser_network_requests",
        "mcp__cctr-playwright__browser_snapshot",
        "mcp__cctr-playwright__browser_click",
        "mcp__cctr-playwright__browser_drag",
        "mcp__cctr-playwright__browser_hover",
        "mcp__cctr-playwright__browser_select_option",
        "mcp__cctr-playwright__browser_tab_list",
        "mcp__cctr-playwright__browser_tab_new",
        "mcp__cctr-playwright__browser_tab_select",
        "mcp__cctr-playwright__browser_tab_close",
        "mcp__cctr-playwright__browser_take_screenshot",
        "mcp__cctr-playwright__browser_wait_for",
        "mcp__cctr-playwright__browser_storage_state",
        "mcp__cctr-playwright__browser_set_storage_state",
        "mcp__cctr-state__get_test_plan",
        "mcp__cctr-state__update_test_step",
    ];

    const prompt = "Query the test plan from mcp__cctr-state__get_test_plan MCP tool to get started.";

    const args = [
        "-p", prompt,
        "--output-format", "stream-json",
        "--model", inputs.model,
        "--max-turns", String(testCase.maxTurns ?? inputs.maxTurns),
        "--mcp-config", mcpConfigPath,
        "--strict-mcp-config",
        "--allowed-tools", allowedTools.join(","),
        "--system-prompt", systemPrompt(),
        "--permission-mode", "bypassPermissions",
    ];

    const env = { ...process.env };
    delete env.ANTHROPIC_API_KEY;

    const child = spawn(claudePath, args, {
        env,
        stdio: ["ignore", "pipe", "pipe"],
    });

    let stderrChunks = "";
    child.stderr!.on("data", (chunk: Buffer) => {
        stderrChunks += chunk.toString();
    });

    const rl = createInterface({ input: child.stdout! });

    try {
        for await (const line of rl) {
            if (!line.trim()) continue;
            try {
                const parsed = JSON.parse(line);
                yield parsed;
            } catch {
                logger.debug("non-JSON line from claude -p", { line: line.slice(0, 200) });
            }
        }
    } finally {
        try { unlinkSync(mcpConfigPath); } catch { /* already cleaned */ }
    }

    const exitCode = await new Promise<number | null>((resolve) => {
        if (child.exitCode !== null) {
            resolve(child.exitCode);
        } else {
            child.on("exit", (code) => resolve(code));
        }
    });

    if (exitCode !== 0 && exitCode !== null) {
        logger.warn("claude -p exited with non-zero code", {
            exitCode,
            testId: testCase.id,
            stderr: stderrChunks.slice(0, 500),
        });
    }
}
