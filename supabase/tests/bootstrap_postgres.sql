\set ON_ERROR_STOP on

create role anon nologin;
create role authenticated nologin;
create schema auth;

create table auth.users (
  id uuid primary key
);

create or replace function auth.uid()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
