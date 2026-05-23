create extension if not exists pgcrypto;

create table public.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  status text not null default 'waiting' check (status in ('waiting', 'playing', 'finished')),
  host_player_id uuid,
  current_round_id uuid,
  current_turn_player_id uuid,
  winner_player_id uuid,
  max_players integer not null default 10 check (max_players between 2 and 10),
  last_activity_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 18),
  seat_index integer not null,
  dice_count integer not null default 5 check (dice_count >= 0),
  is_eliminated boolean not null default false,
  client_token uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  unique (game_id, seat_index)
);

alter table public.games
  add constraint games_host_player_fk foreign key (host_player_id) references public.players(id) on delete set null,
  add constraint games_current_turn_player_fk foreign key (current_turn_player_id) references public.players(id) on delete set null,
  add constraint games_winner_player_fk foreign key (winner_player_id) references public.players(id) on delete set null;

create table public.rounds (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_number integer not null,
  starter_player_id uuid not null references public.players(id) on delete restrict,
  current_bid_id uuid,
  challenge_locked boolean not null default false,
  status text not null default 'active' check (status in ('active', 'resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (game_id, round_number)
);

alter table public.games
  add constraint games_current_round_fk foreign key (current_round_id) references public.rounds(id) on delete set null;

create table public.round_hands (
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  dice_values smallint[] not null,
  primary key (round_id, player_id)
);

create table public.bids (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  quantity integer not null check (quantity > 0),
  face integer not null check (face between 1 and 6),
  is_special_six boolean not null default false,
  rank integer not null,
  created_at timestamptz not null default now()
);

alter table public.rounds
  add constraint rounds_current_bid_fk foreign key (current_bid_id) references public.bids(id) on delete set null;

create table public.challenges (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  round_id uuid not null references public.rounds(id) on delete cascade,
  challenger_player_id uuid not null references public.players(id) on delete cascade,
  declarer_player_id uuid not null references public.players(id) on delete cascade,
  bid_id uuid not null references public.bids(id) on delete cascade,
  claimed_quantity integer not null,
  actual_quantity integer not null,
  outcome text not null check (outcome in ('success', 'fail', 'exact')),
  penalty integer not null default 0,
  loser_player_id uuid references public.players(id) on delete set null,
  revealed_hands jsonb not null default '[]'::jsonb,
  next_starter_player_id uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now()
);

create index players_game_id_idx on public.players(game_id);
create index rounds_game_id_idx on public.rounds(game_id);
create index bids_round_id_created_at_idx on public.bids(round_id, created_at desc);
create index challenges_game_id_created_at_idx on public.challenges(game_id, created_at desc);
create index games_status_last_activity_idx on public.games(status, last_activity_at);

alter table public.games enable row level security;
alter table public.players enable row level security;
alter table public.rounds enable row level security;
alter table public.round_hands enable row level security;
alter table public.bids enable row level security;
alter table public.challenges enable row level security;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists games_touch_updated_at on public.games;
create trigger games_touch_updated_at
before update on public.games
for each row execute function public.touch_updated_at();

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
     and game_id = any(coalesce(v_expired_ids, '{}'::uuid[]));

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

create or replace function public.generate_game_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    exit when not exists (select 1 from public.games where code = v_code);
  end loop;

  return v_code;
end;
$$;

create or replace function public.bid_rank(
  p_quantity integer,
  p_face integer,
  p_is_special_six boolean
)
returns integer
language plpgsql
immutable
as $$
begin
  if p_quantity < 1 then
    raise exception 'quantity must be positive';
  end if;

  if p_is_special_six then
    if p_face <> 6 then
      raise exception 'special bid must use face 6';
    end if;

    return p_quantity * 20 + 6;
  end if;

  if p_face < 1 or p_face > 5 then
    raise exception 'normal bid face must be 1 through 5';
  end if;

  return p_quantity * 10 + p_face;
end;
$$;

create or replace function public.roll_dice(p_count integer)
returns smallint[]
language sql
volatile
as $$
  select coalesce(array_agg((floor(random() * 6)::integer + 1)::smallint), '{}'::smallint[])
  from generate_series(1, greatest(p_count, 0));
$$;

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

create or replace function public.next_alive_player_id(
  p_game_id uuid,
  p_after_seat integer
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id
    from public.players
   where game_id = p_game_id
     and is_eliminated = false
     and dice_count > 0
   order by
     case when seat_index > p_after_seat then 0 else 1 end,
     seat_index
   limit 1;
$$;

create or replace function public.create_round(
  p_game_id uuid,
  p_starter_player_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round_id uuid;
  v_round_number integer;
  v_player public.players;
begin
  select coalesce(max(round_number), 0) + 1
    into v_round_number
    from public.rounds
   where game_id = p_game_id;

  insert into public.rounds (game_id, round_number, starter_player_id)
  values (p_game_id, v_round_number, p_starter_player_id)
  returning id into v_round_id;

  for v_player in
    select *
      from public.players
     where game_id = p_game_id
       and is_eliminated = false
       and dice_count > 0
     order by seat_index
  loop
    insert into public.round_hands (round_id, player_id, dice_values)
    values (v_round_id, v_player.id, public.roll_dice(v_player.dice_count));
  end loop;

  update public.games
     set status = 'playing',
         current_round_id = v_round_id,
         current_turn_player_id = p_starter_player_id,
         last_activity_at = now()
   where id = p_game_id;

  return v_round_id;
end;
$$;

create or replace function public.create_game(p_player_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game_id uuid;
  v_code text;
  v_player public.players;
begin
  perform public.expire_inactive_games();

  if nullif(trim(p_player_name), '') is null then
    raise exception 'player name is required';
  end if;

  v_code := public.generate_game_code();

  insert into public.games (code)
  values (v_code)
  returning id into v_game_id;

  insert into public.players (game_id, name, seat_index)
  values (v_game_id, left(trim(p_player_name), 18), 0)
  returning * into v_player;

  update public.games
     set host_player_id = v_player.id
   where id = v_game_id;

  return jsonb_build_object(
    'game_id', v_game_id,
    'code', v_code,
    'player_id', v_player.id,
    'player_token', v_player.client_token
  );
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

  update public.games
     set last_activity_at = now()
   where id = v_game.id;

  return jsonb_build_object(
    'game_id', v_game.id,
    'code', v_game.code,
    'player_id', v_player.id,
    'player_token', v_player.client_token
  );
end;
$$;

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
  perform public.expire_inactive_games();

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
  perform public.expire_inactive_games();

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
     set current_turn_player_id = v_next_player_id,
         last_activity_at = now()
   where id = p_game_id;

  return public.app_state(p_game_id, p_player_id, p_player_token);
end;
$$;

create or replace function public.challenge_bid(
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
  v_round public.rounds;
  v_player public.players;
  v_bid public.bids;
  v_actual_quantity integer;
  v_penalty integer;
  v_outcome text;
  v_loser_player_id uuid;
  v_loser_seat integer;
  v_loser_eliminated boolean;
  v_alive_count integer;
  v_winner_player_id uuid;
  v_next_starter_player_id uuid;
  v_revealed_hands jsonb;
begin
  perform public.expire_inactive_games();

  v_player := public.assert_player(p_game_id, p_player_id, p_player_token);

  select *
    into v_game
    from public.games
   where id = p_game_id
   for update;

  if v_game.status <> 'playing' then
    raise exception 'game is not playing';
  end if;

  select *
    into v_round
    from public.rounds
   where id = v_game.current_round_id
   for update;

  if v_round.status <> 'active' or v_round.challenge_locked then
    raise exception 'round is already being resolved';
  end if;

  if v_round.current_bid_id is null then
    raise exception 'there is no bid to challenge';
  end if;

  select *
    into v_bid
    from public.bids
   where id = v_round.current_bid_id;

  if v_bid.player_id = p_player_id then
    raise exception 'declarer cannot challenge their own bid';
  end if;

  update public.rounds
     set challenge_locked = true
   where id = v_round.id
     and challenge_locked = false;

  select coalesce(count(*), 0)::integer
    into v_actual_quantity
    from public.round_hands h
    cross join lateral unnest(h.dice_values) as die(value)
   where h.round_id = v_round.id
     and (
       (v_bid.is_special_six and die.value = 6)
       or
       (not v_bid.is_special_six and (die.value = v_bid.face or die.value = 6))
     );

  v_penalty := abs(v_actual_quantity - v_bid.quantity);

  if v_actual_quantity < v_bid.quantity then
    v_outcome := 'success';
    v_loser_player_id := v_bid.player_id;
  elsif v_actual_quantity > v_bid.quantity then
    v_outcome := 'fail';
    v_loser_player_id := p_player_id;
  else
    v_outcome := 'exact';
    v_loser_player_id := null;
  end if;

  select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', p.id,
          'name', p.name,
          'seat_index', p.seat_index,
          'dice', h.dice_values
        )
        order by p.seat_index
      ),
      '[]'::jsonb
    )
    into v_revealed_hands
    from public.round_hands h
    join public.players p on p.id = h.player_id
   where h.round_id = v_round.id;

  if v_loser_player_id is not null and v_penalty > 0 then
    update public.players
       set dice_count = greatest(dice_count - v_penalty, 0),
           is_eliminated = dice_count - v_penalty <= 0
     where id = v_loser_player_id
     returning seat_index, is_eliminated into v_loser_seat, v_loser_eliminated;
  end if;

  update public.rounds
     set status = 'resolved',
         resolved_at = now()
   where id = v_round.id;

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

    insert into public.challenges (
      game_id,
      round_id,
      challenger_player_id,
      declarer_player_id,
      bid_id,
      claimed_quantity,
      actual_quantity,
      outcome,
      penalty,
      loser_player_id,
      revealed_hands,
      next_starter_player_id
    )
    values (
      p_game_id,
      v_round.id,
      p_player_id,
      v_bid.player_id,
      v_bid.id,
      v_bid.quantity,
      v_actual_quantity,
      v_outcome,
      v_penalty,
      v_loser_player_id,
      v_revealed_hands,
      null
    );

    update public.games
       set status = 'finished',
           current_turn_player_id = null,
           winner_player_id = v_winner_player_id,
           last_activity_at = now()
     where id = p_game_id;

    return public.app_state(p_game_id, p_player_id, p_player_token);
  end if;

  if v_outcome = 'exact' then
    v_next_starter_player_id := p_player_id;
  else
    if v_loser_eliminated then
      v_next_starter_player_id := public.next_alive_player_id(p_game_id, v_loser_seat);
    else
      v_next_starter_player_id := v_loser_player_id;
    end if;
  end if;

  insert into public.challenges (
    game_id,
    round_id,
    challenger_player_id,
    declarer_player_id,
    bid_id,
    claimed_quantity,
    actual_quantity,
    outcome,
    penalty,
    loser_player_id,
    revealed_hands,
    next_starter_player_id
  )
  values (
    p_game_id,
    v_round.id,
    p_player_id,
    v_bid.player_id,
    v_bid.id,
    v_bid.quantity,
    v_actual_quantity,
    v_outcome,
    v_penalty,
    v_loser_player_id,
    v_revealed_hands,
    v_next_starter_player_id
  );

  perform public.create_round(p_game_id, v_next_starter_player_id);

  return public.app_state(p_game_id, p_player_id, p_player_token);
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

grant usage on schema public to anon, authenticated;
grant execute on function public.create_game(text) to anon, authenticated;
grant execute on function public.join_game(text, text) to anon, authenticated;
grant execute on function public.start_game(uuid, uuid, uuid) to anon, authenticated;
grant execute on function public.place_bid(uuid, uuid, uuid, integer, integer, boolean) to anon, authenticated;
grant execute on function public.challenge_bid(uuid, uuid, uuid) to anon, authenticated;
grant execute on function public.app_state(uuid, uuid, uuid) to anon, authenticated;
