do $$
declare
  v_remaining_count bigint;
begin
  truncate table
    public.challenges,
    public.bids,
    public.round_hands,
    public.rounds,
    public.players,
    public.games
  restart identity cascade;

  select
    (select count(*) from public.games)
    + (select count(*) from public.players)
    + (select count(*) from public.rounds)
    + (select count(*) from public.round_hands)
    + (select count(*) from public.bids)
    + (select count(*) from public.challenges)
    into v_remaining_count;

  if v_remaining_count <> 0 then
    raise exception 'game reset failed: % rows still remain', v_remaining_count;
  end if;
end $$;

select
  'reset complete' as status,
  current_database() as database_name,
  current_user as database_user,
  now() as reset_at,
  (select count(*) from public.games) as games,
  (select count(*) from public.players) as players,
  (select count(*) from public.rounds) as rounds,
  (select count(*) from public.round_hands) as round_hands,
  (select count(*) from public.bids) as bids,
  (select count(*) from public.challenges) as challenges;
