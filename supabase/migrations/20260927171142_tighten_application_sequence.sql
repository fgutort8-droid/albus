-- Application event identifiers are assigned only by the server path.
revoke all privileges on sequence public.security_events_id_seq from public, anon, authenticated;
