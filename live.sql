-- Cronodisco: juego en vivo desde los celulares
-- El iPad sigue siendo la mesa (motor del juego). Los celulares envían acciones y leen la vista pública.

alter table public.games add column if not exists view jsonb;

create table if not exists public.game_actions (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.games(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  kind text not null check (kind in ('place','skip','buy','challenge','reveal','next')),
  slot int,
  seq int,
  created_at timestamptz not null default now()
);
create index if not exists game_actions_game_idx on public.game_actions(game_id, id);

alter table public.game_actions enable row level security;
drop policy if exists host_actions on public.game_actions;
create policy host_actions on public.game_actions for all to authenticated
  using (exists (select 1 from games g where g.id = game_id and (public.is_admin() or (g.host_id = auth.uid() and public.is_host()))))
  with check (exists (select 1 from games g where g.id = game_id and (public.is_admin() or (g.host_id = auth.uid() and public.is_host()))));
grant select, delete on public.game_actions to authenticated;

-- Jugador: enviar una acción (el iPad la valida y la aplica)
create or replace function public.send_action(p_player_id uuid, p_kind text, p_slot int default null, p_seq int default null) returns void
language plpgsql security definer set search_path = public as $$
declare g games; n int;
begin
  select g2.* into g from players p join games g2 on g2.id = p.game_id where p.id = p_player_id;
  if not found then raise exception 'Jugador no encontrado'; end if;
  if g.status <> 'playing' then raise exception 'La partida no está en curso'; end if;
  if p_kind not in ('place','skip','buy','challenge','reveal','next') then raise exception 'Acción no válida'; end if;
  select count(*) into n from game_actions where game_id = g.id;
  if n > 60 then raise exception 'Demasiadas acciones pendientes'; end if;
  insert into game_actions (game_id, player_id, kind, slot, seq) values (g.id, p_player_id, p_kind, p_slot, p_seq);
end $$;

-- Estado público: ahora incluye la vista de la mesa (sin la canción en juego hasta revelarla)
create or replace function public.game_state(p_code text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'code', g.code, 'status', g.status, 'turn_name', g.turn_name, 'winner', g.winner,
    'win_cards', g.win_cards, 'deck_names', g.deck_names, 'view', g.view,
    'players', coalesce((select json_agg(json_build_object('name', p.name, 'cards', p.cards, 'tokens', p.tokens) order by p.joined_at)
                         from players p where p.game_id = g.id), '[]'::json))
  from games g where g.code = upper(trim(p_code));
$$;

revoke all on function public.send_action(uuid, text, int, int) from public;
grant execute on function public.send_action(uuid, text, int, int) to anon, authenticated;

do $$ begin
  begin alter publication supabase_realtime add table public.game_actions; exception when duplicate_object then null; end;
end $$;

-- Música en los celulares (juego a distancia)
alter table public.games add column if not exists remote_audio boolean not null default false;

-- v3: acciones con número correlativo (evita duplicados entre tiempo real y respaldo)
alter table public.game_actions add column if not exists n bigint;
drop function if exists public.send_action(uuid, text, int, int);
create or replace function public.send_action(p_player_id uuid, p_kind text, p_slot int default null, p_seq int default null, p_n bigint default null) returns void
language plpgsql security definer set search_path = public as $$
declare g games; c int;
begin
  select g2.* into g from players p join games g2 on g2.id = p.game_id where p.id = p_player_id;
  if not found then raise exception 'Jugador no encontrado'; end if;
  if g.status <> 'playing' then raise exception 'La partida no está en curso'; end if;
  if p_kind not in ('place','skip','buy','challenge','reveal','next') then raise exception 'Acción no válida'; end if;
  select count(*) into c from game_actions where game_id = g.id;
  if c > 60 then raise exception 'Demasiadas acciones pendientes'; end if;
  insert into game_actions (game_id, player_id, kind, slot, seq, n) values (g.id, p_player_id, p_kind, p_slot, p_seq, p_n);
end $$;
revoke all on function public.send_action(uuid, text, int, int, bigint) from public;
grant execute on function public.send_action(uuid, text, int, int, bigint) to anon, authenticated;
