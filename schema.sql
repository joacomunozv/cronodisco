-- Cronodisco: esquema Supabase
-- Mazos y canciones solo para administradores; jugadores se unen con funciones RPC.

create extension if not exists pgcrypto;

create table if not exists public.admins (
  email text primary key
);

create table if not exists public.decks (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  description text default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.songs (
  id bigint generated always as identity primary key,
  deck_id uuid not null references public.decks(id) on delete cascade,
  artist text not null,
  title text not null,
  year int not null check (year between 1800 and 2100),
  deezer_id bigint,
  status text not null default 'OK',
  note text default ''
);
create index if not exists songs_deck_idx on public.songs(deck_id);

create table if not exists public.games (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  deck_ids uuid[] not null default '{}',
  deck_names text not null default '',
  win_cards int not null default 10,
  start_tokens int not null default 2,
  status text not null default 'lobby' check (status in ('lobby','playing','finished','cancelled')),
  turn_name text,
  winner text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  name text not null,
  cards int not null default 0,
  tokens int not null default 0,
  joined_from text not null default 'celular',
  joined_at timestamptz not null default now(),
  unique (game_id, name)
);
create index if not exists players_game_idx on public.players(game_id);

-- ¿El usuario conectado es administrador?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

alter table public.admins  enable row level security;
alter table public.decks   enable row level security;
alter table public.songs   enable row level security;
alter table public.games   enable row level security;
alter table public.players enable row level security;

drop policy if exists admin_all on public.admins;
drop policy if exists admin_all on public.decks;
drop policy if exists admin_all on public.songs;
drop policy if exists admin_all on public.games;
drop policy if exists admin_all on public.players;
create policy admin_all on public.admins  for select to authenticated using (public.is_admin());
create policy admin_all on public.decks   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.songs   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.games   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.players for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Jugador: unirse a una partida en sala de espera
create or replace function public.join_game(p_code text, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare g games; p players; n int;
begin
  select * into g from games where code = upper(trim(p_code));
  if not found then raise exception 'No existe una partida con ese código'; end if;
  if g.status <> 'lobby' then raise exception 'La partida ya comenzó o terminó'; end if;
  p_name := left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 18);
  if p_name = '' then raise exception 'Escribe tu nombre'; end if;
  select * into p from players where game_id = g.id and lower(name) = lower(p_name);
  if found then
    return json_build_object('game_id', g.id, 'player_id', p.id, 'name', p.name, 'code', g.code, 'rejoined', true);
  end if;
  select count(*) into n from players where game_id = g.id;
  if n >= 10 then raise exception 'La partida está llena (máximo 10)'; end if;
  insert into players (game_id, name) values (g.id, p_name) returning * into p;
  return json_build_object('game_id', g.id, 'player_id', p.id, 'name', p.name, 'code', g.code, 'rejoined', false);
end $$;

-- Jugador: estado público de una partida (sin canciones)
create or replace function public.game_state(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'code', g.code, 'status', g.status, 'turn_name', g.turn_name, 'winner', g.winner,
    'win_cards', g.win_cards, 'deck_names', g.deck_names,
    'players', coalesce((select json_agg(json_build_object('name', p.name, 'cards', p.cards, 'tokens', p.tokens) order by p.joined_at)
                         from players p where p.game_id = g.id), '[]'::json))
  from games g where g.code = upper(trim(p_code));
$$;

-- Jugador: salir de la sala de espera
create or replace function public.leave_game(p_player_id uuid) returns void
language sql security definer set search_path = public as $$
  delete from players p using games g
  where p.id = p_player_id and g.id = p.game_id and g.status = 'lobby';
$$;

revoke all on function public.join_game(text, text) from public;
revoke all on function public.game_state(text) from public;
revoke all on function public.leave_game(uuid) from public;
grant execute on function public.join_game(text, text) to anon, authenticated;
grant execute on function public.game_state(text) to anon, authenticated;
grant execute on function public.leave_game(uuid) to anon, authenticated;
grant execute on function public.is_admin() to authenticated;

-- Tiempo real para el panel de administrador
do $$ begin
  begin alter publication supabase_realtime add table public.players; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.games;   exception when duplicate_object then null; end;
end $$;

insert into public.admins (email) values ('joacomunozv@gmail.com') on conflict do nothing;
