import { existsSync, readFileSync, rmSync, unlinkSync } from "fs";
import { resolve } from "path";

/**
 * File-based pause/kill control signal for a running JourneyHawk sprint.
 *
 * The runner checks this file between journeys (never mid-journey) — it is
 * only ever read/cleared by the process it belongs to, so no IPC/socket is
 * needed. Mirrors the existing /tmp/journeyhawk-<product>.lock convention.
 */

type ControlSignal = "PAUSE" | "KILL" | null;

function controlFilePath(product: string): string {
    return `/tmp/journeyhawk-${product}.control`;
}

export function readControlSignal(product: string): ControlSignal {
    const path = controlFilePath(product);
    if (!existsSync(path)) return null;
    const raw = readFileSync(path, "utf-8").trim().toUpperCase();
    if (raw === "PAUSE" || raw === "KILL") return raw;
    return null;
}

/**
 * Clears the control file (used by the operator's "resume" action, and by
 * the runner itself after a clean run so a stale signal never leaks into the
 * next invocation).
 */
export function clearControlSignal(product: string): void {
    const path = controlFilePath(product);
    if (existsSync(path)) unlinkSync(path);
}

/**
 * Removes transient per-run state so a subsequent invocation starts fresh:
 * captured browser storageState files and entity sidecars declared by any
 * journey in this run's spec, plus the control file itself. Does NOT touch
 * the persisted journey spec cache (cc-deep.generated.json) or phronex_qa —
 * those are accumulated intelligence, not run-transient mess.
 */
export function cleanupTransientState(
    product: string,
    testCases: Array<{ stateOutputPath?: string; entityOutputPath?: string }>,
): void {
    for (const tc of testCases) {
        for (const p of [tc.stateOutputPath, tc.entityOutputPath]) {
            if (!p) continue;
            const abs = resolve(p);
            if (existsSync(abs)) {
                try {
                    rmSync(abs, { force: true });
                } catch {
                    // best-effort — a leftover state file is stale, not corrupting
                }
            }
        }
    }
    clearControlSignal(product);
}
