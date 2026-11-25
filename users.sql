-- Cronodisco: usuarios anfitriones con aprobación del administrador

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

-- Perfil automático al registrarse (el admin queda aprobado de inmediato)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (user_id, email, name, status, decided_at)
  values (new.id, new.email, left(coalesce(new.raw_user_meta_data ->> 'name', ''), 40),
          case when exists (select 1 from admins a where lower(a.email) = lower(new.email)) then 'approved' else 'pending' end,
          case when exists (select 1 from admins a where lower(a.email) = lower(new.email)) then now() end)
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Perfiles de usuarios que ya existían
insert into public.profiles (user_id, email, status, decided_at)
select u.id, u.email,
       case when exists (select 1 from public.admins a where lower(a.email) = lower(u.email)) then 'approved' else 'pending' end,
       case when exists (select 1 from public.admins a where lower(a.email) = lower(u.email)) then now() end
from auth.users u on conflict (user_id) do nothing;

-- ¿Anfitrión aprobado? (el admin también cuenta)
create or replace function public.is_host() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or exists (select 1 from profiles where user_id = auth.uid() and status = 'approved');
$$;

alter table public.games add column if not exists host_id uuid default auth.uid() references auth.users(id) on delete set null;
alter table public.games add column if not exists host_name text default '';

alter table public.profiles enable row level security;
drop policy if exists own_or_admin on public.profiles;
drop policy if exists admin_update on public.profiles;
create policy own_or_admin on public.profiles for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy admin_update on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Mazos y canciones: los anfitriones leen, solo el admin modifica
drop policy if exists admin_all on public.decks;
drop policy if exists host_read on public.decks;
drop policy if exists admin_write on public.decks;
create policy host_read on public.decks for select to authenticated using (public.is_host());
create policy admin_write on public.decks for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists admin_all on public.songs;
drop policy if exists host_read on public.songs;
drop policy if exists admin_write on public.songs;
create policy host_read on public.songs for select to authenticated using (public.is_host());
create policy admin_write on public.songs for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Partidas y jugadores: cada anfitrión maneja las suyas; el admin ve todas
drop policy if exists admin_all on public.games;
drop policy if exists host_games on public.games;
create policy host_games on public.games for all to authenticated
  using (public.is_admin() or (host_id = auth.uid() and public.is_host()))
  with check (public.is_admin() or (host_id = auth.uid() and public.is_host()));
drop policy if exists admin_all on public.players;
drop policy if exists host_players on public.players;
create policy host_players on public.players for all to authenticated
  using (exists (select 1 from games g where g.id = game_id and (public.is_admin() or (g.host_id = auth.uid() and public.is_host()))))
  with check (exists (select 1 from games g where g.id = game_id and (public.is_admin() or (g.host_id = auth.uid() and public.is_host()))));

grant select, update on public.profiles to authenticated;
grant execute on function public.is_host() to authenticated;

-- Admin: eliminar un usuario (borra su cuenta y perfil; sus partidas quedan sin anfitrión)
create or replace function public.admin_delete_user(p_user_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Solo el administrador puede eliminar usuarios'; end if;
  if p_user_id = auth.uid() then raise exception 'No puedes eliminar tu propia cuenta'; end if;
  delete from auth.users where id = p_user_id;
end $$;
revoke all on function public.admin_delete_user(uuid) from public;
grant execute on function public.admin_delete_user(uuid) to authenticated;

select email, status from public.profiles;
