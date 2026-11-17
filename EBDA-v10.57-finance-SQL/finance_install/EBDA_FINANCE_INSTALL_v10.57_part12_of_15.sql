-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 12 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;
select set_config('ebda.fy_override', '1', false);

-- ============================================================================================================================
--  v11 (2): الرواتب والحوافز — شيت «المؤثرات» بعناوينه الفعلية (55 عموداً: ملاحظات لكل شهر من سبتمبر) ·
--           دورة إلكترونية: مسئول العهدة ← المدير المباشر ← المدير المالى (مع CC) · سجل خصومات معتمد بلا تكرار · تراكمى للعام
-- ============================================================================================================================
-- الحقول بترتيب الملف الفعلى [المفتاح، العنوان، المجموعة، النوع، المستوى، اختيارى؟]
create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  select '[
   ["code","Code","base","text","staff"],["ins_status","الحالة التأمينية","base","text","staff"],["name","الاسم","base","text","staff"],
   ["job","الوظيفة","base","text","staff"],["mobile","رقم الموبيل","base","text","staff"],["ins_no","الرقم التأمينى","base","text","staff"],
   ["national_id","الرقم القومى","base","text","staff"],["bank_account","الحساب البنكى","base","text","staff"],["bank_name","اسم البنك","base","text","staff"],
   ["hire_date","تاريخ التعيين","base","date","staff"],["net_salary","صافى الراتب التعاقدي\nNet salary","base","num","staff"],
   ["gross_salary","إجمالي الراتب\nGross salary","base","num","staff"],["total_cost","إجمالي تكلفة الموظف على الشركة","base","num","staff"],
   ["work_days","عدد ايام العمل","entry","num","month"],["summary","ملخص المؤثرات","finance","text","month"],["hour_deduct","خصم ساعة","finance","num","month"],
   ["day_deduct","خصم يوم","finance","num","month"],["net_after","الراتب الصافى بعد الخصومات","finance","num","month"],
   ["cost_after","إجمالى تكلفة الموظف بعد الخصومات","finance","num","month"],["notes1","ملاحظات","finance","text","month"],
   ["annual_days","الأجازات الإعتيادى — عدد الأيام","entry","num","month"],["annual_detail","الأجازات الإعتيادى — التفصيل","entry","text","month"],
   ["casual_days","الإجازات العارضة — عدد الأيام","entry","num","month"],["casual_detail","الإجازات العارضة — التفصيل","entry","text","month"],
   ["sick_days","الإجازات المرضى — عدد الأيام","entry","num","month"],["sick_detail","الإجازات المرضى — التفصيل","entry","text","month"],
   ["absent_days","غياب بدون إذن — عدد الأيام","entry","num","month"],["absent_detail","غياب بدون إذن — التفصيل","entry","text","month"],
   ["perm_count","الأذونات — عدد الأذونات","entry","num","month"],["perm_detail","الأذونات — التفصيل","entry","text","month"],
   ["notes2","ملاحظات","entry","text","month"],["leave_balance","رصيد الأجازات","base","num","staff"],
   ["m07","شهر يوليو","entry","num","staff"],["m08","شهر أغسطس","entry","num","staff"],["m09","شهر سبتمبر","entry","num","staff"],
   ["m09n","ملاحظات","entry","text","staff",1],
   ["m10","شهر أكتوبر","entry","num","staff"],["m10n","ملاحظات","entry","text","staff",1],["m11","شهر نوفمبر","entry","num","staff"],["m11n","ملاحظات","entry","text","staff",1],
   ["m12","شهر ديسمبر","entry","num","staff"],["m12n","ملاحظات","entry","text","staff",1],["m01","شهر يناير","entry","num","staff"],["m01n","ملاحظات","entry","text","staff",1],
   ["m02","شهر فبراير","entry","num","staff"],["m02n","ملاحظات","entry","text","staff",1],["m03","شهر مارس","entry","num","staff"],["m03n","ملاحظات","entry","text","staff",1],
   ["m04","شهرأبريل","entry","num","staff"],["m04n","ملاحظات","entry","text","staff",1],["m05","شهر مايو","entry","num","staff"],["m05n","ملاحظات","entry","text","staff",1],
   ["m06","شهر يونيو","entry","num","staff"],["m06n","ملاحظات","entry","text","staff",1]]'::jsonb
$$;
-- قواعد الحقول الجديدة (ملاحظات الأشهر) + المدير المباشر يراجع ويصحّح المؤثرات التشغيلية فى مرحلته — دون تغيير ما ضبطه الأدمن
update ebda.config set value = ((select jsonb_object_agg(f->>0, case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb
                                   else '["custody_officer","direct_manager","finance_manager"]'::jsonb end) from jsonb_array_elements(ebda.pay2_fields()) f) || value::jsonb)::text
 where key = 'pay2_field_rules';
update ebda.config c set value = (select jsonb_object_agg(k, case when v ? 'custody_officer' and not v ? 'direct_manager' then v || '["direct_manager"]'::jsonb else v end)
                                    from jsonb_each(c.value::jsonb) e(k, v))::text
 where key = 'pay2_field_rules' and not exists(select 1 from ebda.config where key = 'pay2_rules_v11');
insert into ebda.config(key, value) values('pay2_rules_v11', now()::text) on conflict (key) do nothing;

-- القالب: «الرصيد المتبقى» (معادلة) قبل يوليو؛ ملاحظات الأشهر اختيارية (الملفات الأقدم بدونها تُقبل)
create or replace function ebda.pay2_template_headers() returns jsonb language sql immutable as $$
  select jsonb_agg(h order by o) from (
    select f->>1 h, (o * 10) o from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o)
    union all select 'الرصيد المتبقى', (select o * 10 - 5 from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o) where f->>0 = 'm07')) x
$$;
create or replace function ebda.pay2_header_report(hdrs jsonb) returns jsonb language sql immutable as $$
  with t as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(ebda.pay2_template_headers()) with ordinality a(x, o)),
       f as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(coalesce(hdrs,'[]'::jsonb)) with ordinality a(x, o)),
       m as (select t.h th, t.o tor, f.h fh, f.o fo from t join f on ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm(f.h) and t.k = f.k),
       opt as (select (o * 10) o from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o) where coalesce((f->>5)::int, 0) = 1)
  select jsonb_build_object(
    'template', ebda.pay2_template_headers(),
    'matched', (select count(*) from m),
    'missing', coalesce((select jsonb_agg(t.h order by t.o) from t where not exists(select 1 from m where m.tor = t.o)
                           and not (ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm('ملاحظات') and t.k > 2)), '[]'::jsonb),
    'optional_missing', (select count(*) from t where not exists(select 1 from m where m.tor = t.o) and ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm('ملاحظات') and t.k > 2),
    'extra', coalesce((select jsonb_agg(f.h order by f.o) from f where not exists(select 1 from m where m.fo = f.o)), '[]'::jsonb),
    'renamed', coalesce((select jsonb_agg(jsonb_build_array(m.fh, m.th)) from m where btrim(m.fh) <> btrim(m.th)), '[]'::jsonb),
    'order_changed', exists(select 1 from m a join m b on a.tor < b.tor and a.fo > b.fo))
$$;
-- كتابة حقل على مستوى الموظف: أعمدة الأشهر وملاحظاتها فى months
create or replace function ebda.pay2_set_staff(st_id text, p text, k text, v text, typ text, by_name text) returns void language plpgsql as $$
declare s ebda.pay2_staff; m jsonb; latest text;
begin
  select * into s from ebda.pay2_staff where id = st_id;
  m := ebda.pay2_master(s);
  update ebda.pay2_effects set snap = m where staff_id = st_id and period <> p and snap is null;
  if not exists(select 1 from ebda.pay2_effects where staff_id = st_id and period = p) then
    insert into ebda.pay2_effects(id, staff_id, school_id, period, snap) values(ebda.uid(), st_id, s.school_id, p, m);
  end if;
  update ebda.pay2_effects set snap = coalesce(snap, m) || jsonb_build_object(k, v), updated_by = by_name, updated_at = now()::text where staff_id = st_id and period = p;
  select max(period) into latest from ebda.pay2_effects where staff_id = st_id;
  if p >= coalesce(latest, p) then
    if k ~ '^m\d\dn?$' or k = 'leave_balance_f' then update ebda.pay2_staff set months = coalesce(months,'{}'::jsonb) || jsonb_build_object(k, v) where id = st_id;
    elsif typ = 'num' then execute format('update ebda.pay2_staff set %I = nullif($1,'''')::numeric where id = $2', k) using v, st_id;
    else execute format('update ebda.pay2_staff set %I = $1 where id = $2', k) using v, st_id; end if;
  end if;
end $$;

-- المعرّف الموحد الثابت للموظف (لا يعتمد على الاسم): يُعاد استخدامه عبر الأعوام والمدارس بالرقم القومى
create sequence if not exists ebda.seq_emp_uid;
alter table ebda.pay2_staff add column if not exists emp_uid text default '';
create or replace function ebda.pay2_uid_trg() returns trigger language plpgsql security definer set search_path = ebda as $$
begin
  if coalesce(new.emp_uid,'') = '' then
    if ebda.pay2_nid(new.national_id) <> '' then
      select x.emp_uid into new.emp_uid from ebda.pay2_staff x where ebda.pay2_nid(x.national_id) = ebda.pay2_nid(new.national_id) and coalesce(x.emp_uid,'') <> '' and x.id <> new.id limit 1;
    end if;
    if coalesce(new.emp_uid,'') = '' then new.emp_uid := 'EMP-' || lpad(nextval('ebda.seq_emp_uid')::text, 5, '0'); end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_pay2_uid on ebda.pay2_staff;
create trigger trg_pay2_uid before insert or update of national_id, emp_uid on ebda.pay2_staff for each row execute function ebda.pay2_uid_trg();
do $u$ begin
  perform set_config('ebda.fy_override', '1', true);
  update ebda.pay2_staff s set emp_uid = coalesce((select x.emp_uid from ebda.pay2_staff x where ebda.pay2_nid(x.national_id) <> '' and ebda.pay2_nid(x.national_id) = ebda.pay2_nid(s.national_id)
                                                     and coalesce(x.emp_uid,'') <> '' limit 1), '') where coalesce(s.emp_uid,'') = '';
  update ebda.pay2_staff set emp_uid = 'EMP-' || lpad(nextval('ebda.seq_emp_uid')::text, 5, '0') where coalesce(emp_uid,'') = '';
end $u$;

-- ---------------------------------------------------------------- دورة الاعتماد الشهرية
alter table ebda.pay2_sheets add column if not exists submitted_by text default '';
alter table ebda.pay2_sheets add column if not exists submitted_at text default '';
alter table ebda.pay2_sheets add column if not exists mgr_by text default '';
alter table ebda.pay2_sheets add column if not exists mgr_at text default '';
alter table ebda.pay2_sheets add column if not exists sent_by text default '';
alter table ebda.pay2_sheets add column if not exists sent_at text default '';
alter table ebda.pay2_sheets add column if not exists fin_by text default '';
alter table ebda.pay2_sheets add column if not exists fin_at text default '';
alter table ebda.pay2_sheets add column if not exists fin_note text default '';
alter table ebda.pay2_sheets add column if not exists returned_by text default '';
alter table ebda.pay2_sheets add column if not exists returned_at text default '';
alter table ebda.pay2_sheets add column if not exists returned_reason text default '';
alter table ebda.pay2_sheets add column if not exists returned_stage text default '';
alter table ebda.pay2_sheets add column if not exists version int default 0;
create table if not exists ebda.pay2_flow(id text primary key, school_id text, period text, step text, from_status text, to_status text, note text default '',
  subject text default '', cc jsonb default '[]'::jsonb, attachments jsonb default '[]'::jsonb, by_name text, by_id text, by_role text, at text);
create index if not exists pay2_flow_i on ebda.pay2_flow(school_id, period, at);
create table if not exists ebda.pay2_notices(id text primary key, user_id text not null, kind text default 'action', school_id text, period text, flow_id text,
  title text default '', body text default '', from_name text default '', created_at text default now()::text, read_at text default '');
create index if not exists pay2_notices_u on ebda.pay2_notices(user_id, created_at);
-- سجل الخصومات المعتمدة (لكل موظف/شهر/نوع) — يُعاد إنشاؤه عند كل اعتماد مالى بعد إبطال السابق (لا تكرار ولا حذف)
create table if not exists ebda.pay2_deductions(id text primary key, school_id text, period text, staff_id text, emp_uid text default '', emp_name text default '',
  kind text, qty numeric, rate numeric, method text default '', amount numeric, net_before numeric, net_after numeric, cost_before numeric, cost_after numeric,
  version int default 1, status text default 'active', approved_by text, approved_at text, reversed_by text default '', reversed_at text default '', reversed_reason text default '');
create index if not exists pay2_deductions_i on ebda.pay2_deductions(school_id, period, status);
create unique index if not exists pay2_deductions_u on ebda.pay2_deductions(staff_id, period, kind, version);
-- قاعدة احتساب الخصم: غير مفعّلة افتراضياً (الملفان بلا معادلات للخصم) — يحددها المدير المالى/الأدمن ويفعّلها صراحةً
insert into ebda.config(key, value) values('pay2_deduct_rule', '{"enabled": false, "day_basis": "", "hours_per_day": "", "note": "لا توجد معادلة خصم فى شيت المؤثرات — الخصومات وصافى الراتب بعد الخصومات يدخلها المدير المالى"}')
  on conflict (key) do nothing;

-- ترحيل الحالات السابقة (مرة واحدة): «تمت مراجعة المدير المالى» ← بانتظار الاعتماد المالى · «معتمد» ← معتمد مالياً
do $m$ begin
  perform set_config('ebda.fy_override', '1', true);
  update ebda.pay2_sheets set status = 'sent_finance', sent_by = reviewed_by, sent_at = reviewed_at where status = 'reviewed';
  update ebda.pay2_sheets set status = 'fin_approved', fin_by = approved_by, fin_at = approved_at where status = 'approved';
end $m$;

create or replace function ebda.pay2_status_label(s text) returns text language sql immutable as $$
  select case coalesce(s,'draft') when 'draft' then 'مسودة' when 'submitted' then 'مرسل للمراجعة (المدير المباشر)' when 'mgr_approved' then 'معتمد من المدير المباشر'
    when 'sent_finance' then 'مرسل للمدير المالى' when 'fin_approved' then 'معتمد مالياً' when 'returned' then 'معاد للتعديل' else s end $$;
create or replace function ebda.pay2_owner(s text) returns text language sql immutable as $$
  select case coalesce(s,'draft') when 'draft' then 'مسئول العهدة (المشرف التنفيذى)' when 'returned' then 'مسئول العهدة (المشرف التنفيذى)'
    when 'submitted' then 'المدير المباشر' when 'mgr_approved' then 'المدير المباشر (الإرسال للمدير المالى)' when 'sent_finance' then 'المدير المالى' else '—' end $$;

create or replace function ebda.pay2_is_mgr(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and (ebda.rk(u) = 'direct_manager' or 'payroll.mgr_approve' = any(ebda.perms_of(u)))) $$;
create or replace function ebda.pay2_is_fin(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) <> 'observer' and (ebda.rk(u) = 'finance_manager' or 'payroll.fin_approve' = any(ebda.perms_of(u))) $$;
create or replace function ebda.pay2_is_entry(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and (ebda.rk(u) = 'custody_officer' or 'payroll.submit' = any(ebda.perms_of(u)))) $$;

-- من يعدّل ماذا فى أى مرحلة (بالإضافة لقواعد الحقول): التشغيلى قبل الإرسال للمالى · المالى فى مرحلته · لا تعديل بعد الاعتماد المالى
create or replace function ebda.pay2_stage_ok(u ebda.users, grp text, st text) returns boolean language sql stable as $$
  select case
    when coalesce(st,'draft') = 'fin_approved' then false
    when grp = 'base' then true
    when grp = 'finance' then ebda.pay2_is_fin(u) or ebda.rk(u) = 'admin'
    else (coalesce(st,'draft') in ('draft','returned') and (ebda.pay2_is_entry(u) or ebda.pay2_is_mgr(u)))
      or (coalesce(st,'draft') = 'submitted' and ebda.pay2_is_mgr(u)) end $$;

create or replace function ebda.pay2_users_of(sid text, k text) returns setof ebda.users language sql stable as $$
  select * from ebda.users x where coalesce(x.active,'نعم') not like '%لا%' and ebda.can_school(x, sid) and (
    (k = 'entry' and ebda.rk(x) = 'custody_officer') or (k = 'mgr' and ebda.rk(x) = 'direct_manager') or (k = 'fin' and ebda.rk(x) = 'finance_manager')) $$;
create or replace function ebda.pay2_notify(sid text, p text, flow text, kind text, uids text[], title text, body text, from_name text) returns int language plpgsql as $$
declare n int := 0; x text;
begin
  foreach x in array coalesce(uids, '{}') loop
    if x is null or x = '' then continue; end if;
    insert into ebda.pay2_notices(id, user_id, kind, school_id, period, flow_id, title, body, from_name, created_at)
    values(ebda.uid(), x, kind, sid, p, flow, title, body, from_name, now()::text);
    n := n + 1;
  end loop;
  return n;
end $$;

-- سجل الخصومات المعتمدة من بيانات الشهر: القاعدة المفعّلة (إن وُجدت) أو قيم المدير المالى كما أدخلها
create or replace function ebda.pay2_book_deductions(u ebda.users, sid text, p text, ver int) returns int language plpgsql as $$
declare r record; rule jsonb := coalesce((select value::jsonb from ebda.config where key = 'pay2_deduct_rule'), '{}'::jsonb); n int := 0;
  en boolean := coalesce((rule->>'enabled')::boolean, false); db numeric := nullif(rule->>'day_basis','')::numeric; hp numeric := nullif(rule->>'hours_per_day','')::numeric;
  net numeric; dr numeric; hr numeric; da numeric; ha numeric;
begin
  update ebda.pay2_deductions set status = 'reversed', reversed_by = u.name, reversed_at = now()::text, reversed_reason = 'اعتماد جديد للشهر (الإصدار ' || ver || ')'
   where school_id = sid and period = p and status = 'active';
  for r in select s.id, s.emp_uid, s.name, ebda.pay2_view(s, p) v, e.hour_deduct, e.day_deduct, e.net_after, e.cost_after, e.summary
             from ebda.pay2_staff s join ebda.pay2_effects e on e.staff_id = s.id and e.period = p where s.school_id = sid loop
    net := nullif(r.v->>'net_salary','')::numeric;
    if coalesce(r.hour_deduct,0) = 0 and coalesce(r.day_deduct,0) = 0 and (r.net_after is null or net is null or r.net_after = net) then continue; end if;
    if en and db > 0 and net is not null then
      dr := round(net / db, 4); hr := case when hp > 0 then round(dr / hp, 4) end;
      da := round(coalesce(r.day_deduct,0) * dr, 2); ha := case when hr is not null then round(coalesce(r.hour_deduct,0) * hr, 2) end;
      if coalesce(r.day_deduct,0) <> 0 then
        insert into ebda.pay2_deductions values(ebda.uid(), sid, p, r.id, r.emp_uid, r.name, 'day', r.day_deduct, dr, 'القاعدة المعتمدة: صافى الراتب ÷ ' || db || ' × عدد الأيام', da,
          net, r.net_after, nullif(r.v->>'total_cost','')::numeric, r.cost_after, ver, 'active', u.name, now()::text); n := n + 1; end if;
      if coalesce(r.hour_deduct,0) <> 0 and ha is not null then
        insert into ebda.pay2_deductions values(ebda.uid(), sid, p, r.id, r.emp_uid, r.name, 'hour', r.hour_deduct, hr, 'القاعدة المعتمدة: (صافى الراتب ÷ ' || db || ') ÷ ' || hp || ' × عدد الساعات', ha,
          net, r.net_after, nullif(r.v->>'total_cost','')::numeric, r.cost_after, ver, 'active', u.name, now()::text); n := n + 1; end if;
    else
      if coalesce(r.day_deduct,0) <> 0 then
        insert into ebda.pay2_deductions values(ebda.uid(), sid, p, r.id, r.emp_uid, r.name, 'day', r.day_deduct, null, 'كما أدخلها المدير المالى (لا توجد قاعدة احتساب مفعّلة)', null,
          net, r.net_after, nullif(r.v->>'total_cost','')::numeric, r.cost_after, ver, 'active', u.name, now()::text); n := n + 1; end if;
      if coalesce(r.hour_deduct,0) <> 0 then
        insert into ebda.pay2_deductions values(ebda.uid(), sid, p, r.id, r.emp_uid, r.name, 'hour', r.hour_deduct, null, 'كما أدخلها المدير المالى (لا توجد قاعدة احتساب مفعّلة)', null,
          net, r.net_after, nullif(r.v->>'total_cost','')::numeric, r.cost_after, ver, 'active', u.name, now()::text); n := n + 1; end if;
    end if;
    if net is not null and r.net_after is not null and r.net_after <> net then
      insert into ebda.pay2_deductions values(ebda.uid(), sid, p, r.id, r.emp_uid, r.name, 'total', null, null, 'صافى الراتب التعاقدي − الراتب الصافى بعد الخصومات', round(net - r.net_after, 2),
        net, r.net_after, nullif(r.v->>'total_cost','')::numeric, r.cost_after, ver, 'active', u.name, now()::text); n := n + 1; end if;
  end loop;
  return n;
end $$;

-- خطوة فى دورة الشهر: submit · mgr_approve · send_finance (CC) · fin_approve · return · reopen
create or replace function ebda.pay2_flow_step(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pf$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); step text := coalesce(req->>'step','');
  sh ebda.pay2_sheets; ns text; nt text := btrim(coalesce(req->>'note','')); fid text := ebda.uid(); cc text[] := '{}'; bad text; nn int := 0; nd int := 0;
  sch text; ttl text; ver int; x text; stg text;
begin
  if p !~ '^\d{4}-(0[1-9]|1[0-2])$' then return ebda.err('اختر الشهر'); end if;
  if not ebda.pay2_view_ok(u, sid) or ebda.rk(u) = 'observer' then return ebda.err('لا صلاحية على رواتب هذه الجهة'); end if;
  sh := ebda.pay2_sheet(sid, p);
  select * into sh from ebda.pay2_sheets where id = sh.id for update;
  sch := (select name from ebda.schools where id = sid);
  ttl := 'مؤثرات رواتب ' || coalesce(sch,'') || ' — ' || p;
  if coalesce(req->>'expect','') <> '' and coalesce(sh.status,'draft') <> req->>'expect' then
    return ebda.err('تغيّرت حالة الشهر (' || ebda.pay2_status_label(sh.status) || ') — حدّث الصفحة'); end if;   -- منع التنفيذ المكرر
  if step = 'submit' then
    if not ebda.pay2_is_entry(u) then return ebda.err('الإرسال للمراجعة لمسئول العهدة (المشرف التنفيذى)'); end if;
    if coalesce(sh.status,'draft') not in ('draft','returned') then return ebda.err('الشهر ليس فى مرحلة الإدخال (' || ebda.pay2_status_label(sh.status) || ')'); end if;
    if not exists(select 1 from ebda.pay2_effects e where e.school_id = sid and e.period = p) then return ebda.err('لا توجد مؤثرات مسجلة لهذا الشهر'); end if;
    ns := 'submitted';
    update ebda.pay2_sheets set status = ns, submitted_by = u.name, submitted_at = now()::text where id = sh.id;
    nn := ebda.pay2_notify(sid, p, fid, 'action', array(select id from ebda.pay2_users_of(sid, 'mgr')), ttl, 'أُرسلت المؤثرات للمراجعة والاعتماد' || coalesce(' — ' || nullif(nt,''),''), u.name);
  elsif step = 'mgr_approve' then
    if not ebda.pay2_is_mgr(u) then return ebda.err('اعتماد البيانات التشغيلية للمدير المباشر'); end if;
    if coalesce(sh.status,'draft') <> 'submitted' then return ebda.err('يُعتمد الشهر بعد إرساله من مسئول العهدة (' || ebda.pay2_status_label(sh.status) || ')'); end if;
    ns := 'mgr_approved';
    update ebda.pay2_sheets set status = ns, mgr_by = u.name, mgr_at = now()::text where id = sh.id;
  elsif step = 'send_finance' then
    if not ebda.pay2_is_mgr(u) then return ebda.err('الإرسال للمدير المالى للمدير المباشر'); end if;
    if coalesce(sh.status,'draft') <> 'mgr_approved' then return ebda.err('يُرسل الشهر للمدير المالى بعد اعتماد المدير المباشر'); end if;
    for x in select jsonb_array_elements_text(coalesce(req->'cc','[]'::jsonb)) loop
      if x = u.id or x = any(cc) then continue; end if;
      select coalesce(name, x) into bad from ebda.users where id = x;
      if not exists(select 1 from ebda.users w where w.id = x and coalesce(w.active,'نعم') not like '%لا%' and ebda.pay2_view_ok(w, sid)) then
        return ebda.err('المستلم «' || coalesce(bad, x) || '» غير مصرح له بالاطلاع على رواتب هذه الجهة — لا يُضاف فى CC'); end if;
      cc := cc || x;
    end loop;
    ns := 'sent_finance';
    update ebda.pay2_sheets set status = ns, sent_by = u.name, sent_at = now()::text where id = sh.id;
    nn := ebda.pay2_notify(sid, p, fid, 'action', array(select id from ebda.pay2_users_of(sid, 'fin')), coalesce(nullif(btrim(req->>'subject'),''), ttl),
            'بانتظار مراجعة المؤثرات وتحديد الخصومات والاعتماد المالى' || coalesce(' — ' || nullif(nt,''),''), u.name);
    nn := nn + ebda.pay2_notify(sid, p, fid, 'cc', cc, coalesce(nullif(btrim(req->>'subject'),''), ttl), 'للعلم (CC) — ' || coalesce(nullif(nt,''), 'أُرسلت المؤثرات للمدير المالى'), u.name);
  elsif step = 'fin_approve' then
    if not ebda.pay2_is_fin(u) then return ebda.err('الاعتماد المالى للمدير المالى (أو بصلاحية «payroll.fin_approve»)'); end if;
    if coalesce(sh.status,'draft') <> 'sent_finance' then return ebda.err('يُعتمد مالياً بعد إرسال المدير المباشر (' || ebda.pay2_status_label(sh.status) || ')'); end if;
    if exists(select 1 from ebda.pay2_effects e where e.school_id = sid and e.period = p and e.work_days_fin is not null and e.work_days is not null
                and e.work_days_fin <> e.work_days and coalesce(btrim(e.work_days_reason),'') = '') then
      return ebda.err('يوجد موظف عُدّل «عدد أيام العمل المعتمد» له دون سبب — سجّل سبب الاختلاف قبل الاعتماد المالى'); end if;
    ver := coalesce(sh.version,0) + 1;
    -- نسخة البيانات والملاحظات التى بُنى عليها القرار المالى (لا تتغيّر بتعديل لاحق)
    update ebda.pay2_effects e set approved_snap = jsonb_build_object('version', ver, 'at', now()::text, 'by', u.name, 'work_days', e.work_days, 'work_days_fin', e.work_days_fin,
        'work_days_reason', e.work_days_reason, 'notes_custody', e.notes2, 'notes_t', e.notes1, 'fin_notes', e.fin_notes, 'summary', e.summary,
        'annual_days', e.annual_days, 'casual_days', e.casual_days, 'sick_days', e.sick_days, 'absent_days', e.absent_days, 'perm_count', e.perm_count,
        'hour_deduct', e.hour_deduct, 'day_deduct', e.day_deduct, 'net_after', e.net_after, 'cost_after', e.cost_after)
     where e.school_id = sid and e.period = p;
    nd := ebda.pay2_book_deductions(u, sid, p, ver);
    ns := 'fin_approved';
    update ebda.pay2_sheets set status = ns, fin_by = u.name, fin_at = now()::text, fin_note = nt, version = ver, approved_by = u.name, approved_at = now()::text where id = sh.id;
    nn := ebda.pay2_notify(sid, p, fid, 'info', array(select id from ebda.pay2_users_of(sid, 'mgr') union select id from ebda.pay2_users_of(sid, 'entry')), ttl,
            'اعتمد المدير المالى النتائج المالية للشهر' || coalesce(' — ' || nullif(nt,''),''), u.name);
  elsif step = 'return' then
    if length(nt) < 3 then return ebda.err('اكتب سبب الإعادة للتعديل'); end if;
    if coalesce(sh.status,'draft') in ('submitted','mgr_approved') then
      if not ebda.pay2_is_mgr(u) then return ebda.err('الإعادة فى هذه المرحلة للمدير المباشر'); end if; stg := 'manager';
    elsif coalesce(sh.status,'draft') = 'sent_finance' then
      if not (ebda.pay2_is_fin(u) or ebda.rk(u) = 'admin') then return ebda.err('الإعادة فى هذه المرحلة للمدير المالى'); end if; stg := 'finance';
    else return ebda.err('لا يمكن الإعادة من الحالة الحالية (' || ebda.pay2_status_label(sh.status) || ')'); end if;
    ns := 'returned';
    update ebda.pay2_sheets set status = ns, returned_by = u.name, returned_at = now()::text, returned_reason = nt, returned_stage = stg where id = sh.id;
    nn := ebda.pay2_notify(sid, p, fid, 'action', array(select id from ebda.pay2_users_of(sid, 'entry') union select id from ebda.pay2_users_of(sid, 'mgr')), ttl,
            'أُعيد الشهر للتعديل — ' || nt, u.name);
  elsif step = 'reopen' then
    if ebda.rk(u) <> 'admin' then return ebda.err('إعادة فتح شهر معتمد مالياً للأدمن فقط'); end if;
    if coalesce(sh.status,'draft') <> 'fin_approved' then return ebda.err('الشهر غير معتمد مالياً'); end if;
    if length(nt) < 5 then return ebda.err('اكتب سبب إعادة الفتح'); end if;
    update ebda.pay2_deductions set status = 'reversed', reversed_by = u.name, reversed_at = now()::text, reversed_reason = 'إعادة فتح: ' || nt
     where school_id = sid and period = p and status = 'active';
    ns := 'returned';
    update ebda.pay2_sheets set status = ns, returned_by = u.name, returned_at = now()::text, returned_reason = 'إعادة فتح: ' || nt, returned_stage = 'admin' where id = sh.id;
    nn := ebda.pay2_notify(sid, p, fid, 'action', array(select id from ebda.pay2_users_of(sid, 'entry') union select id from ebda.pay2_users_of(sid, 'mgr') union select id from ebda.pay2_users_of(sid, 'fin')), ttl,
            'أعاد الأدمن فتح الشهر المعتمد — ' || nt, u.name);
  else return ebda.err('إجراء غير معروف'); end if;
  insert into ebda.pay2_flow(id, school_id, period, step, from_status, to_status, note, subject, cc, attachments, by_name, by_id, by_role, at)
  values(fid, sid, p, step, coalesce(sh.status,'draft'), ns, nt, coalesce(req->>'subject',''),
         coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name)) from ebda.users w where w.id = any(cc)), '[]'::jsonb),
         case when jsonb_typeof(req->'attachments') = 'array' then req->'attachments' else '[]'::jsonb end, u.name, u.id, ebda.rk(u), now()::text);
  insert into ebda.pay2_log values(ebda.uid(), sid, p, '', '_status', coalesce(sh.status,'draft'), ns || case when nt <> '' then ' — ' || nt else '' end, 'status', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true, 'status', ns, 'label', ebda.pay2_status_label(ns), 'notified', nn, 'deductions', nd);
end $pf$;

-- توافق: pay2Status القديم يُحوَّل للدورة الجديدة
create or replace function ebda.pay2_status(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pst$
begin
  return ebda.pay2_flow_step(u, req || jsonb_build_object('step', case coalesce(req->>'status','')
    when 'submitted' then 'submit' when 'mgr_approved' then 'mgr_approve' when 'sent_finance' then 'send_finance' when 'fin_approved' then 'fin_approve'
    when 'approved' then 'fin_approve' when 'returned' then 'return' when 'draft' then case when (select status from ebda.pay2_sheets where school_id = req->>'school_id' and period = req->>'period') = 'fin_approved' then 'reopen' else 'return' end
    else coalesce(req->>'step','') end));
end $pst$;

create or replace function ebda.pay2_flow_info(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $pfi$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period','');
begin
  if not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية'); end if;
  return jsonb_build_object('ok', true,
    'flow', coalesce((select jsonb_agg(to_jsonb(f) order by f.at desc) from ebda.pay2_flow f where f.school_id = sid and (p = '' or f.period = p)), '[]'::jsonb),
    'deductions', coalesce((select jsonb_agg(to_jsonb(d) order by d.emp_name, d.kind) from ebda.pay2_deductions d where d.school_id = sid and d.period = p), '[]'::jsonb),
    'rule', (select value::jsonb from ebda.config where key = 'pay2_deduct_rule'),
    'leave_rule', coalesce((select value::jsonb from ebda.config where key = 'pay2_leave_rule'), '{"types": ["annual","casual"]}'::jsonb),
    'cc_candidates', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'role', ebda.rk(w)) order by w.name) from ebda.users w
                                where w.id <> u.id and coalesce(w.active,'نعم') not like '%لا%' and ebda.rk(w) <> 'observer' and ebda.pay2_view_ok(w, sid)), '[]'::jsonb));
end $pfi$;

create or replace function ebda.pay2_rule_set(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $prs$
declare r jsonb := coalesce(req->'rule','{}'::jsonb); old text;
begin
  if not (ebda.rk(u) = 'admin' or ebda.pay2_is_fin(u)) then return ebda.err('قاعدة احتساب الخصومات للمدير المالى أو الأدمن'); end if;
  if coalesce((r->>'enabled')::boolean, false) and (coalesce(r->>'day_basis','') !~ '^[0-9]+(\.[0-9]+)?$' or (r->>'day_basis')::numeric <= 0) then
    return ebda.err('حدّد أساس اليوم (عدد أيام الشهر للقسمة) قبل تفعيل القاعدة'); end if;
  if coalesce(r->>'hours_per_day','') <> '' and r->>'hours_per_day' !~ '^[0-9]+(\.[0-9]+)?$' then return ebda.err('عدد ساعات اليوم غير صحيح'); end if;
  if jsonb_typeof(req->'leave_types') = 'array' then
    if exists(select 1 from jsonb_array_elements_text(req->'leave_types') x where x not in ('annual','casual','sick','absent')) then return ebda.err('نوع إجازة غير معروف'); end if;
    insert into ebda.pay2_log values(ebda.uid(), '', '', '', '_leave_rule', (select value from ebda.config where key = 'pay2_leave_rule'),
      jsonb_build_object('types', req->'leave_types')::text, 'rule', u.name, u.id, ebda.rk(u), now()::text);
    update ebda.config set value = jsonb_build_object('types', req->'leave_types', 'by', u.name, 'at', now()::text)::text where key = 'pay2_leave_rule';
    if req->'rule' is null then return jsonb_build_object('ok', true, 'leave_rule', (select value::jsonb from ebda.config where key = 'pay2_leave_rule')); end if;
  end if;
  select value into old from ebda.config where key = 'pay2_deduct_rule';
  update ebda.config set value = jsonb_build_object('enabled', coalesce((r->>'enabled')::boolean, false), 'day_basis', coalesce(r->>'day_basis',''),
      'hours_per_day', coalesce(r->>'hours_per_day',''), 'note', coalesce(r->>'note',''), 'by', u.name, 'at', now()::text)::text where key = 'pay2_deduct_rule';
  insert into ebda.pay2_log values(ebda.uid(), '', '', '', '_rule', old, (select value from ebda.config where key = 'pay2_deduct_rule'), 'rule', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true, 'rule', (select value::jsonb from ebda.config where key = 'pay2_deduct_rule'));
end $prs$;

create or replace function ebda.pay2_notices_list(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pn$
begin
  if coalesce(req->>'mark','') = 'read' then
    update ebda.pay2_notices set read_at = now()::text where user_id = u.id and read_at = '' and (coalesce(req->>'id','') = '' or id = req->>'id');
  end if;
  return jsonb_build_object('ok', true, 'unread', (select count(*) from ebda.pay2_notices where user_id = u.id and read_at = ''),
    'rows', coalesce((select jsonb_agg(to_jsonb(n) || jsonb_build_object('school', (select name from ebda.schools where id = n.school_id)) order by n.created_at desc)
                      from (select * from ebda.pay2_notices where user_id = u.id order by created_at desc limit 100) n), '[]'::jsonb));
end $pn$;

-- حمل الشهر: كما كان + الدورة والمالك والإجراءات المتاحة + المؤثرات المعدَّلة فقط فى مرحلتها
create or replace function ebda.pay2_load(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pl$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); s ebda.pay2_sheets; st text; mf jsonb;
begin
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  if not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية على رواتب هذه الجهة'); end if;
  select * into s from ebda.pay2_sheets where school_id = sid and period = p;
  st := coalesce(s.status, 'draft');
  mf := case when ebda.rk(u) = 'observer' or ebda.fy_closed_label_on(p || '-01') is not null then '[]'::jsonb
        else coalesce((select jsonb_agg(f->>0) from jsonb_array_elements(ebda.pay2_fields()) f where ebda.pay2_field_ok(u, f->>0) and ebda.pay2_edit_ok(u, f->>0, f->>2, st, p)), '[]'::jsonb) end;
  return jsonb_build_object('ok', true, 'school_id', sid, 'period', p, 'fy', ebda.pay2_fy(p), 'fy_closed', ebda.fy_closed_label_on(p || '-01') is not null,
    'status', st, 'status_label', ebda.pay2_status_label(st), 'owner', ebda.pay2_owner(st), 'sheet', to_jsonb(s), 'fields', ebda.pay2_fields(), 'db_ver', 18, 'lock', ebda.pay2_lock_info(u, st, p), 'budget_items', ebda.pay2_budget_items(), 'my_fields', mf,
    'can_submit', ebda.pay2_is_entry(u) and st in ('draft','returned'), 'can_mgr', ebda.pay2_is_mgr(u) and st in ('submitted','mgr_approved'),
    'can_fin', ebda.pay2_is_fin(u) and st = 'sent_finance', 'can_return', (ebda.pay2_is_mgr(u) and st in ('submitted','mgr_approved')) or ((ebda.pay2_is_fin(u) or ebda.rk(u) = 'admin') and st = 'sent_finance'),
    'can_reopen', ebda.rk(u) = 'admin' and st = 'fin_approved', 'can_rule', ebda.rk(u) = 'admin' or ebda.pay2_is_fin(u),
    'can_review', false, 'can_approve', false,
    'can_import', ebda.rk(u) <> 'observer' and (ebda.rk(u) = 'admin' or ebda.can(u,'payroll.import')) and st in ('draft','returned'),
    'can_delete', ebda.pay2_can_delete(u), 'can_replace', ebda.pay2_can_replace(u),
    'last_import', (select jsonb_build_object('at', i.at, 'by', i.by_name, 'file', i.file, 'mode', i.mode, 'action', i.action) from ebda.pay2_imports i
                    where i.school_id = sid and i.period = p and coalesce(i.action,'') not in ('failed','delete') order by i.at desc limit 1),
    'records', (select count(*) from ebda.pay2_effects e where e.school_id = sid and e.period = p),
    'deductions_total', (select coalesce(sum(amount),0) from ebda.pay2_deductions d where d.school_id = sid and d.period = p and d.status = 'active' and d.kind = 'total'),
    'unread', (select count(*) from ebda.pay2_notices where user_id = u.id and read_at = ''),
    'rows', coalesce((select jsonb_agg(ebda.pay2_row(x, p) || jsonb_build_object('emp_uid', x.emp_uid) order by x.sort, x.created_at, x.name) from ebda.pay2_staff x
                      where x.school_id = sid and x.fy = ebda.pay2_fy(p) and coalesce(x.active,'نعم') = 'نعم'), '[]'::jsonb),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('file', i.file, 'sheet', i.sheet, 'by', i.by_name, 'at', i.at, 'added', i.added, 'updated', i.updated,
                      'unchanged', i.unchanged, 'rejected', i.rejected) order by i.at desc) from ebda.pay2_imports i where i.school_id = sid and i.period = p), '[]'::jsonb));
end $pl$;

-- التراكمى: كل موظف × أشهر العام المالى (يوليو ← يونيو) — الإجماليات من الأشهر المعتمدة مالياً فقط، وما تحت المراجعة منفصل
create or replace function ebda.pay2_cumulative(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $pc$
declare sid text := coalesce(req->>'school_id',''); v_fy text := coalesce(req->>'fy',''); y0 int;
begin
  if v_fy !~ '^\d{4}-\d{4}$' then return ebda.err('اختر العام المالى'); end if;
  if not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية'); end if;
  y0 := left(v_fy,4)::int;
  return jsonb_build_object('ok', true, 'fy', v_fy, 'school', (select name from ebda.schools where id = sid), 'generated_at', now()::text, 'by', u.name,
    'months', (select jsonb_agg(jsonb_build_object('period', m, 'status', coalesce(h.status,'draft'), 'label', ebda.pay2_status_label(coalesce(h.status,'draft')),
                 'records', (select count(*) from ebda.pay2_effects e where e.school_id = sid and e.period = m), 'fin_at', h.fin_at, 'fin_by', h.fin_by) order by o)
               from (select to_char(make_date(y0, 7, 1) + make_interval(months => g), 'YYYY-MM') m, g o from generate_series(0, 11) g) mm
               left join ebda.pay2_sheets h on h.school_id = sid and h.period = mm.m),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'emp_uid', s.emp_uid, 'code', s.code, 'name', s.name, 'job', s.job, 'active', s.active,
        'net_salary', s.net_salary, 'leave_balance', s.leave_balance, 'months_used', s.months,
        'remaining', case when s.leave_balance is null then null else s.leave_balance - coalesce((select sum(nullif(x.val,'')::numeric) from jsonb_each_text(coalesce(s.months,'{}'::jsonb)) x(k, val)
                       where x.k ~ '^m\d\d$' and x.val ~ '^-?[0-9]+(\.[0-9]+)?$'), 0) end,
        'by_month', coalesce((select jsonb_object_agg(e.period, jsonb_build_object('work_days', e.work_days, 'annual_days', e.annual_days, 'casual_days', e.casual_days,
              'sick_days', e.sick_days, 'absent_days', e.absent_days, 'perm_count', e.perm_count, 'hour_deduct', e.hour_deduct, 'day_deduct', e.day_deduct,
              'net_after', e.net_after, 'cost_after', e.cost_after, 'summary', e.summary, 'notes1', e.notes1, 'notes2', e.notes2,
              'work_days_fin', e.work_days_fin, 'work_days_reason', e.work_days_reason, 'work_days_fin_by', e.work_days_fin_by, 'fin_notes', e.fin_notes,
              'leave_month', nullif(ebda.pay2_view(s, e.period)->>('m' || substr(e.period, 6, 2)), ''), 'leave_month_calc', nullif(ebda.pay2_view(s, e.period)->>('m' || substr(e.period, 6, 2) || 'a'), ''),
              'annual_detail', e.annual_detail, 'casual_detail', e.casual_detail, 'sick_detail', e.sick_detail, 'absent_detail', e.absent_detail, 'perm_detail', e.perm_detail,
              'net_salary', nullif(ebda.pay2_view(s, e.period)->>'net_salary','')::numeric, 'total_cost', nullif(ebda.pay2_view(s, e.period)->>'total_cost','')::numeric,
              'deduction', (select sum(d.amount) from ebda.pay2_deductions d where d.staff_id = s.id and d.period = e.period and d.status = 'active' and d.kind = 'total'),
              'status', coalesce((select h.status from ebda.pay2_sheets h where h.school_id = sid and h.period = e.period), 'draft')))
            from ebda.pay2_effects e where e.staff_id = s.id), '{}'::jsonb)) order by s.sort, s.name)
      from ebda.pay2_staff s where s.school_id = sid and s.fy = v_fy), '[]'::jsonb));
end $pc$;

-- لوحة متابعة الدورة لكل الجهات المسموح بها فى عام مالى (للتقارير: لم يُعتمد · بانتظار المالى · المعاد وأسبابه · سجل الإرسال و CC)
create or replace function ebda.pay2_board(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $pb$
declare v_fy text := coalesce(req->>'fy',''); y0 int;
begin
  if v_fy !~ '^\d{4}-\d{4}$' then return ebda.err('اختر العام المالى'); end if;
  y0 := left(v_fy,4)::int;
  return jsonb_build_object('ok', true, 'fy', v_fy, 'generated_at', now()::text, 'by', u.name,
    'sheets', coalesce((select jsonb_agg(jsonb_build_object('school_id', z.id, 'school', z.name, 'period', m.m, 'status', coalesce(h.status,'draft'),
        'label', ebda.pay2_status_label(coalesce(h.status,'draft')), 'owner', ebda.pay2_owner(coalesce(h.status,'draft')),
        'records', (select count(*) from ebda.pay2_effects e where e.school_id = z.id and e.period = m.m),
        'staff', (select count(*) from ebda.pay2_staff s where s.school_id = z.id and s.fy = v_fy and coalesce(s.active,'نعم') = 'نعم'),
        'missing', (select count(*) from ebda.pay2_staff s where s.school_id = z.id and s.fy = v_fy and coalesce(s.active,'نعم') = 'نعم'
                      and not exists(select 1 from ebda.pay2_effects e where e.staff_id = s.id and e.period = m.m and e.work_days is not null)),
        'submitted_by', h.submitted_by, 'submitted_at', h.submitted_at, 'mgr_by', h.mgr_by, 'mgr_at', h.mgr_at, 'sent_by', h.sent_by, 'sent_at', h.sent_at,
        'fin_by', h.fin_by, 'fin_at', h.fin_at, 'returned_by', h.returned_by, 'returned_at', h.returned_at, 'returned_reason', h.returned_reason, 'returned_stage', h.returned_stage,
        'deductions', (select coalesce(sum(d.amount),0) from ebda.pay2_deductions d where d.school_id = z.id and d.period = m.m and d.status = 'active' and d.kind = 'total'))
        order by z.name, m.m)
      from ebda.schools z cross join (select to_char(make_date(y0, 7, 1) + make_interval(months => g), 'YYYY-MM') m from generate_series(0, 11) g) m
      left join ebda.pay2_sheets h on h.school_id = z.id and h.period = m.m
      where ebda.pay2_view_ok(u, z.id) and coalesce(z.cancelled_at,'') = ''
        and (exists(select 1 from ebda.pay2_staff s where s.school_id = z.id and s.fy = v_fy) or h.id is not null)), '[]'::jsonb),
    'flow', coalesce((select jsonb_agg(to_jsonb(f) || jsonb_build_object('school', (select name from ebda.schools where id = f.school_id)) order by f.at desc)
      from ebda.pay2_flow f where ebda.pay2_view_ok(u, f.school_id) and ebda.pay2_fy(f.period) = v_fy), '[]'::jsonb),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('flow_id', n.flow_id, 'user', (select name from ebda.users where id = n.user_id), 'kind', n.kind,
       'created_at', n.created_at, 'read_at', n.read_at)) from ebda.pay2_notices n where ebda.pay2_view_ok(u, n.school_id) and ebda.pay2_fy(n.period) = v_fy), '[]'::jsonb),
    'deductions', coalesce((select jsonb_agg(to_jsonb(d) || jsonb_build_object('school', (select name from ebda.schools where id = d.school_id)) order by d.period, d.emp_name)
      from ebda.pay2_deductions d where ebda.pay2_view_ok(u, d.school_id) and ebda.pay2_fy(d.period) = v_fy), '[]'::jsonb));
end $pb$;

-- المدير المباشر يرى مؤثرات رواتب جهاته فقط (للمراجعة والاعتماد) — دون الرواتب القديمة أو بيانات أخرى
create or replace function ebda.pay2_view_ok(u ebda.users, sid text) returns boolean language sql stable as $$
  select ebda.can_school(u, sid) and (ebda.rk(u) in ('admin','finance_manager','observer','direct_manager') or ebda.can(u,'payroll.view'))
$$;
-- صلاحيات الأدوار: المدير المباشر يرى رواتب جهاته ويعتمد التشغيلى · مسئول العهدة بلا «اعتماد رواتب الشهر» (الاعتماد المالى للمدير المالى)
create or replace function ebda.perm_defaults(rk text) returns text[] language sql immutable as $$
  select case rk
    when 'admin' then array['budget.edit','custody.create','custody.approve','expense.record','expense.approve','expense.fin_approve',
                            'request.approve','request.fin_approve','payroll.view','payroll.import','payroll.approve','manage_users','expense.import',
                            'settings.fiscal','custody.rename','lines.manage','request.create','request.mail','records.cancel','payroll.manage','custody.import','gm.approve','audit.view','settings.view','custody.amount_edit','payroll.base',
                            'fy.close','fy.reopen','payroll.mgr_approve','payroll.submit']
    when 'finance_manager' then array['custody.create','custody.approve','expense.fin_approve','request.fin_approve',
                            'payroll.view','payroll.import','payroll.approve','expense.import','custody.rename','request.mail','fin.signoff','custody.amount_edit','payroll.fin_approve']
    when 'direct_manager' then array['expense.approve','request.approve','request.mail','payroll.mgr_approve']
    when 'custody_officer' then array['expense.record','request.create','request.mail',
                            'expense.import','custody.import',
                            'payroll.view','payroll.import','payroll.approve','payroll.manage','payroll.submit']
    else array[]::text[] end
$$;

-- غلاف الـ API: رسالة واضحة عند محاولة تعديل عام مغلق (والعملية كلها تُلغى)
create or replace function ebda.api(req jsonb)
returns jsonb language plpgsql security definer set search_path = ebda as $w$
declare
  action text := req->>'action';
  tok text := req#>>'{auth,token}';
  th text; sess ebda.sessions; res jsonb;
  idle int := coalesce(nullif((select value from ebda.config where key='session_idle_hours'),'')::int, 12);
  maxd int := coalesce(nullif((select value from ebda.config where key='session_max_days'),'')::int, 7);
begin
  perform set_config('ebda.auth_uid', '', true);
  perform set_config('ebda.session_hash', '', true);
  perform set_config('ebda.fy_override', '', true);
  if action = 'login' then
    res := ebda.api_core(req);
    if res ? 'ok' then
      tok := encode(extensions.gen_random_bytes(32), 'hex');
      insert into ebda.sessions(id, token_hash, user_id, created_at, last_seen, expires_at, user_agent)
      values (ebda.uid(), encode(extensions.digest(tok, 'sha256'), 'hex'), res#>>'{user,id}', now(), now(),
              now() + make_interval(days => maxd), left(coalesce(req->>'ua',''), 200));
      delete from ebda.sessions where expires_at < now() or last_seen < now() - make_interval(hours => idle);
      res := res || jsonb_build_object('token', tok, 'session_idle_hours', idle);
    end if;
    return res;
  end if;
  if coalesce(tok,'') <> '' then
    th := encode(extensions.digest(tok, 'sha256'), 'hex');
    if action = 'logout' then delete from ebda.sessions where token_hash = th; return jsonb_build_object('ok', true); end if;
    select * into sess from ebda.sessions
     where token_hash = th and expires_at > now() and last_seen > now() - make_interval(hours => idle);
    if not found then return ebda.err('انتهت الجلسة — سجّل الدخول من جديد'); end if;
    if sess.last_seen < now() - interval '60 seconds' then
      update ebda.sessions set last_seen = now() where id = sess.id;
    end if;
    perform set_config('ebda.auth_uid', sess.user_id, true);
    perform set_config('ebda.session_hash', th, true);
    req := req - 'auth';
  elsif action = 'logout' then
    return jsonb_build_object('ok', true);
  end if;
  begin
    return ebda.api_core(req);
  exception when sqlstate 'EB001' then
    return ebda.err(sqlerrm);
  end;
end $w$;

create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'custodyLedger','needsTable','priorExpenses','approvalsReport','itemHistory','reviewList','itemDetail','expenseDocs','archivedDoc',
               'custodyAmountInfo','pay2Load','pay2History','pay2Imports','rcData','rcEntities','rcSaved','reqItems','reqDepts','overrunInfo',
               'fyInfo','pay2FlowInfo','pay2Cumulative','pay2Board') $$;

-- بيانات التحميل: الأعوام المالية بحالتها (مفتوح/مغلق) ومن أغلقها
create or replace function ebda.bootstrap_v11(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select ebda.bootstrap_v10(u) || jsonb_build_object('fiscal_years', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'label', f.label,
      'start_date', f.start_date::text, 'end_date', f.end_date::text, 'is_current', f.is_current, 'note', f.note, 'updated_at', f.updated_at, 'updated_by', f.updated_by,
      'status', coalesce(f.status,'open'), 'closed_at', f.closed_at, 'closed_by', f.closed_by, 'close_note', f.close_note) order by f.start_date) from ebda.fiscal_years f), '[]'::jsonb))
$$;

-- ============================================================================================================================
--  v11.1: شيت المؤثرات الديناميكى — تجميع أيام الإجازات فى عمود الشهر (الجانب الأيمن) وتحديث الرصيد · نقل ملاحظات المؤثرات (AE)
--         إلى ملاحظات المدير المالى (T) مع حقل مستقل لقرار المالى · عدد أيام العمل المعتمد من المدير المالى (بالقيمتين والسبب والمستخدم والتاريخ)
-- ============================================================================================================================
alter table ebda.pay2_effects add column if not exists work_days_fin numeric;
alter table ebda.pay2_effects add column if not exists work_days_reason text default '';
alter table ebda.pay2_effects add column if not exists work_days_fin_by text default '';
alter table ebda.pay2_effects add column if not exists work_days_fin_at text default '';
alter table ebda.pay2_effects add column if not exists fin_notes text default '';
alter table ebda.pay2_effects add column if not exists approved_snap jsonb;
-- أنواع الإجازات التى تُخصم من رصيد الأجازات (قابلة للتعديل من المدير المالى/الأدمن): الاعتيادى والعارضة (العارضة من الرصيد السنوى بنص قانون العمل)
-- المرضى والغياب بدون إذن لا تُخصم من الرصيد؛ الغياب يُعرض منفصلاً للمعالجة المالية
insert into ebda.config(key, value) values('pay2_leave_rule', '{"types": ["annual", "casual"]}') on conflict (key) do nothing;

create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  select '[
   ["code","Code","base","text","staff"],["ins_status","الحالة التأمينية","base","text","staff"],["name","الاسم","base","text","staff"],
   ["job","الوظيفة","base","text","staff"],["mobile","رقم الموبيل","base","text","staff"],["ins_no","الرقم التأمينى","base","text","staff"],
   ["national_id","الرقم القومى","base","text","staff"],["bank_account","الحساب البنكى","base","text","staff"],["bank_name","اسم البنك","base","text","staff"],
   ["hire_date","تاريخ التعيين","base","date","staff"],["net_salary","صافى الراتب التعاقدي\nNet salary","base","num","staff"],
   ["gross_salary","إجمالي الراتب\nGross salary","base","num","staff"],["total_cost","إجمالي تكلفة الموظف على الشركة","base","num","staff"],
   ["work_days","عدد ايام العمل","entry","num","month"],["summary","ملخص المؤثرات","finance","text","month"],["hour_deduct","خصم ساعة","finance","num","month"],
   ["day_deduct","خصم يوم","finance","num","month"],["net_after","الراتب الصافى بعد الخصومات","finance","num","month"],
   ["cost_after","إجمالى تكلفة الموظف بعد الخصومات","finance","num","month"],["notes1","ملاحظات","finance","text","month"],
   ["annual_days","الأجازات الإعتيادى — عدد الأيام","entry","num","month"],["annual_detail","الأجازات الإعتيادى — التفصيل","entry","text","month"],
   ["casual_days","الإجازات العارضة — عدد الأيام","entry","num","month"],["casual_detail","الإجازات العارضة — التفصيل","entry","text","month"],
   ["sick_days","الإجازات المرضى — عدد الأيام","entry","num","month"],["sick_detail","الإجازات المرضى — التفصيل","entry","text","month"],
   ["absent_days","غياب بدون إذن — عدد الأيام","entry","num","month"],["absent_detail","غياب بدون إذن — التفصيل","entry","text","month"],
   ["perm_count","الأذونات — عدد الأذونات","entry","num","month"],["perm_detail","الأذونات — التفصيل","entry","text","month"],
   ["notes2","ملاحظات","entry","text","month"],["leave_balance","رصيد الأجازات","base","num","staff"],
   ["m07","شهر يوليو","entry","num","staff"],["m08","شهر أغسطس","entry","num","staff"],["m09","شهر سبتمبر","entry","num","staff"],
   ["m09n","ملاحظات","entry","text","staff",1],
   ["m10","شهر أكتوبر","entry","num","staff"],["m10n","ملاحظات","entry","text","staff",1],["m11","شهر نوفمبر","entry","num","staff"],["m11n","ملاحظات","entry","text","staff",1],
   ["m12","شهر ديسمبر","entry","num","staff"],["m12n","ملاحظات","entry","text","staff",1],["m01","شهر يناير","entry","num","staff"],["m01n","ملاحظات","entry","text","staff",1],
   ["m02","شهر فبراير","entry","num","staff"],["m02n","ملاحظات","entry","text","staff",1],["m03","شهر مارس","entry","num","staff"],["m03n","ملاحظات","entry","text","staff",1],
   ["m04","شهرأبريل","entry","num","staff"],["m04n","ملاحظات","entry","text","staff",1],["m05","شهر مايو","entry","num","staff"],["m05n","ملاحظات","entry","text","staff",1],
   ["m06","شهر يونيو","entry","num","staff"],["m06n","ملاحظات","entry","text","staff",1],
   ["work_days_fin","عدد أيام العمل المعتمد (المدير المالى)","finance","num","month",1],
   ["work_days_reason","سبب تعديل أيام العمل","finance","text","month",1],
   ["fin_notes","ملاحظات وقرار المدير المالى","finance","text","month",1]]'::jsonb
$$;
update ebda.config set value = ((select jsonb_object_agg(f->>0, case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb
                                   else '["custody_officer","direct_manager","finance_manager"]'::jsonb end) from jsonb_array_elements(ebda.pay2_fields()) f) || value::jsonb)::text
 where key = 'pay2_field_rules';

-- مقارنة العناوين: الأعمدة الاختيارية (ملاحظات الأشهر · أعمدة المالى المضافة) لا تُعد ناقصة فى الملفات الأقدم
create or replace function ebda.pay2_header_report(hdrs jsonb) returns jsonb language sql immutable as $$
  with t as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(ebda.pay2_template_headers()) with ordinality a(x, o)),
       f as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(coalesce(hdrs,'[]'::jsonb)) with ordinality a(x, o)),
       m as (select t.h th, t.o tor, f.h fh, f.o fo from t join f on ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm(f.h) and t.k = f.k),
       opt as (select ebda.pay2_hnorm(f->>1) h from jsonb_array_elements(ebda.pay2_fields()) f where coalesce((f->>5)::int, 0) = 1)
  select jsonb_build_object(
    'template', ebda.pay2_template_headers(),
    'matched', (select count(*) from m),
    'missing', coalesce((select jsonb_agg(t.h order by t.o) from t where not exists(select 1 from m where m.tor = t.o)
                           and not (ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm('ملاحظات') and t.k > 2)
                           and not (ebda.pay2_hnorm(t.h) <> ebda.pay2_hnorm('ملاحظات') and ebda.pay2_hnorm(t.h) in (select h from opt))), '[]'::jsonb),
    'optional_missing', (select count(*) from t where not exists(select 1 from m where m.tor = t.o) and (ebda.pay2_hnorm(t.h) in (select h from opt) and (t.k > 2 or ebda.pay2_hnorm(t.h) <> ebda.pay2_hnorm('ملاحظات')))),
    'extra', coalesce((select jsonb_agg(f.h order by f.o) from f where not exists(select 1 from m where m.fo = f.o)), '[]'::jsonb),
    'renamed', coalesce((select jsonb_agg(jsonb_build_array(m.fh, m.th)) from m where btrim(m.fh) <> btrim(m.th)), '[]'::jsonb),
    'order_changed', exists(select 1 from m a join m b on a.tor < b.tor and a.fo > b.fo))
$$;

create or replace function ebda.pay2_leave_types() returns text[] language sql stable as $$
  select coalesce((select array(select jsonb_array_elements_text(value::jsonb->'types')) from ebda.config where key = 'pay2_leave_rule'), array['annual','casual']) $$;
create or replace function ebda.pay2_leave_label(k text) returns text language sql immutable as $$
  select case k when 'annual' then 'اعتيادى' when 'casual' then 'عارضة' when 'sick' then 'مرضى' when 'absent' then 'غياب بدون إذن' else k end $$;

-- بعد كل حفظ/استيراد لسجل موظف فى شهر
create or replace function ebda.pay2_after_save(st_id text, p text, u ebda.users, patch jsonb) returns void language plpgsql security definer set search_path = ebda as $$
declare e ebda.pay2_effects; s ebda.pay2_staff; tps text[] := ebda.pay2_leave_types(); t text; tot numeric := 0; any_ boolean := false; parts text[] := '{}';
  mk text := 'm' || substr(p, 6, 2); old text; v numeric;
begin
  select * into e from ebda.pay2_effects where staff_id = st_id and period = p;
  if not found then return; end if;
  select * into s from ebda.pay2_staff where id = st_id;
  -- (1) أيام العمل المعتمدة من المدير المالى: من عدّل ومتى (القيمة الأصلية لمسئول العهدة تبقى فى «عدد ايام العمل»)
  if patch ? 'work_days_fin' then
    update ebda.pay2_effects set work_days_fin_by = u.name, work_days_fin_at = now()::text where id = e.id;
  end if;
  -- (2) ملاحظات المؤثرات (AE) تُنقل آلياً لملاحظات المدير المالى (T) لنفس الموظف والشهر؛ قرار المالى فى حقله المستقل لا يُستبدل
  if patch ? 'notes2' and coalesce(btrim(e.notes2),'') <> '' and coalesce(e.notes1,'') <> e.notes2 then
    if coalesce(btrim(e.notes1),'') <> '' and coalesce(btrim(e.fin_notes),'') = '' and not exists(
         select 1 from ebda.pay2_log l where l.staff_id = st_id and l.period = p and l.field = 'notes1' and l.source = 'auto' and l.new_value = e.notes1) then
      update ebda.pay2_effects set fin_notes = e.notes1 where id = e.id;   -- نص كتبه المالى فى T من قبل: يُحفظ فى حقله المستقل ولا يضيع
      insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'fin_notes', '', e.notes1, 'auto', u.name, u.id, ebda.rk(u), now()::text);
    end if;
    update ebda.pay2_effects set notes1 = e.notes2 where id = e.id;
    insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'notes1', coalesce(e.notes1,''), e.notes2, 'auto', u.name, u.id, ebda.rk(u), now()::text);
  end if;
  -- (3) تجميع الأيام المخصومة من الرصيد فى عمود الشهر (يحسب من التفاصيل ولا يُضاف فوق قيمة سابقة — لا خصم مزدوج)
  if exists(select 1 from unnest(tps) x where patch ? (x || '_days')) or (patch ? '_row') then
    foreach t in array tps loop
      v := case t when 'annual' then e.annual_days when 'casual' then e.casual_days when 'sick' then e.sick_days when 'absent' then e.absent_days end;
      if v is not null then any_ := true; tot := tot + v; parts := parts || (ebda.pay2_leave_label(t) || ' ' || trim(to_char(v, 'FM999990.##'))); end if;
    end loop;
    if any_ then
      old := coalesce(ebda.pay2_view(s, p)->>mk, '');
      if old = '' or old::numeric <> tot then
        perform ebda.pay2_set_staff(st_id, p, mk, trim(to_char(tot, 'FM999990.##')), 'num', u.name);
        insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, mk, old, trim(to_char(tot, 'FM999990.##')), 'auto', u.name, u.id, ebda.rk(u), now()::text);
      end if;
      perform ebda.pay2_set_staff(st_id, p, mk || 'a', array_to_string(parts, ' + ') || ' = ' || trim(to_char(tot, 'FM999990.##')), 'text', u.name);
    end if;
  end if;
end $$;
-- pay2_set_staff يكتب أعمدة الأشهر وملاحظاتها وبيان التجميع (mXXa) فى months
create or replace function ebda.pay2_set_staff(st_id text, p text, k text, v text, typ text, by_name text) returns void language plpgsql as $$
declare s ebda.pay2_staff; m jsonb; latest text;
begin
  select * into s from ebda.pay2_staff where id = st_id;
  m := ebda.pay2_master(s);
  update ebda.pay2_effects set snap = m where staff_id = st_id and period <> p and snap is null;
  if not exists(select 1 from ebda.pay2_effects where staff_id = st_id and period = p) then
    insert into ebda.pay2_effects(id, staff_id, school_id, period, snap) values(ebda.uid(), st_id, s.school_id, p, m);
  end if;
  update ebda.pay2_effects set snap = coalesce(snap, m) || jsonb_build_object(k, v), updated_by = by_name, updated_at = now()::text where staff_id = st_id and period = p;
  -- عمود الشهر يُكتب أيضاً فى لقطات الأشهر التالية غير المعتمدة (حتى يكون «الرصيد المتبقى» فيها صحيحاً) — الأشهر المعتمدة مالياً لا تتغيّر
  if k ~ '^m\d\d[na]?$' then
    update ebda.pay2_effects e set snap = e.snap || jsonb_build_object(k, v)
     where e.staff_id = st_id and e.period > p and e.snap is not null
       and coalesce((select h.status from ebda.pay2_sheets h where h.school_id = e.school_id and h.period = e.period), 'draft') not in ('fin_approved','approved','mgr_approved','sent_finance');   -- v16: الأشهر المعتمدة من المدير المباشر لا تتغيّر
  end if;
  select max(period) into latest from ebda.pay2_effects where staff_id = st_id;
  if p >= coalesce(latest, p) or k ~ '^m\d\d[na]?$' then
    if k ~ '^m\d\d[na]?$' or k = 'leave_balance_f' then update ebda.pay2_staff set months = coalesce(months,'{}'::jsonb) || jsonb_build_object(k, v) where id = st_id;
    elsif p >= coalesce(latest, p) and typ = 'num' then execute format('update ebda.pay2_staff set %I = nullif($1,'''')::numeric where id = $2', k) using v, st_id;
    elsif p >= coalesce(latest, p) then execute format('update ebda.pay2_staff set %I = $1 where id = $2', k) using v, st_id; end if;
  end if;
end $$;

-- صف الموظف فى الشهر + الإجماليات المحسوبة (منفصلة: إجمالى الغياب والإجازات · المخصوم من الرصيد · الغياب بدون إذن للمعالجة المالية)
create or replace function ebda.pay2_row(s ebda.pay2_staff, p text) returns jsonb language sql stable as $$
  with v as (select ebda.pay2_view(s, p) j),
       e as (select (select x from ebda.pay2_effects x where x.staff_id = s.id and x.period = p) r),
       tp as (select ebda.pay2_leave_types() t)
  select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'active', s.active, 'updated_by', s.updated_by, 'updated_at', s.updated_at)
   || v.j
   || jsonb_build_object('remaining', case when coalesce(v.j->>'leave_balance','') = '' then null
        else (v.j->>'leave_balance')::numeric - coalesce((select sum(nullif(x.val,'')::numeric) from jsonb_each_text(v.j) x(k, val) where x.k ~ '^m\d\d$' and x.val ~ '^-?[0-9]+(\.[0-9]+)?$'),0) end)
   || coalesce((select to_jsonb(e.r) - 'id' - 'staff_id' - 'school_id' - 'period' - 'updated_at' - 'updated_by' - 'snap' - 'approved_snap'
                  || jsonb_build_object('eff_updated_by', (e.r).updated_by, 'eff_updated_at', (e.r).updated_at, 'approved_snap', (e.r).approved_snap) where (e.r).id is not null), '{}'::jsonb)
   || jsonb_build_object(
        'days_total', case when (e.r).id is null or ((e.r).annual_days is null and (e.r).casual_days is null and (e.r).sick_days is null and (e.r).absent_days is null) then null
                      else coalesce((e.r).annual_days,0) + coalesce((e.r).casual_days,0) + coalesce((e.r).sick_days,0) + coalesce((e.r).absent_days,0) end,
        'leave_deducted', nullif(coalesce(case when 'annual' = any(tp.t) then (e.r).annual_days end,0) + coalesce(case when 'casual' = any(tp.t) then (e.r).casual_days end,0)
                      + coalesce(case when 'sick' = any(tp.t) then (e.r).sick_days end,0) + coalesce(case when 'absent' = any(tp.t) then (e.r).absent_days end,0), 0),
        'absent_unexcused', (e.r).absent_days,
        'work_days_final', coalesce((e.r).work_days_fin, (e.r).work_days),
        'work_days_diff', (e.r).work_days_fin is not null and (e.r).work_days is not null and (e.r).work_days_fin <> (e.r).work_days,
        'deduction_total', (select sum(d.amount) from ebda.pay2_deductions d where d.staff_id = s.id and d.period = p and d.status = 'active' and d.kind = 'total'),
        'leave_month_key', 'm' || substr(p, 6, 2))
  from v, e, tp
$$;

-- ============================================================================================================================
--  v12: شيت المؤثرات بالترتيب الفعلى للملف المعتمد (56 عموداً A → BD):
--   الأساسية (A:K) لمسئول العهدة · المدير المالى (L:T) · المؤثرات الشهرية (U:AD) · رصيد الأجازات والمتبقى (AE:AF) · 12 شهراً كل شهر وبجواره ملاحظاته (AG:BD)
--   Code تلقائى ثابت · ملاحظات الشهر المختار تظهر تلقائياً فى «ملاحظات» المدير المالى (T) لنفس الموظف والشهر · المتبقى حتى الشهر المختار
-- ============================================================================================================================
create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  select '[
   ["code","Code","base","text","staff"],["ins_status","الحالة التأمينية","base","text","staff"],["name","الاسم","base","text","staff"],
   ["job","الوظيفة","base","text","staff"],["mobile","رقم الموبيل","base","text","staff"],["ins_no","الرقم التأمينى","base","text","staff"],
   ["national_id","الرقم القومى","base","text","staff"],["bank_account","الحساب البنكى","base","text","staff"],["bank_name","اسم البنك","base","text","staff"],
   ["hire_date","تاريخ التعيين","base","date","staff"],["net_salary","صافى الراتب التعاقدي\nNet salary","base","num","staff"],
   ["gross_salary","إجمالي الراتب\nGross salary","finance","num","staff"],["total_cost","إجمالي تكلفة الموظف على الشركة","finance","num","staff"],
   ["work_days","عدد ايام العمل","entry","num","month"],["summary","ملخص المؤثرات","finance","text","month"],["hour_deduct","خصم ساعة","finance","num","month"],
   ["day_deduct","خصم يوم","finance","num","month"],["net_after","الراتب الصافى بعد الخصومات","finance","num","month"],
   ["cost_after","إجمالى تكلفة الموظف بعد الخصومات","finance","num","month"],["notes1","ملاحظات","finance","text","month"],
   ["annual_days","الأجازات الإعتيادى — عدد الأيام","entry","num","month"],["annual_detail","الأجازات الإعتيادى — التفصيل","entry","text","month"],
   ["casual_days","الإجازات العارضة — عدد الأيام","entry","num","month"],["casual_detail","الإجازات العارضة — التفصيل","entry","text","month"],
   ["sick_days","الإجازات المرضى — عدد الأيام","entry","num","month"],["sick_detail","الإجازات المرضى — التفصيل","entry","text","month"],
   ["absent_days","غياب بدون إذن — عدد الأيام","entry","num","month"],["absent_detail","غياب بدون إذن — التفصيل","entry","text","month"],
   ["perm_count","الأذونات — عدد الأذونات","entry","num","month"],["perm_detail","الأذونات — التفصيل","entry","text","month"],
   ["leave_balance","رصيد الأجازات","entry","num","staff"],
   ["m07","شهر يوليو","entry","num","staff"],["m07n","ملاحظات","entry","text","staff",1],["m08","شهر أغسطس","entry","num","staff"],["m08n","ملاحظات","entry","text","staff",1],
   ["m09","شهر سبتمبر","entry","num","staff"],["m09n","ملاحظات","entry","text","staff",1],["m10","شهر أكتوبر","entry","num","staff"],["m10n","ملاحظات","entry","text","staff",1],
   ["m11","شهر نوفمبر","entry","num","staff"],["m11n","ملاحظات","entry","text","staff",1],["m12","شهر ديسمبر","entry","num","staff"],["m12n","ملاحظات","entry","text","staff",1],
   ["m01","شهر يناير","entry","num","staff"],["m01n","ملاحظات","entry","text","staff",1],["m02","شهر فبراير","entry","num","staff"],["m02n","ملاحظات","entry","text","staff",1],
   ["m03","شهر مارس","entry","num","staff"],["m03n","ملاحظات","entry","text","staff",1],["m04","شهرأبريل","entry","num","staff"],["m04n","ملاحظات","entry","text","staff",1],
   ["m05","شهر مايو","entry","num","staff"],["m05n","ملاحظات","entry","text","staff",1],["m06","شهر يونيو","entry","num","staff"],["m06n","ملاحظات","entry","text","staff",1],
   ["work_days_fin","عدد أيام العمل المعتمد (المدير المالى)","finance","num","month",1],
   ["work_days_reason","سبب تعديل أيام العمل","finance","text","month",1],
   ["fin_notes","ملاحظات وقرار المدير المالى","finance","text","month",1],
   ["notes2","ملاحظات المؤثرات (الشيت القديم)","entry","text","month",1]]'::jsonb
$$;
-- صلاحيات الحقول حسب المواصفة (مرة واحدة؛ يبقى بعدها قابلاً للضبط من «صلاحيات الحقول»):
-- البيانات الأساسية لمسئول العهدة · صافى الراتب له وللمدير المالى · الإجمالى والتكلفة للمدير المالى · Code تلقائى · «ملاحظات» T تلقائية من ملاحظات الشهر
do $r$ declare v jsonb; begin
  if not exists(select 1 from ebda.config where key = 'pay2_rules_v12') then
    select value::jsonb into v from ebda.config where key = 'pay2_field_rules';
    v := coalesce(v,'{}'::jsonb) || jsonb_build_object('code','[]'::jsonb, 'ins_status','["custody_officer"]'::jsonb, 'name','["custody_officer"]'::jsonb, 'job','["custody_officer"]'::jsonb,
      'mobile','["custody_officer"]'::jsonb, 'ins_no','["custody_officer"]'::jsonb, 'national_id','["custody_officer"]'::jsonb, 'bank_account','["custody_officer"]'::jsonb,
      'bank_name','["custody_officer"]'::jsonb, 'hire_date','["custody_officer"]'::jsonb, 'net_salary','["custody_officer","finance_manager"]'::jsonb,
      'gross_salary','["finance_manager"]'::jsonb, 'total_cost','["finance_manager"]'::jsonb, 'notes1','[]'::jsonb, 'leave_balance','["custody_officer","direct_manager"]'::jsonb,
      'm07n','["custody_officer","direct_manager","finance_manager"]'::jsonb, 'm08n','["custody_officer","direct_manager","finance_manager"]'::jsonb);
    insert into ebda.config(key, value) values('pay2_field_rules', v::text) on conflict (key) do update set value = excluded.value;
    insert into ebda.config(key, value) values('pay2_rules_v12', now()::text);
  end if;
end $r$;
update ebda.config set value = ((select jsonb_object_agg(f->>0, case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb
                                   else '["custody_officer","direct_manager","finance_manager"]'::jsonb end) from jsonb_array_elements(ebda.pay2_fields()) f) || value::jsonb)::text
 where key = 'pay2_field_rules';

-- القالب: «الرصيد المتبقى» بعد «رصيد الأجازات» مباشرة (AF) كما فى الملف
create or replace function ebda.pay2_template_headers() returns jsonb language sql immutable as $$
  select jsonb_agg(h order by o) from (
    select f->>1 h, (o * 10) o from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o)
    union all select 'الرصيد المتبقى', (select o * 10 + 5 from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o) where f->>0 = 'leave_balance')) x
$$;
create or replace function ebda.pay2_header_report(hdrs jsonb) returns jsonb language sql immutable as $$
  with t as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(ebda.pay2_template_headers()) with ordinality a(x, o)),
       f as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(coalesce(hdrs,'[]'::jsonb)) with ordinality a(x, o)),
       m as (select t.h th, t.o tor, f.h fh, f.o fo from t join f on ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm(f.h) and t.k = f.k),
       opt as (select ebda.pay2_hnorm(f->>1) h from jsonb_array_elements(ebda.pay2_fields()) f where coalesce((f->>5)::int, 0) = 1 and f->>1 <> 'ملاحظات')
  select jsonb_build_object(
    'template', ebda.pay2_template_headers(),
    'matched', (select count(*) from m),
    'missing', coalesce((select jsonb_agg(t.h order by t.o) from t where not exists(select 1 from m where m.tor = t.o)
                           and not (ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm('ملاحظات') and t.k > 1) and ebda.pay2_hnorm(t.h) not in (select h from opt)), '[]'::jsonb),
    'optional_missing', (select count(*) from t where not exists(select 1 from m where m.tor = t.o) and ((ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm('ملاحظات') and t.k > 1) or ebda.pay2_hnorm(t.h) in (select h from opt))),
    'extra', coalesce((select jsonb_agg(f.h order by f.o) from f where not exists(select 1 from m where m.fo = f.o)), '[]'::jsonb),
    'renamed', coalesce((select jsonb_agg(jsonb_build_array(m.fh, m.th)) from m where btrim(m.fh) <> btrim(m.th)), '[]'::jsonb),
    'order_changed', exists(select 1 from m a join m b on a.tor < b.tor and a.fo > b.fo))
$$;

-- ترتيب الشهر فى العام المالى: يوليو = 0 … يونيو = 11
create or replace function ebda.pay2_midx(mm text) returns int language sql immutable as $$ select (mm::int + 5) % 12 $$;

-- بعد كل حفظ/استيراد: (1) من عدّل أيام العمل المعتمدة (2) ملاحظات الشهر المختار ← «ملاحظات» المدير المالى (T) (3) عمود الشهر من أيام الإجازات المخصومة من الرصيد
create or replace function ebda.pay2_after_save(st_id text, p text, u ebda.users, patch jsonb) returns void language plpgsql security definer set search_path = ebda as $$
declare e ebda.pay2_effects; s ebda.pay2_staff; tps text[] := ebda.pay2_leave_types(); t text; tot numeric := 0; any_ boolean := false; parts text[] := '{}';
  mk text := 'm' || substr(p, 6, 2); old text; v numeric; src text;
begin
  select * into e from ebda.pay2_effects where staff_id = st_id and period = p;
  if not found then return; end if;
  select * into s from ebda.pay2_staff where id = st_id;
  if patch ? 'work_days_fin' then
    update ebda.pay2_effects set work_days_fin_by = u.name, work_days_fin_at = now()::text where id = e.id;
  end if;
  -- ملاحظات الشهر المختار (مثل «ملاحظات نوفمبر») هى مصدر «ملاحظات» المدير المالى لنفس الموظف والشهر — قرار المالى فى حقله المستقل لا يُمس
  if patch ? (mk || 'n') or patch ? 'notes2' or patch ? '_row' then
    src := coalesce(nullif(btrim(ebda.pay2_view(s, p)->>(mk || 'n')),''), nullif(btrim(e.notes2),''), '');
    if src <> '' and coalesce(e.notes1,'') <> src then
      if coalesce(btrim(e.notes1),'') <> '' and coalesce(btrim(e.fin_notes),'') = '' and not exists(
           select 1 from ebda.pay2_log l where l.staff_id = st_id and l.period = p and l.field = 'notes1' and l.source = 'auto' and l.new_value = e.notes1) then
        update ebda.pay2_effects set fin_notes = e.notes1 where id = e.id;   -- نص كتبه المالى فى T من قبل يُحفظ فى حقله المستقل
        insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'fin_notes', '', e.notes1, 'auto', u.name, u.id, ebda.rk(u), now()::text);
      end if;
      update ebda.pay2_effects set notes1 = src where id = e.id;
      insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'notes1', coalesce(e.notes1,''), src, 'auto', u.name, u.id, ebda.rk(u), now()::text);
    elsif src = '' and patch ? (mk || 'n') and exists(select 1 from ebda.pay2_log l where l.staff_id = st_id and l.period = p and l.field = 'notes1' and l.source = 'auto' and l.new_value = e.notes1) then
      update ebda.pay2_effects set notes1 = '' where id = e.id;   -- حُذفت ملاحظة الشهر ← تُحذف نسختها التلقائية فقط
      insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'notes1', coalesce(e.notes1,''), '', 'auto', u.name, u.id, ebda.rk(u), now()::text);
    end if;
  end if;
  -- «ملخص المؤثرات» تلقائى من مؤثرات الشهر (ما لم يكتب المدير المالى ملخصاً بنفسه)
  declare au text; prev text; begin
    select * into e from ebda.pay2_effects where id = e.id;
    au := coalesce(nullif(concat_ws(' · ',
             case when coalesce(e.annual_days,0) <> 0 then 'اعتيادى ' || trim(to_char(e.annual_days,'FM999990.##')) end,
             case when coalesce(e.casual_days,0) <> 0 then 'عارضة ' || trim(to_char(e.casual_days,'FM999990.##')) end,
             case when coalesce(e.sick_days,0) <> 0 then 'مرضى ' || trim(to_char(e.sick_days,'FM999990.##')) end,
             case when coalesce(e.absent_days,0) <> 0 then 'غياب بدون إذن ' || trim(to_char(e.absent_days,'FM999990.##')) end,
             case when coalesce(e.perm_count,0) <> 0 then 'أذونات ' || trim(to_char(e.perm_count,'FM999990.##')) end), ''), '');
    select l.new_value into prev from ebda.pay2_log l where l.staff_id = st_id and l.period = p and l.field = 'summary' and l.source = 'auto' order by l.at desc limit 1;
    if not (patch ? 'summary') and coalesce(e.summary,'') <> au and (coalesce(e.summary,'') = '' or e.summary = prev) then
      update ebda.pay2_effects set summary = au where id = e.id;
      insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, 'summary', coalesce(e.summary,''), au, 'auto', u.name, u.id, ebda.rk(u), now()::text);
    end if;
  end;
  if exists(select 1 from unnest(tps) x where patch ? (x || '_days')) or (patch ? '_row') then
    foreach t in array tps loop
      v := case t when 'annual' then e.annual_days when 'casual' then e.casual_days when 'sick' then e.sick_days when 'absent' then e.absent_days end;
      if v is not null then any_ := true; tot := tot + v; parts := parts || (ebda.pay2_leave_label(t) || ' ' || trim(to_char(v, 'FM999990.##'))); end if;
    end loop;
    if any_ then
      old := coalesce(ebda.pay2_view(s, p)->>mk, '');
      if old = '' or old !~ '^-?[0-9]+(\.[0-9]+)?$' or old::numeric <> tot then
        perform ebda.pay2_set_staff(st_id, p, mk, trim(to_char(tot, 'FM999990.##')), 'num', u.name);
        insert into ebda.pay2_log values(ebda.uid(), e.school_id, p, st_id, mk, old, trim(to_char(tot, 'FM999990.##')), 'auto', u.name, u.id, ebda.rk(u), now()::text);
      end if;
      perform ebda.pay2_set_staff(st_id, p, mk || 'a', array_to_string(parts, ' + ') || ' = ' || trim(to_char(tot, 'FM999990.##')), 'text', u.name);
    end if;
  end if;
end $$;

-- صف الموظف فى الشهر: Code التلقائى · المتبقى حتى الشهر المختار (لا تدخله أشهر لاحقة) · ملخص المؤثرات التلقائى · الإجماليات المنفصلة
-- v15: التأخيرات (عدد التاخيرات · التفصيل) — مؤثر شهرى بعد الأذونات
alter table ebda.pay2_effects add column if not exists late_count numeric;
alter table ebda.pay2_effects add column if not exists late_detail text default '';
create or replace function ebda.pay2_row(s ebda.pay2_staff, p text) returns jsonb language sql stable as $$
  with v as (select ebda.pay2_view(s, p) j),
       e as (select (select x from ebda.pay2_effects x where x.staff_id = s.id and x.period = p) r),
       tp as (select ebda.pay2_leave_types() t)
  select jsonb_build_object('id', s.id, 'name', s.name, 'active', s.active, 'updated_by', s.updated_by, 'updated_at', s.updated_at)
   || v.j
   || jsonb_build_object('code', coalesce(nullif(s.emp_uid,''), s.code), 'code_file', coalesce(s.code,''), 'emp_uid', s.emp_uid,
        'remaining', case when coalesce(v.j->>'leave_balance','') !~ '^-?[0-9]+(\.[0-9]+)?$' then null
          else (v.j->>'leave_balance')::numeric - coalesce((select sum(x.val::numeric) from jsonb_each_text(v.j) x(k, val)
               where x.k ~ '^m\d\d$' and x.val ~ '^-?[0-9]+(\.[0-9]+)?$' and ebda.pay2_midx(substr(x.k,2,2)) <= ebda.pay2_midx(substr(p,6,2))),0) end,
        'used_before', coalesce((select sum(x.val::numeric) from jsonb_each_text(v.j) x(k, val)
               where x.k ~ '^m\d\d$' and x.val ~ '^-?[0-9]+(\.[0-9]+)?$' and ebda.pay2_midx(substr(x.k,2,2)) < ebda.pay2_midx(substr(p,6,2))),0))
   || coalesce((select to_jsonb(e.r) - 'id' - 'staff_id' - 'school_id' - 'period' - 'updated_at' - 'updated_by' - 'snap' - 'approved_snap'
                  || jsonb_build_object('eff_updated_by', (e.r).updated_by, 'eff_updated_at', (e.r).updated_at, 'approved_snap', (e.r).approved_snap) where (e.r).id is not null), '{}'::jsonb)
   || jsonb_build_object(
        'days_total', case when (e.r).id is null or ((e.r).annual_days is null and (e.r).casual_days is null and (e.r).sick_days is null and (e.r).absent_days is null) then null
                      else coalesce((e.r).annual_days,0) + coalesce((e.r).casual_days,0) + coalesce((e.r).sick_days,0) + coalesce((e.r).absent_days,0) end,
        'leave_deducted', nullif(coalesce(case when 'annual' = any(tp.t) then (e.r).annual_days end,0) + coalesce(case when 'casual' = any(tp.t) then (e.r).casual_days end,0)
                      + coalesce(case when 'sick' = any(tp.t) then (e.r).sick_days end,0) + coalesce(case when 'absent' = any(tp.t) then (e.r).absent_days end,0), 0),
        'absent_unexcused', (e.r).absent_days,
        'work_days_final', coalesce((e.r).work_days_fin, (e.r).work_days),
        'work_days_diff', (e.r).work_days_fin is not null and (e.r).work_days is not null and (e.r).work_days_fin <> (e.r).work_days,
        'summary_auto', nullif(concat_ws(' · ',
             case when coalesce((e.r).annual_days,0) <> 0 then 'اعتيادى ' || trim(to_char((e.r).annual_days,'FM999990.##')) end,
             case when coalesce((e.r).casual_days,0) <> 0 then 'عارضة ' || trim(to_char((e.r).casual_days,'FM999990.##')) end,
             case when coalesce((e.r).sick_days,0) <> 0 then 'مرضى ' || trim(to_char((e.r).sick_days,'FM999990.##')) end,
             case when coalesce((e.r).absent_days,0) <> 0 then 'غياب بدون إذن ' || trim(to_char((e.r).absent_days,'FM999990.##')) end,
             case when coalesce((e.r).perm_count,0) <> 0 then 'أذونات ' || trim(to_char((e.r).perm_count,'FM999990.##')) end,
             case when coalesce((e.r).late_count,0) <> 0 then 'تأخيرات ' || trim(to_char((e.r).late_count,'FM999990.##')) end), ''),
        'deduction_total', (select sum(d.amount) from ebda.pay2_deductions d where d.staff_id = s.id and d.period = p and d.status = 'active' and d.kind = 'total'),
        'leave_month_key', 'm' || substr(p, 6, 2))
  from v, e, tp
$$;
-- المقارنة: الأعمدة الاختيارية (ملاحظات الأشهر · أعمدة المالى المستقلة · ملاحظات المؤثرات فى الشيت القديم) لا تُعد ناقصة ولا تغيّر الترتيب
create or replace function ebda.pay2_header_report(hdrs jsonb) returns jsonb language sql immutable as $$
  with t0 as (select f->>1 h, (o * 10) o, coalesce((f->>5)::int, 0) = 1 opt from jsonb_array_elements(ebda.pay2_fields()) with ordinality a(f, o)
              union all select 'الرصيد المتبقى', (select o * 10 + 5 from jsonb_array_elements(ebda.pay2_fields()) with ordinality a(f, o) where f->>0 = 'leave_balance'), false),
       t as (select h, o, opt, row_number() over (partition by ebda.pay2_hnorm(h) order by o) k from t0),
       f as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(coalesce(hdrs,'[]'::jsonb)) with ordinality a(x, o)),
       m as (select t.h th, t.o tor, t.opt, f.h fh, f.o fo from t join f on ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm(f.h) and t.k = f.k)
  select jsonb_build_object(
    'template', ebda.pay2_template_headers(),
    'matched', (select count(*) from m),
    'missing', coalesce((select jsonb_agg(t.h order by t.o) from t where not t.opt and not exists(select 1 from m where m.tor = t.o)), '[]'::jsonb),
    'optional_missing', (select count(*) from t where t.opt and not exists(select 1 from m where m.tor = t.o)),
    'extra', coalesce((select jsonb_agg(f.h order by f.o) from f where not exists(select 1 from m where m.fo = f.o)), '[]'::jsonb),
    'renamed', coalesce((select jsonb_agg(jsonb_build_array(m.fh, m.th)) from m where btrim(m.fh) <> btrim(m.th)), '[]'::jsonb),
    'order_changed', exists(select 1 from m a join m b on a.tor < b.tor and a.fo > b.fo where not a.opt and not b.opt))
$$;


-- ======================================================================= v13: «البند فى الموازنة» لكل موظف (U بعد «ملاحظات» المالى)
-- يحدد بند الموازنة الذى يُحمَّل عليه راتب/حافز الموظف (تمهيداً لخصم الرواتب المصروفة من بنود «الرواتب والحوافز» فى الموازنات).
alter table ebda.pay2_staff add column if not exists budget_item text default '';
create or replace function ebda.pay2_master(s ebda.pay2_staff) returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object('ins_status', s.ins_status, 'job', s.job, 'hire_date', s.hire_date,
     'mobile', s.mobile, 'ins_no', s.ins_no, 'national_id', s.national_id, 'bank_account', s.bank_account, 'bank_name', s.bank_name,
     'net_salary', s.net_salary::text, 'gross_salary', s.gross_salary::text, 'total_cost', s.total_cost::text, 'leave_balance', s.leave_balance::text,
     'budget_item', nullif(s.budget_item,''))) || coalesce(s.months, '{}'::jsonb)
$$;
create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  select '[
   ["code","Code","base","text","staff"],["ins_status","الحالة التأمينية","base","text","staff"],["name","الاسم","base","text","staff"],
   ["job","الوظيفة","base","text","staff"],["mobile","رقم الموبيل","base","text","staff"],["ins_no","الرقم التأمينى","base","text","staff"],
   ["national_id","الرقم القومى","base","text","staff"],["bank_account","الحساب البنكى","base","text","staff"],["bank_name","اسم البنك","base","text","staff"],
   ["hire_date","تاريخ التعيين","base","date","staff"],["net_salary","صافى الراتب التعاقدي\nNet salary","base","num","staff"],
   ["gross_salary","إجمالي الراتب\nGross salary","finance","num","staff"],["total_cost","إجمالي تكلفة الموظف على الشركة","finance","num","staff"],
   ["work_days","عدد ايام العمل","entry","num","month"],["summary","ملخص المؤثرات","finance","text","month"],["hour_deduct","خصم ساعة","finance","num","month"],
   ["day_deduct","خصم يوم","finance","num","month"],["net_after","الراتب الصافى بعد الخصومات","finance","num","month"],
   ["cost_after","إجمالى تكلفة الموظف بعد الخصومات","finance","num","month"],["notes1","ملاحظات","finance","text","month"],
   ["budget_item","البند فى الموازنة","base","text","staff",1],
   ["annual_days","الأجازات الإعتيادى — عدد الأيام","entry","num","month"],["annual_detail","الأجازات الإعتيادى — التفصيل","entry","text","month"],
   ["casual_days","الإجازات العارضة — عدد الأيام","entry","num","month"],["casual_detail","الإجازات العارضة — التفصيل","entry","text","month"],
   ["sick_days","الإجازات المرضى — عدد الأيام","entry","num","month"],["sick_detail","الإجازات المرضى — التفصيل","entry","text","month"],
   ["absent_days","غياب بدون إذن — عدد الأيام","entry","num","month"],["absent_detail","غياب بدون إذن — التفصيل","entry","text","month"],
   ["perm_count","الأذونات — عدد الأذونات","entry","num","month"],["perm_detail","الأذونات — التفصيل","entry","text","month"],
   ["leave_balance","رصيد الأجازات","entry","num","staff"],
   ["m07","شهر يوليو","entry","num","staff"],["m07n","ملاحظات","entry","text","staff",1],["m08","شهر أغسطس","entry","num","staff"],["m08n","ملاحظات","entry","text","staff",1],
   ["m09","شهر سبتمبر","entry","num","staff"],["m09n","ملاحظات","entry","text","staff",1],["m10","شهر أكتوبر","entry","num","staff"],["m10n","ملاحظات","entry","text","staff",1],
   ["m11","شهر نوفمبر","entry","num","staff"],["m11n","ملاحظات","entry","text","staff",1],["m12","شهر ديسمبر","entry","num","staff"],["m12n","ملاحظات","entry","text","staff",1],
   ["m01","شهر يناير","entry","num","staff"],["m01n","ملاحظات","entry","text","staff",1],["m02","شهر فبراير","entry","num","staff"],["m02n","ملاحظات","entry","text","staff",1],
   ["m03","شهر مارس","entry","num","staff"],["m03n","ملاحظات","entry","text","staff",1],["m04","شهرأبريل","entry","num","staff"],["m04n","ملاحظات","entry","text","staff",1],
   ["m05","شهر مايو","entry","num","staff"],["m05n","ملاحظات","entry","text","staff",1],["m06","شهر يونيو","entry","num","staff"],["m06n","ملاحظات","entry","text","staff",1],
   ["work_days_fin","عدد أيام العمل المعتمد (المدير المالى)","finance","num","month",1],
   ["work_days_reason","سبب تعديل أيام العمل","finance","text","month",1],
   ["fin_notes","ملاحظات وقرار المدير المالى","finance","text","month",1],
   ["notes2","ملاحظات المؤثرات (الشيت القديم)","entry","text","month",1]]'::jsonb
$$;
-- قائمة بنود الموازنة الخاصة بالرواتب والحوافز (من دليل البنود؛ قابلة للتعديل من config «pay2_budget_items» كقائمة معرّفات)
insert into ebda.config(key, value) values('pay2_budget_items', '["lc_t01","lc_t02","lc_t03","lc_t04","lc_a01","lc_a02","lc_a04","lc_f01"]') on conflict (key) do nothing;
create or replace function ebda.pay2_budget_items() returns jsonb language sql stable as $$
  select coalesce((select jsonb_agg(coalesce(c.name, d.n) order by x.o)
     from jsonb_array_elements_text(coalesce((select value::jsonb from ebda.config where key = 'pay2_budget_items'), '[]'::jsonb)) with ordinality x(id, o)
     left join ebda.line_catalog c on c.id = x.id
     left join (values ('lc_t01','حافز المدير الأكاديمى'),('lc_t02','حافز المعلمين المنتدبين من وزارة التربية والتعليم'),('lc_t03','راتب معلمى التخصص - قطاع خاص'),
                       ('lc_t04','راتب معلمى المواد الثقافية - قطاع خاص'),('lc_a01','حافز الإداريين المنتدبين وزراة التربية والتعليم'),
                       ('lc_a02','حافز الأخصائيين (النفسى والاجتماعى وعيادة وتطوير تكنولوجى)'),('lc_a04','راتب الإدرايين - قطاع خاص'),
                       ('lc_f01','أتعاب شركة الإدارة (أكاديمية ابدأ إديو)')) d(id, n) on d.id = x.id
     where coalesce(c.name, d.n) is not null), '[]'::jsonb)
$$;
do $r$ declare v jsonb; begin
  if not exists(select 1 from ebda.config where key = 'pay2_rules_v13') then
    select value::jsonb into v from ebda.config where key = 'pay2_field_rules';
    v := coalesce(v,'{}'::jsonb) || jsonb_build_object('budget_item','["custody_officer","finance_manager"]'::jsonb);
    insert into ebda.config(key, value) values('pay2_field_rules', v::text) on conflict (key) do update set value = excluded.value;
    insert into ebda.config(key, value) values('pay2_rules_v13', now()::text);
  end if;
end $r$;

-- ======================================================================= v14: (1) خصم الرواتب المصروفة من بنود الموازنة تلقائياً
-- عند الاعتماد المالى لشهر الرواتب: لكل «بند فى الموازنة» يُسجَّل مصروف واحد على بند الجهة نفسها = مجموع ما يُصرف لموظفيه
-- (الصافى بعد الخصومات، وإلا صافى الراتب التعاقدي). المرجع ثابت (pay2:الجهة:الشهر:البند) فلا تكرار مع إعادة الاعتماد.
-- إعادة فتح الشهر/إعادته للتعديل تلغى هذه المصروفات (إلغاء مسجّل بسبب، لا حذف) وتعود عند الاعتماد التالى بالقيم الجديدة.
create or replace function ebda.pay2_month_amounts(sid text, p text, basis text) returns jsonb language sql stable as $$
  with r as (select ebda.pay2_row(s, p) j from ebda.pay2_staff s where s.school_id = sid and s.fy = ebda.pay2_fy(p) and coalesce(s.active,'نعم') <> 'لا'
               and exists(select 1 from ebda.pay2_effects e where e.staff_id = s.id and e.period = p)),
       a as (select coalesce(nullif(btrim(j->>'budget_item'),''), '') item,
                    case when basis = 'cost' then   -- v14.1: الخصم من الموازنة = إجمالى تكلفة الموظف على الشركة (بعد الخصومات إن وُجدت)
                      coalesce(case when coalesce(j->>'cost_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'cost_after')::numeric end,
                               case when coalesce(j->>'total_cost','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'total_cost')::numeric end,
                               case when coalesce(j->>'net_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_after')::numeric end,
                               case when coalesce(j->>'net_salary','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_salary')::numeric end, 0)
                    else
                      coalesce(case when coalesce(j->>'net_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_after')::numeric end,
                               case when coalesce(j->>'net_salary','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_salary')::numeric end, 0) end amt from r)
  select coalesce(jsonb_agg(jsonb_build_object('item', item, 'amount', s, 'n', n) order by item), '[]'::jsonb)
    from (select item, sum(amt) s, count(*) n from a group by item) x
$$;
create or replace function ebda.pay2_month_amounts(sid text, p text) returns jsonb language sql stable as $$ select ebda.pay2_month_amounts(sid, p, 'net') $$;
create or replace function ebda.pay2_line_of(sid text, item text) returns text language sql stable as $$
  select l.id from ebda.lines l
   where l.school_id = sid and coalesce(l.deleted_at,'') = '' and coalesce(l.active,'نعم') <> 'لا'
     and (l.catalog_id in (select c.id from ebda.line_catalog c where ebda.pay2_hnorm(c.name) = ebda.pay2_hnorm(item)) or ebda.pay2_hnorm(l.name) = ebda.pay2_hnorm(item))
   order by (l.catalog_id <> '') desc limit 1
$$;
create or replace function ebda.pay2_post_budget(sid text, p text, st text, by_name text) returns jsonb language plpgsql security definer set search_path = ebda as $ppb$
declare a jsonb; x jsonb; lid text; k text; d text; posted jsonb := '[]'::jsonb; unlinked jsonb := '[]'::jsonb; keep text[] := '{}'; mn text;
begin
  d := to_char((p || '-01')::date + interval '1 month' - interval '1 day', 'YYYY-MM-DD');
  mn := (array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'])[substr(p,6,2)::int] || ' ' || substr(p,1,4);
  if st in ('fin_approved','approved') then
    a := ebda.pay2_month_amounts(sid, p, 'cost');
    for x in select * from jsonb_array_elements(a) loop
      if (x->>'amount')::numeric = 0 then continue; end if;
      lid := case when x->>'item' = '' then null else ebda.pay2_line_of(sid, x->>'item') end;
      if lid is null then unlinked := unlinked || x; continue; end if;
      k := 'pay2:' || sid || ':' || p || ':' || lid; keep := keep || k;
      if exists(select 1 from ebda.expenses where ref = k) then
        update ebda.expenses set amount = (x->>'amount')::numeric, date = d, line_id = lid, cancelled_at = '', cancelled_by = '', cancel_reason = '',
               description = 'رواتب وحوافز ' || mn || ' — ' || (x->>'item') || ' (' || (x->>'n') || ' موظف)', updated_by = by_name, updated_at = now()::text
         where ref = k and (amount <> (x->>'amount')::numeric or coalesce(cancelled_at,'') <> '' or line_id <> lid or date <> d);
      else
        insert into ebda.expenses(id, date, school_id, custody_id, line_id, spend_item, description, amount, approval, approved_by, approved_at, fin_approval, fin_by, fin_at,
                                  ref, note, created_by, created_at, pay_method, doc_type)
        values(ebda.uid(), d, sid, '', lid, 'رواتب وحوافز', 'رواتب وحوافز ' || mn || ' — ' || (x->>'item') || ' (' || (x->>'n') || ' موظف)', (x->>'amount')::numeric,
               'approved', by_name, now()::text, 'approved', by_name, now()::text, k, 'مسجّل تلقائياً من الاعتماد المالى لشيت المؤثرات', 'النظام — الرواتب والحافز', now()::text, 'تحويل بنكى', 'كشف رواتب');
      end if;
      posted := posted || (x || jsonb_build_object('line_id', lid));
    end loop;
  end if;
  update ebda.expenses set cancelled_at = now()::text, cancelled_by = by_name,
         cancel_reason = case when st in ('fin_approved','approved') then 'لم يعد للبند رواتب فى الشهر المعتمد' else 'أُعيد فتح شهر الرواتب للتعديل — يُسجَّل من جديد عند الاعتماد المالى' end
   where ref like 'pay2:' || sid || ':' || p || ':%' and coalesce(cancelled_at,'') = '' and not (ref = any(keep));
  return jsonb_build_object('posted', posted, 'unlinked', unlinked);
end $ppb$;
create or replace function ebda.pay2_sheet_budget_trg() returns trigger language plpgsql security definer set search_path = ebda as $t$
declare r jsonb;
begin
  if tg_op = 'UPDATE' and coalesce(new.status,'') is not distinct from coalesce(old.status,'') then return new; end if;
  if not (coalesce(new.status,'') in ('fin_approved','approved') or (tg_op = 'UPDATE' and coalesce(old.status,'') in ('fin_approved','approved'))) then return new; end if;
  r := ebda.pay2_post_budget(new.school_id, new.period, coalesce(new.status,''), coalesce(nullif(new.fin_by,''), 'النظام'));
  if jsonb_array_length(r->'unlinked') > 0 then
    insert into ebda.pay2_log values(ebda.uid(), new.school_id, new.period, '', '_budget', '', 'رواتب غير مربوطة ببند موازنة: ' ||
      (select string_agg(coalesce(nullif(x->>'item',''),'(بدون بند)') || ' = ' || (x->>'amount'), ' · ') from jsonb_array_elements(r->'unlinked') x), 'budget', 'النظام', '', '', now()::text);
  end if;
  return new;
end $t$;
drop trigger if exists trg_pay2_budget on ebda.pay2_sheets;
create trigger trg_pay2_budget after insert or update of status on ebda.pay2_sheets for each row execute function ebda.pay2_sheet_budget_trg();
-- حالة الربط بالموازنة لشهر (تظهر للمالى/الأدمن فى شاشة الرواتب)
create or replace function ebda.pay2_budget_info(sid text, p text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'items', (select coalesce(jsonb_agg(x || jsonb_build_object('line_id', ebda.pay2_line_of(sid, x->>'item'),
                 'posted', (select e.amount from ebda.expenses e where e.ref = 'pay2:' || sid || ':' || p || ':' || ebda.pay2_line_of(sid, x->>'item') and coalesce(e.cancelled_at,'') = ''))), '[]'::jsonb)
              from jsonb_array_elements(ebda.pay2_month_amounts(sid, p, 'cost')) x),
    'posted_total', (select coalesce(sum(amount),0) from ebda.expenses where ref like 'pay2:' || sid || ':' || p || ':%' and coalesce(cancelled_at,'') = ''))
$$;

-- ======================================================================= v14: (2) الشيت الرئيسى المجمع للرواتب والحوافز (للأدمن فقط)
-- (أ) جدول مرتبات العاملين بالشركة (ليسوا على شيت مدرسة) — لكل شهر؛ الشهر الجديد يبدأ من آخر شهر سابق
-- (ب) رواتب وحوافز المدارس: رواتب القطاع الخاص · حوافز الحكوميين (من شيت مؤثرات الشهر حسب «البند فى الموازنة») · شركة الأمن · شركة النظافة (من مصروفات البندين فى الشهر)
--     كل قيمة محسوبة يمكن تثبيتها يدوياً باستيراد الشيت (تُحفظ «قيمة مستوردة» وتظهر بجوار المحسوبة)
create table if not exists ebda.pay2_hq(id text primary key, period text not null, sort int default 0, name text default '', hire_date text default '', job text default '',
  net_salary numeric, month_amount numeric, allowances numeric, notes text default '', bank_holder text default '', bank_name text default '', bank_account text default '',
  updated_by text default '', updated_at text default '');
create index if not exists ix_pay2_hq_period on ebda.pay2_hq(period);
create table if not exists ebda.pay2_master(period text not null, school_id text not null, private_amt numeric, gov_amt numeric, security_amt numeric, cleaning_amt numeric,
  updated_by text default '', updated_at text default '', primary key(period, school_id));
create or replace function ebda.pay2_bucket(item text) returns text language sql immutable as $$
  select case when coalesce(item,'') ~ 'حافز' then 'gov' else 'private' end
$$;
create or replace function ebda.pay2_master_get(p text) returns jsonb language plpgsql stable security definer set search_path = ebda as $pmg$
declare hq jsonb; src text;
begin
  select coalesce(jsonb_agg(to_jsonb(h) order by h.sort, h.name), '[]'::jsonb) into hq from ebda.pay2_hq h where h.period = p;
  src := p;
  if jsonb_array_length(hq) = 0 then
    select max(period) into src from ebda.pay2_hq where period < p;
    select coalesce(jsonb_agg(to_jsonb(h) - 'id' || jsonb_build_object('id', '', 'month_amount', h.net_salary, 'allowances', null, 'notes', '') order by h.sort, h.name), '[]'::jsonb)
      into hq from ebda.pay2_hq h where h.period = src;
  end if;
  return jsonb_build_object('ok', true, 'period', p, 'hq', hq, 'hq_from', src,
    'schools', (select coalesce(jsonb_agg(z order by z->>'name' desc), '[]'::jsonb) from (
      select jsonb_build_object('id', s.id, 'name', s.name,
        'calc', jsonb_build_object(
          'private', (select coalesce(sum((x->>'amount')::numeric),0) from jsonb_array_elements(ebda.pay2_month_amounts(s.id, p)) x where ebda.pay2_bucket(x->>'item') = 'private'),
          'gov', (select coalesce(sum((x->>'amount')::numeric),0) from jsonb_array_elements(ebda.pay2_month_amounts(s.id, p)) x where ebda.pay2_bucket(x->>'item') = 'gov'),
          'security', (select coalesce(sum(e.amount),0) from ebda.expenses e join ebda.lines l on l.id = e.line_id where e.school_id = s.id and substr(e.date,1,7) = p and ebda.counts_in_budget(e)
                         and (l.catalog_id = 'lc_a07' or ebda.pay2_hnorm(l.name) = ebda.pay2_hnorm('شركة أمن'))),
          'cleaning', (select coalesce(sum(e.amount),0) from ebda.expenses e join ebda.lines l on l.id = e.line_id where e.school_id = s.id and substr(e.date,1,7) = p and ebda.counts_in_budget(e)
                         and (l.catalog_id = 'lc_a06' or ebda.pay2_hnorm(l.name) = ebda.pay2_hnorm('شركة نظافة')))),
        'fixed', (select jsonb_build_object('private', m.private_amt, 'gov', m.gov_amt, 'security', m.security_amt, 'cleaning', m.cleaning_amt, 'by', m.updated_by, 'at', m.updated_at)
                    from ebda.pay2_master m where m.period = p and m.school_id = s.id),
        'status', (select ebda.pay2_status_label(h.status) from ebda.pay2_sheets h where h.school_id = s.id and h.period = p)) z
      from ebda.schools s where coalesce(s.category,'school') = 'school' and coalesce(s.cancelled_at,'') = '' and coalesce(s.active,'نعم') <> 'لا') q));
end $pmg$;
create or replace function ebda.pay2_master_api(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pma$
declare p text := coalesce(req->>'period',''); x jsonb; sid text; n_hq int := 0; n_sc int := 0; miss jsonb := '[]'::jsonb; i int := 0;
begin
  if ebda.rk(u) <> 'admin' then return ebda.err('الشيت الرئيسى المجمع للرواتب للأدمن فقط'); end if;
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  if coalesce(req->>'mode','get') = 'get' then return ebda.pay2_master_get(p); end if;
  if req->>'mode' = 'import' then
    if jsonb_typeof(req->'hq') = 'array' then
      delete from ebda.pay2_hq where period = p;
      for x in select * from jsonb_array_elements(req->'hq') loop
        if btrim(coalesce(x->>'name','')) = '' then continue; end if;
        i := i + 1;
        insert into ebda.pay2_hq(id, period, sort, name, hire_date, job, net_salary, month_amount, allowances, notes, bank_holder, bank_name, bank_account, updated_by, updated_at)
        values(ebda.uid(), p, i, btrim(x->>'name'), coalesce(x->>'hire_date',''), btrim(coalesce(x->>'job','')),
               nullif(regexp_replace(coalesce(x->>'net_salary',''),'[^0-9.\-]','','g'),'')::numeric, nullif(regexp_replace(coalesce(x->>'month_amount',''),'[^0-9.\-]','','g'),'')::numeric,
               nullif(regexp_replace(coalesce(x->>'allowances',''),'[^0-9.\-]','','g'),'')::numeric, btrim(coalesce(x->>'notes','')),
               btrim(coalesce(x->>'bank_holder','')), btrim(coalesce(x->>'bank_name','')), btrim(coalesce(x->>'bank_account','')), u.name, now()::text);
        n_hq := n_hq + 1;
      end loop;
    end if;
    for x in select * from jsonb_array_elements(coalesce(req->'schools','[]'::jsonb)) loop
      select s.id into sid from ebda.schools s where coalesce(s.category,'school') = 'school' and coalesce(s.cancelled_at,'') = ''
        and (ebda.pay2_hnorm(s.name) = ebda.pay2_hnorm(x->>'name')
             or ebda.pay2_hnorm(x->>'name') like '%' || ebda.pay2_hnorm(btrim(regexp_replace(s.name, '^.*[—-]', ''))) || '%') limit 1;
      if sid is null then miss := miss || to_jsonb(x->>'name'); continue; end if;
      insert into ebda.pay2_master(period, school_id, private_amt, gov_amt, security_amt, cleaning_amt, updated_by, updated_at)
      values(p, sid, nullif(x->>'private','')::numeric, nullif(x->>'gov','')::numeric, nullif(x->>'security','')::numeric, nullif(x->>'cleaning','')::numeric, u.name, now()::text)
      on conflict (period, school_id) do update set private_amt = excluded.private_amt, gov_amt = excluded.gov_amt, security_amt = excluded.security_amt,
        cleaning_amt = excluded.cleaning_amt, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
      n_sc := n_sc + 1; sid := null;
    end loop;
    return ebda.pay2_master_get(p) || jsonb_build_object('imported', jsonb_build_object('hq', n_hq, 'schools', n_sc, 'unmatched', miss));
  end if;
  if req->>'mode' = 'unfix' then   -- العودة للقيم المحسوبة من النظام
    delete from ebda.pay2_master where period = p and (coalesce(req->>'school_id','') = '' or school_id = req->>'school_id');
    return ebda.pay2_master_get(p);
  end if;
  return ebda.err('طلب غير معروف');
end $pma$;


-- ======================================================================= v15: (1) التأخيرات فى شيت المؤثرات (AF:AG بعد الأذونات — 59 عموداً)
create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  select '[
   ["code","Code","base","text","staff"],["ins_status","الحالة التأمينية","base","text","staff"],["name","الاسم","base","text","staff"],
   ["job","الوظيفة","base","text","staff"],["mobile","رقم الموبيل","base","text","staff"],["ins_no","الرقم التأمينى","base","text","staff"],
   ["national_id","الرقم القومى","base","text","staff"],["bank_account","الحساب البنكى","base","text","staff"],["bank_name","اسم البنك","base","text","staff"],
   ["hire_date","تاريخ التعيين","base","date","staff"],["net_salary","صافى الراتب التعاقدي\nNet salary","base","num","staff"],
   ["gross_salary","إجمالي الراتب\nGross salary","finance","num","staff"],["total_cost","إجمالي تكلفة الموظف على الشركة","finance","num","staff"],
   ["work_days","عدد ايام العمل","entry","num","month"],["summary","ملخص المؤثرات","finance","text","month"],["hour_deduct","خصم ساعة","finance","num","month"],
   ["day_deduct","خصم يوم","finance","num","month"],["net_after","الراتب الصافى بعد الخصومات","finance","num","month"],
   ["cost_after","إجمالى تكلفة الموظف بعد الخصومات","finance","num","month"],["notes1","ملاحظات","finance","text","month"],
   ["budget_item","البند فى الموازنة","base","text","staff",1],
   ["annual_days","الأجازات الإعتيادى — عدد الأيام","entry","num","month"],["annual_detail","الأجازات الإعتيادى — التفصيل","entry","text","month"],
   ["casual_days","الإجازات العارضة — عدد الأيام","entry","num","month"],["casual_detail","الإجازات العارضة — التفصيل","entry","text","month"],
   ["sick_days","الإجازات المرضى — عدد الأيام","entry","num","month"],["sick_detail","الإجازات المرضى — التفصيل","entry","text","month"],
   ["absent_days","غياب بدون إذن — عدد الأيام","entry","num","month"],["absent_detail","غياب بدون إذن — التفصيل","entry","text","month"],
   ["perm_count","الأذونات — عدد الأذونات","entry","num","month"],["perm_detail","الأذونات — التفصيل","entry","text","month"],
   ["late_count","التأخيرات — عدد التاخيرات","entry","num","month",1],["late_detail","التأخيرات — التفصيل","entry","text","month",1],
   ["leave_balance","رصيد الأجازات","entry","num","staff"],
   ["m07","شهر يوليو","entry","num","staff"],["m07n","ملاحظات","entry","text","staff",1],["m08","شهر أغسطس","entry","num","staff"],["m08n","ملاحظات","entry","text","staff",1],
   ["m09","شهر سبتمبر","entry","num","staff"],["m09n","ملاحظات","entry","text","staff",1],["m10","شهر أكتوبر","entry","num","staff"],["m10n","ملاحظات","entry","text","staff",1],
   ["m11","شهر نوفمبر","entry","num","staff"],["m11n","ملاحظات","entry","text","staff",1],["m12","شهر ديسمبر","entry","num","staff"],["m12n","ملاحظات","entry","text","staff",1],
   ["m01","شهر يناير","entry","num","staff"],["m01n","ملاحظات","entry","text","staff",1],["m02","شهر فبراير","entry","num","staff"],["m02n","ملاحظات","entry","text","staff",1],
   ["m03","شهر مارس","entry","num","staff"],["m03n","ملاحظات","entry","text","staff",1],["m04","شهرأبريل","entry","num","staff"],["m04n","ملاحظات","entry","text","staff",1],
   ["m05","شهر مايو","entry","num","staff"],["m05n","ملاحظات","entry","text","staff",1],["m06","شهر يونيو","entry","num","staff"],["m06n","ملاحظات","entry","text","staff",1],
   ["work_days_fin","عدد أيام العمل المعتمد (المدير المالى)","finance","num","month",1],
   ["work_days_reason","سبب تعديل أيام العمل","finance","text","month",1],
   ["fin_notes","ملاحظات وقرار المدير المالى","finance","text","month",1],
   ["notes2","ملاحظات المؤثرات (الشيت القديم)","entry","text","month",1]]'::jsonb
$$;
update ebda.config set value = ((select jsonb_object_agg(f->>0, case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb
                                   else '["custody_officer","direct_manager","finance_manager"]'::jsonb end) from jsonb_array_elements(ebda.pay2_fields()) f) || value::jsonb)::text
 where key = 'pay2_field_rules';

-- ======================================================================= v15: (2) نموذج الحضور والغياب الموقع من المدرسة (لكل جهة وشهر) — يرفعه مسئول العهدة كل شهر
-- يُحفظ كل رفع كنسخة (لا حذف فعلى): الأحدث هو المعتمد، والسابقة فى السجل. يراه كل من يرى شيت المؤثرات للجهة.
create table if not exists ebda.pay2_att_docs(id text primary key, school_id text not null, period text not null, file_name text default '', mime text default '',
  size_bytes int default 0, data_url text default '', note text default '', uploaded_by text default '', uploaded_by_id text default '', uploaded_at text default '',
  active boolean default true, removed_by text default '', removed_at text default '', remove_reason text default '');
create index if not exists ix_pay2_att on ebda.pay2_att_docs(school_id, period);
create or replace function ebda.pay2_att_api(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $att$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); md text := coalesce(req->>'mode','list'); d ebda.pay2_att_docs; st text; du text;
begin
  if md = 'get' then
    select * into d from ebda.pay2_att_docs where id = req->>'id';
    if d.id is null or not ebda.pay2_view_ok(u, d.school_id) then return ebda.err('لا صلاحية'); end if;
    return jsonb_build_object('ok', true, 'dataUrl', d.data_url, 'name', d.file_name, 'mime', d.mime);
  end if;
  if p !~ '^\d{4}-\d{2}$' or not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية'); end if;
  st := coalesce((select status from ebda.pay2_sheets where school_id = sid and period = p), 'draft');
  if md = 'upload' then
    if not (ebda.rk(u) = 'admin' or (ebda.pay2_is_entry(u) and ebda.can_school(u, sid))) then return ebda.err('رفع نموذج الحضور لمسئول العهدة (المشرف التنفيذى) أو الأدمن'); end if;
    if st in ('fin_approved','approved') and ebda.rk(u) <> 'admin' then return ebda.err('الشهر معتمد مالياً — لا يمكن تغيير النموذج'); end if;
    du := coalesce(req->>'dataUrl','');
    if du !~ '^data:(application/pdf|image/(png|jpeg|jpg|webp)|application/vnd.openxmlformats-officedocument.spreadsheetml.sheet|application/vnd.ms-excel);base64,' then
      return ebda.err('الملف يجب أن يكون PDF أو صورة (JPG/PNG) أو Excel'); end if;
    if length(du) > 14000000 then return ebda.err('حجم الملف أكبر من 10 ميجا — صغّر حجم المسح الضوئى'); end if;
    insert into ebda.pay2_att_docs(id, school_id, period, file_name, mime, size_bytes, data_url, note, uploaded_by, uploaded_by_id, uploaded_at)
    values(ebda.uid(), sid, p, coalesce(req->>'name',''), split_part(substr(du, 6), ';', 1), (length(du) * 3 / 4)::int, du, coalesce(req->>'note',''), u.name, u.id, now()::text);
    insert into ebda.pay2_log values(ebda.uid(), sid, p, '', '_att_doc', '', 'رفع نموذج الحضور والغياب الموقع: ' || coalesce(req->>'name',''), 'edit', u.name, u.id, ebda.rk(u), now()::text);
  elsif md = 'remove' then
    select * into d from ebda.pay2_att_docs where id = req->>'id' and school_id = sid and period = p and active;
    if d.id is null then return ebda.err('النموذج غير موجود'); end if;
    if not (ebda.rk(u) = 'admin' or (d.uploaded_by_id = u.id and st not in ('fin_approved','approved','mgr_approved','sent_finance'))) then return ebda.err('لا صلاحية لإلغاء النموذج'); end if;
    if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الإلغاء'); end if;
    update ebda.pay2_att_docs set active = false, removed_by = u.name, removed_at = now()::text, remove_reason = btrim(req->>'reason') where id = d.id;
  end if;
  return jsonb_build_object('ok', true, 'status', st,
    'can_upload', (ebda.rk(u) = 'admin' or (ebda.pay2_is_entry(u) and ebda.can_school(u, sid))) and (st not in ('fin_approved','approved') or ebda.rk(u) = 'admin'),
    'docs', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.file_name, 'mime', x.mime, 'size', x.size_bytes, 'by', x.uploaded_by, 'at', x.uploaded_at, 'note', x.note,
               'active', x.active, 'removed_by', x.removed_by, 'removed_at', x.removed_at, 'reason', x.remove_reason, 'mine', x.uploaded_by_id = u.id) order by x.uploaded_at desc)
             from ebda.pay2_att_docs x where x.school_id = sid and x.period = p), '[]'::jsonb));
end $att$;

-- ======================================================================= v16: نسخة احتياطية قبل التعديل (مرة واحدة — لا تُستبدل عند إعادة التشغيل)
create table if not exists ebda.bak_v16_pay2_sheets as table ebda.pay2_sheets;
create table if not exists ebda.bak_v16_pay2_staff as table ebda.pay2_staff;
create table if not exists ebda.bak_v16_pay2_effects as table ebda.pay2_effects;
create table if not exists ebda.bak_v16_expenses as table ebda.expenses;
create table if not exists ebda.bak_v16_lines as table ebda.lines;
-- ======================================================================= v16: (1) قفل شيت المؤثرات بعد اعتماد المدير المباشر
-- بعد «معتمد من المدير المباشر» (وما بعده): لا تعديل لمسئول العهدة ولا لغيره · المدير المالى فى أعمدته فقط حتى 10 أيام بعد نهاية الشهر · ثم طلب تعديل للأدمن.
alter table ebda.pay2_log add column if not exists note text default '';
create or replace function ebda.pay2_locked(st text) returns boolean language sql immutable as $$ select coalesce(st,'') in ('mgr_approved','sent_finance') $$;
create or replace function ebda.pay2_fin_cols() returns text[] language sql immutable as $$
  select array['net_salary','gross_salary','total_cost','work_days_fin','work_days_reason','summary','hour_deduct','day_deduct','net_after','cost_after','fin_notes'] $$;
-- آخر يوم لتعديل المدير المالى = آخر يوم فى الشهر + 10 أيام (بتاريخ القاهرة)
create or replace function ebda.pay2_fin_deadline(p text) returns date language sql immutable as $$
  select ((p || '-01')::date + interval '1 month' - interval '1 day' + interval '10 days')::date $$;
create or replace function ebda.pay2_today() returns date language sql stable as $$
  select coalesce(nullif(current_setting('ebda.today', true),'')::date,
                  nullif((select value from ebda.config where key = 'pay2_today_override'),'')::date,   -- للاختبارات فقط (غير مضبوط فى التشغيل)
                  (now() at time zone 'Africa/Cairo')::date) $$;
create or replace function ebda.pay2_edit_ok(u ebda.users, k text, grp text, st text, p text) returns boolean language sql stable as $$
  select case
    when current_setting('ebda.pay2_force', true) = '1' then true
    when coalesce(st,'draft') in ('fin_approved','approved') then false
    when ebda.pay2_locked(st) then
      ebda.rk(u) = 'admin'
      or (ebda.pay2_is_fin(u) and k = any(ebda.pay2_fin_cols()) and p ~ '^\d{4}-\d{2}$' and ebda.pay2_today() <= ebda.pay2_fin_deadline(p))
    else ebda.pay2_stage_ok(u, grp, st) end $$;
create or replace function ebda.pay2_lock_info(u ebda.users, st text, p text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'locked', ebda.pay2_locked(st) or coalesce(st,'') in ('fin_approved','approved'),
    'mgr_locked', ebda.pay2_locked(st),
    'fin_deadline', case when p ~ '^\d{4}-\d{2}$' then ebda.pay2_fin_deadline(p)::text end,
    'fin_open', p ~ '^\d{4}-\d{2}$' and ebda.pay2_today() <= ebda.pay2_fin_deadline(p),
    'need_reason', ebda.pay2_locked(st),
    'can_request', ebda.rk(u) <> 'observer') $$;

-- ======================================================================= v16: (2) طلبات تعديل شيت المؤثرات إلى الأدمن
create table if not exists ebda.pay2_edit_requests(id text primary key, fy text, school_id text, period text, staff_id text, emp_code text default '', emp_name text default '',
  field text, field_label text default '', current_value text default '', proposed_value text default '', reason text default '',
  att_name text default '', att_data text default '', requested_by text default '', requested_by_id text default '', requested_role text default '', requested_at text default '',
  status text default 'pending', decided_by text default '', decided_at text default '', decision_note text default '',
  applied_old text default '', applied_new text default '', budget_effect text default '', sheet_status text default '');
create index if not exists ix_pay2_ereq on ebda.pay2_edit_requests(school_id, period, status);
create or replace function ebda.pay2_ereq_api(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $er$
declare md text := coalesce(req->>'mode','list'); x ebda.pay2_edit_requests; st ebda.pay2_staff; f jsonb; nv jsonb; cur text; sh text; r jsonb; nid text; bef numeric; aft numeric;
begin
  if ebda.rk(u) = 'observer' then return ebda.err('لا صلاحية'); end if;
  if md = 'create' then
    select * into st from ebda.pay2_staff where id = req->>'staff_id';
    if st.id is null or not ebda.pay2_view_ok(u, st.school_id) then return ebda.err('لا صلاحية على هذا الموظف'); end if;
    if coalesce(req->>'period','') !~ '^\d{4}-\d{2}$' or ebda.pay2_fy(req->>'period') <> st.fy then return ebda.err('الشهر غير صحيح'); end if;
    select e into f from jsonb_array_elements(ebda.pay2_fields()) e where e->>0 = req->>'field' and e->>0 not in ('code','notes1');
    if f is null then return ebda.err('اختر الحقل المطلوب تعديله'); end if;
    nv := ebda.pay2_val(f->>3, coalesce(req->>'proposed',''));
    if not (nv->>'ok')::boolean then return ebda.err(f->>1 || ': ' || (nv->>'err')); end if;
    if length(btrim(coalesce(req->>'reason',''))) < 5 then return ebda.err('اكتب سبب التعديل بالتفصيل'); end if;
    if coalesce(req->>'att_data','') <> '' and (req->>'att_data' !~ '^data:[a-z]+/[a-z0-9.+-]+;base64,' or length(req->>'att_data') > 7000000) then return ebda.err('المرفق غير صالح أو أكبر من 5 ميجا'); end if;
    cur := coalesce(ebda.pay2_row(st, req->>'period')->>(req->>'field'), '');
    if exists(select 1 from ebda.pay2_edit_requests q where q.staff_id = st.id and q.period = req->>'period' and q.field = req->>'field' and q.status = 'pending' and q.proposed_value = nv->>'v') then
      return ebda.err('يوجد طلب معلّق بنفس التعديل'); end if;
    nid := ebda.uid();
    insert into ebda.pay2_edit_requests(id, fy, school_id, period, staff_id, emp_code, emp_name, field, field_label, current_value, proposed_value, reason, att_name, att_data,
      requested_by, requested_by_id, requested_role, requested_at, sheet_status)
    values(nid, st.fy, st.school_id, req->>'period', st.id, coalesce(nullif(st.emp_uid,''), st.code, ''), st.name, f->>0, replace(f->>1, E'\n', ' '), cur, nv->>'v', btrim(req->>'reason'),
      coalesce(req->>'att_name',''), coalesce(req->>'att_data',''), u.name, u.id, ebda.rk(u), now()::text,
      coalesce((select status from ebda.pay2_sheets where school_id = st.school_id and period = req->>'period'), 'draft'));
    perform ebda.pay2_notify(st.school_id, req->>'period', nid, 'edit_request', array(select w.id from ebda.users w where ebda.rk(w) = 'admin' and coalesce(w.active,'نعم') not like '%لا%'),
      'طلب تعديل شيت المؤثرات: ' || st.name, (f->>1) || ': «' || cur || '» ← «' || (nv->>'v') || '» — ' || btrim(req->>'reason'), u.name);
    insert into ebda.pay2_log values(ebda.uid(), st.school_id, req->>'period', st.id, '_edit_request', cur, nv->>'v', 'request', u.name, u.id, ebda.rk(u), now()::text, 'طلب تعديل «' || (f->>1) || '»: ' || btrim(req->>'reason'));
  elsif md = 'att' then
    select * into x from ebda.pay2_edit_requests where id = req->>'id';
    if x.id is null or not (ebda.rk(u) = 'admin' or x.requested_by_id = u.id or ebda.pay2_view_ok(u, x.school_id)) then return ebda.err('لا صلاحية'); end if;
    return jsonb_build_object('ok', true, 'dataUrl', x.att_data, 'name', x.att_name);
  elsif md in ('approve','reject') then
    if ebda.rk(u) <> 'admin' then return ebda.err('اعتماد/رفض طلبات التعديل للأدمن فقط'); end if;
    select * into x from ebda.pay2_edit_requests where id = req->>'id' for update;
    if x.id is null or x.status <> 'pending' then return ebda.err('الطلب غير موجود أو تمت معالجته'); end if;
    if md = 'reject' then
      if length(btrim(coalesce(req->>'note',''))) < 3 then return ebda.err('اكتب سبب الرفض'); end if;
      update ebda.pay2_edit_requests set status = 'rejected', decided_by = u.name, decided_at = now()::text, decision_note = btrim(req->>'note') where id = x.id;
      perform ebda.pay2_notify(x.school_id, x.period, x.id, 'edit_rejected', array[x.requested_by_id], 'رُفض طلب تعديل: ' || x.emp_name, x.field_label || ' — سبب الرفض: ' || btrim(req->>'note'), u.name);
    else
      select * into st from ebda.pay2_staff where id = x.staff_id;
      sh := coalesce((select status from ebda.pay2_sheets where school_id = x.school_id and period = x.period), 'draft');
      cur := coalesce(ebda.pay2_row(st, x.period)->>x.field, '');
      bef := coalesce((select sum(amount) from ebda.expenses where ref like 'pay2:' || x.school_id || ':' || x.period || ':%' and coalesce(cancelled_at,'') = ''), 0);
      perform set_config('ebda.pay2_force', '1', true);
      r := ebda.pay2_save(u, jsonb_build_object('id', x.staff_id, 'period', x.period, 'patch', jsonb_build_object(x.field, x.proposed_value),
             'reason', 'طلب تعديل معتمد من الأدمن — ' || x.reason));
      perform set_config('ebda.pay2_force', '', true);
      if not coalesce((r->>'ok')::boolean, false) then return r; end if;
      -- أثر التعديل على الموازنة للشهر المعتمد مالياً: إعادة احتساب المصروف المرتبط (تحديث لا تكرار)
      if sh in ('fin_approved','approved') then perform ebda.pay2_post_budget(x.school_id, x.period, sh, u.name); perform ebda.pay2_sync_cost_rows(x.school_id, x.period, sh, u.name); end if;
      aft := coalesce((select sum(amount) from ebda.expenses where ref like 'pay2:' || x.school_id || ':' || x.period || ':%' and coalesce(cancelled_at,'') = ''), 0);
      update ebda.pay2_edit_requests set status = 'approved', decided_by = u.name, decided_at = now()::text, decision_note = btrim(coalesce(req->>'note','')),
             applied_old = cur, applied_new = x.proposed_value,
             budget_effect = case when aft <> bef then 'الخصم من الموازنة: ' || bef || ' ← ' || aft || ' (فرق ' || (aft - bef) || ')' else '' end where id = x.id;
      perform ebda.pay2_notify(x.school_id, x.period, x.id, 'edit_approved', array[x.requested_by_id], 'نُفّذ طلب التعديل: ' || x.emp_name,
        x.field_label || ': «' || cur || '» ← «' || x.proposed_value || '»' || case when aft <> bef then ' — أثر الموازنة: ' || (aft - bef) else '' end, u.name);
    end if;
  elsif md = 'cancel' then
    select * into x from ebda.pay2_edit_requests where id = req->>'id' for update;
    if x.id is null or x.status <> 'pending' or x.requested_by_id <> u.id then return ebda.err('لا يمكن إلغاء هذا الطلب'); end if;
    update ebda.pay2_edit_requests set status = 'cancelled', decided_by = u.name, decided_at = now()::text, decision_note = 'ألغاه مقدم الطلب' where id = x.id;
  end if;
  return jsonb_build_object('ok', true, 'is_admin', ebda.rk(u) = 'admin',
    'requests', coalesce((select jsonb_agg(to_jsonb(q) - 'att_data' || jsonb_build_object('has_att', q.att_data <> '', 'school', (select z.name from ebda.schools z where z.id = q.school_id),
                                         'mine', q.requested_by_id = u.id) order by (q.status = 'pending') desc, q.requested_at desc)
       from ebda.pay2_edit_requests q
      where (ebda.rk(u) = 'admin' or q.requested_by_id = u.id or ebda.pay2_view_ok(u, q.school_id))
        and (coalesce(req->>'school_id','') = '' or q.school_id = req->>'school_id') and (coalesce(req->>'period','') = '' or q.period = req->>'period')
        and (coalesce(req->>'status','') = '' or q.status = req->>'status')), '[]'::jsonb));
end $er$;

-- ======================================================================= v16: (3) تكلفة الموظف الكلية ↔ الموازنة: هوية فريدة لكل موظف/شهر + تقارير
-- أساس التكلفة (قرار الإدارة المالية): after = إجمالى التكلفة بعد الخصومات (الافتراضى) · before = إجمالى التكلفة قبل الخصومات
insert into ebda.config(key, value) values('pay2_cost_basis', 'after') on conflict (key) do nothing;
create table if not exists ebda.pay2_cost_rows(id text primary key, staff_id text not null, school_id text, fy text, period text not null, emp_code text default '', emp_name text default '',
  item text default '', line_id text default '', amount numeric default 0, basis text default '', expense_ref text default '', status text default 'active',
  updated_by text default '', updated_at text default '', note text default '', unique(staff_id, period));
create or replace function ebda.pay2_cost_of(j jsonb, basis text) returns numeric language sql immutable as $$
  select coalesce(
    case when basis = 'after' and coalesce(j->>'cost_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'cost_after')::numeric end,
    case when coalesce(j->>'total_cost','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'total_cost')::numeric end,
    case when coalesce(j->>'net_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_after')::numeric end,
    case when coalesce(j->>'net_salary','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_salary')::numeric end, 0) $$;
create or replace function ebda.pay2_month_amounts(sid text, p text, basis text) returns jsonb language sql stable as $$
  with r as (select ebda.pay2_row(s, p) j from ebda.pay2_staff s where s.school_id = sid and s.fy = ebda.pay2_fy(p) and coalesce(s.active,'نعم') <> 'لا'
               and exists(select 1 from ebda.pay2_effects e where e.staff_id = s.id and e.period = p)),
       a as (select coalesce(nullif(btrim(j->>'budget_item'),''), '') item,
                    case when basis = 'cost' then ebda.pay2_cost_of(j, coalesce((select value from ebda.config where key = 'pay2_cost_basis'), 'after'))
                    else coalesce(case when coalesce(j->>'net_after','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_after')::numeric end,
                                  case when coalesce(j->>'net_salary','') ~ '^-?[0-9]+(\.[0-9]+)?$' then (j->>'net_salary')::numeric end, 0) end amt from r)
  select coalesce(jsonb_agg(jsonb_build_object('item', item, 'amount', s, 'n', n) order by item), '[]'::jsonb)
    from (select item, sum(amt) s, count(*) n from a group by item) x
$$;
-- تسجيل التكلفة: صف لكل موظف/شهر (هوية فريدة) + مصروف واحد لكل بند (المرجع الثابت) — إعادة الاعتماد تحدّث ولا تكرر، والإلغاء موثق
create or replace function ebda.pay2_sync_cost_rows(sid text, p text, st text, by_name text) returns void language plpgsql security definer set search_path = ebda as $sc$
declare s ebda.pay2_staff; j jsonb; b text := coalesce((select value from ebda.config where key = 'pay2_cost_basis'), 'after'); lid text; keep text[] := '{}';
begin
  if st in ('fin_approved','approved') then
    for s in select * from ebda.pay2_staff x where x.school_id = sid and x.fy = ebda.pay2_fy(p) and coalesce(x.active,'نعم') <> 'لا'
               and exists(select 1 from ebda.pay2_effects e where e.staff_id = x.id and e.period = p) loop
      j := ebda.pay2_row(s, p);
      lid := case when coalesce(j->>'budget_item','') = '' then null else ebda.pay2_line_of(sid, j->>'budget_item') end;
      insert into ebda.pay2_cost_rows(id, staff_id, school_id, fy, period, emp_code, emp_name, item, line_id, amount, basis, expense_ref, status, updated_by, updated_at)
      values(ebda.uid(), s.id, sid, s.fy, p, coalesce(nullif(s.emp_uid,''), s.code, ''), s.name, coalesce(j->>'budget_item',''), coalesce(lid,''), ebda.pay2_cost_of(j, b), b,
             case when lid is null then '' else 'pay2:' || sid || ':' || p || ':' || lid end, case when lid is null then 'unlinked' else 'active' end, by_name, now()::text)
      on conflict (staff_id, period) do update set item = excluded.item, line_id = excluded.line_id, amount = excluded.amount, basis = excluded.basis, expense_ref = excluded.expense_ref,
        status = excluded.status, emp_name = excluded.emp_name, updated_by = excluded.updated_by, updated_at = excluded.updated_at, note = '';
      keep := keep || s.id;
    end loop;
  end if;
  update ebda.pay2_cost_rows set status = 'cancelled', updated_by = by_name, updated_at = now()::text,
         note = case when st in ('fin_approved','approved') then 'لم يعد ضمن الشهر المعتمد' else 'أُعيد فتح الشهر — يُسجَّل من جديد عند الاعتماد المالى' end
   where school_id = sid and period = p and status <> 'cancelled' and not (staff_id = any(keep));
end $sc$;
create or replace function ebda.pay2_sheet_budget_trg() returns trigger language plpgsql security definer set search_path = ebda as $t$
declare r jsonb;
begin
  if tg_op = 'UPDATE' and coalesce(new.status,'') is not distinct from coalesce(old.status,'') then return new; end if;
  if not (coalesce(new.status,'') in ('fin_approved','approved') or (tg_op = 'UPDATE' and coalesce(old.status,'') in ('fin_approved','approved'))) then return new; end if;
  r := ebda.pay2_post_budget(new.school_id, new.period, coalesce(new.status,''), coalesce(nullif(new.fin_by,''), 'النظام'));
  perform ebda.pay2_sync_cost_rows(new.school_id, new.period, coalesce(new.status,''), coalesce(nullif(new.fin_by,''), 'النظام'));
  if jsonb_array_length(r->'unlinked') > 0 then
    insert into ebda.pay2_log values(ebda.uid(), new.school_id, new.period, '', '_budget', '', 'رواتب غير مربوطة ببند موازنة: ' ||
      (select string_agg(coalesce(nullif(x->>'item',''),'(بدون بند)') || ' = ' || (x->>'amount'), ' · ') from jsonb_array_elements(r->'unlinked') x), 'budget', 'النظام', '', '', now()::text);
  end if;
  insert into ebda.pay2_log values(ebda.uid(), new.school_id, new.period, '', '_budget', '', case when coalesce(new.status,'') in ('fin_approved','approved')
    then 'تسجيل تكلفة الموظفين على الموازنة: ' || coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(r->'posted') x), 0)
    else 'إلغاء تكلفة الشهر من الموازنة (إعادة فتح) — يُسجَّل عند الاعتماد التالى' end, 'budget', 'النظام', '', '', now()::text);
  return new;
end $t$;

-- تقرير تكلفة الموظفين والموازنة (العام المالى المحدد): لكل بند رواتب بكل جهة · لكل شهر · تفاصيل الموظفين
create or replace function ebda.pay2_cost_report(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $cr$
declare v_fy text := coalesce(nullif(req->>'fy',''), ebda.pay2_fy(to_char(ebda.pay2_today(), 'YYYY-MM'))); p text := coalesce(req->>'period','');
  d0 text; d1 text; near numeric := coalesce(nullif((select value from ebda.config where key = 'near_exhaust_pct'),'')::numeric, 90);
begin
  if not (ebda.rk(u) in ('admin','finance_manager','direct_manager')) then return ebda.err('تقارير تكلفة الموظفين للأدمن والمدير المالى والمدير المباشر'); end if;
  d0 := substr(v_fy,1,4) || '-07-01'; d1 := substr(v_fy,6,4) || '-06-30';
  if p !~ '^\d{4}-\d{2}$' then p := to_char(ebda.pay2_today(), 'YYYY-MM'); end if;
  return jsonb_build_object('ok', true, 'fy', v_fy, 'period', p, 'basis', coalesce((select value from ebda.config where key = 'pay2_cost_basis'), 'after'), 'near_pct', near,
    'lines', coalesce((select jsonb_agg(z order by z->>'school', z->>'name') from (
      select jsonb_build_object('line_id', l.id, 'school_id', l.school_id, 'school', sc.name, 'name', l.name, 'section', l.section, 'allocated', coalesce(l.allocated,0),
        'spent_before', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and e.date >= d0 and e.date < p || '-01'),0),
        'month_payroll', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and substr(e.date,1,7) = p and e.ref like 'pay2:%'),0),
        'month_other', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and substr(e.date,1,7) = p and coalesce(e.ref,'') not like 'pay2:%'),0),
        'spent_fy', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and e.date between d0 and d1),0),
        'payroll_fy', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and e.date between d0 and d1 and e.ref like 'pay2:%'),0),
        'pending_cost', coalesce((select sum(c.amount) from ebda.pay2_cost_rows c where c.line_id = l.id and c.fy = v_fy and c.status = 'active'),0)) z
      from ebda.lines l join ebda.schools sc on sc.id = l.school_id
      where coalesce(l.deleted_at,'') = '' and ebda.can_school(u, l.school_id)
        and (coalesce(req->>'school_id','') = '' or l.school_id = req->>'school_id')
        and (l.catalog_id in (select x from jsonb_array_elements_text((select value::jsonb from ebda.config where key = 'pay2_budget_items')) x)
             or exists(select 1 from ebda.pay2_cost_rows c where c.line_id = l.id) or exists(select 1 from ebda.expenses e where e.line_id = l.id and e.ref like 'pay2:%'))) q), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(jsonb_build_object('school_id', c.school_id, 'school', (select name from ebda.schools where id = c.school_id), 'period', c.period,
                 'amount', c.s, 'n', c.n, 'unlinked', c.un) order by c.school_id, c.period)
       from (select school_id, period, sum(amount) filter (where status = 'active') s, count(*) filter (where status = 'active') n, sum(amount) filter (where status = 'unlinked') un
               from ebda.pay2_cost_rows where pay2_cost_rows.fy = v_fy and status <> 'cancelled' and ebda.can_school(u, school_id) and (coalesce(req->>'school_id','') = '' or school_id = req->>'school_id')
              group by school_id, period) c), '[]'::jsonb),
    'details', case when coalesce(req->>'line_id','') = '' then null else
       coalesce((select jsonb_agg(jsonb_build_object('staff_id', c.staff_id, 'code', c.emp_code, 'name', c.emp_name, 'period', c.period, 'amount', c.amount, 'status', c.status, 'basis', c.basis) order by c.emp_name, c.period)
                  from ebda.pay2_cost_rows c where c.line_id = req->>'line_id' and c.fy = v_fy and c.status <> 'cancelled' and ebda.can_school(u, c.school_id)), '[]'::jsonb) end,
    'unlinked', coalesce((select jsonb_agg(jsonb_build_object('name', c.emp_name, 'item', c.item, 'period', c.period, 'amount', c.amount, 'school', (select name from ebda.schools where id = c.school_id)))
                  from ebda.pay2_cost_rows c where c.fy = v_fy and c.status = 'unlinked' and ebda.can_school(u, c.school_id)), '[]'::jsonb));
end $cr$;

-- ======================================================================= v16: (4) نماذج الاستيراد (مكتبة مركزية بالصلاحيات — من الخادم)
create table if not exists ebda.template_downloads(id text primary key, kind text, school_id text default '', period text default '', user_id text, user_name text, role text, at text);
create or replace function ebda.tpl_allowed(u ebda.users) returns text[] language sql stable as $$
  select case ebda.rk(u)
    when 'admin' then array['effects','signed','budget','needs']
    when 'finance_manager' then array['effects','signed','budget','needs']
    when 'custody_officer' then array['effects','signed','needs']
    when 'direct_manager' then array['effects','signed','needs'] || case when ebda.can(u, 'budget.edit') then array['budget'] else '{}'::text[] end
    else '{}'::text[] end $$;
create or replace function ebda.tpl_api(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $tp$
declare k text := coalesce(req->>'kind',''); al text[] := ebda.tpl_allowed(u); sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period','');
begin
  if coalesce(req->>'mode','list') = 'list' then
    return jsonb_build_object('ok', true, 'allowed', to_jsonb(al),
      'schools', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from ebda.schools s where coalesce(s.cancelled_at,'') = ''
                            and coalesce(s.category,'school') = 'school' and ebda.can_school(u, s.id)), '[]'::jsonb),
      'log', case when ebda.rk(u) = 'admin' then coalesce((select jsonb_agg(to_jsonb(t) order by t.at desc) from (select * from ebda.template_downloads order by at desc limit 50) t), '[]'::jsonb) end);
  end if;
  if not (k = any(al)) then return ebda.err('هذا النموذج غير متاح لصلاحياتك'); end if;
  if k in ('effects','signed') and (sid = '' or not ebda.pay2_view_ok(u, sid)) then return ebda.err('اختر جهة ضمن صلاحياتك'); end if;
  if k = 'budget' and sid <> '' and not ebda.can_school(u, sid) then return ebda.err('الجهة ليست ضمن نطاقك'); end if;
  if k in ('effects','signed') and p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  insert into ebda.template_downloads values(ebda.uid(), k, sid, p, u.id, u.name, ebda.rk(u), now()::text);
  insert into ebda.audit_log(id, ts, actor, actor_role, action, entity, details) values(ebda.uid(), now()::text, u.name, ebda.rk(u), 'templateDownload', 'template:' || k,
    jsonb_build_object('kind', k, 'school_id', sid, 'period', p)::text);
  return jsonb_build_object('ok', true, 'kind', k, 'generated_at', now()::text, 'schema_version', (select value from ebda.config where key = 'schema_version'),
    'fields', case when k in ('effects','signed') then ebda.pay2_fields() end,
    'budget_items', case when k in ('effects','signed') then ebda.pay2_budget_items() end,
    'rows', case when k in ('effects','signed') then (select coalesce(jsonb_agg(ebda.pay2_row(s, p) order by s.sort, s.name), '[]'::jsonb) from ebda.pay2_staff s
                   where s.school_id = sid and s.fy = ebda.pay2_fy(p) and coalesce(s.active,'نعم') <> 'لا') end,
    'school', (select name from ebda.schools where id = sid),
    'lines', case when k = 'budget' and sid <> '' and coalesce(req->>'with_lines','') = '1' then (select coalesce(jsonb_agg(jsonb_build_object('section', l.section, 'name', l.name, 'allocated', l.allocated, 'note', l.note) order by l.section, l.name), '[]'::jsonb)
                   from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and coalesce(l.active,'نعم') <> 'لا') end,
    'sections', case when k = 'budget' then (select coalesce(jsonb_agg(distinct c.section), '[]'::jsonb) from ebda.line_catalog c where coalesce(c.section,'') <> '') end,
    'catalog', case when k in ('budget','needs') then (select coalesce(jsonb_agg(c.name order by c.sort), '[]'::jsonb) from ebda.line_catalog c where coalesce(c.parent_id,'') = '') end,
    'lists', case when k = 'needs' then coalesce((select value::jsonb from ebda.config where key = 'source_lists'), '{}'::jsonb) end,
    'depts', case when k = 'needs' then coalesce((select value::jsonb from ebda.config where key = 'request_depts'), '[]'::jsonb) end);
end $tp$;


-- v10.11: الإلغاء التشغيلى (008) مع حفظ القرار السابق للصنف
create or replace function ebda.bulk_cancel(u ebda.users, p_kind text, p_ids text[], p_reason text, p_commit boolean) returns jsonb
language plpgsql security definer set search_path = ebda as $bc$
declare
  id_ text; ok_rows jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb; amt numeric := 0; budget_fx numeric := 0; cust_fx numeric := 0; recv_fx numeric := 0;
  ex ebda.expenses; c ebda.custodies; cl ebda.custody_lines; ri ebda.request_items; rq ebda.requests; n_e int := 0; v numeric; vb numeric; lbl text; note text;
  rsn text := btrim(coalesce(p_reason,''));
begin
  if p_kind not in ('expenses','custodies','custody_lines','request_items','requests') then return ebda.err('نوع غير معروف'); end if;
  if coalesce(cardinality(p_ids),0) = 0 then return ebda.err('لم يتم تحديد أى سجل'); end if;
  if cardinality(p_ids) > 2000 then return ebda.err('2000 سجل كحد أقصى فى العملية الواحدة'); end if;
  if p_commit and length(rsn) < 3 then return ebda.err('اكتب سبب الإلغاء'); end if;
  foreach id_ in array (select array_agg(distinct x) from unnest(p_ids) x) loop
    if p_kind = 'expenses' then
      select * into ex from ebda.expenses where id = id_;
      if ex.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      lbl := coalesce(ex.txn_no,'') || ' · ' || coalesce(ex.description,'');
      if coalesce(ex.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى بالفعل'); continue; end if;
      note := case ebda.expense_stage(ex) when 'settled' then 'كان مسوّى — يخرج من الموازنة وتبقى بيانات التسوية للمراجعة'
                when 'reviewed' then 'كان معتمداً مالياً — يخرج من الموازنة' when 'pending_finance' then 'كان معتمداً من المدير المباشر' else '' end;
      amt := amt + ex.amount;
      if ebda.counts_in_budget(ex) then budget_fx := budget_fx + ex.amount; end if;
      if ebda.active_on_custody(ex) then cust_fx := cust_fx + ex.amount; end if;
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', ex.amount, 'stage', ebda.expense_stage(ex), 'note', note);
      if p_commit then
        update ebda.expenses set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn, updated_by = u.name, updated_at = now()::text where id = ex.id;
      end if;
    elsif p_kind = 'custodies' then
      select * into c from ebda.custodies where id = id_;
      if c.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجودة'); continue; end if;
      lbl := coalesce(c.code,'') || ' · ' || ebda.custody_name(c.title, c.label, c.code) || ' · ' || ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label);
      if coalesce(c.status,'') = 'cancelled' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغاة بالفعل'); continue; end if;
      v := coalesce((select sum(amount) from ebda.tranches where custody_id = c.id), 0);
      select count(*), coalesce(sum(e.amount) filter (where ebda.counts_in_budget(e)),0), coalesce(sum(e.amount) filter (where ebda.active_on_custody(e)),0)
        into n_e, vb, cust_fx from ebda.expenses e where e.custody_id = c.id and coalesce(e.cancelled_at,'') = '';
      recv_fx := recv_fx + v; budget_fx := budget_fx + vb; amt := amt + v;
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', v, 'expenses', n_e, 'note',
        case when n_e > 0 then 'تُلغى معها ' || n_e || ' عملية مصروف' else '' end);
      if p_commit then
        update ebda.custodies set status = 'cancelled', cancel_reason = rsn, cancelled_by = u.name, cancelled_at = now()::text where id = c.id;
        update ebda.expenses set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = 'ضمن إلغاء العهدة ' || coalesce(c.code,'') || ': ' || rsn,
          updated_by = u.name, updated_at = now()::text where custody_id = c.id and coalesce(cancelled_at,'') = '';
      end if;
    elsif p_kind = 'custody_lines' then
      select * into cl from ebda.custody_lines where id = id_;
      if cl.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      select * into c from ebda.custodies where id = cl.custody_id;
      lbl := coalesce(c.code,'') || ' · ' || coalesce((select name from ebda.lines where id = cl.line_id),'');
      if coalesce(cl.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى بالفعل'); continue; end if;
      if coalesce(c.status,'') = 'cancelled' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'العهدة كلها ملغاة'); continue; end if;
      select count(*), coalesce(sum(e.amount) filter (where ebda.counts_in_budget(e)),0), coalesce(sum(e.amount) filter (where ebda.active_on_custody(e)),0)
        into n_e, vb, v from ebda.expenses e where e.custody_id = cl.custody_id and e.line_id = cl.line_id and coalesce(e.cancelled_at,'') = '';
      budget_fx := budget_fx + vb; cust_fx := cust_fx + v; amt := amt + coalesce(cl.amount,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', coalesce(cl.amount,0), 'expenses', n_e, 'note',
        'البند فقط — العهدة وبقية بنودها كما هى' || case when n_e > 0 then ' · تُلغى ' || n_e || ' عملية مصروف على هذا البند' else '' end);
      if p_commit then
        update ebda.custody_lines set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn where id = cl.id;
        update ebda.expenses set cancelled_at = now()::text, cancelled_by = u.name,
          cancel_reason = 'ضمن إلغاء البند «' || coalesce((select name from ebda.lines where id = cl.line_id),'') || '» من العهدة ' || coalesce(c.code,'') || ': ' || rsn,
          updated_by = u.name, updated_at = now()::text
        where custody_id = cl.custody_id and line_id = cl.line_id and coalesce(cancelled_at,'') = '';
      end if;
    elsif p_kind = 'request_items' then
      select * into ri from ebda.request_items where id = id_;
      if ri.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      select * into rq from ebda.requests where id = ri.request_id;
      lbl := coalesce(rq.req_no,'') || ' · ' || coalesce(ri.name,'');
      if coalesce(ri.decision,'') = 'cancelled' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى بالفعل'); continue; end if;
      if rq.status in ('transferred','spent','settled') then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'الطلب حُوِّل لعهدة — ألغِ المصروف/بند العهدة بدلاً منه'); continue; end if;
      amt := amt + coalesce(ri.amount,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', ri.amount, 'note', 'البند فقط — بقية بنود الطلب كما هى');
      if p_commit then
        update ebda.request_items set cancel_prev_decision = decision, decision = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn where id = ri.id;
        update ebda.requests set total = coalesce((select sum(amount) from ebda.request_items where request_id = rq.id and decision not in ('rejected','deferred','cancelled')),0) where id = rq.id;
        perform ebda.req_event(rq.id, u, 'إلغاء بند: ' || coalesce(ri.name,''), rq.status, rq.status, rsn);
      end if;
    else
      select * into rq from ebda.requests where id = id_;
      if rq.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      lbl := coalesce(rq.req_no,'') || ' · ' || coalesce(rq.requester_name,'');
      if rq.status = 'cancelled' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى بالفعل'); continue; end if;
      if rq.status in ('transferred','spent','settled') then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'الطلب حُوِّل لعهدة — ألغِ العهدة أو مصروفاتها'); continue; end if;
      amt := amt + coalesce(rq.total,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', rq.total, 'note', ebda.req_status_label(rq.status));
      if p_commit then
        update ebda.requests set status = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn where id = rq.id;
        perform ebda.req_event(rq.id, u, 'إلغاء الطلب (الأدمن)', rq.status, 'cancelled', rsn);
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', case when p_commit then 'commit' else 'preview' end, 'kind', p_kind,
    'ok_n', jsonb_array_length(ok_rows), 'skip_n', jsonb_array_length(skip), 'amount', amt,
    'effect', jsonb_build_object('budget_spent', -budget_fx, 'custody_spent', -cust_fx, 'custody_received', -recv_fx),
    'rows', ok_rows, 'skipped', skip);
end $bc$;

-- ============================================================================
--  استيراد المصروفات (008 كما هو)
-- ============================================================================
create or replace function ebda.import_expenses(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $ie$
declare
  urole text := ebda.rk(u);
  commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
  amode text := case when coalesce(req->>'approve_mode','') = 'approved' and ebda.rk(u) = 'admin' then 'approved' else 'workflow' end;
  fname text := left(coalesce(req->>'file_name',''), 200);
  bid text := ebda.uid();
  sch text[] := ebda.scope_arr(u);
  -- v10.1: مسئول العهدة يستورد على عهده هو فقط؛ العهدة الجديدة باسمه وتُرسل للاعتماد (لا اعتماد ذاتى)
  self_only boolean := ebda.rk(u) = 'custody_officer' and ebda.can(u,'custody.import') and not (ebda.can(u,'custody.create') and ebda.can(u,'custody.approve'));
  can_new boolean := (ebda.can(u,'custody.create') and ebda.can(u,'custody.approve')) or (ebda.rk(u) = 'custody_officer' and ebda.can(u,'custody.import'));
  rw jsonb; i int := 0; st text; errs jsonb; warns jsonb;
  sid text; sname text; ckey text; cno text; hold text; cdate text; d text; mth text; fm text;
  amt numeric; camt numeric; cid text; ccode text; cnew boolean;
  cust ebda.custodies; lid text; lname text; m_ text; s_ text; n int; k text; dupof text;
  hu ebda.users; newid text; dkey text; extra text;
  cmap jsonb := '{}'::jsonb;    -- مفتاح العهدة ← بياناتها (موجودة/جديدة)
  lmap jsonb := '{}'::jsonb;    -- (مدرسة|رئيسى|فرعى) ← البند
  smap jsonb := '{}'::jsonb;    -- اسم المدرسة ← id
  seen text[] := '{}';
  out jsonb := '[]'::jsonb;
  c_ok int := 0; c_warn int := 0; c_dup int := 0; c_err int := 0; tot numeric := 0;
  months jsonb := '{}'::jsonb; lamt jsonb := '{}'::jsonb; camts jsonb := '{}'::jsonb;
  cinfo jsonb; linfo jsonb; res jsonb; exc jsonb;
begin
  if not (urole = 'admin' or ebda.can(u,'expense.import')) then return ebda.err('صلاحية استيراد المصروفات مطلوبة'); end if;
  if jsonb_typeof(coalesce(req->'rows','null'::jsonb)) <> 'array' or jsonb_array_length(req->'rows') = 0 then
    return ebda.err('لم يُتعرَّف على أى صف مصروفات فى الملف'); end if;
  if jsonb_array_length(req->'rows') > 20000 then return ebda.err('الملف أكبر من 20,000 صف — قسّمه إلى أكثر من ملف'); end if;

  for rw in select * from jsonb_array_elements(req->'rows') loop
    i := i + 1; errs := '[]'::jsonb; st := 'ok';
    warns := case when jsonb_typeof(rw->'warnings') = 'array' then rw->'warnings' else '[]'::jsonb end;
    sid := null; sname := ''; cid := null; ccode := ''; cnew := false; lid := null; lname := ''; amt := null; dupof := null; mth := '';
    ckey := null; cinfo := null; linfo := null; d := '';

    -- ---------------------------------------------------------- 1) المدرسة
    if coalesce(rw->>'school_id','') <> '' and exists(select 1 from ebda.schools s where s.id = rw->>'school_id') then
      sid := rw->>'school_id';
    elsif btrim(coalesce(rw->>'school','')) <> '' then
      k := ebda.norm_txt(rw->>'school');
      if smap ? k then sid := smap->>k;
      else
        select min(s.id), count(*) into sid, n from ebda.schools s where ebda.norm_txt(s.name) = k;
        if n <> 1 then
          select min(s.id), count(*) into sid, n from ebda.schools s
           where length(k) >= 3 and (ebda.norm_txt(s.name) like '%'||k||'%' or k like '%'||ebda.norm_txt(s.name)||'%');
        end if;
        if n <> 1 then sid := null; end if;
        smap := smap || jsonb_build_object(k, sid);
      end if;
      if sid is null then errs := errs || to_jsonb('المدرسة غير معروفة: '||btrim(rw->>'school')); end if;
    elsif urole <> 'admin' and coalesce(u.schools,'') <> '*' and cardinality(sch) = 1 then
      sid := sch[1]; warns := warns || to_jsonb('المدرسة غير مذكورة فى الملف — استُخدم مكانك'::text);
    else
      errs := errs || to_jsonb('المدرسة غير محددة'::text);
    end if;
    if sid is not null and not ebda.can_school(u, sid) then errs := errs || to_jsonb('المدرسة ليست ضمن نطاقك'::text); sid := null; end if;
    if sid is not null then select s.name into sname from ebda.schools s where s.id = sid; end if;

    -- ---------------------------------------------------------- 2) القيمة والتاريخ والشهر
    amt := ebda.imp_num(rw->>'amount');
    if amt is null or amt <= 0 then errs := errs || to_jsonb('قيمة المصروف غير صحيحة: '||coalesce(nullif(rw->>'amount',''),'فارغة')); end if;
    d := btrim(coalesce(rw->>'date',''));
    if not ebda.imp_date_ok(d) then
      errs := errs || to_jsonb('تاريخ المصروف غير صحيح: '||coalesce(nullif(rw->>'date_raw',''), nullif(d,''), 'فارغ'));
    elsif d > to_char(now() + interval '1 day','YYYY-MM-DD') then
      -- غالباً اليوم والشهر مقلوبان فى Excel (12/09 ← 09/12): نقترح التاريخ الصحيح
      errs := errs || to_jsonb('تاريخ المصروف فى المستقبل: '||d||
        case when substr(d,9,2)::int <= 12 and ebda.imp_date_ok(substr(d,1,4)||'-'||substr(d,9,2)||'-'||substr(d,6,2))
                  and substr(d,1,4)||'-'||substr(d,9,2)||'-'||substr(d,6,2) <= to_char(now(),'YYYY-MM-DD')
             then ' (ربما المقصود '||substr(d,1,4)||'-'||substr(d,9,2)||'-'||substr(d,6,2)||' — اليوم والشهر مقلوبان)' else '' end);
    else
      mth := substr(d,1,7);
      fm := btrim(coalesce(rw->>'month',''));
      if fm ~ '^\d{1,2}$' and fm::int <> substr(d,6,2)::int then
        warns := warns || to_jsonb('الشهر فى الملف ('||fm||') لا يطابق تاريخ المصروف — اعتُمد شهر التاريخ');
      elsif fm ~ '^\d{4}-\d{2}$' and fm <> mth then
        warns := warns || to_jsonb('الشهر فى الملف ('||fm||') لا يطابق تاريخ المصروف — اعتُمد شهر التاريخ');
      end if;
    end if;

    -- مصروف خارج السنة المالية لموازنة المدرسة (سبتمبر ← أغسطس): يُستورد على العهدة لكنه لا يدخل فى منصرف موازنة السنة الحالية
    if sid is not null and mth <> '' and exists(select 1 from ebda.schools s where s.id = sid and coalesce(s.period,'') ~ '\d{4}'
         and ebda.exp_fy(d) <> ebda.period_fy(s.period)) then
      warns := warns || to_jsonb('التاريخ خارج السنة المالية للموازنة ('||(select s.period from ebda.schools s where s.id = sid)||') — لن يظهر فى منصرف موازنة هذه السنة');
    end if;

    -- ---------------------------------------------------------- 3) العهدة (موجودة أو تُنشأ)
    cno := btrim(translate(coalesce(rw->>'custody_no',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'));
    hold := btrim(regexp_replace(coalesce(rw->>'holder',''), '\s+', ' ', 'g'));
    if self_only and hold = '' and cno = '' then hold := u.name; end if;   -- مسئول العهدة: على عهدته هو
    cdate := btrim(coalesce(rw->>'custody_date',''));
    camt := case when btrim(coalesce(rw->>'custody_amount','')) = '' then null else ebda.imp_num(rw->>'custody_amount') end;
    if btrim(coalesce(rw->>'custody_amount','')) <> '' and (camt is null or camt < 0) then
      errs := errs || to_jsonb('قيمة العهدة غير صحيحة: '||(rw->>'custody_amount')); end if;
    if cdate <> '' and not ebda.imp_date_ok(cdate) then
      warns := warns || to_jsonb('تاريخ العهدة غير مفهوم: '||coalesce(nullif(rw->>'custody_date_raw',''), cdate)); cdate := ''; end if;
    if sid is not null then
      if cno = '' and hold = '' then
        errs := errs || to_jsonb('رقم العهدة ومسئول العهدة غير موجودين'::text);
      else
        ckey := sid || '|' || case when cno <> '' then 'n:'||upper(cno) else 'h:'||ebda.norm_txt(hold) end;
        if cmap ? ckey then
          cinfo := cmap->ckey;
        else
          cust := null;
          if cno <> '' then
            select * into cust from ebda.custodies c where c.school_id = sid and c.ext_ref = cno and coalesce(c.status,'') <> 'cancelled'
              order by c.opened_at desc limit 1;
            if cust.id is null then
              select * into cust from ebda.custodies c where upper(c.code) = upper(cno) limit 1;
            end if;
          else
            select * into cust from ebda.custodies c where c.school_id = sid and coalesce(c.status,'open') in ('open','pending_settlement')
              and (ebda.norm_txt(ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label)) = ebda.norm_txt(hold)
                   or (coalesce(c.holder,'') <> '' and ebda.norm_txt(c.holder) = ebda.norm_txt(hold))) order by c.opened_at desc limit 1;
          end if;
          if cust.id is not null then
            cinfo := jsonb_build_object('id', cust.id, 'code', cust.code, 'new', false, 'school_id', cust.school_id,
              'holder', ebda.person_name(cust.user_id, cust.holder_emp_id, cust.holder, cust.label), 'holder_text', coalesce(cust.holder,''), 'status', coalesce(cust.status,'open'),
              'approval', coalesce(cust.approval,'approved'), 'user_id', coalesce(cust.user_id,''), 'user', coalesce(cust."user",''),
              'received', (select coalesce(sum(t.amount),0) from ebda.tranches t where t.custody_id = cust.id),
              'spent', (select coalesce(sum(e.amount),0) from ebda.expenses e where e.custody_id = cust.id and ebda.active_on_custody(e)),
              'restricted', exists(select 1 from ebda.custody_lines cl where cl.custody_id = cust.id and coalesce(cl.cancelled_at,'') = ''),
              'ext_ref', cno, 'file_amount', camt, 'warn_holder', '');
          else
            hu := null; k := '';
            if hold <> '' then
              select * into hu from ebda.users z where coalesce(z.active,'نعم') like '%نعم%' and ebda.norm_txt(z.name) = ebda.norm_txt(hold)
                and (coalesce(z.schools,'') = '*' or sid = any(ebda.scope_arr(z)))
                order by case when ebda.rk(z) = 'custody_officer' then 0 else 1 end limit 1;
            else
              -- الملف لا يذكر المسئول (ورقة لكل عهدة): يُربط بمسئول العهدة الوحيد فى المدرسة إن وُجد، وإلا تُنشأ باسم الورقة
              select count(*) into n from ebda.users z where coalesce(z.active,'نعم') like '%نعم%' and ebda.rk(z) = 'custody_officer'
                and coalesce(z.schools,'') <> '*' and sid = any(ebda.scope_arr(z));
              if n = 1 then
                select * into hu from ebda.users z where coalesce(z.active,'نعم') like '%نعم%' and ebda.rk(z) = 'custody_officer'
                  and coalesce(z.schools,'') <> '*' and sid = any(ebda.scope_arr(z));
                k := 'مسئول العهدة غير مذكور فى الملف — رُبطت العهدة بمسئول العهدة الوحيد فى المدرسة: '||hu.name;
              else
                k := 'مسئول العهدة غير مذكور فى الملف — أُنشئت العهدة «'||cno||'» بدون مسئول؛ حدّده من شاشة العهد';
              end if;
            end if;
            if self_only then hu := u; k := ''; end if;
            cinfo := jsonb_build_object('id', null, 'code', '', 'new', true, 'school_id', sid,
              'holder', coalesce(nullif(hold,''), hu.name, ''), 'cname', btrim(coalesce(rw->>'custody_name','')), 'auto_note', k, 'note', left(coalesce(rw->>'custody_note',''), 1000), 'status', 'open', 'approval', 'approved',
              'user_id', coalesce(hu.id,''), 'user', coalesce(hu.username,''), 'received', coalesce(camt,0), 'spent', 0, 'restricted', false,
              'ext_ref', cno, 'file_amount', camt, 'date', cdate, 'first_date', d);
          end if;
          cmap := cmap || jsonb_build_object(ckey, cinfo);
        end if;

        if (cinfo->>'new')::boolean then
          cnew := true;
          if not can_new then errs := errs || to_jsonb('العهدة '||coalesce(nullif(cno,''), hold)||' غير موجودة ولا تملك صلاحية إنشاء واعتماد العهد'); end if;
          if self_only and hold <> '' and ebda.norm_txt(hold) <> ebda.norm_txt(u.name) then
            errs := errs || to_jsonb('العهدة باسم مسئول آخر ('||hold||') — يمكنك استيراد عهدك أنت فقط'); end if;
          if self_only and not (cinfo ? 'warned_self') then
            warns := warns || to_jsonb('عهدة جديدة باسمك — تُرسل للاعتماد (المدير المالى) ولا تُعتمد تلقائياً'::text);
            cinfo := cinfo || '{"warned_self":true}'::jsonb; cmap := cmap || jsonb_build_object(ckey, cinfo);
          end if;
          if hold <> '' and ebda.norm_txt(hold) <> ebda.norm_txt(cinfo->>'holder') then
            warns := warns || to_jsonb('نفس رقم العهدة بمسئول مختلف فى الملف ('||hold||') — اعتُمد '||(cinfo->>'holder')); end if;
          if camt is not null and cinfo->>'file_amount' is not null and camt <> (cinfo->>'file_amount')::numeric then
            warns := warns || to_jsonb('قيمة العهدة تختلف بين صفوف الملف — اعتُمدت '||(cinfo->>'file_amount')); end if;
          if (cinfo->>'file_amount') is null and camt is not null then
            cinfo := cinfo || jsonb_build_object('file_amount', camt, 'received', camt); cmap := cmap || jsonb_build_object(ckey, cinfo); end if;
          if coalesce(cinfo->>'date','') = '' and cdate <> '' then
            cinfo := cinfo || jsonb_build_object('date', cdate); cmap := cmap || jsonb_build_object(ckey, cinfo); end if;
          if coalesce(cinfo->>'auto_note','') <> '' and not (cinfo ? 'warned_user') then
            warns := warns || to_jsonb(cinfo->>'auto_note');
            cinfo := cinfo || '{"warned_user":true}'::jsonb; cmap := cmap || jsonb_build_object(ckey, cinfo);
          end if;
          if coalesce(cinfo->>'user_id','') = '' and coalesce(cinfo->>'holder','') <> '' and not (cinfo ? 'warned_user') then
            warns := warns || to_jsonb('مسئول العهدة «'||(cinfo->>'holder')||'» غير مسجل كمستخدم — ستُنشأ العهدة باسمه بدون حساب دخول (اربطه لاحقاً)');
            cinfo := cinfo || '{"warned_user":true}'::jsonb; cmap := cmap || jsonb_build_object(ckey, cinfo);
          end if;
        else
          cid := cinfo->>'id'; ccode := cinfo->>'code';
          if cinfo->>'school_id' <> sid then errs := errs || to_jsonb('رقم العهدة '||cno||' تابع لمدرسة أخرى'); end if;
          if cinfo->>'status' in ('settled','closed') then errs := errs || to_jsonb('العهدة '||ccode||' مسوّاة/مغلقة'); end if;
          if cinfo->>'status' = 'cancelled' then errs := errs || to_jsonb('العهدة '||ccode||' ملغاة'); end if;
          if cinfo->>'approval' <> 'approved' then errs := errs || to_jsonb('العهدة '||ccode||' لم تُعتمد بعد'); end if;
          if urole not in ('admin','finance_manager') and coalesce(cinfo->>'user_id','') <> u.id and coalesce(cinfo->>'user','') <> u.username then
            errs := errs || to_jsonb('العهدة '||ccode||' ليست عهدتك'); end if;
          if hold <> '' and ebda.norm_txt(hold) <> ebda.norm_txt(cinfo->>'holder') and ebda.norm_txt(hold) <> ebda.norm_txt(coalesce(cinfo->>'holder_text','')) then
            warns := warns || to_jsonb('اسم المسئول فى الملف ('||hold||') يختلف عن المسجل ('||(cinfo->>'holder')||')'); end if;
          if camt is not null and abs(camt - (cinfo->>'received')::numeric) > 0.5 then
            warns := warns || to_jsonb('قيمة العهدة فى الملف ('||camt||') تختلف عن المسجلة ('||(cinfo->>'received')||') — لم تُعدَّل'); end if;
        end if;
      end if;
    end if;

    -- ---------------------------------------------------------- 4) البند (رئيسى ← فرعى) من موازنة المدرسة
    m_ := ebda.norm_txt(rw->>'main'); s_ := ebda.norm_txt(rw->>'sub');
    if sid is not null then
      if m_ = '' and s_ = '' then
        errs := errs || to_jsonb('البند غير مذكور'::text);
      else
        k := sid || '|' || m_ || '|' || s_;
        if lmap ? k then linfo := lmap->k;
        else
          linfo := null;
          declare cand text[]; how text := '';
          begin
            -- v8: البند الموحد (الاسم المعتمد أو المسمى القديم) ← بند الجهة
            cand := array(select x from (select ebda.school_line_for(sid, ebda.catalog_resolve(coalesce(nullif(s_,''), m_))) x) q where x is not null);
            if cardinality(cand) = 0 and s_ <> '' and m_ <> '' then
              cand := array(select x from (select ebda.school_line_for(sid, ebda.catalog_resolve(m_)) x) q where x is not null);
            end if;
            if cardinality(cand) = 1 then null;
            elsif s_ <> '' then
              cand := array(select l.id from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and ebda.norm_txt(l.name) = s_
                              and (m_ = '' or ebda.norm_txt(l.section) = m_));
              if cardinality(cand) = 0 and m_ <> '' then
                cand := array(select l.id from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and ebda.norm_txt(l.name) = s_);
                if cardinality(cand) = 1 then how := 'section'; end if;
              end if;
              if cardinality(cand) = 0 then
                cand := array(select l.id from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and length(s_) >= 3
                                and (ebda.norm_txt(l.name) like '%'||s_||'%' or s_ like '%'||ebda.norm_txt(l.name)||'%')
                                and (m_ = '' or ebda.norm_txt(l.section) = m_ or ebda.norm_txt(l.section) like '%'||m_||'%'));
                if cardinality(cand) = 1 then how := 'approx'; end if;
              end if;
            else
              cand := array(select l.id from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and ebda.norm_txt(l.name) = m_);
              if cardinality(cand) = 0 then
                cand := array(select l.id from ebda.lines l where l.school_id = sid and coalesce(l.deleted_at,'') = '' and ebda.norm_txt(l.section) = m_);
                if cardinality(cand) > 1 then cand := '{}'; how := 'many'; end if;
              end if;
            end if;
            if cardinality(cand) = 1 then
              select jsonb_build_object('id', l.id, 'name', l.name, 'section', coalesce(l.section,''), 'active', coalesce(l.active,'نعم') like '%نعم%', 'how', how)
                into linfo from ebda.lines l where l.id = cand[1];
            else
              linfo := jsonb_build_object('id', null, 'many', cardinality(cand) > 1 or how = 'many');
            end if;
          end;
          lmap := lmap || jsonb_build_object(k, linfo);
        end if;
        if linfo->>'id' is null then
          errs := errs || to_jsonb(case when (linfo->>'many')::boolean then 'البند يطابق أكثر من بند فى موازنة المدرسة — حدّد البند الفرعى: '
                                        else 'بند غير معروف فى موازنة المدرسة: ' end
                                   || concat_ws(' / ', nullif(btrim(rw->>'main'),''), nullif(btrim(rw->>'sub'),'')));
        else
          lid := linfo->>'id'; lname := linfo->>'name';
          if not (linfo->>'active')::boolean then errs := errs || to_jsonb('البند معطّل — لا يقبل مصروفات: '||lname); end if;
          if linfo->>'how' = 'section' then warns := warns || to_jsonb('البند الرئيسى فى الملف يختلف عن قسم البند فى الموازنة ('||(linfo->>'section')||')'); end if;
          if linfo->>'how' = 'approx' then warns := warns || to_jsonb('طوبق البند تقريبياً: «'||btrim(coalesce(rw->>'sub',''))||'» ← «'||lname||'»'); end if;
          if cid is not null and (cinfo->>'restricted')::boolean
             and not exists(select 1 from ebda.custody_lines cl where cl.custody_id = cid and cl.line_id = lid and coalesce(cl.cancelled_at,'') = '') then
            errs := errs || to_jsonb('البند «'||lname||'» غير مخصص للعهدة '||ccode); end if;
        end if;
      end if;
    end if;

    -- ---------------------------------------------------------- 5) التكرار (داخل الملف أو مسجل من قبل)
    if jsonb_array_length(errs) = 0 then
      dkey := coalesce(ckey,'') || '|' || d || '|' || amt::text || '|' ||
              case when ebda.norm_txt(rw->>'doc_no') <> '' then 'doc:'||ebda.norm_txt(rw->>'doc_no') else 'txt:'||ebda.norm_txt(rw->>'description') end;
      if dkey = any(seen) then
        st := 'duplicate'; dupof := 'مكرر داخل الملف (نفس العهدة والتاريخ والقيمة والمستند/الوصف)';
      elsif cid is not null then
        select e.txn_no into k from ebda.expenses e
         where e.custody_id = cid and e.date = d and e.amount = amt and coalesce(e.cancelled_at,'') = ''
           and case when ebda.norm_txt(rw->>'doc_no') <> '' then ebda.norm_txt(e.doc_no) = ebda.norm_txt(rw->>'doc_no')
                         or (coalesce(e.doc_no,'') = '' and ebda.norm_txt(e.description) = ebda.norm_txt(rw->>'description'))
                    else ebda.norm_txt(e.description) = ebda.norm_txt(rw->>'description') end
         limit 1;
        if k is not null then st := 'duplicate'; dupof := 'مسجل من قبل ('||k||')'; end if;
      end if;
      seen := seen || dkey;
    end if;

    if jsonb_array_length(errs) > 0 then st := 'error'; c_err := c_err + 1;
    elsif st = 'duplicate' then c_dup := c_dup + 1;
    else
      if jsonb_array_length(warns) > 0 then st := 'warning'; c_warn := c_warn + 1; else c_ok := c_ok + 1; end if;
      tot := tot + amt;
      months := months || jsonb_build_object(mth, coalesce((months->>mth)::numeric,0) + amt);
      lamt := lamt || jsonb_build_object(lid, coalesce((lamt->>lid)::numeric,0) + amt);
      camts := camts || jsonb_build_object(ckey, coalesce((camts->>ckey)::numeric,0) + amt);
    end if;

    -- ---------------------------------------------------------- 6) التنفيذ (عند التأكيد فقط)
    newid := null;
    if commit_ and st in ('ok','warning') then
      cinfo := cmap->ckey;
      if (cinfo->>'new')::boolean and cinfo->>'id' is null then
        cid := ebda.uid();
        insert into ebda.custodies(id,label,holder,school_id,note,"user",code,status,opened_at,kind,purpose)
        values(cid, 'عهدة '||coalesce(nullif(cinfo->>'holder',''), cinfo->>'ext_ref', ''), coalesce(cinfo->>'holder',''), sid,
               concat_ws(' · ', 'أُنشئت تلقائياً من استيراد ملف المصروفات: '||fname, nullif(cinfo->>'note','')),
               cinfo->>'user', 'CUST-'||lpad(nextval('ebda.seq_cust')::text,3,'0'), 'open',
               coalesce(nullif(cinfo->>'date',''), cinfo->>'first_date', to_char(now(),'YYYY-MM-DD')),
               coalesce(req->>'custody_kind',''), '');
        update ebda.custodies set user_id = coalesce(cinfo->>'user_id',''),
          approval = case when self_only then 'review' else 'approved' end, approved_by = case when self_only then '' else u.name end,
          approved_at = case when self_only then '' else now()::text end, submitted_by = case when self_only then u.name else submitted_by end,
          ext_ref = coalesce(cinfo->>'ext_ref',''), import_batch = bid,
          -- اسم العهدة: من الملف (ورقة العهدة نفسها أو عمود «اسم العهدة»)، وإلا اسمها الافتراضى
          title = coalesce(nullif(cinfo->>'cname',''), nullif(req->>'custody_title',''), case when coalesce(cinfo->>'holder','') = '' then coalesce(cinfo->>'ext_ref','') else '' end)
        where id = cid;
        if coalesce((cinfo->>'file_amount')::numeric, 0) > 0 then
          insert into ebda.tranches(id,custody_id,date,amount,note)
          values(ebda.uid(), cid, coalesce(nullif(cinfo->>'date',''), cinfo->>'first_date', to_char(now(),'YYYY-MM-DD')),
                 (cinfo->>'file_amount')::numeric, 'القيمة الأساسية للعهدة (من ملف الاستيراد)');
        end if;
        select code into ccode from ebda.custodies where id = cid;
        cinfo := cinfo || jsonb_build_object('id', cid, 'code', ccode);
        cmap := cmap || jsonb_build_object(ckey, cinfo);
      end if;
      cid := cinfo->>'id'; ccode := cinfo->>'code';
      -- v10.7: رابط مجلد مستندات العهدة (الصف الأول فى ملف المصروفات)
      if coalesce(btrim(rw->>'doc_folder'),'') ~* '^https?://' then
        update ebda.custodies set doc_folder = btrim(rw->>'doc_folder') where id = cid and coalesce(doc_folder,'') = '';
      end if;
      extra := (select string_agg(key||': '||value, ' · ') from jsonb_each_text(coalesce(rw->'extra','{}'::jsonb)) where btrim(value) <> '');
      newid := ebda.uid();
      insert into ebda.expenses(id,date,school_id,custody_id,line_id,spend_item,description,amount,approval,approved_by,doc_url,doc_name,
         review_status,review_note,settled,ref,note,created_by,created_at,txn_no)
      values(newid, d, sid, cid, lid, '', coalesce(nullif(btrim(rw->>'description'),''), lname), amt,
         case when amode = 'approved' then 'approved' else 'pending' end, case when amode = 'approved' then u.name else '' end, '', '',
         '', '', '', coalesce(rw->>'doc_no',''),
         concat_ws(' · ', 'مستورد من ملف'||case when fname <> '' then ' «'||fname||'»' else '' end||' — '||coalesce(rw->>'r', 'صف '||i), extra),
         u.name, now()::text, 'EXP-'||lpad(nextval('ebda.seq_exp')::text,5,'0'));
      update ebda.expenses set pay_method = coalesce(rw->>'pay_method',''), created_by_id = u.id, supplier = coalesce(rw->>'supplier',''),
        doc_no = coalesce(rw->>'doc_no',''), import_batch = bid, import_row = coalesce(rw->>'r', i::text),
        submitted_at = now()::text,
        approved_by_id = case when amode = 'approved' then u.id else '' end,
        approved_at = case when amode = 'approved' then now()::text else '' end,
        approval_note = case when amode = 'approved' then 'معتمد بالاستيراد (بيانات فعلية)' else '' end,
        fin_approval = case when amode = 'approved' then 'approved' else coalesce(fin_approval,'') end,
        fin_by = case when amode = 'approved' then u.name else coalesce(fin_by,'') end,
        fin_by_id = case when amode = 'approved' then u.id else coalesce(fin_by_id,'') end,
        fin_at = case when amode = 'approved' then now()::text else coalesce(fin_at,'') end,
        doc_url = case when coalesce(btrim(rw->>'doc_link'),'') ~* '^https?://' then btrim(rw->>'doc_link') else '' end,
        doc_is_link = case when coalesce(btrim(rw->>'doc_link'),'') ~* '^https?://' then 'نعم' else '' end,
        doc_name = case when coalesce(btrim(rw->>'doc_link'),'') ~* '^https?://' then coalesce(nullif(rw->>'doc_no',''),'رابط مستند') else '' end,
        gm_approval = '',
        gm_note = case when ebda.can_gm(u) then coalesce(btrim(rw->>'gm_note'),'') else '' end,
        gm_by = case when ebda.can_gm(u) and coalesce(btrim(rw->>'gm_note'),'') <> '' then u.name else '' end,
        gm_at = case when ebda.can_gm(u) and coalesce(btrim(rw->>'gm_note'),'') <> '' then now()::text else '' end,
        -- v10.3: علامات الصح فى الملف تُحفظ كمعلومة فقط — الاعتماد من الجدول بواسطة صاحبه
        file_gm_ok = case when ebda.truthy(rw->>'gm_review') then 'نعم' else '' end,
        file_fin_ok = case when ebda.truthy(rw->>'fin_ok') then 'نعم' else '' end,
        file_gm_note = case when not ebda.can_gm(u) then coalesce(btrim(rw->>'gm_note'),'') else '' end,
        src_item = coalesce(rw->>'src_item',''), src_suggested = coalesce(rw->>'src_suggested',''), src_holder = coalesce(rw->>'src_holder',''),
        src_seq = coalesce(rw->>'src_seq',''), src_balance = coalesce(rw->>'src_balance',''), src_doc = coalesce(rw->>'src_doc',''), src_sheet = coalesce(rw->>'sheet',''),
        src_row = case when jsonb_typeof(rw->'orig_h') = 'array' then jsonb_build_object('h', rw->'orig_h', 'v', rw->'orig_v', 'sheet', coalesce(rw->>'sheet',''), 'row', coalesce(rw->>'r','')) end,
        category = coalesce(btrim(rw->>'category'),''),
        doc_ref = case when coalesce(btrim(rw->>'doc_link'),'') = '' and coalesce(rw->>'src_doc','') in ('نعم','true','✓')
                        and coalesce(btrim(rw->>'doc_folder'),'') <> '' then 'folder_review' else '' end
      where id = newid;
    end if;

    -- v10: أعمدة الاعتمادات فى الملف تُطبَّق حسب صلاحية من يستورد فقط
    if ebda.truthy(rw->>'gm_review') or ebda.truthy(rw->>'fin_ok') then
      warns := warns || to_jsonb('علامات الاعتماد فى الملف تُحفظ كمعلومة فقط — الاعتماد من جدول العهدة بواسطة المدير العام / المدير المالى'::text); end if;
    out := out || jsonb_build_object('i', i, 'r', coalesce(rw->>'r',''), 'status', st, 'errors', errs, 'warnings', warns, 'duplicate_of', dupof,
      'school_id', sid, 'school', coalesce(sname, rw->>'school', ''), 'custody', case when cnew and not commit_ then 'جديدة' else coalesce(ccode, cmap#>>array[ckey,'code'], '') end,
      'custody_no', cno, 'custody_new', cnew, 'holder', coalesce(cmap#>>array[ckey,'holder'], hold), 'line_id', lid, 'line', lname,
      'main', coalesce(rw->>'main',''), 'sub', coalesce(rw->>'sub',''), 'date', d, 'month', mth, 'amount', amt,
      'description', coalesce(rw->>'description',''), 'supplier', coalesce(rw->>'supplier',''), 'doc_no', coalesce(rw->>'doc_no',''),
      'expense_id', newid);
  end loop;

  -- ---------------------------------------------------------- أثر الاستيراد على الموازنة والعهد
  res := jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'approve_mode', amode,
    'summary', jsonb_build_object('rows', i, 'ok', c_ok, 'warning', c_warn, 'duplicate', c_dup, 'error', c_err,
       'importable', c_ok + c_warn, 'amount', tot, 'months', months,
       'new_custodies', (select count(*) from jsonb_each(cmap) x where (x.value->>'new')::boolean and camts ? x.key),
       'existing_custodies', (select count(*) from jsonb_each(cmap) x where not (x.value->>'new')::boolean and camts ? x.key),
       'schools', (select count(distinct split_part(x.key,'|',1)) from jsonb_each(camts) x)),
    'rows', out,
    'custodies', coalesce((select jsonb_agg(jsonb_build_object('key', x.key, 'code', coalesce(x.value->>'code',''), 'new', (x.value->>'new')::boolean,
        'ext_ref', x.value->>'ext_ref', 'holder', x.value->>'holder', 'linked_user', coalesce(x.value->>'user_id','') <> '',
        'school', (select s.name from ebda.schools s where s.id = x.value->>'school_id'),
        'received', (x.value->>'received')::numeric, 'spent_before', (x.value->>'spent')::numeric,
        'imported', coalesce((camts->>x.key)::numeric, 0),
        'remaining_after', (x.value->>'received')::numeric - (x.value->>'spent')::numeric - coalesce((camts->>x.key)::numeric, 0))
        order by x.value->>'holder')
      from jsonb_each(cmap) x where camts ? x.key), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(z order by z->>'school', z->>'section', z->>'line') from (
        select jsonb_build_object('line_id', l.id, 'line', l.name, 'section', coalesce(l.section,''), 'school', s.name,
          'allocated', coalesce(l.allocated,0), 'actual_before', p.pre, 'imported', p.imp, 'counts_now', amode = 'approved',
          'actual_after', p.pre + p.addv, 'remaining_after', coalesce(l.allocated,0) - p.pre - p.addv,
          'pct_after', case when coalesce(l.allocated,0) > 0 then round(100 * (p.pre + p.addv) / l.allocated, 1) end,
          'state', ebda.budget_state(l.allocated, p.pre + p.addv)) z
        from ebda.lines l join ebda.schools s on s.id = l.school_id
        cross join lateral (select coalesce(sum(a.amount),0) spent from ebda.agg_line_month a
                            where a.line_id = l.id and (coalesce(s.period,'') !~ '\d{4}' or a.fy = ebda.period_fy(s.period))) b
        cross join lateral (select (lamt->>l.id)::numeric imp) m
        -- بعد التنفيذ يكون التجميع قد شمل المصروفات المعتمدة بالفعل؛ فيُطرح للحصول على «قبل»
        cross join lateral (select b.spent - case when amode = 'approved' and commit_ then m.imp else 0 end pre,
                                   case when amode = 'approved' then m.imp else 0 end addv, m.imp imp) p
        where lamt ? l.id) q), '[]'::jsonb));

  if commit_ then
    exc := coalesce((select jsonb_agg(x) from jsonb_array_elements(out) x where x->>'status' in ('error','duplicate','warning')), '[]'::jsonb);
    insert into ebda.import_batches(id,kind,file_name,actor,actor_id,approve_mode,rows_n,imported_n,amount,summary,exceptions)
    values(bid, 'expenses', fname, u.name, u.id, amode, i, c_ok + c_warn, tot, res->'summary', exc);
    res := res || jsonb_build_object('batch_id', bid);
  end if;
  return res;
end $ie$;

select 'الجزء 12 من 15 تم ✓ — شغّل الجزء 13' as result;
