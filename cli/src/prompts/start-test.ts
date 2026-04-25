import { which } from "bun";
import { dirname, resolve as pathResolve } from "path";
import { systemPrompt } from "./system";
import { query } from "@anthropic-ai/claude-code";
import { inputs } from "../utils/args";
import type { TestCase } from "../types/test-case";

/**
 * Absolute filesystem path to the @playwright/mcp CLI script.
 *
 * The package's `exports` field intentionally does not export `cli.js`, so
 * `require.resolve("@playwright/mcp/cli.js")` throws ERR_PACKAGE_PATH_NOT_EXPORTED.
 * Resolve via the always-exported `package.json` instead, then read the
 * declared `bin.playwright-mcp` entry point and join.
 *
 * This avoids spawning via `npx`/`bunx`, which on Windows have unreliable
 * cache initialisation when invoked from a child process (npm-cache _npx
 * directory ENOENT errors observed in Phase 67-05).
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
 * Resolve a path that the @anthropic-ai/claude-code SDK can spawn correctly.
 *
 * On Windows, `bun.which("claude")` may return a path to a Bun-compiled
 * `claude.exe` shim. The SDK's spawn pattern is:
 *
 *   spawn(executable, [...executableArgs, pathToClaudeCodeExecutable, ...args])
 *
 * where `executable` defaults to `"bun"` (when run under Bun) or `"node"`.
 * Both interpreters fail when handed an `.exe` because they try to evaluate
 * it as a JavaScript source file. The fix is to pass the bundled `cli.js`
 * path directly.
 */
const resolveClaudeCliPath = (): string => {
    // Prefer the JS entrypoint of the bundled SDK package.
    try {
        // eslint-disable-next-line @typescript-eslint/no-var-requires
        const cliJsPath = require.resolve("@anthropic-ai/claude-code/cli.js");
        if (cliJsPath) return cliJsPath;
    } catch {
        // fall through
    }
    // Fallback: bun's which() — accepts the risk of the exe path on Windows.
    const fallback = which("claude");
    if (!fallback) {
        throw new Error(
            "Claude not found via require.resolve nor PATH. Did you run `bun install`?",
        );
    }
    return fallback;
};

export const startTest = (testCase: TestCase) => {
    const claudePath = resolveClaudeCliPath();
    if (!claudePath) {
        throw new Error("Claude not found on PATH. Did you run `bun install`?");
    }
    return query({
        prompt: "Query the test plan from mcp__testState__get_test_plan MCP tool to get started.",
        options: {
            customSystemPrompt: systemPrompt(),
            maxTurns: inputs.maxTurns,
            pathToClaudeCodeExecutable: claudePath,
            model: inputs.model,
            mcpServers: {
                "cctr-playwright": {
                    // Explicit type:"stdio" — required by Claude Code >= 1.0.88.
                    // Older versions inferred from `command`; newer ones silently
                    // drop entries lacking explicit `type`.
                    type: "stdio",
                    // Direct node spawn of the @playwright/mcp cli.js. Avoids
                    // npx (which has cache-ENOENT issues on Windows when spawned
                    // from a child process — see investigation in
                    // .planning/phases/67-qa-skills/67-05-SUMMARY.md). The
                    // package is now a direct dependency of phronex-test-runner;
                    // require.resolve gives the absolute path that survives
                    // re-spawning.
                    command: "node",
                    args: [
                        playwrightMcpCliPath(),
                        "--output-dir",
                        `${inputs.resultsPath}/${testCase.id}/playwright`,
                        // NOTE: `--save-trace` was supported in @playwright/mcp
                        // v0.0.31 but DROPPED in v0.0.70+. Including it causes
                        // the MCP server to exit with "unknown option" before
                        // the JSON-RPC handshake completes. Output traces are
                        // still saved by default into --output-dir.
                        "--image-responses",
                        "omit",
                    ],
                },
                "cctr-state": {
                    type: "http",
                    url: "http://localhost:3001/",
                    headers: {
                        "Content-Type": "application/json",
                    },
                },
            },
            allowedTools: [
                // Playwright MCP tools for interacting with the browser
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
                // Custom MCP tools for managing the test state
                "mcp__cctr-state__get_test_plan",
                "mcp__cctr-state__update_test_step",
            ],
        },
    });
};
