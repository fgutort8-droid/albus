begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select plan(3);
select ok(not has_sequence_privilege('anon','public.security_events_id_seq','USAGE,SELECT,UPDATE'),
  'anonymous clients cannot operate the application event sequence');
select ok(not has_sequence_privilege('authenticated','public.security_events_id_seq','USAGE,SELECT,UPDATE'),
  'authenticated clients cannot operate the application event sequence');
select ok(has_sequence_privilege('service_role','public.security_events_id_seq','USAGE'),
  'server event recording retains sequence access');
select * from finish();
rollback;
