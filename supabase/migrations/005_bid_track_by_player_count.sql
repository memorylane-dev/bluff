create or replace function public.place_bid(
  p_game_id uuid,
  p_player_id uuid,
  p_player_token uuid,
  p_quantity integer,
  p_face integer,
  p_is_special_six boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_round public.rounds;
  v_player public.players;
  v_previous_bid public.bids;
  v_rank integer;
  v_bid_id uuid;
  v_total_dice integer;
  v_alive_count integer;
  v_track_dice integer;
  v_next_player_id uuid;
begin
  v_player := public.assert_player(p_game_id, p_player_id, p_player_token);

  select *
    into v_game
    from public.games
   where id = p_game_id
   for update;

  if v_game.status <> 'playing' then
    raise exception 'game is not playing';
  end if;

  if v_game.current_turn_player_id <> p_player_id then
    raise exception 'not your turn';
  end if;

  select *
    into v_round
    from public.rounds
   where id = v_game.current_round_id
   for update;

  if v_round.status <> 'active' or v_round.challenge_locked then
    raise exception 'round is not active';
  end if;

  v_rank := public.bid_rank(p_quantity, p_face, p_is_special_six);

  if v_round.current_bid_id is not null then
    select *
      into v_previous_bid
      from public.bids
     where id = v_round.current_bid_id;

    if v_rank <= v_previous_bid.rank then
      raise exception 'bid must be higher than current bid';
    end if;
  end if;

  select coalesce(sum(dice_count), 0)::integer,
         count(*)::integer
    into v_total_dice,
         v_alive_count
    from public.players
   where game_id = p_game_id
     and is_eliminated = false
     and dice_count > 0;

  v_track_dice := v_total_dice + least(
    greatest(
      case
        when v_alive_count <= 3 then 0
        when v_alive_count <= 6 then (v_alive_count - 3) * 2
        else 6 + (v_alive_count - 6) * 2
      end,
      0
    ),
    16
  );

  if p_is_special_six then
    if p_quantity * 2 > v_track_dice then
      raise exception 'special six quantity is above the current track';
    end if;
  elsif p_quantity > v_track_dice then
    raise exception 'quantity is above the current track';
  end if;

  insert into public.bids (game_id, round_id, player_id, quantity, face, is_special_six, rank)
  values (p_game_id, v_round.id, p_player_id, p_quantity, p_face, p_is_special_six, v_rank)
  returning id into v_bid_id;

  update public.rounds
     set current_bid_id = v_bid_id
   where id = v_round.id;

  v_next_player_id := public.next_alive_player_id(p_game_id, v_player.seat_index);

  update public.games
     set current_turn_player_id = v_next_player_id
   where id = p_game_id;

  return public.app_state(p_game_id, p_player_id, p_player_token);
end;
$$;

grant execute on function public.place_bid(uuid, uuid, uuid, integer, integer, boolean) to anon, authenticated;
