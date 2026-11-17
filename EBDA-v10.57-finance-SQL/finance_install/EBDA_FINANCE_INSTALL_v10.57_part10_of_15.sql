-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 10 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;
select set_config('ebda.fy_override', '1', false);
alter table ebda.payroll_periods add column if not exists cancelled_at text default '';
alter table ebda.payroll_periods add column if not exists cancelled_by text default '';
alter table ebda.payroll_periods add column if not exists cancel_reason text default '';
alter table ebda.lines add column if not exists import_batch text default '';
alter table ebda.lines add column if not exists last_batch text default '';
alter table ebda.import_batches add column if not exists school_id text default '';
alter table ebda.import_batches add column if not exists month text default '';
alter table ebda.import_batches add column if not exists snapshot jsonb default '{}'::jsonb;   -- القيم السابقة للسجلات التى عدّلتها الدفعة
alter table ebda.import_batches add column if not exists revert_reason text default '';
alter table ebda.import_batches add column if not exists revert_result jsonb default '{}'::jsonb;
create index if not exists ix_payslips_batch on ebda.payslips(import_batch);
create index if not exists ix_payslips_last_batch on ebda.payslips(last_batch);
create index if not exists ix_lines_batch on ebda.lines(import_batch);
create index if not exists ix_expenses_batch on ebda.expenses(import_batch);

-- إجماليات الشيت المرجعى («إجماليات ابدأ-إديو») للمطابقة مع القسائم
create table if not exists ebda.payroll_totals(id text primary key, school_id text, month text, category text, amount numeric default 0,
  source_file text default '', batch text default '', created_at text default now()::text, created_by text default '');
create unique index if not exists ux_payroll_totals on ebda.payroll_totals(school_id, month, category);

-- قواعد حساب المؤثرات: لا قيمة افتراضية للساعة/اليوم قبل اعتماد الشركة للقاعدة (approved=false)
insert into ebda.config(key,value) values ('effects_rules',
  '{"approved":false,"day_basis":"fixed","day_divisor":30,"hours_per_day":8,"ot_hour_rate":1,"ot_day_rate":1,"ded_hour_rate":1,"ded_day_rate":1,"prorate":false}')
on conflict (key) do nothing;
-- حالات بنود الموازنة (قابلة للتعديل من «الإعدادات ← إعدادات حالات بنود الموازنة»):
--   الاستهلاك = المصروف الفعلى المعتمد ÷ الموازنة الكلية المعتمدة للبند × 100 (وليس المخصص الشهرى)
--   أقل من near_exhaust_pct ← ضمن الموازنة · من near_exhaust_pct حتى status_over_pct ← على وشك تجاوز الموازنة · أكثر من status_over_pct ← متجاوز الموازنة
insert into ebda.config(key,value) values ('near_exhaust_pct','80') on conflict (key) do nothing;
update ebda.config set value = '80' where key = 'near_exhaust_pct' and value = '90' and not exists(select 1 from ebda.config where key = 'status_over_pct');
insert into ebda.config(key,value) values ('status_over_pct','100') on conflict (key) do nothing;
insert into ebda.config(key,value) values ('status_within_from','0') on conflict (key) do nothing;
alter table ebda.schools add column if not exists cancelled_at text default '';
alter table ebda.schools add column if not exists cancelled_by text default '';
alter table ebda.schools add column if not exists cancel_reason text default '';
insert into ebda.config(key,value) values ('approval_overdue_days','7') on conflict (key) do nothing;
insert into ebda.config(key,value) values ('school_gap_pct','30') on conflict (key) do nothing;
insert into ebda.config(key,value) values ('unusual_ded_pct','50') on conflict (key) do nothing;

create or replace function ebda.backup_tables() returns text[] language sql immutable as $$
  select array['config','users','schools','entity_types','line_catalog','line_aliases','line_map_log','fiscal_years','lines','custody_names','custody_kinds','custodies','custody_lines','tranches',
               'expenses','requests','request_items','request_events','request_mails','mail_outbox','spend_items','holders','approvers','emails','salaries','temp_budgets',
               'employees','payroll_components','payroll_periods','payslips','payslip_items','payroll_totals','import_batches','purge_log','audit_log','audit_changes'] $$;

create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems') $$;

-- تتبع التعديلات لجدول الإجماليات الجديد (نفس مشغّل باقى الجداول)
drop trigger if exists trg_track_payroll_totals on ebda.payroll_totals;
create trigger trg_track_payroll_totals after insert or update or delete on ebda.payroll_totals for each row execute function ebda.track_change();

-- ============================================================================
--  الرواتب: الفصل بين المستحقات · الخصومات · الاستقطاعات · التزامات الشركة (لا تُخصم من الموظف)
-- ============================================================================
-- أنواع عناصر الراتب: earning (مستحق +) · deduction (خصم −) · withholding (استقطاع −) · employer (التزام على الشركة — لا يؤثر على صافى الموظف)
update ebda.payroll_components set kind = 'withholding' where code in ('insurance','tax','advance','other_deduction') and kind = 'deduction' and coalesce(system,'') like '%نعم%';
update ebda.payroll_components set name = 'حصة الموظف فى التأمينات' where code = 'insurance' and name = 'تأمينات';
update ebda.payroll_components set name = 'أقساط السلف' where code = 'advance' and name = 'سلفة';
insert into ebda.payroll_components(id,code,name,kind,active,sort,system)
select ebda.uid(), v.code, v.name, v.kind, 'نعم', v.sort, 'نعم' from (values
  ('absence','خصم الغياب','deduction',20), ('penalty','خصم الجزاءات','deduction',21), ('other_ded','خصومات أخرى','deduction',22),
  ('employer_insurance','حصة الشركة فى التأمينات','employer',40)) v(code,name,kind,sort)
where not exists(select 1 from ebda.payroll_components c where c.code = v.code);

create or replace function ebda.payslip_net(base_net numeric, adj jsonb) returns numeric language sql stable as $$
  select coalesce(base_net,0) + coalesce((select sum(case c.kind when 'earning' then 1 when 'employer' then 0 else -1 end * coalesce(nullif(a.value,'')::numeric,0))
     from jsonb_each_text(coalesce(adj,'{}'::jsonb)) a join ebda.payroll_components c on c.code=a.key),0)
$$;

-- تفاصيل الخصومات/الاستقطاعات/المستحقات لكل قسيمة (أكثر من بند لنفس النوع، بالسبب والتاريخ)
--   source = import: تفصيل لما ورد فى ملف الرواتب (صافى الملف يتضمنه — لا يُخصم مرة ثانية)
--   source = manual: مؤثرات يدوية — مجموعها لكل نوع هو adjustments ويؤثر على الصافى
create table if not exists ebda.payslip_items(id text primary key, payslip_id text not null, code text not null, kind text default '', amount numeric default 0,
  reason text default '', item_date text default '', source text default 'manual', batch text default '', created_by text default '', created_at text default now()::text);
create index if not exists ix_payslip_items_slip on ebda.payslip_items(payslip_id);
drop trigger if exists trg_track_payslip_items on ebda.payslip_items;
create trigger trg_track_payslip_items after insert or update or delete on ebda.payslip_items for each row execute function ebda.track_change();

create or replace function ebda.ins_cat(t text) returns text language sql immutable as $$
  select case when coalesce(t,'') like '%غير%' then 'uninsured' when coalesce(t,'') like '%مؤمن%' then 'insured' else 'unspecified' end $$;

-- ============================================================================
--  مؤثرات الرواتب — الحساب
-- ============================================================================
create or replace function ebda.eff_rules() returns jsonb language plpgsql stable security definer set search_path = ebda as $er$
declare j jsonb;
begin
  begin j := nullif(btrim(coalesce((select value from ebda.config where key='effects_rules'),'')),'')::jsonb;
  exception when others then j := null; end;
  return coalesce(j, '{}'::jsonb);
end $er$;

create or replace function ebda.jnum(j jsonb, k text, d numeric) returns numeric language plpgsql immutable as $jn$
begin
  return coalesce(nullif(btrim(coalesce(j->>k,'')),'')::numeric, d);
exception when others then return d;
end $jn$;

-- مجموع عناصر الراتب اليدوية (adjustments) حسب النوع
create or replace function ebda.adj_kind_sum(adj jsonb, p_kind text) returns numeric language sql stable security definer set search_path = ebda as $$
  select coalesce(sum(coalesce(nullif(a.value,'')::numeric,0)),0) from jsonb_each_text(coalesce(adj,'{}'::jsonb)) a
  join ebda.payroll_components c on c.code = a.key where c.kind = p_kind $$;

-- حساب المؤثرات لقسيمة: الصافى = المستحق قبل المؤثرات + الإضافى − الخصم + عناصر الراتب اليدوية
-- (صافى ملف الحضور net_import لا يُضاف ولا يُخصم مرة ثانية: القسيمة ذات بيانات المؤثرات تُحسب من «صافى الراتب التعاقدى» فقط)
create or replace function ebda.eff_calc(p_contract numeric, p_work_days numeric, p_oth numeric, p_otd numeric, p_dh numeric, p_dd numeric,
                                         p_adj jsonb, r jsonb) returns jsonb
language plpgsql stable security definer set search_path = ebda as $ec$
declare
  ok boolean := coalesce(r->>'approved','') in ('true','1','yes');
  divisor numeric := ebda.jnum(r,'day_divisor',30);
  hpd numeric := ebda.jnum(r,'hours_per_day',8);
  dayv numeric; hourv numeric; base_due numeric := coalesce(p_contract,0); ot numeric := 0; dd numeric := 0;
  adj_e numeric := ebda.adj_kind_sum(p_adj,'earning'); adj_d numeric := ebda.adj_kind_sum(p_adj,'deduction') + ebda.adj_kind_sum(p_adj,'withholding');
  has_eff boolean := coalesce(p_oth,0) + coalesce(p_otd,0) + coalesce(p_dh,0) + coalesce(p_dd,0) > 0;
  st text;
begin
  if not ok then
    -- بدون قاعدة معتمدة: لا تُحسب قيمة ساعة/يوم. القسيمة بلا مؤثرات تبقى = التعاقدى؛ وذات المؤثرات «بانتظار قاعدة الحساب»
    st := case when has_eff then 'pending_rule' else 'no_effects' end;
    return jsonb_build_object('state', st, 'base_due', base_due, 'ot_amount', 0, 'ded_amount', 0, 'day_value', null, 'hour_value', null,
                              'adj_earn', adj_e, 'adj_ded', adj_d, 'net', round(base_due + adj_e - adj_d, 2));
  end if;
  if coalesce(r->>'day_basis','fixed') = 'work_days' and coalesce(p_work_days,0) > 0 then divisor := p_work_days; end if;
  if divisor <= 0 then divisor := 30; end if;
  if hpd <= 0 then hpd := 8; end if;
  dayv := coalesce(p_contract,0) / divisor;
  hourv := dayv / hpd;
  if coalesce(r->>'prorate','') in ('true','1','yes') and p_work_days is not null and p_work_days < ebda.jnum(r,'day_divisor',30) then
    base_due := round(coalesce(p_contract,0) * p_work_days / ebda.jnum(r,'day_divisor',30), 2);
  end if;
  ot := round(coalesce(p_oth,0) * hourv * ebda.jnum(r,'ot_hour_rate',1) + coalesce(p_otd,0) * dayv * ebda.jnum(r,'ot_day_rate',1), 2);
  dd := round(coalesce(p_dh,0) * hourv * ebda.jnum(r,'ded_hour_rate',1) + coalesce(p_dd,0) * dayv * ebda.jnum(r,'ded_day_rate',1), 2);
  return jsonb_build_object('state', case when has_eff then 'computed' else 'no_effects' end, 'base_due', base_due, 'ot_amount', ot, 'ded_amount', dd,
                            'day_value', round(dayv, 4), 'hour_value', round(hourv, 4), 'adj_earn', adj_e, 'adj_ded', adj_d,
                            'net', round(base_due + ot - dd + adj_e - adj_d, 2));
end $ec$;

-- إعادة حساب صافى القسيمة (الوحيدة المسموح لها بكتابة net)
create or replace function ebda.slip_recalc(p_id text) returns void language plpgsql security definer set search_path = ebda as $sr$
declare p ebda.payslips; c jsonb; r jsonb := ebda.eff_rules();
begin
  select * into p from ebda.payslips where id = p_id;
  if p.id is null then return; end if;
  if p.contract_net is null then
    update ebda.payslips set net = ebda.payslip_net(net_import, adjustments) where id = p_id;
    return;
  end if;
  c := ebda.eff_calc(p.contract_net, p.eff_work_days, p.ot_hours, p.ot_days, p.ded_hours, p.ded_days, p.adjustments, r);
  update ebda.payslips set base_due = (c->>'base_due')::numeric, ot_amount = (c->>'ot_amount')::numeric, ded_amount = (c->>'ded_amount')::numeric,
    effects_state = c->>'state', net = (c->>'net')::numeric,
    effects_rule = case when c->>'state' = 'computed' then r || jsonb_build_object('day_value', c->'day_value', 'hour_value', c->'hour_value') else null end
  where id = p_id;
end $sr$;

-- استعادة سجل من لقطته السابقة (كل الأعمدة) — يُستخدم عند إلغاء دفعة عدّلت سجلات موجودة
create or replace function ebda.restore_row(p_tbl text, p_before jsonb) returns void language plpgsql security definer set search_path = ebda as $rr$
declare sets text;
begin
  if p_tbl not in ('payslips','lines') then raise exception 'table not allowed'; end if;
  select string_agg(format('%I = r.%I', column_name, column_name), ', ') into sets
  from information_schema.columns where table_schema = 'ebda' and table_name = p_tbl and column_name <> 'id';
  execute format('update ebda.%I t set %s from jsonb_populate_record(null::ebda.%I, $1) r where t.id = r.id', p_tbl, sets, p_tbl) using p_before;
end $rr$;

create or replace function ebda.month_locked(p_school text, p_month text) returns boolean language sql stable security definer set search_path = ebda as $$
  select exists(select 1 from ebda.payroll_periods pp where pp.school_id = p_school and pp.month = p_month and pp.status = 'approved') $$;

-- ============================================================================
--  (1) استيراد الرواتب الشهرية (منقول من api_core كما هو) + تتبع الدفعة ولقطة القيم السابقة
-- ============================================================================
create or replace function ebda.import_payroll(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $ip$
declare
  sid text := req->>'school_id'; ln jsonb; lid text; nk text; pid text; n_emp int := 0; n_new int := 0; n_upd int := 0;
  bid text := ebda.uid(); snap jsonb := '{}'::jsonb; ps ebda.payslips; n_skip int := 0; onx text := coalesce(nullif(req->>'on_existing',''),'update');
  it record; e_sum numeric; d_sum numeric; w_sum numeric; netv numeric; snap_items jsonb := '{}'::jsonb;
begin
  if not ebda.can(u,'payroll.import') then return ebda.err('صلاحية استيراد الرواتب مطلوبة'); end if;
  if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then return ebda.err('المكان غير موجود'); end if;
  if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
  if coalesce(req->>'month','') !~ '^[0-9]{4}-[0-9]{2}$' then return ebda.err('الشهر غير صحيح'); end if;
  if ebda.month_locked(sid, req->>'month') then
    return ebda.err('رواتب هذا الشهر معتمدة — يجب إعادة فتحها (للأدمن) قبل الاستيراد'); end if;
  if jsonb_typeof(coalesce(req->'rows','null'::jsonb))<>'array' or jsonb_array_length(req->'rows')=0 then return ebda.err('لا توجد بيانات'); end if;
  for ln in select * from jsonb_array_elements(req->'rows') loop
    if coalesce(btrim(ln->>'name'),'')='' then return ebda.err('يوجد سطر بدون اسم موظف'); end if;
    if not (ebda.num_ok(ln->>'salary') and ebda.num_ok(ln->>'net') and ebda.num_ok(ln->>'ded_total') and ebda.num_ok(ln->>'absent_days')
            and ebda.num_ok(ln->>'permissions') and ebda.num_ok(ln->>'deduct_days') and ebda.num_ok(ln->>'month_days') and ebda.num_ok(ln->>'allowances')
            and ebda.num_ok(ln->>'direct_ded') and ebda.num_ok(ln->>'leave_opening') and ebda.num_ok(ln->>'leave_used') and ebda.num_ok(ln->>'leave_balance')) then
      return ebda.err('قيمة رقمية غير صحيحة للموظف: '||(ln->>'name')); end if;
    if coalesce(ln->>'employee_id','')<>'' and not exists(select 1 from ebda.employees e where e.id=ln->>'employee_id' and e.school_id=sid) then
      return ebda.err('الموظف المطابق غير تابع لهذا المكان: '||(ln->>'name')); end if;
    if jsonb_typeof(coalesce(ln->'items','{}'::jsonb)) <> 'object' or exists(select 1 from jsonb_each_text(coalesce(ln->'items','{}'::jsonb)) a
         where not ebda.num_ok(a.value) or not exists(select 1 from ebda.payroll_components c where c.code = a.key)) then
      return ebda.err('عنصر راتب غير معروف أو قيمة غير صحيحة للموظف: '||(ln->>'name')); end if;
  end loop;
  if onx not in ('update','new_only') then return ebda.err('خيار غير معروف للسجلات الموجودة'); end if;
  insert into ebda.import_batches(id, kind, file_name, actor, actor_id, approve_mode, rows_n, school_id, month)
  values(bid, 'payroll', coalesce(req->>'file_name',''), u.name, u.id, '', jsonb_array_length(req->'rows'), sid, req->>'month');
  for ln in select * from jsonb_array_elements(req->'rows') loop
    lid := nullif(ln->>'employee_id','');
    nk := regexp_replace(coalesce(ln->>'national_id',''),'[^0-9]','','g');
    if lid is null and nk<>'' then select e.id into lid from ebda.employees e where e.school_id=sid and e.national_key=nk order by e.id limit 1; end if;
    if lid is null then select e.id into lid from ebda.employees e where e.school_id=sid and ebda.norm_txt(e.name)=ebda.norm_txt(ln->>'name') order by e.id limit 1; end if;
    if lid is null then
      lid := ebda.uid();
      insert into ebda.employees(id,school_id,category,name,job,national_id,national_key,account_no,bank,ebda_start,hire_date,base_salary,
          staff_group,assignment,work_type,insurance_status,emp_no,active,archived)
      values(lid, sid, case when ln->>'staff_group'='gov' then 'gov' else 'contract' end, btrim(ln->>'name'), coalesce(ln->>'job',''),
          coalesce(ln->>'national_id',''), nk, coalesce(ln->>'account_no',''), coalesce(ln->>'bank',''), coalesce(ln->>'start_date',''), coalesce(ln->>'start_date',''),
          coalesce(nullif(btrim(ln->>'salary'),'')::numeric,0), coalesce(ln->>'staff_group',''), coalesce(ln->>'assignment',''), coalesce(ln->>'work_type',''),
          coalesce(ln->>'insurance_status',''), coalesce(ln->>'emp_no',''), 'نعم','لا');
      n_emp := n_emp + 1;
    else
      update ebda.employees set job=coalesce(nullif(ln->>'job',''),job), assignment=coalesce(nullif(ln->>'assignment',''),assignment),
        work_type=coalesce(nullif(ln->>'work_type',''),work_type), staff_group=coalesce(nullif(ln->>'staff_group',''),staff_group),
        national_id=case when coalesce(national_id,'')='' then coalesce(ln->>'national_id','') else national_id end,
        national_key=case when coalesce(national_key,'')='' then nk else national_key end,
        account_no=coalesce(nullif(ln->>'account_no',''),account_no), bank=coalesce(nullif(ln->>'bank',''),bank),
        ebda_start=coalesce(nullif(ln->>'start_date',''),ebda_start), base_salary=coalesce(nullif(btrim(ln->>'salary'),'')::numeric,base_salary),
        insurance_status=coalesce(nullif(ln->>'insurance_status',''),insurance_status), emp_no=coalesce(nullif(ln->>'emp_no',''),emp_no)
      where id=lid;
    end if;
    if coalesce(ln->>'employee_only','')='1' then continue; end if;
    -- قسيمة الشهر: سطر واحد قائم لكل موظف لكل شهر (القسائم الملغاة تبقى تاريخاً ولا تُحدَّث)
    pid := null;
    select p.id into pid from ebda.payslips p where p.employee_id=lid and p.month=req->>'month' and coalesce(p.cancelled_at,'')='' order by p.id limit 1;
    if pid is null then
      pid := ebda.uid();
      insert into ebda.payslips(id,employee_id,emp_name,school_id,month,created_by,created_at,adjustments,import_batch,last_batch)
      values(pid, lid, btrim(ln->>'name'), sid, req->>'month', u.name, now()::text, '{}'::jsonb, bid, bid);
      n_new := n_new + 1;
    else
      if onx = 'new_only' then n_skip := n_skip + 1; continue; end if;   -- «استيراد السجلات الجديدة فقط»: الموجود لا يُمس
      if not snap ? pid then select * into ps from ebda.payslips where id = pid; snap := snap || jsonb_build_object(pid, to_jsonb(ps)); end if;
      n_upd := n_upd + 1;
    end if;
    -- تفصيل عناصر الملف (خصومات/استقطاعات/مستحقات) — يُستبدل عند إعادة الاستيراد فلا يتكرر (والسابق محفوظ فى لقطة الدفعة)
    if snap ? pid and not snap_items ? pid then
      snap_items := snap_items || jsonb_build_object(pid, coalesce((select jsonb_agg(to_jsonb(x)) from ebda.payslip_items x where x.payslip_id = pid and x.source = 'import'), '[]'::jsonb));
    end if;
    delete from ebda.payslip_items where payslip_id = pid and source = 'import';
    for it in select a.key code, a.value::numeric amt, c.kind from jsonb_each_text(coalesce(ln->'items','{}'::jsonb)) a join ebda.payroll_components c on c.code = a.key
              where nullif(btrim(a.value),'') is not null and a.value::numeric <> 0 loop
      insert into ebda.payslip_items(id, payslip_id, code, kind, amount, source, batch, created_by, item_date)
      values(ebda.uid(), pid, it.code, it.kind, it.amt, 'import', bid, u.name, req->>'month' || '-01');
    end loop;
    select coalesce(sum(amount) filter (where kind='earning'),0), coalesce(sum(amount) filter (where kind='deduction'),0), coalesce(sum(amount) filter (where kind='withholding'),0)
      into e_sum, d_sum, w_sum from ebda.payslip_items where payslip_id = pid and source = 'import';
    -- الصافى من الملف؛ وإن لم يرد: المستحقات − الخصومات − الاستقطاعات
    netv := case when coalesce(btrim(ln->>'net'),'') <> '' then (ln->>'net')::numeric
                 else coalesce(nullif(btrim(ln->>'salary'),'')::numeric,0) + coalesce(nullif(btrim(ln->>'allowances'),'')::numeric,0) + e_sum
                      - case when d_sum > 0 then d_sum else coalesce(nullif(btrim(ln->>'ded_total'),'')::numeric,0) end - w_sum end;
    update ebda.payslips set emp_name=btrim(ln->>'name'), staff_group=coalesce(ln->>'staff_group',''), job=coalesce(ln->>'job',''),
      insurance_status = coalesce(nullif(ln->>'insurance_status',''), (select nullif(insurance_status,'') from ebda.employees where id = lid), insurance_status),
      base=coalesce(nullif(btrim(ln->>'salary'),'')::numeric,0), allowances=coalesce(nullif(btrim(ln->>'allowances'),'')::numeric,0),
      gross=coalesce(nullif(btrim(ln->>'salary'),'')::numeric,0)+coalesce(nullif(btrim(ln->>'allowances'),'')::numeric,0),
      ded_total=coalesce(nullif(btrim(ln->>'ded_total'),'')::numeric,0), direct_ded=coalesce(nullif(btrim(ln->>'direct_ded'),'')::numeric,0),
      month_days=coalesce(nullif(btrim(ln->>'month_days'),'')::numeric,0), work_days=coalesce(nullif(btrim(ln->>'work_days'),'')::numeric,0),
      attend_days=coalesce(nullif(btrim(ln->>'attend_days'),'')::numeric,0), rest_days=coalesce(nullif(btrim(ln->>'rest_days'),'')::numeric,0),
      absent_days=coalesce(nullif(btrim(ln->>'absent_days'),'')::numeric,0), permissions=coalesce(nullif(btrim(ln->>'permissions'),'')::numeric,0),
      deduct_days=coalesce(nullif(btrim(ln->>'deduct_days'),'')::numeric,0),
      leave_opening=coalesce(nullif(btrim(ln->>'leave_opening'),'')::numeric,0), leave_used=coalesce(nullif(btrim(ln->>'leave_used'),'')::numeric,0),
      leave_balance=coalesce(nullif(btrim(ln->>'leave_balance'),'')::numeric,0),
      task_pct=coalesce(nullif(btrim(ln->>'task_pct'),'')::numeric,0), quality_pct=coalesce(nullif(btrim(ln->>'quality_pct'),'')::numeric,0),
      avg_pct=coalesce(nullif(btrim(ln->>'avg_pct'),'')::numeric,0),
      net_import=netv, note=coalesce(ln->>'note',''), source_file=coalesce(req->>'file_name',''),
      updated_at=now()::text, last_batch=bid
    where id=pid;
    perform ebda.slip_recalc(pid);
  end loop;
  if n_new + n_upd > 0 then
    insert into ebda.payroll_periods(id,school_id,month,status,file_name,imported_at,imported_by)
    values(ebda.uid(), sid, req->>'month', 'draft', coalesce(req->>'file_name',''), now()::text, u.name)
    on conflict (school_id,month) do update set file_name=excluded.file_name, imported_at=excluded.imported_at, imported_by=excluded.imported_by,
      status = case when ebda.payroll_periods.status = 'cancelled' then 'draft' else ebda.payroll_periods.status end,
      cancelled_at = '', cancelled_by = '', cancel_reason = '';
  end if;
  update ebda.import_batches set imported_n = n_new + n_upd, snapshot = jsonb_build_object('payslips', snap, 'items', snap_items),
    amount = coalesce((select sum(net) from ebda.payslips where last_batch = bid and coalesce(cancelled_at,'')=''),0),
    summary = jsonb_build_object('employees_added', n_emp, 'payslips_added', n_new, 'payslips_updated', n_upd, 'skipped_existing', n_skip, 'on_existing', onx)
  where id = bid;
  return jsonb_build_object('ok',true,'employees_added',n_emp,'payslips_added',n_new,'payslips_updated',n_upd,'skipped_existing',n_skip,'batch_id',bid);
end $ip$;

-- ============================================================================
--  (1) استيراد الموازنة (منقول من api_core كما هو: الدمج + الاستبدال) + تتبع الدفعة
-- ============================================================================
create or replace function ebda.import_budget(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $ib$
declare
  ln jsonb; sid text; lid text; newid text; lrow ebda.lines; n_new int := 0; n_upd int := 0; n_same int := 0;
  bid text := ebda.uid(); snap jsonb := '{}'::jsonb; replaced jsonb := '[]'::jsonb;
begin
  if not ebda.can(u,'budget.edit') then return ebda.err('لا صلاحية لاستيراد الموازنة'); end if;
  if coalesce(req->>'mode','') = 'merge' then
    if jsonb_typeof(coalesce(req->'lines','null'::jsonb)) <> 'array' or jsonb_array_length(req->'lines') = 0 then
      return ebda.err('لا توجد بنود للاستيراد'); end if;
    for ln in select * from jsonb_array_elements(req->'lines') loop
      sid := coalesce(nullif(ln->>'school_id',''), req->>'school_id');
      if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then
        return ebda.err('جهة غير موجودة فى السطر: '||coalesce(ln->>'name','')); end if;
      if not ebda.can_school(u, sid) then return ebda.err('الجهة ليست ضمن نطاقك: '||coalesce((select name from ebda.schools where id=sid),'')); end if;
      if coalesce(btrim(ln->>'name'),'')='' then return ebda.err('يوجد سطر بدون اسم بند'); end if;
      if coalesce(ln->>'allocated','0') !~ '^\s*[0-9]*\.?[0-9]*\s*$' then
        return ebda.err('مبلغ غير صحيح للبند: '||coalesce(ln->>'name','')); end if;
      if coalesce(ln->>'line_id','')<>'' and not exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and l.school_id=sid) then
        return ebda.err('البند المطابق غير موجود فى الجهة: '||coalesce(ln->>'name','')); end if;
    end loop;
    insert into ebda.import_batches(id, kind, file_name, actor, actor_id, approve_mode, rows_n, school_id)
    values(bid, 'budget', coalesce(req->>'file_name',''), u.name, u.id, 'merge', jsonb_array_length(req->'lines'), coalesce(req->>'school_id',''));
    for ln in select * from jsonb_array_elements(req->'lines') loop
      sid := coalesce(nullif(ln->>'school_id',''), req->>'school_id');
      lid := nullif(ln->>'line_id','');
      if lid is null then
        select l.id into lid from ebda.lines l where l.school_id=sid and coalesce(l.deleted_at,'')=''
          and l.catalog_id = ebda.catalog_resolve(ln->>'name') limit 1;
      end if;
      if lid is null then
        select l.id into lid from ebda.lines l where l.school_id=sid and coalesce(l.deleted_at,'')=''
          and ebda.norm_txt(l.name)=ebda.norm_txt(ln->>'name') and ebda.norm_txt(l.section)=ebda.norm_txt(coalesce(ln->>'section','')) limit 1;
      end if;
      if lid is null then
        insert into ebda.lines(id,school_id,section,name,allocated,note,monthly_plan,import_batch,last_batch)
        values(ebda.uid(), sid, coalesce(ln->>'section',''), btrim(ln->>'name'), coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0),
               coalesce(ln->>'note',''), coalesce(ln->>'monthly_plan',''), bid, bid);
        n_new := n_new + 1;
      else
        select * into lrow from ebda.lines where id=lid;
        if lrow.allocated is distinct from coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0)
           or (coalesce(ln->>'note','')<>'' and coalesce(lrow.note,'')<>(ln->>'note'))
           or (coalesce(ln->>'monthly_plan','')<>'' and coalesce(lrow.monthly_plan,'')<>(ln->>'monthly_plan'))
           or (coalesce(ln->>'rename','')='1' and (lrow.name<>btrim(ln->>'name') or coalesce(lrow.section,'')<>coalesce(ln->>'section',''))) then
          if not snap ? lid then snap := snap || jsonb_build_object(lid, to_jsonb(lrow)); end if;
          update ebda.lines set allocated=coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0),
            note=case when coalesce(ln->>'note','')<>'' then ln->>'note' else note end,
            monthly_plan=case when coalesce(ln->>'monthly_plan','')<>'' then ln->>'monthly_plan' else monthly_plan end,
            name=case when coalesce(ln->>'rename','')='1' then btrim(ln->>'name') else name end,
            section=case when coalesce(ln->>'rename','')='1' then coalesce(ln->>'section',section) else section end,
            last_batch=bid
          where id=lid;
          n_upd := n_upd + 1;
        else
          n_same := n_same + 1;
        end if;
      end if;
    end loop;
    update ebda.import_batches set imported_n = n_new + n_upd, snapshot = jsonb_build_object('lines', snap),
      amount = coalesce((select sum(allocated) from ebda.lines where last_batch = bid),0),
      summary = jsonb_build_object('added', n_new, 'updated', n_upd, 'unchanged', n_same) where id = bid;
    return jsonb_build_object('ok',true,'added',n_new,'updated',n_upd,'unchanged',n_same,'count',n_new+n_upd+n_same,'batch_id',bid);
  end if;

  sid := req->>'school_id';
  if req ? 'newSchool' then
    if ebda.rk(u)<>'admin' then return ebda.err('إنشاء جهة جديدة للأدمن فقط'); end if;
    newid := ebda.uid();
    insert into ebda.schools(id,name,type,period,students,active,category)
    values(newid, req#>>'{newSchool,name}', coalesce(req#>>'{newSchool,type}',''), coalesce(req#>>'{newSchool,period}',''),
       0, 'نعم', coalesce(req#>>'{newSchool,category}','school'));
    sid := newid;
  elsif not ebda.can_school(u, sid) then return ebda.err('هذه الجهة ليست ضمن نطاقك');
  end if;
  if exists(select 1 from ebda.expenses e join ebda.lines l on l.id=e.line_id where l.school_id=sid) then
    return ebda.err('هذه الجهة عليها مصروفات مرتبطة ببنودها — لا يمكن استبدال الموازنة بالكامل. عدّل البنود من شاشة الموازنات');
  end if;
  -- لقطة البنود المستبدلة (تُعاد عند إلغاء الدفعة)
  replaced := coalesce((select jsonb_agg(to_jsonb(l)) from ebda.lines l where l.school_id = sid), '[]'::jsonb);
  insert into ebda.import_batches(id, kind, file_name, actor, actor_id, approve_mode, rows_n, school_id)
  values(bid, 'budget', coalesce(req->>'file_name',''), u.name, u.id, 'replace', jsonb_array_length(coalesce(req->'lines','[]'::jsonb)), sid);
  delete from ebda.lines where school_id = sid;
  for ln in select * from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) loop
    insert into ebda.lines(id,school_id,section,name,allocated,note,import_batch,last_batch)
    values(ebda.uid(), sid, coalesce(ln->>'section',''), coalesce(ln->>'name',''), coalesce((ln->>'allocated')::numeric,0), '', bid, bid);
  end loop;
  update ebda.import_batches set imported_n = jsonb_array_length(coalesce(req->'lines','[]'::jsonb)), snapshot = jsonb_build_object('replaced', replaced),
    amount = coalesce((select sum(allocated) from ebda.lines where import_batch = bid),0),
    summary = jsonb_build_object('added', jsonb_array_length(coalesce(req->'lines','[]'::jsonb)), 'replaced', jsonb_array_length(replaced)) where id = bid;
  return jsonb_build_object('ok',true,'school_id',sid,'count',jsonb_array_length(coalesce(req->'lines','[]'::jsonb)),'batch_id',bid);
end $ib$;

-- ============================================================================
--  (2) استيراد ملف المؤثرات — معاينة ثم تنفيذ
-- ============================================================================
create or replace function ebda.import_effects(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $ief$
declare
  sid text := req->>'school_id'; mon text := req->>'month'; commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
  create_missing boolean := coalesce(req->>'create_missing','') in ('1','true');
  r jsonb := ebda.eff_rules(); ln jsonb; i int := 0; out_rows jsonb := '[]'::jsonb; errs jsonb; warns jsonb; eid text; how text; n_match int;
  code text; nm text; c jsonb; pid text; ps ebda.payslips; seen text[] := '{}'; seen_code text[] := '{}';
  n_err int := 0; n_unknown int := 0; n_new int := 0; n_upd int := 0; n_emp int := 0; n_ok int := 0;
  bid text := ebda.uid(); snap jsonb := '{}'::jsonb; tot jsonb; t_contract numeric := 0; t_ot numeric := 0; t_ded numeric := 0; t_net numeric := 0;
  f text; adj jsonb; exc jsonb := '[]'::jsonb; grp text;
begin
  if not ebda.can(u,'payroll.import') then return ebda.err('صلاحية استيراد الرواتب مطلوبة'); end if;
  if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then return ebda.err('اختر المدرسة / المكان'); end if;
  if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
  if coalesce(mon,'') !~ '^[0-9]{4}-[0-9]{2}$' then return ebda.err('اختر شهر الرواتب'); end if;
  if jsonb_typeof(coalesce(req->'rows','null'::jsonb))<>'array' or jsonb_array_length(req->'rows')=0 then return ebda.err('لا توجد بيانات فى الملف'); end if;
  if jsonb_array_length(req->'rows') > 3000 then return ebda.err('3000 سطر كحد أقصى'); end if;
  if commit_ and ebda.month_locked(sid, mon) then return ebda.err('رواتب هذا الشهر معتمدة — يجب إعادة فتحها (للأدمن) قبل استيراد المؤثرات'); end if;

  for ln in select * from jsonb_array_elements(req->'rows') loop
    i := i + 1; errs := '[]'::jsonb; warns := '[]'::jsonb; eid := null; how := '';
    code := btrim(coalesce(ln->>'code','')); nm := btrim(coalesce(ln->>'name',''));
    if nm = '' and code = '' then errs := errs || to_jsonb('بدون اسم أو كود'::text); end if;
    foreach f in array array['contract_net','work_days','ot_hours','ot_days','ded_hours','ded_days'] loop
      if not ebda.num_ok(ln->>f) or coalesce(nullif(btrim(ln->>f),'')::numeric,0) < 0 then
        errs := errs || to_jsonb(('قيمة غير صحيحة فى «' || case f when 'contract_net' then 'صافى الراتب التعاقدى' when 'work_days' then 'عدد أيام العمل'
          when 'ot_hours' then 'إضافى ساعة' when 'ot_days' then 'إضافى يوم' when 'ded_hours' then 'خصم ساعة' else 'خصم يوم' end || '»')::text);
      end if;
    end loop;
    if jsonb_array_length(errs) = 0 then
      if coalesce(btrim(ln->>'contract_net'),'') = '' then errs := errs || to_jsonb('صافى الراتب التعاقدى مفقود'::text); end if;
      if coalesce(nullif(btrim(ln->>'work_days'),'')::numeric,0) > 31 then errs := errs || to_jsonb('عدد أيام العمل أكبر من 31'::text); end if;
      if coalesce(nullif(btrim(ln->>'ded_days'),'')::numeric,0) > 31 then errs := errs || to_jsonb('أيام الخصم أكبر من 31'::text); end if;
    end if;
    -- المطابقة: الكود (رقم الموظف) ثم الاسم — داخل نفس المدرسة فقط
    if code <> '' then
      select count(*), min(e.id) into n_match, eid from ebda.employees e where e.school_id = sid and btrim(coalesce(e.emp_no,'')) = code;
      if n_match = 1 then how := 'code'; elsif n_match > 1 then eid := null; errs := errs || to_jsonb(('الكود ' || code || ' مكرر لأكثر من موظف')::text); end if;
      if code = any(seen_code) then errs := errs || to_jsonb(('الكود ' || code || ' مكرر فى الملف')::text); end if;
      seen_code := seen_code || code;
    end if;
    if eid is null and how = '' and nm <> '' and not exists(select 1 from jsonb_array_elements_text(errs) x where x like 'الكود%مكرر لأكثر%') then
      select count(*), min(e.id) into n_match, eid from ebda.employees e where e.school_id = sid and ebda.norm_txt(e.name) = ebda.norm_txt(nm);
      if n_match = 1 then how := 'name';
        if code <> '' then warns := warns || to_jsonb('الكود غير مسجل للموظف — سيُسجَّل'::text); end if;
      elsif n_match > 1 then eid := null; errs := errs || to_jsonb('الاسم يطابق أكثر من موظف — أضف الكود'::text);
      else eid := null; end if;
    end if;
    if eid is not null and eid = any(seen) then errs := errs || to_jsonb('الموظف مكرر فى الملف'::text); end if;
    if eid is not null then seen := seen || eid; end if;
    if eid is null and jsonb_array_length(errs) = 0 then
      n_unknown := n_unknown + 1;
      warns := warns || to_jsonb(case when create_missing then 'موظف غير مسجل — سيُضاف للمدرسة' else 'موظف غير مسجل — لن يُستورد (فعّل «إضافة غير المسجلين» أو سجّله أولاً)' end);
    end if;
    pid := null;
    if eid is not null then
      select p.id into pid from ebda.payslips p where p.employee_id = eid and p.month = mon and coalesce(p.cancelled_at,'') = '' order by p.id limit 1;
      if pid is not null and exists(select 1 from ebda.payslips p where p.id = pid and coalesce(p.net_import,0) > 0) then
        warns := warns || to_jsonb('للموظف صافى من ملف الحضور — سيُحسب الصافى من المؤثرات مرة واحدة (لا خصم مزدوج)'::text);
      end if;
    end if;
    adj := coalesce((select p.adjustments from ebda.payslips p where p.id = pid), '{}'::jsonb);
    c := case when jsonb_array_length(errs) = 0 then ebda.eff_calc(coalesce(nullif(btrim(ln->>'contract_net'),'')::numeric,0), nullif(btrim(ln->>'work_days'),'')::numeric,
           coalesce(nullif(btrim(ln->>'ot_hours'),'')::numeric,0), coalesce(nullif(btrim(ln->>'ot_days'),'')::numeric,0),
           coalesce(nullif(btrim(ln->>'ded_hours'),'')::numeric,0), coalesce(nullif(btrim(ln->>'ded_days'),'')::numeric,0), adj, r) else null end;
    if jsonb_array_length(errs) > 0 then n_err := n_err + 1; end if;
    if c is not null and (eid is not null or create_missing) then
      n_ok := n_ok + 1;
      t_contract := t_contract + coalesce((c->>'base_due')::numeric,0); t_ot := t_ot + (c->>'ot_amount')::numeric;
      t_ded := t_ded + (c->>'ded_amount')::numeric; t_net := t_net + (c->>'net')::numeric;
    end if;
    if eid is null and jsonb_array_length(errs) = 0 then exc := exc || jsonb_build_object('row', coalesce(ln->>'row', i::text), 'name', nm, 'code', code, 'reason', 'موظف غير مسجل'); end if;
    out_rows := out_rows || jsonb_build_object('row', coalesce(ln->>'row', i::text), 'code', code, 'name', nm, 'employee_id', coalesce(eid,''),
      'match', case when eid is not null then how when jsonb_array_length(errs) > 0 then 'error' else 'unknown' end,
      'slip', case when pid is not null then 'update' when eid is not null or create_missing then 'new' else '' end,
      'insurance_status', coalesce(ln->>'insurance_status',''), 'job', coalesce(ln->>'job',''),
      'contract_net', ln->>'contract_net', 'work_days', ln->>'work_days', 'ot_hours', ln->>'ot_hours', 'ot_days', ln->>'ot_days',
      'ded_hours', ln->>'ded_hours', 'ded_days', ln->>'ded_days', 'summary', coalesce(ln->>'summary',''), 'note', coalesce(ln->>'note',''),
      'calc', c, 'errors', errs, 'warnings', warns);
  end loop;

  -- مطابقة إجماليات الشيت المرجعى (إن أُرسلت)
  tot := coalesce((select jsonb_agg(jsonb_build_object('category', t->>'category', 'amount', ebda.imp_num(t->>'amount'),
            'computed', case when t->>'category' like '%حكوم%' then
                (select coalesce(sum((x->'calc'->>'net')::numeric),0) from jsonb_array_elements(out_rows) x where x->'calc' is not null and x->>'insurance_status' like '%حكوم%' and (x->>'employee_id' <> '' or create_missing))
              when t->>'category' like '%خاص%' or t->>'category' like '%رواتب%' then
                (select coalesce(sum((x->'calc'->>'net')::numeric),0) from jsonb_array_elements(out_rows) x where x->'calc' is not null and x->>'insurance_status' not like '%حكوم%' and (x->>'employee_id' <> '' or create_missing))
              else null end))
          from jsonb_array_elements(coalesce(req->'totals','[]'::jsonb)) t where coalesce(t->>'category','') <> ''), '[]'::jsonb);

  if not commit_ then
    return jsonb_build_object('ok', true, 'mode', 'preview', 'rules', r, 'rule_approved', coalesce(r->>'approved','') in ('true','1','yes'),
      'rows', out_rows, 'totals_check', tot,
      'summary', jsonb_build_object('rows', i, 'ok', n_ok, 'errors', n_err, 'unknown', n_unknown,
        'contract', t_contract, 'ot', t_ot, 'ded', t_ded, 'net', t_net,
        'new', (select count(*) from jsonb_array_elements(out_rows) x where x->>'slip' = 'new' and jsonb_array_length(x->'errors') = 0),
        'update', (select count(*) from jsonb_array_elements(out_rows) x where x->>'slip' = 'update' and jsonb_array_length(x->'errors') = 0)));
  end if;
  if n_err > 0 then return ebda.err('صحّح الأخطاء فى الملف أولاً (' || n_err || ' سطر) — لم يُحفظ شىء'); end if;
  if n_ok = 0 then return ebda.err('لا توجد سطور قابلة للاستيراد (كل الموظفين غير مسجلين)'); end if;

  insert into ebda.import_batches(id, kind, file_name, actor, actor_id, approve_mode, rows_n, school_id, month, exceptions)
  values(bid, 'effects', coalesce(req->>'file_name',''), u.name, u.id, coalesce(req->>'sheet',''), i, sid, mon, exc);
  for ln in select * from jsonb_array_elements(out_rows) loop
    eid := nullif(ln->>'employee_id','');
    if eid is null and not create_missing then continue; end if;
    grp := case when ln->>'insurance_status' like '%حكوم%' then 'gov' else 'private' end;
    if eid is null then
      eid := ebda.uid();
      insert into ebda.employees(id,school_id,category,name,job,emp_no,insurance_status,base_salary,staff_group,active,archived)
      values(eid, sid, case when grp='gov' then 'gov' else 'contract' end, ln->>'name', coalesce(ln->>'job',''), coalesce(ln->>'code',''),
             coalesce(ln->>'insurance_status',''), coalesce(nullif(btrim(ln->>'contract_net'),'')::numeric,0), grp, 'نعم', 'لا');
      n_emp := n_emp + 1;
    else
      -- البيانات الثابتة تُكمَّل فقط (لا تُستبدل بيانات مسجلة)
      update ebda.employees set emp_no = case when coalesce(emp_no,'') = '' then coalesce(ln->>'code','') else emp_no end,
        insurance_status = coalesce(nullif(ln->>'insurance_status',''), insurance_status),
        job = case when coalesce(job,'') = '' then coalesce(ln->>'job','') else job end
      where id = eid;
    end if;
    pid := null;
    select p.id into pid from ebda.payslips p where p.employee_id = eid and p.month = mon and coalesce(p.cancelled_at,'') = '' order by p.id limit 1;
    if pid is null then
      pid := ebda.uid();
      insert into ebda.payslips(id,employee_id,emp_name,school_id,month,created_by,created_at,adjustments,import_batch,last_batch,staff_group,job,base,gross,net_import)
      values(pid, eid, ln->>'name', sid, mon, u.name, now()::text, '{}'::jsonb, bid, bid, grp, coalesce(ln->>'job',''),
             coalesce(nullif(btrim(ln->>'contract_net'),'')::numeric,0), coalesce(nullif(btrim(ln->>'contract_net'),'')::numeric,0), 0);
      n_new := n_new + 1;
    else
      if not snap ? pid then select * into ps from ebda.payslips where id = pid; snap := snap || jsonb_build_object(pid, to_jsonb(ps)); end if;
      n_upd := n_upd + 1;
    end if;
    -- إعادة الاستيراد تستبدل قيم المؤثرات (لا تُضاف فوقها) → لا احتساب مزدوج
    update ebda.payslips set emp_code = coalesce(ln->>'code',''), insurance_status = coalesce(ln->>'insurance_status',''),
      contract_net = coalesce(nullif(btrim(ln->>'contract_net'),'')::numeric,0), eff_work_days = nullif(btrim(ln->>'work_days'),'')::numeric,
      ot_hours = coalesce(nullif(btrim(ln->>'ot_hours'),'')::numeric,0), ot_days = coalesce(nullif(btrim(ln->>'ot_days'),'')::numeric,0),
      ded_hours = coalesce(nullif(btrim(ln->>'ded_hours'),'')::numeric,0), ded_days = coalesce(nullif(btrim(ln->>'ded_days'),'')::numeric,0),
      effects_summary = coalesce(ln->>'summary',''), effects_note = coalesce(ln->>'note',''),
      job = case when coalesce(job,'') = '' then coalesce(ln->>'job','') else job end,
      effects_batch = bid, last_batch = bid, source_file = coalesce(req->>'file_name',''), updated_at = now()::text
    where id = pid;
    perform ebda.slip_recalc(pid);
  end loop;
  insert into ebda.payroll_periods(id,school_id,month,status,file_name,imported_at,imported_by)
  values(ebda.uid(), sid, mon, 'draft', coalesce(req->>'file_name',''), now()::text, u.name)
  on conflict (school_id,month) do update set file_name=excluded.file_name, imported_at=excluded.imported_at, imported_by=excluded.imported_by,
    status = case when ebda.payroll_periods.status = 'cancelled' then 'draft' else ebda.payroll_periods.status end,
    cancelled_at = '', cancelled_by = '', cancel_reason = '';
  for ln in select * from jsonb_array_elements(tot) loop
    if (ln->>'amount') is null then continue; end if;
    insert into ebda.payroll_totals(id, school_id, month, category, amount, source_file, batch, created_by)
    values(ebda.uid(), sid, mon, ln->>'category', (ln->>'amount')::numeric, coalesce(req->>'file_name',''), bid, u.name)
    on conflict (school_id, month, category) do update set amount = excluded.amount, source_file = excluded.source_file, batch = excluded.batch,
      created_by = excluded.created_by, created_at = now()::text;
  end loop;
  update ebda.import_batches set imported_n = n_new + n_upd, snapshot = jsonb_build_object('payslips', snap),
    amount = coalesce((select sum(net) from ebda.payslips where last_batch = bid and coalesce(cancelled_at,'')=''),0),
    summary = jsonb_build_object('employees_added', n_emp, 'payslips_added', n_new, 'payslips_updated', n_upd, 'unknown', n_unknown,
                                 'contract', t_contract, 'ot', t_ot, 'ded', t_ded, 'net', t_net)
  where id = bid;
  return jsonb_build_object('ok', true, 'mode', 'commit', 'batch_id', bid, 'employees_added', n_emp, 'payslips_added', n_new, 'payslips_updated', n_upd,
    'skipped_unknown', case when create_missing then 0 else n_unknown end, 'totals_check', tot,
    'summary', jsonb_build_object('contract', t_contract, 'ot', t_ot, 'ded', t_ded, 'net', t_net));
end $ief$;

-- إعادة حساب قسائم الشهور غير المعتمدة بعد تغيير القاعدة
create or replace function ebda.effects_recalc_open() returns int language plpgsql security definer set search_path = ebda as $ro$
declare p record; n int := 0;
begin
  for p in select z.id from ebda.payslips z where z.contract_net is not null and coalesce(z.cancelled_at,'') = ''
             and not ebda.month_locked(z.school_id, z.month) loop
    perform ebda.slip_recalc(p.id); n := n + 1;
  end loop;
  return n;
end $ro$;

-- ============================================================================
--  (1) الإلغاء الجماعى — أنواع جديدة (قسائم · كشف شهر · بنود موازنة · موازنة كاملة) فوق أنواع v9
-- ============================================================================
create or replace function ebda.bulk_cancel2(u ebda.users, p_kind text, p_ids text[], p_reason text, p_commit boolean) returns jsonb
language plpgsql security definer set search_path = ebda as $bc2$
declare
  id_ text; ok_rows jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb; amt numeric := 0; budget_fx numeric := 0;
  ps ebda.payslips; l ebda.lines; lbl text; sid text; mon text; n int; v numeric; reasons text; rsn text := btrim(coalesce(p_reason,''));
begin
  if p_kind not in ('payslips','payroll_month','lines','budget') then
    return ebda.bulk_cancel(u, p_kind, p_ids, p_reason, p_commit);
  end if;
  if coalesce(cardinality(p_ids),0) = 0 then return ebda.err('لم يتم تحديد أى سجل'); end if;
  if cardinality(p_ids) > 2000 then return ebda.err('2000 سجل كحد أقصى فى العملية الواحدة'); end if;
  if p_commit and length(rsn) < 3 then return ebda.err('اكتب سبب الإلغاء'); end if;
  foreach id_ in array (select array_agg(distinct x) from unnest(p_ids) x) loop
    if p_kind = 'payslips' then
      select * into ps from ebda.payslips where id = id_;
      if ps.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجودة'); continue; end if;
      lbl := coalesce(ps.emp_name,'') || ' · ' || ps.month || ' · ' || coalesce((select name from ebda.schools where id = ps.school_id),'');
      if not ebda.can_school(u, ps.school_id) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'خارج نطاقك'); continue; end if;
      if coalesce(ps.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغاة بالفعل'); continue; end if;
      if ebda.month_locked(ps.school_id, ps.month) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'رواتب الشهر معتمدة — أعد فتحها أولاً'); continue; end if;
      amt := amt + coalesce(ps.net,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', ps.net, 'note', 'القسيمة فقط — بقية كشف الشهر كما هو');
      if p_commit then
        update ebda.payslips set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn, updated_at = now()::text where id = ps.id;
      end if;
    elsif p_kind = 'payroll_month' then
      sid := split_part(id_, '|', 1); mon := split_part(id_, '|', 2);
      lbl := 'كشف ' || mon || ' · ' || coalesce((select name from ebda.schools where id = sid), sid);
      if not exists(select 1 from ebda.schools where id = sid) or mon !~ '^[0-9]{4}-[0-9]{2}$' then
        skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'غير موجود'); continue; end if;
      if not ebda.can_school(u, sid) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'خارج نطاقك'); continue; end if;
      if ebda.month_locked(sid, mon) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'رواتب الشهر معتمدة — أعد فتحها أولاً'); continue; end if;
      select count(*), coalesce(sum(net),0) into n, v from ebda.payslips where school_id = sid and month = mon and coalesce(cancelled_at,'') = '';
      if n = 0 then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'لا توجد قسائم قائمة'); continue; end if;
      amt := amt + v;
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', v, 'count', n, 'note', 'تُلغى ' || n || ' قسيمة — بيانات العاملين تبقى');
      if p_commit then
        update ebda.payslips set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = 'إلغاء كشف الشهر: ' || rsn, updated_at = now()::text
        where school_id = sid and month = mon and coalesce(cancelled_at,'') = '';
        update ebda.payroll_periods set status = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn
        where school_id = sid and month = mon;
      end if;
    elsif p_kind = 'lines' then
      select * into l from ebda.lines where id = id_;
      if l.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      lbl := coalesce((select name from ebda.schools where id = l.school_id),'') || ' · ' || coalesce(l.name,'');
      if not ebda.can_school(u, l.school_id) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'خارج نطاقك'); continue; end if;
      if coalesce(l.deleted_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى بالفعل'); continue; end if;
      reasons := ebda.line_links(l.id);
      if reasons <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', reasons); continue; end if;
      amt := amt + coalesce(l.allocated,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', l.allocated, 'note', 'البند فقط — الموازنة وبقية بنودها كما هى');
      if p_commit then
        update ebda.lines set deleted_at = now()::text, deleted_by = u.name, delete_reason = 'إلغاء: ' || rsn where id = l.id;
      end if;
    else
      sid := id_;
      lbl := 'موازنة ' || coalesce((select name from ebda.schools where id = sid), sid);
      if not exists(select 1 from ebda.schools where id = sid) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'غير موجودة'); continue; end if;
      if not ebda.can_school(u, sid) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'خارج نطاقك'); continue; end if;
      select count(*), coalesce(sum(allocated),0) into n, v from ebda.lines where school_id = sid and coalesce(deleted_at,'') = '';
      if n = 0 then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'لا توجد بنود قائمة'); continue; end if;
      reasons := (select string_agg(x, ' · ') from (select distinct ebda.line_links(z.id) x from ebda.lines z
                   where z.school_id = sid and coalesce(z.deleted_at,'') = '') q where x <> '');
      if coalesce(reasons,'') <> '' then
        skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'بنود مرتبطة بحركات: ' || reasons || ' — ألغِها أولاً أو ألغِ البنود غير المرتبطة فقط'); continue; end if;
      amt := amt + v;
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', v, 'count', n, 'note', 'تُلغى ' || n || ' بند (تبقى تاريخياً ويمكن استرجاعها)');
      if p_commit then
        update ebda.lines set deleted_at = now()::text, deleted_by = u.name, delete_reason = 'إلغاء الموازنة: ' || rsn
        where school_id = sid and coalesce(deleted_at,'') = '';
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', case when p_commit then 'commit' else 'preview' end, 'kind', p_kind,
    'ok_n', jsonb_array_length(ok_rows), 'skip_n', jsonb_array_length(skip), 'amount', amt,
    'effect', jsonb_build_object('budget_spent', 0, 'custody_spent', 0, 'custody_received', 0),
    'rows', ok_rows, 'skipped', skip);
end $bc2$;

-- سبب منع إلغاء بند موازنة (حركات قائمة مرتبطة به) — فارغ = يمكن إلغاؤه
create or replace function ebda.line_links(p_line text) returns text language sql stable security definer set search_path = ebda as $$
  select coalesce(string_agg(x, ' · '), '') from (
    select 'عليه ' || count(*) || ' مصروف قائم' x from ebda.expenses e where e.line_id = p_line and coalesce(e.cancelled_at,'') = '' having count(*) > 0
    union all
    select 'موزع على ' || count(*) || ' عهدة' from ebda.custody_lines cl join ebda.custodies c on c.id = cl.custody_id
      where cl.line_id = p_line and coalesce(cl.cancelled_at,'') = '' and coalesce(c.status,'') <> 'cancelled' having count(*) > 0
    union all
    select 'عليه ' || count(*) || ' طلب عهدة قيد الاعتماد' from ebda.request_items it join ebda.requests r on r.id = it.request_id
      where it.line_id = p_line and r.status in ('pending_supervisor','pending_accountant','needs_info') and coalesce(it.decision,'') not in ('cancelled','rejected') having count(*) > 0
  ) q $$;

-- ============================================================================
--  (1) إلغاء دفعة استيراد كاملة — معاينة العدد والقيمة ثم التنفيذ (لا تمس سجلات خارج الدفعة)
-- ============================================================================
create or replace function ebda.batch_cancel(u ebda.users, p_id text, p_reason text, p_commit boolean) returns jsonb
language plpgsql security definer set search_path = ebda as $bk$
declare
  b ebda.import_batches; rsn text := btrim(coalesce(p_reason,'')); rows_ jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb;
  n_cancel int := 0; n_restore int := 0; amt numeric := 0; k text; bef jsonb; ps ebda.payslips; l ebda.lines; why text; res jsonb;
  n_e int; v numeric; n_set int;
begin
  select * into b from ebda.import_batches where id = p_id;
  if b.id is null then return ebda.err('دفعة الاستيراد غير موجودة'); end if;
  if coalesce(b.reverted_at,'') <> '' then return ebda.err('تم إلغاء هذه الدفعة من قبل (' || b.reverted_at || ' بواسطة ' || coalesce(b.reverted_by,'') || ')'); end if;
  if p_commit and length(rsn) < 3 then return ebda.err('اكتب سبب إلغاء الدفعة'); end if;
  if coalesce(b.school_id,'') <> '' and not ebda.can_school(u, b.school_id) then return ebda.err('الدفعة خارج نطاقك'); end if;

  if coalesce(b.kind,'expenses') in ('expenses','') then
    select count(*), coalesce(sum(e.amount),0) into n_e, v from ebda.expenses e where e.import_batch = b.id and coalesce(e.cancelled_at,'') = '' and coalesce(e.settled,'') not like '%نعم%';
    select count(*) into n_set from ebda.expenses e where e.import_batch = b.id and coalesce(e.cancelled_at,'') = '' and coalesce(e.settled,'') like '%نعم%';
    if not p_commit then
      return jsonb_build_object('ok', true, 'mode', 'preview', 'kind', 'expenses', 'file_name', b.file_name, 'cancel_n', n_e, 'restore_n', 0, 'amount', v,
        'skip_n', n_set, 'custodies_n', (select count(*) from ebda.custodies c where c.import_batch = b.id and coalesce(c.status,'open') = 'open'),
        'skipped', case when n_set > 0 then jsonb_build_array(jsonb_build_object('label', n_set || ' مصروف مسوّى', 'reason', 'المسوّى لا يُلغى ضمن الدفعة — ألغِه منفرداً بعد المراجعة')) else '[]'::jsonb end,
        'rows', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'label', coalesce(e.txn_no,'') || ' · ' || coalesce(e.description,''), 'amount', e.amount))
                 from (select * from ebda.expenses e where e.import_batch = b.id and coalesce(e.cancelled_at,'') = '' and coalesce(e.settled,'') not like '%نعم%' order by e.date limit 300) e), '[]'::jsonb));
    end if;
    res := ebda.revert_import(u, b.id, rsn);
    if res ? 'error' then return res; end if;
    update ebda.import_batches set revert_reason = rsn, revert_result = res where id = b.id;
    return res || jsonb_build_object('mode', 'commit', 'kind', 'expenses', 'cancel_n', res->'cancelled_expenses', 'amount', v);
  end if;

  if b.kind in ('payroll','effects') then
    if ebda.month_locked(b.school_id, b.month) then return ebda.err('رواتب ' || b.month || ' معتمدة — أعد فتحها (للأدمن) قبل إلغاء الدفعة'); end if;
    -- القسائم التى أنشأتها الدفعة: تُلغى (إن لم تعدّلها دفعة لاحقة)
    for ps in select * from ebda.payslips where import_batch = b.id and coalesce(cancelled_at,'') = '' order by emp_name loop
      if ps.last_batch <> b.id then
        skip := skip || jsonb_build_object('id', ps.id, 'label', ps.emp_name, 'reason', 'عُدّلت بدفعة لاحقة — ألغِ الدفعة الأحدث أولاً'); continue; end if;
      n_cancel := n_cancel + 1; amt := amt + coalesce(ps.net,0);
      rows_ := rows_ || jsonb_build_object('id', ps.id, 'label', ps.emp_name, 'amount', ps.net, 'op', 'cancel');
      if p_commit then update ebda.payslips set cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = 'إلغاء دفعة استيراد: ' || rsn where id = ps.id; end if;
    end loop;
    -- القسائم الموجودة التى عدّلتها الدفعة: تعود لقيمها السابقة
    for k, bef in select * from jsonb_each(coalesce(b.snapshot->'payslips','{}'::jsonb)) loop
      select * into ps from ebda.payslips where id = k;
      if ps.id is null or coalesce(ps.cancelled_at,'') <> '' then continue; end if;
      if ps.last_batch <> b.id then
        skip := skip || jsonb_build_object('id', ps.id, 'label', ps.emp_name, 'reason', 'عُدّلت بدفعة لاحقة — ألغِ الدفعة الأحدث أولاً'); continue; end if;
      n_restore := n_restore + 1;
      rows_ := rows_ || jsonb_build_object('id', ps.id, 'label', ps.emp_name, 'amount', ps.net, 'before', bef->'net', 'op', 'restore');
      if p_commit then
        perform ebda.restore_row('payslips', bef);
        if b.snapshot->'items' ? k then
          delete from ebda.payslip_items where payslip_id = k and source = 'import';
          insert into ebda.payslip_items select * from jsonb_populate_recordset(null::ebda.payslip_items, b.snapshot->'items'->k);
        end if;
      end if;
    end loop;
    if p_commit then
      if not exists(select 1 from ebda.payslips where school_id = b.school_id and month = b.month and coalesce(cancelled_at,'') = '') then
        update ebda.payroll_periods set status = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = 'إلغاء دفعة استيراد: ' || rsn
        where school_id = b.school_id and month = b.month;
      end if;
      if b.kind = 'effects' then delete from ebda.payroll_totals where batch = b.id; end if;
    end if;
  elsif b.kind = 'needs' then   -- طلبات الاحتياجات المستوردة: تُلغى (تبقى تاريخاً) ما لم تتحول لعهدة
    for k, bef in select r.id, to_jsonb(r) from ebda.requests r where r.import_batch = b.id and coalesce(r.status,'') <> 'cancelled' order by r.req_no loop
      if bef->>'status' in ('transferred','spent','settled') then
        skip := skip || jsonb_build_object('id', k, 'label', bef->>'req_no', 'reason', 'الطلب حُوِّل لعهدة — ألغِ العهدة أو مصروفاتها'); continue; end if;
      n_cancel := n_cancel + 1; amt := amt + coalesce((bef->>'total')::numeric,0);
      rows_ := rows_ || jsonb_build_object('id', k, 'label', bef->>'req_no', 'amount', bef->'total', 'op', 'cancel');
      if p_commit then update ebda.requests set status = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = 'إلغاء دفعة استيراد: ' || rsn where id = k; end if;
    end loop;
  elsif b.kind = 'budget' then
    for l in select * from ebda.lines where import_batch = b.id and coalesce(deleted_at,'') = '' order by name loop
      if l.last_batch <> b.id then skip := skip || jsonb_build_object('id', l.id, 'label', l.name, 'reason', 'عُدّل بدفعة لاحقة'); continue; end if;
      why := ebda.line_links(l.id);
      if why <> '' then skip := skip || jsonb_build_object('id', l.id, 'label', l.name, 'reason', why); continue; end if;
      n_cancel := n_cancel + 1; amt := amt + coalesce(l.allocated,0);
      rows_ := rows_ || jsonb_build_object('id', l.id, 'label', l.name, 'amount', l.allocated, 'op', 'cancel');
      if p_commit then update ebda.lines set deleted_at = now()::text, deleted_by = u.name, delete_reason = 'إلغاء دفعة استيراد: ' || rsn where id = l.id; end if;
    end loop;
    for k, bef in select * from jsonb_each(coalesce(b.snapshot->'lines','{}'::jsonb)) loop
      select * into l from ebda.lines where id = k;
      if l.id is null or coalesce(l.deleted_at,'') <> '' then continue; end if;
      if l.last_batch <> b.id then skip := skip || jsonb_build_object('id', l.id, 'label', l.name, 'reason', 'عُدّل بدفعة لاحقة'); continue; end if;
      n_restore := n_restore + 1;
      rows_ := rows_ || jsonb_build_object('id', l.id, 'label', l.name, 'amount', l.allocated, 'before', bef->'allocated', 'op', 'restore');
      if p_commit then perform ebda.restore_row('lines', bef); end if;
    end loop;
    -- استبدال كامل: تعود البنود المستبدلة (إن لم يوجد مثلها)
    for bef in select * from jsonb_array_elements(coalesce(b.snapshot->'replaced','[]'::jsonb)) loop
      if exists(select 1 from ebda.lines where id = bef->>'id') then continue; end if;
      n_restore := n_restore + 1;
      rows_ := rows_ || jsonb_build_object('id', bef->>'id', 'label', bef->>'name', 'amount', bef->'allocated', 'op', 'reinsert');
      if p_commit then insert into ebda.lines select * from jsonb_populate_record(null::ebda.lines, bef); end if;
    end loop;
  else
    return ebda.err('نوع دفعة غير مدعوم');
  end if;
  if p_commit then
    update ebda.import_batches set reverted_at = now()::text, reverted_by = u.name, revert_reason = rsn,
      revert_result = jsonb_build_object('cancelled', n_cancel, 'restored', n_restore, 'skipped', jsonb_array_length(skip)) where id = b.id;
  end if;
  return jsonb_build_object('ok', true, 'mode', case when p_commit then 'commit' else 'preview' end, 'kind', b.kind, 'file_name', b.file_name,
    'school_id', b.school_id, 'month', b.month, 'cancel_n', n_cancel, 'restore_n', n_restore, 'amount', amt,
    'skip_n', jsonb_array_length(skip), 'skipped', skip, 'rows', rows_);
end $bk$;

-- ============================================================================
--  (1) التعديل الجماعى — حقل واحد محدد فقط (قائمة مسموحة) مع السبب والقيم السابقة
-- ============================================================================
create or replace function ebda.bulk_edit(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $be$
declare
  kind text := coalesce(req->>'kind',''); fld text := coalesce(req->>'field',''); val text := coalesce(req->>'value','');
  ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb)));
  commit_ boolean := coalesce(req->>'mode','preview') = 'commit'; rsn text := btrim(coalesce(req->>'reason',''));
  allowed text[]; single_only text[]; numeric_f text[]; id_ text; cur text; lbl text; sid text; ok_rows jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb;
  ps ebda.payslips; l ebda.lines; ex ebda.expenses;
begin
  if kind = 'payslips' then
    allowed := array['note','job','effects_note','effects_summary','ot_hours','ot_days','ded_hours','ded_days','allowances','contract_net'];
    single_only := array['allowances','contract_net']; numeric_f := array['ot_hours','ot_days','ded_hours','ded_days','allowances','contract_net'];
  elsif kind = 'lines' then
    allowed := array['note','section','allocated','active']; single_only := array['allocated']; numeric_f := array['allocated'];
  elsif kind = 'expenses' then
    allowed := array['note','supplier','doc_no','description']; single_only := array['description']; numeric_f := array[]::text[];
  else return ebda.err('نوع غير معروف'); end if;
  if not fld = any(allowed) then return ebda.err('هذا الحقل غير مسموح بتعديله جماعياً'); end if;
  if cardinality(ids) = 0 then return ebda.err('لم يتم تحديد أى سجل'); end if;
  if cardinality(ids) > 2000 then return ebda.err('2000 سجل كحد أقصى'); end if;
  if fld = any(single_only) and cardinality(ids) > 1 then
    return ebda.err('حقل المبلغ يُعدَّل لسجل واحد فقط — لا يُوحَّد مبلغ عدة سجلات بقيمة واحدة'); end if;
  if fld = any(numeric_f) and (not ebda.num_ok(val) or btrim(val) = '' or val::numeric < 0) then return ebda.err('قيمة رقمية غير صحيحة'); end if;
  if fld = 'active' and val not in ('نعم','لا') then return ebda.err('القيمة: نعم أو لا'); end if;
  if commit_ and length(rsn) < 3 then return ebda.err('اكتب سبب التعديل'); end if;
  foreach id_ in array ids loop
    if kind = 'payslips' then
      select * into ps from ebda.payslips where id = id_;
      if ps.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجودة'); continue; end if;
      lbl := ps.emp_name || ' · ' || ps.month; sid := ps.school_id;
      if coalesce(ps.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغاة'); continue; end if;
      if ebda.month_locked(ps.school_id, ps.month) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'رواتب الشهر معتمدة'); continue; end if;
      if fld in ('ot_hours','ot_days','ded_hours','ded_days','contract_net') and ps.contract_net is null and fld <> 'contract_net' then
        skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'لا توجد بيانات مؤثرات لهذه القسيمة (استورد ملف المؤثرات)'); continue; end if;
      cur := to_jsonb(ps)->>fld;
    elsif kind = 'lines' then
      select * into l from ebda.lines where id = id_;
      if l.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      lbl := l.name; sid := l.school_id;
      if coalesce(l.deleted_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى'); continue; end if;
      cur := to_jsonb(l)->>fld;
    else
      select * into ex from ebda.expenses where id = id_;
      if ex.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود'); continue; end if;
      lbl := coalesce(ex.txn_no,'') || ' · ' || coalesce(ex.description,''); sid := ex.school_id;
      if coalesce(ex.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'ملغى'); continue; end if;
      cur := to_jsonb(ex)->>fld;
    end if;
    if not ebda.can_school(u, sid) then skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'خارج نطاقك'); continue; end if;
    if (fld = any(numeric_f) and cur is not null and nullif(cur,'')::numeric = val::numeric) or (not fld = any(numeric_f) and coalesce(cur,'') = val) then
      skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'نفس القيمة — لا تغيير'); continue; end if;
    ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'before', cur, 'after', val);
    if commit_ then
      if kind = 'payslips' then
        execute format('update ebda.payslips set %I = $1::%s, updated_at = now()::text where id = $2', fld,
                       case when fld = any(numeric_f) then 'numeric' else 'text' end) using val, id_;
        if fld = 'allowances' then update ebda.payslips set gross = coalesce(base,0) + coalesce(allowances,0) where id = id_; end if;
        perform ebda.slip_recalc(id_);
      elsif kind = 'lines' then
        execute format('update ebda.lines set %I = $1::%s where id = $2', fld, case when fld = any(numeric_f) then 'numeric' else 'text' end) using val, id_;
      else
        execute format('update ebda.expenses set %I = $1, updated_by = $3, updated_at = now()::text where id = $2', fld) using val, id_, u.name;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'kind', kind, 'field', fld, 'value', val,
    'ok_n', jsonb_array_length(ok_rows), 'skip_n', jsonb_array_length(skip), 'rows', ok_rows, 'skipped', skip);
end $be$;

-- ============================================================================
--  (4) حالة البند المالى: ضمن الموازنة · معرض للتجاوز (حد قابل للضبط) · متجاوز · لا توجد موازنة معتمدة
-- ============================================================================
drop function if exists ebda.line_state(numeric, numeric, numeric);
create or replace function ebda.line_state(p_alloc numeric, p_used numeric, p_near numeric) returns text language sql stable as $$
  select case when coalesce(p_alloc,0) <= 0 then 'no_budget'
              when coalesce(p_used,0) * 100 > p_alloc * ebda.cfg_int('status_over_pct', 100) then 'over'
              when coalesce(p_used,0) * 100 >= p_alloc * coalesce(p_near, ebda.cfg_int('near_exhaust_pct', 80)) then 'at_risk'
              else 'within' end $$;
-- الجملة التوضيحية لمسئول العهدة (بدون نسب أو أرقام)
create or replace function ebda.line_state_text(st text) returns text language sql immutable as $$
  select case st when 'over' then 'تنبيه: البند تجاوز الموازنة' when 'at_risk' then 'تنبيه: البند على وشك تجاوز الموازنة'
                 when 'no_budget' then 'لا توجد موازنة معتمدة لهذا البند' else 'البند ضمن الموازنة' end $$;
create or replace function ebda.line_state_label(st text) returns text language sql immutable as $$
  select case st when 'over' then 'متجاوز الموازنة' when 'at_risk' then 'على وشك تجاوز الموازنة'
                 when 'no_budget' then 'لا توجد موازنة معتمدة' else 'ضمن الموازنة' end $$;

-- المصروفات الملغاة لا تدخل خط الاعتماد (كانت تُحتسب فى تنبيه العجز)
create or replace function ebda.line_pipeline(lid text, excl text default '') returns numeric language sql stable as $$
  select coalesce(sum(e.amount),0) from ebda.expenses e
   where e.line_id=lid and e.id<>coalesce(excl,'') and e.approval<>'rejected' and coalesce(e.fin_approval,'')<>'rejected' and coalesce(e.cancelled_at,'')='' $$;

-- موقف البند قبل/بعد المصروف الجارى تسجيله — من البيانات الفعلية لحظياً (للأدمن والمالى والمباشر ومسئول العهدة فى نطاقه)
create or replace function ebda.line_status2(u ebda.users, lid text, amt numeric, excl text) returns jsonb
language plpgsql stable security definer set search_path = ebda as $ls$
declare l ebda.lines; actual numeric; comm numeric; alloc numeric; before_ numeric; after_ numeric; st text; near numeric := ebda.cfg_int('near_exhaust_pct', 80);
  a numeric := greatest(coalesce(amt,0), 0); msg text := ''; pct numeric;
begin
  select * into l from ebda.lines where id = lid;
  if l.id is null or coalesce(l.deleted_at,'') <> '' then return jsonb_build_object('ok', true, 'known', false); end if;
  if not ebda.can_school(u, l.school_id) then return ebda.err('هذا البند ليس ضمن نطاقك'); end if;
  if ebda.rk(u) = 'custody_officer' and not (
       exists(select 1 from ebda.custodies c where c.school_id = l.school_id and ((coalesce(c.user_id,'') <> '' and c.user_id = u.id) or c."user" = u.username))) then
    return ebda.err('هذا البند ليس ضمن عهدك'); end if;
  alloc := coalesce(l.allocated, 0);
  actual := coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and e.id <> coalesce(excl,'') and ebda.counts_in_budget(e)), 0);
  comm := coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and e.id <> coalesce(excl,'') and coalesce(e.cancelled_at,'') = ''
                     and ebda.expense_stage(e) in ('pending_manager','pending_finance','fin_returned','returned')), 0);
  before_ := alloc - actual;
  after_ := before_ - a;
  st := ebda.line_state(alloc, actual + a, near);
  pct := case when alloc > 0 then round((actual + a) * 100 / alloc, 1) end;
  -- مسئول العهدة: جملة توضيحية فقط — بدون نسبة استهلاك أو أى رقم من الموازنة
  if ebda.rk(u) = 'custody_officer' then
    return jsonb_build_object('ok', true, 'known', true, 'line_id', l.id, 'name', l.name, 'state', st, 'text_only', true,
      'over', st = 'over' or (st = 'no_budget' and a > 0), 'message', ebda.line_state_text(st),
      'note', 'ظهور الحالة لا يعنى اعتماد المصروف — تظل الموافقات والمراجعة والتسوية كما هى');
  end if;
  msg := case st
    when 'over' then 'متجاوز الموازنة: بعد هذا المصروف يصل الاستهلاك إلى ' || pct || '% من الموازنة الكلية — تجاوز ' || to_char(-after_, 'FM999,999,999,990.00') || ' ج.م'
    when 'at_risk' then 'على وشك تجاوز الموازنة: بعد هذا المصروف يصل الاستهلاك إلى ' || pct || '% من الموازنة الكلية (الحد ' || near || '%) — المتبقى ' || to_char(after_, 'FM999,999,999,990.00') || ' ج.م'
    when 'no_budget' then 'لا توجد موازنة معتمدة لهذا البند — سيُراجع المصروف من المدير المالى'
    else '' end;
  return jsonb_build_object('label', ebda.line_state_label(st), 'over_pct', ebda.cfg_int('status_over_pct', 100), 'ok', true, 'known', true, 'line_id', l.id, 'name', l.name, 'state', st, 'near_pct', near,
    'allocated', alloc, 'actual', actual, 'committed', comm, 'counted', actual, 'pipeline', actual + comm,
    'remaining', before_, 'amount', a, 'after', after_, 'pct', pct, 'pct_before', case when alloc > 0 then round(actual * 100 / alloc, 1) end,
    'over', st = 'over' or (st = 'no_budget' and a > 0), 'message', msg,
    'note', 'ظهور الحالة لا يعنى اعتماد المصروف — تظل الموافقات والمراجعة والتسوية كما هى');
end $ls$;

-- ============================================================================
--  (3) «داش بورد» — كل التجميعات على الخادم، والملغى خارج الإجماليات
-- ============================================================================
create or replace function ebda.dashboard(u ebda.users, f jsonb) returns jsonb
language plpgsql stable security definer set search_path = ebda as $db$
declare
  urole text := ebda.rk(u); star boolean := coalesce(u.schools,'')='*' or ebda.rk(u)='admin'; sch text[] := ebda.scope_arr(u);
  sb boolean := ebda.sees_budgets(u); sp boolean := ebda.sees_budgets(u) or ebda.can(u,'payroll.view');
  f_sch text[] := array(select jsonb_array_elements_text(coalesce(f->'school_ids','[]'::jsonb)));
  cat text := coalesce(f->>'category',''); cid text := coalesce(f->>'catalog_id',''); lid text := coalesce(f->>'line_id','');
  hold text := coalesce(f->>'holder',''); cst text := coalesce(f->>'cust_status',''); est text := coalesce(f->>'exp_stage','');
  mon text := coalesce(f->>'month',''); d_from text := coalesce(f->>'date_from',''); d_to text := coalesce(f->>'date_to','');
  near numeric := ebda.cfg_int('near_exhaust_pct', 80); od int := ebda.cfg_int('custody_overdue_days', 30); apd int := ebda.cfg_int('approval_overdue_days', 7);
  gap numeric := ebda.cfg_int('school_gap_pct', 30); unus numeric := ebda.cfg_int('unusual_ded_pct', 50);
  s_ids text[]; l_ids text[]; c_ids text[]; e_ids text[]; line_f boolean; fy ebda.fiscal_years; res jsonb := '{}'::jsonb; alerts jsonb := '[]'::jsonb;
  bud jsonb := '{}'::jsonb; cus jsonb := '{}'::jsonb; pay jsonb := '{}'::jsonb; lists jsonb := '{}'::jsonb; pm text[]; today text := current_date::text;
  lines_j jsonb := '[]'::jsonb; lan jsonb := null; r_ids text[];
begin
  if urole not in ('admin','finance_manager','direct_manager','custody_officer') and not sp then return ebda.err('لا صلاحية لعرض «داش بورد»'); end if;
  if urole = 'custody_officer' then sp := false; end if;   -- مسئول العهدة: لا بيانات رواتب
  if coalesce(f->>'fy_id','') <> '' then
    select * into fy from ebda.fiscal_years where id = f->>'fy_id';
    if fy.id is not null then
      d_from := greatest(d_from, fy.start_date::text); d_to := case when d_to = '' then fy.end_date::text else least(d_to, fy.end_date::text) end;
    end if;
  end if;
  if mon <> '' then d_from := greatest(d_from, mon || '-01'); d_to := case when d_to = '' then mon || '-31' else least(d_to, mon || '-31') end; end if;
  line_f := cid <> '' or lid <> '';
  s_ids := array(select s.id from ebda.schools s where (star or s.id = any(sch)) and (cardinality(f_sch) = 0 or s.id = any(f_sch))
                 and (cat = '' or coalesce(s.category,'school') = cat));
  l_ids := array(select l.id from ebda.lines l where l.school_id = any(s_ids) and coalesce(l.deleted_at,'') = ''
                 and (lid = '' or l.id = lid) and (cid = '' or l.catalog_id = cid or ebda.catalog_main(l.catalog_id) = cid));
  c_ids := array(select c.id from ebda.vis_custodies(u) c where c.school_id = any(s_ids)
                 and (hold = '' or c.user_id = hold or c.holder_emp_id = hold or c.holder = hold)
                 and (case when cst = '' then coalesce(c.status,'open') <> 'cancelled' else coalesce(c.status,'open') = cst end));
  -- المصروفات القائمة (غير الملغاة) فى النطاق والفلاتر — الملغى لا يدخل أى إجمالى نشط
  e_ids := array(select e.id from ebda.expenses e where e.school_id = any(s_ids) and coalesce(e.cancelled_at,'') = ''
                 and (urole not in ('direct_manager','custody_officer') or e.custody_id = any(c_ids))
                 and (d_from = '' or e.date >= d_from) and (d_to = '' or e.date <= d_to)
                 and (not line_f or e.line_id = any(l_ids))
                 and (hold = '' and cst = '' or e.custody_id = any(c_ids))
                 and (est = '' or ebda.expense_stage(e) = est));
  r_ids := array(select r.id from ebda.requests r where r.school_id = any(s_ids)
                 and (urole <> 'custody_officer' or (coalesce(r.requester_id,'') <> '' and r.requester_id = u.id) or (coalesce(r.requester_id,'') = '' and r.requester = u.username))
                 and coalesce(r.status,'') not in ('cancelled','draft'));

  -- ------------------------------------------------ تحليل حالة الموازنة حسب البنود (للأدمن والمدير المالى والمدير المباشر ومسئول العهدة — كلٌّ فى نطاقه)
  -- الاستهلاك = المصروف الفعلى المعتمد + المصروفات المسجلة قيد الاعتماد (التزامات) — الملغى والمرفوض والمسودة والطلبات غير المعتمدة خارج الحساب
  if sb or urole in ('custody_officer','direct_manager') then
    if not sb or hold <> '' then   -- مسئول العهدة/المدير المباشر/فلتر المسئول: البنود المرتبطة بالعهد المرئية فقط
      l_ids := array(select x from unnest(l_ids) x where
                 exists(select 1 from ebda.custody_lines cl where cl.line_id = x and cl.custody_id = any(c_ids) and coalesce(cl.cancelled_at,'') = '')
              or exists(select 1 from ebda.expenses e where e.line_id = x and e.custody_id = any(c_ids) and coalesce(e.cancelled_at,'') = ''));
    end if;
    with la as (select l.* from ebda.lines l join unnest(l_ids) x(id) using (id)),
    ex as (select e.line_id, e.custody_id, e.amount, ebda.counts_in_budget(e) cnt, ebda.expense_stage(e) stg from ebda.expenses e
           where e.line_id = any(l_ids) and coalesce(e.cancelled_at,'') = '' and (d_from = '' or e.date >= d_from) and (d_to = '' or e.date <= d_to)),
    pl as (select la.id, la.school_id, la.name, la.section, coalesce(la.allocated,0) alloc,
             coalesce(sum(ex.amount) filter (where ex.cnt),0) actual,
             coalesce(sum(ex.amount) filter (where ex.stg in ('pending_manager','pending_finance','fin_returned','returned')),0) committed,
             coalesce(sum(ex.amount) filter (where ex.cnt and ex.custody_id = any(c_ids)),0) mine
           from la left join ex on ex.line_id = la.id group by la.id, la.school_id, la.name, la.section, la.allocated)
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'school_id', school_id, 'school', (select name from ebda.schools where id = pl.school_id),
        'name', name, 'section', section, 'alloc', alloc, 'actual', actual, 'pending', committed, 'committed', committed, 'used', actual,
        'remaining', alloc - actual, 'mine', mine,
        'pct', case when alloc > 0 then round(actual * 100 / alloc, 1) end,
        'state', ebda.line_state(alloc, actual, near), 'label', ebda.line_state_label(ebda.line_state(alloc, actual, near)),
        'over_amount', greatest(actual - alloc, 0),
        'over_pct', case when alloc > 0 and actual > alloc then round((actual - alloc) * 100 / alloc, 1) end,
        'holders', coalesce((select string_agg(distinct ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), '، ') from ebda.custodies c
                    where c.id = any(c_ids) and (exists(select 1 from ebda.custody_lines cl where cl.custody_id = c.id and cl.line_id = pl.id and coalesce(cl.cancelled_at,'') = '')
                                                 or exists(select 1 from ebda.expenses e where e.custody_id = c.id and e.line_id = pl.id and coalesce(e.cancelled_at,'') = ''))), '')
      ) order by actual desc), '[]'::jsonb) into lines_j from pl;
    lan := jsonb_build_object('near_pct', near, 'over_pct', ebda.cfg_int('status_over_pct', 100), 'basis', 'المصروف الفعلى المعتمد ÷ الموازنة الكلية للبند', 'lines', lines_j,
      'cats', coalesce((select jsonb_object_agg(st, jsonb_build_object('n', n, 'alloc', a, 'used', us, 'over', ov, 'remaining', rm)) from (
          select x->>'state' st, count(*) n, sum((x->>'alloc')::numeric) a, sum((x->>'used')::numeric) us, sum((x->>'over_amount')::numeric) ov,
                 sum(greatest((x->>'remaining')::numeric, 0)) rm from jsonb_array_elements(lines_j) x group by 1) q), '{}'::jsonb));
    if urole = 'custody_officer' then
      lan := jsonb_build_object('text_only', true, 'lines', coalesce((select jsonb_agg(jsonb_build_object('id', x->'id', 'school', x->'school', 'name', x->'name', 'section', x->'section',
               'state', x->'state', 'text', ebda.line_state_text(x->>'state'))) from jsonb_array_elements(lines_j) x), '[]'::jsonb),
        'cats', coalesce((select jsonb_object_agg(st, jsonb_build_object('n', n)) from (select x->>'state' st, count(*) n from jsonb_array_elements(lines_j) x group by 1) q), '{}'::jsonb));
    end if;
    if urole = 'custody_officer' then
      alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind', case when x->>'state' = 'over' then 'over' else 'near' end,
                'sev', case when x->>'state' = 'over' then 'high' else 'med' end, 'title', ebda.line_state_text(x->>'state'), 'detail', '',
                'school', x->>'school', 'subject', x->>'name', 'amount', null, 'action', 'مراجعة المدير المالى قبل صرف جديد على البند',
                'link', jsonb_build_object('tab','custodies')))
              from jsonb_array_elements(lines_j) x where x->>'state' in ('over','at_risk')), '[]'::jsonb);
    else
    alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','over','sev','high','title','متجاوز الموازنة',
                'detail', 'الاستهلاك ' || (x->>'pct') || '% من الموازنة الكلية (' || round((x->>'used')::numeric) || ' من ' || round((x->>'alloc')::numeric) || ')',
                'school', x->>'school', 'subject', (x->>'name') || case when x->>'holders' <> '' then ' · ' || (x->>'holders') else '' end,
                'amount', (x->>'over_amount')::numeric,
                'action', 'مراجعة البند: نقل مخصص أو إيقاف الصرف عليه', 'link', jsonb_build_object('tab','monthly','line_id', x->>'id','school_id', x->>'school_id')))
              from jsonb_array_elements(lines_j) x where x->>'state' = 'over'), '[]'::jsonb);
    alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','near','sev','med','title','على وشك تجاوز الموازنة',
                'detail', 'الاستهلاك ' || (x->>'pct') || '% من الموازنة الكلية (الحد ' || near || '%) — المتبقى ' || round((x->>'remaining')::numeric),
                'school', x->>'school', 'subject', (x->>'name') || case when x->>'holders' <> '' then ' · ' || (x->>'holders') else '' end,
                'amount', (x->>'remaining')::numeric,
                'action', 'متابعة الصرف المتبقى والتخطيط للشهور القادمة', 'link', jsonb_build_object('tab','monthly','line_id', x->>'id','school_id', x->>'school_id')))
              from jsonb_array_elements(lines_j) x where x->>'state' = 'at_risk'), '[]'::jsonb);
    end if;
  end if;

  -- ------------------------------------------------ الموازنة: المخصص / الفعلى (معتمد) / قيد الاعتماد / الملتزم (رصيد عهد مفتوحة) / المطلوب (طلبات غير معتمدة)
  if sb then
    bud := jsonb_build_object(
      'allocated', coalesce((select sum((x->>'alloc')::numeric) from jsonb_array_elements(lines_j) x),0),
      'actual', coalesce((select sum((x->>'actual')::numeric) from jsonb_array_elements(lines_j) x),0),
      'pending', coalesce((select sum((x->>'committed')::numeric) from jsonb_array_elements(lines_j) x),0),
      'remaining', coalesce((select sum((x->>'alloc')::numeric) - sum((x->>'actual')::numeric) from jsonb_array_elements(lines_j) x),0),
      'overrun', coalesce((select sum((x->>'over_amount')::numeric) from jsonb_array_elements(lines_j) x),0),
      'lines_n', jsonb_array_length(lines_j),
      'over_n', (select count(*) from jsonb_array_elements(lines_j) x where x->>'state' = 'over'),
      'near_n', (select count(*) from jsonb_array_elements(lines_j) x where x->>'state' = 'at_risk'),
      'by_line', lines_j,
      'by_school', coalesce((select jsonb_agg(jsonb_build_object('school_id', s.id, 'school', s.name, 'alloc', coalesce(q.alloc,0), 'actual', coalesce(q.actual,0),
                    'pending', coalesce(q.pending,0), 'pct', case when coalesce(q.alloc,0) > 0 then round(q.actual * 100 / q.alloc, 1) end) order by s.name)
                    from ebda.schools s join (select x->>'school_id' school_id, sum((x->>'alloc')::numeric) alloc, sum((x->>'actual')::numeric) actual,
                                                     sum((x->>'committed')::numeric) pending from jsonb_array_elements(lines_j) x group by 1) q on q.school_id = s.id
                    where q.alloc > 0 or q.actual > 0), '[]'::jsonb),
      'by_month', coalesce((select jsonb_agg(jsonb_build_object('m', m, 'actual', a,
                    'plan', (select round(coalesce(sum(ebda.plan_month(l.monthly_plan, l.allocated, ebda.fy_month(m || '-01'))),0), 2) from ebda.lines l where l.id = any(l_ids))) order by m)
                    from (select substr(e.date,1,7) m, sum(e.amount) a from ebda.expenses e where e.line_id = any(l_ids) and ebda.counts_in_budget(e)
                          and (d_from = '' or e.date >= d_from) and (d_to = '' or e.date <= d_to) and e.date ~ '^\d{4}-\d{2}' group by 1) q), '[]'::jsonb));
    bud := bud || jsonb_build_object(
      'pct', case when (bud->>'allocated')::numeric > 0 then round((bud->>'actual')::numeric * 100 / (bud->>'allocated')::numeric, 1) else null end,
      'committed', coalesce((select sum(greatest(coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id),0)
                          - coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e)),0), 0))
                          from ebda.custodies c join unnest(c_ids) x(id) using (id) where coalesce(c.status,'open') in ('open','pending_settlement')), 0),
      'requested', coalesce((select sum(r.total) from ebda.requests r where r.school_id = any(s_ids)
                          and r.status in ('pending_supervisor','pending_accountant','needs_info')
                          and (d_from = '' or substr(coalesce(r.created_at,''),1,10) >= d_from) and (d_to = '' or substr(coalesce(r.created_at,''),1,10) <= d_to)), 0));
    -- فرق كبير فى الصرف بين المدارس (نسبة الاستخدام)
    alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','school_gap','sev','low','title','فرق كبير فى نسبة الصرف بين المدارس',
                'detail', a.school || ' ' || a.pct || '% مقابل ' || b2.school || ' ' || b2.pct || '%', 'school', a.school || ' / ' || b2.school, 'subject', '',
                'amount', abs(a.actual - b2.actual), 'action', 'مراجعة أسباب الفرق ومعدل الصرف', 'link', jsonb_build_object('tab','dashboard')))
              from (select x->>'school' school, (x->>'pct')::numeric pct, (x->>'actual')::numeric actual from jsonb_array_elements(bud->'by_school') x where x->>'pct' is not null) a
              join (select x->>'school' school, (x->>'pct')::numeric pct, (x->>'actual')::numeric actual from jsonb_array_elements(bud->'by_school') x where x->>'pct' is not null) b2
                on a.school < b2.school and abs(a.pct - b2.pct) >= gap), '[]'::jsonb);
  end if;

  -- ------------------------------------------------ العهد والمصروفات
  with cc as (select c.*, coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id),0) issued,
                coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e)),0) spent,
                coalesce((select min(t.date) from ebda.tranches t where t.custody_id = c.id), c.opened_at) since
              from ebda.custodies c join unnest(c_ids) x(id) using (id)),
  ex as (select e.*, ebda.expense_stage(e) stg, ebda.active_on_custody(e) act from ebda.expenses e join unnest(e_ids) x(id) using (id))
  select jsonb_build_object(
    'active_n', (select count(*) from cc where coalesce(status,'open') in ('open','pending_settlement')),
    'issued', coalesce((select sum(issued) from cc),0),
    'recorded', coalesce((select sum(amount) from ex where ex.act and custody_id is not null and custody_id <> ''),0),
    'recorded_n', (select count(*) from ex where ex.act),
    'settled', coalesce((select sum(amount) from ex where stg = 'settled'),0),
    'unsettled', coalesce((select sum(amount) from ex where stg in ('pending_manager','pending_finance','reviewed','fin_returned','returned','draft')),0),
    'pending_manager', jsonb_build_object('n', (select count(*) from ex where stg = 'pending_manager'), 'amount', coalesce((select sum(amount) from ex where stg = 'pending_manager'),0)),
    'pending_finance', jsonb_build_object('n', (select count(*) from ex where stg = 'pending_finance'), 'amount', coalesce((select sum(amount) from ex where stg = 'pending_finance'),0)),
    'returned', jsonb_build_object('n', (select count(*) from ex where stg in ('returned','fin_returned')), 'amount', coalesce((select sum(amount) from ex where stg in ('returned','fin_returned')),0)),
    'no_docs', jsonb_build_object('n', (select count(*) from ex where stg not in ('draft','rejected','fin_rejected') and coalesce(doc_url,'') = '' and coalesce(doc_no,'') = ''),
                                  'amount', coalesce((select sum(amount) from ex where stg not in ('draft','rejected','fin_rejected') and coalesce(doc_url,'') = '' and coalesce(doc_no,'') = ''),0)),
    'over_n', (select count(*) from cc where spent > issued and spent > 0),
    'overdue_n', (select count(*) from cc where coalesce(status,'open') in ('open','pending_settlement') and coalesce(since,'') <> '' and substr(since,1,10) < (current_date - od)::text),
    'top_lines', coalesce((select jsonb_agg(z order by (z->>'amount')::numeric desc) from (select jsonb_build_object('line_id', ex.line_id, 'name', coalesce(l.name,'—'),
                   'school', (select name from ebda.schools where id = l.school_id), 'amount', sum(ex.amount), 'n', count(*)) z
                   from ex left join ebda.lines l on l.id = ex.line_id where ex.act group by ex.line_id, l.name, l.school_id order by sum(ex.amount) desc limit 10) q), '[]'::jsonb),
    'top_holders', coalesce((select jsonb_agg(z order by (z->>'amount')::numeric desc) from (select jsonb_build_object('holder', ebda.person_name(cc.user_id, cc.holder_emp_id, cc.holder, cc.label),
                   'amount', sum(cc.spent), 'issued', sum(cc.issued), 'n', count(*)) z from cc group by ebda.person_name(cc.user_id, cc.holder_emp_id, cc.holder, cc.label)
                   order by sum(cc.spent) desc limit 10) q), '[]'::jsonb)
  ) into cus;
  -- قوائم التفاصيل (لكل رقم قابل للضغط)
  lists := jsonb_build_object(
    'expenses', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'txn_no', e.txn_no, 'date', e.date, 'description', e.description, 'amount', e.amount,
                  'stage', ebda.expense_stage(e), 'school', (select name from ebda.schools where id = e.school_id), 'line', (select name from ebda.lines where id = e.line_id),
                  'custody', (select ebda.custody_name(c.title, c.label, c.code) from ebda.custodies c where c.id = e.custody_id),
                  'holder', (select ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) from ebda.custodies c where c.id = e.custody_id),
                  'counted', ebda.counts_in_budget(e), 'no_doc', coalesce(e.doc_url,'') = '' and coalesce(e.doc_no,'') = '',
                  'waiting_days', (current_date - coalesce(ebda.safe_date(substr(coalesce(nullif(e.submitted_at,''), e.created_at),1,10)), current_date)))
                  order by e.date desc) from (select e.* from ebda.expenses e join unnest(e_ids) x(id) using (id) order by e.date desc limit 3000) e), '[]'::jsonb),
    'custodies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'name', ebda.custody_name(c.title, c.label, c.code),
                  'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), 'school', (select name from ebda.schools where id = c.school_id),
                  'status', coalesce(c.status,'open'), 'issued', c.issued, 'spent', c.spent, 'since', c.since,
                  'over', c.spent > c.issued and c.spent > 0,
                  'overdue', coalesce(c.status,'open') in ('open','pending_settlement') and coalesce(c.since,'') <> '' and substr(c.since,1,10) < (current_date - od)::text)
                  order by c.code) from (select c.*, coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id),0) issued,
                      coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e)),0) spent,
                      coalesce((select min(t.date) from ebda.tranches t where t.custody_id = c.id), c.opened_at) since
                    from ebda.custodies c join unnest(c_ids) x(id) using (id)) c), '[]'::jsonb));
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','custody_over','sev','high','title','عهدة تجاوزت مبلغها',
              'detail', 'المصروف ' || round((x->>'spent')::numeric) || ' من المستلم ' || round((x->>'issued')::numeric), 'school', x->>'school',
              'subject', (x->>'code') || ' · ' || (x->>'holder'), 'amount', (x->>'spent')::numeric - (x->>'issued')::numeric,
              'action', 'استكمال دفعة للعهدة أو مراجعة المصروفات الزائدة', 'link', jsonb_build_object('tab','tracker','custody_id', x->>'id')))
            from jsonb_array_elements(lists->'custodies') x where (x->>'over')::boolean), '[]'::jsonb);
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','custody_overdue','sev','med','title','عهدة متأخرة التسوية',
              'detail', 'مفتوحة منذ ' || substr(x->>'since',1,10) || ' (أكثر من ' || od || ' يوم)', 'school', x->>'school',
              'subject', (x->>'code') || ' · ' || (x->>'holder'), 'amount', (x->>'issued')::numeric - (x->>'spent')::numeric,
              'action', 'مطالبة مسئول العهدة بالتسوية', 'link', jsonb_build_object('tab','tracker','custody_id', x->>'id')))
            from jsonb_array_elements(lists->'custodies') x where (x->>'overdue')::boolean), '[]'::jsonb);
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','approval_overdue','sev','med',
              'title', case when x->>'stage' = 'pending_manager' then 'اعتماد متأخر لدى المدير المباشر' else 'مراجعة مالية متأخرة' end,
              'detail', 'بانتظار منذ ' || (x->>'waiting_days') || ' يوم', 'school', x->>'school', 'subject', (x->>'txn_no') || ' · ' || coalesce(x->>'holder',''),
              'amount', (x->>'amount')::numeric, 'action', 'اعتماد أو إعادة المصروف', 'link', jsonb_build_object('tab','approvals','q', x->>'txn_no')))
            from jsonb_array_elements(lists->'expenses') x where x->>'stage' in ('pending_manager','pending_finance') and (x->>'waiting_days')::int > apd), '[]'::jsonb);
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','returned_open','sev','low','title','مصروف معاد لم يُستكمل',
              'detail', 'معاد منذ ' || (x->>'waiting_days') || ' يوم', 'school', x->>'school', 'subject', (x->>'txn_no') || ' · ' || coalesce(x->>'holder',''),
              'amount', (x->>'amount')::numeric, 'action', 'متابعة مسئول العهدة لاستكمال المطلوب', 'link', jsonb_build_object('tab','approvals','q', x->>'txn_no')))
            from jsonb_array_elements(lists->'expenses') x where x->>'stage' in ('returned','fin_returned') and (x->>'waiting_days')::int > apd), '[]'::jsonb);
  cus := cus || jsonb_build_object('requests', jsonb_build_object(
      'needs_info', (select count(*) from ebda.requests r where r.id = any(r_ids) and r.status in ('needs_info','returned')),
      'pending_supervisor', (select count(*) from ebda.requests r where r.id = any(r_ids) and r.status = 'pending_supervisor'),
      'pending_accountant', (select count(*) from ebda.requests r where r.id = any(r_ids) and r.status = 'pending_accountant')),
    'remaining', coalesce((select sum(greatest((x->>'issued')::numeric - (x->>'spent')::numeric, 0)) from jsonb_array_elements(lists->'custodies') x
                           where x->>'status' in ('open','pending_settlement')), 0));
  lists := lists || jsonb_build_object('requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'req_no', r.req_no, 'status', r.status,
      'status_label', ebda.req_status_label(r.status), 'total', r.total, 'created_at', substr(coalesce(r.created_at,''),1,10), 'requester', r.requester_name,
      'school', (select name from ebda.schools where id = r.school_id)) order by r.created_at desc)
      from ebda.requests r where r.id = any(r_ids) and r.status in ('needs_info','returned','pending_supervisor','pending_accountant')), '[]'::jsonb));
  if (cus->'no_docs'->>'n')::int > 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object('kind','no_docs','sev','low','title','مصروفات بدون مستندات',
      'detail', (cus->'no_docs'->>'n') || ' مصروف يحتاج مستنداً قبل التسوية', 'school', '', 'subject', '', 'amount', (cus->'no_docs'->>'amount')::numeric,
      'action', 'إرفاق المستندات أو رقم المستند', 'link', jsonb_build_object('tab','approvals','status','needdoc')));
  end if;
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','request_returned','sev','low','title','طلب عهدة معاد لم يُستكمل',
              'detail', ebda.req_status_label(r.status), 'school', (select name from ebda.schools where id = r.school_id),
              'subject', coalesce(r.req_no,'') || ' · ' || coalesce(r.requester_name,''), 'amount', r.total,
              'action', 'متابعة استكمال البيانات المطلوبة', 'link', jsonb_build_object('tab','requests','req', r.id)))
            from ebda.requests r where r.id = any(r_ids) and r.status in ('needs_info','returned')
              and substr(coalesce(r.created_at,''),1,10) < (current_date - apd)::text), '[]'::jsonb);
  alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','request_overdue','sev','med','title','طلب عهدة متأخر الاعتماد',
              'detail', ebda.req_status_label(r.status), 'school', (select name from ebda.schools where id = r.school_id),
              'subject', coalesce(r.req_no,'') || ' · ' || coalesce(r.requester_name,''), 'amount', r.total,
              'action', 'البت فى الطلب', 'link', jsonb_build_object('tab','requests','req', r.id)))
            from ebda.requests r where r.id = any(r_ids) and r.status in ('pending_supervisor','pending_accountant')
              and substr(coalesce(r.created_at,''),1,10) < (current_date - apd)::text), '[]'::jsonb);

  -- ------------------------------------------------ الرواتب (لمن له صلاحية الرواتب فقط)
  if sp then
    pm := array(select distinct p.month from ebda.payslips p where p.school_id = any(s_ids) and coalesce(p.cancelled_at,'') = ''
                and (d_from = '' or p.month >= substr(d_from,1,7)) and (d_to = '' or p.month <= substr(d_to,1,7)) order by 1);
    with ps as (select p.*, coalesce(p.contract_net, p.base) before_,
                  coalesce(p.allowances,0) + coalesce(p.ot_amount,0) + ebda.adj_kind_sum(p.adjustments,'earning') adds,
                  case when p.contract_net is null then coalesce(p.ded_total,0) else 0 end + coalesce(p.ded_amount,0) + ebda.adj_kind_sum(p.adjustments,'deduction') + ebda.adj_kind_sum(p.adjustments,'withholding') deds
                from ebda.payslips p where p.school_id = any(s_ids) and coalesce(p.cancelled_at,'') = '' and p.month = any(pm))
    select jsonb_build_object(
      'months', to_jsonb(pm),
      'contract', coalesce((select sum(before_) from ps),0), 'additions', coalesce((select sum(adds) from ps),0),
      'deductions', coalesce((select sum(deds) from ps),0), 'net', coalesce((select sum(net) from ps),0), 'n', (select count(*) from ps),
      'by_school_month', coalesce((select jsonb_agg(jsonb_build_object('school_id', school_id, 'school', (select name from ebda.schools where id = q.school_id), 'month', month,
                    'contract', c, 'additions', a, 'deductions', d, 'net', n, 'count', k) order by month, school_id)
                    from (select school_id, month, sum(before_) c, sum(adds) a, sum(deds) d, sum(net) n, count(*) k from ps group by 1,2) q), '[]'::jsonb),
      'ded_types', jsonb_build_object(
                                      'effects', coalesce((select sum(ded_amount) from ps),0),
                                      'attendance', coalesce((select sum(ded_total) from ps where contract_net is null),0),
                                      'components', coalesce((select jsonb_object_agg(name, amt) from (select c.name, sum(coalesce(nullif(a.value,'')::numeric,0)) amt
                                          from ps, jsonb_each_text(coalesce(ps.adjustments,'{}'::jsonb)) a join ebda.payroll_components c on c.code = a.key
                                          where c.kind = 'deduction' group by c.name) q), '{}'::jsonb)),
      'pending_rule_n', (select count(*) from ps where effects_state = 'pending_rule'),
      'unusual', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', emp_name, 'school', (select name from ebda.schools where id = ps.school_id), 'month', month,
                    'before', before_, 'deductions', deds, 'net', net,
                    'reason', case when net < 0 then 'صافى سالب' when coalesce(ded_days,0) > coalesce(nullif(eff_work_days,0), 31) then 'أيام الخصم أكبر من أيام العمل'
                                   else 'الخصم أكبر من ' || unus || '% من الراتب' end))
                    from ps where net < 0 or (before_ > 0 and deds * 100 > before_ * unus) or coalesce(ded_days,0) > coalesce(nullif(eff_work_days,0), 31)), '[]'::jsonb),
      'dup', coalesce((select jsonb_agg(jsonb_build_object('employee_id', employee_id, 'name', nm, 'month', month, 'n', k))
                    from (select employee_id, month, max(emp_name) nm, count(*) k from ps group by employee_id, month having count(*) > 1) q), '[]'::jsonb),
      'totals_check', coalesce((select jsonb_agg(jsonb_build_object('school', (select name from ebda.schools where id = t.school_id), 'school_id', t.school_id, 'month', t.month,
                    'category', t.category, 'sheet', t.amount,
                    'computed', (select coalesce(sum(p.net),0) from ps p where p.school_id = t.school_id and p.month = t.month
                                  and case when t.category like '%حكوم%' then coalesce(p.insurance_status,'') like '%حكوم%' or p.staff_group = 'gov'
                                           else not (coalesce(p.insurance_status,'') like '%حكوم%' or p.staff_group = 'gov') end)))
                    from ebda.payroll_totals t where t.school_id = any(s_ids) and t.month = any(pm) and (t.category like '%حكوم%' or t.category like '%خاص%')), '[]'::jsonb),
      'unknown_n', coalesce((select sum(jsonb_array_length(b.exceptions)) from ebda.import_batches b where b.kind = 'effects' and coalesce(b.reverted_at,'') = ''
                    and b.school_id = any(s_ids) and b.month = any(pm)
                    and b.created_at = (select max(b2.created_at) from ebda.import_batches b2 where b2.kind = 'effects' and b2.school_id = b.school_id and b2.month = b.month and coalesce(b2.reverted_at,'') = '')),0),
      'slips', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', emp_name, 'school', (select name from ebda.schools where id = ps.school_id), 'month', month,
                    'before', before_, 'additions', adds, 'deductions', deds, 'net', net, 'state', effects_state) order by month, emp_name) from ps), '[]'::jsonb)
    ) into pay;
    alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','pay_unusual','sev','high','title','خصم غير منطقى فى الرواتب',
                'detail', x->>'reason', 'school', x->>'school', 'subject', (x->>'name') || ' · ' || (x->>'month'), 'amount', (x->>'deductions')::numeric,
                'action', 'مراجعة المؤثرات قبل الاعتماد', 'link', jsonb_build_object('tab','salaries','month', x->>'month')))
              from jsonb_array_elements(pay->'unusual') x), '[]'::jsonb);
    alerts := alerts || coalesce((select jsonb_agg(jsonb_build_object('kind','pay_mismatch','sev','high','title','عدم تطابق إجمالى الرواتب مع شيت الإجماليات',
                'detail', (x->>'category') || ': الشيت ' || round((x->>'sheet')::numeric, 2) || ' · المحسوب ' || round((x->>'computed')::numeric, 2),
                'school', x->>'school', 'subject', x->>'month', 'amount', (x->>'computed')::numeric - (x->>'sheet')::numeric,
                'action', 'مراجعة الفرق (تعيين خلال الشهر/أيام العمل/المؤثرات) قبل التحويل', 'link', jsonb_build_object('tab','salaries','month', x->>'month')))
              from jsonb_array_elements(pay->'totals_check') x where abs((x->>'computed')::numeric - (x->>'sheet')::numeric) > 1), '[]'::jsonb);
    if (pay->>'pending_rule_n')::int > 0 then
      alerts := alerts || jsonb_build_array(jsonb_build_object('kind','pay_rule','sev','high','title','مؤثرات بانتظار قاعدة الحساب',
                'detail', (pay->>'pending_rule_n') || ' قسيمة بها ساعات/أيام إضافى أو خصم ولم تُعتمد قاعدة قيمة الساعة/اليوم', 'school', '', 'subject', '',
                'amount', null, 'action', 'اعتماد قاعدة الحساب من «الرواتب ← قواعد المؤثرات»', 'link', jsonb_build_object('tab','salaries')));
    end if;
    if jsonb_array_length(pay->'dup') > 0 then
      alerts := alerts || jsonb_build_array(jsonb_build_object('kind','pay_dup','sev','high','title','قسائم مكررة لنفس الموظف فى نفس الشهر',
                'detail', jsonb_array_length(pay->'dup') || ' موظف', 'school', '', 'subject', '', 'amount', null,
                'action', 'إلغاء القسيمة الزائدة', 'link', jsonb_build_object('tab','salaries')));
    end if;
    if (pay->>'unknown_n')::int > 0 then
      alerts := alerts || jsonb_build_array(jsonb_build_object('kind','pay_unknown','sev','med','title','موظفون غير مسجلين فى آخر استيراد مؤثرات',
                'detail', (pay->>'unknown_n') || ' سطر لم يُستورد', 'school', '', 'subject', '', 'amount', null,
                'action', 'تسجيل الموظفين ثم إعادة استيراد الملف', 'link', jsonb_build_object('tab','salaries')));
    end if;
  end if;

  return jsonb_build_object('ok', true, 'generated_at', now()::text,
    'filters', jsonb_build_object('school_ids', to_jsonb(s_ids), 'date_from', d_from, 'date_to', d_to, 'month', mon, 'category', cat,
                                  'catalog_id', cid, 'line_id', lid, 'holder', hold, 'cust_status', cst, 'exp_stage', est),
    'sees', jsonb_build_object('budget', sb, 'payroll', sp),
    'budget', case when sb then bud else null end, 'line_analysis', lan, 'custody', cus, 'payroll', case when sp then pay else null end,
    'lists', lists, 'alerts', alerts,
    'thresholds', jsonb_build_object('near_pct', near, 'overdue_days', od, 'approval_days', apd, 'school_gap_pct', gap, 'unusual_ded_pct', unus));
end $db$;

-- لوحة البداية v10 = v9 بدون القسائم الملغاة (تبقى تاريخاً فى قاعدة البيانات) + قواعد المؤثرات + إجماليات الشيت
-- المزامنة مع جوجل شيت: الملغى نهائياً لا يُصدَّر ولا يدخل أى رقم
create or replace function ebda.sync_export() returns jsonb language plpgsql stable security definer set search_path = ebda as $sx$
declare res jsonb;
begin
  res := jsonb_build_object('ok', true, 'generated_at', now()::text, 'schema_version', 1);

  -- الموازنات: صف لكل (جهة × بند) مع المصروف لكل شهر من السنة المالية
  res := res || jsonb_build_object('budget', coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', l.id, 'entity_id', s.id, 'entity', s.name, 'entity_type', coalesce(s.category,'school'), 'fiscal_year', coalesce(s.period,''),
      'section', coalesce(l.section,''), 'line', l.name, 'annual', coalesce(l.allocated,0),
      'monthly', round(coalesce(l.allocated,0)/12.0, 2),
      'months', (select jsonb_agg(coalesce((select sum(e.amount) from ebda.expenses e
                    where coalesce(e.cancelled_at,'')='' and e.line_id=l.id and ebda.counts_in_budget(e) and ebda.fy_month(e.date)=m),0) order by m)
                 from generate_series(1,12) m),
      'spent', coalesce((select sum(e.amount) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.line_id=l.id and ebda.counts_in_budget(e)),0),
      'pending', coalesce((select sum(e.amount) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.line_id=l.id and e.approval<>'rejected'
                    and coalesce(e.fin_approval,'')<>'rejected' and not ebda.counts_in_budget(e)),0)
    ) order by s.name, l.section, l.name)
    from ebda.lines l join ebda.schools s on s.id=l.school_id where coalesce(l.deleted_at,'')=''), '[]'::jsonb));

  -- العهد
  res := res || jsonb_build_object('custodies', coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', c.id, 'code', c.code, 'entity', coalesce(s.name,''), 'entity_type', coalesce(s.category,''), 'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), 'custody_name', ebda.custody_name(c.title, c.label, c.code),
      'user', coalesce(c."user",''), 'label', coalesce(c.label,''), 'opened_at', coalesce(nullif(c.opened_at,''), (select min(t.date) from ebda.tranches t where t.custody_id=c.id), ''),
      'received', coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id=c.id),0),
      'spent', coalesce((select sum(e.amount) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.custody_id=c.id and e.approval<>'rejected' and coalesce(e.fin_approval,'')<>'rejected'),0),
      'settled_amount', coalesce((select sum(e.amount) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.custody_id=c.id and coalesce(e.settled,'') like '%نعم%'),0),
      'exp_count', (select count(*) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.custody_id=c.id),
      'pending_count', (select count(*) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.custody_id=c.id and e.approval='pending'),
      'unsettled_count', (select count(*) from ebda.expenses e where coalesce(e.cancelled_at,'')='' and e.custody_id=c.id and e.approval='approved' and coalesce(e.fin_approval,'')<>'rejected' and not (coalesce(e.settled,'') like '%نعم%')),
      'status', coalesce(c.status,'open'), 'settled_at', coalesce(c.settled_at,''), 'closed_at', coalesce(c.closed_at,'')
    ) order by c.code)
    from ebda.custodies c left join ebda.schools s on s.id=c.school_id where coalesce(c.status,'')<>'cancelled'), '[]'::jsonb));

  -- المصروفات
  res := res || jsonb_build_object('expenses', coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', e.id, 'txn_no', coalesce(e.txn_no,''), 'date', coalesce(e.date,''), 'entity', coalesce(s.name,''),
      'custody_code', coalesce(c.code, 'شراء مركزى'), 'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), 'custody_name', ebda.custody_name(c.title, c.label, c.code), 'line', coalesce(l.name,''), 'section', coalesce(l.section,''),
      'spend_item', coalesce(e.spend_item,''), 'description', coalesce(e.description,''), 'amount', coalesce(e.amount,0),
      'approval', coalesce(e.approval,''), 'approved_by', coalesce(e.approved_by,''), 'approved_at', coalesce(e.approved_at,''),
      'fin_approval', coalesce(e.fin_approval,''), 'fin_by', coalesce(e.fin_by,''), 'fin_at', coalesce(e.fin_at,''),
      'settled', case when coalesce(e.settled,'') like '%نعم%' then 'نعم' else 'لا' end, 'settled_at', coalesce(e.settled_at,''),
      'review_status', coalesce(e.review_status,''), 'review_note', coalesce(e.review_note,''),
      'doc_name', coalesce(e.doc_name,''), 'doc_type', coalesce(e.doc_type,''),
      'doc_link', case when coalesce(e.doc_is_link,'') like '%نعم%' then coalesce(e.doc_url,'') else '' end,
      'has_doc', case when coalesce(e.doc_url,'')<>'' then 'نعم' else 'لا' end,
      'in_budget', case when ebda.counts_in_budget(e) then 'نعم' else 'لا' end,
      'created_by', coalesce(e.created_by,''), 'created_at', coalesce(e.created_at,''), 'updated_by', coalesce(e.updated_by,''), 'updated_at', coalesce(e.updated_at,''),
      'note', coalesce(e.note,'')
    ) order by e.txn_no)
    from ebda.expenses e left join ebda.custodies c on c.id=e.custody_id left join ebda.schools s on s.id=e.school_id left join ebda.lines l on l.id=e.line_id where coalesce(e.cancelled_at,'')=''), '[]'::jsonb));

  -- طلبات العهد
  res := res || jsonb_build_object('requests', coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', r.id, 'req_no', coalesce(r.req_no,''), 'entity', coalesce(s.name,''), 'requester', coalesce(r.requester_name,''),
      'created_at', coalesce(r.created_at,''), 'total', coalesce(r.total,0), 'status', r.status, 'reason', coalesce(r.reason,''), 'note', coalesce(r.note,''),
      'decided_by', coalesce(r.decided_by,''), 'fin_by', coalesce(r.acc_by,''), 'custody_code', coalesce(c.code,''),
      'items', coalesce((select string_agg(coalesce(l.name, it.name)||': '||it.amount::text, ' | ') from ebda.request_items it left join ebda.lines l on l.id=it.line_id where it.request_id=r.id),'')
    ) order by r.req_no)
    from ebda.requests r left join ebda.schools s on s.id=r.school_id left join ebda.custodies c on c.id=r.custody_id), '[]'::jsonb));
  return res;
end $sx$;


-- لوحة البداية v10: الإلغاء النهائى — السجلات الملغاة لا تُرسل للشاشات التشغيلية إطلاقاً (تبقى فقط فى سجل التدقيق والسجل التاريخى للأدمن)
create or replace function ebda.bootstrap_v10(u ebda.users) returns jsonb
language plpgsql stable security definer set search_path = ebda as $b10$
declare res jsonb := ebda.bootstrap_v9(u); sp boolean := ebda.sees_budgets(u) or ebda.can(u,'payroll.view'); near numeric := ebda.cfg_int('near_exhaust_pct', 80);
  dead text[];
begin
  if res ? 'error' then return res; end if;
  dead := array(select c.id from ebda.custodies c where coalesce(c.status,'') = 'cancelled');
  res := jsonb_set(res, '{expenses}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(res->'expenses','[]'::jsonb)) x
           where coalesce(x->>'cancelled_at','') = '' and not coalesce(x->>'custody_id','') = any(dead)), '[]'::jsonb));
  res := jsonb_set(res, '{custodies}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(res->'custodies','[]'::jsonb)) x
           where coalesce(x->>'status','') <> 'cancelled'), '[]'::jsonb));
  if res ? 'custody_lines' then
    res := jsonb_set(res, '{custody_lines}', coalesce((select jsonb_agg(x) from jsonb_array_elements(res->'custody_lines') x
             where coalesce(x->>'cancelled_at','') = '' and not coalesce(x->>'custody_id','') = any(dead)), '[]'::jsonb));
  end if;
  if res ? 'tranches' then
    res := jsonb_set(res, '{tranches}', coalesce((select jsonb_agg(x) from jsonb_array_elements(res->'tranches') x
             where not coalesce(x->>'custody_id','') = any(dead)), '[]'::jsonb));
  end if;
  res := jsonb_set(res, '{requests}', coalesce((select jsonb_agg(case when x ? 'items' then jsonb_set(x, '{items}', coalesce((select jsonb_agg(i) from jsonb_array_elements(x->'items') i
             where coalesce(i->>'decision','') <> 'cancelled'), '[]'::jsonb)) else x end)
           from jsonb_array_elements(coalesce(res->'requests','[]'::jsonb)) x where coalesce(x->>'status','') <> 'cancelled'), '[]'::jsonb));
  -- حالة كل بند مرئى بالنسبة للموازنة (تُعرض بجوار البند فى كل شاشات المصروف والعهدة) — نفس قاعدة line_status2
  res := res || jsonb_build_object('line_state', coalesce((select jsonb_object_agg(q.id, jsonb_build_object('alloc', q.alloc, 'actual', q.actual, 'committed', q.comm,
             'state', ebda.line_state(q.alloc, q.actual, near), 'pct', case when q.alloc > 0 then round(q.actual * 100 / q.alloc, 1) end,
             'remaining', q.alloc - q.actual))
           from (select l.id, coalesce(l.allocated,0) alloc,
                   coalesce(sum(e.amount) filter (where ebda.counts_in_budget(e)),0) actual,
                   coalesce(sum(e.amount) filter (where coalesce(e.cancelled_at,'') = '' and ebda.expense_stage(e) in ('pending_manager','pending_finance','fin_returned','returned')),0) comm
                 from ebda.lines l left join ebda.expenses e on e.line_id = l.id
                 where l.id in (select x->>'id' from jsonb_array_elements(coalesce(res->'lines','[]'::jsonb)) x)
                 group by l.id, l.allocated) q), '{}'::jsonb));
  if ebda.rk(u) = 'custody_officer' then   -- جملة توضيحية فقط: لا نسب ولا أرقام لمسئول العهدة
    res := jsonb_set(res, '{line_state}', coalesce((select jsonb_object_agg(k, jsonb_build_object('state', v->>'state', 'text', ebda.line_state_text(v->>'state')))
             from jsonb_each(res->'line_state') e(k, v)), '{}'::jsonb));
  end if;
  if res ? 'payslips' then
    res := jsonb_set(res, '{payslips}', coalesce((select jsonb_agg(x) from jsonb_array_elements(res->'payslips') x where coalesce(x->>'cancelled_at','') = ''), '[]'::jsonb));
    res := jsonb_set(res, '{payroll_periods}', coalesce((select jsonb_agg(x) from jsonb_array_elements(coalesce(res->'payroll_periods','[]'::jsonb)) x
                                                         where coalesce(x->>'status','') <> 'cancelled'), '[]'::jsonb));
    res := jsonb_set(res, '{payroll_months}', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'school_id', school_id, 'net', net, 'n', n) order by month) from (
          select z.month, z.school_id, sum(z.net) net, count(*) n from ebda.payslips z
          where ebda.can_school(u, z.school_id) and coalesce(z.cancelled_at,'') = '' group by 1, 2) q), '[]'::jsonb));
  end if;
  if sp then
    res := res || jsonb_build_object('payroll_totals', coalesce((select jsonb_agg(to_jsonb(t)) from ebda.payroll_totals t where ebda.can_school(u, t.school_id)), '[]'::jsonb));
  end if;
  return res || jsonb_build_object('settings', coalesce(res->'settings','{}'::jsonb) || jsonb_build_object('effects_rules', ebda.eff_rules(),
      'near_exhaust_pct', ebda.cfg_int('near_exhaust_pct', 80), 'approval_overdue_days', ebda.cfg_int('approval_overdue_days', 7),
      'school_gap_pct', ebda.cfg_int('school_gap_pct', 30), 'unusual_ded_pct', ebda.cfg_int('unusual_ded_pct', 50),
      'status_within_from', ebda.cfg_int('status_within_from', 0), 'status_over_pct', ebda.cfg_int('status_over_pct', 100)));
end $b10$;

-- ============================================================================
--  (5) الإلغاء النهائى (للأدمن فقط): حذف من البيانات التشغيلية + أثر تدقيق مختصر منفصل (purge_log)
--      مصروف · عهدة كاملة (بدفعاتها وبنودها ومصروفاتها) · بند داخل عهدة (ومصروفاته فى تلك العهدة فقط)
--      لا يُنفَّذ على عهدة مسوّاة/مغلقة (يُعرض السبب) — والأرصدة والإجماليات محسوبة من الحركات فتتحدث تلقائياً
-- ============================================================================
create table if not exists ebda.purge_log(id text primary key, kind text, record_id text, label text default '', amount numeric default 0,
  reason text default '', actor text default '', actor_id text default '', at timestamptz default now(), linked jsonb default '{}'::jsonb, data jsonb);
create index if not exists ix_purge_log_at on ebda.purge_log(at desc);
revoke all on ebda.purge_log from anon, authenticated;

create or replace function ebda.purge_records(u ebda.users, p_kind text, p_ids text[], p_reason text, p_commit boolean) returns jsonb
language plpgsql security definer set search_path = ebda as $pg$
declare
  id_ text; ok_rows jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb; amt numeric := 0; rsn text := btrim(coalesce(p_reason,''));
  ex ebda.expenses; c ebda.custodies; cl ebda.custody_lines; lbl text; n_e int; v numeric; ids_e text[];
begin
  if ebda.rk(u) <> 'admin' then return ebda.err('الإلغاء النهائى للأدمن فقط'); end if;
  if p_kind not in ('expenses','custodies','custody_lines') then return ebda.err('نوع غير معروف'); end if;
  if coalesce(cardinality(p_ids),0) = 0 then return ebda.err('لم يتم تحديد أى سجل'); end if;
  if cardinality(p_ids) > 2000 then return ebda.err('2000 سجل كحد أقصى فى العملية الواحدة'); end if;
  if p_commit and length(rsn) < 3 then return ebda.err('اكتب سبب الإلغاء النهائى'); end if;
  foreach id_ in array (select array_agg(distinct x) from unnest(p_ids) x) loop
    if p_kind = 'expenses' then
      select * into ex from ebda.expenses where id = id_;
      if ex.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود (حُذف من قبل)'); continue; end if;
      lbl := coalesce(ex.txn_no,'') || ' · ' || coalesce(ex.description,'');
      select * into c from ebda.custodies where id = ex.custody_id;
      if c.id is not null and coalesce(c.status,'') in ('settled','closed') then
        skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'العهدة ' || coalesce(c.code,'') || ' مسوّاة/مغلقة — أعد فتحها أولاً حتى لا يختل رصيد التسوية'); continue; end if;
      amt := amt + coalesce(ex.amount,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', ex.amount, 'note',
        case when ebda.counts_in_budget(ex) then 'يخرج من المصروف الفعلى للبند' when ebda.active_on_custody(ex) then 'يخرج من رصيد العهدة' else '' end);
      if p_commit then
        insert into ebda.purge_log(id, kind, record_id, label, amount, reason, actor, actor_id, data)
        values(ebda.uid(), 'expense', ex.id, lbl, ex.amount, rsn, u.name, u.id, to_jsonb(ex) - 'doc_url');
        delete from ebda.expenses where id = ex.id;
      end if;
    elsif p_kind = 'custodies' then
      select * into c from ebda.custodies where id = id_;
      if c.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجودة (حُذفت من قبل)'); continue; end if;
      lbl := coalesce(c.code,'') || ' · ' || ebda.custody_name(c.title, c.label, c.code) || ' · ' || ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label);
      select count(*), coalesce(sum(amount),0) into n_e, v from ebda.expenses where custody_id = c.id;
      amt := amt + coalesce((select sum(amount) from ebda.tranches where custody_id = c.id),0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', coalesce((select sum(amount) from ebda.tranches where custody_id = c.id),0),
        'note', 'تُحذف معها ' || n_e || ' عملية مصروف (' || v || ') ودفعاتها وتوزيعها على البنود'
          || case when exists(select 1 from ebda.requests r where r.custody_id = c.id) then ' · طلبات العهد المرتبطة تصبح «ملغاة»' else '' end);
      if p_commit then
        insert into ebda.purge_log(id, kind, record_id, label, amount, reason, actor, actor_id, linked, data)
        values(ebda.uid(), 'custody', c.id, lbl, coalesce((select sum(amount) from ebda.tranches where custody_id = c.id),0), rsn, u.name, u.id,
          jsonb_build_object('expenses', n_e, 'expenses_amount', v, 'expense_ids', (select coalesce(jsonb_agg(id),'[]'::jsonb) from ebda.expenses where custody_id = c.id)),
          to_jsonb(c) || jsonb_build_object('tranches', (select coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) from ebda.tranches t where t.custody_id = c.id),
                                            'custody_lines', (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from ebda.custody_lines x where x.custody_id = c.id)));
        update ebda.requests set status = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name,
          cancel_reason = 'حُذفت العهدة ' || coalesce(c.code,'') || ' نهائياً: ' || rsn, custody_id = '' where custody_id = c.id;
        delete from ebda.expenses where custody_id = c.id;
        delete from ebda.tranches where custody_id = c.id;
        delete from ebda.custody_lines where custody_id = c.id;
        delete from ebda.custodies where id = c.id;
      end if;
    else
      select * into cl from ebda.custody_lines where id = id_;
      if cl.id is null then skip := skip || jsonb_build_object('id', id_, 'label', id_, 'reason', 'غير موجود (حُذف من قبل)'); continue; end if;
      select * into c from ebda.custodies where id = cl.custody_id;
      lbl := coalesce(c.code,'') || ' · ' || coalesce((select name from ebda.lines where id = cl.line_id),'');
      if coalesce(c.status,'') in ('settled','closed') then
        skip := skip || jsonb_build_object('id', id_, 'label', lbl, 'reason', 'العهدة مسوّاة/مغلقة — أعد فتحها أولاً'); continue; end if;
      select count(*), coalesce(sum(amount),0) into n_e, v from ebda.expenses where custody_id = cl.custody_id and line_id = cl.line_id;
      amt := amt + coalesce(cl.amount,0);
      ok_rows := ok_rows || jsonb_build_object('id', id_, 'label', lbl, 'amount', coalesce(cl.amount,0),
        'note', 'البند فقط — العهدة وبقية بنودها كما هى' || case when n_e > 0 then ' · تُحذف ' || n_e || ' عملية مصروف على هذا البند فى هذه العهدة (' || v || ')' else '' end);
      if p_commit then
        insert into ebda.purge_log(id, kind, record_id, label, amount, reason, actor, actor_id, linked, data)
        values(ebda.uid(), 'custody_line', cl.id, lbl, cl.amount, rsn, u.name, u.id, jsonb_build_object('expenses', n_e, 'expenses_amount', v),
               to_jsonb(cl) || jsonb_build_object('expenses', (select coalesce(jsonb_agg(to_jsonb(e) - 'doc_url'),'[]'::jsonb) from ebda.expenses e where e.custody_id = cl.custody_id and e.line_id = cl.line_id)));
        delete from ebda.expenses where custody_id = cl.custody_id and line_id = cl.line_id;
        delete from ebda.custody_lines where id = cl.id;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', case when p_commit then 'commit' else 'preview' end, 'kind', p_kind, 'final', true,
    'ok_n', jsonb_array_length(ok_rows), 'skip_n', jsonb_array_length(skip), 'amount', amt,
    'effect', jsonb_build_object('budget_spent', 0, 'custody_spent', 0, 'custody_received', 0), 'rows', ok_rows, 'skipped', skip);
end $pg$;

-- ============================================================================
--  (6) تقرير حالة الموازنات (أسبوعى · شهرى · سنوى · فترة مخصصة) — مصروف الفترة منفصل عن التراكمى حتى نهايتها
--      الحالة دائماً من الموازنة الكلية للبند (التراكمى من بداية العام المالى حتى نهاية الفترة ÷ الموازنة الكلية)
-- ============================================================================
create or replace function ebda.budget_status_report(u ebda.users, f jsonb) returns jsonb
language plpgsql stable security definer set search_path = ebda as $bsr$
declare
  d_from date; d_to date; fy0 date; star boolean := coalesce(u.schools,'')='*' or ebda.rk(u)='admin'; sch text[] := ebda.scope_arr(u);
  sid text := coalesce(f->>'school_id',''); cat text := coalesce(f->>'category',''); sec text := coalesce(f->>'section',''); stf text := coalesce(f->>'state','');
  near numeric := ebda.cfg_int('near_exhaust_pct', 80); rows_ jsonb; summ jsonb;
begin
  if not ebda.sees_budgets(u) then return ebda.err('تقرير حالة الموازنات للأدمن والمدير المالى'); end if;
  d_from := ebda.safe_date(f->>'date_from'); d_to := ebda.safe_date(f->>'date_to');
  if d_from is null or d_to is null or d_from > d_to then return ebda.err('حدد الفترة (من / إلى) بشكل صحيح'); end if;
  fy0 := coalesce(ebda.fy_start_for(d_to::text), date_trunc('year', d_to)::date);
  with ln as (
    select l.id, l.school_id, s.name school, coalesce(s.category,'school') category, coalesce(l.section,'') section, l.name, coalesce(l.allocated,0) alloc, l.monthly_plan
    from ebda.lines l join ebda.schools s on s.id = l.school_id
    where coalesce(l.deleted_at,'') = '' and (star or l.school_id = any(sch))
      and (sid = '' or l.school_id = sid) and (cat = '' or coalesce(s.category,'school') = cat) and (sec = '' or ebda.norm_txt(coalesce(l.section,'')) = ebda.norm_txt(sec))),
  ex as (select e.line_id, e.amount, ebda.safe_date(e.date) d, ebda.counts_in_budget(e) cnt, ebda.expense_stage(e) stg
         from ebda.expenses e where e.line_id in (select id from ln) and coalesce(e.cancelled_at,'') = ''),
  agg as (select ln.*,
            coalesce((select sum(amount) from ex where ex.line_id = ln.id and ex.cnt and ex.d between d_from and d_to),0) period_spent,
            coalesce((select sum(amount) from ex where ex.line_id = ln.id and ex.cnt and ex.d between fy0 and d_to),0) cumulative,
            coalesce((select sum(amount) from ex where ex.line_id = ln.id and ex.stg in ('pending_manager','pending_finance','fin_returned','returned') and ex.d <= d_to),0) committed,
            coalesce((select sum(ebda.plan_month(ln.monthly_plan, ln.alloc, ebda.fy_month(to_char(m, 'YYYY-MM-DD')))
                       * ((least(d_to, (m + interval '1 month - 1 day')::date) - greatest(d_from, m::date) + 1)::numeric
                          / extract(day from (m + interval '1 month - 1 day'))::numeric))
                      from generate_series(date_trunc('month', d_from), date_trunc('month', d_to), interval '1 month') m), 0) period_plan
          from ln),
  st as (select agg.*, ebda.line_state(alloc, cumulative, near) state from agg where alloc > 0 or cumulative > 0 or period_spent > 0 or committed > 0)
  select coalesce(jsonb_agg(jsonb_build_object('line_id', id, 'school_id', school_id, 'budget', school, 'category', category, 'section', section, 'line', name,
      'alloc', alloc, 'period_spent', period_spent, 'cumulative', cumulative, 'committed', committed, 'consumption', cumulative,
      'remaining', alloc - cumulative, 'pct', case when alloc > 0 then round(cumulative * 100 / alloc, 1) end, 'state', state, 'label', ebda.line_state_label(state),
      'period_plan', round(period_plan, 2),
      'note', case state
         when 'over' then 'تجاوز الموازنة الكلية بمبلغ ' || to_char(cumulative - alloc, 'FM999,999,999,990.00')
         when 'at_risk' then 'على وشك تجاوز الموازنة — المتبقى ' || to_char(alloc - cumulative, 'FM999,999,999,990.00')
         when 'no_budget' then 'صرف بدون موازنة معتمدة'
         else case when period_spent > period_plan + 0.5 and alloc > 0 then 'تجاوز مخصص الفترة مع بقائه ضمن الموازنة الكلية' else '' end end)
      order by school, section, name), '[]'::jsonb) into rows_
  from st where stf = '' or state = stf;
  summ := jsonb_build_object('lines', jsonb_array_length(rows_),
    'alloc', coalesce((select sum((x->>'alloc')::numeric) from jsonb_array_elements(rows_) x),0),
    'period_spent', coalesce((select sum((x->>'period_spent')::numeric) from jsonb_array_elements(rows_) x),0),
    'cumulative', coalesce((select sum((x->>'cumulative')::numeric) from jsonb_array_elements(rows_) x),0),
    'committed', coalesce((select sum((x->>'committed')::numeric) from jsonb_array_elements(rows_) x),0),
    'remaining', coalesce((select sum((x->>'remaining')::numeric) from jsonb_array_elements(rows_) x),0),
    'within', (select count(*) from jsonb_array_elements(rows_) x where x->>'state' = 'within'),
    'at_risk', (select count(*) from jsonb_array_elements(rows_) x where x->>'state' = 'at_risk'),
    'over', (select count(*) from jsonb_array_elements(rows_) x where x->>'state' = 'over'),
    'no_budget', (select count(*) from jsonb_array_elements(rows_) x where x->>'state' = 'no_budget'));
  summ := summ || jsonb_build_object('pct', case when (summ->>'alloc')::numeric > 0 then round((summ->>'cumulative')::numeric * 100 / (summ->>'alloc')::numeric, 1) end);
  return jsonb_build_object('ok', true, 'has_data', jsonb_array_length(rows_) > 0, 'date_from', d_from::text, 'date_to', d_to::text, 'fy_start', fy0::text,
    'rules', jsonb_build_object('near_pct', near, 'over_pct', ebda.cfg_int('status_over_pct', 100), 'within_from', ebda.cfg_int('status_within_from', 0)),
    'generated_at', now()::text, 'summary', summ, 'rows', rows_);
end $bsr$;

-- حالة البند فى التقارير (نفس القاعدة القابلة للضبط): none · within · near (على وشك) · over — الـ 100% «على وشك» وليست «مستنفد»
create or replace function ebda.budget_state(alloc numeric, spent numeric) returns text language sql stable as $$
  select case when coalesce(alloc,0) <= 0.5 and coalesce(spent,0) <= 0.5 then 'none'
              when coalesce(alloc,0) <= 0.5 then 'over'
              when coalesce(spent,0) * 100 > alloc * ebda.cfg_int('status_over_pct', 100) then 'over'
              when coalesce(spent,0) * 100 >= alloc * ebda.cfg_int('near_exhaust_pct', 80) then 'near'
              else 'within' end $$;

-- ============================================================================
--  (7) تقارير الرواتب — كل التجميعات على الخادم من القسائم القائمة (الملغاة خارجها)
--      المستحقات · الخصومات (حسب النوع) · الاستقطاعات (حسب النوع) · التزامات الشركة (منفصلة) · الصافى
-- ============================================================================
create or replace function ebda.slip_lines(p ebda.payslips) returns table(kind text, code text, name text, amount numeric, reason text, item_date text, source text)
language sql stable security definer set search_path = ebda as $$
  -- المستحقات
  select 'earning', 'base', case when p.contract_net is not null then 'صافى الراتب التعاقدى' else 'الراتب الأساسى' end,
         coalesce(p.base_due, p.contract_net, p.base, 0), '', '', 'slip'
  union all select 'earning', 'allowances', 'البدلات', coalesce(p.allowances,0), '', '', 'slip' where coalesce(p.allowances,0) <> 0
  union all select 'earning', 'ot_effects', 'إضافى (مؤثرات)', coalesce(p.ot_amount,0), '', '', 'effects' where coalesce(p.ot_amount,0) <> 0
  -- خصومات المؤثرات والحضور (من الملف)
  union all select 'deduction', 'ded_effects', 'خصم ساعات/أيام (مؤثرات)', coalesce(p.ded_amount,0), '', '', 'effects' where coalesce(p.ded_amount,0) <> 0
  union all select 'deduction', 'ded_attendance', 'خصومات الحضور والغياب (إجمالى الملف)', coalesce(p.ded_total,0), '', '', 'slip'
    where p.contract_net is null and coalesce(p.ded_total,0) <> 0
      and not exists(select 1 from ebda.payslip_items i where i.payslip_id = p.id and i.source = 'import' and i.kind = 'deduction')
  -- عناصر الملف التفصيلية + المؤثرات اليدوية (تفاصيلها إن وُجدت، وإلا قيمتها المجمعة)
  union all select i.kind, i.code, c.name, i.amount, i.reason, i.item_date, i.source from ebda.payslip_items i join ebda.payroll_components c on c.code = i.code
    where i.payslip_id = p.id and (i.source = 'import' or exists(select 1 from ebda.payslip_items m where m.payslip_id = p.id and m.source = 'manual'))
  union all select c.kind, a.key, c.name, a.value::numeric, '', '', 'manual' from jsonb_each_text(coalesce(p.adjustments,'{}'::jsonb)) a
    join ebda.payroll_components c on c.code = a.key
    where not exists(select 1 from ebda.payslip_items m where m.payslip_id = p.id and m.source = 'manual') and coalesce(nullif(a.value,'')::numeric,0) <> 0
$$;

create or replace function ebda.payroll_report(u ebda.users, f jsonb) returns jsonb
language plpgsql stable security definer set search_path = ebda as $pr$
declare
  m_from text := coalesce(nullif(f->>'month_from',''), '0000-00'); m_to text := coalesce(nullif(f->>'month_to',''), '9999-99');
  sid text := coalesce(f->>'school_id',''); eid text := coalesce(f->>'employee_id',''); ins text := coalesce(f->>'insurance','');
  dty text := coalesce(f->>'ded_type',''); wty text := coalesce(f->>'wh_type',''); pst text := coalesce(f->>'status','');
  ids text[]; rows_ jsonb; items jsonb; res jsonb;
begin
  if not (ebda.sees_budgets(u) or ebda.can(u,'payroll.view')) then return ebda.err('لا صلاحية لعرض تقارير الرواتب'); end if;
  ids := array(select p.id from ebda.payslips p left join ebda.employees e on e.id = p.employee_id
    where coalesce(p.cancelled_at,'') = '' and ebda.can_school(u, p.school_id) and p.month between m_from and m_to
      and (sid = '' or p.school_id = sid) and (eid = '' or p.employee_id = eid)
      and (ins = '' or ebda.ins_cat(coalesce(nullif(p.insurance_status,''), e.insurance_status)) = ins)
      and (pst = '' or coalesce((select pp.status from ebda.payroll_periods pp where pp.school_id = p.school_id and pp.month = p.month), 'draft') = pst)
      and (dty = '' or exists(select 1 from ebda.slip_lines(p) l where l.kind = 'deduction' and l.code = dty))
      and (wty = '' or exists(select 1 from ebda.slip_lines(p) l where l.kind = 'withholding' and l.code = wty)));
  with sl as (select p.*, e.emp_no, coalesce(nullif(p.insurance_status,''), e.insurance_status, '') ins_label,
                ebda.ins_cat(coalesce(nullif(p.insurance_status,''), e.insurance_status)) ins_c, s.name school,
                coalesce((select pp.status from ebda.payroll_periods pp where pp.school_id = p.school_id and pp.month = p.month), 'draft') pstatus
              from ebda.payslips p left join ebda.employees e on e.id = p.employee_id join ebda.schools s on s.id = p.school_id where p.id = any(ids)),
  li as (select sl.id slip_id, l.* from sl cross join lateral ebda.slip_lines((select x from ebda.payslips x where x.id = sl.id)) l),
  tot as (select slip_id, coalesce(sum(amount) filter (where kind='earning'),0) earn, coalesce(sum(amount) filter (where kind='deduction'),0) ded,
            coalesce(sum(amount) filter (where kind='withholding'),0) wh, coalesce(sum(amount) filter (where kind='employer'),0) emp from li group by 1)
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', sl.id, 'employee_id', sl.employee_id, 'code', coalesce(nullif(sl.emp_code,''), sl.emp_no, ''), 'name', sl.emp_name,
        'school_id', sl.school_id, 'school', sl.school, 'job', sl.job, 'insurance', sl.ins_label, 'ins_cat', sl.ins_c, 'month', sl.month, 'status', sl.pstatus,
        'base', coalesce(sl.base_due, sl.contract_net, sl.base, 0), 'allowances', coalesce(sl.allowances,0),
        'earnings', coalesce(t.earn,0), 'deductions', coalesce(t.ded,0), 'withholdings', coalesce(t.wh,0), 'employer', coalesce(t.emp,0), 'net', sl.net,
        'computed_net', coalesce(t.earn,0) - coalesce(t.ded,0) - coalesce(t.wh,0),
        'ded_map', coalesce((select jsonb_object_agg(code, s_) from (select code, sum(amount) s_ from li where li.slip_id = sl.id and kind = 'deduction' group by code) q), '{}'::jsonb),
        'wh_map', coalesce((select jsonb_object_agg(code, s_) from (select code, sum(amount) s_ from li where li.slip_id = sl.id and kind = 'withholding' group by code) q), '{}'::jsonb))
        order by sl.school, sl.emp_name, sl.month) from sl left join tot t on t.slip_id = sl.id), '[]'::jsonb),
    'items', coalesce((select jsonb_agg(jsonb_build_object('slip_id', li.slip_id, 'kind', li.kind, 'code', li.code, 'type', li.name, 'amount', li.amount,
        'reason', li.reason, 'date', li.item_date, 'source', li.source, 'name', sl.emp_name, 'code_emp', coalesce(nullif(sl.emp_code,''), sl.emp_no, ''),
        'school', sl.school, 'month', sl.month, 'ins_cat', sl.ins_c) order by li.kind, li.name, sl.school, sl.emp_name)
        from li join sl on sl.id = li.slip_id where li.kind in ('deduction','withholding','employer')
          and (dty = '' or li.kind <> 'deduction' or li.code = dty) and (wty = '' or li.kind <> 'withholding' or li.code = wty)), '[]'::jsonb),
    'types', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'code', code, 'type', name, 'n', n, 'amount', a) order by kind, a desc)
        from (select kind, code, max(name) name, count(*) n, sum(amount) a from li where kind in ('deduction','withholding','employer')
                and (dty = '' or kind <> 'deduction' or code = dty) and (wty = '' or kind <> 'withholding' or code = wty) group by kind, code) q), '[]'::jsonb),
    'by_school', coalesce((select jsonb_agg(jsonb_build_object('school_id', school_id, 'school', school, 'employees', n_emp, 'slips', n_sl, 'insured', n_ins, 'uninsured', n_un, 'unspecified', n_na,
        'earnings', ea, 'deductions', de, 'withholdings', wh, 'employer', em, 'net', ne, 'avg_net', case when n_sl > 0 then round(ne / n_sl, 2) end,
        'ded_types', coalesce((select jsonb_object_agg(name, a) from (select li.name, sum(li.amount) a from li join sl x on x.id = li.slip_id where x.school_id = q.school_id and li.kind = 'deduction' group by li.name) z), '{}'::jsonb),
        'wh_types', coalesce((select jsonb_object_agg(name, a) from (select li.name, sum(li.amount) a from li join sl x on x.id = li.slip_id where x.school_id = q.school_id and li.kind = 'withholding' group by li.name) z), '{}'::jsonb))
        order by school) from (select sl.school_id, sl.school, count(distinct sl.employee_id) n_emp, count(*) n_sl,
              count(distinct sl.employee_id) filter (where ins_c = 'insured') n_ins, count(distinct sl.employee_id) filter (where ins_c = 'uninsured') n_un,
              count(distinct sl.employee_id) filter (where ins_c = 'unspecified') n_na,
              coalesce(sum(t.earn),0) ea, coalesce(sum(t.ded),0) de, coalesce(sum(t.wh),0) wh, coalesce(sum(t.emp),0) em, coalesce(sum(sl.net),0) ne
            from sl left join tot t on t.slip_id = sl.id group by 1, 2) q), '[]'::jsonb),
    'by_insurance', coalesce((select jsonb_agg(jsonb_build_object('ins_cat', ins_c, 'employees', n_emp, 'slips', n_sl, 'earnings', ea, 'deductions', de, 'withholdings', wh, 'net', ne,
        'ded_types', coalesce((select jsonb_object_agg(name, a) from (select li.name, sum(li.amount) a from li join sl x on x.id = li.slip_id where x.ins_c = q.ins_c and li.kind = 'deduction' group by li.name) z), '{}'::jsonb),
        'wh_types', coalesce((select jsonb_object_agg(name, a) from (select li.name, sum(li.amount) a from li join sl x on x.id = li.slip_id where x.ins_c = q.ins_c and li.kind = 'withholding' group by li.name) z), '{}'::jsonb),
        'dist', coalesce((select jsonb_agg(jsonb_build_object('school', x.school, 'month', x.month, 'employees', count_, 'net', net_) order by x.month, x.school)
                 from (select school, month, count(distinct employee_id) count_, sum(net) net_ from sl where sl.ins_c = q.ins_c group by school, month) x), '[]'::jsonb))
        order by ins_c) from (select sl.ins_c, count(distinct sl.employee_id) n_emp, count(*) n_sl, coalesce(sum(t.earn),0) ea, coalesce(sum(t.ded),0) de,
              coalesce(sum(t.wh),0) wh, coalesce(sum(sl.net),0) ne from sl left join tot t on t.slip_id = sl.id group by 1) q), '[]'::jsonb),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', month, 'slips', n_sl, 'employees', n_emp, 'insured', n_ins, 'uninsured', n_un,
        'earnings', ea, 'deductions', de, 'withholdings', wh, 'net', ne) order by month)
        from (select sl.month, count(*) n_sl, count(distinct sl.employee_id) n_emp, count(distinct sl.employee_id) filter (where ins_c = 'insured') n_ins,
              count(distinct sl.employee_id) filter (where ins_c = 'uninsured') n_un, coalesce(sum(t.earn),0) ea, coalesce(sum(t.ded),0) de,
              coalesce(sum(t.wh),0) wh, coalesce(sum(sl.net),0) ne from sl left join tot t on t.slip_id = sl.id group by 1) q), '[]'::jsonb),
    'totals', (select jsonb_build_object('slips', count(*), 'employees', count(distinct sl.employee_id), 'earnings', coalesce(sum(t.earn),0), 'deductions', coalesce(sum(t.ded),0),
        'withholdings', coalesce(sum(t.wh),0), 'employer', coalesce(sum(t.emp),0), 'net', coalesce(sum(sl.net),0),
        'net_mismatch', count(*) filter (where abs(coalesce(t.earn,0) - coalesce(t.ded,0) - coalesce(t.wh,0) - coalesce(sl.net,0)) > 1))
        from sl left join tot t on t.slip_id = sl.id)
  ) into res;
  return jsonb_build_object('ok', true, 'filters', f, 'generated_at', now()::text) || res;
end $pr$;

-- ============================================================================
--  (7) السنة المالية الافتراضية: 1 يوليو 2026 ← 30 يونيو 2027 (يعدّلها الأدمن من «الإعدادات ← إعدادات السنة المالية»)
--      يُطبَّق مرة واحدة فقط إذا كان العام الحالى ما زال على القيمة التلقائية القديمة (1 سبتمبر 2026) — ولا تتغير أى حركة أو تاريخ
-- ============================================================================
do $fy$
declare cur ebda.fiscal_years; adm ebda.users; r jsonb;
begin
  if exists(select 1 from ebda.config where key = 'fy_v10_default_applied') then return; end if;
  select * into cur from ebda.fiscal_years where is_current like '%نعم%' limit 1;
  select * into adm from ebda.users where ebda.role_key(role) = 'admin' order by id limit 1;
  if cur.id is not null and cur.start_date = date '2026-09-01' and adm.id is not null then
    -- العام السابق التلقائى (1/9/2025 ← 31/8/2026) ينتهى 30/6/2026 حتى لا تتداخل الأعوام
    update ebda.fiscal_years set end_date = date '2026-06-30', note = trim(coalesce(note,'') || ' (عُدّلت نهايته لبداية العام المالى الجديد 1/7/2026)')
     where id <> cur.id and start_date = date '2025-09-01' and end_date = date '2026-08-31';
    r := ebda.save_fiscal_year(adm, jsonb_build_object('id', cur.id, 'label', cur.label, 'start_date', '2026-07-01', 'end_date', '2027-06-30',
           'note', coalesce(cur.note,''), 'is_current', 'نعم'));
    insert into ebda.audit_log(id, ts, actor, actor_role, action, entity, details)
    values(ebda.uid(), now()::text, 'ترقية النظام (009)', 'النظام', 'saveFiscalYear', cur.id,
           jsonb_build_object('before', jsonb_build_object('start_date', cur.start_date, 'end_date', cur.end_date),
                              'after', jsonb_build_object('start_date', '2026-07-01', 'end_date', '2027-06-30'), 'result', r)::text);
  end if;
  insert into ebda.config(key, value) values ('fy_v10_default_applied', now()::text) on conflict (key) do nothing;
end $fy$;

-- ============================================================================
--  (8) المصروفات والاحتياجات والاعتمادات (ملف «متابعة المصروفات والاحتياجات»)
--      اعتماد المدير العام + ملاحظاته (الأدمن فقط) · اعتماد المدير المالى (صلاحية الاعتماد المالى) — يُفرض فى الخادم وفى الاستيراد
-- ============================================================================
alter table ebda.expenses add column if not exists gm_approval text default '';   -- '' بانتظار · approved · rejected
alter table ebda.expenses add column if not exists gm_note text default '';
alter table ebda.expenses add column if not exists gm_by text default '';
alter table ebda.expenses add column if not exists gm_at text default '';
alter table ebda.requests add column if not exists gm_approval text default '';
alter table ebda.requests add column if not exists gm_note text default '';
alter table ebda.requests add column if not exists gm_by text default '';
alter table ebda.requests add column if not exists gm_at text default '';
alter table ebda.requests add column if not exists import_batch text default '';
alter table ebda.request_items add column if not exists gm_note text default '';
alter table ebda.request_items add column if not exists fin_approval text default '';   -- '' · approved · rejected (اعتماد المدير المالى للبند)
alter table ebda.request_items add column if not exists fin_by text default '';
alter table ebda.request_items add column if not exists fin_at text default '';
alter table ebda.request_items add column if not exists import_key text default '';
alter table ebda.request_items add column if not exists decision_date text default '';
create index if not exists ix_request_items_import_key on ebda.request_items(import_key);

create or replace function ebda.truthy(t text) returns boolean language sql immutable as $$
  select lower(btrim(coalesce(t,''))) in ('1','true','yes','نعم','✓','✔','x','تم','معتمد') $$;

-- قرار البند من نص الملف ← رمز النظام
create or replace function ebda.decision_code(t text) returns text language sql immutable as $$
  select case when t is null or btrim(t) = '' then ''
              when ebda.norm_txt(t) like '%جزئ%' then 'partial'
              when ebda.norm_txt(t) like '%معتمد%' or ebda.norm_txt(t) like '%موافق%' then 'approved'
              when ebda.norm_txt(t) like '%مرفوض%' or ebda.norm_txt(t) like '%رفض%' then 'rejected'
              when ebda.norm_txt(t) like '%مؤجل%' or ebda.norm_txt(t) like '%تاجيل%' then 'deferred'
              when ebda.norm_txt(t) like '%ملغ%' then 'cancelled'
              else '?' end $$;

-- مطابقة اسم بند (نوع المصروف) ببند موازنة الجهة: الكتالوج الموحد/المرادفات ثم الاسم المطابق — بدون تخمين
create or replace function ebda.match_school_line(p_school text, p_name text) returns jsonb language plpgsql stable security definer set search_path = ebda as $ml$
declare cid text; lid text; n int;
begin
  if coalesce(btrim(p_name),'') = '' then return jsonb_build_object('how','none'); end if;
  cid := ebda.catalog_resolve(p_name);
  if cid is not null then
    lid := ebda.school_line_for(p_school, cid);
    if lid is not null then return jsonb_build_object('how','catalog','line_id',lid,'line',(select name from ebda.lines where id = lid)); end if;
  end if;
  select count(*), min(l.id) into n, lid from ebda.lines l where l.school_id = p_school and coalesce(l.deleted_at,'') = ''
    and ebda.line_norm(l.name) = ebda.line_norm(p_name);
  if n = 1 then return jsonb_build_object('how','exact','line_id',lid,'line',(select name from ebda.lines where id = lid)); end if;
  return jsonb_build_object('how', case when n > 1 then 'ambiguous' else 'unmatched' end);
end $ml$;

-- استيراد الاحتياجات (معاينة ثم تنفيذ): صف = صنف · طلب لكل (تاريخ الطلب · الجهة الطالبة · سبب الطلب) · منع التكرار ببصمة ثابتة
create or replace function ebda.import_needs(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $in$
declare
  sid text := req->>'school_id'; commit_ boolean := coalesce(req->>'mode','preview') = 'commit'; lmap jsonb := coalesce(req->'line_map','{}'::jsonb);
  ln jsonb; i int := 0; errs jsonb; warns jsonb; out_ jsonb := '[]'::jsonb; m jsonb; lid text; lname text; how text; qty numeric; up numeric; tot numeric;
  dt date; key_ text; seen text[] := '{}'; st text; dec text; grp text; rid text; groups jsonb := '{}'::jsonb; bid text := ebda.uid();
  can_dec boolean := ebda.rk(u) = 'admin' or ebda.can(u,'request.approve') or ebda.can(u,'request.fin_approve');
  can_fin boolean := ebda.can(u,'request.fin_approve'); is_gm boolean := ebda.rk(u) = 'admin';
  dupc jsonb := '{}'::jsonb; okey text; n_ok int := 0; n_err int := 0; n_dup int := 0; n_rev int := 0; n_req int := 0; amt numeric := 0; xr jsonb;
begin
  if not (ebda.rk(u) in ('admin','finance_manager') or ebda.can(u,'request.create')) then return ebda.err('لا صلاحية لاستيراد الاحتياجات'); end if;
  if sid is null or not exists(select 1 from ebda.schools where id = sid) then return ebda.err('اختر المدرسة / الجهة'); end if;
  if not ebda.can_school(u, sid) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
  if jsonb_typeof(coalesce(req->'rows','null'::jsonb)) <> 'array' or jsonb_array_length(req->'rows') = 0 then return ebda.err('لا توجد بيانات'); end if;
  for ln in select * from jsonb_array_elements(req->'rows') loop
    i := i + 1; errs := '[]'::jsonb; warns := '[]'::jsonb; lid := null; lname := ''; how := ''; dt := null;
    if coalesce(btrim(ln->>'name'),'') = '' then errs := errs || to_jsonb('بدون اسم صنف'::text); end if;
    qty := ebda.imp_num(ln->>'qty'); up := ebda.imp_num(ln->>'unit_price'); tot := ebda.imp_num(ln->>'total');
    if coalesce(btrim(ln->>'qty'),'') <> '' and qty is null then errs := errs || to_jsonb('العدد غير صحيح'::text); end if;
    if coalesce(btrim(ln->>'unit_price'),'') <> '' and up is null then errs := errs || to_jsonb('القيمة التقديرية غير صحيحة'::text); end if;
    if qty is null and up is null and tot is null then warns := warns || to_jsonb('لا توجد قيمة فى الملف — يُستورد بقيمة صفر للمراجعة'::text); end if;
    if qty is null then qty := 1; end if;
    if up is null then up := coalesce(tot, 0) / nullif(qty, 0); end if;
    if tot is not null and abs(tot - round(qty * coalesce(up,0), 2)) > 0.01 and up is not null and coalesce(btrim(ln->>'unit_price'),'') <> '' then
      warns := warns || to_jsonb('الإجمالى المكتوب فى الملف (' || tot || ') ≠ العدد × القيمة (' || round(qty * coalesce(up,0), 2) || ') — اعتُمد العدد × القيمة'); end if;
    tot := round(qty * coalesce(up,0), 2);
    if coalesce(btrim(ln->>'date'),'') <> '' then dt := ebda.safe_date(ln->>'date'); if dt is null then errs := errs || to_jsonb('تاريخ الطلب غير صحيح'::text); end if;
    else warns := warns || to_jsonb('تاريخ الطلب غير مذكور فى الملف — يبقى فارغاً كما هو'::text); end if;
    -- البند: ربط يدوى من شاشة المراجعة ← ثم الموحد/المرادفات ← ثم الاسم المطابق
    if coalesce(lmap->>btrim(coalesce(ln->>'line','')),'') <> '' and exists(select 1 from ebda.lines l where l.id = lmap->>btrim(ln->>'line') and l.school_id = sid) then
      lid := lmap->>btrim(ln->>'line'); how := 'manual'; lname := (select name from ebda.lines where id = lid);
    else
      m := ebda.match_school_line(sid, ln->>'line'); how := m->>'how'; lid := m->>'line_id'; lname := coalesce(m->>'line','');
    end if;
    if lid is null then
      -- v10.4: لا يُفقد أى صنف — يُستورد غير مربوط ببند (ويُحفظ نص البند كما فى الملف) ويظهر للربط لاحقاً
      n_rev := n_rev + 1;
      warns := warns || to_jsonb(case when how = 'none' then 'نوع المصروف (البند) فارغ فى الملف — يُستورد غير مربوط ببند (اربطه لاحقاً)'
                                      when how = 'ambiguous' then 'البند يطابق أكثر من بند — يُستورد غير مربوط (حدده يدوياً)'
                                      else 'البند «' || coalesce(ln->>'line','') || '» غير موجود فى موازنة الجهة — يُستورد غير مربوط (اربطه يدوياً)' end);
    end if;
    dec := ebda.decision_code(ln->>'decision');
    if dec = '?' then warns := warns || to_jsonb(('قرار غير معروف «' || (ln->>'decision') || '» — سيُترك بدون قرار')::text); dec := ''; end if;
    if dec <> '' and not can_dec then warns := warns || to_jsonb('تم تجاهل «الاعتماد» — ليس من صلاحياتك'::text); dec := ''; end if;
    if coalesce(btrim(ln->>'gm_note'),'') <> '' and not is_gm then warns := warns || to_jsonb('تم تجاهل «ملاحظات المدير العام» — للأدمن فقط'::text); end if;
    if ebda.truthy(ln->>'fin_ok') then warns := warns || to_jsonb('علامة «اعتماد المدير المالى» فى الملف تُحفظ كمعلومة فقط — الاعتماد من الجدول بواسطة المدير المالى'::text); end if;
    key_ := md5(sid || '|' || coalesce(dt::text,'') || '|' || ebda.norm_txt(coalesce(ln->>'name','')) || '|' || qty || '|' || round(coalesce(up,0),2) || '|' || ebda.norm_txt(coalesce(ln->>'dept','')));
    st := case when jsonb_array_length(errs) > 0 then 'error' else 'ok' end;
    -- v10.4: السطور المتطابقة داخل نفس الملف تُستورد عند طلب ذلك صراحةً (مفتاح مميز بترتيب التكرار — إعادة الاستيراد لا تكررها)
    okey := key_;
    if st = 'ok' and key_ = any(seen) and coalesce(req->>'keep_file_dups','') in ('true','1') then
      dupc := jsonb_set(dupc, array[okey], to_jsonb(coalesce((dupc->>okey)::int, 0) + 1));
      key_ := md5(okey || '#' || (dupc->>okey)); end if;
    if st = 'ok' and (key_ = any(seen) or exists(select 1 from ebda.request_items it join ebda.requests r on r.id = it.request_id
                                                where it.import_key = key_ and coalesce(r.status,'') <> 'cancelled')) then
      st := 'duplicate'; warns := warns || to_jsonb(case when key_ = any(seen) then 'مكرر داخل الملف' else 'مستورد من قبل — لن يتكرر' end);
    end if;
    seen := seen || okey;
    if st = 'ok' then n_ok := n_ok + 1; amt := amt + tot; elsif st = 'error' then n_err := n_err + 1; else n_dup := n_dup + 1; end if;
    out_ := out_ || jsonb_build_object('i', i, 'row', coalesce(ln->>'row', i::text), 'name', ln->>'name', 'qty', qty, 'unit_price', up, 'total', tot,
      'source_line', coalesce(ln->>'line',''), 'line_id', coalesce(lid,''), 'line', lname, 'how', how, 'date', coalesce(dt::text,''), 'dept', coalesce(ln->>'dept',''),
      'decision', dec, 'status', st, 'errors', errs, 'warnings', warns, 'key', key_);
  end loop;
  if not commit_ then
    return jsonb_build_object('ok', true, 'mode', 'preview', 'rows', out_,
      'summary', jsonb_build_object('rows', i, 'ready', n_ok, 'errors', n_err, 'duplicates', n_dup, 'needs_review', n_rev, 'amount', amt,
        'matched', (select count(*) from jsonb_array_elements(out_) x where x->>'line_id' <> ''),
        'unmatched_lines', coalesce((select jsonb_agg(distinct x->>'source_line') from jsonb_array_elements(out_) x where x->>'line_id' = '' and x->>'source_line' <> ''), '[]'::jsonb),
        'unified', coalesce((select jsonb_agg(distinct jsonb_build_object('from', x->>'source_line', 'to', x->>'line', 'how', x->>'how'))
                            from jsonb_array_elements(out_) x where x->>'line_id' <> '' and ebda.line_norm(x->>'source_line') <> ebda.line_norm(x->>'line')), '[]'::jsonb)));
  end if;
  if n_ok = 0 then return ebda.err('لا توجد سطور جاهزة للاستيراد (صحّح الأخطاء أو اربط البنود)'); end if;
  insert into ebda.import_batches(id, kind, file_name, actor, actor_id, approve_mode, rows_n, school_id)
  values(bid, 'needs', coalesce(req->>'file_name',''), u.name, u.id, coalesce(req->>'sheet',''), i, sid);
  i := 0;
  for ln in select * from jsonb_array_elements(req->'rows') loop
    i := i + 1;
    xr := out_->(i - 1);
    if xr->>'status' <> 'ok' then continue; end if;
    grp := coalesce(xr->>'date','') || '|' || ebda.norm_txt(coalesce(ln->>'dept','')) || '|' || ebda.norm_txt(coalesce(ln->>'reason',''));
    rid := groups->>grp;
    if rid is null then
      rid := ebda.uid();
      insert into ebda.requests(id,school_id,requester,requester_name,status,note,total,created_at,req_no,reason,request_date,dept,description,priority,import_batch,submitted_at)
      values(rid, sid, u.username, u.name, 'pending_supervisor', 'مستورد من ملف «' || coalesce(req->>'file_name','') || '»', 0, now()::text,
             'REQ-'||lpad(nextval('ebda.seq_req')::text,4,'0'), coalesce(btrim(ln->>'reason'),''),
             coalesce(xr->>'date',''), coalesce(btrim(ln->>'dept'),''),
             coalesce(btrim(ln->>'description'),''), coalesce(btrim(ln->>'priority'),''), bid, now()::text);
      -- v10.1: الطلب مربوط بمن استورده (وبمسئول العهدة نفسه إن كان هو المستورد) — بلا اعتماد تلقائى
      update ebda.requests set requester_id = u.id,
        holder_id = case when ebda.rk(u) = 'custody_officer' then u.id else coalesce(holder_id,'') end,
        holder_name = case when ebda.rk(u) = 'custody_officer' then u.name else coalesce(holder_name,'') end where id = rid;
      groups := groups || jsonb_build_object(grp, rid); n_req := n_req + 1;
      perform ebda.req_event(rid, u, 'استيراد من Excel', '', 'pending_supervisor', coalesce(req->>'file_name',''));
    end if;
    insert into ebda.request_items(id,request_id,line_id,name,amount,unit,qty,unit_price,stock_check,stock_result,decision,item_note,sort,
                                   gm_note,fin_approval,fin_by,fin_at,import_key,decision_date,sup_note)
    values(ebda.uid(), rid, xr->>'line_id', btrim(ln->>'name'), (xr->>'total')::numeric, coalesce(btrim(ln->>'unit'),''), (xr->>'qty')::numeric, (xr->>'unit_price')::numeric,
           coalesce(btrim(ln->>'stock_check'),''), coalesce(btrim(ln->>'stock_result'),''), coalesce(xr->>'decision',''),
           coalesce(btrim(ln->>'description'),''), i,
           case when is_gm then coalesce(btrim(ln->>'gm_note'),'') else '' end,
           '', '', '',
           xr->>'key', coalesce(ebda.safe_date(ln->>'decision_date')::text,''), coalesce(btrim(ln->>'decision_note'),''));
    -- v10.3: علامات الملف تُحفظ كمعلومة (لا اعتماد بالاستيراد) — والملاحظات النصية لا تضيع
    update ebda.request_items set file_fin_ok = case when ebda.truthy(ln->>'fin_ok') then 'نعم' else '' end,
      file_settle = case when ebda.truthy(ln->>'settlement') then 'نعم' else '' end,
      file_gm_note = case when not is_gm then coalesce(btrim(ln->>'gm_note'),'') else '' end,
      src_line = coalesce(btrim(ln->>'line'),''),
      src_row = case when jsonb_typeof(ln->'orig_h') = 'array' then jsonb_build_object('h', ln->'orig_h', 'v', ln->'orig_v', 'sheet', coalesce(req->>'sheet',''), 'row', coalesce(ln->>'row','')) end,
      category = coalesce(btrim(ln->>'category'),''),
      dept = coalesce(btrim(ln->>'dept'),'')   -- v10.11: الجهة الطالبة لكل صنف كما فى الملف
    where request_id = rid and import_key = xr->>'key';
  end loop;
  -- إجمالى كل طلب وحالته: وجود قرار معتمد (ممن له الصلاحية) ← بانتظار المدير المالى
  update ebda.requests r set total = coalesce((select sum(amount) from ebda.request_items it where it.request_id = r.id and coalesce(it.decision,'') not in ('rejected','deferred','cancelled')),0),
    status = case when exists(select 1 from ebda.request_items it where it.request_id = r.id and it.decision in ('approved','partial')) then 'pending_accountant' else r.status end,
    decided_by = case when exists(select 1 from ebda.request_items it where it.request_id = r.id and it.decision <> '') then u.name else decided_by end,
    settlement = settlement
  where r.import_batch = bid;
  update ebda.import_batches set imported_n = n_ok, amount = amt, summary = jsonb_build_object('requests', n_req, 'items', n_ok, 'errors', n_err, 'duplicates', n_dup, 'needs_review', n_rev),
    exceptions = coalesce((select jsonb_agg(x) from jsonb_array_elements(out_) x where x->>'status' <> 'ok' or coalesce(x->>'line_id','') = ''), '[]'::jsonb) where id = bid;
  return jsonb_build_object('ok', true, 'mode', 'commit', 'batch_id', bid, 'requests', n_req, 'items', n_ok, 'skipped_duplicates', n_dup, 'errors', n_err, 'amount', amt);
end $in$;

-- اعتماد المدير العام وملاحظاته (الأدمن فقط) — مصروفات أو طلبات
create or replace function ebda.gm_review(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $gm$
declare kind text := coalesce(req->>'kind','expenses'); dec text := coalesce(req->>'decision',''); gnote text := btrim(coalesce(req->>'note',''));
  ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb))); n int;
begin
  if not ebda.can_gm(u) then return ebda.err('اعتماد المدير العام وملاحظاته للمدير العام (الأدمن) أو لمن مُنح الصلاحية صراحةً'); end if;
  if dec not in ('approved','rejected','','note') then return ebda.err('قرار غير صحيح'); end if;
  if dec = 'rejected' and length(gnote) < 3 then return ebda.err('اكتب ملاحظة المدير العام (سبب الرفض)'); end if;
  if coalesce(cardinality(ids),0) = 0 then return ebda.err('لم يتم تحديد أى سجل'); end if;
  if kind = 'expenses' then
    update ebda.expenses set gm_approval = case when dec = 'note' then gm_approval else dec end, gm_note = case when gnote <> '' or dec <> 'note' then gnote else gm_note end,
      gm_by = u.name, gm_at = now()::text, updated_by = u.name, updated_at = now()::text
    where id = any(ids) and coalesce(cancelled_at,'') = '';
  elsif kind = 'requests' then
    update ebda.requests set gm_approval = case when dec = 'note' then gm_approval else dec end, gm_note = case when gnote <> '' or dec <> 'note' then gnote else gm_note end,
      gm_by = u.name, gm_at = now()::text where id = any(ids) and coalesce(status,'') <> 'cancelled';
  else return ebda.err('نوع غير معروف'); end if;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'updated', n);
end $gm$;

-- تقرير المصروفات والاحتياجات والاعتمادات
create or replace function ebda.approvals_report(u ebda.users, f jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $ar$
declare d_from text := coalesce(nullif(f->>'date_from',''), '0000'); d_to text := coalesce(nullif(f->>'date_to',''), '9999'); sid text := coalesce(f->>'school_id','');
  star boolean := coalesce(u.schools,'')='*' or ebda.rk(u)='admin'; sch text[] := ebda.scope_arr(u);
begin
  if not ebda.sees_budgets(u) then return ebda.err('للأدمن والمدير المالى'); end if;
  return (with s as (select id, name from ebda.schools where (star or id = any(sch)) and (sid = '' or id = sid)),
  ex as (select e.*, ebda.expense_stage(e) stg, ebda.counts_in_budget(e) cnt from ebda.expenses e join s on s.id = e.school_id where coalesce(e.cancelled_at,'') = '' and e.date between d_from and d_to),
  it as (select it.*, r.status rstatus, r.gm_approval rgm, r.school_id, r.request_date from ebda.request_items it join ebda.requests r on r.id = it.request_id join s on s.id = r.school_id
         where coalesce(r.status,'') not in ('cancelled','draft') and coalesce(nullif(r.request_date,''), substr(r.created_at,1,10)) between d_from and d_to and coalesce(it.decision,'') <> 'cancelled')
  select jsonb_build_object('ok', true,
    'expenses', jsonb_build_object('n', (select count(*) from ex), 'amount', coalesce((select sum(amount) from ex),0),
      'by_stage', coalesce((select jsonb_object_agg(stg, jsonb_build_object('n', n, 'amount', a)) from (select stg, count(*) n, sum(amount) a from ex group by 1) q), '{}'::jsonb),
      'mgr_approved', jsonb_build_object('n', (select count(*) from ex where approval = 'approved'), 'amount', coalesce((select sum(amount) from ex where approval = 'approved'),0)),
      'fin_approved', jsonb_build_object('n', (select count(*) from ex where fin_approval = 'approved'), 'amount', coalesce((select sum(amount) from ex where fin_approval = 'approved'),0)),
      'gm_approved', jsonb_build_object('n', (select count(*) from ex where gm_approval = 'approved'), 'amount', coalesce((select sum(amount) from ex where gm_approval = 'approved'),0)),
      'gm_rejected', jsonb_build_object('n', (select count(*) from ex where gm_approval = 'rejected'), 'amount', coalesce((select sum(amount) from ex where gm_approval = 'rejected'),0)),
      'incomplete', jsonb_build_object('n', (select count(*) from ex where stg in ('draft','pending_manager','pending_finance','returned','fin_returned')),
                                       'amount', coalesce((select sum(amount) from ex where stg in ('draft','pending_manager','pending_finance','returned','fin_returned')),0)),
      'no_line', (select count(*) from ex where coalesce(line_id,'') = '' or not exists(select 1 from ebda.lines l where l.id = ex.line_id))),
    'needs', jsonb_build_object('n', (select count(*) from it), 'amount', coalesce((select sum(amount) from it),0),
      'by_decision', coalesce((select jsonb_object_agg(coalesce(nullif(decision,''),'pending'), jsonb_build_object('n', n, 'amount', a)) from (select decision, count(*) n, sum(amount) a from it group by 1) q), '{}'::jsonb),
      'fin_approved', jsonb_build_object('n', (select count(*) from it where fin_approval = 'approved'), 'amount', coalesce((select sum(amount) from it where fin_approval = 'approved'),0)),
      'gm_noted', (select count(*) from it where coalesce(gm_note,'') <> ''),
      'incomplete', jsonb_build_object('n', (select count(*) from it where rstatus in ('pending_supervisor','pending_accountant','needs_info','returned')),
                                        'amount', coalesce((select sum(amount) from it where rstatus in ('pending_supervisor','pending_accountant','needs_info','returned')),0)),
      'no_line', (select count(*) from it where coalesce(line_id,'') = '')),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('school', s.name, 'line', l.name, 'section', coalesce(l.section,''), 'alloc', coalesce(l.allocated,0),
        'actual', coalesce((select sum(amount) from ex where ex.line_id = l.id and ex.cnt),0),
        'needs_approved', coalesce((select sum(amount) from it where it.line_id = l.id and it.decision in ('approved','partial')),0),
        'needs_pending', coalesce((select sum(amount) from it where it.line_id = l.id and coalesce(it.decision,'') = ''),0),
        'state', ebda.line_state(coalesce(l.allocated,0), coalesce((select sum(amount) from ex where ex.line_id = l.id and ex.cnt),0), null))
        order by s.name, l.section, l.name)
      from ebda.lines l join s on s.id = l.school_id where coalesce(l.deleted_at,'') = ''
        and (exists(select 1 from ex where ex.line_id = l.id) or exists(select 1 from it where it.line_id = l.id))), '[]'::jsonb),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'kind', b.kind, 'file', b.file_name, 'at', b.created_at, 'by', b.actor, 'school', (select name from ebda.schools where id = b.school_id),
        'imported', b.imported_n, 'errors', (select count(*) from jsonb_array_elements(b.exceptions) x where x->>'status' = 'error'),
        'duplicates', (select count(*) from jsonb_array_elements(b.exceptions) x where x->>'status' = 'duplicate'),
        'unmatched', coalesce((select jsonb_agg(distinct coalesce(x->>'source_line', x->>'main')) from jsonb_array_elements(b.exceptions) x
                               where coalesce(x->>'line_id','') = '' and coalesce(x->>'source_line', x->>'main','') <> ''), '[]'::jsonb),
        'reverted', coalesce(b.reverted_at,'') <> '') order by b.created_at desc)
      from (select * from ebda.import_batches b where b.kind in ('expenses','needs') and (sid = '' or coalesce(b.school_id,'') in ('', sid)) order by created_at desc limit 50) b), '[]'::jsonb)));
end $ar$;

-- ============================================================================
--  9) صلاحيات مسئول العهدة: استيراد العهد/المصروفات · استيراد الاحتياجات · وحدة الرواتب كاملة
--     (payroll.manage = كل إجراءات وحدة الرواتب التى كانت للأدمن فقط — داخل نطاق جهاته فقط،
--      ولا تمنح أى صلاحية على الموازنات أو المستخدمين أو الإعدادات أو بقية الوحدات)
--     الأدوار الأخرى كما هى تماماً.
-- ============================================================================
create or replace function ebda.perm_defaults(rk text) returns text[] language sql immutable as $$
  select case rk
    when 'admin' then array['budget.edit','custody.create','custody.approve','expense.record','expense.approve','expense.fin_approve',
                            'request.approve','request.fin_approve','payroll.view','payroll.import','payroll.approve','manage_users','expense.import',
                            'settings.fiscal','custody.rename','lines.manage','request.create','request.mail','records.cancel','payroll.manage','custody.import','gm.approve','audit.view','settings.view','custody.amount_edit','payroll.base']
    -- v10.2: المدير المالى — اعتماداته وإجراءاته المالية فقط؛ تعديل الموازنات وإدارة البنود الموحدة بمنح صريح فقط (+budget.edit / +lines.manage)
    when 'finance_manager' then array['custody.create','custody.approve','expense.fin_approve','request.fin_approve',
                            'payroll.view','payroll.import','payroll.approve','expense.import','custody.rename','request.mail','fin.signoff','custody.amount_edit']
    when 'direct_manager' then array['expense.approve','request.approve','request.mail']
    when 'custody_officer' then array['expense.record','request.create','request.mail',
                            'expense.import','custody.import',
                            'payroll.view','payroll.import','payroll.approve','payroll.manage']
    else array[]::text[] end
$$;

-- إدارة كاملة لوحدة الرواتب (الأدمن أو صلاحية payroll.manage)
create or replace function ebda.pay_manage(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and 'payroll.manage' = any(ebda.perms_of(u)))
$$;

-- نطاق إجراءات الرواتب/العاملين القديمة (كانت للأدمن فقط): كل سجل مستهدف وكل جهة جديدة يجب أن تكون ضمن نطاق المستخدم
create or replace function ebda.pay_scope_ok(u ebda.users, action text, req jsonb) returns boolean
language plpgsql stable security definer set search_path = ebda as $ps$
declare tgt text[] := '{}'; s text;
begin
  if ebda.rk(u) = 'admin' then return true; end if;
  if action in ('updateSalary','deleteSalary') then tgt := tgt || (select school_id from ebda.salaries where id = req->>'id');
  elsif action in ('updateEmployee','linkEmployee','archiveEmployee','restoreEmployee','deleteEmployee') then
    if not exists(select 1 from ebda.employees where id = req->>'id') then return false; end if;
    tgt := tgt || (select school_id from ebda.employees where id = req->>'id');
  elsif action in ('updatePayslip','deletePayslip') then
    if not exists(select 1 from ebda.payslips where id = req->>'id') then return false; end if;
    tgt := tgt || (select school_id from ebda.payslips where id = req->>'id');
  end if;
  if action in ('updateSalary','deleteSalary') and cardinality(tgt) = 0 then return false; end if;
  tgt := tgt || array_remove(array[req#>>'{salary,school_id}', req#>>'{emp,school_id}', req#>>'{slip,school_id}', req#>>'{patch,school_id}',
                                   case when action in ('importSalaries','importEmployees') then coalesce(req->>'school_id','') end], null);
  if action = 'addPayslipsBatch' then
    tgt := tgt || array(select coalesce(x->>'school_id','') from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) x);
  end if;
  if action in ('addSalary','addEmployee','addPayslip','importSalaries','importEmployees') and cardinality(tgt) = 0 then return false; end if;
  foreach s in array tgt loop
    if s is null or s = '' or not ebda.can_school(u, s) then return false; end if;
  end loop;
  return true;
end $ps$;

-- استيراد العهد (ورقة «عهد») لمسئول العهدة: العهدة باسمه هو فقط وتُرسل للاعتماد (لا اعتماد ذاتى)
-- (تُعاد كتابة import_custodies من 006 بإضافة هذا الفرع فقط — انظر gen_009.py)


-- ============================================================================
--  10) v10.2: المدير المالى — رؤية الأدمن الكاملة (كل الجهات · كل الشاشات · كل التقارير · سجل التعديلات) للعرض فقط،
--      والتنفيذ بصلاحيات دوره فقط (الاعتماد المالى · الإعادة للاستكمال · التسوية · ...) — الفصل مطبق فى الخادم:
--      إجراءات القراءة وحدها تُنفَّذ بنطاق الأدمن؛ أى إجراء آخر يُنفَّذ بالمستخدم الحقيقى وصلاحياته.
-- ============================================================================
create or replace function ebda.fin_view_action(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'approvalsReport','purgeLog') $$;

create or replace function ebda.me_json(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select jsonb_build_object('id',u.id,'username',u.username,'name',u.name,'role',coalesce(ebda.role_legacy(u.role),u.role),
            'role_key',ebda.rk(u),'role_label',ebda.role_label(u.role),'schools',u.schools,'perms',coalesce(u.perms,''),
            'must_reset',coalesce(u.must_reset,'لا'),'permissions',to_jsonb(ebda.perms_of(u)),'manager_id',coalesce(u.manager_id,''),
            'view_all', ebda.rk(u) = 'finance_manager') $$;

-- لوحة البداية للمدير المالى: بيانات الأدمن كاملة + هويته وصلاحياته الحقيقية (الأزرار التنفيذية تتبع صلاحياته فقط)
create or replace function ebda.fin_view(b jsonb, u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select case when b ? 'me' then jsonb_set(
           case when 'audit.view' = any(ebda.perms_of(u)) then b else b - 'audit' - 'audit_changes' - 'backups' end,
           '{me}', ebda.me_json(u)) else b end $$;


-- ============================================================================
--  11) v10.3: جدول بشكل الملف المرجعى («مصاريف …» و«احتياجات شهرية …») + اعتماد المدير العام والمدير المالى وملاحظاتهما داخل الجدول
--      + المصروفات السابقة لرفع الموازنات (سبتمبر) تُسند لبنودها الصحيحة بتاريخها الأصلى داخل السنة المالية 1/7 ← 30/6
-- ============================================================================
alter table ebda.expenses add column if not exists fin_sign text default '';        -- اعتماد المدير المالى (علامة الجدول)
alter table ebda.expenses add column if not exists fin_sign_note text default '';
alter table ebda.expenses add column if not exists fin_sign_by text default '';
alter table ebda.expenses add column if not exists fin_sign_at text default '';
alter table ebda.expenses add column if not exists file_gm_ok text default '';      -- علامة صح فى الملف (معلومة فقط — ليست اعتماداً)
alter table ebda.expenses add column if not exists file_fin_ok text default '';
alter table ebda.expenses add column if not exists file_gm_note text default '';
alter table ebda.request_items add column if not exists gm_approval text default '';
alter table ebda.request_items add column if not exists gm_by text default '';
alter table ebda.request_items add column if not exists gm_at text default '';
alter table ebda.request_items add column if not exists fin_note text default '';
alter table ebda.request_items add column if not exists file_fin_ok text default '';
alter table ebda.request_items add column if not exists file_settle text default '';
alter table ebda.request_items add column if not exists file_gm_note text default '';
alter table ebda.request_items add column if not exists src_line text default '';     -- نوع المصروف كما فى الملف (لا يضيع حتى لو لم يُربط ببند)
insert into ebda.config(key, value) values ('budget_upload_date', '2026-09-01') on conflict (key) do nothing;

-- من يعتمد: المدير العام = الأدمن أو منح صريح gm.approve · المدير المالى = صلاحية fin.signoff (افتراضية للمدير المالى، وبمنح صريح لغيره)
-- لا يغيّر أحدهما اعتماد الآخر (الأدمن لا يملك fin.signoff إلا بمنح صريح)
create or replace function ebda.can_gm(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and 'gm.approve' = any(ebda.perms_of(u))) $$;
create or replace function ebda.can_fin_sign(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) <> 'observer' and 'fin.signoff' = any(ebda.perms_of(u)) $$;
create table if not exists ebda.item_decisions(
  id text primary key, kind text not null, item_id text not null, signer text not null,
  decision text default '', note text default '', prev_decision text default '', prev_note text default '',
  by_name text default '', by_id text default '', by_role text default '', at text default '');
create index if not exists item_decisions_item on ebda.item_decisions(kind, item_id, at);
insert into ebda.config(key, value) values ('require_doc_fin_sign', 'yes') on conflict (key) do nothing;

select 'الجزء 10 من 15 تم ✓ — شغّل الجزء 11' as result;
