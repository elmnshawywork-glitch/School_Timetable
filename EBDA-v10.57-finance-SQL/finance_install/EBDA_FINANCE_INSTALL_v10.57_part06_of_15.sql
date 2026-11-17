-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 6 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;

-- خريطة الربط الحالية: كل بند جهة ← البند الموحد + المكرر داخل الجهة (للمراجعة قبل الدمج)
create or replace function ebda.line_mapping(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $lm$
  with sl as (
    select l.*, s.name s_name from ebda.lines l join ebda.schools s on s.id = l.school_id
    where coalesce(l.deleted_at,'') = '' and (ebda.role_key(u.role) = 'admin' or coalesce(u.schools,'') = '*' or l.school_id = any(ebda.scope_arr(u))))
  select jsonb_build_object('ok', true,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('line_id', sl.id, 'school_id', sl.school_id, 'school', sl.s_name,
        'name', sl.name, 'legacy_name', coalesce(sl.legacy_name,''), 'catalog_id', sl.catalog_id, 'main_id', ebda.catalog_main(sl.catalog_id),
        'method', coalesce((select m.method from ebda.line_map_log m where m.line_id = sl.id order by m.created_at desc limit 1),
                           case when coalesce(sl.legacy_name,'') = '' then 'exact'
                                when exists(select 1 from ebda.line_aliases a where a.norm = ebda.line_norm(sl.legacy_name)) then 'alias'
                                when ebda.line_norm(sl.legacy_name) = ebda.line_norm(sl.name) then 'normalized' else 'new' end),
        'expenses', (select count(*) from ebda.expenses e where e.line_id = sl.id),
        'dup', (select count(*) from sl z where z.school_id = sl.school_id and z.catalog_id = sl.catalog_id) > 1)
        order by sl.s_name, sl.name) from sl), '[]'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object('alias', a.alias, 'catalog_id', a.catalog_id, 'source', a.source) order by a.alias) from ebda.line_aliases a), '[]'::jsonb)) $lm$;

-- ============================================================================
--  (3) العام المالى: بداية ونهاية ومسمى يحدّدها المستخدم المخوّل — بلا تداخل
-- ============================================================================
create table if not exists ebda.fiscal_years(
  id text primary key, label text not null, start_date date not null, end_date date not null,
  is_current text default 'لا', note text default '', created_at text default now()::text, created_by text default '',
  updated_at text default '', updated_by text default '');
do $fc$ begin
  if not exists (select 1 from pg_constraint where conname = 'fy_order') then
    alter table ebda.fiscal_years add constraint fy_order check (end_date > start_date and end_date < (start_date + interval '12 months')::date);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fy_no_overlap') then
    alter table ebda.fiscal_years add constraint fy_no_overlap exclude using gist (daterange(start_date, end_date, '[]') with &&);
  end if;
end $fc$;
create unique index if not exists ux_fy_label on ebda.fiscal_years(ebda.norm_txt(label));

-- السنوات الحالية (من «سنة» كل جهة) تُسجَّل بنفس القاعدة التى كان يعمل بها النظام (سبتمبر ← أغسطس) — فلا يتغيّر أى رقم بالترحيل
insert into ebda.fiscal_years(id, label, start_date, end_date, note, created_by)
select 'fy_' || y, p, make_date(y, 9, 1), make_date(y + 1, 8, 31), 'مُرحَّل من سنة الجهات (سبتمبر ← أغسطس)', 'migration'
from (select distinct on (substring(period from '\d{4}')::int) btrim(period) p, substring(period from '\d{4}')::int y
      from ebda.schools where coalesce(period,'') ~ '\d{4}' order by substring(period from '\d{4}')::int, btrim(period)) z
where not exists (select 1 from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(z.p))
  and not exists (select 1 from ebda.fiscal_years f where daterange(f.start_date, f.end_date, '[]') && daterange(make_date(z.y,9,1), make_date(z.y+1,8,31), '[]'));
-- لا توجد سنوات إطلاقاً ← السنة الحالية (سبتمبر ← أغسطس)
insert into ebda.fiscal_years(id, label, start_date, end_date, note, created_by)
select 'fy_' || y, y || '/' || (y + 1), make_date(y, 9, 1), make_date(y + 1, 8, 31), 'سنة افتراضية', 'migration'
from (select case when extract(month from current_date) >= 9 then extract(year from current_date)::int else extract(year from current_date)::int - 1 end y) q
where not exists (select 1 from ebda.fiscal_years);
-- السنة الحالية: التى تحتوى تاريخ اليوم، وإلا الأحدث
update ebda.fiscal_years set is_current = 'نعم'
where not exists (select 1 from ebda.fiscal_years f where f.is_current like '%نعم%')
  and id = coalesce((select f.id from ebda.fiscal_years f where current_date between f.start_date and f.end_date limit 1),
                    (select f.id from ebda.fiscal_years f order by f.start_date desc limit 1));

create or replace function ebda.try_jsonb(t text) returns jsonb language plpgsql immutable as $tj$
begin return t::jsonb; exception when others then return null; end $tj$;

-- تاريخ آمن من نص (يوم غير صالح ← آخر يوم فى الشهر)
create or replace function ebda.safe_date(d text) returns date language sql immutable as $$
  select case when coalesce(d,'') ~ '^\d{4}-\d{2}' and substr(d,6,2)::int between 1 and 12 then
    make_date(substr(d,1,4)::int, substr(d,6,2)::int, 1)
      + (least(greatest(coalesce(nullif(substring(d from '^\d{4}-\d{2}-(\d{2})'),'')::int, 1), 1),
               extract(day from (make_date(substr(d,1,4)::int, substr(d,6,2)::int, 1) + interval '1 month - 1 day'))::int) - 1)
  end $$;

-- بداية السنة المالية التى يقع فيها تاريخ: من الجدول، وإلا بنفس شهر/يوم بداية السنة الحالية (بدون افتراض يناير أو سبتمبر)
create or replace function ebda.fy_start_for(d text) returns date language sql stable security definer set search_path = ebda as $$
  with x as (select ebda.safe_date(d) dd),
  c as (select coalesce((select f.start_date from ebda.fiscal_years f where f.is_current like '%نعم%' limit 1), date '2000-09-01') cs)
  select case when x.dd is null then null else coalesce(
    (select f.start_date from ebda.fiscal_years f where x.dd between f.start_date and f.end_date limit 1),
    (select case when (extract(month from x.dd), extract(day from x.dd)) >= (extract(month from c.cs), least(extract(day from c.cs), 28))
                 then make_date(extract(year from x.dd)::int, extract(month from c.cs)::int, least(extract(day from c.cs)::int, 28))
                 else make_date(extract(year from x.dd)::int - 1, extract(month from c.cs)::int, least(extract(day from c.cs)::int, 28)) end from c)) end
  from x $$;

-- رقم السنة المالية = سنة بدايتها، ورقم الشهر داخلها (1..12) — نفس الأسماء القديمة حتى تعمل كل التقارير كما هى
create or replace function ebda.exp_fy(d text) returns int language sql stable as $$
  select extract(year from ebda.fy_start_for(d))::int $$;
create or replace function ebda.fy_month(d text) returns int language sql stable as $$
  select case when s is null then null else
    least(greatest((extract(year from ebda.safe_date(d))::int * 12 + extract(month from ebda.safe_date(d))::int)
                 - (extract(year from s)::int * 12 + extract(month from s)::int) + 1, 1), 12) end
  from (select ebda.fy_start_for(d) s) q $$;

-- سنة الجهة (المسمى) ← رقم سنة البداية وحدودها
create or replace function ebda.period_fy(p text) returns int language sql stable security definer set search_path = ebda as $$
  select coalesce((select extract(year from f.start_date)::int from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(p) limit 1),
                  case when coalesce(p,'') ~ '\d{4}' then extract(year from ebda.fy_start_for(substring(p from '\d{4}') || '-12-31'))::int end) $$;
create or replace function ebda.fy_from(p text) returns text language sql stable security definer set search_path = ebda as $$
  select coalesce((select f.start_date::text from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(p) limit 1),
                  case when coalesce(p,'') ~ '\d{4}' then (select f.start_date::text from ebda.fiscal_years f where extract(year from f.start_date)::int = substring(p from '\d{4}')::int limit 1) end,
                  case when coalesce(p,'') ~ '\d{4}' then ebda.fy_start_for(substring(p from '\d{4}') || '-12-31')::text end,
                  '0000-00-00') $$;
create or replace function ebda.fy_to(p text) returns text language sql stable security definer set search_path = ebda as $$
  select coalesce((select f.end_date::text from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(p) limit 1),
                  case when coalesce(p,'') ~ '\d{4}' then (select f.end_date::text from ebda.fiscal_years f where extract(year from f.start_date)::int = substring(p from '\d{4}')::int limit 1) end,
                  case when coalesce(p,'') ~ '\d{4}' then ((ebda.fy_start_for(substring(p from '\d{4}') || '-12-31') + interval '12 months')::date - 1)::text end,
                  '9999-99-99') $$;

-- منصرف البنود داخل سنة الجهة (المسمى ← سنة البداية من إعدادات العام المالى)
create or replace function ebda.line_fy_spend(u ebda.users) returns table(line_id text, school_id text, m int, amount numeric)
language plpgsql stable security definer set search_path = ebda as $lf$
declare star boolean := coalesce(u.schools,'')='*' or ebda.role_key(u.role)='admin'; sch text[] := ebda.scope_arr(u);
begin
  return query
  select a.line_id, a.school_id, a.m, a.amount from ebda.agg_line_month a
  join ebda.schools s on s.id = a.school_id
  join ebda.lines l on l.id = a.line_id and coalesce(l.deleted_at,'') = ''
  where (star or a.school_id = any(sch)) and a.amount <> 0
    and (coalesce(s.period,'') !~ '\d{4}' or a.fy = ebda.period_fy(s.period));
end $lf$;

do $rb$ begin perform ebda.rebuild_line_agg(); end $rb$;

-- حفظ سنة مالية: التحقق + عدم التداخل + نقل التوزيع الشهرى للبنود مع الشهر الصحيح + إعادة بناء التجميعات (التواريخ لا تتغيّر)
create or replace function ebda.save_fiscal_year(u ebda.users, j jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $sf$
declare o ebda.fiscal_years; fid text := nullif(j->>'id',''); lb text := btrim(coalesce(j->>'label',''));
        sd date; ed date; k int; n_rot int := 0; cur boolean := coalesce(j->>'is_current','') like '%نعم%' or coalesce(j->>'is_current','') = 'true';
begin
  if lb = '' then return ebda.err('اكتب مسمى العام المالى (مثال 2026/2027)'); end if;
  if coalesce(j->>'start_date','') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(j->>'end_date','') !~ '^\d{4}-\d{2}-\d{2}$' then
    return ebda.err('حدّد تاريخ البداية وتاريخ النهاية'); end if;
  begin sd := (j->>'start_date')::date; ed := (j->>'end_date')::date; exception when others then return ebda.err('تاريخ غير صحيح'); end;
  if ed <= sd then return ebda.err('تاريخ النهاية يجب أن يكون بعد تاريخ البداية'); end if;
  if ed >= (sd + interval '12 months')::date then return ebda.err('العام المالى لا يزيد عن 12 شهراً (من '||sd||' حتى '||((sd + interval '12 months')::date - 1)||' كحد أقصى)'); end if;
  if exists(select 1 from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(lb) and f.id is distinct from fid) then
    return ebda.err('يوجد عام مالى بنفس المسمى'); end if;
  if exists(select 1 from ebda.fiscal_years f where f.id is distinct from fid and daterange(f.start_date, f.end_date, '[]') && daterange(sd, ed, '[]')) then
    return ebda.err('الفترة تتداخل مع العام المالى «'||(select f.label from ebda.fiscal_years f where f.id is distinct from fid
      and daterange(f.start_date, f.end_date, '[]') && daterange(sd, ed, '[]') limit 1)||'» — لا يُسمح بتداخل الفترات حتى لا يُحتسب مصروف مرتين'); end if;
  if fid is not null then
    select * into o from ebda.fiscal_years where id = fid;
    if o.id is null then return ebda.err('العام المالى غير موجود'); end if;
    -- التوزيع الشهرى لبنود جهات هذه السنة يُزاح بحيث يبقى مبلغ كل شهر تقويمى كما هو
    k := (extract(month from sd)::int - extract(month from o.start_date)::int + 12) % 12;
    if k <> 0 then
      update ebda.lines l set monthly_plan = (select jsonb_agg(p.v->((i + k) % 12) order by i) from generate_series(0,11) i)::text
      from (select l2.id, ebda.try_jsonb(l2.monthly_plan) v from ebda.lines l2 join ebda.schools s on s.id = l2.school_id
            where ebda.norm_txt(s.period) = ebda.norm_txt(o.label) and coalesce(l2.monthly_plan,'') ~ '^\s*\[' ) p
      where p.id = l.id and jsonb_typeof(p.v) = 'array' and jsonb_array_length(p.v) = 12;
      get diagnostics n_rot = row_count;
    end if;
    update ebda.fiscal_years set label = lb, start_date = sd, end_date = ed, note = coalesce(j->>'note', note),
      updated_at = now()::text, updated_by = u.name where id = fid;
    -- الجهات المرتبطة بالمسمى القديم تتبع المسمى الجديد (نفس السنة)
    if ebda.norm_txt(o.label) <> ebda.norm_txt(lb) then update ebda.schools set period = lb where ebda.norm_txt(period) = ebda.norm_txt(o.label); end if;
  else
    fid := 'fy_' || substr(md5(lb || clock_timestamp()::text), 1, 10);
    insert into ebda.fiscal_years(id, label, start_date, end_date, note, created_by) values (fid, lb, sd, ed, coalesce(j->>'note',''), u.name);
  end if;
  if cur or not exists(select 1 from ebda.fiscal_years f where f.is_current like '%نعم%') then
    update ebda.fiscal_years set is_current = case when id = fid then 'نعم' else 'لا' end;
  end if;
  perform ebda.rebuild_line_agg();
  return jsonb_build_object('ok', true, 'id', fid, 'plans_shifted', n_rot,
    'fiscal_years', (select jsonb_agg(to_jsonb(f) order by f.start_date) from ebda.fiscal_years f));
end $sf$;

-- ============================================================================
--  (4) طلب العهدة / الاحتياجات (مطابق لشيت «احتياجات شهرية») + سجل الطلب + البريد
-- ============================================================================
alter table ebda.requests add column if not exists request_date text default '';
alter table ebda.requests add column if not exists dept text default '';            -- الجهة الطالبة
alter table ebda.requests add column if not exists description text default '';     -- الوصف التفصيلى للطلب
alter table ebda.requests add column if not exists priority text default '';        -- الأولوية
alter table ebda.requests add column if not exists holder_id text default '';       -- مسئول العهدة (الشخص)
alter table ebda.requests add column if not exists holder_name text default '';
alter table ebda.requests add column if not exists mgr_id text default '';          -- المدير المباشر المرتبط وقت الإرسال
alter table ebda.requests add column if not exists mgr_name text default '';
alter table ebda.requests add column if not exists decision_note text default '';   -- مبررات قرار الاعتماد
alter table ebda.requests add column if not exists submitted_at text default '';
alter table ebda.requests add column if not exists returned_at text default '';
alter table ebda.requests add column if not exists settlement text default '';      -- التسوية المالية
alter table ebda.requests add column if not exists settlement_note text default '';
alter table ebda.requests add column if not exists settled_at text default '';
alter table ebda.requests add column if not exists settled_by text default '';
alter table ebda.requests add column if not exists updated_at text default '';
alter table ebda.requests add column if not exists mail_status text default '';     -- آخر حالة إرسال للمدير المالى
alter table ebda.requests add column if not exists mail_at text default '';

alter table ebda.request_items add column if not exists unit text default '';          -- الوحدة
alter table ebda.request_items add column if not exists qty numeric default 0;         -- العدد/الكمية
alter table ebda.request_items add column if not exists unit_price numeric default 0;  -- القيمة التقديرية للوحدة
alter table ebda.request_items add column if not exists stock_check text default '';   -- حالة التحقق من المخزن
alter table ebda.request_items add column if not exists stock_result text default '';  -- نتيجة مراجعة المخزون
alter table ebda.request_items add column if not exists item_note text default '';
alter table ebda.request_items add column if not exists sort int default 0;

create table if not exists ebda.request_events(id text primary key, request_id text not null, ts text default now()::text,
  actor text default '', actor_id text default '', action text not null, from_status text default '', to_status text default '', note text default '');
create index if not exists ix_req_events on ebda.request_events(request_id);
create table if not exists ebda.request_mails(id text primary key, request_id text not null, created_at text default now()::text,
  sender text default '', sender_id text default '', to_addr text default '', cc jsonb default '[]'::jsonb, subject text default '',
  message text default '', body_html text default '', attachments jsonb default '[]'::jsonb,
  status text default 'prepared', provider_id text default '', error text default '', sent_at text default '');
create index if not exists ix_req_mails on ebda.request_mails(request_id);

create or replace function ebda.req_event(p_req text, u ebda.users, p_action text, p_from text, p_to text, p_note text) returns void
language sql security definer set search_path = ebda as $$
  insert into ebda.request_events(id, request_id, actor, actor_id, action, from_status, to_status, note)
  values (ebda.uid(), p_req, coalesce(u.name,''), coalesce(u.id,''), p_action, coalesce(p_from,''), coalesce(p_to,''), coalesce(p_note,'')) $$;

create or replace function ebda.req_status_label(s text) returns text language sql immutable as $$
  select case s when 'draft' then 'مسودة' when 'pending_supervisor' then 'بانتظار موافقة المدير المباشر'
    when 'returned' then 'معاد للتعديل' when 'rejected' then 'مرفوض'
    when 'pending_accountant' then 'معتمد من المدير المباشر — بانتظار المدير المالى'
    when 'transferred' then 'معتمد مالياً — تم التحويل للعهدة' when 'spent' then 'تم الصرف' when 'settled' then 'تمت التسوية'
    else coalesce(s,'') end $$;

-- عرض الطلب: نفس الحقول بالترتيب المعتمد — يُستخدم فى البريد والتنزيل والطباعة (نسخة مطابقة لما فى النظام)
create or replace function ebda.esc(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;') $$;
create or replace function ebda.fmt_num(n numeric) returns text language sql immutable as $$
  select case when n is null then '' when n = trunc(n) then to_char(n, 'FM999,999,999,990') else to_char(n, 'FM999,999,999,990.00') end $$;

create or replace function ebda.request_html(p_id text) returns text language plpgsql stable security definer set search_path = ebda as $rh$
declare r ebda.requests; s text; it record; i int := 0; rows text := ''; tot numeric := 0; th text :=
  'style="background:#123C5A;color:#fff;padding:6px 8px;border:1px solid #9aa9b6;font-size:12px;text-align:center"';
  td text := 'style="padding:6px 8px;border:1px solid #c9d3dc;font-size:12px;vertical-align:top"';
  ev text := '';
begin
  select * into r from ebda.requests where id = p_id;
  if r.id is null then return ''; end if;
  s := coalesce((select name from ebda.schools where id = r.school_id), '');
  for it in select x.*, coalesce(l.name,'') lname from ebda.request_items x left join ebda.lines l on l.id = x.line_id
            where x.request_id = r.id order by x.sort, x.id loop
    i := i + 1;
    if coalesce(it.decision,'') not in ('rejected','deferred','cancelled') then tot := tot + coalesce(it.amount,0); end if;
    rows := rows || '<tr' || case when it.decision in ('rejected','deferred','cancelled') then ' style="color:#999;text-decoration:line-through"' else '' end || '>'
      || '<td '||td||' align="center">'||i||'</td><td '||td||'><b>'||ebda.esc(it.name)||'</b>'||case when coalesce(it.item_note,'')<>'' then '<br><span style="color:#555">'||ebda.esc(it.item_note)||'</span>' else '' end||'</td>'
      || '<td '||td||' align="center">'||ebda.esc(it.unit)||'</td><td '||td||' align="center">'||ebda.fmt_num(nullif(it.qty,0))||'</td>'
      || '<td '||td||' align="left">'||ebda.fmt_num(nullif(it.unit_price,0))||'</td><td '||td||' align="left"><b>'||ebda.fmt_num(it.amount)||'</b></td>'
      || '<td '||td||'>'||ebda.esc(it.lname)||'</td><td '||td||'>'||ebda.esc(it.stock_check)||'</td><td '||td||'>'||ebda.esc(it.stock_result)||'</td>'
      || '<td '||td||'>'||ebda.esc(case it.decision when 'rejected' then 'مرفوض' when 'approved' then 'معتمد بالكامل' when 'partial' then 'معتمد جزئياً' when 'deferred' then 'مؤجل للشهر التالى' when 'cancelled' then 'ملغى' else coalesce(it.decision,'') end)
      || case when coalesce(it.sup_note,'')<>'' then ' — '||ebda.esc(it.sup_note) else '' end||'</td></tr>';
  end loop;
  for it in select * from ebda.request_events e where e.request_id = r.id order by e.ts loop
    ev := ev || '<tr><td '||td||'>'||ebda.esc(left(it.ts,16))||'</td><td '||td||'>'||ebda.esc(it.actor)||'</td><td '||td||'>'||ebda.esc(it.action)
       ||'</td><td '||td||'>'||ebda.esc(ebda.req_status_label(it.to_status))||'</td><td '||td||'>'||ebda.esc(it.note)||'</td></tr>';
  end loop;
  return '<div dir="rtl" style="font-family:Arial,Tahoma,sans-serif;color:#16232F">'
    || '<div style="color:#123C5A;font-weight:bold;font-size:14px">ابدأ إديو للتطوير والتدريب</div>'
    || '<div style="color:#666;font-size:11px;margin-bottom:8px">الذراع التعليمى والتدريبى لمبادرة ابدأ الرئاسية لتطوير الصناعة</div>'
    || '<h2 style="color:#123C5A;margin:6px 0">طلب عهدة / احتياجات — '||ebda.esc(r.req_no)||'</h2>'
    || '<table style="border-collapse:collapse;width:100%;margin-bottom:10px">'
    || '<tr><td '||td||' width="18%"><b>الرقم المرجعى</b></td><td '||td||'>'||ebda.esc(r.req_no)||'</td><td '||td||' width="18%"><b>المدرسة / الموقع</b></td><td '||td||'>'||ebda.esc(s)||'</td></tr>'
    || '<tr><td '||td||'><b>مقدم الطلب</b></td><td '||td||'>'||ebda.esc(r.requester_name)||'</td><td '||td||'><b>مسئول العهدة</b></td><td '||td||'>'||ebda.esc(coalesce(nullif(r.holder_name,''), r.requester_name))||'</td></tr>'
    || '<tr><td '||td||'><b>الجهة الطالبة</b></td><td '||td||'>'||ebda.esc(r.dept)||'</td><td '||td||'><b>تاريخ الطلب</b></td><td '||td||'>'||ebda.esc(coalesce(nullif(r.request_date,''), left(r.created_at,10)))||'</td></tr>'
    || '<tr><td '||td||'><b>الأولوية</b></td><td '||td||'>'||ebda.esc(r.priority)||'</td><td '||td||'><b>الحالة</b></td><td '||td||'>'||ebda.esc(ebda.req_status_label(r.status))||'</td></tr>'
    || '<tr><td '||td||'><b>سبب الطلب</b></td><td '||td||' colspan="3">'||ebda.esc(r.reason)||'</td></tr>'
    || '<tr><td '||td||'><b>الوصف التفصيلى</b></td><td '||td||' colspan="3">'||ebda.esc(r.description)||'</td></tr>'
    || '</table>'
    || '<table style="border-collapse:collapse;width:100%"><thead><tr><th '||th||'>م</th><th '||th||'>الصنف</th><th '||th||'>الوحدة</th><th '||th||'>الكمية</th>'
    || '<th '||th||'>القيمة التقديرية للوحدة</th><th '||th||'>الإجمالى التقديرى</th><th '||th||'>نوع المصروف / البند</th><th '||th||'>التحقق من المخزن</th>'
    || '<th '||th||'>نتيجة مراجعة المخزون</th><th '||th||'>الاعتماد / مبررات القرار</th></tr></thead><tbody>'||rows
    || '<tr><td '||td||' colspan="5" align="left"><b>الإجمالى التقديرى للطلب</b></td><td '||td||' align="left"><b>'||ebda.fmt_num(tot)||' ج.م</b></td><td '||td||' colspan="4"></td></tr>'
    || '</tbody></table>'
    || '<table style="border-collapse:collapse;width:100%;margin-top:10px">'
    || '<tr><td '||td||' width="18%"><b>اعتماد المدير المباشر</b></td><td '||td||'>'
    || case when r.status in ('pending_accountant','transferred','spent','settled') then 'تمت الموافقة' when r.status = 'rejected' and coalesce(r.fin_at,'') = '' then 'مرفوض'
            when r.status = 'returned' then 'أُعيد للتعديل' else 'لم يُعتمد بعد' end
    || case when coalesce(r.decided_by,'')<>'' then ' — '||ebda.esc(r.decided_by) else '' end||'</td>'
    || '<td '||td||' width="18%"><b>تاريخ الاعتماد</b></td><td '||td||'>'||ebda.esc(left(coalesce(r.decided_at,''),10))||'</td></tr>'
    || '<tr><td '||td||'><b>مبررات القرار</b></td><td '||td||' colspan="3">'||ebda.esc(coalesce(nullif(r.decision_note,''), r.note))||'</td></tr>'
    || '<tr><td '||td||'><b>الاعتماد المالى</b></td><td '||td||'>'||case when r.status in ('transferred','spent','settled') then 'معتمد — '||ebda.esc(r.acc_by)
            when r.status = 'rejected' and coalesce(r.fin_at,'')<>'' then 'مرفوض مالياً' else 'لم يتم بعد (موافقة المدير المباشر لا تعنى الاعتماد المالى)' end||'</td>'
    || '<td '||td||'><b>التسوية المالية</b></td><td '||td||'>'||ebda.esc(coalesce(nullif(r.settlement,''),'لم تتم'))||case when coalesce(r.settlement_note,'')<>'' then ' — '||ebda.esc(r.settlement_note) else '' end||'</td></tr>'
    || '</table>'
    || case when ev <> '' then '<h4 style="color:#123C5A;margin:12px 0 4px">سجل الطلب</h4><table style="border-collapse:collapse;width:100%"><thead><tr><th '||th||'>الوقت</th><th '||th||'>بواسطة</th><th '||th||'>الإجراء</th><th '||th||'>الحالة</th><th '||th||'>ملاحظات</th></tr></thead><tbody>'||ev||'</tbody></table>' else '' end
    || '<p style="color:#888;font-size:11px;margin-top:12px">نسخة مطابقة لبيانات الطلب المسجلة فى نظام متابعة الموازنات والعهد — '||to_char(now() at time zone 'Africa/Cairo','YYYY-MM-DD HH24:MI')||'</p></div>';
end $rh$;

-- ============================================================================
--  تتبع التعديلات للجداول الجديدة + النسخ الاحتياطى يشملها
-- ============================================================================
do $tr$
declare t text;
begin
  foreach t in array array['line_catalog','line_aliases','fiscal_years','request_items','request_events','request_mails'] loop
    execute format('drop trigger if exists trg_track_%1$s on ebda.%1$I', t);
    execute format('create trigger trg_track_%1$s after insert or update or delete on ebda.%1$I for each row execute function ebda.track_change()', t);
  end loop;
end $tr$;

create or replace function ebda.backup_tables() returns text[] language sql immutable as $$
  select array['config','users','schools','entity_types','line_catalog','line_aliases','line_map_log','fiscal_years','lines','custody_names','custody_kinds','custodies','custody_lines','tranches',
               'expenses','requests','request_items','request_events','request_mails','spend_items','holders','approvers','emails','salaries','temp_budgets',
               'employees','payroll_components','payroll_periods','payslips','import_batches','audit_log','audit_changes'] $$;


-- ---------------------------------------------------------------- مساعدات الطلب (v8)
-- من يرى الطلب: الأدمن، مقدّمه/مسئول عهدته، وغيرهما داخل نطاق الجهة (المسودة لصاحبها فقط)
create or replace function ebda.can_request(u ebda.users, r ebda.requests) returns boolean language sql stable security definer set search_path = ebda as $$
  select ebda.rk(u) = 'admin'
      or (coalesce(r.requester_id,'') <> '' and r.requester_id = u.id) or (coalesce(r.requester_id,'') = '' and r.requester = u.username)
      or (coalesce(r.holder_id,'') <> '' and r.holder_id = u.id)
      or (coalesce(r.status,'') <> 'draft' and ebda.rk(u) <> 'custody_officer' and ebda.can_school(u, r.school_id)) $$;
create or replace function ebda.is_requester(u ebda.users, r ebda.requests) returns boolean language sql stable as $$
  select (coalesce(r.requester_id,'') <> '' and r.requester_id = u.id) or (coalesce(r.requester_id,'') = '' and r.requester = u.username) $$;

-- حفظ أصناف الطلب (استبدال كامل) مع التحقق — الإجمالى = الكمية × القيمة التقديرية للوحدة (يُحسب هنا لا فى الواجهة)
create or replace function ebda.req_items_save(p_req text, p_school text, items jsonb) returns text
language plpgsql security definer set search_path = ebda as $ri$
declare it jsonb; i int := 0; q numeric; p numeric; amt numeric;
begin
  if jsonb_typeof(coalesce(items,'null'::jsonb)) <> 'array' or jsonb_array_length(items) = 0 then return 'أضف صنفاً واحداً على الأقل'; end if;
  for it in select * from jsonb_array_elements(items) loop
    i := i + 1;
    if coalesce(btrim(it->>'name'),'') = '' then return 'الصنف رقم '||i||': اكتب اسم الصنف'; end if;
    if coalesce(it->>'line_id','') = '' then return 'الصنف «'||btrim(it->>'name')||'»: اختر نوع المصروف / البند'; end if;
    if not exists(select 1 from ebda.lines l where l.id = it->>'line_id' and l.school_id = p_school and coalesce(l.deleted_at,'') = '') then
      return 'الصنف «'||btrim(it->>'name')||'»: البند غير تابع لهذه المدرسة/الجهة'; end if;
    if exists(select 1 from ebda.lines l where l.id = it->>'line_id' and coalesce(l.active,'نعم') not like '%نعم%') then
      return 'الصنف «'||btrim(it->>'name')||'»: البند معطّل — لا يقبل طلبات جديدة'; end if;
    if coalesce(btrim(it->>'qty'),'') <> '' or coalesce(btrim(it->>'unit_price'),'') <> '' then
      if coalesce(btrim(it->>'qty'),'') !~ '^[0-9]+(\.[0-9]+)?$' or (it->>'qty')::numeric <= 0 then
        return 'الصنف «'||btrim(it->>'name')||'»: الكمية يجب أن تكون رقماً أكبر من صفر'; end if;
      if coalesce(btrim(it->>'unit_price'),'') !~ '^[0-9]+(\.[0-9]+)?$' or (it->>'unit_price')::numeric <= 0 then
        return 'الصنف «'||btrim(it->>'name')||'»: القيمة التقديرية للوحدة يجب أن تكون رقماً أكبر من صفر'; end if;
      q := (it->>'qty')::numeric; p := (it->>'unit_price')::numeric; amt := round(q * p, 2);
    else
      if coalesce(btrim(it->>'amount'),'') !~ '^[0-9]+(\.[0-9]+)?$' or (it->>'amount')::numeric <= 0 then
        return 'الصنف «'||btrim(it->>'name')||'»: أدخل الكمية والقيمة التقديرية للوحدة'; end if;
      q := 0; p := 0; amt := (it->>'amount')::numeric;
    end if;
    if amt > 100000000 then return 'الصنف «'||btrim(it->>'name')||'»: قيمة غير منطقية'; end if;
  end loop;
  delete from ebda.request_items where request_id = p_req;
  i := 0;
  for it in select * from jsonb_array_elements(items) loop
    i := i + 1;
    if coalesce(btrim(it->>'qty'),'') <> '' then q := (it->>'qty')::numeric; p := (it->>'unit_price')::numeric; amt := round(q * p, 2);
    else q := 0; p := 0; amt := (it->>'amount')::numeric; end if;
    insert into ebda.request_items(id, request_id, line_id, name, amount, sup_note, decision, unit, qty, unit_price, stock_check, stock_result, item_note, sort)
    values (ebda.uid(), p_req, it->>'line_id', btrim(it->>'name'), amt, '', 'approved', btrim(coalesce(it->>'unit','')), q, p,
            btrim(coalesce(it->>'stock_check','')), btrim(coalesce(it->>'stock_result','')), btrim(coalesce(it->>'item_note','')), i);
  end loop;
  update ebda.requests set total = coalesce((select sum(amount) from ebda.request_items where request_id = p_req and decision not in ('rejected','deferred','cancelled')),0) where id = p_req;
  return null;
end $ri$;

-- رأس الطلب (الحقول المطابقة لشيت الاحتياجات)
create or replace function ebda.req_header_err(r jsonb) returns text language sql immutable as $$
  select case
    when coalesce(btrim(r->>'reason'),'') = '' then 'اكتب سبب الطلب'
    when coalesce(r->>'request_date','') <> '' and coalesce(r->>'request_date','') !~ '^\d{4}-\d{2}-\d{2}$' then 'تاريخ الطلب غير صحيح'
    when coalesce(r->>'priority','') not in ('','عادية','متوسطة','عاجلة','عاجلة — مرتبطة بالسلامة أو توقف العمل','مرتفعة — تؤثر على تنفيذ العملية التعليمية',
         'متوسطة — مطلوبة خلال الشهر','منخفضة — يمكن تأجيلها') then 'الأولوية غير صحيحة'
    else null end $$;

-- الصنف الفرعى للمصروف: مسموح فقط إذا كان فرعاً من بند المصروف الموحد (مثل «مستهلكات معامل» تحت «مستهلكات ورش ومعامل»)
create or replace function ebda.valid_sub(p_line text, p_sub text) returns text language sql stable security definer set search_path = ebda as $$
  select case when coalesce(p_sub,'') = '' then ''
    else coalesce((select c.id from ebda.line_catalog c join ebda.lines l on l.id = p_line
                   where c.id = p_sub and (c.parent_id = l.catalog_id or c.id = l.catalog_id)), '!') end $$;

-- لوحة البداية v8 = v6 + القائمة الموحدة + العام المالى + سجل الطلبات وبريدها (المسودات لأصحابها فقط)
create or replace function ebda.bootstrap_v8(u ebda.users) returns jsonb
language plpgsql stable security definer set search_path = ebda as $b8$
declare res jsonb := ebda.bootstrap_v6(u); ids text[];
begin
  if res ? 'error' then return res; end if;
  res := jsonb_set(res, '{requests}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(res->'requests','[]'::jsonb)) x
           where coalesce(x->>'status','') <> 'draft' or x->>'requester_id' = u.id or (coalesce(x->>'requester_id','') = '' and x->>'requester' = u.username)
              or ebda.rk(u) = 'admin'), '[]'::jsonb));
  ids := array(select x->>'id' from jsonb_array_elements(res->'requests') x);
  -- البند الموحد لكل بند جهة (حتى للأدوار التى لا ترى المبالغ)
  res := jsonb_set(res, '{lines}', coalesce((select jsonb_agg(x || jsonb_build_object('catalog_id', coalesce(l.catalog_id,'')))
           from jsonb_array_elements(coalesce(res->'lines','[]'::jsonb)) x left join ebda.lines l on l.id = x->>'id'), '[]'::jsonb));
  return res || jsonb_build_object(
    'line_catalog', coalesce((select jsonb_agg(to_jsonb(c) order by c.sort, c.name) from ebda.line_catalog c), '[]'::jsonb),
    'line_aliases', coalesce((select jsonb_agg(jsonb_build_object('alias', a.alias, 'catalog_id', a.catalog_id)) from ebda.line_aliases a), '[]'::jsonb),
    'fiscal_years', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'label', f.label, 'start_date', f.start_date::text, 'end_date', f.end_date::text,
                     'is_current', f.is_current, 'note', f.note, 'updated_at', f.updated_at, 'updated_by', f.updated_by) order by f.start_date) from ebda.fiscal_years f), '[]'::jsonb),
    'request_events', coalesce((select jsonb_agg(to_jsonb(e) order by e.ts) from ebda.request_events e where e.request_id = any(ids)), '[]'::jsonb),
    'request_mails', coalesce((select jsonb_agg(to_jsonb(m) - 'body_html' order by m.created_at) from ebda.request_mails m where m.request_id = any(ids)), '[]'::jsonb))
    || jsonb_build_object('settings', coalesce(res->'settings','{}'::jsonb) || jsonb_build_object(
         'finance_email', coalesce((select value from ebda.config where key='finance_email'),''),
         'mail_cc_default', coalesce((select value from ebda.config where key='mail_cc_default'),'')));
end $b8$;


-- الاستعادة (005 + ربط البنود الموحدة بعد الاستعادة)
create or replace function ebda.restore_backup(p_id text, p_actor text) returns jsonb
language plpgsql security definer set search_path = ebda as $rb$
declare b ebda.backups; t text; safety jsonb; n int; restored jsonb := '{}'::jsonb; cols text;
begin
  select * into b from ebda.backups where id = p_id;
  if not found then return ebda.err('النسخة غير موجودة'); end if;
  safety := ebda.make_backup('safety', p_actor, 'قبل استعادة '||b.name);
  perform set_config('ebda.restoring', '1', true);
  foreach t in array ebda.backup_tables() loop
    if to_regclass('ebda.'||t) is null or not (b.data ? t) then continue; end if;
    select string_agg(format('%I', a.attname), ',' order by a.attnum) into cols
      from pg_attribute a where a.attrelid = ('ebda.'||t)::regclass and a.attnum > 0 and not a.attisdropped;
    if t in ('audit_log','audit_changes') then
      execute format('insert into ebda.%1$I(%2$s) select %2$s from jsonb_populate_recordset(null::ebda.%1$I, $1) r where not exists (select 1 from ebda.%1$I x where x.id = r.id)', t, cols)
        using b.data->t;
    else
      execute format('delete from ebda.%I', t);
      execute format('insert into ebda.%1$I(%2$s) select %2$s from jsonb_populate_recordset(null::ebda.%1$I, $1)', t, cols) using b.data->t;
    end if;
    get diagnostics n = row_count;
    restored := restored || jsonb_build_object(t, n);
  end loop;
  -- الأرقام المسلسلة لا ترجع للخلف (منع تكرار أرقام العمليات) — وإعادة بناء التجميعات من البيانات المستعادة
  perform set_config('ebda.restoring', '', true);
  perform ebda.catalog_link_all();
  perform ebda.rebuild_line_agg();
  return jsonb_build_object('ok', true, 'restored', b.name, 'safety_backup', safety, 'rows', restored);
end $rb$;

-- ============================================================================
--  استيراد المصروفات (006 + السنة المالية من الإعدادات + المطابقة بالبند الموحد)
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
  can_new boolean := ebda.can(u,'custody.create') and ebda.can(u,'custody.approve');
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
              'restricted', exists(select 1 from ebda.custody_lines cl where cl.custody_id = cust.id),
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
             and not exists(select 1 from ebda.custody_lines cl where cl.custody_id = cid and cl.line_id = lid) then
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
        update ebda.custodies set user_id = coalesce(cinfo->>'user_id',''), approval = 'approved', approved_by = u.name, approved_at = now()::text,
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
        doc_name = case when coalesce(btrim(rw->>'doc_link'),'') ~* '^https?://' then coalesce(nullif(rw->>'doc_no',''),'رابط مستند') else '' end
      where id = newid;
    end if;

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

select 'الجزء 6 من 15 تم ✓ — شغّل الجزء 7' as result;
