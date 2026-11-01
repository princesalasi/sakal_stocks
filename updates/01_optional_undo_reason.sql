-- Update 1 (1 Nov 2026): the reason for Undo is now optional.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run more than once. Does not change or delete any log entries.

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
