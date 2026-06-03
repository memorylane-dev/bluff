alter table public.games
  drop constraint if exists games_max_players_check;

alter table public.games
  alter column max_players set default 20,
  add constraint games_max_players_check check (max_players between 2 and 20);

update public.games
   set max_players = 20
 where status = 'waiting'
   and max_players < 20;
