// _shared/anthropic.ts — the only place that talks to Claude.

import Anthropic from "npm:@anthropic-ai/sdk@0.120.0";
import { BREAKDOWN_JSON_SCHEMA } from "./breakdown_schema.ts";
import { GRADE_JSON_SCHEMA } from "./grade_prompt.ts";
import { HttpError } from "./http.ts";

let client: Anthropic | null = null;

function getClient(): Anthropic {
  if (client) return client;
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new HttpError(500, "MISCONFIGURED", "ANTHROPIC_API_KEY is not set");
  // One ledger reservation must map to at most one provider request. The
  // Messages API does not currently expose a dependable idempotency guarantee
  // for SDK retries, so a timeout after Anthropic accepted the request could
  // otherwise turn one reserved grading into several billed generations. A
  // student may retry from the app, but that new attempt must pass every rate,
  // entitlement, risk and monetary gate again.
  client = new Anthropic({ apiKey, maxRetries: 0 });
  return client;
}

export interface GenerationUsage {
  inputTokens: number;
  outputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
}

export interface GenerationResult extends GenerationUsage {
  raw: unknown;
  model: string;
}

class ProviderResponseError extends HttpError {
  constructor(error: HttpError, readonly usage: GenerationUsage | null) {
    super(error.status, error.code, error.message);
  }
}

/** Only validated billing counters cross this boundary, never response content. */
export function providerUsage(error: unknown): GenerationUsage | null {
  return error instanceof ProviderResponseError ? error.usage : null;
}

function readUsage(value: Anthropic.Usage): GenerationUsage | null {
  if (!value) return null;
  const counters = [
    value.input_tokens,
    value.output_tokens,
    value.cache_creation_input_tokens ?? 0,
    value.cache_read_input_tokens ?? 0,
  ];
  if (!counters.every((n) => Number.isSafeInteger(n) && n >= 0 && n <= 2147483647)) {
    return null;
  }
  return {
    inputTokens: counters[0],
    outputTokens: counters[1],
    cacheWriteTokens: counters[2],
    cacheReadTokens: counters[3],
  };
}

export async function generateBreakdown(
  model: string,
  systemPrompt: string,
  userPrompt: string,
): Promise<GenerationResult> {
  let usage: GenerationUsage | null = null;
  try {
    const response = await getClient().messages.create({
      model,
      max_tokens: 2000,
      // cache_control on the system block: the rubric is identical for every
      // student taking this assessment. Below ~1024 tokens Anthropic will not
      // cache at all, so generic breakdowns simply miss — that is expected.
      system: [{
        type: "text",
        text: systemPrompt,
        cache_control: { type: "ephemeral" },
      }],
      messages: [{ role: "user", content: userPrompt }],
      output_config: {
        format: { type: "json_schema", schema: BREAKDOWN_JSON_SCHEMA },
      },
    } as Anthropic.MessageCreateParamsNonStreaming);

    usage = readUsage(response.usage);
    if (response.stop_reason === "refusal") {
      throw new HttpError(422, "REFUSED", "The assignment could not be planned.");
    }

    const block = response.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") {
      throw new HttpError(502, "EMPTY_RESPONSE", "Model returned no text block");
    }

    let raw: unknown;
    try {
      raw = JSON.parse(block.text);
    } catch {
      throw new HttpError(502, "MALFORMED_RESPONSE", "Model output was not valid JSON");
    }

    if (!usage) {
      throw new HttpError(502, "INVALID_PROVIDER_USAGE", "Provider accounting is unavailable.");
    }
    return { raw, model, ...usage };
  } catch (e) {
    if (e instanceof HttpError) throw new ProviderResponseError(e, usage);
    if (e instanceof Anthropic.APIError) {
      const status = e.status ?? 0;

      // 429 and 5xx are genuinely transient: the client should fall back to
      // its local planner and try again later.
      if (status === 429 || status >= 500) {
        console.error("anthropic transient error", status);
        throw new HttpError(503, "UPSTREAM_UNAVAILABLE", "Plan generation is unavailable.");
      }

      // Anything else — a 400 above all — means WE sent something invalid.
      // Log it loudly; a quiet "try again later" would hide a real bug.
      console.error(
        "ANTHROPIC REQUEST REJECTED (this is a bug in our request):",
        status,
      );
      throw new HttpError(502, "UPSTREAM_REJECTED", "Plan generation failed.");
    }
    if (usage) {
      throw new ProviderResponseError(
        new HttpError(502, "MALFORMED_RESPONSE", "Provider response was unusable."),
        usage,
      );
    }
    throw e;
  }
}

/**
 * Mark a piece of work against a rubric.
 *
 * `max_tokens` is generous where the breakdown's is not: useful feedback on an
 * essay is genuinely long, and truncating it mid-criterion would produce a
 * grade with half its reasons missing.
 *
 * A refusal is surfaced as a refusal rather than dressed up as a server error.
 * The student pasted the text; they are owed a straight answer about why it was
 * not marked.
 */
export async function gradeWork(
  systemPrompt: string,
  userPrompt: string,
  /** Chosen by the caller from the grading basis — see `gradeModelFor`. */
  model: string,
): Promise<GenerationResult> {
  let usage: GenerationUsage | null = null;
  try {
    const response = await getClient().messages.create({
      model,
      // Sized to the *bounded* output, not to a round number.
      //
      // 4,000 was under it and this failed against the live endpoint: a
      // three-criterion history rubric asked for band distances truncated
      // mid-object, and truncated JSON does not parse, so a full Opus call was
      // spent to return "Model output was not valid JSON". The normaliser caps
      // a comment at 1,200 characters and a quote at 400, so eight criteria is
      // ~3,400 tokens, feedback ~1,000, three improvements ~450. 8,000 clears
      // that with room and costs nothing extra — max_tokens is a ceiling, and
      // billing is on what is actually written.
      max_tokens: 8000,
      system: [{ type: "text", text: systemPrompt, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: userPrompt }],
      output_config: {
        format: { type: "json_schema", schema: GRADE_JSON_SCHEMA },
      },
    } as Anthropic.MessageCreateParamsNonStreaming);

    usage = readUsage(response.usage);
    if (response.stop_reason === "refusal") {
      throw new HttpError(422, "REFUSED", "Albus could not mark this work.");
    }

    // Truncation, said out loud.
    //
    // Without this it arrives as "not valid JSON", which sends whoever reads
    // the log looking for a schema bug — the output was perfectly well formed
    // right up to the token it was cut off at. Distinguishing the two is the
    // difference between a five-minute fix and an afternoon.
    if (response.stop_reason === "max_tokens") {
      console.error("grading truncated at max_tokens — output cap is too low for this rubric");
      throw new HttpError(502, "RESPONSE_TRUNCATED", "Marking ran long and was cut off.");
    }

    const block = response.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") {
      throw new HttpError(502, "EMPTY_RESPONSE", "Model returned no text block");
    }

    let raw: unknown;
    try {
      raw = JSON.parse(block.text);
    } catch {
      throw new HttpError(502, "MALFORMED_RESPONSE", "Model output was not valid JSON");
    }

    if (!usage) {
      throw new HttpError(502, "INVALID_PROVIDER_USAGE", "Provider accounting is unavailable.");
    }
    return { raw, model, ...usage };
  } catch (e) {
    if (e instanceof HttpError) throw new ProviderResponseError(e, usage);
    if (e instanceof Anthropic.APIError) {
      const status = e.status ?? 0;
      if (status === 429 || status >= 500) {
        console.error("anthropic transient error", status);
        throw new HttpError(503, "UPSTREAM_UNAVAILABLE", "Marking is unavailable right now.");
      }
      console.error("ANTHROPIC REQUEST REJECTED (bug in our request):", status);
      throw new HttpError(502, "UPSTREAM_REJECTED", "Albus could not mark this work.");
    }
    if (usage) {
      throw new ProviderResponseError(
        new HttpError(502, "MALFORMED_RESPONSE", "Provider response was unusable."),
        usage,
      );
    }
    throw e;
  }
}
