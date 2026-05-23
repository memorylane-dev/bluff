begin;

truncate table
  public.challenges,
  public.bids,
  public.round_hands,
  public.rounds,
  public.players,
  public.games
restart identity cascade;

commit;

select
  'reset complete' as status,
  now() as reset_at,
  (select count(*) from public.games) as games,
  (select count(*) from public.players) as players,
  (select count(*) from public.rounds) as rounds,
  (select count(*) from public.round_hands) as round_hands,
  (select count(*) from public.bids) as bids,
  (select count(*) from public.challenges) as challenges;
