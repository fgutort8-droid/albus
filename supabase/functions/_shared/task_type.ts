// _shared/task_type.ts
//
// The kinds of work a task can be.

// Must agree with `assignments_task_type_check` in Postgres and with `TaskType`
// in the iOS app. A value the client can send that is missing here is a 422
// the student can do nothing about.
export const TASK_TYPES: ReadonlySet<string> = new Set([
  "essay",
  "problem_set",
  "lab_report",
  "reading",
  "revision",
  "project",
  "presentation",
  "other",
]);

// The IB assessment types the app offered until September 2026, and the
// generic type each became. Postgres no longer accepts them: migration
// 20260917120000_retire_ib_schema converted stored rows with this same table.
// An app built before then can still send one, so it is converted here rather
// than refused, and the student still gets a plan.
//
// Converting here is also what makes the deploy order safe. This function
// must be live before that migration, or an old build could pay for a plan
// that Postgres then refuses to save.
export const RETIRED_TASK_TYPES: ReadonlyMap<string, string> = new Map([
  ["internal_assessment", "project"],
  ["extended_essay", "essay"],
  ["tok_essay", "essay"],
  ["tok_exhibition", "project"],
  ["mock_exam", "revision"],
  ["final_exam", "revision"],
]);

/** The type to plan and store for a requested one, or null if it is not a task type. */
export function normaliseTaskType(requested: string): string | null {
  if (TASK_TYPES.has(requested)) return requested;
  return RETIRED_TASK_TYPES.get(requested) ?? null;
}
