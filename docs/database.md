# Database

14 tables in `public`, in four groups.

## Identity
| Table | Notes |
|---|---|
| `profiles` | 1:1 with `auth.users`, created by trigger. Study window and daily capacity — the scheduler's constraints. |

## The student's work — all owner-scoped
| Table | Notes |
|---|---|
| `courses` | A student's course, optionally linked to a template. |
| `assignments` | Title, deadline, estimated minutes, task type. |
| `subtasks` | The steps a breakdown produced. May cite a rubric criterion. |
| `plan_sessions` | Scheduler output. `is_fixed` marks classes the scheduler routes around. |

## Curriculum — global reference, read-only to clients
| Table | Notes |
|---|---|
| `curricula` | IB_DP, AP, GENERIC |
| `course_templates` | IB History HL, etc. |
| `assessment_types` | IA, Paper 1, EE, DBQ |
| `rubric_criteria` | Criterion name, marks, **our own paraphrased guidance** |
| `syllabus_topics` | Ordered topic list |
| `duration_priors` | Cold-start medians for the local estimator |

## Calibration and commerce
| Table | Notes |
|---|---|
| `completion_logs` | Estimated vs actual. **No free text, ever.** |
| `entitlements` | Subscription tier. Server-written only. |
| `ai_usage` | Per-call model and token counts. Server-written only. |

## Why `completion_logs` looks like that

It mirrors the `/logs` payload exactly: curriculum, course code, task type,
estimated, actual, hour bucket, minutes late, confidence. No title, no notes,
no assignment id that could be joined back to content by anyone with only this
table.

That gives a complete calibration dataset while never recording what a student
is actually working on. Widening this schema later is easy; narrowing it after
launch is not. Don't widen it.

`confidence` is `high` only when a real timer produced the number. Completions
inferred from the session window are `low` and should be weighted down.

## Task status from the phone

`sync_my_assignments(p_finished uuid[], p_open uuid[]) → integer` updates only
the signed-in student's tasks. It finishes active rows first, then reopens
completed rows one at a time through the normal active-task trigger. A reopen
refused by the plan cap is skipped. Archived rows, foreign rows and IDs present
in both lists remain unchanged. The return value counts changed rows, so
repeating the same state is harmless.

`release_my_other_assignments(p_keep uuid[]) → integer` archives the student's
other active tasks after the app obtains their agreement. Empty/null keep lists
release every active place. Completed tasks and children/results remain intact.
Both RPCs derive the owner from `auth.uid()`, accept at most 500 entries per
array, and allow `authenticated` callers only. Neither changes the separate
weekly AI-plan allowance.
