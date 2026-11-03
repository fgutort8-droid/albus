begin;

-- Albus uses PostgREST and student RPCs, not GraphQL. CLI 2.98.2 enables
-- pg_graphql by default, exposing 13 application tables to authenticated
-- GraphQL clients. Keep the table grants needed by REST and remove the unused
-- resolver instead. RESTRICT refuses unexpected application dependencies.
-- IF EXISTS also supports stacks whose platform never enabled the extension.
drop extension if exists pg_graphql restrict;

commit;
