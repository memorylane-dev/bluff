create or replace function public.list_open_games()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'game_id', room.id,
        'code', room.code,
        'host_player_name', room.host_player_name,
        'player_count', room.player_count,
        'max_players', room.max_players,
        'created_at', room.created_at
      )
      order by room.created_at desc
    ),
    '[]'::jsonb
  )
  from (
    select
      g.id,
      g.code,
      g.max_players,
      g.created_at,
      host.name as host_player_name,
      count(p.id)::integer as player_count
    from public.games g
    join public.players host on host.id = g.host_player_id
    join public.players p on p.game_id = g.id
    where g.status = 'waiting'
    group by g.id, g.code, g.max_players, g.created_at, host.name
    having count(p.id) < g.max_players
    order by g.created_at desc
    limit 20
  ) room;
$$;

grant execute on function public.list_open_games() to anon, authenticated;
