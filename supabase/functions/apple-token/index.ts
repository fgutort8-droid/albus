import { adminClient, requireUser } from "../_shared/auth.ts";
import { createAppleTokenHandler } from "./handler.ts";

Deno.serve(createAppleTokenHandler({
  requireUser,
  adminClient,
  env: (name) => Deno.env.get(name),
  fetch,
  now: Date.now,
}));
