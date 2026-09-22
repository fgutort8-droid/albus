import { assert, assertEquals } from "jsr:@std/assert@1";
import { normaliseTaskType, RETIRED_TASK_TYPES, TASK_TYPES } from "../_shared/task_type.ts";

// The same eight as `assignments_task_type_check` after migration
// 20260917120000. If this fails, one of the three lists moved without the
// others: fix the drift, don't edit this until it passes.
const GENERIC = [
  "essay",
  "problem_set",
  "lab_report",
  "reading",
  "revision",
  "project",
  "presentation",
  "other",
];

Deno.test("the accepted types are exactly the eight generic shapes", () => {
  assertEquals([...TASK_TYPES].sort(), [...GENERIC].sort());
});

Deno.test("a generic type passes through unchanged", () => {
  for (const type of GENERIC) assertEquals(normaliseTaskType(type), type);
});

Deno.test("each retired IB type becomes the type the migration gave stored rows", () => {
  // The migration's table, restated. The app stored these until September 2026.
  assertEquals(Object.fromEntries(RETIRED_TASK_TYPES), {
    internal_assessment: "project",
    extended_essay: "essay",
    tok_essay: "essay",
    tok_exhibition: "project",
    mock_exam: "revision",
    final_exam: "revision",
  });
  for (const [retired, replacement] of RETIRED_TASK_TYPES) {
    assertEquals(normaliseTaskType(retired), replacement);
    assert(
      TASK_TYPES.has(replacement),
      `${retired} maps to ${replacement}, which Postgres refuses`,
    );
    assert(!TASK_TYPES.has(retired), `${retired} is retired but still accepted as-is`);
  }
});

Deno.test("anything else is refused, including names every object has", () => {
  for (
    const value of [
      "",
      "Essay",
      "exam",
      " essay",
      "constructor",
      "__proto__",
      "toString",
      "hasOwnProperty",
    ]
  ) {
    assertEquals(normaliseTaskType(value), null, JSON.stringify(value));
  }
});
