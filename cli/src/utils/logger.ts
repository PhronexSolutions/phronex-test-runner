import winston from "winston";
import { inputs } from "./args";

// Create transports array - always include console
const transports: winston.transport[] = [
    new winston.transports.Console({
        level: inputs.verbose ? "debug" : "info",
        format: winston.format.combine(winston.format.timestamp(), winston.format.colorize(), winston.format.simple()),
    }),
    new winston.transports.File({
        filename: `${inputs.resultsPath}/debug.log`,
        level: "debug",
        format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
    }),
];

// Create the logger instance
export const logger = winston.createLogger({
    level: "info",
    transports,
});

/**
 * Emits a single CTRF-shaped JSON line to stdout — the contract
 * phronex_common.testing.strategist.run_arbiter._parse_ctrf_event expects (a
 * JSON object with "status" + "name" keys, one per line) to track its
 * consecutive-fail / per-journey-timeout / network-fail abort conditions.
 *
 * Routed through its own winston Console transport (bare-JSON formatter, no
 * "level: message" prefix) rather than a raw stdout write, purely for
 * consistency with `logger` above — same write path this codebase already
 * relies on everywhere else.
 */
const ctrfLogger = winston.createLogger({
    level: "info",
    format: winston.format.printf((info) => JSON.stringify({ name: info.name, status: info.status, duration: info.duration })),
    transports: [new winston.transports.Console()],
});

export function logCtrfEvent(event: { name: string; status: "passed" | "failed"; duration: number }): void {
    // winston.Logger#info(obj) treats a lone object argument as the log
    // MESSAGE, not as top-level info fields — info.name/status/duration would
    // silently be undefined (winston does not error, it just formats
    // "undefined"/drops the line). #log({level, ...fields}) is the documented
    // way to pass a full custom info object with level alongside it.
    ctrfLogger.log({ level: "info", ...event });
}
