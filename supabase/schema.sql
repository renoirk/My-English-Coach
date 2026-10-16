-- My English Coach cloud sync schema
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('student','parent')),
  display_name text,
  link_code text unique,
  linked_student_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id,email,role,display_name)
  values(new.id,new.email,case when new.raw_user_meta_data->>'role' = 'parent' then 'parent' else 'student' end,coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create table if not exists public.learning_data (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.learning_data enable row level security;

create or replace function public.is_linked_student(p_student_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'parent' and p.linked_student_id = p_student_id) $$;

drop policy if exists "profile read self or linked student" on public.profiles;
create policy "profile read self or linked student" on public.profiles for select to authenticated
using (id = auth.uid() or public.is_linked_student(id));

drop policy if exists "profile insert self" on public.profiles;
create policy "profile insert self" on public.profiles for insert to authenticated
with check (id = auth.uid() and role in ('student','parent'));

drop policy if exists "profile update self safe" on public.profiles;
create policy "profile update self safe" on public.profiles for update to authenticated
using (id = auth.uid()) with check (id = auth.uid() and role in ('student','parent'));

drop policy if exists "learning data read student or linked parent" on public.learning_data;
create policy "learning data read student or linked parent" on public.learning_data for select to authenticated
using (student_id = auth.uid() or public.is_linked_student(student_id));

drop policy if exists "student inserts own learning data" on public.learning_data;
create policy "student inserts own learning data" on public.learning_data for insert to authenticated
with check (student_id = auth.uid());

drop policy if exists "student updates own learning data" on public.learning_data;
create policy "student updates own learning data" on public.learning_data for update to authenticated
using (student_id = auth.uid()) with check (student_id = auth.uid());

create or replace function public.protect_profile_role_and_link()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.role is distinct from old.role then
    raise exception '계정 유형은 변경할 수 없습니다.';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_profile_role_and_link on public.profiles;
create trigger protect_profile_role_and_link before update on public.profiles
for each row execute function public.protect_profile_role_and_link();

create or replace function public.rotate_student_link_code()
returns text language plpgsql security definer set search_path = public
as $$
declare new_code text;
begin
  if not exists(select 1 from public.profiles where id = auth.uid() and role = 'student') then
    raise exception '학생 계정만 연결 코드를 발급할 수 있습니다.';
  end if;
  new_code := upper(substr(encode(gen_random_bytes(6),'hex'),1,10));
  update public.profiles set link_code = new_code where id = auth.uid();
  return new_code;
end;
$$;

create or replace function public.link_student_by_code(p_code text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare sid uuid;
begin
  if not exists(select 1 from public.profiles where id = auth.uid() and role = 'parent') then
    raise exception '보호자 계정으로 로그인해 주세요.';
  end if;
  select id into sid from public.profiles where link_code = upper(trim(p_code)) and role = 'student';
  if sid is null then raise exception '연결 코드가 올바르지 않습니다.'; end if;
  update public.profiles set linked_student_id = sid where id = auth.uid();
  return sid;
end;
$$;

grant execute on function public.rotate_student_link_code() to authenticated;
grant execute on function public.link_student_by_code(text) to authenticated;
