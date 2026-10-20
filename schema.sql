-- =====================================================================
--  Messagerie — schéma Supabase (à coller dans SQL Editor → Run)
--  Tables, sécurité (RLS), temps réel et stockage des médias.
-- =====================================================================

-- ---------- Tables ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text unique not null check (username ~ '^[A-Za-z0-9_.]{3,30}$'),
  display_name text,
  avatar_url   text,
  created_at   timestamptz not null default now()
);

create table if not exists public.conversations (
  id              uuid primary key default gen_random_uuid(),
  title           text,
  is_group        boolean not null default false,
  created_by      uuid references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  last_preview    text,
  last_sender     uuid references public.profiles(id) on delete set null
);

create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  joined_at       timestamptz not null default now(),
  last_read_at    timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members(user_id);

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id       uuid not null references public.profiles(id) on delete cascade,
  kind            text not null check (kind in ('text','image','audio')),
  body            text check (char_length(body) <= 4000),
  media_path      text,
  duration_ms     integer,
  created_at      timestamptz not null default now(),
  check ((kind = 'text' and body is not null) or (kind <> 'text' and media_path is not null))
);
create index if not exists messages_conv_created_idx on public.messages(conversation_id, created_at desc);

-- ---------- Fonctions utilitaires ----------
-- Appartenance (security definer pour éviter la récursion RLS)
create or replace function public.is_member(c uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from conversation_members where conversation_id = c and user_id = auth.uid());
$$;

-- Profil créé automatiquement à l'inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare uname text;
begin
  uname := coalesce(nullif(new.raw_user_meta_data->>'username', ''), split_part(new.email, '@', 1));
  uname := regexp_replace(uname, '[^A-Za-z0-9_.]', '', 'g');
  if char_length(uname) < 3 then uname := 'user_' || substr(new.id::text, 1, 6); end if;
  if exists (select 1 from profiles where username = uname) then
    uname := left(uname, 23) || '_' || substr(new.id::text, 1, 6);
  end if;
  insert into profiles (id, username, display_name)
  values (new.id, uname, coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), uname));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Mise à jour de l'aperçu de conversation à chaque message
create or replace function public.on_message_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update conversations set
    last_message_at = new.created_at,
    last_sender     = new.sender_id,
    last_preview    = case new.kind when 'text' then left(new.body, 120)
                                    when 'image' then '📷 Photo'
                                    else '🎤 Message vocal' end
  where id = new.conversation_id;
  return new;
end $$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.on_message_insert();

-- Démarrer (ou retrouver) une discussion à deux
create or replace function public.start_direct(other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  if other = auth.uid() then raise exception 'Impossible de discuter avec soi-même'; end if;
  select c.id into cid from conversations c
    join conversation_members a on a.conversation_id = c.id and a.user_id = auth.uid()
    join conversation_members b on b.conversation_id = c.id and b.user_id = other
   where not c.is_group limit 1;
  if cid is not null then return cid; end if;
  insert into conversations (is_group, created_by) values (false, auth.uid()) returning id into cid;
  insert into conversation_members (conversation_id, user_id) values (cid, auth.uid()), (cid, other);
  return cid;
end $$;

-- Créer un groupe
create or replace function public.create_group(p_title text, p_members uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into conversations (title, is_group, created_by)
  values (coalesce(nullif(trim(p_title), ''), 'Groupe'), true, auth.uid()) returning id into cid;
  insert into conversation_members (conversation_id, user_id)
  select cid, u from unnest(array_append(p_members, auth.uid())) as u
  on conflict do nothing;
  return cid;
end $$;

revoke execute on function public.start_direct(uuid) from anon;
revoke execute on function public.create_group(text, uuid[]) from anon;

-- ---------- Sécurité (RLS) ----------
alter table public.profiles             enable row level security;
alter table public.conversations        enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages             enable row level security;

drop policy if exists "profiles lisibles" on public.profiles;
create policy "profiles lisibles" on public.profiles for select to authenticated using (true);
drop policy if exists "profil modifiable par soi" on public.profiles;
create policy "profil modifiable par soi" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "conversations des membres" on public.conversations;
create policy "conversations des membres" on public.conversations for select to authenticated
  using (public.is_member(id));

drop policy if exists "membres visibles" on public.conversation_members;
create policy "membres visibles" on public.conversation_members for select to authenticated
  using (public.is_member(conversation_id));
drop policy if exists "lu/non lu" on public.conversation_members;
create policy "lu/non lu" on public.conversation_members for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke update on public.conversation_members from authenticated;
grant update (last_read_at) on public.conversation_members to authenticated;

drop policy if exists "lire les messages" on public.messages;
create policy "lire les messages" on public.messages for select to authenticated
  using (public.is_member(conversation_id));
drop policy if exists "envoyer un message" on public.messages;
create policy "envoyer un message" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_member(conversation_id));

-- ---------- Temps réel ----------
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.conversation_members;
exception when duplicate_object then null; end $$;

-- ---------- Stockage des photos et vocaux ----------
-- Bucket privé, fichiers rangés par conversation : media/<conversation_id>/<message_id>.<ext>
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 20971520)   -- 20 Mo max par fichier
on conflict (id) do nothing;

drop policy if exists "media lecture membres" on storage.objects;
create policy "media lecture membres" on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));

drop policy if exists "media envoi membres" on storage.objects;
create policy "media envoi membres" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_member(((storage.foldername(name))[1])::uuid));
