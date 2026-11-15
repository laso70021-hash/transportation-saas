import assert from 'node:assert/strict';
import fs from 'node:fs';
import {PGlite} from '@electric-sql/pglite';

const db = new PGlite();
const owner = crypto.randomUUID(), other = crypto.randomUUID(), unconfirmed = crypto.randomUUID();
try {
  await db.exec(`create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key,created_at timestamptz not null,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema auth to authenticated;
    grant execute on function auth.uid() to authenticated;
    create table public.sl_platform_admins(user_id uuid primary key references auth.users);
  `);
  await db.query(`insert into auth.users values ($1,'2026-01-01',null),($2,'2026-01-02',now()),($3,'2026-01-03',now())`, [unconfirmed,owner,other]);
  await db.exec(fs.readFileSync(new URL('../supabase/migrations/20261114092529_logistics_account_owner.sql',import.meta.url),'utf8'));
  assert.deepEqual((await db.query('select user_id from sl_platform_admins')).rows,[{user_id:owner}]);
  console.log('PASS Only the first existing confirmed account receives administrator access');
  async function login(id) {
    await db.exec('reset role');
    await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
    await db.exec('set role authenticated');
  }
  await login(owner);
  assert.equal((await db.query('select * from sl_account_owner')).rows.length,1);
  await assert.rejects(db.query('update sl_account_owner set user_id=$1',[other]),/permission denied/);
  console.log('PASS Owner can identify their account but cannot transfer ownership through the API');
  await login(other);
  assert.equal((await db.query('select * from sl_account_owner')).rows.length,0);
  await assert.rejects(db.query('insert into sl_account_owner(user_id) values($1)',[other]),/permission denied/);
  await assert.rejects(db.query('delete from sl_account_owner'),/permission denied/);
  console.log('PASS Other accounts cannot see, claim, or remove owner-only role switching');
  await db.exec('reset role; set role anon');
  await assert.rejects(db.query('select * from sl_account_owner'),/permission denied/);
  await db.exec('reset role');
  const later=crypto.randomUUID();
  await db.query('insert into auth.users values($1,now(),now())',[later]);
  assert.equal((await db.query('select * from sl_platform_admins where user_id=$1',[later])).rows.length,0);
  await assert.rejects(db.query('insert into sl_account_owner(user_id) values($1)',[other]));
  console.log('PASS Anonymous access is denied, later signups remain ordinary accounts, and ownership is unique');
} finally { await db.close(); }
