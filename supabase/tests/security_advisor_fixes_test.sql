-- Disabling the unused GraphQL surface preserves the REST/RPC grants.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select plan(6);

select ok(not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_graphql'),
          'pg_graphql is disabled');
select ok(pg_catalog.to_regprocedure('graphql.resolve(text,jsonb,text,jsonb)') is null,
          'the direct GraphQL resolver is absent');

-- Some platform versions retain a wrapper returning an extension-disabled
-- error; others omit it. Neither may return application data through GraphQL.
select pg_catalog.to_regprocedure('graphql_public.graphql(text,text,jsonb,jsonb)') is not null as wrapper_exists \gset
set local role anon;
\if :wrapper_exists
select ok(response ? 'errors' and not (response ? 'data'),
          'anonymous GraphQL wrapper cannot return application data')
from (select graphql_public.graphql(query := '{ plansCollection(first: 1) { edges { node { tier } } } }') as response) as result;
\else
select pass('anonymous GraphQL wrapper is absent');
\endif
set local role authenticated;
\if :wrapper_exists
select ok(response ? 'errors' and not (response ? 'data'),
          'authenticated GraphQL wrapper cannot return application data')
from (select graphql_public.graphql(query := '{ plansCollection(first: 1) { edges { node { tier } } } }') as response) as result;
\else
select pass('authenticated GraphQL wrapper is absent');
\endif
select is((select count(*) from public.plans), 3::bigint, 'authenticated REST table grants still allow reading all three plans');
select is(public.my_tier(), 'free'::text, 'student tier RPC retains its safe missing-identity result');
reset role;

select * from finish();
rollback;
