-- =====================================================================
-- ONE-TIME FRESH START – deletes ALL stock entries and the activity log.
-- Kept: people, PINs, admin rights, low-stock levels, and logins.
-- This cannot be undone. Run it only once, right before you start real use.
--
-- Supabase: SQL Editor → New query → paste everything → Run.
-- If Supabase warns about a "destructive operation", confirm.
-- =====================================================================
begin;

-- The log is normally locked against deleting. Unlock it only for this moment.
alter table sakal.movements disable trigger user;
alter table sakal.events    disable trigger user;

delete from sakal.movements;
delete from sakal.events;

-- Lock it again.
alter table sakal.movements enable trigger user;
alter table sakal.events    enable trigger user;

-- Tell the app on every phone to throw away its saved copy of the old entries.
insert into sakal.events(user_id, action, details) values (null, 'log reset', 'All test entries cleared – fresh start');

commit;

-- Check: entries_left should be 0, people_kept should be your number of people.
select (select count(*) from sakal.movements) as entries_left,
       (select count(*) from sakal.users)     as people_kept;
