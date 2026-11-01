-- =====================================================================
-- Sakal Snacks – stock tracker database setup (Supabase)
-- Run this ONCE in Supabase: SQL Editor → New query → paste → Run.
-- Before running, change the name and PIN in the LAST line of this file.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Private schema: not reachable from the website directly.
-- The website can only call the functions at the bottom of this file.
create schema if not exists sakal;
revoke all on schema sakal from public;

-- ---------- tables ----------
create table if not exists sakal.users (
  id          serial primary key,
  name        text not null unique check (length(btrim(name)) between 1 and 40),
  pin_hash    text not null,
  is_admin    boolean not null default false,
  active      boolean not null default true,
  failed      int not null default 0,
  locked_until timestamptz,
  created_at  timestamptz not null default now()
);

create table if not exists sakal.sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    int not null references sakal.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);

-- The stock log. Every production, take-out, stock count and reversal is one row.
-- Rows can never be changed or deleted (see triggers below).
create table if not exists sakal.movements (
  id         bigserial primary key,
  logged_at  timestamptz not null default now(),          -- real time of entry, set by the server
  user_id    int not null references sakal.users(id),
  entry_date date not null,                                -- the day it happened (user can pick)
  product    text not null check (product in ('ripe','unripe')),
  batch      text not null check (length(btrim(batch)) between 1 and 20),
  kind       text not null check (kind in ('production','takeout','count','reversal')),
  boxes      int  not null,                                -- + adds to stock, − removes
  reason     text check (reason is null or reason in ('sale','sample','own use','damaged','other')),
  customer   text,
  note       text,
  ref_id     bigint references sakal.movements(id),        -- for reversals: the entry being reversed
  group_id   uuid,                                         -- one take-out split over several batches
  constraint boxes_nonzero check (boxes <> 0 or kind = 'count')
);
create index if not exists movements_pb on sakal.movements(product, batch);
create index if not exists movements_ref on sakal.movements(ref_id);

-- Activity log: user added, PIN reset, settings changed, lockouts ...
create table if not exists sakal.events (
  id        bigserial primary key,
  logged_at timestamptz not null default now(),
  user_id   int references sakal.users(id),
  action    text not null,
  details   text
);

create table if not exists sakal.settings (
  product   text primary key check (product in ('ripe','unripe')),
  low_stock int  not null default 5 check (low_stock >= 0)
);
insert into sakal.settings(product, low_stock) values ('ripe', 5), ('unripe', 5) on conflict do nothing;

-- ---------- logs are permanent ----------
create or replace function sakal.no_change() returns trigger language plpgsql as $$
begin
  raise exception 'Log entries cannot be changed or deleted';
end $$;

drop trigger if exists movements_locked on sakal.movements;
create trigger movements_locked before update or delete on sakal.movements
  for each row execute function sakal.no_change();
drop trigger if exists movements_no_truncate on sakal.movements;
create trigger movements_no_truncate before truncate on sakal.movements
  for each statement execute function sakal.no_change();
drop trigger if exists events_locked on sakal.events;
create trigger events_locked before update or delete on sakal.events
  for each row execute function sakal.no_change();
drop trigger if exists events_no_truncate on sakal.events;
create trigger events_no_truncate before truncate on sakal.events
  for each statement execute function sakal.no_change();

-- ---------- helpers (private) ----------
create or replace function sakal.me(p_token uuid) returns sakal.users
language plpgsql as $$
declare u sakal.users;
begin
  select u2.* into u
    from sakal.sessions s join sakal.users u2 on u2.id = s.user_id
   where s.token = p_token and s.expires_at > now() and u2.active;
  if not found then raise exception 'NOT_LOGGED_IN'; end if;
  return u;
end $$;

create or replace function sakal.need_admin(u sakal.users) returns void
language plpgsql as $$
begin
  if not u.is_admin then raise exception 'Only an admin can do this'; end if;
end $$;

create or replace function sakal.stock_of(p_product text, p_batch text) returns int
language sql stable as $$
  select coalesce(sum(boxes), 0)::int from sakal.movements where product = p_product and batch = p_batch;
$$;

create or replace function sakal.check_pin(p_pin text) returns void
language plpgsql as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then raise exception 'PIN must be 4 to 6 digits'; end if;
end $$;

create or replace function sakal.check_product(p text) returns void
language plpgsql as $$
begin
  if p is null or p not in ('ripe','unripe') then raise exception 'Choose ripe or unripe'; end if;
end $$;

create or replace function sakal.check_date(d date) returns void
language plpgsql as $$
begin
  if d is null then raise exception 'Date is missing'; end if;
  if d > current_date + 1 then raise exception 'Date cannot be in the future'; end if;
  if d < date '2020-01-01' then raise exception 'Date is too far in the past'; end if;
end $$;

create or replace function sakal.lock_stock() returns void language sql as $$
  select pg_advisory_xact_lock(424242);
$$;

-- Used once below to create the first admin.
create or replace function sakal.create_first_admin(p_name text, p_pin text) returns text
language plpgsql as $$
begin
  if exists (select 1 from sakal.users) then return 'Users already exist – nothing changed'; end if;
  perform sakal.check_pin(p_pin);
  insert into sakal.users(name, pin_hash, is_admin) values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')), true);
  insert into sakal.events(user_id, action, details) values (currval('sakal.users_id_seq'), 'setup', 'First admin created: ' || btrim(p_name));
  return 'Admin ' || btrim(p_name) || ' created';
end $$;

-- =====================================================================
-- Functions the website calls
-- =====================================================================

-- Names for the login screen
create or replace function public.list_users() returns json
language sql stable security definer set search_path = sakal, public as $$
  select coalesce(json_agg(json_build_object('id', id, 'name', name) order by name), '[]'::json)
    from sakal.users where active;
$$;

-- Log in with PIN. 5 wrong PINs → that user is locked for 15 minutes.
-- (Returns an error message instead of raising, so the failed-try counter is kept.)
create or replace function public.login(p_user_id int, p_pin text) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; t uuid;
begin
  select * into u from sakal.users where id = p_user_id and active;
  if not found then return json_build_object('ok', false, 'error', 'Unknown user'); end if;
  if u.locked_until is not null and u.locked_until > now() then
    return json_build_object('ok', false, 'error', 'Too many wrong PINs. Locked for ' ||
      greatest(1, ceil(extract(epoch from (u.locked_until - now())) / 60))::int || ' more minute(s).');
  end if;
  if p_pin is null or u.pin_hash <> extensions.crypt(p_pin, u.pin_hash) then
    if u.failed + 1 >= 5 then
      update sakal.users set failed = 0, locked_until = now() + interval '15 minutes' where id = u.id;
      insert into sakal.events(user_id, action, details) values (u.id, 'locked', '5 wrong PINs – locked for 15 minutes');
      return json_build_object('ok', false, 'error', 'Wrong PIN. Too many tries – locked for 15 minutes.');
    end if;
    update sakal.users set failed = failed + 1 where id = u.id;
    return json_build_object('ok', false, 'error', 'Wrong PIN (' || (4 - u.failed) || case when u.failed = 3 then ' try' else ' tries' end || ' left)');
  end if;
  update sakal.users set failed = 0, locked_until = null where id = u.id;
  delete from sakal.sessions where expires_at < now();
  insert into sakal.sessions(user_id) values (u.id) returning token into t;
  return json_build_object('ok', true, 'token', t, 'user', json_build_object('id', u.id, 'name', u.name, 'is_admin', u.is_admin));
end $$;

create or replace function public.logout(p_token uuid) returns json
language sql security definer set search_path = sakal, public as $$
  delete from sakal.sessions where token = p_token;
  select json_build_object('ok', true);
$$;

-- Everything the app needs. Pass the last ids you already have to get only new rows.
create or replace function public.get_state(p_token uuid, p_after_move bigint default 0, p_after_event bigint default 0) returns json
language plpgsql stable security definer set search_path = sakal, public as $$
declare u sakal.users;
begin
  u := sakal.me(p_token);
  return json_build_object(
    'me', json_build_object('id', u.id, 'name', u.name, 'is_admin', u.is_admin),
    'users', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'is_admin', is_admin, 'active', active) order by id), '[]') from sakal.users),
    'settings', (select coalesce(json_object_agg(product, low_stock), '{}') from sakal.settings),
    'movements', (select coalesce(json_agg(m order by m.id), '[]') from sakal.movements m where m.id > coalesce(p_after_move, 0)),
    'events', (select coalesce(json_agg(e order by e.id), '[]') from sakal.events e where e.id > coalesce(p_after_event, 0)),
    'server_time', now()
  );
end $$;

create or replace function public.add_production(p_token uuid, p_product text, p_boxes int, p_batch text, p_date date, p_note text default null) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; new_id bigint;
begin
  u := sakal.me(p_token);
  perform sakal.check_product(p_product);
  perform sakal.check_date(p_date);
  if p_boxes is null or p_boxes <= 0 or p_boxes > 100000 then raise exception 'Enter how many boxes were produced'; end if;
  if p_batch is null or btrim(p_batch) = '' then raise exception 'Batch is missing'; end if;
  perform sakal.lock_stock();
  insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, note)
  values (u.id, p_date, p_product, btrim(p_batch), 'production', p_boxes, nullif(btrim(p_note), ''))
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id);
end $$;

-- Take boxes out. Empty batch = take from the oldest batches first.
create or replace function public.take_out(p_token uuid, p_product text, p_boxes int, p_batch text, p_reason text, p_customer text, p_note text, p_date date) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; g uuid := gen_random_uuid(); left_ int; avail int; take int; b record; total int;
begin
  u := sakal.me(p_token);
  perform sakal.check_product(p_product);
  perform sakal.check_date(p_date);
  if p_boxes is null or p_boxes <= 0 then raise exception 'Enter how many boxes are taken out'; end if;
  if p_reason is null or p_reason not in ('sale','sample','own use','damaged','other') then raise exception 'Choose a reason'; end if;
  perform sakal.lock_stock();
  if p_batch is not null and btrim(p_batch) <> '' then
    avail := sakal.stock_of(p_product, btrim(p_batch));
    if avail < p_boxes then raise exception 'Only % box(es) of % batch % in stock', avail, p_product, btrim(p_batch); end if;
    insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, reason, customer, note, group_id)
    values (u.id, p_date, p_product, btrim(p_batch), 'takeout', -p_boxes, p_reason, nullif(btrim(p_customer), ''), nullif(btrim(p_note), ''), g);
  else
    select coalesce(sum(boxes), 0) into total from sakal.movements where product = p_product;
    if total < p_boxes then raise exception 'Only % box(es) of % chips in stock', total, p_product; end if;
    left_ := p_boxes;
    for b in
      select batch, sum(boxes)::int as stock, min(entry_date) filter (where kind = 'production') as first_day, min(id) as first_id
        from sakal.movements where product = p_product
       group by batch having sum(boxes) > 0
       order by first_day nulls last, first_id
    loop
      exit when left_ <= 0;
      take := least(left_, b.stock);
      insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, reason, customer, note, group_id)
      values (u.id, p_date, p_product, b.batch, 'takeout', -take, p_reason, nullif(btrim(p_customer), ''), nullif(btrim(p_note), ''), g);
      left_ := left_ - take;
    end loop;
  end if;
  return json_build_object('ok', true, 'group', g);
end $$;

-- Physical count: logs the difference between counted and recorded stock.
create or replace function public.stock_count(p_token uuid, p_product text, p_batch text, p_counted int, p_note text, p_date date) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; cur int; new_id bigint;
begin
  u := sakal.me(p_token);
  perform sakal.check_product(p_product);
  perform sakal.check_date(p_date);
  if p_batch is null or btrim(p_batch) = '' then raise exception 'Choose a batch'; end if;
  if p_counted is null or p_counted < 0 then raise exception 'Enter the number of boxes counted'; end if;
  perform sakal.lock_stock();
  cur := sakal.stock_of(p_product, btrim(p_batch));
  insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, note)
  values (u.id, p_date, p_product, btrim(p_batch), 'count', p_counted - cur,
          'Counted ' || p_counted || ', recorded ' || cur || coalesce(' – ' || nullif(btrim(p_note), ''), ''))
  returning id into new_id;
  return json_build_object('ok', true, 'id', new_id, 'difference', p_counted - cur);
end $$;

-- Undo a wrong entry by adding the opposite entry. The original stays in the log. Reason is optional.
create or replace function public.reverse_entry(p_token uuid, p_id bigint, p_note text) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; m sakal.movements; r record; n int := 0;
begin
  u := sakal.me(p_token);
  perform sakal.lock_stock();
  select * into m from sakal.movements where id = p_id;
  if not found then raise exception 'Entry not found'; end if;
  if m.kind = 'reversal' then raise exception 'A reversal cannot be reversed – enter the correct values again instead'; end if;
  for r in
    select * from sakal.movements x
     where ((m.group_id is not null and x.group_id = m.group_id) or x.id = m.id) and x.kind <> 'reversal'
     order by x.id
  loop
    if exists (select 1 from sakal.movements where ref_id = r.id) then raise exception 'Entry #% was already reversed', r.id; end if;
    if r.boxes <> 0 then
      if sakal.stock_of(r.product, r.batch) - r.boxes < 0 then
        raise exception 'Cannot reverse: boxes of batch % were already taken out. Reverse those take-outs first, or do a stock count.', r.batch;
      end if;
      insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, note, ref_id, group_id)
      values (u.id, current_date, r.product, r.batch, 'reversal', -r.boxes, nullif(btrim(p_note), ''), r.id, null);
      n := n + 1;
    else
      -- a count with no difference: log that it was withdrawn
      insert into sakal.movements(user_id, entry_date, product, batch, kind, boxes, note, ref_id)
      values (u.id, current_date, r.product, r.batch, 'count', 0, 'Withdrawn' || coalesce(': ' || nullif(btrim(p_note), ''), ''), r.id);
      n := n + 1;
    end if;
  end loop;
  return json_build_object('ok', true, 'reversed', n);
end $$;

create or replace function public.change_pin(p_token uuid, p_old text, p_new text) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users;
begin
  u := sakal.me(p_token);
  if u.pin_hash <> extensions.crypt(coalesce(p_old, ''), u.pin_hash) then raise exception 'Current PIN is wrong'; end if;
  perform sakal.check_pin(p_new);
  update sakal.users set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = u.id;
  insert into sakal.events(user_id, action, details) values (u.id, 'pin changed', u.name || ' changed their PIN');
  return json_build_object('ok', true);
end $$;

-- ---------- admin ----------
create or replace function public.add_user(p_token uuid, p_name text, p_pin text, p_is_admin boolean) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users;
begin
  u := sakal.me(p_token); perform sakal.need_admin(u);
  if p_name is null or btrim(p_name) = '' then raise exception 'Enter a name'; end if;
  if exists (select 1 from sakal.users where lower(name) = lower(btrim(p_name))) then raise exception 'That name already exists'; end if;
  perform sakal.check_pin(p_pin);
  insert into sakal.users(name, pin_hash, is_admin) values (btrim(p_name), extensions.crypt(p_pin, extensions.gen_salt('bf')), coalesce(p_is_admin, false));
  insert into sakal.events(user_id, action, details) values (u.id, 'user added', btrim(p_name) || case when p_is_admin then ' (admin)' else '' end);
  return json_build_object('ok', true);
end $$;

create or replace function public.reset_pin(p_token uuid, p_user_id int, p_pin text) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; t sakal.users;
begin
  u := sakal.me(p_token); perform sakal.need_admin(u);
  select * into t from sakal.users where id = p_user_id; if not found then raise exception 'User not found'; end if;
  perform sakal.check_pin(p_pin);
  update sakal.users set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), failed = 0, locked_until = null where id = t.id;
  delete from sakal.sessions where user_id = t.id and t.id <> u.id;
  insert into sakal.events(user_id, action, details) values (u.id, 'pin reset', 'PIN reset for ' || t.name);
  return json_build_object('ok', true);
end $$;

create or replace function public.set_user_active(p_token uuid, p_user_id int, p_active boolean) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; t sakal.users;
begin
  u := sakal.me(p_token); perform sakal.need_admin(u);
  if p_user_id = u.id then raise exception 'You cannot deactivate yourself'; end if;
  select * into t from sakal.users where id = p_user_id; if not found then raise exception 'User not found'; end if;
  update sakal.users set active = p_active where id = t.id;
  if not p_active then delete from sakal.sessions where user_id = t.id; end if;
  insert into sakal.events(user_id, action, details) values (u.id, case when p_active then 'user activated' else 'user deactivated' end, t.name);
  return json_build_object('ok', true);
end $$;

create or replace function public.set_admin(p_token uuid, p_user_id int, p_is_admin boolean) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; t sakal.users;
begin
  u := sakal.me(p_token); perform sakal.need_admin(u);
  if p_user_id = u.id then raise exception 'You cannot change your own admin rights'; end if;
  select * into t from sakal.users where id = p_user_id; if not found then raise exception 'User not found'; end if;
  update sakal.users set is_admin = p_is_admin where id = t.id;
  insert into sakal.events(user_id, action, details) values (u.id, case when p_is_admin then 'made admin' else 'admin removed' end, t.name);
  return json_build_object('ok', true);
end $$;

create or replace function public.set_low_stock(p_token uuid, p_product text, p_boxes int) returns json
language plpgsql security definer set search_path = sakal, public as $$
declare u sakal.users; old int;
begin
  u := sakal.me(p_token); perform sakal.need_admin(u);
  perform sakal.check_product(p_product);
  if p_boxes is null or p_boxes < 0 then raise exception 'Enter 0 or more boxes'; end if;
  select low_stock into old from sakal.settings where product = p_product;
  update sakal.settings set low_stock = p_boxes where product = p_product;
  insert into sakal.events(user_id, action, details) values (u.id, 'low-stock level', p_product || ': ' || old || ' → ' || p_boxes || ' boxes');
  return json_build_object('ok', true);
end $$;

-- Only the functions above are callable from the website.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('list_users','login','logout','get_state','add_production','take_out',
       'stock_count','reverse_entry','change_pin','add_user','reset_pin','set_user_active','set_admin','set_low_stock')
  loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on all tables in schema sakal from public;
revoke all on all functions in schema sakal from public;

-- =====================================================================
-- FIRST ADMIN – change the name and PIN (4–6 digits) before running:
select sakal.create_first_admin('Prince', '1234');
-- =====================================================================
