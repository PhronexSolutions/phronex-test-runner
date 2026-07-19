import z from "zod";

export const recordEntityToolInput = z.object({
  key: z.string().describe("Name the downstream journey references as {{key}}"),
  value: z.string().describe("The runtime-created value (e.g. the nonce, or instance_id)"),
});
