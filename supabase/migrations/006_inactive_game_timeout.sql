alter table public.games
  add column if not exists last_activity_at timestamptz not null default now();

create index if not exists games_status_last_activity_idx
  on public.games(status, last_activity_at);

create or replace function public.expire_inactive_games()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expired_ids uuid[];
begin
  with expired as (
    update public.games
       set status = 'finished',
           current_turn_player_id = null,
           winner_player_id = null
     where status <> 'finished'
       and last_activity_at < now() - interval '30 minutes'
    returning id
  )
  select coalesce(array_agg(id), '{}'::uuid[])
    into v_expired_ids
    from expired;

  update public.rounds
     set status = 'resolved',
         resolved_at = coalesce(resolved_at, now())
   where status = 'active'
     and game_id = any(v_expired_ids);

  return coalesce(array_length(v_expired_ids, 1), 0);
end;
$$;

create or replace function public.touch_game_activity_from_child()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game_id uuid;
begin
  if tg_op = 'DELETE' then
    v_game_id := old.game_id;
  else
    v_game_id := new.game_id;
  end if;

  update public.games
     set last_activity_at = now()
   where id = v_game_id
     and status <> 'finished';

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end;
$$;

drop trigger if exists players_touch_game_activity on public.players;
create trigger players_touch_game_activity
after insert or update or delete on public.players
for each row execute function public.touch_game_activity_from_child();

drop trigger if exists bids_touch_game_activity on public.bids;
create trigger bids_touch_game_activity
after insert on public.bids
for each row execute function public.touch_game_activity_from_child();

drop trigger if exists challenges_touch_game_activity on public.challenges;
create trigger challenges_touch_game_activity
after insert on public.challenges
for each row execute function public.touch_game_activity_from_child();

create or replace function public.assert_player(
  p_game_id uuid,
  p_player_id uuid,
  p_player_token uuid
)
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players;
begin
  perform public.expire_inactive_games();

  select *
    into v_player
    from public.players
   where id = p_player_id
     and game_id = p_game_id
     and client_token = p_player_token;

  if not found then
    raise exception 'invalid player session';
  end if;

  if v_player.is_eliminated or v_player.dice_count <= 0 then
    raise exception 'eliminated players cannot act';
  end if;

  return v_player;
end;
$$;

create or replace function public.list_open_games()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rooms jsonb;
begin
  perform public.expire_inactive_games();

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
    into v_rooms
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

  return v_rooms;
end;
$$;

create or replace function public.join_game(
  p_code text,
  p_player_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_player public.players;
  v_player_count integer;
  v_seat_index integer;
begin
  perform public.expire_inactive_games();

  if nullif(trim(p_player_name), '') is null then
    raise exception 'player name is required';
  end if;

  select *
    into v_game
    from public.games
   where code = upper(trim(p_code))
   for update;

  if not found then
    raise exception 'game not found';
  end if;

  if v_game.status <> 'waiting' then
    raise exception 'game already started';
  end if;

  select count(*)
    into v_player_count
    from public.players
   where game_id = v_game.id;

  if v_player_count >= v_game.max_players then
    raise exception 'game is full';
  end if;

  select coalesce(max(seat_index), -1) + 1
    into v_seat_index
    from public.players
   where game_id = v_game.id;

  insert into public.players (game_id, name, seat_index)
  values (v_game.id, left(trim(p_player_name), 18), v_seat_index)
  returning * into v_player;

  return jsonb_build_object(
    'game_id', v_game.id,
    'code', v_game.code,
    'player_id', v_player.id,
    'player_token', v_player.client_token
  );
end;
$$;

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
  perform public.expire_inactive_games();

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

create or replace function public.app_state(
  p_game_id uuid,
  p_player_id uuid default null,
  p_player_token uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game public.games;
  v_round public.rounds;
  v_me public.players;
  v_has_me boolean := false;
  v_players jsonb;
  v_current_bid jsonb;
  v_latest_bids jsonb;
  v_last_challenge jsonb;
  v_own_hand smallint[] := '{}'::smallint[];
begin
  perform public.expire_inactive_games();

  select *
    into v_game
    from public.games
   where id = p_game_id;

  if not found then
    raise exception 'game not found';
  end if;

  if p_player_id is not null and p_player_token is not null then
    select *
      into v_me
      from public.players
     where id = p_player_id
       and game_id = p_game_id
       and client_token = p_player_token;
    v_has_me := found;
  end if;

  select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'name', p.name,
          'seat_index', p.seat_index,
          'dice_count', p.dice_count,
          'is_eliminated', p.is_eliminated,
          'is_host', p.id = v_game.host_player_id
        )
        order by p.seat_index
      ),
      '[]'::jsonb
    )
    into v_players
    from public.players p
   where p.game_id = p_game_id;

  if v_game.current_round_id is not null then
    select *
      into v_round
      from public.rounds
     where id = v_game.current_round_id;

    if v_round.current_bid_id is not null then
      select jsonb_build_object(
          'id', b.id,
          'player_id', b.player_id,
          'player_name', p.name,
          'quantity', b.quantity,
          'face', b.face,
          'is_special_six', b.is_special_six,
          'rank', b.rank,
          'created_at', b.created_at
        )
        into v_current_bid
        from public.bids b
        join public.players p on p.id = b.player_id
       where b.id = v_round.current_bid_id;
    end if;

    if v_has_me then
      select coalesce(dice_values, '{}'::smallint[])
        into v_own_hand
        from public.round_hands
       where round_id = v_round.id
         and player_id = v_me.id;
    end if;

    select coalesce(
        jsonb_agg(row_json order by created_at desc),
        '[]'::jsonb
      )
      into v_latest_bids
      from (
        select
          b.created_at,
          jsonb_build_object(
            'id', b.id,
            'player_id', b.player_id,
            'player_name', p.name,
            'quantity', b.quantity,
            'face', b.face,
            'is_special_six', b.is_special_six,
            'rank', b.rank,
            'created_at', b.created_at
          ) as row_json
        from public.bids b
        join public.players p on p.id = b.player_id
        where b.round_id = v_round.id
        order by b.created_at desc
        limit 8
      ) recent_bids;
  else
    v_latest_bids := '[]'::jsonb;
  end if;

  select jsonb_build_object(
      'id', c.id,
      'challenger_player_id', c.challenger_player_id,
      'challenger_name', challenger.name,
      'declarer_player_id', c.declarer_player_id,
      'declarer_name', declarer.name,
      'claimed_quantity', c.claimed_quantity,
      'actual_quantity', c.actual_quantity,
      'outcome', c.outcome,
      'penalty', c.penalty,
      'loser_player_id', c.loser_player_id,
      'loser_name', loser.name,
      'revealed_hands', c.revealed_hands,
      'created_at', c.created_at
    )
    into v_last_challenge
    from public.challenges c
    join public.players challenger on challenger.id = c.challenger_player_id
    join public.players declarer on declarer.id = c.declarer_player_id
    left join public.players loser on loser.id = c.loser_player_id
   where c.game_id = p_game_id
   order by c.created_at desc
   limit 1;

  return jsonb_build_object(
    'game', jsonb_build_object(
      'id', v_game.id,
      'code', v_game.code,
      'status', v_game.status,
      'max_players', v_game.max_players,
      'host_player_id', v_game.host_player_id,
      'current_round_id', v_game.current_round_id,
      'current_turn_player_id', v_game.current_turn_player_id,
      'winner_player_id', v_game.winner_player_id
    ),
    'me', case
      when v_has_me then jsonb_build_object(
        'id', v_me.id,
        'name', v_me.name,
        'seat_index', v_me.seat_index,
        'dice_count', v_me.dice_count,
        'is_eliminated', v_me.is_eliminated,
        'is_host', v_me.id = v_game.host_player_id
      )
      else null
    end,
    'players', v_players,
    'round', case
      when v_game.current_round_id is not null then jsonb_build_object(
        'id', v_round.id,
        'round_number', v_round.round_number,
        'starter_player_id', v_round.starter_player_id,
        'current_bid', v_current_bid
      )
      else null
    end,
    'own_hand', coalesce(to_jsonb(v_own_hand), '[]'::jsonb),
    'latest_bids', coalesce(v_latest_bids, '[]'::jsonb),
    'last_challenge', v_last_challenge
  );
end;
$$;

grant execute on function public.expire_inactive_games() to anon, authenticated;
grant execute on function public.list_open_games() to anon, authenticated;
grant execute on function public.join_game(text, text) to anon, authenticated;
grant execute on function public.leave_game(uuid, uuid, uuid) to anon, authenticated;
grant execute on function public.app_state(uuid, uuid, uuid) to anon, authenticated;
