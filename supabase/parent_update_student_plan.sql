-- My English Coach: allow linked parents to edit only study goal/plan fields.
create or replace function public.parent_update_student_plan(
  p_weeks integer,
  p_minutes integer,
  p_goal text,
  p_interest text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  sid uuid;
  old_state jsonb;
  old_profile jsonb;
  new_profile jsonb;
begin
  select linked_student_id into sid
  from public.profiles
  where id = auth.uid() and role = 'parent';

  if sid is null then
    raise exception '연결된 학생이 없습니다.';
  end if;

  if p_weeks not in (4, 8, 12) then
    raise exception '학습 기간은 4, 8, 12주 중에서 선택해 주세요.';
  end if;
  if p_minutes not in (15, 30, 45) then
    raise exception '하루 학습 시간은 15, 30, 45분 중에서 선택해 주세요.';
  end if;
  if p_goal not in ('exam', 'basics', 'reading') then
    raise exception '학습 목표 값이 올바르지 않습니다.';
  end if;
  if p_interest not in ('soccer', 'games', 'friends') then
    raise exception '관심 주제 값이 올바르지 않습니다.';
  end if;

  select state into old_state
  from public.learning_data
  where student_id = sid
  for update;

  if old_state is null then
    raise exception '학생의 클라우드 학습 기록을 찾을 수 없습니다.';
  end if;

  old_profile := coalesce(old_state->'profile', '{}'::jsonb);
  new_profile := old_profile || jsonb_build_object(
    'weeks', p_weeks,
    'minutes', p_minutes,
    'goal', p_goal,
    'interest', p_interest
  );

  update public.learning_data
  set state = jsonb_set(old_state, '{profile}', new_profile, true),
      updated_at = now()
  where student_id = sid;
end;
$$;

revoke all on function public.parent_update_student_plan(integer, integer, text, text) from public, anon;
grant execute on function public.parent_update_student_plan(integer, integer, text, text) to authenticated;
