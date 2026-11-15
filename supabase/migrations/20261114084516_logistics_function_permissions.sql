-- Hosted Supabase can grant EXECUTE directly to anon via default privileges.
-- Revoking PUBLIC alone does not remove those direct grants.
-- Preserve each existing authenticated grant, including disabled legacy RPCs.
begin;
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='public' and left(p.proname,3)='sl_')
       or n.nspname='logistics_private'
  loop
    execute format('revoke execute on function %s from public, anon', f.signature);
  end loop;
end;
$$;
notify pgrst, 'reload schema';
commit;
