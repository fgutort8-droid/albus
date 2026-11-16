"""Rebuild the wording audit's source inventory and exact change ledger. No network."""
from pathlib import Path
import csv
import difflib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
BASE = subprocess.check_output(['git', 'merge-base', 'origin/main', 'HEAD'], text=True).strip()  # main at the last merge
APP = 'ios/App/Albus/'
PREFIX = {'S': APP+'Screens/', 'V': APP+'Services/', 'M': APP+'Models/',
          'C': APP+'Components/', 'H': APP+'Shell/',
          'N': 'ios/AlbusCore/Sources/AlbusCore/Notifications/'}

def expand(name):
    return PREFIX[name[0]]+name[2:]+'.swift' if name[:1] in PREFIX and name[1:2]==':' else name

def location(spec):
    name, needle = spec.split('@', 1)
    name = expand(name)
    lines = (ROOT/name).read_text().splitlines()
    found = [n for n,line in enumerate(lines,1) if needle in line]
    if not found:
        raise ValueError(f'Missing location: {spec}')
    return f'`{name}:{found[0]}`'

def escaped(value):
    return value.replace('|', '\\|').replace('\n', '<br>')

def table(rows):
    return '\n'.join('| '+' | '.join(escaped(v) for v in row)+' |' for row in rows)+'\n'

# Evidence for each changed source file. Individual before/after spans are generated below.
EVIDENCE = {
'Corpus': ('N:NotificationPlanner@case .morningBrief:;N:NotificationPlanner@let first = blocksToday.min;N:NotificationPlanner@func settle', 'Daily totals and the first scheduled step do not establish urgency, dependencies, tomorrow savings or free time afterwards. Quiet hours can delay nudges.'),
'Corpus+Deadline': ('N:NotificationPlanner@func settle;N:NotificationPlanner@facts[.minutes];V:PlanCoordinator@func updateStep', 'Quiet hours can delay deadline tiers. Notifications do not clear schedules or edit deadlines; remaining estimated minutes are not all unplaced minutes.'),
'Corpus+Engagement': ('N:NotificationPlanner@private func engagementCandidates;N:NotificationPlanner@func applyPause;V:NotificationState@func recordAppOpen;V:NotificationCoordinator@let weekAgo;V:FocusSession@private func bank()', 'Dormancy tracks app opens, not offline work. Routine pause is finite and only timely opens clear it; urgent delivery is not guaranteed. Momentum is a timer snapshot from the seven days before context creation.'),
'AccountDeletionScreen': ('V:AccountDeletion@catch is AccountUnreachable;S:AccountDeletionScreen@appleCode = try await AppleConfirmation().authorizationCode();supabase/functions/delete-account/handler.ts@if (!result.revoked) failure;supabase/functions/delete-account/handler.ts@caller.db.rpc("delete_my_account")', 'Remote erasure, local cleanup and best-effort Apple revocation differ; payment/security records survive content deletion. Apple\'s confirmation on the phone is required before any deletion request is sent; only the server\'s later revocation call is best-effort.'),
'AddTaskSheet': ('M:ToolSelection@let areas = SubjectArea.of;V:PlanService@private struct Request', 'Course identifies/organises tasks and informs tool selection; it does not send educational level. Marking requires Plus/Pro.'),
'GradeResultView': ('supabase/functions/_shared/grade_prompt.ts@let overallMarks', 'AI returns estimates; nil score is not proof of an unscored rubric.'),
'GraderScreen': ('supabase/functions/_shared/grade_prompt.ts@const VOICE;V:GradingService@private struct Request;S:GraderScreen@private var isBlind;S:GraderScreen@left this week;supabase/migrations/0034_three_plans.sql@(\'pro\',  2', 'No teacher-certified grade, deadline field or latency guarantee. No extra rubric retains an attached task rubric; truly blind output strips marks. No plan includes unlimited marking, so the meter\'s no-limit branch says No plan limit rather than Unlimited.'),
'HomeScreen': ('S:HomeScreen@static func shows;V:MarkingCoordinator@let assignment = assignmentID.flatMap', 'Filters include archive state; scheduling can fail to place work; in-flight grading can be stored unlinked after task deletion.'),
'MonthCalendarScreen': ('V:PlanCoordinator@func reschedule', 'Calendar shows only successfully placed sessions; adding work cannot guarantee a filled month.'),
'NotificationSettingsScreen': ('N:NotificationPlanner@let first = blocksToday.min;N:NotificationPlanner@func enforceDailyCap;N:NotificationPlanner@func settle', 'One first-block nudge per day. Urgent reminders bypass daily cap but still face quiet hours, scheduling budget and OS authorization.'),
'PaywallScreen': ('supabase/migrations/0034_three_plans.sql@(\'free\', 0;supabase/migrations/20260916090000_tighten_fair_use_ceilings.sql@update private.ai_tier_budgets;M:ToolSelection@static func suggestions', 'All tiers share tools. Paid AI has rate/cost limits. Marking is an estimate. Popularity is unmeasured. Local rubric saves are ungated; server sync is limited. Pro also has 2,000-task/200-rubric safety ceilings.'),
'RubricEditorSheet': ('supabase/functions/_shared/rubric.ts@.sort(;ios/AlbusCore/Sources/AlbusCore/Models/LocalPlan.swift@public static func sessions', 'Criterion order is input, not an enforced output order; generic local sessions do not use rubric criteria.'),
'RubricsScreen': ('M:LocalStore@deleteRule: .nullify;V:RubricWriter@static func commit', 'Deletion detaches the rubric and preserves assignments/history. Paid marking and potential rubric use are now qualified.'),
'SettingsScreen': ('V:EntitlementService@static func plan(from;V:LocalAccount@func signedOut();V:RubricWriter@static func commit', 'Server price is a monthly reference, expiresAt is not renewal status, null is no plan limit, AI has fair use, synced rubric usage differs from local saves, tasks do not download to a new phone. Free\'s five AI plans a week are a plan limit, so only an unlimited AI allowance is labelled fair use.'),
'SignInScreen': ('V:SessionService@linkIdentityWithIdToken;V:LocalAccount@enum Decision', 'Apple linking preserves identity; no task-download path exists. Account recovery does not transfer local tasks.'),
'TaskDetailScreen': ('V:MarkingCoordinator@let assignment = assignmentID.flatMap;V:PlanCoordinator@func deleteStep', 'Late marking can remain in history. Next step is ordinal, not a measured productivity benefit; no steps can also result from editing.'),
'ToolsScreen': ('M:StudyTool@var url: URL;S:ToolsScreen@openURL(tool.url)', 'Opening a static HTTPS URL supplies no account/work payload and does not specifically choose Safari. Grader output is an estimated paid feature.'),
'AccountDeletion': ('V:AccountDeletion@catch is AccountUnreachable', 'Cleanup can follow an unreachable account as well as confirmed deletion; removed unproven remote-deletion assertion.'),
'GradingService': ('supabase/functions/grade/index.ts@const workHash;supabase/migrations/20260916090000_tighten_fair_use_ceilings.sql@update private.ai_tier_budgets', 'Reuse needs a saved identical request; no unconditional no-double-charge guarantee. Rate limits include daily windows; cost limit rolls over 30 days; sign-in may need repeating.'),
'PlanService': ('V:PlanService@var plansLocally;supabase/migrations/20260916090000_tighten_fair_use_ceilings.sql@update private.ai_tier_budgets', 'AI refusals fall back locally, including Plus/Pro; removed every-time AI and shortly recovery guarantees; cost window is rolling.'),
'PurchaseFlow': ('V:PurchaseFlow@if await entitlements.waitForPaidPlan', 'Purchase/restore can succeed before backend entitlement confirmation; timeout cannot promise automatic activation within a minute.'),
'RubricService': ('V:RubricWriter@static func sync', 'Writer saves locally then attempts one sync. No generic failed-upload retry queue exists; saving again retries.'),
'WorkExtractor': ('V:WorkExtractor@VNRecognizeTextRequest', 'OCR can fail on existing text, so an empty result does not establish an empty document.'),
'NotificationActions': ('V:NotificationRouter@guard action != NotificationActions.ID.notToday;V:NotificationRouter@wantsFocus = action', 'Dismiss acknowledges without suppressing the day; deadline/start action can open focus mode rather than just the plan.'),
'FocusModeScreen': ('V:FocusSession@private func bank();V:FocusSession@func noteLeftApp', 'Measures timer elapsed time, including background time, not actual attention.'),
'GradingTests': ('S:PaywallScreen@Unlimited AI plans within fair use', 'Updated both existing paid-plan headline assertions.'),
'GradingHistoryScreen': ('V:MarkingCoordinator@private func store', 'History lists successfully saved local gradings; it does not download all server results.'),
'PurchaseService': ('V:PurchaseService@case .notAllowed', 'A generic restriction does not establish that Screen Time can remove it.'),
'MarkingCoordinatorTests': ('V:GradingService@Try again with the same work and settings', 'Updated existing save-failure wording assertion; save/announcement behavior assertions are unchanged.'),
}

# Unchanged/remaining claims, grouped only where variants share a mechanism.
CLAIMS = r'''
S:PaywallScreen@5 AI plans a week|Free: five AI plans per rolling week and phone-made plans afterwards.|supabase/migrations/20260915120000_free_gets_five_ai_plans.sql@update public.plans;V:PlanService@var plansLocally|true
S:PaywallScreen@5 active tasks|Free five active tasks / Plus ten active tasks.|supabase/migrations/0034_three_plans.sql@('free', 0;V:PlanCoordinator@func addAssignment|true
S:PaywallScreen@5 markings a week|Plus two and Pro five markings per rolling week; revised drafts can be marked again.|supabase/migrations/0034_three_plans.sql@('plus', 1;supabase/functions/grade/index.ts@const workHash|true
S:PaywallScreen@var priceCents|Fallback €0 / €9.99 / €17.99 monthly.|supabase/migrations/20260916120000_launch_prices.sql@update public.plans|true
S:PaywallScreen@private func price(of|Localized App Store offer overrides fallback; annual prices appear only with annual offers.|V:PurchaseService@price: product.localizedPriceString;S:PaywallScreen@private var offersYearly|true
S:PaywallScreen@Text("Save|Annual savings are computed against 12 monthly charges and rounded down.|V:PurchaseService@func yearlySaving|true
S:PaywallScreen@Start \(trial) free|Trial button and trial-then-price caption only when offer is free trial and user eligible.|V:PurchaseService@private static func freeTrial|true
S:PaywallScreen@private var callToAction|Your plan / subscribe / switch / manage subscription actions correspond to current tier and selected offer.|S:PaywallScreen@private var callToAction;S:PaywallScreen@private var subCaption|true
S:PaywallScreen@Free needs no subscription.|Free needs no subscription; choosing Free while paid opens Apple management and existing access lasts to expiry.|V:PurchaseFlow@static func manageSubscription;V:EntitlementService@return expiresAt > .now|true
S:PaywallScreen@Starts now.|Upgrade starts now / downgrade at renewal depends on App Store group/ranking/period configuration. Recommended pending owner verification: Apple shows when your change takes effect before you confirm.|V:PurchaseFlow@if option.tier < before;V:PurchaseService@func purchase(productID|reported
S:PaywallScreen@Renews automatically. Cancel anytime.|Renewal/cancellation/trial terms are subscription semantics, but live product configuration is not in source. Owner must verify App Store products and terms. Recommended pending verification: Review the renewal and cancellation terms in Apple's confirmation.|V:PurchaseService@static let catalogue;V:PurchaseService@private static func freeTrial|reported
S:PaywallScreen@Still loading prices.|Loading/not-on-sale/unavailable-build messages follow offer availability; cannot buy absent offer.|V:PurchaseService@func purchase(_ option|true
V:PurchaseFlow@Restored. You're on|Restore confirmation only after server paid entitlement; nothing-to-restore follows active Store entitlements, not task data.|V:PurchaseService@restorePurchases().entitlements.active.isEmpty;V:PurchaseFlow@if await entitlements.waitForPaidPlan(attempts|true
V:PurchaseFlow@Waiting for approval.|Pending purchase awaiting approval; no approval time promised.|V:PurchaseService@case .pending|true
V:PurchaseService@No connection. Try again|Purchase/restore errors: offline, unavailable, loading, not on sale, already owned, in progress, Store error, pending, cancelled and generic failure.|V:PurchaseService@static func message|true
V:PurchaseService@Purchases aren't allowed on this device.|Purchase restriction is described without guessing which device policy can remove it.|V:PurchaseService@case .notAllowed|fixed
C:EntitlementRefreshNotice@Plan figures couldn't be confirmed.|Failed refresh displays last values, which can initially be Free fallback; no fresh confirmation is claimed.|V:EntitlementService@func refresh()|true
S:SettingsScreen@Your tasks stay on this phone and come back|Sign-out keeps tasks for same owner; another account cannot see them without removal choice.|V:LocalAccount@func signedOut();H:RootView@private func settleLocalData|true
S:SettingsScreen@aboutRow("Signed in with"|Apple / Not saved / Signed in / Not signed in follows provider classification.|V:SessionService@static func method(of|true
S:SignInScreen@Sign in to start planning.|Apple sign-in precedes app and onboarding; no email/password sign-in UI.|H:RootView@case .needsAccount, .failed:;S:SignInScreen@SignInWithAppleButton|true
S:SignInScreen@The account on this phone hasn't been saved|Leaving a legacy anonymous account may lose access to it and removes local work after confirmation.|S:SignInScreen@private func switchAccounts;V:LocalAccount@case .ask|true
S:SignInScreen@static let agreement|13+ and parent/guardian agreement under 16, accepting Terms and Privacy. This is an acknowledgement, not age verification.|V:AppLinks@static let terms;S:SignInScreen@let terms = Button|true
V:SignIn@No connection. Check|Sign-in failure messages distinguish offline/rate limit/Apple-ID conflict/unavailable/generic; cancelled is silent. Retry waiting is advice, not guaranteed recovery.|V:SignIn@enum SignInError|true
S:AccountSwitchScreen@The tasks, rubrics and markings|Remove-and-continue erases local tasks/rubrics/marks; Go back preserves them and signs out.|S:AccountSwitchScreen@private func remove();S:AccountSwitchScreen@private func goBack()|true
S:AccountDeletionScreen@Deleting your account does NOT cancel|Deleting Albus does not cancel Apple billing; cancellation happens in Apple's subscription management.|supabase/functions/delete-account/handler.ts@caller.db.rpc("delete_my_account");V:PurchaseFlow@static func manageSubscription|true
V:AccountDeletion@Nothing on this device was changed.|Offline/unconfirmed deletion preserves local data; global Nothing was changed is limited to preflight failure before deletion request.|V:AccountDeletion@var asked = false;V:AccountDeletion@try await clearLocal()|true
V:SessionService@case .needsApple:|Deletion needs Apple confirmation / invalid code / wrong Apple ID are explicit server refusals.|V:SessionService@switch (status, code)|true
S:OnboardingFlow@So Albus can build your first plan.|Setup collects preferences, accepts first task, creates plan, then directs to Home. Ready does not require AI success.|S:OnboardingFlow@await coordinator.addAssignment;V:PlanCoordinator@func addAssignment|true
S:AddTaskSheet@Anything the teacher said|Task instructions, type, priority, deadline, subject, rubric and estimated time are used in planning; optional fields are optional.|V:PlanService@private struct Request;supabase/functions/breakdown/index.ts@notes: input.notes|true
S:HomeScreen@It was made on another phone|Stop counting releases other server tasks while leaving other phones' local tasks intact.|V:PlanCoordinator@func releaseOthers;V:AssignmentService@release_my_other_assignments|true
S:HomeScreen@Some work still needs time|Unplaced steps/count/minutes refer to next seven days plus overdue; editing/splitting/deadline discussion are suggestions, not guaranteed fit.|S:HomeScreen@private func weekFit;ios/AlbusCore/Sources/AlbusCore/Models/WeekFit.swift@public struct WeekFit|true
S:HomeScreen@Albus is writing the steps|Planning/failure/local-fallback status banners follow coordinator state.|V:PlanCoordinator@status = .failed|true
S:HomeScreen@keeps \(limit)|Task limit and absent-on-phone server task count can block adding tasks; finish or release work to free space.|V:PlanCoordinator@func syncServerCount;V:EntitlementService@activeTasksUsed|true
S:HomeScreen@Not in your plan|Task progress/rubric/archived markers and Completed assignments collect here use task state. Archived records also appear in Done.|S:HomeScreen@static func shows;M:LocalStore@var isArchived|true
S:MonthCalendarScreen@var text =|Month session count, approximate hours, heaviest day and empty-day text derive from scheduled sessions.|S:MonthCalendarScreen@let inMonth|true
S:TaskDetailScreen@Every step is done.|All-step completion and hand-in suggestion; no automatic submission claimed.|S:TaskDetailScreen@Every step is done.;M:LocalStore@var isComplete|true
S:TaskDetailScreen@This plan doesn't fit|Unplaced step warnings use scheduler output, and remaining time/step completion are derived from stored estimates.|V:PlanCoordinator@unplacedStepIDs;ios/AlbusCore/Sources/AlbusCore/Scheduler/Scheduler.swift@unplaceable|true
S:TaskDetailScreen@Serves criterion|Criterion association, start session, reopen, mark done, add/reorder/edit buttons correspond to stored codes and coordinator actions.|M:LocalStore@criterionCode;V:PlanCoordinator@func setCompleted|true
S:TaskDetailScreen@Albus reads what you wrote|Grader suggests prioritised changes and allows marking a draft again; ordering is a model instruction, not a teacher-result guarantee.|supabase/functions/_shared/grade_prompt.ts@Order the feedback|true
S:StepEditorSheet@Changing this re-flows|Step edits/reordering/deletion reschedule; 5–600 minute range is clamped; deletion releases scheduled time.|V:PlanCoordinator@func updateStep;V:PlanCoordinator@func deleteStep;S:StepEditorSheet@var minutes: Int|true
S:FocusModeScreen@Paused. Time is not counting.|Pause/resume and completed timer descriptions; no app locking; background departures counted.|V:FocusSession@func pause();V:FocusSession@func noteLeftApp|true
S:RubricEditorSheet@criteria below are optional|Pasted rubric alone is valid; structured criteria optional; character counter tracks editor cap.|supabase/functions/_shared/rubric.ts@if (criteria.length === 0;S:RubricEditorSheet@bodyRemaining|true
S:RubricEditorSheet@Leave blank to add up|Reference total is saved/displayed, or summed from criteria if blank. Grading uses criteria/pasted rubric, not this explicit reference field.|M:LocalStore@var effectiveTotalMarks;supabase/functions/_shared/grade_prompt.ts@const rubricTotal|true
V:RubricWriter@Couldn't save that rubric.|Local save/duplicate/delete failure versus server sync failure messages preserve distinction.|V:RubricWriter@try context.save();V:RubricWriter@static func sync|true
S:GraderScreen@PDF or plain text|Import PDF/plain text, photograph or paste; on-device extraction and displayed word count; minimum input before Continue.|V:WorkExtractor@private static func text(fromFile;V:WorkExtractor@VNRecognizeTextRequest;S:GraderScreen@isEnabled: wordCount > 30|true
S:GraderScreen@Saved for next time|Typed and photographed rubrics use shared writer and persist for reuse.|V:RubricWriter@static func commit;S:GraderScreen@RubricWriter.commit|true
S:GraderScreen@With no rubric, Albus still won't|Actually blind grading strips all marks/grade labels regardless of requested presentation scale.|supabase/functions/_shared/grade_prompt.ts@The label is stripped|true
S:GraderScreen@Albus is preparing your feedback.|Rotating text describes possible feedback and waiting, not specific server progress; no telemetry is claimed.|V:GradingService@client.functions.invoke;S:GraderScreen@Albus is preparing your feedback.|fixed
S:GraderScreen@We'll tell you when your feedback is ready.|Marking can outlive screen and announce saved result in-app or with local notification; OS permission/suspension still governs background delivery.|V:MarkingCoordinator@private func announce;H:AppShell@Your feedback is ready|true
S:GraderScreen@Text(isBlind ? "Sonnet 5"|Sonnet 5 blind / Opus 5 rubric models match configured server routes, not a live availability certification.|supabase/functions/_shared/grade_prompt.ts@export function gradeModelFor|true
S:GraderScreen@left this week|Marking allowance, Plus/Pro inclusion, used allowance and next return date are server-derived; Pro gets no claim of a larger marking allowance; Compare plans still opens the paywall.|V:EntitlementService@gradeResetsAt;S:GraderScreen@The next one is back|true
S:GradingHistoryScreen@Your saved markings on this phone|History explicitly contains saved markings on this phone for draft comparison.|V:MarkingCoordinator@private func store|fixed
S:GradingHistoryScreen@A read, no rubric|History date/count/basis labels reflect stored result, including legacy curriculum results.|M:LocalStore@enum GradingBasis;S:GradingHistoryScreen@switch grading.basis|true
S:GradeResultView@Marked by|Model, approximate words, criteria/quotes, scores, feedback and improvements display stored result fields.|M:LocalStore@var approximateWords;supabase/functions/grade/index.ts@breakdown: criteriaPayload|true
S:GradeResultView@Albus is grading blindly|Blind disclaimer says no awarded marks and may differ from teacher's grade.|supabase/functions/_shared/grade_prompt.ts@The label is stripped|true
V:GradingService@Marking is part of Albus Plus and Pro.|Not included versus used allowance/reset-date errors derive from distinct server codes.|V:GradingService@static func translate;supabase/functions/_shared/quota.ts@export async function reserveAIUsage|true
V:GradingService@That's longer than Albus can mark|Too long/output too long/too short/missing rubric/offline errors map to refusal types; word limit is explicitly approximate.|V:GradingService@static func translate;supabase/functions/grade/index.ts@if (work.length > MAX_WORK_CHARS)|true
V:ModelResponseFailure@static let retryableDescription|Shared unusable model response message is used for malformed/empty answers in both planning and grading.|V:PlanService@case "EMPTY_RESPONSE";V:GradingService@case "EMPTY_RESPONSE"|true
V:PlanService@That's as many tasks|Task limit, AI not included, weekly AI allowance and offline are distinct cases; local fallback only for AI/network failures.|V:PlanService@static func translate;V:PlanService@var plansLocally|true
V:PlanService@Albus can't write an AI plan right now.|Unavailable planning no longer promises persistence, because an earlier local save can have failed.|V:PlanCoordinator@save(context, "insert assignment");V:PlanCoordinator@private func save|fixed
V:PlanCoordinator@The one you just added stays|Refused but started assignment remains until next launch, then work is retained as a record.|V:PlanCoordinator@func removeRefusedAssignments|true
V:PlanCoordinator@Couldn't rebuild your plan.|Rebuild and save errors correspond to caught persistence/scheduler failures.|V:PlanCoordinator@private func save;V:PlanCoordinator@func reschedule|true
S:ToolsScreen@Try a tool name|Search advice names tool/category/activity terms, matching name/reason/category predicates.|M:StudyTool@func matches;S:ToolsScreen@private var visible|fixed
S:ToolsScreen@Albus picks from all|Full catalogue participates in step suggestions; need/subject/runway/prior selections rank tools independently of subscription.|M:ToolSelection@static func suggestions;M:ToolSelection@let scored =|true
S:NotificationSettingsScreen@Albus will tell you what's due|Deadline, first-block and no-longer-fitting reminders are local candidates subject to settings/permission/budget.|N:NotificationPlanner@private func allCandidates;V:NotificationScheduler@static func request|true
S:NotificationSettingsScreen@Plain and factual. No jokes.|Serious mode chooses plain register; overdue kind disallows chaotic copy.|N:NotificationPlanner@let requested: Register;N:NotificationCopy@allowsChaos|true
S:NotificationSettingsScreen@Three days before|72/24/3-hour warnings, morning time, quiet hours, study window and days off feed planner settings; quiet hours can shift requested times.|N:NotificationPlanner@let tiers:;V:Preferences@var availability|true
S:NotificationSettingsScreen@Notifications are off|Denied system authorization and Open Settings affordance reflect OS state.|V:NotificationCoordinator@authorization = await;S:NotificationSettingsScreen@UIApplication.openSettingsURLString|true
V:NotificationScheduler@content.title = "Session finished"|Completion notification means timer finished, not auto-completed work; pause/end cancels pending timer alert.|V:NotificationScheduler@UNTimeIntervalNotificationTrigger;V:FocusSession@func pause|true
V:NotificationScheduler@content.title = "Your feedback is ready"|Saved grading ready notification and shell banner route by grading ID.|V:MarkingCoordinator@announce(id, title: title);H:AppShell@Your feedback is ready|true
V:LocalAccount@func allowsReminders|Reminder rebuild requires signed-in matching owner; sign-out clears pending/delivered notifications.|ios/App/Albus/AlbusApp.swift@allowsReminders;V:LocalAccount@func allowsReminders|true
V:CactusAttachment@func masterURL|Attachment contains locally rendered cactus artwork; no prose or network request.|V:CactusAttachment@ImageRenderer;V:NotificationScheduler@CactusAttachment.attachment|true
C:Indicators@accessibilityValue|Progress/step/completion accessibility values and toggle hints reflect supplied state and handlers.|C:Indicators@fraction.clamped01;C:Indicators@isComplete ? "Completed"|true
C:Labels@Text(isOverdue|Due/overdue dates, counts and duration labels are direct formatting of current values.|C:Labels@Text(isOverdue;C:Labels@static func short|true
C:ScheduleViews@HAPPENING NOW|Current/up-next/tomorrow/missed/partial-completion schedule copy and focus controls use session times/state.|C:ScheduleViews@var isNow;C:ScheduleViews@if let partial|true
M:LocalStore@Pasted rubric|Rubric summaries/counts and grading score/title/approximate words format stored data, not sync confirmation.|M:LocalStore@var summary;M:LocalStore@var approximateWords|true
V:AppLinks@static let terms|Terms/privacy/support and Apple subscription-management actions open configured URLs; live page publication is not certified.|V:AppLinks@static let privacy;V:PurchaseFlow@open(AppLinks.manageSubscriptions)|true
V:GradingService@private struct Request|Grading sends text/presentation/title/rubric and assignment IDs; original file bytes are absent. Feedback/quotes may retain work excerpts; no in-app zero-retention claim found.|V:WorkExtractor@VNRecognizeTextRequest;supabase/functions/grade/index.ts@breakdown: criteriaPayload|true
V:PlanService@private struct Request|Planning sends title/type/deadline/time/notes/course/rubric/priority/capacity and persists assignment context plus generated steps.|supabase/functions/breakdown/index.ts@"create_assignment_with_plan"|true
'''

def main():
    rows=[]
    for line in CLAIMS.strip().splitlines():
        source,claim,evidence,status=line.split('|')
        rows.append([location(source),claim,'; '.join(location(x) for x in evidence.split(';')),status])
    changed = subprocess.check_output(['git','diff','--name-only',BASE],cwd=ROOT,text=True).splitlines()
    spans=[]
    for name in changed:
        if not name.endswith('.swift'): continue
        old=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT,text=True).splitlines()
        new=(ROOT/name).read_text().splitlines()
        evidence,why=EVIDENCE[Path(name).stem]
        proof='; '.join(location(x) for x in evidence.split(';'))+' — '+why
        for tag,a,b,c,d in difflib.SequenceMatcher(a=old,b=new,autojunk=False).get_opcodes():
            if tag=='equal': continue
            spans.append([f'`{name}:{a+1}` (base)', '\n'.join(x.strip() for x in old[a:b]) or '(none)',
                          f'`{name}:{c+1}` (final)', '\n'.join(x.strip() for x in new[c:d]) or '(removed)',proof,'fixed'])
    (OUT/'changes.md').write_text('# Exact changes and evidence\n\nComparison: `48185b6` to current source. Every changed source span, including the two existing test assertions, is reproduced below. Removed tool-perk rows are explicitly authorized; other application edits are display wording.\n\n| Before location | Before | After location | After | Evidence | Status |\n| --- | --- | --- | --- | --- | --- |\n'+table(spans))
    app_files=sorted((ROOT/APP).rglob('*.swift'))
    core_files=sorted((ROOT/PREFIX['N']/'Copy').glob('Corpus*.swift'))
    files=app_files+core_files;count=0
    with (OUT/'string-inventory.tsv').open('w') as out:
        writer=csv.writer(out,delimiter='\t',lineterminator='\n');writer.writerow(['file','line','source'])
        for f in files:
            for n,line in enumerate(f.read_text().splitlines(),1):
                if '"' in line:
                    writer.writerow([str(f.relative_to(ROOT)),n,line.strip()]);count+=1
    template_pattern=re.compile(r'\.init\("([^"]+)",[^\n]+\n\s*"([^"]*)",\n\s*"([^"]*)"')
    reminders=[]
    for f in core_files:
        name=str(f.relative_to(ROOT)); source=f.read_text()
        old=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT,text=True)
        old_templates={m[1]:(m[2],m[3]) for m in template_pattern.finditer(old)}
        evidence,why=EVIDENCE[f.stem]
        proof='; '.join(location(x) for x in evidence.split(';'))+' — '+why
        for m in template_pattern.finditer(source):
            line=source[:m.start()].count('\n')+1
            status='true' if old_templates[m[1]]==(m[2],m[3]) else 'fixed'
            reminders.append([f'`{name}:{line}`',m[1]+': '+m[2]+' / '+m[3],proof,status])
    (OUT/'notifications.md').write_text('# Imported notification corpus\n\nEvery fixed template below preserves its identifier, kind, workload, register and required placeholder set. True rows contain data-backed reminders, suggestions or mascot humour rather than unsupported functional promises. Times and estimates reflect the context captured when scheduled; notification delivery and stale context remain subject to iOS and rebuilds.\n\n| Location | Template and displayed copy | Evidence | Status |\n| --- | --- | --- | --- |\n'+table(reminders))
    external=[];name=APP+'Models/StudyTool.swift'
    for n,line in enumerate((ROOT/name).read_text().splitlines(),1):
        m=re.search(r'case \.\w+: \("([^"]+)", "([^"]+)", \.\w+, "[^"]+", "([^"]+)"',line)
        if m:
            tool,host,claim=m.groups()
            external.append([f'`{name}:{n}`',tool+': '+claim,'Static host `'+host+'`; '+location('M:StudyTool@var url: URL')+'. No provider implementation in repo.','reported','Visit '+tool+'.'])
    (OUT/'external-tools.md').write_text('# External catalogue claims\n\nEvery description below is visible in the app. Code proves what Albus displays/opens, not a provider\'s current features, price, availability or result quality. These claims remain **unverified**, not implicitly approved. No external tool was opened or account created. The neutral fallback is proposed wording, not a recommendation to remove a tool or change its URL. Owner review is needed for provider verification and any catalogue/product change.\n\n| Location | Tool and claim | Evidence/limitation | Status | Proposed fallback |\n| --- | --- | --- | --- | --- |\n'+table(external))
    intro=f'''# App wording audit — 4 November 2026

Base: `48185b6`. Worktree: `~/Developer/albus-app-wording`. Branch: `app/wording-matches-behaviour`.

This is a source-to-copy audit, not certification of live services or App Store configuration. It covers the app-authored strings in all {len(app_files)} Swift files under `ios/App/Albus/` plus the {len(core_files)} imported `AlbusCore` notification corpus files: screens, shell, components, service failures, models, accessibility and notifications. [The inventory](string-inventory.tsv) preserves all {count} quoted source lines, including internal literals, previews and sample data, so the scope can be reviewed. Labels, names, format strings and controls without factual promises were checked against their associated actions/values; they are not separate marketing claims. Dynamic model-generated prose and third-party pages cannot be exhaustively verified as fixed app strings.

There are {len(rows)} additional grouped claim rows below, {len(spans)} exact changed spans in [the before/after evidence table](changes.md), {len(reminders)} individually listed [notification templates](notifications.md), and {len(external)} individually listed third-party descriptions in [the reported catalogue appendix](external-tools.md). Together these form the audit table; corrected claims are not omitted just because they moved to the change ledger. Repeated variants are grouped only where their underlying implementation is shared.

**true** means supported by source under the conditions stated; **fixed** means wording changed; **reported** means unresolved or externally unverifiable, with recommended wording. A prompt instruction establishes intended AI behavior, not guaranteed output quality.

The task references a 4 November section of `website/privacy-audit.md` / PR #47. It is absent at the required base; that file ends on 7 October. Available entries and `docs/backend.md` were read as leads and checked against code. The backend document's tiered-tools table is stale: selection ignores `tools_access`.

No behavior, prices, limits, layout logic, server code, website, App Store documents or dependencies were changed. `Config.xcconfig` was not read, printed, copied, edited or committed. The app still uses the same models, limits, URLs and actions. No sign-in, live backend invocation, push, or PR was performed.

## Unchanged and reported claims

| Location | Claim and qualifications/recommendation | Evidence | Status |
| --- | --- | --- | --- |
'''
    (OUT/'audit.md').write_text(intro+table(rows)+'\nSee [open product/configuration items](reported.md) and [test output, cleanup and rerun instructions](validation.md).\n')
    print(f'{len(rows)} claim groups, {len(spans)} changed spans, {len(external)} external claims; {len(files)} files / {count} quoted lines.')

if __name__=='__main__':main()
