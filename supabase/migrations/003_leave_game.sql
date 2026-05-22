create or replace function public.leave_game(
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
  v_alive_count integer;
  v_total_count integer;
  v_winner_player_id uuid;
  v_next_turn_player_id uuid;
begin
  select *
    into v_player
    from public.players
   where id = p_player_id
     and game_id = p_game_id
     and client_token = p_player_token
   for update;

  if not found then
    raise exception 'invalid player session';
  end if;

  select *
    into v_game
    from public.games
   where id = p_game_id
   for update;

  if not found then
    raise exception 'game not found';
  end if;

  if v_game.status = 'waiting' then
    delete from public.players
     where id = p_player_id;

    select count(*)
      into v_total_count
      from public.players
     where game_id = p_game_id;

    if v_total_count = 0 then
      update public.games
         set status = 'finished',
             host_player_id = null,
             current_turn_player_id = null,
             winner_player_id = null
       where id = p_game_id;
    else
      if v_game.host_player_id = p_player_id then
        update public.games
           set host_player_id = (
             select id
               from public.players
              where game_id = p_game_id
              order by seat_index
              limit 1
           )
         where id = p_game_id;
      end if;
    end if;

    return jsonb_build_object('left', true);
  end if;

  if v_game.status = 'playing' then
    update public.players
       set dice_count = 0,
           is_eliminated = true
     where id = p_player_id;

    if v_game.current_round_id is not null then
      delete from public.round_hands
       where round_id = v_game.current_round_id
         and player_id = p_player_id;
    end if;

    select count(*)
      into v_alive_count
      from public.players
     where game_id = p_game_id
       and is_eliminated = false
       and dice_count > 0;

    if v_alive_count <= 1 then
      select id
        into v_winner_player_id
        from public.players
       where game_id = p_game_id
         and is_eliminated = false
         and dice_count > 0
       limit 1;

      update public.games
         set status = 'finished',
             current_turn_player_id = null,
             winner_player_id = v_winner_player_id
       where id = p_game_id;
    elsif v_game.current_turn_player_id = p_player_id then
      v_next_turn_player_id := public.next_alive_player_id(p_game_id, v_player.seat_index);

      update public.games
         set current_turn_player_id = v_next_turn_player_id
       where id = p_game_id;
    end if;

    return jsonb_build_object('left', true);
  end if;

  return jsonb_build_object('left', true);
end;
$$;

grant execute on function public.leave_game(uuid, uuid, uuid) to anon, authenticated;
