begin;

-- A plan that follows a rubric is written by Sonnet 5, which reasons before
-- it answers. That reasoning is billed as output, so the plan call's output
-- allowance went from 2,000 to 5,000 tokens (`BREAKDOWN_MAX_TOKENS` in
-- `_shared/anthropic.ts`) to stop plans being cut off.
--
-- What is set aside for a call before it runs has to cover the most it can
-- cost, because `check_and_record_ai_usage` admits a call against that figure,
-- not against its real cost, which is only known afterwards. US$0.06 covered
-- 2,000 output tokens (US$0.02) and about 20,000 input tokens (US$0.04). At
-- 5,000 output tokens (US$0.05) it would have left room for only 5,000 input
-- tokens, and the largest rubric the app allows is several times that.
--
-- US$0.125 covers 5,000 output tokens (US$0.05) and 36,000 input tokens
-- (US$0.072). The largest prompt the app can send is about 105,000 characters:
-- forty criteria of 2,000 characters, an 8,000-character rubric body, the notes
-- and the instructions. At three characters a token, which is denser than
-- English prose, that is 35,000 tokens, and the answer's schema adds a few
-- hundred (`BREAKDOWN_INPUT_TOKENS_COVERED`, checked by `prompt_test.ts`).
--
-- For every prompt, the most a plan can cost beyond what is set aside for it is
-- now smaller than it was: the reservation grew by US$0.065 and the most the
-- answer can cost by US$0.03. Text that is mostly digits or symbols can still
-- pack more tokens into a character than this assumes, as it could before, and
-- the ledger records what each call really cost.
--
-- Setting more aside spends nothing and raises no limit. It only means a rubric
-- plan is refused slightly sooner when a budget is nearly used up.
--
-- A plan without a rubric is written by Haiku 4.5, which does not reason unless
-- asked and has no rubric in its prompt: about 6,600 characters at most, 2,700
-- tokens with the schema. With 5,000 output tokens that is under US$0.028, so
-- US$0.03 still covers it. Marking is unchanged: its allowance did not move.
create or replace function private.ai_reservation_cost(
  p_kind text,
  p_model text
) returns integer
language sql
immutable
set search_path = ''
as $$
  -- Conservative endpoint ceilings, not average prices. Unknown combinations
  -- fail expensive rather than cheap, so adding a model without adding its
  -- price can stop capacity but can never open an unmetered path.
  select case
    when p_kind = 'grade' and p_model = 'claude-opus-5'    then 450000
    when p_kind = 'grade' and p_model = 'claude-sonnet-5'  then 200000
    when p_kind = 'chat'  and p_model = 'claude-sonnet-5'  then  60000
    when p_kind = 'chat'  and p_model = 'claude-haiku-4-5' then  30000
    when p_kind = 'breakdown' and p_model = 'claude-sonnet-5'  then 125000
    when p_kind = 'breakdown' and p_model = 'claude-haiku-4-5' then  30000
    else 500000
  end;
$$;

revoke all on function private.ai_reservation_cost(text, text)
  from public, anon, authenticated;

-- Prove the arithmetic above against the prices the ledger itself charges,
-- rather than trusting the comment. 5,000 is the plan call's output allowance;
-- 36,000 and 2,700 are the largest prompts, in tokens, as worked out above.
do $$
declare
  v_sonnet_worst bigint := private.ai_metered_cost('claude-sonnet-5', 36000, 5000);
  v_haiku_worst  bigint := private.ai_metered_cost('claude-haiku-4-5', 2700, 5000);
begin
  if private.ai_reservation_cost('breakdown', 'claude-sonnet-5') < v_sonnet_worst then
    raise exception 'a rubric plan can cost % micro-USD, more than is set aside', v_sonnet_worst;
  end if;
  if private.ai_reservation_cost('breakdown', 'claude-haiku-4-5') < v_haiku_worst then
    raise exception 'a plan without a rubric can cost % micro-USD, more than is set aside', v_haiku_worst;
  end if;
end $$;

commit;
