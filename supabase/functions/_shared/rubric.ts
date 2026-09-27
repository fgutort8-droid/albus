// _shared/rubric.ts — fetch the rubric a breakdown or a grading is grounded in.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.112.3";
import type { RubricContext } from "./prompt.ts";

/** The rubric the student saved and attached to this assignment, if any. */
export async function loadPersonalRubric(
  db: SupabaseClient,
  rubricId: string | null,
): Promise<RubricContext | null> {
  if (!rubricId) return null;

  const { data, error } = await db
    .from("rubrics")
    .select(`name, body, total_marks, rubric_items ( id, code, name, marks, guidance, ordinal )`)
    .eq("id", rubricId)
    .maybeSingle();

  if (error || !data) {
    if (error) console.warn("personal rubric lookup failed, continuing generic");
    return null;
  }

  const criteria = ((data.rubric_items ?? []) as Array<{
    id: string;
    code: string | null;
    name: string;
    marks: number | null;
    guidance: string | null;
    ordinal: number;
  }>)
    .sort((a, b) => a.ordinal - b.ordinal)
    .map(({ id, code, name, marks, guidance }) => ({
      id,
      code: code ?? "",
      name,
      marks,
      guidance,
    }));

  const body = typeof data.body === "string" ? data.body : null;
  if (criteria.length === 0 && !(body ?? "").trim()) return null;

  return { name: data.name as string, criteria, body };
}

/** Which rubric the grader found, and where it came from. */
export interface ResolvedRubric {
  rubric: RubricContext | null;
  basis: "personal" | "blind";
}

/**
 * Work out what a piece of work should be marked against, from the work itself.
 *
 * The student picks nothing. An assignment already knows whether a rubric was
 * attached when it was created, so asking them to name one again is asking them
 * to repeat themselves.
 *
 * **The lookup runs through the caller's own client, so RLS decides what an id
 * resolves to.** An assignment belonging to another student returns no row --
 * not a rubric, and not an error that leaks its existence -- so a forged id
 * degrades to blind rather than to somebody else's mark scheme.
 */
export async function resolveGradingRubric(
  db: SupabaseClient,
  assignmentId: string,
): Promise<ResolvedRubric> {
  const { data, error } = await db
    .from("assignments")
    .select("rubric_id")
    .eq("id", assignmentId)
    .maybeSingle();

  // No row means RLS refused it or it does not exist. Both are "we have no
  // rubric", and neither is worth distinguishing to the caller.
  if (error || !data) {
    if (error) console.warn("assignment lookup failed, grading blind");
    return { rubric: null, basis: "blind" };
  }

  const personal = await loadPersonalRubric(
    db,
    typeof data.rubric_id === "string" ? data.rubric_id : null,
  );
  return personal ? { rubric: personal, basis: "personal" } : { rubric: null, basis: "blind" };
}
