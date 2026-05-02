import express, { type Request, type Response } from "express";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import type { TestCase } from "../../types/test-case.js";
import z from "zod";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import http from "http";
import { writeFileSync } from "fs";
import { join } from "path";
import { logger } from "../../utils/logger.js";
import { updateTestPlanToolInput } from "./update-test-plan-tool-input.js";

class MCPStateServer {
    private app: express.Application;
    private server: http.Server | null = null;
    private port: number;
    private mcpServer: Server;
    private transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined,
    });
    private testState: TestCase | null = null;
    private outputDir: string | null;

    constructor(port: number = 3001, outputDir: string | null = null) {
        this.port = port;
        this.outputDir = outputDir;
        this.app = express();
        this.app.use(express.json());

        // Create single MCP server instance
        this.mcpServer = new Server(
            {
                name: "test-state-server",
                version: "0.1.0",
            },
            {
                capabilities: {
                    tools: {},
                },
            }
        );

        this.setupMCPHandlers();
        this.setupRoutes();
    }

    private setupMCPHandlers() {
        // List tools
        this.mcpServer.setRequestHandler(ListToolsRequestSchema, async () => {
            return {
                tools: [
                    {
                        name: "get_test_plan",
                        description: "Get the entire test plan with current state",
                        inputSchema: {
                            type: "object",
                            properties: {},
                            additionalProperties: false,
                        },
                    },
                    {
                        name: "update_test_step",
                        description: "Update a test step with passed/failed status",
                        inputSchema: z.toJSONSchema(updateTestPlanToolInput),
                    },
                ],
            };
        });

        // Call tools
        this.mcpServer.setRequestHandler(CallToolRequestSchema, async (request) => {
            const { name, arguments: args } = request.params;

            switch (name) {
                case "get_test_plan":
                    return {
                        content: [
                            {
                                type: "text",
                                text: JSON.stringify(this.testState, null, 2),
                            },
                        ],
                    };

                case "update_test_step": {
                    const { stepId, status, error } = updateTestPlanToolInput.parse(args);
                    const step = this.testState?.steps.find((s) => s.id === stepId);

                    if (!step) {
                        throw new Error(`Step ${stepId} not found`);
                    }

                    step.status = status;
                    if (error) {
                        step.error = error;
                    }

                    // Flush step outcomes to disk after every update so the
                    // pipeline can read real outcomes even if the journey hits
                    // the turn limit before saveResults() is called.
                    if (this.outputDir && this.testState) {
                        try {
                            writeFileSync(
                                join(this.outputDir, "step-outcomes.json"),
                                JSON.stringify(
                                    {
                                        journeyId: this.testState.id,
                                        steps: this.testState.steps.map((s) => ({
                                            id: s.id,
                                            status: s.status ?? "pending",
                                            error: s.error ?? null,
                                        })),
                                    },
                                    null,
                                    2
                                )
                            );
                        } catch (writeErr) {
                            logger.debug("step-outcomes flush failed (non-fatal)", { writeErr });
                        }
                    }

                    return {
                        content: [
                            {
                                type: "text",
                                text: `Updated step ${stepId} (${step.description}) to ${status}${error ? `: ${error}` : ""}`,
                            },
                        ],
                    };
                }

                default:
                    throw new Error(`Unknown tool: ${name}`);
            }
        });
    }

    private setupRoutes() {
        this.app.post("/", async (req: Request, res: Response) => {
            this.transport.handleRequest(req, res, req.body);
        });

        this.mcpServer.connect(this.transport);
    }

    public start(): Promise<void> {
        return new Promise((resolve) => {
            this.server = this.app.listen(this.port, () => {
                logger.debug(`testState MCP Server running on port ${this.port}`);
                resolve();
            });
        });
    }

    public stop(): Promise<void> {
        return new Promise((resolve) => {
            if (this.server) {
                this.server.close(() => {
                    resolve();
                });
            } else {
                resolve();
            }
        });
    }

    public clearState(): void {
        this.testState = null;
    }

    public setTestState(testState: TestCase) {
        this.testState = testState;
    }

    public getState(): TestCase | null {
        return this.testState;
    }
}

export { MCPStateServer };
