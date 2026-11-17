-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 15 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;
select set_config('ebda.fy_override', '1', false);

-- ---------------------------------------------------------------- الصلاحيات: الدالة العامة فقط (كما فى 002) — جداول النسخ الاحتياطى غير متاحة لأى دور عام
revoke all on all tables in schema ebda from anon, authenticated;
revoke all on all sequences in schema ebda from anon, authenticated;
revoke execute on all functions in schema ebda from public, anon, authenticated;
grant usage on schema ebda to anon, authenticated;
grant execute on function ebda.api(jsonb) to anon, authenticated;
grant execute on function public.api(jsonb) to anon, authenticated;

insert into ebda.config(key,value) values ('schema_version','9') on conflict (key) do update set value='9';

do $ov$ begin perform set_config('ebda.fy_override', '', false); end $ov$;

-- ===================== F90 — the TEMS bridge =====================
-- EBDA Finance inside TEMS — the bridge (v10.57). Run AFTER the finance schema (ebda) is installed in the TEMS database.
-- Re-runnable. Drops no table / column, changes no financial data.
--
-- One identity: the TEMS session. The finance system no longer has its own sign-in in this database:
--   * every finance call goes through public.ebda_fin_api(p_token, req): the TEMS session is checked, then the finance profile linked to
--     that TEMS account (ebda.users.tems_user_id) is used — with ITS role, scope (places) and detailed permissions (ebda.can / perms_of,
--     unchanged), at every single call (a grant withdrawn stops the very next call);
--   * the TEMS administrator (role «manager») is the finance administrator (a linked finance profile is created for him once);
--   * nobody else gets any finance access unless the administrator links his TEMS account to a finance profile — a TEMS role (principal…)
--     gives nothing by itself;
--   * only the TEMS administrator may add / change / remove finance users and their permissions (even a finance «manage_users» grant does
--     not allow it here); nobody can change the administrator's profile; every change is logged (ebda.tems_grant_log + the finance audit);
--   * the finance system's own sign-in (public.api with a user name + PIN) is closed to the browser in this database.

alter table ebda.users add column if not exists tems_user_id text default '';
create unique index if not exists ux_fin_users_tems on ebda.users(tems_user_id) where coalesce(tems_user_id,'') <> '';

create table if not exists ebda.tems_grant_log(
  id bigserial primary key, at timestamptz not null default now(), by_tems text not null, by_name text default '',
  action text not null, fin_user text default '', tems_user text default '', before jsonb, after jsonb);
alter table ebda.tems_grant_log enable row level security;
revoke all on ebda.tems_grant_log from anon, authenticated;

-- the TEMS account behind a session: id, role, name (null when the session is not valid)
create or replace function ebda.tems_who(p_token text) returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare s public.ebda_gate_sessions; u public.ebda_gate_ucache;
begin
  s := public.ebda_gate_session(p_token);
  if s.token_hash is null or coalesce(s.must_change,false) then return null; end if;
  select * into u from public.ebda_gate_ucache where id = s.user_id;
  if u.id is null then return null; end if;
  return jsonb_build_object('id', u.id, 'role', u.role, 'school', coalesce(u.school_id,''), 'name', coalesce(u.u->>'name',''), 'username', coalesce(u.u->>'username',''));
end $$;
revoke all on function ebda.tems_who(text) from public, anon, authenticated;

-- the finance profile of a TEMS account (the administrator's is created once, linked, with the administrator role)
create or replace function ebda.tems_fin_user(w jsonb) returns ebda.users language plpgsql volatile security definer set search_path = ebda as $$
declare fu ebda.users;
begin
  if w is null then return null; end if;
  select * into fu from ebda.users where tems_user_id = w->>'id';
  if w->>'role' = 'manager' then
    if fu.id is null then
      insert into ebda.users(id, username, pin, name, role, schools, active, email, tems_user_id)
      values ('tems_'||(w->>'id'), 'tems:'||coalesce(nullif(w->>'username',''), w->>'id'), encode(extensions.gen_random_bytes(18),'hex'),
              coalesce(nullif(w->>'name',''),'الأدمن'), 'manager', '*', 'نعم', '', w->>'id')
      on conflict (id) do update set tems_user_id = excluded.tems_user_id
      returning * into fu;
      insert into ebda.tems_grant_log(by_tems, by_name, action, fin_user, tems_user, after)
        values (w->>'id', coalesce(w->>'name',''), 'admin-profile', fu.id, w->>'id', jsonb_build_object('role','manager','schools','*'));
    elsif fu.role <> 'manager' or coalesce(fu.active,'') not like '%نعم%' or fu.schools <> '*' then
      update ebda.users set role = 'manager', active = 'نعم', schools = '*' where id = fu.id returning * into fu;   -- the administrator is always the finance administrator
    end if;
    return fu;
  end if;
  if fu.id is null or coalesce(fu.active,'') not like '%نعم%' then return null; end if;
  return fu;
end $$;
revoke all on function ebda.tems_fin_user(jsonb) from public, anon, authenticated;

-- may this TEMS session open «الماليات»? (the menu entry is shown only then — the server decides, not the page)
create or replace function public.ebda_fin_access(p_token text) returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare w jsonb; fu ebda.users;
begin
  w := ebda.tems_who(p_token);
  if w is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  fu := ebda.tems_fin_user(w);
  if fu.id is null then return jsonb_build_object('ok', false, 'error', 'لا توجد صلاحية على الماليات — يمنحها الأدمن'); end if;
  return jsonb_build_object('ok', true, 'admin', w->>'role' = 'manager', 'user', jsonb_build_object('id', fu.id, 'name', fu.name, 'role', fu.role, 'schools', fu.schools),
                            'permissions', to_jsonb(ebda.perms_of(fu)));
end $$;
revoke all on function public.ebda_fin_access(text) from public;
grant execute on function public.ebda_fin_access(text) to anon, authenticated;

-- every finance call from TEMS
create or replace function public.ebda_fin_api(p_token text, req jsonb) returns jsonb language plpgsql volatile security definer
set search_path = ebda, public, extensions as $$
declare w jsonb; fu ebda.users; action text := coalesce(req->>'action',''); res jsonb; tid text; prev jsonb; fid text; tu public.ebda_gate_ucache;
begin
  w := ebda.tems_who(p_token);
  if w is null then return jsonb_build_object('error', 'انتهت الجلسة — سجّل الدخول من جديد'); end if;
  fu := ebda.tems_fin_user(w);
  if fu.id is null then return jsonb_build_object('error', 'لا تملك صلاحية على الماليات — يمنحها الأدمن فقط'); end if;
  req := req - 'auth';
  -- no separate finance sign-in inside TEMS
  if action in ('login','logout','setPassword','resetPin') then
    if action = 'logout' then return jsonb_build_object('ok', true); end if;
    return jsonb_build_object('error', 'الدخول وكلمات السر من TEMS — لا توجد كلمة سر منفصلة للماليات');
  end if;
  -- the users of the finance system and their permissions: the TEMS administrator only
  if action in ('addUser','updateUser','deleteUser','temsUsers') then
    if w->>'role' <> 'manager' then
      return jsonb_build_object('error', 'منح صلاحيات الماليات وتعديلها للأدمن فقط');
    end if;
    if action = 'temsUsers' then
      return jsonb_build_object('ok', true, 'items', coalesce((
        select jsonb_agg(jsonb_build_object('id', c.id, 'name', coalesce(c.u->>'name',''), 'username', coalesce(c.u->>'username',''), 'role', c.role,
                 'role_label', case c.role when 'manager' then 'الأدمن' when 'principal' then 'مدير مدرسة' when 'teacher' then 'معلم' when 'student' then 'طالب' else c.role end,
                 'school', coalesce((select s->>'name' from public.ebda_state m, jsonb_array_elements(m.data->'schools') s where m.id = 'main' and s->>'id' = c.school_id limit 1), ''),
                 'linked', (select x.id from ebda.users x where x.tems_user_id = c.id limit 1)) order by c.u->>'name')
          from public.ebda_gate_ucache c where not c.deleted and not c.disabled and c.role not in ('student','parent')), '[]'::jsonb));
    end if;
    fid := coalesce(req->>'id', req#>>'{patch,id}', '');
    if action in ('updateUser','deleteUser') and exists (select 1 from ebda.users x where x.id = fid and coalesce(x.tems_user_id,'') <> ''
         and exists (select 1 from public.ebda_gate_ucache c where c.id = x.tems_user_id and c.role = 'manager')) then
      return jsonb_build_object('error', 'حساب الأدمن لا يُعدَّل من هنا');
    end if;
    tid := coalesce(req#>>'{user,tems_user_id}', req#>>'{patch,tems_user_id}', '');
    if action in ('addUser','updateUser') and tid <> '' then
      select * into tu from public.ebda_gate_ucache where id = tid and not deleted and not disabled;
      if tu.id is null then return jsonb_build_object('error', 'حساب TEMS غير موجود أو موقوف'); end if;
      if tu.role = 'manager' then return jsonb_build_object('error', 'الأدمن له صلاحية الماليات كاملة تلقائياً'); end if;
      if exists (select 1 from ebda.users x where x.tems_user_id = tid and x.id <> fid) then
        return jsonb_build_object('error', 'حساب TEMS هذا مرتبط بالفعل بمستخدم آخر فى الماليات'); end if;
    end if;
    if action in ('updateUser','deleteUser') then select to_jsonb(x) - 'pin' into prev from ebda.users x where x.id = fid; end if;
    if req ? 'user' then req := jsonb_set(req, '{user}', (req->'user') - 'tems_user_id'); end if;
    if req ? 'patch' then req := jsonb_set(req, '{patch}', (req->'patch') - 'tems_user_id'); end if;
  end if;
  perform set_config('ebda.auth_uid', fu.id, true);
  perform set_config('ebda.session_hash', '', true);
  perform set_config('ebda.fy_override', '', true);
  begin
    res := ebda.api_core(req);
  exception when sqlstate 'EB001' then
    return ebda.err(sqlerrm);
  end;
  -- the administrator sees which TEMS account each finance user is
  if action = 'bootstrap' and w->>'role' = 'manager' and jsonb_typeof(res->'users') = 'array' then
    res := jsonb_set(res, '{users}', coalesce((select jsonb_agg(x || jsonb_build_object('tems_user_id', coalesce(fu2.tems_user_id,''),
             'tems_name', coalesce((select coalesce(c.u->>'name','')||' — '||coalesce(c.u->>'username','') from public.ebda_gate_ucache c where c.id = fu2.tems_user_id),'')) order by o)
             from jsonb_array_elements(res->'users') with ordinality t(x,o) left join ebda.users fu2 on fu2.id = x->>'id'), '[]'::jsonb));
  end if;
  -- link / log the users' changes
  if action in ('addUser','updateUser','deleteUser') and jsonb_typeof(res) = 'object' and not (res ? 'error') then
    if action = 'addUser' then fid := coalesce(res#>>'{item,id}', res#>>'{user,id}', res->>'id', (select x.id from ebda.users x where x.username = req#>>'{user,username}' order by x.id desc limit 1), ''); end if;
    if action in ('addUser','updateUser') and fid <> '' and tid <> '' then update ebda.users set tems_user_id = tid where id = fid; end if;
    insert into ebda.tems_grant_log(by_tems, by_name, action, fin_user, tems_user, before, after)
      values (w->>'id', coalesce(w->>'name',''), action, fid, coalesce(nullif(tid,''), prev->>'tems_user_id', ''), prev,
              (select to_jsonb(x) - 'pin' from ebda.users x where x.id = fid));
  end if;
  return res;
end $$;
revoke all on function public.ebda_fin_api(text, jsonb) from public;
grant execute on function public.ebda_fin_api(text, jsonb) to anon, authenticated;

-- the log of the grants (administrator only)
create or replace function public.ebda_fin_grant_log(p_token text, p_limit int default 300) returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare w jsonb;
begin
  w := ebda.tems_who(p_token);
  if w is null or w->>'role' <> 'manager' then return jsonb_build_object('ok', false, 'error', 'للأدمن فقط'); end if;
  return jsonb_build_object('ok', true, 'items', coalesce((select jsonb_agg(to_jsonb(g) order by g.id desc) from (select * from ebda.tems_grant_log order by id desc limit greatest(1, least(p_limit, 2000))) g), '[]'::jsonb));
end $$;
revoke all on function public.ebda_fin_grant_log(text, int) from public;
grant execute on function public.ebda_fin_grant_log(text, int) to anon, authenticated;

-- the finance system's own sign-in is closed to the browser in this database (the bridge above is the only door)
do $$ begin
  if to_regprocedure('public.api(jsonb)') is not null then
    execute 'revoke execute on function public.api(jsonb) from public, anon, authenticated';
  end if;
end $$;
insert into ebda.config(key, value) values ('allow_pin_auth', 'no') on conflict (key) do update set value = 'no';
insert into ebda.config(key, value) values ('tems_bridge', 'v10.57') on conflict (key) do update set value = 'v10.57';

select 'EBDA finance bridge OK' as result,
  (select count(*) from ebda.users where coalesce(tems_user_id,'') <> '') as linked_users,
  has_function_privilege('anon', 'public.api(jsonb)', 'execute') as old_signin_open,
  has_function_privilege('anon', 'public.ebda_fin_api(text,jsonb)', 'execute') as bridge_open;

select 'EBDA finance install OK' as result, (select count(*) from pg_tables where schemaname='ebda') as tables, (select count(*) from pg_proc p join pg_namespace s on s.oid=p.pronamespace where s.nspname='ebda') as functions, to_regprocedure('public.ebda_fin_api(text,jsonb)') is not null as tems_bridge;
