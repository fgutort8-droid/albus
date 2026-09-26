import { assert, assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import {
  InvalidPlanError,
  MAX_STEPS,
  validateAndNormalise,
} from "../_shared/breakdown_schema.ts";

const ok = {
  steps: [
    {
      title: "Find sources",
      guidance: "Skim three.",
      estimated_minutes: 60,
      rubric_criterion_code: "A",
    },
    { title: "Draft", guidance: "Write it.", estimated_minutes: 120, rubric_criterion_code: "B" },
  ],
};

Deno.test("accepts a well-formed plan unchanged", () => {
  const r = validateAndNormalise(ok, 180);
  assertEquals(r.steps.length, 2);
  assertEquals(r.steps[0].rubric_criterion_code, "A");
});

Deno.test("rejects responses with no usable steps", () => {
  assertThrows(() => validateAndNormalise({}, 180), InvalidPlanError);
  assertThrows(() => validateAndNormalise({ steps: [] }, 180), InvalidPlanError);
  assertThrows(() => validateAndNormalise(null, 180), InvalidPlanError);
});

Deno.test("rejects a step with no title — unstartable by definition", () => {
  assertThrows(
    () =>
      validateAndNormalise({
        steps: [{ title: "  ", guidance: "x", estimated_minutes: 30, rubric_criterion_code: null }],
      }, 60),
    InvalidPlanError,
  );
});

Deno.test("clamps absurd durations instead of failing the request", () => {
  const r = validateAndNormalise({
    steps: [{
      title: "Do it",
      guidance: "",
      estimated_minutes: 99999,
      rubric_criterion_code: null,
    }],
  }, 120);
  assert(r.steps[0].estimated_minutes <= 480);
  assert(r.steps[0].estimated_minutes >= 5);
});

Deno.test("coerces a non-numeric duration to a sane default", () => {
  const r = validateAndNormalise({
    steps: [{
      title: "Do it",
      guidance: "",
      estimated_minutes: "soon",
      rubric_criterion_code: null,
    }],
  }, 120);
  assertEquals(r.steps[0].estimated_minutes, 30);
});

Deno.test("scales down a plan that overshoots the student's budget", () => {
  const r = validateAndNormalise({
    steps: [
      { title: "A", guidance: "", estimated_minutes: 400, rubric_criterion_code: null },
      { title: "B", guidance: "", estimated_minutes: 400, rubric_criterion_code: null },
    ],
  }, 120); // budget 2h, model asked for 13h
  const total = r.steps.reduce((n, s) => n + s.estimated_minutes, 0);
  assert(total <= 120 * 1.5 + 10, `expected ~<=180, got ${total}`);
});

Deno.test("caps runaway step counts", () => {
  const many = {
    steps: Array.from({ length: 40 }, (_, i) => ({
      title: `S${i}`,
      guidance: "",
      estimated_minutes: 10,
      rubric_criterion_code: null,
    })),
  };
  // Asserted against the constant, not a literal: the cap is the database RPC's
  // 20-subtask limit rather than a taste judgement, and hard-coding 12 here is
  // what made raising it look like a regression.
  assertEquals(validateAndNormalise(many, 400).steps.length, MAX_STEPS);
});

Deno.test("a step longer than one sitting is split, not clamped", () => {
  // Clamping deleted the excess: a 300-minute step became 120 and the plan
  // quietly claimed less work than the assignment needs. The scheduler places
  // each step as one unbroken block, so the length also has to be placeable.
  const plan = validateAndNormalise({
    steps: [{
      title: "Draft the essay",
      guidance: "",
      estimated_minutes: 300,
      rubric_criterion_code: null,
      tool_need: "drafting",
    }],
  }, 300, 180);

  assertEquals(plan.steps.length, 3);
  assertEquals(plan.steps.every((s) => s.estimated_minutes <= 120), true);
  // The work survives the split.
  assertEquals(plan.steps.reduce((n, s) => n + s.estimated_minutes, 0), 300);
  assertStringIncludes(plan.steps[0].title, "1 of 3");
});

Deno.test("the sitting limit follows the student, not a constant", () => {
  const long = { steps: [{ title: "Read", guidance: "", estimated_minutes: 200,
                           rubric_criterion_code: null, tool_need: "reading" }] };
  // A student with 90 minutes a day cannot sit for 120: the scheduler would
  // never find a day with room, and the step would vanish.
  assertEquals(validateAndNormalise(long, 200, 90).steps.every((s) => s.estimated_minutes <= 90), true);
  assertEquals(validateAndNormalise(long, 200, 300).steps.every((s) => s.estimated_minutes <= 120), true);
});

Deno.test("normalises an empty criterion code to null", () => {
  const r = validateAndNormalise({
    steps: [{ title: "A", guidance: "", estimated_minutes: 30, rubric_criterion_code: "  " }],
  }, 60);
  assertEquals(r.steps[0].rubric_criterion_code, null);
});

Deno.test("split allocation stays bounded for every finite provider duration", () => {
  const original = Array.from;
  let largestAllocation = 0;
  Array.from = new Proxy(original, {
    apply(target, thisArg, args) {
      const length = args[0]?.length;
      if (typeof length === "number") {
        largestAllocation = Math.max(largestAllocation, length);
        // Fail safely before allocating an adversarially large array.
        if (length > MAX_STEPS) throw new Error("split allocation exceeded output bound");
      }
      return Reflect.apply(target, thisArg, args);
    },
  });
  try {
    for (const minutes of [1e9, 9e100, Number.MAX_VALUE]) {
      const result = validateAndNormalise({
        steps: [{ title: "Synthetic step", estimated_minutes: minutes }],
      }, 120);
      assertEquals(result.steps.length, MAX_STEPS);
      assert(result.steps.every((step) => Number.isFinite(step.estimated_minutes)));
    }
    assertEquals(largestAllocation, MAX_STEPS);
  } finally {
    Array.from = original;
  }
});

Deno.test("bounded splitting preserves the original prefix and later validation", () => {
  const result = validateAndNormalise({
    steps: [{ title: "Long task", estimated_minutes: 2501 }],
  }, 3000);
  assertEquals(result.steps.map((step) => [step.title, step.estimated_minutes]),
    Array.from({ length: MAX_STEPS }, (_, i) => [`Long task (${i + 1} of 21)`, 119]));
  assertThrows(() => validateAndNormalise({
    steps: [{ title: "Long task", estimated_minutes: 2501 }, { title: "", estimated_minutes: 30 }],
  }, 3000), InvalidPlanError);
});
