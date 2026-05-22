create or replace function public.start_game(
  p_game_id uuid,
  p_player_id uuid,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.players;
  v_starter_player_id uuid;
  v_player_count integer;
  v_starting_dice_count integer;
begin
  v_player := public.assert_player(p_game_id, p_player_id, p_player_token);

  select *
    into v_game
    from public.games
   where id = p_game_id
   for update;

  if v_game.host_player_id <> p_player_id then
    raise exception 'only host can start the game';
  end if;

  if v_game.status <> 'waiting' then
    raise exception 'game is not waiting';
  end if;

  select count(*)
    into v_player_count
    from public.players
   where game_id = p_game_id
     and is_eliminated = false
     and dice_count > 0;

  if v_player_count < 2 then
    raise exception 'at least two players are required';
  end if;

  v_starting_dice_count := floor(40::numeric / v_player_count)::integer;

  update public.players
     set dice_count = v_starting_dice_count,
         is_eliminated = false
   where game_id = p_game_id;

  select id
    into v_starter_player_id
    from public.players
   where game_id = p_game_id
     and is_eliminated = false
     and dice_count > 0
   order by random()
   limit 1;

  perform public.create_round(p_game_id, v_starter_player_id);

  return public.app_state(p_game_id, p_player_id, p_player_token);
end;
$$;

grant execute on function public.start_game(uuid, uuid, uuid) to anon, authenticated;
