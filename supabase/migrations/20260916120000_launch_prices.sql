-- 20260916120000_launch_prices
--
-- Launch prices, decided by Felipe on 16 Sep 2026: Plus EUR 9.99 a month (was
-- 7.99), Pro EUR 17.99 (was 14.99). Yearly plans follow in App Store Connect at
-- EUR 99.99 and EUR 179.99, still two months free; this table only holds the
-- monthly figure the paywall shows.
--
-- Why raise before anyone pays: EU App Store prices include VAT, which Apple
-- removes before its 15% commission, so at 7.99 / 14.99 the app kept only
-- about EUR 5.61 / 10.53 a month. A month-long worst case -- an account
-- running up its whole per-account AI ceiling of US$3 / US$6 -- left a 54% /
-- 51% margin. At 9.99 / 17.99 the app keeps about EUR 7.02 / 12.64 and that
-- worst case leaves 63% / 59%. Raising now reaches no subscriber; raising
-- later would reach every one, and a large increase needs each one's consent.
--
-- 9.99 keeps Plus under ten euros. Pro moves by three so it stays just under
-- twice Plus, as it was, and Plus still reads as the sensible middle.
--
-- Nothing about what a plan includes changes here.

begin;

update public.plans set price_cents = 999,  updated_at = now() where tier = 'plus';
update public.plans set price_cents = 1799, updated_at = now() where tier = 'pro';

do $$
begin
  if (select price_cents from public.plans where tier = 'free') is distinct from 0
     or (select price_cents from public.plans where tier = 'plus') is distinct from 999
     or (select price_cents from public.plans where tier = 'pro') is distinct from 1799 then
    raise exception 'launch prices are not EUR 0 / 9.99 / 17.99';
  end if;
end $$;

commit;
