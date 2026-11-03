import { adminClient, requireUser } from "../_shared/auth.ts";
import { createDeleteAccountHandler } from "./handler.ts";

Deno.serve(createDeleteAccountHandler({
  requireUser,
  adminClient,
  env: (name) => Deno.env.get(name),
  fetch,
  now: Date.now,
}));
