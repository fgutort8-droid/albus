// _shared/breakdown_schema.ts
// The contract for what the model must return, plus defensive validation.
//
// `output_config.format` already constrains the model, but we re-validate:
// a schema guarantees shape, not sanity. A step claiming 40 hours, or ten
// steps for a 30-minute reading, is well-formed and still wrong.

import { studyNeed } from "./needs.ts";

export interface PlanStep {
  title: string;
  guidance: string;
  estimated_minutes: number;
  rubric_criterion_code: string | null;
  /** What this step needs doing to it, from the shared vocabulary. Decides
   *  which of the 225 tools the app offers for it. */
  tool_need: string | null;
}

export interface BreakdownResult {
  steps: PlanStep[];
}

/**
 * Shape only — deliberately minimal.
 *
 * `output_config.format` supports a restricted JSON Schema subset: it rejects
 * minItems above 1, and rejects minimum/maximum/maxLength entirely. Encoding
 * bounds here also duplicates logic that validateAndNormalise must perform
 * regardless, since a schema can guarantee a field is an integer but not that
 * it is a sane number of minutes.
 *
 * So: the schema guarantees shape, the validator guarantees sanity.
 */
export const BREAKDOWN_JSON_SCHEMA = {
  type: "object",
  properties: {
    steps: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          guidance: { type: "string" },
          estimated_minutes: { type: "integer" },
          rubric_criterion_code: { type: ["string", "null"] },
          tool_need: { type: ["string", "null"] },
        },
        required: [
          "title", "guidance", "estimated_minutes", "rubric_criterion_code", "tool_need",
        ],
        additionalProperties: false,
      },
    },
  },
  required: ["steps"],
  additionalProperties: false,
} as const;

/// The database RPC rejects more than 20 subtasks, so this is the real ceiling
/// rather than a taste judgement. It was 12, which silently truncated the long
/// plans a three-month project actually needs.
export const MAX_STEPS = 20;
const MIN_STEP_MINUTES = 5;

/**
 * The longest a single step may be, for this student.
 *
 * A step is one sitting, and the scheduler places each one as a single
 * contiguous block: `findSlot` skips any day whose remaining capacity is below
 * the step's length, so a step longer than the student's daily capacity is
 * never placed anywhere. It does not shrink or split — it silently disappears
 * from the calendar. An 8-hour step with sixty days available and a 3-hour day
 * schedules exactly nothing.
 *
 * Capped at two hours regardless of how much time the student has: three
 * unbroken hours on one task is not a realistic unit of study work, and a plan
 * built from them is the thing this exists to stop.
 */
export function sessionCeiling(dailyCapacityMinutes: number): number {
  const capacity = Number.isFinite(dailyCapacityMinutes) ? dailyCapacityMinutes : 150;
  return Math.max(30, Math.min(120, Math.floor(capacity)));
}

export class InvalidPlanError extends Error {}

/**
 * Clamp rather than reject where a value is merely implausible, and reject
 * only what cannot be salvaged. A student waiting on a plan is better served
 * by a slightly-adjusted plan than by an error.
 */
export function validateAndNormalise(
  raw: unknown,
  totalEstimatedMinutes: number,
  dailyCapacityMinutes: number = 150,
): BreakdownResult {
  const stepCeiling = sessionCeiling(dailyCapacityMinutes);
  if (typeof raw !== "object" || raw === null || !("steps" in raw)) {
    throw new InvalidPlanError("response had no steps array");
  }
  const steps = (raw as { steps: unknown }).steps;
  if (!Array.isArray(steps) || steps.length === 0) {
    throw new InvalidPlanError("steps array was empty");
  }

  const normalised: PlanStep[] = steps.slice(0, MAX_STEPS).flatMap((s, i) => {
    const step = s as Record<string, unknown>;
    const title = typeof step.title === "string" ? step.title.trim() : "";
    if (!title) throw new InvalidPlanError(`step ${i} had no title`);

    const rawMinutes = Number(step.estimated_minutes);
    const minutes = Number.isFinite(rawMinutes)
      ? Math.max(MIN_STEP_MINUTES, Math.round(rawMinutes))
      : 30;

    const code = typeof step.rubric_criterion_code === "string"
      ? step.rubric_criterion_code.trim() || null
      : null;

    const base = {
      title: title.slice(0, 200),
      guidance: typeof step.guidance === "string" ? step.guidance.trim().slice(0, 1000) : "",
      rubric_criterion_code: code,
      // Dropped rather than rejected when unrecognised: a need outside the
      // vocabulary costs this step its tool suggestions, never the plan.
      tool_need: studyNeed(step.tool_need),
    };

    // Split rather than clamp.
    //
    // Clamping a 300-minute step to the ceiling silently deletes the other
    // three hours: the plan then claims less work than the assignment needs,
    // and the student runs out of plan before running out of essay. Splitting
    // keeps the total and produces sittings the scheduler can actually place.
    if (minutes <= stepCeiling) {
      return [{ ...base, estimated_minutes: minutes }];
    }
    const parts = Math.ceil(minutes / stepCeiling);
    const each = Math.max(MIN_STEP_MINUTES, Math.round(minutes / parts));
    return Array.from({ length: Math.min(parts, MAX_STEPS) }, (_, part) => ({
      ...base,
      title: `${base.title} (${part + 1} of ${parts})`.slice(0, 200),
      estimated_minutes: each,
    }));
  }).slice(0, MAX_STEPS);

  // If the model's total wildly overshoots what the student said they had,
  // scale proportionally rather than handing back a plan that cannot fit.
  const total = normalised.reduce((n, s) => n + s.estimated_minutes, 0);
  const ceiling = totalEstimatedMinutes * 1.5;
  if (total > ceiling && total > 0) {
    const factor = ceiling / total;
    for (const s of normalised) {
      s.estimated_minutes = Math.max(
        MIN_STEP_MINUTES,
        Math.round(s.estimated_minutes * factor),
      );
    }
  }

  return { steps: normalised };
}
