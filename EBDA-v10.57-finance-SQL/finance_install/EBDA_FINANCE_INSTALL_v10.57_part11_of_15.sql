-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 11 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;
select set_config('ebda.fy_override', '1', false);

-- حالة البند + الإجراء المطلوب + المسئول عنه (لكل بند على حدة)
create or replace function ebda.sign_info(gm text, fin text, has_doc boolean) returns jsonb language sql stable as $$
  select case
    when coalesce(gm,'') = 'approved' and coalesce(fin,'') = 'approved' then jsonb_build_object('state','معتمد نهائيًا','action','لا يوجد','owner','—','code','done')
    when coalesce(gm,'') = 'rejected' then jsonb_build_object('state','مرفوض من المدير العام','action','لا يُعتمد — راجع سبب الرفض','owner','—','code','gm_rejected')
    when coalesce(gm,'') = 'returned' then jsonb_build_object('state','معاد للتعديل من المدير العام','action','تعديل البند وفق الملاحظات ثم إعادة المراجعة','owner','مسئول العهدة','code','gm_returned')
    when coalesce(gm,'') <> 'approved' then jsonb_build_object('state','بانتظار مراجعة المدير العام','action','مراجعة البند ومستنداته والموافقة/الرفض/الإعادة','owner','المدير العام','code','gm_pending')
    when coalesce(fin,'') = 'rejected' then jsonb_build_object('state','تسوية مرفوضة من المدير المالى','action','لا تُعتمد التسوية — راجع السبب','owner','—','code','fin_rejected')
    when coalesce(fin,'') = 'returned' then jsonb_build_object('state','معاد للاستكمال من المدير المالى','action','استكمال البيانات/المستندات المطلوبة','owner','مسئول العهدة','code','fin_returned')
    when not coalesce(has_doc, true) and coalesce((select value from ebda.config where key = 'require_doc_fin_sign'),'yes') = 'yes'
      then jsonb_build_object('state','بانتظار المستندات قبل التسوية','action','إرفاق المستند/الفاتورة بالبند','owner','مسئول العهدة','code','need_doc')
    else jsonb_build_object('state','بانتظار اعتماد التسوية من المدير المالى','action','مراجعة البند والمستندات واعتماد التسوية/رفضها/إعادتها','owner','المدير المالى','code','fin_pending') end $$;
create or replace function ebda.sign_state(gm text, fin text) returns text language sql stable as $$ select ebda.sign_info(gm, fin, true)->>'state' $$;

-- قرار لكل بند على حدة: المدير العام (موافقة/رفض/إعادة للتعديل) ثم المدير المالى (اعتماد التسوية/رفضها/إعادتها للاستكمال)
-- • الرفض والإعادة بسبب إلزامى • المدير المالى بعد موافقة المدير العام فقط، ومع وجود المستند الإلزامى للمصروف
-- • لا يغيّر أحدهما قرار الآخر • تغيير قرار المدير العام بعد اعتماد التسوية يُلغى اعتماد التسوية (يُعاد للمدير المالى) • كل قرار يُحفظ فى سجل البند ولا يُحذف
create or replace function ebda.sign_off(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $so$
declare kind text := coalesce(req->>'kind','expenses'); who text := coalesce(req->>'signer','');
  ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb)));
  dec text; has_note boolean := req ? 'note' and jsonb_typeof(req->'note') = 'string'; nt text := left(btrim(coalesce(req->>'note','')), 2000);
  n int := 0; bad int; id_ text; e ebda.expenses; it ebda.request_items; cur_d text; cur_n text; gm_d text; doc_ok boolean; skip jsonb := '[]'::jsonb; ovr boolean := false;
begin
  -- القرار: decision صريح، أو approved=true/false (توافق مع الإصدار السابق)
  dec := case when req ? 'decision' then coalesce(req->>'decision','')
              when req ? 'approved' and jsonb_typeof(req->'approved') = 'boolean' then case when (req->>'approved')::boolean then 'approved' else '' end
              else null end;
  if who = 'gm' then
    if not ebda.can_gm(u) then return ebda.err('قرار المدير العام وملاحظاته للمدير العام فقط (أو بمنح صريح)'); end if;
  elsif who = 'fin' then
    if not ebda.can_fin_sign(u) then return ebda.err('اعتماد التسوية وملاحظاتها للمدير المالى فقط (أو بمنح صريح)'); end if;
    -- تجاوز مرحلة المدير العام: بمنح صريح «approval.override» فقط وبسبب مكتوب (يُسجل فى سجل البند)
    if coalesce(req->>'override','') in ('true','1') then
      if not ('approval.override' = any(ebda.perms_of(u))) then return ebda.err('تجاوز مراحل الاعتماد يحتاج صلاحية إدارية صريحة «approval.override»'); end if;
      if length(btrim(coalesce(req->>'override_reason',''))) < 5 then return ebda.err('اكتب سبب تجاوز مرحلة المدير العام'); end if;
      ovr := true;
    end if;
  else return ebda.err('حدد نوع الاعتماد'); end if;
  if dec is null and not has_note then return ebda.err('لا يوجد تغيير'); end if;
  if dec is not null and dec not in ('approved','rejected','returned','') then return ebda.err('قرار غير صحيح'); end if;
  if dec in ('rejected','returned') and length(nt) < 3 then
    return ebda.err(case when dec = 'rejected' then 'اكتب سبب الرفض' else 'اكتب المطلوب تعديله/استكماله' end); end if;
  if coalesce(cardinality(ids),0) = 0 then return ebda.err('لم يتم تحديد أى بند'); end if;
  if cardinality(ids) > 500 then return ebda.err('500 بند كحد أقصى'); end if;
  if kind = 'expenses' then
    select count(*) into bad from ebda.expenses x where x.id = any(ids) and (coalesce(x.cancelled_at,'') <> '' or not ebda.can_school(u, x.school_id));
    if bad > 0 or (select count(*) from ebda.expenses x where x.id = any(ids)) <> cardinality(ids) then return ebda.err('بند غير موجود أو ملغى أو خارج نطاقك'); end if;
  elsif kind = 'needs' then
    select count(*) into bad from ebda.request_items x join ebda.requests r on r.id = x.request_id
      where x.id = any(ids) and (coalesce(r.status,'') = 'cancelled' or coalesce(x.decision,'') = 'cancelled' or not ebda.can_school(u, r.school_id));
    if bad > 0 or (select count(*) from ebda.request_items x where x.id = any(ids)) <> cardinality(ids) then return ebda.err('بند غير موجود أو ملغى أو خارج نطاقك'); end if;
  else return ebda.err('نوع غير معروف'); end if;

  foreach id_ in array ids loop
    if kind = 'expenses' then
      select * into e from ebda.expenses where id = id_ for update;
      gm_d := coalesce(e.gm_approval,''); doc_ok := coalesce(e.doc_url,'') <> '';
      cur_d := case when who = 'gm' then gm_d else coalesce(e.fin_sign,'') end;
      cur_n := case when who = 'gm' then coalesce(e.gm_note,'') else coalesce(e.fin_sign_note,'') end;
    else
      select * into it from ebda.request_items where id = id_ for update;
      gm_d := coalesce(it.gm_approval,''); doc_ok := true;
      cur_d := case when who = 'gm' then gm_d else coalesce(it.fin_approval,'') end;
      cur_n := case when who = 'gm' then coalesce(it.gm_note,'') else coalesce(it.fin_note,'') end;
    end if;
    -- منع تجاوز المراحل
    if who = 'fin' and dec is not null and dec <> '' and gm_d <> 'approved' and coalesce(req->>'override','') in ('true','1') and ovr then
      null;   -- تجاوز إدارى مسجل بسببه
    elsif who = 'fin' and dec is not null and dec <> '' and gm_d <> 'approved' then
      skip := skip || jsonb_build_object('id', id_, 'reason', 'لا يُتخذ قرار التسوية قبل موافقة المدير العام على البند'); continue; end if;
    if who = 'fin' and dec = 'approved' and not doc_ok and coalesce((select value from ebda.config where key = 'require_doc_fin_sign'),'yes') = 'yes' then
      skip := skip || jsonb_build_object('id', id_, 'reason', 'لا تُعتمد التسوية بدون المستند/الفاتورة المرفقة بالبند — أرفقه أو أعد البند للاستكمال'); continue; end if;
    if kind = 'expenses' then
      if who = 'gm' then
        update ebda.expenses set gm_approval = coalesce(dec, gm_approval), gm_note = case when has_note then nt else gm_note end, gm_by = u.name, gm_at = now()::text,
          fin_sign = case when dec is not null and dec <> 'approved' and coalesce(fin_sign,'') <> '' then '' else fin_sign end where id = id_;
        if dec is not null and dec <> 'approved' and coalesce(e.fin_sign,'') <> '' then
          insert into ebda.item_decisions values(ebda.uid(), kind, id_, 'fin', '', 'أُلغى قرار التسوية تلقائياً لتغيير قرار المدير العام', e.fin_sign, coalesce(e.fin_sign_note,''), u.name, u.id, ebda.rk(u), now()::text);
        end if;
      else
        update ebda.expenses set fin_sign = coalesce(dec, fin_sign), fin_sign_note = case when has_note then nt else fin_sign_note end, fin_sign_by = u.name, fin_sign_at = now()::text where id = id_;
      end if;
    else
      if who = 'gm' then
        update ebda.request_items set gm_approval = coalesce(dec, gm_approval), gm_note = case when has_note then nt else gm_note end, gm_by = u.name, gm_at = now()::text,
          fin_approval = case when dec is not null and dec <> 'approved' and coalesce(fin_approval,'') <> '' then '' else fin_approval end where id = id_;
        if dec is not null and dec <> 'approved' and coalesce(it.fin_approval,'') <> '' then
          insert into ebda.item_decisions values(ebda.uid(), kind, id_, 'fin', '', 'أُلغى قرار التسوية تلقائياً لتغيير قرار المدير العام', it.fin_approval, coalesce(it.fin_note,''), u.name, u.id, ebda.rk(u), now()::text);
        end if;
      else
        update ebda.request_items set fin_approval = coalesce(dec, fin_approval), fin_note = case when has_note then nt else fin_note end, fin_by = u.name, fin_at = now()::text where id = id_;
      end if;
    end if;
    insert into ebda.item_decisions values(ebda.uid(), kind, id_, who, coalesce(dec, cur_d),
      case when ovr and gm_d <> 'approved' then 'تجاوز إدارى لمرحلة المدير العام — السبب: ' || btrim(req->>'override_reason') || case when has_note and nt <> '' then ' · ' || nt else '' end
           when has_note then nt else cur_n end, cur_d, cur_n, u.name, u.id, ebda.rk(u) || case when ovr and gm_d <> 'approved' then ' (تجاوز)' else '' end, now()::text);
    n := n + 1;
  end loop;
  if n = 0 and jsonb_array_length(skip) > 0 then return ebda.err(skip->0->>'reason'); end if;
  return jsonb_build_object('ok', true, 'updated', n, 'skipped', skip);
end $so$;

-- سجل قرارات البند (لا يُحذف)
create or replace function ebda.item_history(u ebda.users, p_kind text, id_ text) returns jsonb language plpgsql stable security definer set search_path = ebda as $ih$
declare sid text;
begin
  if p_kind = 'expenses' then select school_id into sid from ebda.expenses where id = id_;
    if not exists(select 1 from ebda.vis_expenses(u) e where e.id = id_) then return ebda.err('لا صلاحية على هذا البند'); end if;
  else select r.school_id into sid from ebda.request_items it join ebda.requests r on r.id = it.request_id where it.id = id_;
    if not exists(select 1 from ebda.request_items it join ebda.requests r on r.id = it.request_id where it.id = id_ and ebda.can_request(u, r)) then return ebda.err('لا صلاحية على هذا البند'); end if;
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((select jsonb_agg(jsonb_build_object('signer', d.signer, 'decision', d.decision, 'note', d.note, 'prev_decision', d.prev_decision,
      'prev_note', d.prev_note, 'by', d.by_name, 'role', d.by_role, 'at', d.at) order by d.at) from ebda.item_decisions d where d.kind = p_kind and d.item_id = id_), '[]'::jsonb));
end $ih$;

-- القوائم المرجعية من ورقة SOURCE (أنواع المصروف · الجهات الطالبة · الأولويات · مسئولو العهد · حالة المخزن · نتيجة المراجعة · قرارات الاعتماد)
insert into ebda.config(key, value) values ('source_lists', '{}') on conflict (key) do nothing;

-- جدول مصروفات العهد بشكل الملف: م · التاريخ · البند (الوصف) · مسئول العهدة · الوصف المقترح (بند الموازنة) · مصاريف OUT · الرصيد · مستند
--   · مراجعة المدير العام · ملاحظاته · اعتماد المدير المالى · ملاحظاته · الحالة — صفوف الاستلام (دفعات العهدة) تزيد الرصيد كما فى الملف
create or replace function ebda.custody_ledger(u ebda.users, f jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $cl$
declare sid text := coalesce(f->>'school_id',''); cid text := coalesce(f->>'custody_id',''); bid text := coalesce(f->>'batch_id','');
  d1 text := coalesce(nullif(f->>'date_from',''), '0000-01-01'); d2 text := coalesce(nullif(f->>'date_to',''), '9999-12-31'); st text := coalesce(f->>'state','');
  res jsonb;
begin
  with ex as (select e.* from ebda.vis_expenses(u) e where coalesce(e.cancelled_at,'') = '' and ebda.active_on_custody(e)
                and (sid = '' or e.school_id = sid) and (cid = '' or e.custody_id = cid) and (bid = '' or e.import_batch = bid)),
  cs as (select c.* from ebda.custodies c where c.id in (select distinct custody_id from ex where custody_id is not null)
           or (bid = '' and (cid <> '' and c.id = cid))),
  mv as (
    select c.id cust, 'in' k, t.id, coalesce(nullif(t.date,''), substr(c.opened_at,1,10)) dt, t.amount amt, null::ebda.expenses e,
           coalesce(nullif(t.note,''), 'استلام مبلغ ' || t.amount || ' على العهدة') txt, t.id ord2
      from cs c join ebda.tranches t on t.custody_id = c.id where bid = ''
    union all
    select e.custody_id, 'out', e.id, e.date, e.amount, e::ebda.expenses, coalesce(e.description,''), coalesce(e.txn_no, e.id) from ex e),
  run as (select m.*, sum(case when k = 'in' then amt else -amt end) over (partition by cust order by case when k = 'in' and txt like 'القيمة الأساسية%' then 0 else 1 end, dt, case when k = 'in' then 0 else 1 end, ord2 rows unbounded preceding) bal,
                 row_number() over (partition by cust, k order by dt, ord2) seq from mv m)
  select jsonb_build_object('ok', true,
    'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u),
    'custodies', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'code', c.code, 'school_id', c.school_id, 'school', (select name from ebda.schools where id = c.school_id),
        'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), 'name', ebda.custody_name(c.title, c.label, c.code),
        'doc_folder', coalesce(c.doc_folder,''), 'overrun', ebda.custody_overrun(c.id),
        'received', (select coalesce(sum(amount),0) from ebda.tranches t where t.custody_id = c.id),
        'spent', (select coalesce(sum(e.amount),0) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e)),
        'rows', coalesce((select jsonb_agg(jsonb_build_object('k', r.k, 'id', r.id, 'seq', case when r.k = 'out' then r.seq end, 'date', r.dt, 'item', r.txt,
              'line', case when r.k = 'out' then coalesce((select name from ebda.lines where id = (r.e).line_id), '') else 'عهدة' end,
              'line_id', (r.e).line_id, 'out', case when r.k = 'out' then r.amt end, 'in', case when r.k = 'in' then r.amt end, 'balance', r.bal,
              'doc_url', case when r.k = 'out' then case when coalesce((r.e).doc_url,'') like 'data:%' then 'inline:' else coalesce((r.e).doc_url,'') end end, 'doc_name', (r.e).doc_name,
              'doc_file', coalesce((r.e).note,'') like '%مستند: نعم%',
              'suggested', (r.e).src_suggested, 'doc_ref', coalesce((r.e).doc_ref,''), 'docs_n', case when r.k = 'out' then (select count(*) from ebda.expense_docs d where d.expense_id = r.id) else 0 end,
              'doc_type', (r.e).doc_type, 'doc_no', (r.e).doc_no, 'txn_no', (r.e).txn_no,
              'gm', (r.e).gm_approval, 'gm_note', (r.e).gm_note, 'gm_by', (r.e).gm_by, 'gm_at', (r.e).gm_at,
              'fin', (r.e).fin_sign, 'fin_note', (r.e).fin_sign_note, 'fin_by', (r.e).fin_sign_by, 'fin_at', (r.e).fin_sign_at,
              'file_gm', (r.e).file_gm_ok, 'file_fin', (r.e).file_fin_ok, 'file_gm_note', (r.e).file_gm_note,
              'state', case when r.k = 'out' then ebda.sign_info((r.e).gm_approval, (r.e).fin_sign, coalesce((r.e).doc_url,'') <> '')->>'state' end, 'stage', case when r.k = 'out' then ebda.expense_stage(r.e) end,
              'info', case when r.k = 'out' then ebda.sign_info((r.e).gm_approval, (r.e).fin_sign, coalesce((r.e).doc_url,'') <> '') end,
              'counted', case when r.k = 'out' then ebda.counts_in_budget(r.e) end)
            order by case when r.k = 'in' and r.txt like 'القيمة الأساسية%' then 0 else 1 end, r.dt, case when r.k = 'in' then 0 else 1 end, r.ord2)
            from run r where r.cust = c.id and r.dt between d1 and d2
              and (st = '' or (r.k = 'out' and ebda.sign_info((r.e).gm_approval, (r.e).fin_sign, coalesce((r.e).doc_url,'') <> '')->>'state' = st))), '[]'::jsonb))
        order by (select name from ebda.schools where id = c.school_id), c.code) from cs c), '[]'::jsonb)) into res;
  return res;
end $cl$;

-- جدول الاحتياجات بشكل الملف «احتياجات شهرية …» + اعتماد المدير العام/المالى وملاحظاتهما
create or replace function ebda.needs_table(u ebda.users, f jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $nt$
declare sid text := coalesce(f->>'school_id',''); bid text := coalesce(f->>'batch_id','');
  d1 text := coalesce(nullif(f->>'date_from',''), '0000-01-01'); d2 text := coalesce(nullif(f->>'date_to',''), '9999-12-31'); st text := coalesce(f->>'state','');
  res jsonb;
begin
  with rq as (select r.* from ebda.requests r where ebda.can_request(u, r) and coalesce(r.status,'') not in ('cancelled')
                and (sid = '' or r.school_id = sid) and (bid = '' or r.import_batch = bid)
                and coalesce(nullif(r.request_date,''), substr(r.created_at,1,10)) between d1 and d2),
  it as (select it.*, r.req_no, r.school_id, r.status rstatus, coalesce(nullif(r.request_date,''), substr(r.created_at,1,10)) rdate, r.reason, r.priority, r.settlement,
                r.description rdesc, r.requester_name, r.created_at rc, r.request_date rq_date
           from ebda.request_items it join rq r on r.id = it.request_id where coalesce(it.decision,'') <> 'cancelled'
             and (st = '' or ebda.sign_state(it.gm_approval, it.fin_approval) = st))
  select jsonb_build_object('ok', true, 'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', it.id, 'request_id', it.request_id, 'req_no', it.req_no, 'school_id', it.school_id,
        'school', (select name from ebda.schools where id = it.school_id), 'name', it.name, 'unit', it.unit, 'qty', it.qty, 'unit_price', it.unit_price, 'total', it.amount,
        'line', coalesce((select name from ebda.lines where id = it.line_id), ''), 'line_id', it.line_id, 'src_line', it.src_line, 'dept', it.dept,
        'date', case when it.rdate = substr(coalesce(it.rc,''),1,10) and coalesce(it.rq_date,'') = '' then '' else it.rdate end, 'reason', it.reason,
        'description', coalesce(nullif(it.item_note,''), it.rdesc, ''), 'priority', it.priority, 'stock_check', it.stock_check, 'stock_result', it.stock_result,
        'decision', it.decision, 'decision_note', it.sup_note, 'decision_date', it.decision_date, 'settlement', coalesce(it.settlement,''), 'file_settle', it.file_settle,
        'gm', it.gm_approval, 'gm_note', it.gm_note, 'gm_by', it.gm_by, 'gm_at', it.gm_at, 'file_gm_note', it.file_gm_note,
        'fin', it.fin_approval, 'fin_note', it.fin_note, 'fin_by', it.fin_by, 'fin_at', it.fin_at, 'file_fin', it.file_fin_ok,
        'state', ebda.sign_state(it.gm_approval, it.fin_approval), 'info', ebda.sign_info(it.gm_approval, it.fin_approval, true), 'request_status', it.rstatus, 'requester', it.requester_name)
      order by (select name from ebda.schools where id = it.school_id), it.rdate, it.req_no, it.sort) from it), '[]'::jsonb)) into res;
  return res;
end $nt$;

-- المصروفات السابقة لرفع الموازنات: كل مصروف قائم داخل السنة المالية قبل تاريخ رفع الموازنات (افتراضياً 1/9/2026)،
-- مع بنده الحالى واقتراح البند الصحيح (القائمة الموحدة/المرادفات/الاسم)، وهل يُحتسب فى الاستهلاك التراكمى — بدون أى تغيير للتاريخ
create or replace function ebda.prior_expenses(u ebda.users, f jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $pe$
declare sid text := coalesce(f->>'school_id',''); cut text := coalesce(nullif(f->>'before',''), (select value from ebda.config where key = 'budget_upload_date'), '2026-09-01');
  fy0 date; fy1 date; res jsonb;
begin
  select start_date, end_date into fy0, fy1 from ebda.fiscal_years where coalesce(is_current,'') like '%نعم%' order by start_date desc limit 1;
  if fy0 is null then fy0 := ebda.fy_start_for(cut); fy1 := (fy0 + interval '12 months')::date - 1; end if;
  with ex as (select e.* from ebda.vis_expenses(u) e where coalesce(e.cancelled_at,'') = '' and ebda.active_on_custody(e) and (sid = '' or e.school_id = sid)
                and (e.date < cut or e.line_id is null or not exists(select 1 from ebda.lines l where l.id = e.line_id and l.school_id = e.school_id and coalesce(l.deleted_at,'') = ''))),
  rows_ as (select e.*, ebda.counts_in_budget(e::ebda.expenses) cnt, ebda.expense_stage(e::ebda.expenses) stg, l.name lname, (l.id is not null and l.school_id = e.school_id and coalesce(l.deleted_at,'') = '') line_ok,
                   ebda.match_school_line(e.school_id, coalesce(nullif(e.spend_item,''), e.description)) sug,
                   case when e.date < fy0::text then 'other_fy' when e.date > fy1::text then 'other_fy' else 'this_fy' end fyk
              from ex e left join ebda.lines l on l.id = e.line_id)
  select jsonb_build_object('ok', true, 'fy_start', fy0::text, 'fy_end', fy1::text, 'before', cut,
    'summary', jsonb_build_object(
      'n', (select count(*) from rows_), 'amount', coalesce((select sum(amount) from rows_),0),
      'this_fy_n', (select count(*) from rows_ where fyk = 'this_fy'), 'this_fy_amount', coalesce((select sum(amount) from rows_ where fyk = 'this_fy'),0),
      'counted_amount', coalesce((select sum(amount) from rows_ where fyk = 'this_fy' and line_ok and cnt),0),
      'unlinked_n', (select count(*) from rows_ where not line_ok), 'other_fy_n', (select count(*) from rows_ where fyk = 'other_fy'),
      'other_fy_amount', coalesce((select sum(amount) from rows_ where fyk = 'other_fy'),0)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'txn_no', r.txn_no, 'date', r.date, 'school_id', r.school_id, 'school', (select name from ebda.schools where id = r.school_id),
        'description', r.description, 'amount', r.amount, 'line_id', case when r.line_ok then r.line_id end, 'line', case when r.line_ok then r.lname else '' end,
        'suggest_id', r.sug->>'line_id', 'suggest', coalesce(r.sug->>'line',''), 'how', r.sug->>'how', 'fy', r.fyk,
        'counted', r.fyk = 'this_fy' and r.line_ok and r.cnt, 'stage', r.stg,
        'holder', (select ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) from ebda.custodies c where c.id = r.custody_id))
      order by r.school_id, r.date, r.txn_no) from rows_ r), '[]'::jsonb)) into res;
  return res;
end $pe$;

-- إسناد المصروفات لبنودها الصحيحة (الأدمن): البند فقط يتغير — التاريخ والمبلغ والمستندات والجهة والمسئول كما هى · معاينة ثم تنفيذ
create or replace function ebda.relink_expenses(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $rl$
declare commit_ boolean := coalesce(req->>'mode','preview') = 'commit'; x jsonb; e ebda.expenses; l ebda.lines; ok_ jsonb := '[]'::jsonb; skip jsonb := '[]'::jsonb; n int := 0;
begin
  if ebda.rk(u) <> 'admin' and not ebda.can(u,'budget.edit') then return ebda.err('إسناد المصروفات للبنود للأدمن (أو بصلاحية تعديل الموازنة الممنوحة صراحةً)'); end if;
  if jsonb_typeof(coalesce(req->'map','null'::jsonb)) <> 'array' or jsonb_array_length(req->'map') = 0 then return ebda.err('لا توجد مصروفات محددة'); end if;
  if commit_ and length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الإسناد'); end if;
  for x in select * from jsonb_array_elements(req->'map') loop
    select * into e from ebda.expenses where id = x->>'id';
    if e.id is null or coalesce(e.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', x->>'id', 'reason', 'غير موجود أو ملغى'); continue; end if;
    if not ebda.can_school(u, e.school_id) then skip := skip || jsonb_build_object('id', e.id, 'reason', 'خارج نطاقك'); continue; end if;
    select * into l from ebda.lines where id = x->>'line_id';
    if l.id is null or l.school_id is distinct from e.school_id or coalesce(l.deleted_at,'') <> '' then
      skip := skip || jsonb_build_object('id', e.id, 'txn_no', e.txn_no, 'reason', 'البند ليس من موازنة نفس الجهة'); continue; end if;
    if e.line_id = l.id then skip := skip || jsonb_build_object('id', e.id, 'txn_no', e.txn_no, 'reason', 'مربوط بالفعل بنفس البند'); continue; end if;
    ok_ := ok_ || jsonb_build_object('id', e.id, 'txn_no', e.txn_no, 'date', e.date, 'amount', e.amount,
      'from', coalesce((select name from ebda.lines where id = e.line_id), ''), 'to', l.name, 'from_id', e.line_id, 'to_id', l.id);
    if commit_ then
      update ebda.expenses set line_id = l.id, updated_by = u.name, updated_at = now()::text,
        note = concat_ws(' · ', nullif(note,''), 'أُسند للبند «' || l.name || '» (' || btrim(req->>'reason') || ')') where id = e.id;
      n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'rows', ok_, 'skipped', skip, 'updated', n);
end $rl$;

-- القراءة لنفس فئة المتابع/المدير المالى (عرض فقط)
create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'custodyLedger','needsTable','priorExpenses','approvalsReport','itemHistory','reviewList','itemDetail','expenseDocs','archivedDoc') $$;
create or replace function ebda.fin_view_action(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'approvalsReport','purgeLog','priorExpenses') $$;

-- ============================================================================
--  13) v10.5: الالتزام الحرفى بأعمدة ملف Excel + شاشة «مراجعة البنود» (مؤشرات · بحث · فلاتر · تفاصيل · قرار لكل بند)
--      • كل صف مستورد يحتفظ بعناوين الملف وقيمه بترتيبها (src_row) — «البند» و«الوصف المقترح» و«مسئول العهدة» و«الرصيد» و«مستند» كما هى
--      • «تصنيف بند الصرف» حقل مستقل لا يُستنتج آلياً — يُنقل من الملف إن وُجد عموده، وإلا يُحدده المصرح له صراحةً (مع سجل)
--      • تجاوز مرحلة اعتماد: للأدمن بمنح صريح «approval.override» فقط، وبسبب مكتوب يُسجل فى سجل البند
-- ============================================================================
alter table ebda.expenses add column if not exists src_item text default '';        -- «البند» كما فى الملف
alter table ebda.expenses add column if not exists src_suggested text default '';   -- «الوصف المقترح» كما فى الملف
alter table ebda.expenses add column if not exists src_holder text default '';      -- «مسئول العهدة» كما فى الملف
alter table ebda.expenses add column if not exists src_seq text default '';         -- «م»
alter table ebda.expenses add column if not exists src_balance text default '';     -- «الرصيد» كما حسبه الملف (للمقارنة)
alter table ebda.expenses add column if not exists src_doc text default '';         -- «مستند» كما فى الملف
alter table ebda.expenses add column if not exists src_sheet text default '';
alter table ebda.expenses add column if not exists src_row jsonb;                   -- {"h":[عناوين الملف], "v":[القيم]} بنفس الترتيب
alter table ebda.expenses add column if not exists category text default '';       -- تصنيف بند الصرف (حقل مستقل)
alter table ebda.request_items add column if not exists src_row jsonb;
alter table ebda.request_items add column if not exists category text default '';

-- الحالة بالمسميات المعتمدة (مسودة · فى انتظار المراجعة · فى انتظار الاعتماد المالى · يحتاج إلى تعديل · معتمد · مرفوض)
create or replace function ebda.review_bucket(draft boolean, gm text, fin text) returns text language sql immutable as $$
  select case when draft then 'draft'
              when coalesce(gm,'') = 'rejected' or coalesce(fin,'') = 'rejected' then 'rejected'
              when coalesce(gm,'') = 'returned' or coalesce(fin,'') = 'returned' then 'needs_edit'
              when coalesce(gm,'') = 'approved' and coalesce(fin,'') = 'approved' then 'approved'
              when coalesce(gm,'') = 'approved' then 'fin_pending'
              else 'gm_pending' end $$;

create or replace function ebda.review_list(u ebda.users, kind text, f jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $rv$
declare sid text := coalesce(f->>'school_id',''); d1 text := coalesce(nullif(f->>'date_from',''), '0000-01-01'); d2 text := coalesce(nullif(f->>'date_to',''), '9999-12-31');
  lid text := coalesce(f->>'line_id',''); cat text := coalesce(f->>'category',''); hold text := coalesce(f->>'holder',''); f_dept text := coalesce(f->>'dept','');
  bk text := coalesce(f->>'bucket',''); qq text := ebda.norm_txt(coalesce(f->>'q','')); bid text := coalesce(f->>'batch_id','');
  lim int := least(greatest(coalesce(nullif(f->>'limit','')::int, 100), 1), 500); off int := greatest(coalesce(nullif(f->>'offset','')::int, 0), 0); res jsonb;
begin
  if kind = 'expenses' then
    with x as (
      select e.id, e.txn_no, e.date, e.school_id, (select name from ebda.schools where id = e.school_id) school, e.amount,
             coalesce(nullif(e.src_item,''), e.description, '') item, e.src_suggested, coalesce(e.category,'') category, e.line_id,
             coalesce((select name from ebda.lines where id = e.line_id),'') line, coalesce((select section from ebda.lines where id = e.line_id),'') line_section,
             coalesce(nullif(e.src_holder,''), (select ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) from ebda.custodies c where c.id = e.custody_id), '') holder,
             e.gm_approval gm, e.gm_note, e.fin_sign fin, e.fin_sign_note fin_note, coalesce(e.doc_url,'') <> '' has_doc, e.import_batch, e.description,
             ebda.review_bucket(coalesce(e.approval,'') = 'draft', e.gm_approval, e.fin_sign) bucket,
             ebda.sign_info(e.gm_approval, e.fin_sign, coalesce(e.doc_url,'') <> '') info
        from ebda.vis_expenses(u) e
       where coalesce(e.cancelled_at,'') = '' and coalesce(e.approval,'') <> 'rejected'
         and (sid = '' or e.school_id = sid) and e.date between d1 and d2 and (lid = '' or e.line_id = lid) and (bid = '' or e.import_batch = bid)),
    y as (select * from x where (cat = '' or category = cat) and (hold = '' or ebda.norm_txt(holder) = ebda.norm_txt(hold))
            and (qq = '' or ebda.norm_txt(item || ' ' || coalesce(src_suggested,'') || ' ' || coalesce(description,'') || ' ' || coalesce(txn_no,'') || ' ' || line) like '%' || qq || '%'))
    select jsonb_build_object('ok', true, 'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u),
      'kpis', (select jsonb_build_object('all', count(*), 'draft', count(*) filter (where bucket = 'draft'), 'gm_pending', count(*) filter (where bucket = 'gm_pending'),
                 'fin_pending', count(*) filter (where bucket = 'fin_pending'), 'needs_edit', count(*) filter (where bucket = 'needs_edit'),
                 'approved', count(*) filter (where bucket = 'approved'), 'rejected', count(*) filter (where bucket = 'rejected'), 'amount', coalesce(sum(amount),0)) from y),
      'total', (select count(*) from y where bk = '' or bucket = bk),
      'categories', coalesce((select jsonb_agg(distinct category) from x where category <> ''), '[]'::jsonb),
      'holders', coalesce((select jsonb_agg(distinct holder) from x where holder <> ''), '[]'::jsonb),
      'rows', coalesce((select jsonb_agg(to_jsonb(z) - 'description') from (select * from y where bk = '' or bucket = bk order by date desc, txn_no desc limit lim offset off) z), '[]'::jsonb))
    into res;
  else
    with x as (
      select it.id, r.req_no txn_no, coalesce(nullif(r.request_date,''), substr(r.created_at,1,10)) date, r.school_id, (select name from ebda.schools where id = r.school_id) school,
             it.amount, it.name item, it.src_line src_suggested, coalesce(it.category,'') category, it.line_id,
             coalesce((select name from ebda.lines where id = it.line_id),'') line, coalesce((select section from ebda.lines where id = it.line_id),'') line_section,
             coalesce(nullif(it.dept,''), r.dept, '') dept, coalesce(r.holder_name, r.requester_name, '') holder, it.qty, it.unit, it.unit_price,
             it.gm_approval gm, it.gm_note, it.fin_approval fin, it.fin_note, true has_doc, r.import_batch, r.status request_status,
             coalesce(r.priority,'') priority, ebda.req_status_label(r.status) status_label, r.id request_id,
             ebda.review_bucket(coalesce(r.status,'') = 'draft', it.gm_approval, it.fin_approval) bucket, ebda.sign_info(it.gm_approval, it.fin_approval, true) info
        from ebda.request_items it join ebda.requests r on r.id = it.request_id
       where ebda.can_request(u, r) and coalesce(r.status,'') <> 'cancelled' and coalesce(it.decision,'') <> 'cancelled'
         and (sid = '' or r.school_id = sid) and coalesce(nullif(r.request_date,''), substr(r.created_at,1,10)) between d1 and d2
         and (lid = '' or it.line_id = lid) and (bid = '' or r.import_batch = bid)),
    y as (select * from x where (cat = '' or category = cat) and (f_dept = '' or ebda.norm_txt(x.dept) = ebda.norm_txt(f_dept))
            and (qq = '' or ebda.norm_txt(item || ' ' || coalesce(src_suggested,'') || ' ' || coalesce(txn_no,'') || ' ' || line || ' ' || x.dept) like '%' || qq || '%'))
    select jsonb_build_object('ok', true, 'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u),
      'kpis', (select jsonb_build_object('all', count(*), 'draft', count(*) filter (where bucket = 'draft'), 'gm_pending', count(*) filter (where bucket = 'gm_pending'),
                 'fin_pending', count(*) filter (where bucket = 'fin_pending'), 'needs_edit', count(*) filter (where bucket = 'needs_edit'),
                 'approved', count(*) filter (where bucket = 'approved'), 'rejected', count(*) filter (where bucket = 'rejected'), 'amount', coalesce(sum(amount),0)) from y),
      'total', (select count(*) from y where bk = '' or bucket = bk),
      'categories', coalesce((select jsonb_agg(distinct category) from x where category <> ''), '[]'::jsonb),
      'depts', coalesce((select jsonb_agg(distinct x.dept) from x where x.dept <> ''), '[]'::jsonb),
      'rows', coalesce((select jsonb_agg(to_jsonb(z)) from (select * from y where bk = '' or bucket = bk order by date desc, txn_no desc limit lim offset off) z), '[]'::jsonb))
    into res;
  end if;
  return res;
end $rv$;

-- تفاصيل البند: كل أعمدة الملف الأصلية بترتيبها + حقول النظام + المستند + قرارا المدير العام والمدير المالى + سجل القرارات
create or replace function ebda.item_detail(u ebda.users, kind text, id_ text) returns jsonb language plpgsql stable security definer set search_path = ebda as $idt$
declare e ebda.expenses; it ebda.request_items; r ebda.requests; c ebda.custodies;
begin
  if kind = 'expenses' then
    select * into e from ebda.vis_expenses(u) x where x.id = id_;
    if e.id is null then return ebda.err('لا صلاحية على هذا البند أو غير موجود'); end if;
    select * into c from ebda.custodies where id = e.custody_id;
    return jsonb_build_object('ok', true, 'kind', kind, 'id', e.id, 'txn_no', e.txn_no, 'date', e.date, 'amount', e.amount, 'school', (select name from ebda.schools where id = e.school_id),
      'original', coalesce(e.src_row, '{}'::jsonb), 'src_sheet', e.src_sheet,
      'fields', jsonb_build_array(
        jsonb_build_array('البند (كما فى الملف)', coalesce(nullif(e.src_item,''), e.description, '')), jsonb_build_array('الوصف المقترح (كما فى الملف)', coalesce(e.src_suggested,'')),
        jsonb_build_array('تصنيف بند الصرف', coalesce(e.category,'')), jsonb_build_array('بند الموازنة المرتبط', coalesce((select section || ' / ' || name from ebda.lines where id = e.line_id),'غير مربوط')),
        jsonb_build_array('مسئول العهدة', coalesce(nullif(e.src_holder,''), ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), '')), jsonb_build_array('العهدة', coalesce(c.code,'')),
        jsonb_build_array('مصاريف OUT', e.amount), jsonb_build_array('الرصيد (كما فى الملف)', coalesce(e.src_balance,'')), jsonb_build_array('مستند (كما فى الملف)', coalesce(e.src_doc,'')),
        jsonb_build_array('المورد', coalesce(e.supplier,'')), jsonb_build_array('رقم المستند', coalesce(e.doc_no,'')), jsonb_build_array('ملاحظات', coalesce(e.note,'')),
        jsonb_build_array('دورة الاعتماد (المدير المباشر/المالية)', ebda.expense_stage(e))),
      'doc_url', case when coalesce(e.doc_url,'') like 'data:%' then 'inline:' else coalesce(e.doc_url,'') end, 'doc_name', coalesce(e.doc_name,''),
      'gm', jsonb_build_object('decision', e.gm_approval, 'note', e.gm_note, 'by', e.gm_by, 'at', e.gm_at, 'file_mark', e.file_gm_ok, 'file_note', e.file_gm_note),
      'fin', jsonb_build_object('decision', e.fin_sign, 'note', e.fin_sign_note, 'by', e.fin_sign_by, 'at', e.fin_sign_at, 'file_mark', e.file_fin_ok),
      'info', ebda.sign_info(e.gm_approval, e.fin_sign, coalesce(e.doc_url,'') <> ''), 'bucket', ebda.review_bucket(coalesce(e.approval,'') = 'draft', e.gm_approval, e.fin_sign),
      'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u), 'can_category', ebda.can_categorize(u, 'expenses', e.id),
      'history', (ebda.item_history(u, 'expenses', e.id))->'items');
  else
    select * into it from ebda.request_items where id = id_;
    select * into r from ebda.requests where id = it.request_id;
    if it.id is null or not ebda.can_request(u, r) then return ebda.err('لا صلاحية على هذا البند أو غير موجود'); end if;
    return jsonb_build_object('ok', true, 'kind', kind, 'id', it.id, 'txn_no', r.req_no, 'date', r.request_date, 'amount', it.amount, 'school', (select name from ebda.schools where id = r.school_id),
      'original', coalesce(it.src_row, '{}'::jsonb),
      'fields', jsonb_build_array(
        jsonb_build_array('الصنف', it.name), jsonb_build_array('الوحدة', coalesce(it.unit,'')), jsonb_build_array('العدد', it.qty), jsonb_build_array('قيمة تقديرية للوحدة', it.unit_price),
        jsonb_build_array('الإجمالى', it.amount), jsonb_build_array('نوع المصروف (كما فى الملف)', coalesce(it.src_line,'')), jsonb_build_array('تصنيف بند الصرف', coalesce(it.category,'')),
        jsonb_build_array('بند الموازنة المرتبط', coalesce((select section || ' / ' || name from ebda.lines where id = it.line_id),'غير مربوط')),
        jsonb_build_array('الجهة الطالبة', coalesce(nullif(it.dept,''), r.dept, '')), jsonb_build_array('سبب الطلب', coalesce(r.reason,'')), jsonb_build_array('وصف تفصيلى للطلب', coalesce(nullif(it.item_note,''), r.description, '')),
        jsonb_build_array('الأولوية', coalesce(r.priority,'')), jsonb_build_array('حالة التحقق من المخزن', coalesce(it.stock_check,'')), jsonb_build_array('نتيجة مراجعة المخزون', coalesce(it.stock_result,'')),
        jsonb_build_array('الاعتماد', coalesce(it.decision,'')), jsonb_build_array('مبررات قرار الاعتماد', coalesce(it.sup_note,'')), jsonb_build_array('تاريخ الاعتماد', coalesce(it.decision_date,'')),
        jsonb_build_array('التسوية المالية', coalesce(nullif(r.settlement,''), case when it.file_settle = 'نعم' then '✓ فى الملف' else '' end)),
        jsonb_build_array('حالة طلب العهدة', ebda.req_status_label(r.status))),
      'doc_url', '', 'gm', jsonb_build_object('decision', it.gm_approval, 'note', it.gm_note, 'by', it.gm_by, 'at', it.gm_at, 'file_note', it.file_gm_note),
      'fin', jsonb_build_object('decision', it.fin_approval, 'note', it.fin_note, 'by', it.fin_by, 'at', it.fin_at, 'file_mark', it.file_fin_ok),
      'info', ebda.sign_info(it.gm_approval, it.fin_approval, true), 'bucket', ebda.review_bucket(coalesce(r.status,'') = 'draft', it.gm_approval, it.fin_approval),
      'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u), 'can_category', ebda.can_categorize(u, 'needs', it.id),
      'history', (ebda.item_history(u, 'needs', it.id))->'items');
  end if;
end $idt$;

-- تحديد «تصنيف بند الصرف» إجراء صريح: الأدمن، أو صاحب صلاحية «records.classify» الممنوحة صراحةً — ولا يغيّر البند الأصلى
create or replace function ebda.can_categorize(u ebda.users, kind text, id_ text) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and 'records.classify' = any(ebda.perms_of(u))) $$;
create or replace function ebda.set_category(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $sc$
declare kind text := coalesce(req->>'kind','expenses'); ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb)));
  cat text := left(btrim(coalesce(req->>'category','')), 200); n int;
begin
  if not ebda.can_categorize(u, kind, '') then return ebda.err('تحديد تصنيف بند الصرف للأدمن أو بصلاحية صريحة'); end if;
  if coalesce(cardinality(ids),0) = 0 then return ebda.err('لم يتم تحديد أى بند'); end if;
  if kind = 'expenses' then
    if exists(select 1 from ebda.expenses x where x.id = any(ids) and not ebda.can_school(u, x.school_id)) then return ebda.err('خارج نطاقك'); end if;
    update ebda.expenses set category = cat, updated_by = u.name, updated_at = now()::text where id = any(ids);
  else
    update ebda.request_items set category = cat where id = any(ids);
  end if;
  get diagnostics n = row_count;
  insert into ebda.item_decisions select ebda.uid(), kind, x, 'category', 'category', cat, '', '', u.name, u.id, ebda.rk(u), now()::text from unnest(ids) x;
  return jsonb_build_object('ok', true, 'updated', n);
end $sc$;

-- ============================================================================
--  14) v10.6: تبويب «العهد» الموحد — المستندات لكل حركة بسجل لا يُفقد عند الاستبدال + ترتيب الرصيد الافتتاحى
-- ============================================================================
create table if not exists ebda.expense_docs(
  id text primary key, expense_id text not null, doc_url text default '', doc_name text default '', doc_type text default '',
  is_link text default '', archived_by text default '', archived_at text default '', reason text default '');
create index if not exists expense_docs_exp on ebda.expense_docs(expense_id, archived_at);


-- ================================================================ v10.6: إعادة الإرسال للمراجعة بعد «إرجاع للاستكمال»
create or replace function ebda.resubmit_items(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $rs$
declare kind text := coalesce(req->>'kind','expenses'); ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb)));
  nt text := left(btrim(coalesce(req->>'note','')), 2000); id_ text; e ebda.expenses; it ebda.request_items; r ebda.requests; c ebda.custodies;
  n int := 0; skip jsonb := '[]'::jsonb; who text; prev text; prevn text;
begin
  if coalesce(cardinality(ids),0) = 0 then return ebda.err('لم يتم تحديد أى بند'); end if;
  if cardinality(ids) > 500 then return ebda.err('500 بند كحد أقصى'); end if;
  if kind not in ('expenses','needs') then return ebda.err('نوع غير معروف'); end if;
  foreach id_ in array ids loop
    if kind = 'expenses' then
      select * into e from ebda.expenses where id = id_ for update;
      if not found or coalesce(e.cancelled_at,'') <> '' then skip := skip || jsonb_build_object('id', id_, 'reason', 'غير موجود أو ملغى'); continue; end if;
      select * into c from ebda.custodies where id = e.custody_id;
      if not (ebda.rk(u) = 'admin' or (c.id is not null and ebda.owns_custody(u, c))) then
        skip := skip || jsonb_build_object('id', id_, 'reason', 'إعادة الإرسال لمسئول العهدة صاحب الحركة'); continue; end if;
      if coalesce(e.gm_approval,'') = 'returned' then who := 'gm'; prev := 'returned'; prevn := coalesce(e.gm_note,'');
        update ebda.expenses set gm_approval = '' where id = id_;
      elsif coalesce(e.fin_sign,'') = 'returned' then who := 'fin'; prev := 'returned'; prevn := coalesce(e.fin_sign_note,'');
        update ebda.expenses set fin_sign = '' where id = id_;
      else skip := skip || jsonb_build_object('id', id_, 'reason', 'البند ليس معاداً للاستكمال'); continue; end if;
    else
      select * into it from ebda.request_items where id = id_ for update;
      if not found then skip := skip || jsonb_build_object('id', id_, 'reason', 'غير موجود'); continue; end if;
      select * into r from ebda.requests where id = it.request_id;
      if coalesce(r.status,'') = 'cancelled' or not (ebda.rk(u) = 'admin' or ebda.is_requester(u, r) or (coalesce(r.holder_id,'') <> '' and r.holder_id = u.id)) then
        skip := skip || jsonb_build_object('id', id_, 'reason', 'إعادة الإرسال لمقدم الطلب'); continue; end if;
      if coalesce(it.gm_approval,'') = 'returned' then who := 'gm'; prev := 'returned'; prevn := coalesce(it.gm_note,'');
        update ebda.request_items set gm_approval = '' where id = id_;
      elsif coalesce(it.fin_approval,'') = 'returned' then who := 'fin'; prev := 'returned'; prevn := coalesce(it.fin_note,'');
        update ebda.request_items set fin_approval = '' where id = id_;
      else skip := skip || jsonb_build_object('id', id_, 'reason', 'البند ليس معاداً للاستكمال'); continue; end if;
    end if;
    -- ملاحظة المسئول السابقة تبقى كما هى، والقرار السابق محفوظ فى السجل
    insert into ebda.item_decisions values(ebda.uid(), kind, id_, who, 'resubmitted',
      case when nt <> '' then 'أُعيد الإرسال بعد الاستكمال: ' || nt else 'أُعيد الإرسال بعد الاستكمال' end, prev, prevn, u.name, u.id, ebda.rk(u), now()::text);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', n > 0 or jsonb_array_length(skip) = 0, 'n', n, 'skipped', skip) || case when n = 0 and jsonb_array_length(skip) > 0 then jsonb_build_object('error', skip->0->>'reason') else '{}'::jsonb end;
end $rs$;

-- ================================================================ v10.7 (1): تعديل قيمة العهدة المستلمة بعد تسجيلها — بسبب مكتوب، مع القيمة القديمة والجديدة
alter table ebda.custodies add column if not exists doc_folder text default '';
alter table ebda.expenses add column if not exists doc_ref text default '';
create table if not exists ebda.custody_amount_log(
  id text primary key, custody_id text not null, tranche_id text default '', old_amount numeric, new_amount numeric,
  old_received numeric, new_received numeric, reason text default '', by_name text default '', by_id text default '', by_role text default '', at text default '');
create index if not exists custody_amount_log_c on ebda.custody_amount_log(custody_id, at);

create or replace function ebda.can_edit_custody_amount(u ebda.users, c ebda.custodies) returns boolean language sql stable as $$
  select ebda.rk(u) <> 'observer' and ebda.can_custody(u, c)
     and not (ebda.rk(u) <> 'admin' and ebda.owns_custody(u, c))          -- مسئول العهدة لا يعدّل قيمة عهدته بنفسه
     and (ebda.rk(u) = 'admin' or 'custody.amount_edit' = any(ebda.perms_of(u)))
$$;

create or replace function ebda.edit_custody_amount(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $ca$
declare c ebda.custodies; t ebda.tranches; amt numeric; rsn text := btrim(coalesce(req->>'reason','')); old_rec numeric; new_rec numeric; spent numeric;
begin
  select * into c from ebda.custodies where id = req->>'custody_id' for update;
  if not found then return ebda.err('العهدة غير موجودة'); end if;
  if coalesce(c.status,'') = 'cancelled' or coalesce(c.cancelled_at,'') <> '' then return ebda.err('العهدة ملغاة'); end if;
  if not ebda.can_edit_custody_amount(u, c) then
    return ebda.err(case when ebda.owns_custody(u, c) and ebda.rk(u) <> 'admin' then 'مسئول العهدة لا يعدّل قيمة العهدة المستلمة بنفسه — يعدّلها المدير المالى أو المفوَّض'
                         else 'لا صلاحية لتعديل قيمة العهدة' end); end if;
  if not ebda.num_ok(req->>'amount') or coalesce(btrim(req->>'amount'),'') = '' then return ebda.err('القيمة غير صحيحة'); end if;
  amt := (req->>'amount')::numeric;
  if amt < 0 then return ebda.err('القيمة لا تكون سالبة'); end if;
  if length(rsn) < 3 then return ebda.err('اكتب سبب التعديل'); end if;
  select coalesce(sum(amount),0) into old_rec from ebda.tranches where custody_id = c.id;
  if coalesce(req->>'tranche_id','') <> '' then
    select * into t from ebda.tranches where id = req->>'tranche_id' and custody_id = c.id for update;
    if not found then return ebda.err('الدفعة غير موجودة فى هذه العهدة'); end if;
  else
    -- القيمة الأساسية للعهدة (الدفعة الافتتاحية)، وإلا أول دفعة
    select * into t from ebda.tranches where custody_id = c.id
      order by (coalesce(note,'') like 'القيمة الأساسية%') desc, date, id limit 1 for update;
  end if;
  if t.id is null then
    insert into ebda.tranches(id, custody_id, date, amount, note) values(ebda.uid(), c.id, coalesce(nullif(c.opened_at,''), to_char(now(),'YYYY-MM-DD')), amt, 'القيمة الأساسية للعهدة')
      returning * into t;
    insert into ebda.custody_amount_log values(ebda.uid(), c.id, t.id, 0, amt, old_rec, old_rec + amt, rsn, u.name, u.id, ebda.rk(u), now()::text);
  else
    if t.amount = amt then return ebda.err('القيمة لم تتغير'); end if;
    insert into ebda.custody_amount_log values(ebda.uid(), c.id, t.id, t.amount, amt, old_rec, old_rec - t.amount + amt, rsn, u.name, u.id, ebda.rk(u), now()::text);
    update ebda.tranches set amount = amt where id = t.id;
  end if;
  select coalesce(sum(amount),0) into new_rec from ebda.tranches where custody_id = c.id;
  select coalesce(sum(e.amount),0) into spent from ebda.expenses e where e.custody_id = c.id and coalesce(e.cancelled_at,'') = '' and coalesce(e.approval,'') <> 'rejected';
  -- المصروفات لا تتغير — الرصيد يُحسب من الوارد والمنصرف مباشرة
  return jsonb_build_object('ok', true, 'tranche_id', t.id, 'old_received', old_rec, 'received', new_rec, 'spent', spent, 'balance', new_rec - spent);
end $ca$;

create or replace function ebda.custody_amount_history(u ebda.users, cid text) returns jsonb language plpgsql stable security definer set search_path = ebda as $ch$
declare c ebda.custodies;
begin
  select * into c from ebda.custodies where id = cid;
  if not found or not ebda.can_custody(u, c) then return ebda.err('لا صلاحية'); end if;
  return jsonb_build_object('ok', true, 'can_edit', ebda.can_edit_custody_amount(u, c), 'doc_folder', coalesce(c.doc_folder,''),
    'tranches', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'date', t.date, 'amount', t.amount, 'note', t.note) order by (coalesce(t.note,'') like 'القيمة الأساسية%') desc, t.date) from ebda.tranches t where t.custody_id = cid), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('old', l.old_amount, 'new', l.new_amount, 'old_received', l.old_received, 'new_received', l.new_received,
              'reason', l.reason, 'by', l.by_name, 'role', l.by_role, 'at', l.at) order by l.at desc) from ebda.custody_amount_log l where l.custody_id = cid), '[]'::jsonb));
end $ch$;

-- ================================================================ v10.7 (2): استيراد روابط المستندات — مستقل عن استيراد المصروفات
-- المطابقة برقم البند «م» فى الملف أو رقم العملية فقط — لا يُربط مستند بالترتيب. لا يُنشأ رابط فردى غير موجود فى المصدر.
create or replace function ebda.import_doc_links(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $dl$
declare c ebda.custodies; folder text := btrim(coalesce(req->>'folder_url','')); commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
  rw jsonb; k text; url text; ids text[]; e ebda.expenses; res jsonb := '[]'::jsonb; nlink int := 0; nrev int := 0; nmiss int := 0; namb int := 0; nsame int := 0;
  seen text[] := '{}'; st text;
begin
  select * into c from ebda.custodies where id = req->>'custody_id';
  if not found then return ebda.err('اختر العهدة'); end if;
  if coalesce(req->>'school_id','') <> '' and c.school_id <> req->>'school_id' then return ebda.err('العهدة ليست تابعة للمكان المختار'); end if;
  if not (ebda.rk(u) = 'admin' or ebda.owns_custody(u, c) or (ebda.rk(u) = 'finance_manager' and ebda.can_custody(u, c))) then
    return ebda.err('لا صلاحية لربط مستندات هذه العهدة'); end if;
  if folder <> '' and folder !~* '^https?://' then return ebda.err('رابط المجلد يجب أن يبدأ بـ http:// أو https://'); end if;
  if jsonb_array_length(coalesce(req->'rows','[]'::jsonb)) > 3000 then return ebda.err('3000 صف كحد أقصى'); end if;
  for rw in select * from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) loop
    k := btrim(coalesce(rw->>'key','')); url := btrim(coalesce(rw->>'url',''));
    if k = '' then continue; end if;
    if k = any(seen) then res := res || jsonb_build_object('key', k, 'status', 'dup', 'msg', 'رقم مكرر فى الملف — تم تجاهل التكرار'); continue; end if;
    seen := seen || k;
    if url <> '' and url !~* '^https?://' then res := res || jsonb_build_object('key', k, 'status', 'bad_url', 'msg', 'رابط غير صالح'); continue; end if;
    ids := array(select x.id from ebda.expenses x where x.custody_id = c.id and coalesce(x.cancelled_at,'') = ''
                   and (btrim(coalesce(x.src_seq,'')) = k or btrim(coalesce(x.txn_no,'')) = k or regexp_replace(btrim(coalesce(x.src_seq,'')), '\.0+$', '') = regexp_replace(k, '\.0+$', '')));
    if cardinality(ids) = 0 then nmiss := nmiss + 1; res := res || jsonb_build_object('key', k, 'status', 'no_match', 'msg', 'لا يوجد مصروف بهذا الرقم فى العهدة'); continue; end if;
    if cardinality(ids) > 1 then namb := namb + 1; res := res || jsonb_build_object('key', k, 'status', 'ambiguous', 'msg', 'أكثر من مصروف بنفس الرقم — يحتاج مراجعة يدوية', 'n', cardinality(ids)); continue; end if;
    select * into e from ebda.expenses where id = ids[1] for update;
    if url <> '' then
      if coalesce(e.doc_url,'') = url then nsame := nsame + 1; st := 'same';
      else
        st := 'link'; nlink := nlink + 1;
        if commit_ then
          if coalesce(e.doc_url,'') <> '' then
            insert into ebda.expense_docs(id, expense_id, doc_url, doc_name, doc_type, is_link, archived_by, archived_at, reason)
            values(ebda.uid(), e.id, e.doc_url, coalesce(e.doc_name,''), coalesce(e.doc_type,''), coalesce(e.doc_is_link,''), u.name, now()::text, 'استُبدل باستيراد روابط المستندات');
          end if;
          update ebda.expenses set doc_url = url, doc_is_link = 'نعم', doc_name = 'مستند البند ' || k, doc_ref = '' where id = e.id;
        end if;
      end if;
    else
      -- لا يوجد رابط فردى فى المصدر: لا يُخترع رابط — المستند فى مجلد العهدة ويحتاج مراجعة
      if coalesce(e.doc_url,'') <> '' then st := 'has_doc'; nsame := nsame + 1;
      else st := 'review'; nrev := nrev + 1; if commit_ then update ebda.expenses set doc_ref = 'folder_review' where id = e.id; end if; end if;
    end if;
    res := res || jsonb_build_object('key', k, 'status', st, 'txn_no', e.txn_no, 'id', e.id, 'amount', e.amount, 'item', coalesce(nullif(e.src_item,''), e.description), 'url', url);
  end loop;
  if commit_ and folder <> '' then update ebda.custodies set doc_folder = folder where id = c.id; end if;
  return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'custody', c.code, 'folder', folder,
    'linked', nlink, 'review', nrev, 'no_match', nmiss, 'ambiguous', namb, 'unchanged', nsame, 'rows', res,
    'unlisted', (select count(*) from ebda.expenses x where x.custody_id = c.id and coalesce(x.cancelled_at,'') = '' and not (btrim(coalesce(x.src_seq,'')) = any(seen) or btrim(coalesce(x.txn_no,'')) = any(seen))));
end $dl$;

-- ================================================================ v10.7 (3): نظام الرواتب الجديد — قالب «شيت مؤثرات رواتب ابدأ اديو الشهرية»
-- نسخة احتياطية من بيانات الرواتب الحالية قبل الاستبدال (مرة واحدة؛ الجداول القديمة تبقى كما هى للرجوع إليها)
do $bk$
declare t text;
begin
  foreach t in array array['employees','salaries','payslips','payslip_items','payroll_periods','payroll_components','payroll_totals','effects','payroll_effects','effects_rules'] loop
    if to_regclass('ebda.' || t) is not null and to_regclass('ebda.bk_v107_' || t) is null then
      execute format('create table ebda.%I as table ebda.%I', 'bk_v107_' || t, t);
    end if;
  end loop;
end $bk$;

create table if not exists ebda.pay2_staff(
  id text primary key, school_id text not null, fy text not null, code text default '', ins_status text default '', name text not null, name_key text not null,
  job text default '', hire_date text default '', hire_raw text default '', net_salary numeric, leave_balance numeric, months jsonb default '{}'::jsonb,
  active text default 'نعم', sort int default 0, created_at text default now()::text, created_by text default '', updated_at text default '', updated_by text default '');
create unique index if not exists pay2_staff_u on ebda.pay2_staff(school_id, fy, name_key);
create table if not exists ebda.pay2_effects(
  id text primary key, staff_id text not null, school_id text not null, period text not null,
  work_days numeric, summary text default '', hour_deduct numeric, day_deduct numeric, notes1 text default '',
  annual_days numeric, annual_detail text default '', casual_days numeric, casual_detail text default '', sick_days numeric, sick_detail text default '',
  absent_days numeric, absent_detail text default '', perm_count numeric, perm_detail text default '', notes2 text default '',
  updated_at text default '', updated_by text default '');
create unique index if not exists pay2_effects_u on ebda.pay2_effects(staff_id, period);
create table if not exists ebda.pay2_sheets(
  id text primary key, school_id text not null, period text not null, status text default 'draft', note text default '',
  reviewed_by text default '', reviewed_at text default '', approved_by text default '', approved_at text default '');
create unique index if not exists pay2_sheets_u on ebda.pay2_sheets(school_id, period);
create table if not exists ebda.pay2_log(
  id text primary key, school_id text, period text, staff_id text, field text, old_value text, new_value text, source text default 'edit',
  by_name text, by_id text, by_role text, at text);
create index if not exists pay2_log_i on ebda.pay2_log(school_id, period, at);
create table if not exists ebda.pay2_imports(
  id text primary key, school_id text, period text, file text default '', sheet text default '', by_name text, by_id text, at text,
  added int default 0, updated int default 0, unchanged int default 0, rejected int default 0, report jsonb default '[]'::jsonb);

-- الحقول بترتيب القالب: [المفتاح، العنوان فى الملف، المجموعة، النوع، المستوى]
create or replace function ebda.pay2_fields() returns jsonb language sql immutable as $$
  -- v10.9: العناوين الأصلية لشيت المؤثرات (ملفا بدر ودمياط) بنفس الترتيب — [المفتاح، العنوان كما فى الملف، المجموعة، النوع، المستوى]
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
   ["m10","شهر أكتوبر","entry","num","staff"],["m11","شهر نوفمبر","entry","num","staff"],["m12","شهر ديسمبر","entry","num","staff"],
   ["m01","شهر يناير","entry","num","staff"],["m02","شهر فبراير","entry","num","staff"],["m03","شهر مارس","entry","num","staff"],
   ["m04","شهرأبريل","entry","num","staff"],["m05","شهر مايو","entry","num","staff"],["m06","شهر يونيو","entry","num","staff"]]'::jsonb
$$;

-- قواعد تعديل الحقول (قابلة للضبط من الأدمن): الحقل → الأدوار التى تملأه/تعدّله. الأدمن دائماً. غير المذكور = مشاهدة فقط.
insert into ebda.config(key, value) values('pay2_field_rules', (select jsonb_object_agg(f->>0,
    case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb else '["custody_officer","finance_manager"]'::jsonb end)::text
  from jsonb_array_elements(ebda.pay2_fields()) f)) on conflict (key) do nothing;

create or replace function ebda.pay2_fy(period text) returns text language sql immutable as $$
  select case when split_part(period,'-',2)::int >= 7 then split_part(period,'-',1) || '-' || (split_part(period,'-',1)::int + 1)
              else (split_part(period,'-',1)::int - 1) || '-' || split_part(period,'-',1) end
$$;
create or replace function ebda.pay2_key(n text) returns text language sql immutable as $$
  select regexp_replace(btrim(coalesce(n,'')), '\s+', ' ', 'g')
$$;
create or replace function ebda.pay2_loose(n text) returns text language sql immutable as $$
  select translate(regexp_replace(coalesce(n,''), '\s+', '', 'g'), 'أإآىةؤئ', 'اااي' || 'ه' || 'وي')
$$;
create or replace function ebda.pay2_view_ok(u ebda.users, sid text) returns boolean language sql stable as $$
  select ebda.can_school(u, sid) and (ebda.rk(u) in ('admin','finance_manager','observer') or ebda.can(u,'payroll.view'))
$$;
-- صلاحية تعديل حقل بعينه: الأدمن · أو منح صريح للحقل «payfield.<key>» · أو البيانات الأساسية بمنح «payroll.base» · أو دور المستخدم فى قواعد الحقل
create or replace function ebda.pay2_field_ok(u ebda.users, f text) returns boolean language sql stable security definer set search_path = ebda as $$
  select ebda.rk(u) = 'admin'
      or (ebda.rk(u) <> 'observer' and (
           ('payfield.' || f) = any(ebda.perms_of(u))
        or ('payroll.base' = any(ebda.perms_of(u)) and exists(select 1 from jsonb_array_elements(ebda.pay2_fields()) x where x->>0 = f and x->>2 = 'base'))
        or coalesce((select (value::jsonb) -> f from ebda.config where key = 'pay2_field_rules'), '[]'::jsonb) ? ebda.rk(u)))
$$;
create or replace function ebda.pay2_my_fields(u ebda.users) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(f->>0), '[]'::jsonb) from jsonb_array_elements(ebda.pay2_fields()) f where ebda.pay2_field_ok(u, f->>0)
$$;

create or replace function ebda.pay2_sheet(sid text, p text) returns ebda.pay2_sheets language plpgsql as $$
declare s ebda.pay2_sheets;
begin
  select * into s from ebda.pay2_sheets where school_id = sid and period = p;
  if not found then insert into ebda.pay2_sheets(id, school_id, period) values(ebda.uid(), sid, p) on conflict do nothing;
    select * into s from ebda.pay2_sheets where school_id = sid and period = p; end if;
  return s;
end $$;

-- تحويل/تحقق قيمة حقل: يعيد {ok, v (نص التخزين), err}
create or replace function ebda.pay2_val(typ text, raw text) returns jsonb language plpgsql immutable as $$
declare t text := btrim(coalesce(raw,'')); d date;
begin
  if t = '' then return jsonb_build_object('ok', true, 'v', ''); end if;
  if typ = 'num' then
    t := translate(t, '٠١٢٣٤٥٦٧٨٩٫', '0123456789.');
    if t !~ '^-?[0-9]+(\.[0-9]+)?$' then return jsonb_build_object('ok', false, 'err', 'قيمة رقمية غير صحيحة: ' || raw); end if;
    return jsonb_build_object('ok', true, 'v', t);
  elsif typ = 'date' then
    t := translate(t, '٠١٢٣٤٥٦٧٨٩', '0123456789');
    begin
      if t ~ '^\d{4}-\d{1,2}-\d{1,2}' then d := to_date(substr(t,1,10), 'YYYY-MM-DD');
      elsif t ~ '^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}$' then d := to_date(regexp_replace(t, '[.-]', '/', 'g'), 'DD/MM/YYYY');
      else return jsonb_build_object('ok', false, 'err', 'تاريخ تعيين غير صحيح: ' || raw); end if;
    exception when others then return jsonb_build_object('ok', false, 'err', 'تاريخ تعيين غير صحيح: ' || raw); end;
    if d < date '1950-01-01' or d > date '2100-01-01' then return jsonb_build_object('ok', false, 'err', 'تاريخ تعيين خارج المدى: ' || raw); end if;
    return jsonb_build_object('ok', true, 'v', to_char(d, 'YYYY-MM-DD'));
  end if;
  return jsonb_build_object('ok', true, 'v', left(t, 2000));
end $$;

alter table ebda.pay2_effects add column if not exists snap jsonb;
alter table ebda.pay2_imports add column if not exists action text default '';
-- بيانات الموظف كما هى فى شهر بعينه: البيانات الحالية ثم لقطة الشهر (إن وُجدت) — استيراد شهر جديد لا يغيّر الأشهر السابقة
create or replace function ebda.pay2_master(s ebda.pay2_staff) returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object('ins_status', s.ins_status, 'job', s.job, 'hire_date', s.hire_date,
     'net_salary', s.net_salary::text, 'leave_balance', s.leave_balance::text)) || coalesce(s.months, '{}'::jsonb)
$$;
create or replace function ebda.pay2_view(s ebda.pay2_staff, p text) returns jsonb language sql stable as $$
  -- الشهر الذى له لقطة يُعرض من لقطته وحدها (حتى لا تتسرب إليه قيم أُضيفت لاحقاً لأشهر أخرى)
  select coalesce((select e.snap from ebda.pay2_effects e where e.staff_id = s.id and e.period = p), ebda.pay2_master(s))
$$;
-- كتابة حقل على مستوى الموظف لشهر p: تُجمَّد لقطة الأشهر الأخرى أولاً، ثم لقطة الشهر p، والبيانات الحالية فقط إن كان p أحدث شهر
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
    if k ~ '^m\d\d$' then update ebda.pay2_staff set months = coalesce(months,'{}'::jsonb) || jsonb_build_object(k, v) where id = st_id;
    elsif typ = 'num' then execute format('update ebda.pay2_staff set %I = nullif($1,'''')::numeric where id = $2', k) using v, st_id;
    else execute format('update ebda.pay2_staff set %I = $1 where id = $2', k) using v, st_id; end if;
  end if;
end $$;

create or replace function ebda.pay2_row(s ebda.pay2_staff, p text) returns jsonb language sql stable as $$
  with v as (select ebda.pay2_view(s, p) j)
  select jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name, 'active', s.active, 'updated_by', s.updated_by, 'updated_at', s.updated_at)
   || v.j
   || jsonb_build_object('remaining', case when coalesce(v.j->>'leave_balance','') = '' then null
        else (v.j->>'leave_balance')::numeric - coalesce((select sum(nullif(x.val,'')::numeric) from jsonb_each_text(v.j) x(k, val) where x.k ~ '^m\d\d$'),0) end)
   || coalesce((select to_jsonb(e) - 'id' - 'staff_id' - 'school_id' - 'period' - 'updated_at' - 'updated_by' - 'snap'
                  || jsonb_build_object('eff_updated_by', e.updated_by, 'eff_updated_at', e.updated_at)
                from ebda.pay2_effects e where e.staff_id = s.id and e.period = p), '{}'::jsonb)
  from v
$$;


create or replace function ebda.pay2_load(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pl$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); s ebda.pay2_sheets;
begin
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  if not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية على رواتب هذه الجهة'); end if;
  select * into s from ebda.pay2_sheets where school_id = sid and period = p;
  return jsonb_build_object('ok', true, 'school_id', sid, 'period', p, 'fy', ebda.pay2_fy(p),
    'status', coalesce(s.status, 'draft'), 'sheet', to_jsonb(s), 'fields', ebda.pay2_fields(),
    'my_fields', case when ebda.rk(u) = 'observer' then '[]'::jsonb else ebda.pay2_my_fields(u) end,
    'can_review', ebda.rk(u) in ('admin','finance_manager') and ebda.can_school(u, sid),
    'can_approve', ebda.rk(u) = 'admin' or 'gm.approve' = any(ebda.perms_of(u)),
    'can_import', ebda.rk(u) <> 'observer' and (ebda.rk(u) = 'admin' or ebda.can(u,'payroll.import')),
    'can_delete', ebda.pay2_can_delete(u), 'can_replace', ebda.pay2_can_replace(u),
    'last_import', (select jsonb_build_object('at', i.at, 'by', i.by_name, 'file', i.file, 'mode', i.mode, 'action', i.action) from ebda.pay2_imports i
                    where i.school_id = sid and i.period = p and coalesce(i.action,'') not in ('failed','delete') order by i.at desc limit 1),
    'records', (select count(*) from ebda.pay2_effects e where e.school_id = sid and e.period = p),
    'rows', coalesce((select jsonb_agg(ebda.pay2_row(x, p) order by x.sort, x.created_at, x.name) from ebda.pay2_staff x
                      where x.school_id = sid and x.fy = ebda.pay2_fy(p) and coalesce(x.active,'نعم') = 'نعم'), '[]'::jsonb),
    'imports', coalesce((select jsonb_agg(jsonb_build_object('file', i.file, 'sheet', i.sheet, 'by', i.by_name, 'at', i.at, 'added', i.added, 'updated', i.updated,
                      'unchanged', i.unchanged, 'rejected', i.rejected) order by i.at desc) from ebda.pay2_imports i where i.school_id = sid and i.period = p), '[]'::jsonb));
end $pl$;

-- تعديل حقل/حقول موظف (يدوياً) — كل حقل يُفحص مستقلاً على الخادم
create or replace function ebda.pay2_save(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $ps2$
declare st ebda.pay2_staff; p text := coalesce(req->>'period',''); sh ebda.pay2_sheets; f jsonb; k text; nv jsonb; old text; denied text[] := '{}';
  n int := 0; eid text; errs jsonb := '[]'::jsonb;
begin
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  select * into st from ebda.pay2_staff where id = req->>'id' for update;
  if not found then return ebda.err('الموظف غير موجود'); end if;
  if not ebda.pay2_view_ok(u, st.school_id) or ebda.rk(u) = 'observer' then return ebda.err('لا صلاحية على رواتب هذه الجهة'); end if;
  if st.fy <> ebda.pay2_fy(p) then return ebda.err('الشهر خارج السنة المالية لبيانات الموظف'); end if;
  sh := ebda.pay2_sheet(st.school_id, p);
  if sh.status in ('approved','fin_approved') and current_setting('ebda.pay2_force', true) is distinct from '1' then
    return ebda.err('مؤثرات هذا الشهر معتمدة مالياً — لا تعديل إلا بطلب تعديل للأدمن'); end if;
  -- v16: بعد اعتماد المدير المباشر: لا تعديل إلا للمدير المالى فى أعمدته خلال المهلة (أو الأدمن) — وبسبب مكتوب
  if ebda.pay2_locked(sh.status) and current_setting('ebda.pay2_force', true) is distinct from '1' and length(btrim(coalesce(req->>'reason',''))) < 3 then
    return ebda.err('الشهر معتمد من المدير المباشر — اكتب سبب التعديل'); end if;
  for f in select * from jsonb_array_elements(ebda.pay2_fields()) loop
    k := f->>0;
    if not (coalesce(req->'patch','{}'::jsonb) ? k) then continue; end if;
    if not ebda.pay2_field_ok(u, k) then denied := denied || (f->>1); continue; end if;
    if not ebda.pay2_edit_ok(u, k, f->>2, coalesce(sh.status,'draft'), p) then denied := denied || ((f->>1) || ' (غير متاح فى مرحلة «' || ebda.pay2_status_label(sh.status) || '»)'); continue; end if;
    nv := ebda.pay2_val(f->>3, req#>>array['patch',k]);
    if not (nv->>'ok')::boolean then errs := errs || to_jsonb(f->>1 || ': ' || (nv->>'err')); continue; end if;
    if k = 'name' and nv->>'v' = '' then errs := errs || to_jsonb('الاسم لا يكون فارغاً'::text); continue; end if;
    if f->>4 = 'staff' then
      old := case when k in ('name','code') then coalesce(to_jsonb(st)->>k,'') else coalesce(ebda.pay2_view(st, p)->>k,'') end;
      if old = nv->>'v' or (f->>3 = 'num' and old <> '' and nv->>'v' <> '' and old::numeric = (nv->>'v')::numeric) then continue; end if;
      if k = 'code' then
        if nv->>'v' <> '' and exists(select 1 from ebda.pay2_staff x where x.fy = st.fy and x.code = nv->>'v' and x.id <> st.id) then
          errs := errs || to_jsonb('الكود مستخدم لموظف آخر'::text); continue; end if;
        update ebda.pay2_staff set code = nv->>'v' where id = st.id;
      elsif k = 'name' then
        if exists(select 1 from ebda.pay2_staff x where x.school_id = st.school_id and x.fy = st.fy and x.name_key = ebda.pay2_key(nv->>'v') and x.id <> st.id) then
          errs := errs || to_jsonb('يوجد موظف آخر بنفس الاسم'::text); continue; end if;
        update ebda.pay2_staff set name = ebda.pay2_key(nv->>'v'), name_key = ebda.pay2_key(nv->>'v') where id = st.id;
      else perform ebda.pay2_set_staff(st.id, p, k, nv->>'v', f->>3, u.name);
        if k = 'leave_balance' then perform ebda.pay2_set_staff(st.id, p, 'leave_balance_f', '', 'text', u.name); end if;   -- قيمة يدوية تُلغى المعادلة القديمة
      end if;
      update ebda.pay2_staff set updated_by = u.name, updated_at = now()::text where id = st.id;
    else
      select id into eid from ebda.pay2_effects where staff_id = st.id and period = p;
      if eid is null then eid := ebda.uid(); insert into ebda.pay2_effects(id, staff_id, school_id, period) values(eid, st.id, st.school_id, p); end if;
      execute format('select coalesce(%I::text, '''') from ebda.pay2_effects where id = $1', k) into old using eid;
      if old = nv->>'v' or (f->>3 = 'num' and old <> '' and nv->>'v' <> '' and old::numeric = (nv->>'v')::numeric) then continue; end if;
      if f->>3 = 'num' then execute format('update ebda.pay2_effects set %I = nullif($1,'''')::numeric, updated_by = $2, updated_at = now()::text where id = $3', k) using nv->>'v', u.name, eid;
      else execute format('update ebda.pay2_effects set %I = $1, updated_by = $2, updated_at = now()::text where id = $3', k) using nv->>'v', u.name, eid; end if;
    end if;
    insert into ebda.pay2_log values(ebda.uid(), st.school_id, p, st.id, k, old, nv->>'v', 'edit', u.name, u.id, ebda.rk(u), now()::text);
    n := n + 1;
  end loop;
  -- تعديل بعد مراجعة المدير المالى من غيره يعيد الشهر لحالة «مسودة»
  if n > 0 and sh.status = 'reviewed' and ebda.rk(u) not in ('admin','finance_manager') then
    update ebda.pay2_sheets set status = 'draft', note = 'عُدّل بعد المراجعة بواسطة ' || u.name where id = sh.id;
  end if;
  -- v11.1: تجميع أيام الإجازات فى عمود الشهر · نقل ملاحظات المؤثرات للمدير المالى · توقيع تعديل أيام العمل المعتمدة
  if n > 0 then perform ebda.pay2_after_save(st.id, p, u, coalesce(req->'patch','{}'::jsonb)); end if;
  if n > 0 and btrim(coalesce(req->>'reason','')) <> '' then   -- v16: سبب التعديل مع كل قيمة سابقة/جديدة
    update ebda.pay2_log set note = btrim(req->>'reason') where staff_id = st.id and period = p and by_id = u.id and at = now()::text and coalesce(note,'') = ''; end if;
  if n = 0 and cardinality(denied) > 0 then return ebda.err('لا صلاحية لتعديل: ' || array_to_string(denied, '، ')); end if;
  if n = 0 and jsonb_array_length(errs) > 0 then return ebda.err(errs->>0); end if;
  return jsonb_build_object('ok', true, 'n', n, 'denied', to_jsonb(denied), 'errors', errs,
    'row', ebda.pay2_row((select x from ebda.pay2_staff x where x.id = st.id), p));
end $ps2$;


-- ================================================================ v10.9: شيت المؤثرات بعناوينه الأصلية · العام المالى · الاستبدال/الدمج · أرشيف واستعادة
alter table ebda.pay2_staff add column if not exists mobile text default '';
alter table ebda.pay2_staff add column if not exists ins_no text default '';
alter table ebda.pay2_staff add column if not exists national_id text default '';
alter table ebda.pay2_staff add column if not exists bank_account text default '';
alter table ebda.pay2_staff add column if not exists bank_name text default '';
alter table ebda.pay2_staff add column if not exists gross_salary numeric;
alter table ebda.pay2_staff add column if not exists total_cost numeric;
alter table ebda.pay2_effects add column if not exists net_after numeric;
alter table ebda.pay2_effects add column if not exists cost_after numeric;
alter table ebda.pay2_effects add column if not exists extra jsonb;      -- أعمدة إضافية فى الملف غير موجودة فى القالب: تُحفظ كما هى ولا تُهمل
alter table ebda.pay2_imports add column if not exists fy text default '';
alter table ebda.pay2_imports add column if not exists mode text default '';
alter table ebda.pay2_imports add column if not exists scope text default '';
alter table ebda.pay2_imports add column if not exists deleted int default 0;
alter table ebda.pay2_imports add column if not exists ignored int default 0;
alter table ebda.pay2_imports add column if not exists review int default 0;
alter table ebda.pay2_imports add column if not exists archive_id text default '';
alter table ebda.pay2_imports add column if not exists headers jsonb;
create table if not exists ebda.pay2_archive(
  id text primary key, import_id text default '', school_id text, fy text, scope text, periods text[], staff jsonb, effects jsonb, sheets jsonb,
  reason text default '', by_name text, by_id text, at text, restored_at text default '', restored_by text default '');
-- قواعد الحقول الجديدة (لا تغيّر ما ضبطه الأدمن)
update ebda.config set value = ((select jsonb_object_agg(f->>0, case f->>2 when 'base' then '[]'::jsonb when 'finance' then '["finance_manager"]'::jsonb else '["custody_officer","finance_manager"]'::jsonb end)
                                 from jsonb_array_elements(ebda.pay2_fields()) f) || value::jsonb)::text where key = 'pay2_field_rules';

create or replace function ebda.pay2_master(s ebda.pay2_staff) returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object('ins_status', s.ins_status, 'job', s.job, 'hire_date', s.hire_date,
     'mobile', s.mobile, 'ins_no', s.ins_no, 'national_id', s.national_id, 'bank_account', s.bank_account, 'bank_name', s.bank_name,
     'net_salary', s.net_salary::text, 'gross_salary', s.gross_salary::text, 'total_cost', s.total_cost::text, 'leave_balance', s.leave_balance::text)) || coalesce(s.months, '{}'::jsonb)
$$;
create or replace function ebda.pay2_nid(t text) returns text language sql immutable as $$
  select regexp_replace(translate(coalesce(t,''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g')
$$;
-- الكود يُعتبر معرّفاً ثابتاً فقط إن لم يكن رقماً مسلسلاً صغيراً (فى ملفات المدرستين عمود Code = 1، 2، 3 … مسلسل الصف)
create or replace function ebda.pay2_code_stable(c text) returns boolean language sql immutable as $$
  select btrim(coalesce(c,'')) <> '' and btrim(c) !~ '^[0-9]{1,3}(\.0+)?$'
$$;
-- العناوين المعتمدة بالترتيب (عنوانا الصفين للمجموعات) — للمقارنة بعناوين الملف
create or replace function ebda.pay2_template_headers() returns jsonb language sql immutable as $$
  select jsonb_agg(h order by o) from (
    select f->>1 h, (o * 10) o from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o)
    union all select 'الرصيد المتبقى', (select o * 10 - 5 from jsonb_array_elements(ebda.pay2_fields()) with ordinality t(f, o) where f->>0 = 'm07')) x
$$;
create or replace function ebda.pay2_hnorm(t text) returns text language sql immutable as $$
  select regexp_replace(translate(lower(coalesce(t,'')), 'أإآىة', 'اااىه'), '[\s—\-_()]+', '', 'g')
$$;
-- مقارنة عناوين الملف بالقالب: المطابق · الناقص · الإضافى · اختلاف الترتيب
create or replace function ebda.pay2_header_report(hdrs jsonb) returns jsonb language sql immutable as $$
  -- المطابقة بالعنوان (مع تجاهل المسافات/الأسطر) ثم بترتيب التكرار (العنوان «ملاحظات» يتكرر فى الملف)
  with t as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(ebda.pay2_template_headers()) with ordinality a(x, o)),
       f as (select x h, o, row_number() over (partition by ebda.pay2_hnorm(x) order by o) k from jsonb_array_elements_text(coalesce(hdrs,'[]'::jsonb)) with ordinality a(x, o)),
       m as (select t.h th, t.o tor, f.h fh, f.o fo from t join f on ebda.pay2_hnorm(t.h) = ebda.pay2_hnorm(f.h) and t.k = f.k)
  select jsonb_build_object(
    'template', ebda.pay2_template_headers(),
    'matched', (select count(*) from m),
    'missing', coalesce((select jsonb_agg(t.h order by t.o) from t where not exists(select 1 from m where m.tor = t.o)), '[]'::jsonb),
    'extra', coalesce((select jsonb_agg(f.h order by f.o) from f where not exists(select 1 from m where m.fo = f.o)), '[]'::jsonb),
    'renamed', coalesce((select jsonb_agg(jsonb_build_array(m.fh, m.th)) from m where btrim(m.fh) <> btrim(m.th)), '[]'::jsonb),
    'order_changed', exists(select 1 from m a join m b on a.tor < b.tor and a.fo > b.fo))
$$;

create or replace function ebda.pay2_archive_scope(u ebda.users, p_sid text, p_fy text, p_scope text, p_periods text[], p_reason text, p_imp text) returns text language plpgsql as $$
declare aid text := ebda.uid();
begin
  insert into ebda.pay2_archive(id, import_id, school_id, fy, scope, periods, staff, effects, sheets, reason, by_name, by_id, at)
  values(aid, p_imp, p_sid, p_fy, p_scope, p_periods,
    (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from ebda.pay2_staff s where s.school_id = p_sid and s.fy = p_fy),
    (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from ebda.pay2_effects e where e.school_id = p_sid and ebda.pay2_fy(e.period) = p_fy and (p_scope = 'fy' or e.period = any(p_periods))),
    (select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from ebda.pay2_sheets h where h.school_id = p_sid and ebda.pay2_fy(h.period) = p_fy and (p_scope = 'fy' or h.period = any(p_periods))),
    p_reason, u.name, u.id, now()::text);
  return aid;
end $$;

create or replace function ebda.pay2_can_replace(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and 'payroll.replace' = any(ebda.perms_of(u)))
$$;

-- مدرسة أخرى مذكورة فى اسم الورقة/الملف (لمنع تحميل المؤثرات على المدرسة الخطأ)
create or replace function ebda.pay2_lastword(n text) returns text language sql immutable as $$
  select (select x from unnest(regexp_split_to_array(btrim(regexp_replace(coalesce(n,''), '[-—–_()]', ' ', 'g')), '\s+')) with ordinality t(x, o) order by o desc limit 1)
$$;
create or replace function ebda.pay2_school_conflict(sid text, txt text) returns text language sql stable as $$
  select (select z.name from ebda.schools z where z.id <> sid and coalesce(z.cancelled_at,'') = '' and length(ebda.pay2_lastword(z.name)) > 2
                 and position(ebda.pay2_lastword(z.name) in coalesce(txt,'')) > 0 limit 1)
   where not exists(select 1 from ebda.schools z where z.id = sid and length(ebda.pay2_lastword(z.name)) > 2 and position(ebda.pay2_lastword(z.name) in coalesce(txt,'')) > 0)
$$;

-- استيراد شيت المؤثرات لمدرسة وعام مالى وشهر — معاينة ثم تنفيذ (دالة واحدة = عملية واحدة: أى خطأ يلغى كل شىء)
-- mode: merge (الاحتفاظ بالقديم + إضافة الجديد؛ المتكرر: update | keep | review لكل سجل) · replace (حذف بيانات المدرسة/العام [أو أشهر الملف] ثم الاستيراد، بعد أرشفتها)
-- الربط: تأكيد يدوى ← الرقم القومى ← الكود الثابت ← الاسم المطابق؛ الاسم المشابه للمراجعة. لا احتساب تلقائى لأى مؤثر مالى.
create or replace function ebda.pay2_import(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pi$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); v_fy text; is_new boolean; commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
  how text := coalesce(nullif(req->>'how',''), case when req->>'on_existing' = 'update' then 'merge' else '' end);
  scope text := coalesce(nullif(req->>'scope',''), 'months'); dup_default text := coalesce(nullif(req->>'dup_action',''), 'update');
  row_act jsonb := coalesce(req->'row_actions','{}'::jsonb); act text; dup boolean;
  sh ebda.pay2_sheets; rw jsonb; f jsonb; k text; nv jsonb; st ebda.pay2_staff; i int := 0; rep jsonb := '[]'::jsonb; row_errs jsonb; row_notes jsonb;
  nadd int := 0; nupd int := 0; nsame int := 0; nrej int := 0; nrev int := 0; nign int := 0; ndel_s int := 0; ndel_e int := 0;
  keys text[] := '{}'; used text[] := '{}'; nk text; cd text; nid text; changed int; diffs jsonb; eid text; old text; sim_st ebda.pay2_staff;
  hdr jsonb; prior ebda.pay2_imports; n_existing int; conflict text; other_school text; links jsonb := coalesce(req->'confirm_links','{}'::jsonb);
  aid text := ''; iid text := ebda.uid(); periods text[] := array[p]; fy_ok boolean;
begin
  if p !~ '^\d{4}-(0[1-9]|1[0-2])$' then return ebda.err('اختر الشهر والسنة'); end if;
  if ebda.rk(u) = 'observer' or not (ebda.rk(u) = 'admin' or ebda.can(u,'payroll.import')) then return ebda.err('لا صلاحية لاستيراد الرواتب'); end if;
  if not exists(select 1 from ebda.schools where id = sid) then return ebda.err('اختر المدرسة'); end if;
  if not ebda.can_school(u, sid) then return ebda.err('الجهة ليست ضمن نطاقك'); end if;
  if jsonb_array_length(coalesce(req->'rows','[]'::jsonb)) > 2000 then return ebda.err('2000 صف كحد أقصى'); end if;
  v_fy := ebda.pay2_fy(p);
  -- العام المالى المختار: من الأعوام المسجلة، والشهر داخله
  if coalesce(req->>'fy','') <> '' then
    if req->>'fy' <> v_fy then return ebda.err('الشهر ' || p || ' خارج العام المالى المختار ' || (req->>'fy')); end if;
    select exists(select 1 from ebda.fiscal_years y where to_char(y.start_date::date,'YYYY') || '-' || to_char(y.end_date::date,'YYYY') = v_fy) into fy_ok;
    if not fy_ok then return ebda.err('العام المالى ' || (req->>'fy') || ' غير مسجل على السيستم'); end if;
  end if;
  if how not in ('', 'merge', 'replace') or scope not in ('months','fy') or dup_default not in ('update','keep','review') then return ebda.err('طريقة معالجة غير صحيحة'); end if;
  if how = 'replace' and not ebda.pay2_can_replace(u) then return ebda.err('استبدال البيانات (الحذف ثم الاستيراد) للأدمن أو بصلاحية «payroll.replace»'); end if;
  conflict := ebda.pay2_school_conflict(sid, coalesce(req->>'sheet','') || ' ' || coalesce(req->>'file',''));
  if conflict is not null then return ebda.err('الملف/الورقة تخص «' || conflict || '» — لا تُحمَّل مؤثراتها على مدرسة أخرى. اختر المدرسة الصحيحة'); end if;
  if not (coalesce(req->'columns','[]'::jsonb) ? 'name') then return ebda.err('عمود «الاسم» غير موجود — الملف لا يطابق القالب'); end if;
  hdr := ebda.pay2_header_report(coalesce(req->'headers', '[]'::jsonb));
  if commit_ and jsonb_typeof(req->'headers') = 'array' and (jsonb_array_length(hdr->'missing') > 0 or jsonb_array_length(hdr->'extra') > 0 or (hdr->>'order_changed')::boolean)
     and coalesce(req->>'ack_headers','') <> 'true' then
    return ebda.err('عناوين الملف تختلف عن القالب المعتمد — راجع الاختلافات وأكّد قبل الاستيراد'); end if;
  sh := case when commit_ then ebda.pay2_sheet(sid, p) else (select x from ebda.pay2_sheets x where x.school_id = sid and x.period = p) end;
  if coalesce(sh.status,'') in ('approved','fin_approved') then return ebda.err('مؤثرات هذا الشهر معتمدة مالياً — لا استيراد إلا بعد إعادة الفتح'); end if;
  select * into prior from ebda.pay2_imports where school_id = sid and period = p and coalesce(action,'') not in ('failed','delete') order by at desc limit 1;
  select count(*) into n_existing from ebda.pay2_effects where school_id = sid and period = p;
  -- ما سيُحذف عند الاستبدال
  if how = 'replace' then
    if scope = 'fy' then
      select count(*) into ndel_s from ebda.pay2_staff where school_id = sid and fy = v_fy;
      select count(*) into ndel_e from ebda.pay2_effects where school_id = sid and ebda.pay2_fy(period) = v_fy;
      if exists(select 1 from ebda.pay2_sheets h where h.school_id = sid and ebda.pay2_fy(h.period) = v_fy and h.status in ('approved','fin_approved')) then
        return ebda.err('يوجد شهر معتمد فى هذا العام المالى — لا استبدال إلا بعد إعادة فتحه'); end if;
    else
      select count(*) into ndel_e from ebda.pay2_effects where school_id = sid and period = any(periods);
    end if;
  end if;
  if commit_ and how = '' and (prior.id is not null or n_existing > 0) then
    return ebda.err('مؤثرات هذا الشهر سبق استيرادها — اختر «دمج» أو «استبدال» للمتابعة أو ألغِ العملية'); end if;
  -- الاستبدال: أرشفة ثم حذف نطاق المدرسة/العام فقط (داخل نفس العملية؛ يُستورد الملف بعدها كبيانات جديدة)
  if commit_ and how = 'replace' then
    aid := ebda.pay2_archive_scope(u, sid, v_fy, scope, periods, 'قبل الاستبدال باستيراد «' || coalesce(req->>'file','') || '»', iid);
    if scope = 'fy' then
      delete from ebda.pay2_effects where school_id = sid and ebda.pay2_fy(period) = v_fy;
      delete from ebda.pay2_staff where school_id = sid and fy = v_fy;
    else
      delete from ebda.pay2_effects where school_id = sid and period = any(periods);
    end if;
  end if;
  for rw in select * from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) loop
    i := i + 1; is_new := false; row_errs := '[]'::jsonb; row_notes := '[]'::jsonb; changed := 0; diffs := '[]'::jsonb; st := null; sim_st := null; other_school := null; dup := false;
    nk := ebda.pay2_key(rw->>'name'); cd := btrim(coalesce(rw->>'code','')); nid := ebda.pay2_nid(rw->>'national_id');
    if nk = '' then continue; end if;
    -- مفتاح التكرار داخل الملف: الرقم القومى ثم الكود الثابت ثم الاسم (الموظف له سجل واحد فى شيت الشهر)
    if (nid <> '' and ('#n' || nid) = any(keys)) or (ebda.pay2_code_stable(cd) and ('#c' || cd) = any(keys)) or (nid = '' and nk = any(keys)) then nrev := nrev + 1;
      rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'errors', jsonb_build_array('الموظف مكرر فى الملف لنفس الشهر — للمراجعة، لم يُستورد التكرار')); continue; end if;
    keys := keys || nk; if nid <> '' then keys := keys || ('#n' || nid); end if; if ebda.pay2_code_stable(cd) then keys := keys || ('#c' || cd); end if;
    for f in select * from jsonb_array_elements(ebda.pay2_fields()) loop
      if rw ? (f->>0) then nv := ebda.pay2_val(f->>3, rw->>(f->>0));
        if not (nv->>'ok')::boolean then row_errs := row_errs || to_jsonb(f->>1 || ': ' || (nv->>'err')); end if; end if;
    end loop;
    if links ? (rw->>'_row') then
      select * into st from ebda.pay2_staff where id = links->>(rw->>'_row') and school_id = sid and fy = v_fy;
      if st.id is null then row_errs := row_errs || to_jsonb('الموظف المختار للربط ليس من نفس المدرسة/العام المالى'::text);
      else row_notes := row_notes || to_jsonb('رُبط يدوياً بالموظف «' || st.name || '» (الاسم المسجل لم يُغيَّر)'); end if;
    end if;
    if st.id is null and nid <> '' then
      select * into st from ebda.pay2_staff where school_id = sid and fy = v_fy and ebda.pay2_nid(national_id) = nid;
      if st.id is null then
        select z.name into other_school from ebda.pay2_staff x join ebda.schools z on z.id = x.school_id where x.fy = v_fy and ebda.pay2_nid(x.national_id) = nid and x.school_id <> sid limit 1;
        if other_school is not null then row_errs := row_errs || to_jsonb('الرقم القومى مسجل لموظف فى «' || other_school || '» — لا يُحمَّل على مدرسة أخرى'); end if;
      elsif st.name_key <> nk then row_notes := row_notes || to_jsonb('رُبط بالرقم القومى — الاسم المسجل «' || st.name || '» يختلف عن الملف ولم يُغيَّر'); end if;
    end if;
    if st.id is null and jsonb_array_length(row_errs) = 0 and ebda.pay2_code_stable(cd) then
      select * into st from ebda.pay2_staff where school_id = sid and fy = v_fy and (code = cd or emp_uid = cd) limit 1;   -- v12: Code التلقائى (المصدَّر) أو كود الملف
      if st.id is null then
        select z.name into other_school from ebda.pay2_staff x join ebda.schools z on z.id = x.school_id where x.fy = v_fy and x.code = cd and x.school_id <> sid limit 1;
        if other_school is not null then row_errs := row_errs || to_jsonb('الكود ' || cd || ' مسجل لموظف فى «' || other_school || '» — لا يُحمَّل على مدرسة أخرى'); end if;
      elsif nid <> '' and ebda.pay2_nid(st.national_id) <> '' and ebda.pay2_nid(st.national_id) <> nid then
        nrev := nrev + 1;
        rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'errors', jsonb_build_array('نفس الكود لكن الرقم القومى مختلف — يحتاج مراجعة'),
          'suggest', jsonb_build_object('id', st.id, 'name', st.name, 'code', st.code)); continue;
      elsif st.name_key <> nk then row_notes := row_notes || to_jsonb('رُبط بالكود ' || cd || ' — الاسم المسجل «' || st.name || '» يختلف عن الملف ولم يُغيَّر'); end if;
    end if;
    if st.id is null and jsonb_array_length(row_errs) = 0 then
      select * into st from ebda.pay2_staff where school_id = sid and fy = v_fy and name_key = nk;
      if st.id is not null and ((nid <> '' and ebda.pay2_nid(st.national_id) <> '' and ebda.pay2_nid(st.national_id) <> nid)
                                or (ebda.pay2_code_stable(cd) and ebda.pay2_code_stable(st.code) and st.code <> cd)) then
        nrev := nrev + 1;
        rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'errors', jsonb_build_array('نفس الاسم لكن الرقم القومى/الكود مختلف — قد يكونا موظفين مختلفين. يحتاج مراجعة'),
          'suggest', jsonb_build_object('id', st.id, 'name', st.name, 'code', st.code)); continue; end if;
    end if;
    if st.id is null and jsonb_array_length(row_errs) = 0 then
      select * into sim_st from ebda.pay2_staff where school_id = sid and fy = v_fy and ebda.pay2_loose(name) = ebda.pay2_loose(nk) limit 1;
      if sim_st.id is not null then
        nrev := nrev + 1;
        rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'errors', jsonb_build_array('لم يُتعرَّف على الموظف — يوجد اسم مشابه مسجل «' || sim_st.name || '». يحتاج مراجعة قبل الربط'),
          'suggest', jsonb_build_object('id', sim_st.id, 'name', sim_st.name, 'code', sim_st.code)); continue; end if;
    end if;
    if st.id is not null and st.id = any(used) then row_errs := row_errs || to_jsonb('سجلان فى الملف مرتبطان بنفس الموظف'::text); end if;
    if jsonb_array_length(row_errs) > 0 then nrej := nrej + 1;
      rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'rejected', 'errors', row_errs, 'notes', row_notes); continue; end if;
    if st.id is null and not ebda.pay2_field_ok(u, 'name') then nrev := nrev + 1;
      rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'errors', jsonb_build_array('غير مسجل على السيستم — لا يمكن ربطه بموظف (إضافة الموظفين تحتاج صلاحية البيانات الأساسية)')); continue; end if;
    if coalesce(btrim(rw->>'hire_date'),'') = '' then row_notes := row_notes || to_jsonb('تاريخ التعيين فارغ فى الملف'::text); end if;
    -- السجل المتكرر (موظف له سجل لنفس المدرسة/الشهر): الاختلافات أولاً
    if st.id is not null and exists(select 1 from ebda.pay2_effects e where e.staff_id = st.id and e.period = p) then dup := true; end if;
    for f in select * from jsonb_array_elements(ebda.pay2_fields()) loop
      k := f->>0;
      if st.id is null or k = 'name' or not (rw ? k) then continue; end if;
      if k = 'code' and (cd = '' or cd = coalesce(st.emp_uid,'') or coalesce(st.code,'') <> '') then continue; end if;
      nv := ebda.pay2_val(f->>3, rw->>k);
      old := case when k = 'code' then coalesce(st.code,'') when f->>4 = 'staff' then coalesce(ebda.pay2_view(st, p)->>k,'')
                  else coalesce((select to_jsonb(e)->>k from ebda.pay2_effects e where e.staff_id = st.id and e.period = p), '') end;
      if old = nv->>'v' or (f->>3 = 'num' and old <> '' and nv->>'v' <> '' and old::numeric = (nv->>'v')::numeric) then continue; end if;
      diffs := diffs || jsonb_build_array(jsonb_build_array(f->>1, old, nv->>'v'));
    end loop;
    act := case when not dup or jsonb_array_length(diffs) = 0 then 'update' else coalesce(row_act->>(rw->>'_row'), dup_default) end;
    if act = 'keep' then nign := nign + 1;
      rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'ignored', 'dup', true, 'diffs', diffs, 'notes', row_notes || to_jsonb('سجل موجود — احتُفظ بالبيانات القديمة وتُجوهل سجل الملف'::text)); continue; end if;
    if act = 'review' then nrev := nrev + 1;
      rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'status', 'review', 'dup', true, 'diffs', diffs, 'errors', jsonb_build_array('سجل موجود مختلف — تُرك للمراجعة دون تغيير')); continue; end if;
    if st.id is null then
      is_new := true;
      if commit_ then
        insert into ebda.pay2_staff(id, school_id, fy, name, name_key, code, sort, created_by) values(ebda.uid(), sid, v_fy, nk, nk, case when cd ~* '^EMP-[0-9]+$' then '' else cd end, i, u.name) returning * into st;
        insert into ebda.pay2_log values(ebda.uid(), sid, p, st.id, 'name', '', nk, 'import', u.name, u.id, ebda.rk(u), now()::text);
      end if;
      nadd := nadd + 1;
    end if;
    if st.id is not null then used := used || st.id; end if;
    for f in select * from jsonb_array_elements(ebda.pay2_fields()) loop
      k := f->>0;
      if k = 'name' or not (rw ? k) then continue; end if;
      if k = 'code' and (is_new or cd = '' or cd = coalesce(st.emp_uid,'') or coalesce(st.code,'') <> '') then continue; end if;
      nv := ebda.pay2_val(f->>3, rw->>k);
      if st.id is null then old := '';
      elsif f->>4 = 'staff' then old := case when k = 'code' then coalesce(st.code,'') else coalesce(ebda.pay2_view(st, p)->>k,'') end;
      else old := coalesce((select to_jsonb(e)->>k from ebda.pay2_effects e where e.staff_id = st.id and e.period = p), ''); end if;
      if old = nv->>'v' or (f->>3 = 'num' and old <> '' and nv->>'v' <> '' and old::numeric = (nv->>'v')::numeric) then continue; end if;
      if not (ebda.pay2_field_ok(u, k) and ebda.pay2_edit_ok(u, k, f->>2, coalesce(sh.status,'draft'), p)) then
        if nv->>'v' <> '' or old <> '' then row_notes := row_notes || to_jsonb('«' || (f->>1) || '» حقل غير مسموح لك — لم يُغيَّر'); end if;
        continue; end if;
      changed := changed + 1;
      if commit_ then
        if k = 'code' then update ebda.pay2_staff set code = nv->>'v' where id = st.id;
        elsif f->>4 = 'staff' then
          perform ebda.pay2_set_staff(st.id, p, k, nv->>'v', f->>3, u.name);
          if k = 'hire_date' then update ebda.pay2_staff set hire_raw = coalesce(rw->>'hire_raw','') where id = st.id; end if;
        else
          select id into eid from ebda.pay2_effects where staff_id = st.id and period = p;
          if eid is null then
            update ebda.pay2_effects set snap = ebda.pay2_master(st) where staff_id = st.id and snap is null;
            eid := ebda.uid(); insert into ebda.pay2_effects(id, staff_id, school_id, period, snap) values(eid, st.id, sid, p, ebda.pay2_master((select x from ebda.pay2_staff x where x.id = st.id)));
          end if;
          if f->>3 = 'num' then execute format('update ebda.pay2_effects set %I = nullif($1,'''')::numeric, updated_by = $2, updated_at = now()::text where id = $3', k) using nv->>'v', u.name, eid;
          else execute format('update ebda.pay2_effects set %I = $1, updated_by = $2, updated_at = now()::text where id = $3', k) using nv->>'v', u.name, eid; end if;
          eid := null;
        end if;
        insert into ebda.pay2_log values(ebda.uid(), sid, p, st.id, k, old, nv->>'v', 'import', u.name, u.id, ebda.rk(u), now()::text);
      end if;
    end loop;
    if commit_ and st.id is not null and not exists(select 1 from ebda.pay2_effects e where e.staff_id = st.id and e.period = p) then
      update ebda.pay2_effects set snap = ebda.pay2_master(st) where staff_id = st.id and snap is null;
      insert into ebda.pay2_effects(id, staff_id, school_id, period, snap, updated_by, updated_at)
      values(ebda.uid(), st.id, sid, p, ebda.pay2_master((select x from ebda.pay2_staff x where x.id = st.id)), u.name, now()::text);
    end if;
    -- أعمدة إضافية فى الملف: تُحفظ كما هى مع سجل الشهر
    -- v11: معادلة «رصيد الأجازات» كما فى الملف (تُعاد فى التصدير)
    if commit_ and st.id is not null and coalesce(rw->>'leave_balance_f','') ~ '^=[0-9.+*/() -]{1,80}$' and ebda.pay2_field_ok(u, 'leave_balance') then
      perform ebda.pay2_set_staff(st.id, p, 'leave_balance_f', rw->>'leave_balance_f', 'text', u.name);
    end if;
    if commit_ and st.id is not null and jsonb_typeof(rw->'extra') = 'object' and rw->'extra' <> '{}'::jsonb then
      update ebda.pay2_effects set extra = coalesce(extra,'{}'::jsonb) || (rw->'extra') where staff_id = st.id and period = p;
    end if;
    if commit_ and changed > 0 then update ebda.pay2_staff set updated_by = u.name, updated_at = now()::text, sort = i where id = st.id; end if;
    if commit_ and st.id is not null then perform ebda.pay2_after_save(st.id, p, u, rw); end if;
    rep := rep || jsonb_build_object('row', rw->>'_row', 'name', nk, 'code', cd, 'dup', dup, 'diffs', diffs,
      'status', case when is_new then 'new' when changed > 0 then 'updated' else 'unchanged' end, 'changed', changed, 'notes', row_notes);
    if not is_new then if changed > 0 then nupd := nupd + 1; else nsame := nsame + 1; end if; end if;
  end loop;
  -- الاستبدال لا يُنفَّذ إن كان فى الملف ما لا يمكن استيراده (حتى لا تُحذف بيانات ولا يحل محلها شىء)
  if how = 'replace' and (nrej > 0 or nrev > 0) then
    if commit_ then raise exception 'pay2_replace_blocked'; end if;
  end if;
  if commit_ then
    insert into ebda.pay2_imports(id, school_id, period, file, sheet, by_name, by_id, at, added, updated, unchanged, rejected, report, action, fy, mode, scope, deleted, ignored, review, archive_id, headers)
    values(iid, sid, p, coalesce(req->>'file',''), coalesce(req->>'sheet',''), u.name, u.id, now()::text, nadd, nupd, nsame, nrej, rep,
           case when how = 'replace' then 'replace' when prior.id is not null or n_existing > 0 then 'update' else 'new' end, v_fy,
           coalesce(nullif(how,''), 'new'), case when how = 'replace' then scope else '' end, ndel_e, nign, nrev, aid, hdr);
    if sh.status = 'reviewed' and ebda.rk(u) not in ('admin','finance_manager') then update ebda.pay2_sheets set status = 'draft', note = 'استيراد بعد المراجعة بواسطة ' || u.name where id = sh.id; end if;
  end if;
  return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'fy', v_fy, 'period', p, 'how', how, 'scope', scope,
    'school', (select name from ebda.schools where id = sid), 'employees', i, 'headers', case when jsonb_typeof(req->'headers') = 'array' then hdr end, 'can_replace', ebda.pay2_can_replace(u),
    'already', case when prior.id is not null or n_existing > 0 then jsonb_build_object('at', prior.at, 'by', prior.by_name, 'file', prior.file, 'records', n_existing) end,
    'to_delete', jsonb_build_object('staff', ndel_s, 'records', ndel_e),
    'not_in_file', coalesce((select jsonb_agg(x.name order by x.name) from ebda.pay2_staff x join ebda.pay2_effects e on e.staff_id = x.id and e.period = p
                             where x.school_id = sid and x.fy = v_fy and not (x.id = any(used))), '[]'::jsonb),
    'replace_blocked', how = 'replace' and (nrej > 0 or nrev > 0),
    'added', nadd, 'updated', nupd, 'unchanged', nsame, 'rejected', nrej, 'review', nrev, 'ignored', nign, 'missing_columns', case when jsonb_typeof(req->'headers') = 'array' then hdr->'missing' else '[]'::jsonb end, 'rows', rep, 'import_id', case when commit_ then iid end);
exception when raise_exception then
  if sqlerrm = 'pay2_replace_blocked' then
    return ebda.err('لم يُنفَّذ الاستبدال: فى الملف سجلات بها أخطاء أو تحتاج مراجعة — صحّحها أو اختر «دمج». لم يُحذف أى شىء'); end if;
  raise;
end $pi$;

-- استعادة بيانات مؤرشفة (قبل استبدال) — للأدمن؛ الحالة الحالية تُؤرشف أولاً فتكون الاستعادة نفسها قابلة للرجوع
create or replace function ebda.pay2_restore(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pr2$
declare a ebda.pay2_archive; aid text;
begin
  if ebda.rk(u) <> 'admin' then return ebda.err('استعادة بيانات الرواتب المؤرشفة للأدمن فقط'); end if;
  select * into a from ebda.pay2_archive where id = req->>'archive_id' for update;
  if not found then return ebda.err('النسخة غير موجودة'); end if;
  if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الاستعادة'); end if;
  aid := ebda.pay2_archive_scope(u, a.school_id, a.fy, a.scope, a.periods, 'قبل الاستعادة من نسخة ' || a.at || ' — ' || btrim(req->>'reason'), '');
  if a.scope = 'fy' then
    delete from ebda.pay2_effects where school_id = a.school_id and ebda.pay2_fy(period) = a.fy;
    delete from ebda.pay2_staff where school_id = a.school_id and fy = a.fy;
    insert into ebda.pay2_staff select * from jsonb_populate_recordset(null::ebda.pay2_staff, a.staff);
  else
    delete from ebda.pay2_effects where school_id = a.school_id and period = any(a.periods);
    insert into ebda.pay2_staff select * from jsonb_populate_recordset(null::ebda.pay2_staff, a.staff) on conflict (id) do nothing;
  end if;
  insert into ebda.pay2_effects select * from jsonb_populate_recordset(null::ebda.pay2_effects, a.effects);
  update ebda.pay2_archive set restored_at = now()::text, restored_by = u.name where id = a.id;
  insert into ebda.pay2_log values(ebda.uid(), a.school_id, coalesce(a.periods[1],''), '', '_restore', a.at, btrim(req->>'reason'), 'restore', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true, 'staff', jsonb_array_length(a.staff), 'records', jsonb_array_length(a.effects), 'backup_of_current', aid);
end $pr2$;

-- سجل عمليات الاستيراد (حسب الصلاحية) — المدرسة · العام المالى · الشهر · الملف · الطريقة · النتيجة · المستخدم · الوقت
create or replace function ebda.pay2_imports_list(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $pil$
begin
  if coalesce(req->>'id','') <> '' then
    if not exists(select 1 from ebda.pay2_imports i where i.id = req->>'id' and ebda.pay2_view_ok(u, i.school_id)) then return ebda.err('لا صلاحية'); end if;
    return (select jsonb_build_object('ok', true, 'report', i.report, 'headers', i.headers) from ebda.pay2_imports i where i.id = req->>'id');
  end if;
  return jsonb_build_object('ok', true, 'can_restore', ebda.rk(u) = 'admin', 'can_delete', ebda.pay2_can_delete(u), 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'school', z.name, 'school_id', i.school_id, 'period', i.period,
      'fy', coalesce(nullif(i.fy,''), ebda.pay2_fy(i.period)), 'file', i.file, 'sheet', i.sheet, 'mode', coalesce(i.mode,''), 'scope', coalesce(i.scope,''),
      'by', i.by_name, 'at', i.at, 'added', i.added, 'updated', i.updated, 'unchanged', i.unchanged, 'rejected', i.rejected, 'deleted', coalesce(i.deleted,0),
      'ignored', coalesce(i.ignored,0), 'review', coalesce(i.review,0), 'action', coalesce(i.action,''), 'archive_id', coalesce(i.archive_id,''),
      'restored', (select a.restored_at from ebda.pay2_archive a where a.id = i.archive_id),
      'reason', case when i.action = 'failed' then i.report->0->'errors'->>0 when i.action = 'delete' then i.sheet else '' end) order by i.at desc)
    from ebda.pay2_imports i join ebda.schools z on z.id = i.school_id
    where ebda.pay2_view_ok(u, i.school_id) and (coalesce(req->>'school_id','') = '' or i.school_id = req->>'school_id')
      and (coalesce(req->>'fy','') = '' or coalesce(nullif(i.fy,''), ebda.pay2_fy(i.period)) = req->>'fy')), '[]'::jsonb));
end $pil$;




create or replace function ebda.pay2_status(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pst$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); sh ebda.pay2_sheets; ns text := coalesce(req->>'status',''); nt text := btrim(coalesce(req->>'note',''));
begin
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  if not ebda.can_school(u, sid) or ebda.rk(u) = 'observer' then return ebda.err('لا صلاحية'); end if;
  sh := ebda.pay2_sheet(sid, p);
  select * into sh from ebda.pay2_sheets where id = sh.id for update;
  if ns = 'reviewed' then
    if ebda.rk(u) not in ('admin','finance_manager') then return ebda.err('مراجعة المؤثرات للمدير المالى'); end if;
    if sh.status <> 'draft' then return ebda.err('الحالة الحالية لا تسمح بالمراجعة'); end if;
    if not exists(select 1 from ebda.pay2_staff x where x.school_id = sid and x.fy = ebda.pay2_fy(p)) then return ebda.err('لا توجد بيانات للمراجعة'); end if;
    update ebda.pay2_sheets set status = 'reviewed', reviewed_by = u.name, reviewed_at = now()::text, note = nt where id = sh.id;
  elsif ns = 'approved' then
    if not (ebda.rk(u) = 'admin' or 'gm.approve' = any(ebda.perms_of(u))) then return ebda.err('اعتماد المؤثرات للأدمن/المدير العام'); end if;
    if sh.status <> 'reviewed' then return ebda.err('يُعتمد الشهر بعد مراجعة المدير المالى'); end if;
    update ebda.pay2_sheets set status = 'approved', approved_by = u.name, approved_at = now()::text, note = nt where id = sh.id;
  elsif ns = 'draft' then
    if sh.status = 'approved' and ebda.rk(u) <> 'admin' then return ebda.err('إعادة فتح شهر معتمد للأدمن فقط'); end if;
    if sh.status = 'reviewed' and ebda.rk(u) not in ('admin','finance_manager') then return ebda.err('لا صلاحية'); end if;
    if length(nt) < 3 then return ebda.err('اكتب سبب إعادة الفتح/الإرجاع'); end if;
    update ebda.pay2_sheets set status = 'draft', note = nt where id = sh.id;
  else return ebda.err('حالة غير صحيحة'); end if;
  insert into ebda.pay2_log values(ebda.uid(), sid, p, '', '_status', sh.status, ns || case when nt <> '' then ' — ' || nt else '' end, 'status', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true, 'status', ns);
end $pst$;

create or replace function ebda.pay2_add(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pa$
declare sid text := coalesce(req->>'school_id',''); p text := coalesce(req->>'period',''); nk text := ebda.pay2_key(req#>>'{patch,name}'); nid text; r jsonb;
begin
  if p !~ '^\d{4}-\d{2}$' then return ebda.err('اختر الشهر'); end if;
  if not ebda.can_school(u, sid) or not ebda.pay2_field_ok(u, 'name') then return ebda.err('إضافة موظف تحتاج صلاحية البيانات الأساسية'); end if;
  if nk = '' then return ebda.err('اكتب الاسم'); end if;
  if exists(select 1 from ebda.pay2_staff where school_id = sid and fy = ebda.pay2_fy(p) and name_key = nk) then return ebda.err('الموظف موجود بالفعل'); end if;
  if coalesce((select status from ebda.pay2_sheets where school_id = sid and period = p),'') in ('approved','fin_approved') then return ebda.err('الشهر معتمد مالياً'); end if;
  if ebda.pay2_locked((select status from ebda.pay2_sheets where school_id = sid and period = p)) and ebda.rk(u) <> 'admin' then return ebda.err('الشهر معتمد من المدير المباشر — الإضافة بطلب تعديل للأدمن'); end if;
  nid := ebda.uid();
  insert into ebda.pay2_staff(id, school_id, fy, name, name_key, sort, created_by) values(nid, sid, ebda.pay2_fy(p), nk, nk,
    coalesce((select max(sort) + 1 from ebda.pay2_staff where school_id = sid and fy = ebda.pay2_fy(p)), 1), u.name);
  insert into ebda.pay2_log values(ebda.uid(), sid, p, nid, 'name', '', nk, 'add', u.name, u.id, ebda.rk(u), now()::text);
  r := ebda.pay2_save(u, jsonb_build_object('id', nid, 'period', p, 'patch', coalesce(req->'patch','{}'::jsonb) - 'name'));
  return jsonb_build_object('ok', true, 'id', nid, 'row', ebda.pay2_row((select x from ebda.pay2_staff x where x.id = nid), p));
end $pa$;

create or replace function ebda.pay2_remove(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pr$
declare st ebda.pay2_staff; p text := coalesce(req->>'period','');
begin
  select * into st from ebda.pay2_staff where id = req->>'id' for update;
  if not found then return ebda.err('الموظف غير موجود'); end if;
  if not ebda.can_school(u, st.school_id) or not ebda.pay2_field_ok(u, 'name') then return ebda.err('لا صلاحية'); end if;
  if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب السبب'); end if;
  update ebda.pay2_staff set active = 'لا', updated_by = u.name, updated_at = now()::text where id = st.id;   -- لا حذف فعلى
  insert into ebda.pay2_log values(ebda.uid(), st.school_id, p, st.id, 'active', 'نعم', 'لا — ' || btrim(req->>'reason'), 'edit', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true);
end $pr$;

create or replace function ebda.pay2_rules(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $prl$
declare r jsonb; k text; v jsonb;
begin
  if coalesce(req->>'mode','get') in ('set','commit') then
    if ebda.rk(u) <> 'admin' then return ebda.err('ضبط صلاحيات الحقول للأدمن فقط'); end if;
    r := '{}'::jsonb;
    for k, v in select * from jsonb_each(coalesce(req->'rules','{}'::jsonb)) loop
      if not exists(select 1 from jsonb_array_elements(ebda.pay2_fields()) f where f->>0 = k) then return ebda.err('حقل غير معروف: ' || k); end if;
      if jsonb_typeof(v) <> 'array' or exists(select 1 from jsonb_array_elements_text(v) x where x not in ('custody_officer','finance_manager','direct_manager')) then
        return ebda.err('أدوار غير صحيحة للحقل ' || k); end if;
      r := r || jsonb_build_object(k, v);
    end loop;
    update ebda.config set value = ((select value::jsonb from ebda.config where key = 'pay2_field_rules') || r)::text where key = 'pay2_field_rules';
  end if;
  return jsonb_build_object('ok', true, 'fields', ebda.pay2_fields(), 'rules', (select value::jsonb from ebda.config where key = 'pay2_field_rules'));
end $prl$;

create or replace function ebda.pay2_history(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $ph$
declare sid text := coalesce(req->>'school_id','');
begin
  if not ebda.pay2_view_ok(u, sid) then return ebda.err('لا صلاحية'); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object('field', l.field, 'old', l.old_value, 'new', l.new_value, 'source', l.source,
      'by', l.by_name, 'role', l.by_role, 'at', l.at, 'name', coalesce((select s.name from ebda.pay2_staff s where s.id = l.staff_id), '')) order by l.at desc)
    from (select * from ebda.pay2_log l where l.school_id = sid and (coalesce(req->>'period','') = '' or l.period = req->>'period')
            and (coalesce(req->>'staff_id','') = '' or l.staff_id = req->>'staff_id') order by l.at desc limit 500) l), '[]'::jsonb));
end $ph$;

-- ================================================================ v10.9: مركز التقارير — بيانات فعلية حسب صلاحية المستخدم ونطاقه
-- كل مجموعة بيانات تُرجع صفوفاً بمفاتيح ثابتة؛ التخصيص (الحقول/الترتيب/التجميع/الإجماليات) فى الواجهة على نفس الصفوف — لا تكرار للمبالغ:
-- كل صف = سجل واحد من جدوله (مصروف واحد، عهدة واحدة، بند واحد، صنف طلب واحد، سجل شهر لموظف واحد).
create table if not exists ebda.rc_saved(id text primary key, owner_id text, owner_name text, name text not null, config jsonb not null,
  shared text default 'لا', created_at text default now()::text, updated_at text default '', last_run_at text default '');

create or replace function ebda.rc_stage_label(s text) returns text language sql immutable as $$
  select case s when 'draft' then 'مسودة' when 'returned' then 'معاد للتعديل (المدير المباشر)' when 'rejected' then 'مرفوض (المدير المباشر)'
    when 'pending_manager' then 'بانتظار المدير المباشر' when 'settled' then 'مسوّى' when 'fin_rejected' then 'مرفوض مالياً' when 'fin_returned' then 'معاد للتعديل (المالى)'
    when 'reviewed' then 'معتمد مالياً' when 'pending_finance' then 'بانتظار المدير المالى' when 'cancelled' then 'ملغى' else coalesce(s,'') end
$$;
create or replace function ebda.rc_dec_label(s text) returns text language sql immutable as $$
  select case coalesce(s,'') when 'approved' then 'موافق' when 'rejected' then 'مرفوض' when 'returned' then 'معاد للاستكمال' when 'resubmitted' then 'أُعيد الإرسال'
    when 'pending' then 'بانتظار المراجعة' when 'draft' then 'مسودة' when 'review' then 'قيد المراجعة' when '' then 'لم يُراجع' else s end
$$;
create or replace function ebda.rc_in(v text, arr jsonb) returns boolean language sql immutable as $$
  select arr is null or jsonb_typeof(arr) <> 'array' or jsonb_array_length(arr) = 0 or arr ? coalesce(v,'')
$$;

create or replace function ebda.rc_data(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $rc$
declare k text := coalesce(req->>'kind',''); f jsonb := coalesce(req->'filters','{}'::jsonb);
  d1 text := coalesce(nullif(f->>'date_from',''), '0000-01-01'); d2 text := coalesce(nullif(f->>'date_to',''), '9999-12-31');
  sch jsonb := f->'school_ids'; cus jsonb := f->'custody_ids'; lns jsonb := f->'line_ids'; sup jsonb := f->'suppliers'; ppl jsonb := f->'people';
  rows jsonb; can_audit boolean := ebda.rk(u) in ('admin','observer') or 'audit.view' = any(ebda.perms_of(u));
begin
  if k = 'expenses' then
    select coalesce(jsonb_agg(x order by x->>'date', x->>'txn_no'), '[]'::jsonb) into rows from (
      select jsonb_build_object('id', e.id, 'date', left(e.date,10), 'month', left(e.date,7), 'txn_no', e.txn_no, 'school_id', e.school_id, 'school', z.name,
        'custody_id', e.custody_id, 'custody', c.code, 'custody_name', ebda.custody_name(c.title, c.label, c.code), 'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label),
        'line_id', e.line_id, 'line', l.name, 'section', l.section, 'item', coalesce(nullif(e.src_item,''), e.description), 'description', e.description,
        'supplier', coalesce(e.supplier,''), 'amount', e.amount, 'stage', ebda.rc_stage_label(ebda.expense_stage(e)),
        'mgr', ebda.rc_dec_label(e.approval), 'fin', ebda.rc_dec_label(e.fin_approval), 'gm', ebda.rc_dec_label(e.gm_approval), 'fin_sign', ebda.rc_dec_label(e.fin_sign),
        'gm_note', coalesce(e.gm_note,''), 'fin_note', coalesce(nullif(e.fin_sign_note,''), e.fin_note, ''),
        'settled', case when ebda.expense_stage(e) in ('settled','reviewed') then 'مسوّى' else 'غير مسوّى' end,
        'in_budget', case when ebda.counts_in_budget(e) then 'نعم' else 'لا' end, 'has_doc', case when coalesce(e.doc_url,'') <> '' then 'نعم' else 'لا' end,
        'category', coalesce(e.category,''), 'doc_no', coalesce(e.doc_no,''), 'created_by', coalesce(e.created_by,'')) x
      from ebda.vis_expenses(u) e left join ebda.schools z on z.id = e.school_id left join ebda.custodies c on c.id = e.custody_id left join ebda.lines l on l.id = e.line_id
      where coalesce(e.cancelled_at,'') = '' and left(coalesce(e.date,''),10) between d1 and d2
        and ebda.rc_in(e.school_id, sch) and ebda.rc_in(e.custody_id, cus) and ebda.rc_in(e.line_id, lns) and ebda.rc_in(coalesce(e.supplier,''), sup)
        and (coalesce(f->>'only_custody','') <> 'true' or coalesce(e.custody_id,'') <> '')) q;
  elsif k = 'custodies' then
    -- الرصيد السابق للفترة منفصل عن حركات الفترة
    select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into rows from (
      select jsonb_build_object('id', c.id, 'code', c.code, 'name', ebda.custody_name(c.title, c.label, c.code), 'school_id', c.school_id, 'school', z.name,
        'holder', ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), 'opened_at', left(coalesce(c.opened_at,''),10),
        'status', case coalesce(c.status,'open') when 'open' then 'مفتوحة' when 'pending_settlement' then 'بانتظار التسوية' when 'settled' then 'تمت التسوية' when 'closed' then 'مغلقة' when 'cancelled' then 'ملغاة' else c.status end,
        'approval', ebda.rc_dec_label(c.approval),
        'original', coalesce((select t.amount from ebda.tranches t where t.custody_id = c.id order by (coalesce(t.note,'') like 'القيمة الأساسية%') desc, t.date limit 1), 0),
        'received_total', coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id and left(coalesce(t.date,''),10) <= d2), 0),
        'received_before', coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id and left(coalesce(t.date,''),10) < d1), 0),
        'received_in', coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = c.id and left(coalesce(t.date,''),10) between d1 and d2), 0),
        'spent_before', coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and left(coalesce(e.date,''),10) < d1), 0),
        'spent_in', coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and left(coalesce(e.date,''),10) between d1 and d2), 0),
        'settled_in', coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and ebda.expense_stage(e) in ('settled','reviewed') and left(coalesce(e.date,''),10) between d1 and d2), 0),
        'unsettled_in', coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and ebda.expense_stage(e) not in ('settled','reviewed') and left(coalesce(e.date,''),10) between d1 and d2), 0),
        'count_in', (select count(*) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and left(coalesce(e.date,''),10) between d1 and d2),
        'pending_in', (select count(*) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and ebda.expense_stage(e) in ('pending_manager','pending_finance','returned','fin_returned','draft') and left(coalesce(e.date,''),10) between d1 and d2),
        'no_doc_in', (select count(*) from ebda.expenses e where e.custody_id = c.id and ebda.active_on_custody(e) and coalesce(e.doc_url,'') = '' and left(coalesce(e.date,''),10) between d1 and d2)) x
      from ebda.vis_custodies(u) c left join ebda.schools z on z.id = c.school_id
      where coalesce(c.cancelled_at,'') = '' and ebda.rc_in(c.school_id, sch) and ebda.rc_in(c.id, cus)) q;
    select coalesce(jsonb_agg(x || jsonb_build_object('opening', (x->>'received_before')::numeric - (x->>'spent_before')::numeric,
        'closing', (x->>'received_before')::numeric - (x->>'spent_before')::numeric + (x->>'received_in')::numeric - (x->>'spent_in')::numeric)), '[]'::jsonb) into rows
      from jsonb_array_elements(rows) x;
  elsif k = 'lines' then
    select coalesce(jsonb_agg(x order by x->>'school', x->>'section', x->>'name'), '[]'::jsonb) into rows from (
      select jsonb_build_object('id', l.id, 'school_id', l.school_id, 'school', z.name, 'section', l.section, 'name', l.name, 'allocated', coalesce(l.allocated,0),
        'spent_in', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and left(coalesce(e.date,''),10) between d1 and d2), 0),
        'committed_in', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.active_on_custody(e) and not ebda.counts_in_budget(e) and left(coalesce(e.date,''),10) between d1 and d2), 0),
        'spent_to_date', coalesce((select sum(e.amount) from ebda.expenses e where e.line_id = l.id and ebda.counts_in_budget(e) and left(coalesce(e.date,''),10) <= d2), 0),
        'needs_in', coalesce((select sum(coalesce(it.amount,0)) from ebda.request_items it join ebda.requests r on r.id = it.request_id
                               where it.line_id = l.id and coalesce(r.status,'') <> 'cancelled' and coalesce(it.cancelled_at,'') = '' and left(coalesce(nullif(r.request_date,''), r.created_at),10) between d1 and d2), 0)) x
      from ebda.lines l join ebda.schools z on z.id = l.school_id
      where coalesce(l.deleted_at,'') = '' and ebda.can_school(u, l.school_id) and ebda.rc_in(l.school_id, sch) and ebda.rc_in(l.id, lns)) q;
    select coalesce(jsonb_agg(x || jsonb_build_object('remaining', (x->>'allocated')::numeric - (x->>'spent_to_date')::numeric,
        'pct', case when (x->>'allocated')::numeric > 0 then round((x->>'spent_to_date')::numeric * 100 / (x->>'allocated')::numeric, 1) else 0 end,
        'state', case when (x->>'allocated')::numeric - (x->>'spent_to_date')::numeric < 0 then 'عجز' else 'ضمن المخصص' end)), '[]'::jsonb) into rows from jsonb_array_elements(rows) x;
  elsif k = 'needs' then
    select coalesce(jsonb_agg(x order by x->>'date', x->>'req_no'), '[]'::jsonb) into rows from (
      select jsonb_build_object('id', it.id, 'req_no', r.req_no, 'date', left(coalesce(nullif(r.request_date,''), r.created_at),10), 'school_id', r.school_id, 'school', z.name,
        'dept', coalesce(nullif(it.dept,''), r.dept, ''), 'item', it.name, 'unit', coalesce(it.unit,''), 'qty', it.qty, 'unit_price', it.unit_price, 'amount', coalesce(it.amount,0),
        'line', l.name, 'priority', coalesce(r.priority,''), 'status', coalesce(r.status,''), 'gm', ebda.rc_dec_label(it.gm_approval), 'fin', ebda.rc_dec_label(it.fin_approval),
        'gm_note', coalesce(it.gm_note,''), 'fin_note', coalesce(it.fin_note,''), 'requester', coalesce(r.requester_name,'')) x
      from ebda.request_items it join ebda.requests r on r.id = it.request_id left join ebda.schools z on z.id = r.school_id left join ebda.lines l on l.id = it.line_id
      where coalesce(r.status,'') <> 'cancelled' and coalesce(it.cancelled_at,'') = '' and ebda.can_request(u, r)
        and left(coalesce(nullif(r.request_date,''), r.created_at),10) between d1 and d2 and ebda.rc_in(r.school_id, sch) and ebda.rc_in(it.line_id, lns)) q;
  elsif k = 'payroll' then
    -- سجل شهر لكل موظف (شهر الاستحقاق) — بيانات الشهر كما هى (لقطته) — حسب صلاحية الاطلاع على رواتب كل مدرسة
    select coalesce(jsonb_agg(x order by x->>'period', x->>'school', x->>'name'), '[]'::jsonb) into rows from (
      select ebda.pay2_row(s, e.period) || jsonb_build_object('period', e.period, 'fy', ebda.pay2_fy(e.period), 'school_id', s.school_id, 'school', z.name, 'staff_id', s.id) x
      from ebda.pay2_effects e join ebda.pay2_staff s on s.id = e.staff_id join ebda.schools z on z.id = s.school_id
      where ebda.pay2_view_ok(u, s.school_id) and e.period between left(d1,7) and left(d2,7) and ebda.rc_in(s.school_id, sch)
        and (coalesce(f->>'fy','') = '' or ebda.pay2_fy(e.period) = f->>'fy')
        and (ppl is null or jsonb_typeof(ppl) <> 'array' or jsonb_array_length(ppl) = 0 or ppl ? ebda.pay2_key(s.name) or (coalesce(s.national_id,'') <> '' and ppl ? ('#' || ebda.pay2_nid(s.national_id))))) q;
  elsif k = 'decisions' then
    select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into rows from (
      select jsonb_build_object('at', left(d.at,16), 'kind', case d.kind when 'expenses' then 'مصروف' when 'needs' then 'صنف طلب' else d.kind end,
        'ref', coalesce(e.txn_no, r.req_no, ''), 'item', coalesce(nullif(e.src_item,''), e.description, it.name, ''), 'school', z.name,
        'signer', case d.signer when 'gm' then 'المدير العام' when 'fin' then 'المدير المالى' when 'category' then 'التصنيف' else d.signer end,
        'decision', ebda.rc_dec_label(d.decision), 'prev', ebda.rc_dec_label(d.prev_decision), 'note', coalesce(d.note,''), 'by', d.by_name, 'role', d.by_role) x
      from ebda.item_decisions d
      left join ebda.expenses e on d.kind = 'expenses' and e.id = d.item_id
      left join ebda.request_items it on d.kind = 'needs' and it.id = d.item_id left join ebda.requests r on r.id = it.request_id
      left join ebda.schools z on z.id = coalesce(e.school_id, r.school_id)
      where left(coalesce(d.at,''),10) between d1 and d2 and ebda.rc_in(coalesce(e.school_id, r.school_id), sch)
        and ((e.id is not null and exists(select 1 from ebda.vis_expenses(u) v where v.id = e.id)) or (r.id is not null and ebda.can_request(u, r)))) q;
  elsif k = 'audit' then
    if not can_audit then return ebda.err('سجل التعديلات غير متاح لك'); end if;
    select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) into rows from (
      select jsonb_build_object('at', left(a.ts,16), 'actor', a.actor, 'role', a.actor_role, 'action', a.action, 'entity', coalesce(a.entity,'')) x
      from ebda.audit_log a where left(coalesce(a.ts,''),10) between d1 and d2 order by a.ts desc limit 5000) q;
  else return ebda.err('نوع تقرير غير معروف'); end if;
  return jsonb_build_object('ok', true, 'kind', k, 'rows', rows, 'generated_at', now()::text, 'by', u.name);
end $rc$;

-- قوائم الاختيار من البيانات المسجلة (حسب النطاق)
create or replace function ebda.rc_entities(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select jsonb_build_object('ok', true,
    'suppliers', coalesce((select jsonb_agg(distinct btrim(e.supplier)) from ebda.vis_expenses(u) e where btrim(coalesce(e.supplier,'')) <> '' and coalesce(e.cancelled_at,'') = ''), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(p order by p->>'name') from (
        select distinct on (coalesce(nullif(ebda.pay2_nid(s.national_id),''), ebda.pay2_key(s.name)))
          jsonb_build_object('key', case when ebda.pay2_nid(s.national_id) <> '' then '#' || ebda.pay2_nid(s.national_id) else ebda.pay2_key(s.name) end,
            'name', s.name, 'code', s.code, 'job', s.job, 'school', (select name from ebda.schools z where z.id = s.school_id), 'school_id', s.school_id) p
        from ebda.pay2_staff s where ebda.pay2_view_ok(u, s.school_id)
        order by coalesce(nullif(ebda.pay2_nid(s.national_id),''), ebda.pay2_key(s.name)), s.fy desc) q), '[]'::jsonb),
    'holders', coalesce((select jsonb_agg(distinct ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label)) from ebda.vis_custodies(u) c), '[]'::jsonb),
    'can_audit', ebda.rk(u) in ('admin','observer') or 'audit.view' = any(ebda.perms_of(u)),
    'can_payroll', exists(select 1 from ebda.schools z where ebda.pay2_view_ok(u, z.id)))
$$;

create or replace function ebda.rc_saved_api(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $rs$
declare m text := coalesce(req->>'mode','list'); r ebda.rc_saved;
begin
  if m = 'save' then
    if ebda.rk(u) = 'observer' then return ebda.err('حساب «متابع» للعرض فقط'); end if;
    if length(btrim(coalesce(req->>'name',''))) < 2 then return ebda.err('اكتب اسماً للتقرير'); end if;
    if jsonb_typeof(req->'config') <> 'object' then return ebda.err('إعدادات غير صحيحة'); end if;
    if coalesce(req->>'id','') <> '' then
      select * into r from ebda.rc_saved where id = req->>'id';
      if not found or (r.owner_id <> u.id and ebda.rk(u) <> 'admin') then return ebda.err('لا صلاحية لتعديل هذا التقرير'); end if;
      update ebda.rc_saved set name = btrim(req->>'name'), config = req->'config', shared = case when coalesce(req->>'shared','') in ('true','نعم') then 'نعم' else 'لا' end, updated_at = now()::text where id = r.id;
      return jsonb_build_object('ok', true, 'id', r.id);
    end if;
    insert into ebda.rc_saved(id, owner_id, owner_name, name, config, shared) values(ebda.uid(), u.id, u.name, btrim(req->>'name'), req->'config',
      case when coalesce(req->>'shared','') in ('true','نعم') then 'نعم' else 'لا' end) returning * into r;
    return jsonb_build_object('ok', true, 'id', r.id);
  elsif m = 'delete' then
    select * into r from ebda.rc_saved where id = req->>'id';
    if not found or (r.owner_id <> u.id and ebda.rk(u) <> 'admin') then return ebda.err('لا صلاحية لحذف هذا التقرير'); end if;
    delete from ebda.rc_saved where id = r.id;
    return jsonb_build_object('ok', true);
  elsif m = 'ran' then
    update ebda.rc_saved set last_run_at = now()::text where id = req->>'id' and (owner_id = u.id or shared = 'نعم');
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'config', s.config, 'owner', s.owner_name,
      'mine', s.owner_id = u.id, 'shared', s.shared, 'created_at', s.created_at, 'last_run_at', s.last_run_at) order by s.name)
    from ebda.rc_saved s where s.owner_id = u.id or s.shared = 'نعم'), '[]'::jsonb));
end $rs$;

create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'custodyLedger','needsTable','priorExpenses','approvalsReport','itemHistory','reviewList','itemDetail','expenseDocs','archivedDoc',
               'custodyAmountInfo','pay2Load','pay2History','pay2Imports','rcData','rcEntities','rcSaved') $$;

-- ================================================================ v10.10: حذف بيانات الرواتب لجهة وفترة · تسجيل العمليات الفاشلة · السجلات غير الموجودة فى الملف
create or replace function ebda.pay2_can_delete(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and 'payroll.delete' = any(ebda.perms_of(u)))
$$;
-- حذف جميع بيانات الرواتب والمؤثرات لجهة + (شهر | عام مالى كامل) — بعد أرشفتها (قابلة للاستعادة من سجل العمليات)
create or replace function ebda.pay2_purge(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pp$
declare sid text := coalesce(req->>'school_id',''); v_fy text := coalesce(req->>'fy',''); p text := coalesce(req->>'period','');
  scope text; periods text[]; ns int; ne int; nh int; aid text; iid text := ebda.uid(); commit_ boolean := coalesce(req->>'mode','preview') = 'commit'; locked text;
begin
  if not ebda.pay2_can_delete(u) then return ebda.err('حذف بيانات الرواتب للأدمن أو بصلاحية «payroll.delete»'); end if;
  if not exists(select 1 from ebda.schools where id = sid) then return ebda.err('اختر الجهة'); end if;
  if not ebda.can_school(u, sid) then return ebda.err('الجهة ليست ضمن نطاقك'); end if;
  if v_fy !~ '^\d{4}-\d{4}$' then return ebda.err('اختر العام المالى'); end if;
  if p <> '' and (p !~ '^\d{4}-(0[1-9]|1[0-2])$' or ebda.pay2_fy(p) <> v_fy) then return ebda.err('الشهر خارج العام المالى المختار'); end if;
  scope := case when p = '' then 'fy' else 'months' end; periods := case when p = '' then '{}'::text[] else array[p] end;
  -- القيود: شهر معتمد نهائياً لا يُحذف (يُعاد فتحه أولاً بسبب موثق)
  select string_agg(h.period, '، ' order by h.period) into locked from ebda.pay2_sheets h
   where h.school_id = sid and ebda.pay2_fy(h.period) = v_fy and (scope = 'fy' or h.period = p) and h.status in ('approved','fin_approved');
  select count(*) into ne from ebda.pay2_effects where school_id = sid and ebda.pay2_fy(period) = v_fy and (scope = 'fy' or period = p);
  select count(*) into ns from ebda.pay2_staff where school_id = sid and fy = v_fy;
  select count(*) into nh from ebda.pay2_sheets where school_id = sid and ebda.pay2_fy(period) = v_fy and (scope = 'fy' or period = p);
  if not commit_ then
    return jsonb_build_object('ok', true, 'school', (select name from ebda.schools where id = sid), 'fy', v_fy, 'period', p, 'scope', scope,
      'records', ne, 'staff', case when scope = 'fy' then ns else 0 end, 'locked', locked);
  end if;
  if locked is not null then return ebda.err('لا يمكن الحذف: أشهر معتمدة نهائياً (' || locked || ') — أعد فتحها أولاً بسبب موثق'); end if;
  if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الحذف'); end if;
  if ne = 0 and (scope = 'months' or ns = 0) then return ebda.err('لا توجد بيانات للحذف فى الجهة والفترة المحددتين'); end if;
  aid := ebda.pay2_archive_scope(u, sid, v_fy, scope, periods, 'حذف بيانات الفترة — ' || btrim(req->>'reason'), iid);
  delete from ebda.pay2_effects where school_id = sid and ebda.pay2_fy(period) = v_fy and (scope = 'fy' or period = p);
  delete from ebda.pay2_sheets where school_id = sid and ebda.pay2_fy(period) = v_fy and (scope = 'fy' or period = p);
  if scope = 'fy' then delete from ebda.pay2_staff where school_id = sid and fy = v_fy; end if;
  insert into ebda.pay2_imports(id, school_id, period, file, sheet, by_name, by_id, at, added, updated, unchanged, rejected, report, action, fy, mode, scope, deleted, ignored, review, archive_id)
  values(iid, sid, case when p = '' then v_fy else p end, '', btrim(req->>'reason'), u.name, u.id, now()::text, 0, 0, 0, 0, '[]'::jsonb, 'delete', v_fy, 'delete', scope, ne, 0, 0, aid);
  insert into ebda.pay2_log values(ebda.uid(), sid, p, '', '_delete', ne::text || ' سجل', btrim(req->>'reason'), 'delete', u.name, u.id, ebda.rk(u), now()::text);
  return jsonb_build_object('ok', true, 'deleted', ne, 'staff', case when scope = 'fy' then ns else 0 end, 'archive_id', aid);
end $pp$;

-- العمليات الفاشلة تُسجَّل (السبب) — الاستيراد نفسه لم يُنفَّذ
create or replace function ebda.pay2_import_logged(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $pl2$
declare r jsonb;
begin
  r := ebda.pay2_import(u, req);
  if coalesce(req->>'mode','') = 'commit' and r ? 'error' and exists(select 1 from ebda.schools where id = req->>'school_id') then
    insert into ebda.pay2_imports(id, school_id, period, file, sheet, by_name, by_id, at, added, updated, unchanged, rejected, report, action, fy, mode, scope)
    values(ebda.uid(), req->>'school_id', coalesce(req->>'period',''), coalesce(req->>'file',''), coalesce(req->>'sheet',''), u.name, u.id, now()::text, 0, 0, 0, 0,
           jsonb_build_array(jsonb_build_object('status', 'failed', 'errors', jsonb_build_array(r->>'error'))), 'failed',
           coalesce(nullif(req->>'fy',''), case when coalesce(req->>'period','') ~ '^\d{4}-\d{2}$' then ebda.pay2_fy(req->>'period') else '' end), coalesce(nullif(req->>'how',''), 'new'), coalesce(req->>'scope',''));
  end if;
  return r;
end $pl2$;

-- ================================================================ v10.11: طلبات العهد — الجهة الطالبة لكل صنف · الجدول الموحد · المؤشرات · التقارير · الإلغاء التشغيلى
alter table ebda.request_items add column if not exists dept text default '';
alter table ebda.request_items add column if not exists cancel_prev_decision text default '';
-- الأصناف القديمة: جهة الطلب كما هى (لا تغيير فى البيانات — فقط تُنسخ لكل صنف لم تُحدد له جهة)
update ebda.request_items it set dept = coalesce(r.dept,'') from ebda.requests r where r.id = it.request_id and coalesce(it.dept,'') = '' and coalesce(r.dept,'') <> '';
insert into ebda.config(key, value) values ('request_depts', '["الشئون الاكاديمية والمعلمون","قسم المهارات الحياتية","شئون الطلاب","شئون العاملين","الجودة والتطوير المؤسسى","قسم الصيانة والمرافق","المعامل والحاسب الالى","ورشة اللوجستيات","قسم الكنترول والامتحانات","التدريب الميدانى","النظافة والبوفيه","مكاتب ادارية","قسم التمريض"]')
on conflict (key) do nothing;

-- الجهات الطالبة المسموح بها للمستخدم: الأقسام المسجلة + الجهات المستخدمة فعلاً فى طلبات نطاقه + المدارس/المراكز المسموح له بها
create or replace function ebda.req_dept_options(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
    select btrim(v) x from jsonb_array_elements_text(coalesce((select value::jsonb from ebda.config where key = 'request_depts'), '[]'::jsonb)) v
    union select btrim(it.dept) from ebda.request_items it join ebda.requests r on r.id = it.request_id where coalesce(btrim(it.dept),'') <> '' and position(' · ' in it.dept) = 0 and ebda.can_school(u, r.school_id)
    union select btrim(z.name) from ebda.schools z where ebda.can_school(u, z.id) and coalesce(z.cancelled_at,'') = '') q where coalesce(x,'') <> ''
$$;
-- التحقق: لكل صنف جهة طالبة (إلزامية) — المختارة صراحةً يجب أن تكون من القائمة المسموح بها
create or replace function ebda.req_dept_err(u ebda.users, hdr_dept text, items jsonb) returns text language plpgsql stable security definer set search_path = ebda as $$
declare it jsonb; i int := 0; opts jsonb := ebda.req_dept_options(u);
begin
  if jsonb_typeof(coalesce(items,'null'::jsonb)) <> 'array' then return null; end if;
  for it in select * from jsonb_array_elements(items) loop
    i := i + 1;
    if coalesce(btrim(it->>'dept'),'') = '' and coalesce(btrim(hdr_dept),'') = '' then
      return 'الصنف رقم ' || i || ' («' || coalesce(btrim(it->>'name'),'') || '»): اختر الجهة الطالبة'; end if;
    if coalesce(btrim(it->>'dept'),'') <> '' and not (opts ? btrim(it->>'dept')) then
      return 'الصنف «' || coalesce(btrim(it->>'name'),'') || '»: الجهة الطالبة «' || btrim(it->>'dept') || '» غير مسجلة أو غير مسموح لك بها'; end if;
  end loop;
  return null;
end $$;

-- حفظ الأصناف (كما فى 007) + الجهة الطالبة لكل صنف
create or replace function ebda.req_items_save(p_req text, p_school text, items jsonb) returns text
language plpgsql security definer set search_path = ebda as $ri$
declare it jsonb; i int := 0; q numeric; p numeric; amt numeric; hdr text := coalesce((select dept from ebda.requests where id = p_req), '');
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
    insert into ebda.request_items(id, request_id, line_id, name, amount, sup_note, decision, unit, qty, unit_price, stock_check, stock_result, item_note, sort, dept)
    values (ebda.uid(), p_req, it->>'line_id', btrim(it->>'name'), amt, '', 'approved', btrim(coalesce(it->>'unit','')), q, p,
            btrim(coalesce(it->>'stock_check','')), btrim(coalesce(it->>'stock_result','')), btrim(coalesce(it->>'item_note','')), i,
            coalesce(nullif(btrim(coalesce(it->>'dept','')),''), hdr));
  end loop;
  update ebda.requests set total = coalesce((select sum(amount) from ebda.request_items where request_id = p_req and decision not in ('rejected','deferred','cancelled')),0) where id = p_req;
  return null;
end $ri$;

-- حالة الصنف التشغيلية (للجدول الموحد والمؤشرات والتقارير) — حالة الصنف منفصلة عن حالة الطلب
create or replace function ebda.req_item_bucket(r ebda.requests, it ebda.request_items) returns text language sql immutable as $$
  select case
    when coalesce(it.decision,'') = 'cancelled' or coalesce(it.cancelled_at,'') <> '' or coalesce(r.status,'') = 'cancelled' then 'cancelled'
    when coalesce(r.status,'') = 'draft' then 'draft'
    when coalesce(it.decision,'') = 'rejected' or coalesce(it.gm_approval,'') = 'rejected' or coalesce(it.fin_approval,'') = 'rejected' then 'rejected'
    when coalesce(r.status,'') = 'rejected' then 'rejected'
    when coalesce(r.status,'') in ('returned','needs_info') or coalesce(it.gm_approval,'') = 'returned' or coalesce(it.fin_approval,'') = 'returned' then 'needs_edit'
    when coalesce(it.fin_approval,'') = 'approved' then 'approved'
    when coalesce(r.status,'') in ('approved','transferred','spent','settled') then 'approved'
    when coalesce(it.gm_approval,'') = 'approved' then 'fin_pending'
    else 'gm_pending' end
$$;

-- كل أصناف الطلبات فى نطاق المستخدم (صف لكل صنف مربوط بطلبه) — استدعاء واحد يخدم الجدول والمؤشرات والتقارير
create or replace function ebda.req_items_all(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $ra$
declare rows jsonb;
begin
  select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'req_no' desc, (x->>'sort')::int), '[]'::jsonb) into rows from (
    select jsonb_build_object('id', it.id, 'request_id', r.id, 'req_no', r.req_no, 'date', left(coalesce(nullif(r.request_date,''), r.created_at),10),
      'school_id', r.school_id, 'school', z.name, 'dept', coalesce(nullif(it.dept,''), r.dept, ''), 'requester', coalesce(r.requester_name,''), 'requester_id', coalesce(nullif(r.requester_id,''), r.requester),
      'holder', coalesce(r.holder_name,''), 'item', it.name, 'line_id', it.line_id, 'line', l.name, 'category', coalesce(nullif(it.category,''), l.name, ''),
      'unit', coalesce(it.unit,''), 'qty', it.qty, 'unit_price', it.unit_price, 'amount', coalesce(it.amount,0), 'priority', coalesce(r.priority,''),
      'req_status', coalesce(r.status,''), 'req_status_label', ebda.req_status_label(r.status),
      'gm', coalesce(it.gm_approval,''), 'gm_note', coalesce(it.gm_note,''), 'gm_by', coalesce(it.gm_by,''), 'gm_at', left(coalesce(it.gm_at,''),16),
      'fin', coalesce(it.fin_approval,''), 'fin_note', coalesce(it.fin_note,''), 'fin_by', coalesce(it.fin_by,''), 'fin_at', left(coalesce(it.fin_at,''),16),
      'decision', coalesce(it.decision,''), 'note', concat_ws(' · ', nullif(it.item_note,''), nullif(it.sup_note,''), nullif(r.note,'')),
      'stock_check', coalesce(it.stock_check,''), 'stock_result', coalesce(it.stock_result,''), 'sort', coalesce(it.sort,0),
      'reason', coalesce(r.reason,''), 'description', coalesce(r.description,''), 'decided_by', coalesce(r.decided_by,''), 'decision_note', coalesce(r.decision_note,''),
      'cancelled_at', left(coalesce(nullif(it.cancelled_at,''), r.cancelled_at, ''),16), 'cancelled_by', coalesce(nullif(it.cancelled_by,''), r.cancelled_by, ''),
      'cancel_reason', coalesce(nullif(it.cancel_reason,''), r.cancel_reason, ''), 'req_cancelled', coalesce(r.status,'') = 'cancelled',
      'bucket', ebda.req_item_bucket(r, it)) x
    from ebda.request_items it join ebda.requests r on r.id = it.request_id
    left join ebda.schools z on z.id = r.school_id left join ebda.lines l on l.id = it.line_id
    where ebda.can_request(u, r)) q;
  return jsonb_build_object('ok', true, 'rows', rows, 'depts', ebda.req_dept_options(u),
    'can_cancel', ebda.rk(u) = 'admin', 'can_gm', ebda.can_gm(u), 'can_fin', ebda.can_fin_sign(u), 'generated_at', now()::text, 'by', u.name);
end $ra$;

create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'custodyLedger','needsTable','priorExpenses','approvalsReport','itemHistory','reviewList','itemDetail','expenseDocs','archivedDoc',
               'custodyAmountInfo','pay2Load','pay2History','pay2Imports','rcData','rcEntities','rcSaved','reqItems','reqDepts') $$;

-- ================================================================ v10.12: تسوية تجاوز قيمة العهدة (المصروفات > القيمة المسلّمة) · سداد مسئول العهدة · اعتماد المالى · الإغلاق
-- «تجاوز قيمة العهدة» حالة مستقلة عن «تجاوز بند الموازنة»: تُحسب من العهدة نفسها (الوارد − المنصرف الفعلى) ولا تغيّر الموازنات.
-- السداد لا يُسجَّل كدفعة واردة على العهدة (لا يغيّر قيمتها التاريخية) — سجل مستقل بإثباته، ولا يُحذف (إبطال بسبب فقط).
alter table ebda.custodies add column if not exists overrun_status text default '';
alter table ebda.custodies add column if not exists overrun_approved_by text default '';
alter table ebda.custodies add column if not exists overrun_approved_at text default '';
alter table ebda.custodies add column if not exists overrun_note text default '';
alter table ebda.custodies add column if not exists overrun_amount_approved numeric default 0;
create table if not exists ebda.custody_overrun_payments(
  id text primary key, custody_id text not null, holder text default '', amount numeric not null default 0, paid_at text default '',
  method text default '', receipt_no text default '', doc_url text default '', note text default '',
  created_by text default '', created_by_id text default '', created_at text default '',
  status text default 'active', void_reason text default '', void_by text default '', void_at text default '');
create index if not exists custody_overrun_payments_c on ebda.custody_overrun_payments(custody_id);
insert into ebda.config(key, value) values ('overrun_pay_methods', '["نقدى","تحويل بنكى","شيك","بطاقة / محفظة إلكترونية","خصم من المستحقات","أخرى"]') on conflict (key) do nothing;

create or replace function ebda.custody_overrun(cid text) returns jsonb language sql stable set search_path = ebda as $$
  with c as (select * from ebda.custodies where id = cid),
  f as (select coalesce((select sum(t.amount) from ebda.tranches t where t.custody_id = cid),0) received,
               coalesce((select sum(e.amount) from ebda.expenses e where e.custody_id = cid and ebda.active_on_custody(e)),0) spent,
               coalesce((select sum(p.amount) from ebda.custody_overrun_payments p where p.custody_id = cid and p.status = 'active'),0) paid),
  g as (select f.*, round(greatest(f.spent - f.received, 0), 2) overrun from f)
  select jsonb_build_object('received', g.received, 'spent', g.spent, 'overrun', g.overrun, 'paid', g.paid,
    'remaining', round(greatest(g.overrun - g.paid, 0), 2),
    'state', case when g.overrun <= 0.004 and g.paid <= 0 then 'none'
                  when coalesce(c.overrun_status,'') = 'approved' and g.paid >= g.overrun - 0.004 then 'approved'
                  when g.paid <= 0 then 'required'
                  when g.paid < g.overrun - 0.004 then 'partial'
                  else 'paid' end,
    'approved_by', coalesce(c.overrun_approved_by,''), 'approved_at', coalesce(c.overrun_approved_at,''), 'approval_note', coalesce(c.overrun_note,''))
  from g, c $$;

create or replace function ebda.overrun_label(s text) returns text language sql immutable as $$
  select case s when 'required' then 'تجاوز يستلزم التسوية' when 'partial' then 'تسوية غير مكتملة'
                when 'paid' then 'تم سداد المبلغ المتجاوز — بانتظار اعتماد المدير المالى' when 'approved' then 'تسوية التجاوز معتمدة' else '' end $$;

-- يمنع اعتبار العهدة مسوّاة/مغلقة قبل معالجة التجاوز: يعيد رسالة الخطأ أو null
create or replace function ebda.overrun_block(cid text) returns text language sql stable as $$
  select case (ebda.custody_overrun(cid)->>'state')
    when 'required' then 'العهدة بها تجاوز ' || to_char((ebda.custody_overrun(cid)->>'overrun')::numeric, 'FM999,999,990.00') || ' ج.م غير مسدد — سجّل سداد المبلغ المتجاوز أولاً'
    when 'partial' then 'تسوية التجاوز غير مكتملة — المتبقى ' || to_char((ebda.custody_overrun(cid)->>'remaining')::numeric, 'FM999,999,990.00') || ' ج.م'
    when 'paid' then 'تم سداد التجاوز ولم يعتمده المدير المالى بعد — لا يمكن الإغلاق قبل الاعتماد'
    else null end $$;

-- تحديث حالة التجاوز المخزنة على العهدة (للعرض السريع فى القوائم) بعد كل عملية
create or replace function ebda.overrun_sync(cid text) returns void language plpgsql as $$
declare o jsonb := ebda.custody_overrun(cid);
begin
  update ebda.custodies set overrun_status = case when o->>'state' = 'none' then '' else o->>'state' end where id = cid;
end $$;

create or replace function ebda.overrun_can_pay(u ebda.users, c ebda.custodies) returns boolean language sql stable as $$
  select ebda.rk(u) <> 'observer' and (ebda.owns_custody(u, c) or ebda.rk(u) in ('admin','finance_manager') or ebda.can(u,'custody.approve')) $$;
create or replace function ebda.overrun_can_approve(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'finance_manager' or ebda.can_fin_sign(u) $$;

create or replace function ebda.overrun_info(u ebda.users, req jsonb) returns jsonb language plpgsql stable security definer set search_path = ebda as $$
declare c ebda.custodies;
begin
  select * into c from ebda.custodies where id = req->>'id';
  if not found or not ebda.can_custody(u, c) then return ebda.err('العهدة غير موجودة أو ليست ضمن نطاقك'); end if;
  return jsonb_build_object('ok', true, 'id', c.id, 'code', c.code, 'name', ebda.custody_name(c.title, c.label, c.code), 'holder', coalesce(nullif(c.holder,''), c.label, ''),
    'school', (select name from ebda.schools where id = c.school_id), 'status', coalesce(c.status,'open'), 'info', ebda.custody_overrun(c.id),
    'label', ebda.overrun_label(ebda.custody_overrun(c.id)->>'state'),
    'payments', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at) from ebda.custody_overrun_payments p where p.custody_id = c.id), '[]'::jsonb),
    'methods', coalesce((select value::jsonb from ebda.config where key = 'overrun_pay_methods'), '[]'::jsonb),
    'can_pay', ebda.overrun_can_pay(u, c) and coalesce(c.status,'open') not in ('closed','cancelled'),
    'can_approve', ebda.overrun_can_approve(u), 'can_void', ebda.rk(u) in ('admin','finance_manager') or ebda.can_fin_sign(u),
    'can_close', ebda.can(u,'custody.approve') and coalesce(c.status,'open') not in ('closed','cancelled'),
    'unsettled_expenses', (select count(*) from ebda.expenses e where e.custody_id = c.id and e.approval <> 'rejected' and coalesce(e.fin_approval,'') <> 'rejected'
                                 and coalesce(e.cancelled_at,'') = '' and not (coalesce(e.settled,'') like '%نعم%')),
    'block', ebda.overrun_block(c.id));
end $$;

create or replace function ebda.overrun_pay(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $$
declare c ebda.custodies; o jsonb; amt numeric; pid text := ebda.uid(); m jsonb;
begin
  select * into c from ebda.custodies where id = req->>'id' for update;
  if not found or not ebda.can_custody(u, c) then return ebda.err('العهدة غير موجودة أو ليست ضمن نطاقك'); end if;
  if not ebda.overrun_can_pay(u, c) then return ebda.err('تسجيل السداد لمسئول العهدة أو المدير المالى / الأدمن فقط'); end if;
  if coalesce(c.status,'open') in ('closed','cancelled') then return ebda.err('العهدة مغلقة / ملغاة'); end if;
  o := ebda.custody_overrun(c.id);
  if (o->>'overrun')::numeric <= 0 then return ebda.err('لا يوجد تجاوز على هذه العهدة — المصروفات لا تتجاوز قيمتها'); end if;
  if coalesce(req->>'amount','') !~ '^\s*[0-9]+(\.[0-9]+)?\s*$' or (req->>'amount')::numeric <= 0 then return ebda.err('اكتب المبلغ المسدد (رقم أكبر من صفر)'); end if;
  amt := round((req->>'amount')::numeric, 2);
  if amt > (o->>'remaining')::numeric + 0.004 then
    return ebda.err('المبلغ أكبر من المتبقى من التجاوز (' || to_char((o->>'remaining')::numeric, 'FM999,999,990.00') || ' ج.م)'); end if;
  if coalesce(req->>'paid_at','') !~ '^\d{4}-\d{2}-\d{2}' then return ebda.err('اختر تاريخ السداد'); end if;
  m := coalesce((select value::jsonb from ebda.config where key = 'overrun_pay_methods'), '[]'::jsonb);
  if coalesce(req->>'method','') = '' or not (m ? (req->>'method')) then return ebda.err('اختر طريقة السداد من الطرق المعتمدة'); end if;
  if coalesce(req->>'client_id','') <> '' and exists(select 1 from ebda.custody_overrun_payments where id = 'p_' || (req->>'client_id')) then
    return jsonb_build_object('ok', true, 'duplicate', true, 'info', o); end if;   -- منع التكرار عند الضغط المتكرر
  if coalesce(req->>'client_id','') <> '' then pid := 'p_' || (req->>'client_id'); end if;
  insert into ebda.custody_overrun_payments(id, custody_id, holder, amount, paid_at, method, receipt_no, doc_url, note, created_by, created_by_id, created_at)
  values(pid, c.id, coalesce(nullif(c.holder,''), c.label, ''), amt, left(req->>'paid_at',10), req->>'method', coalesce(btrim(req->>'receipt_no'),''),
         coalesce(btrim(req->>'doc_url'),''), coalesce(btrim(req->>'note'),''), u.name, u.id, now()::text);
  -- أى سداد جديد يُبطل اعتماداً سابقاً (لا يتجاوز الاعتماد)
  update ebda.custodies set overrun_approved_by = '', overrun_approved_at = '', overrun_amount_approved = 0 where id = c.id and overrun_status = 'approved';
  perform ebda.overrun_sync(c.id);
  return jsonb_build_object('ok', true, 'id', pid, 'info', ebda.custody_overrun(c.id), 'label', ebda.overrun_label(ebda.custody_overrun(c.id)->>'state'));
end $$;

create or replace function ebda.overrun_void(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $$
declare p ebda.custody_overrun_payments; c ebda.custodies;
begin
  select * into p from ebda.custody_overrun_payments where id = req->>'payment_id' for update;
  if not found then return ebda.err('السداد غير موجود'); end if;
  select * into c from ebda.custodies where id = p.custody_id;
  if not (ebda.rk(u) in ('admin','finance_manager') or ebda.can_fin_sign(u)) or not ebda.can_custody(u, c) then return ebda.err('إبطال السداد للمدير المالى / الأدمن فقط'); end if;
  if p.status <> 'active' then return ebda.err('السداد مُبطل بالفعل'); end if;
  if coalesce(c.status,'open') = 'closed' then return ebda.err('العهدة مغلقة — أعد فتحها أولاً'); end if;
  if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الإبطال'); end if;
  update ebda.custody_overrun_payments set status = 'void', void_reason = btrim(req->>'reason'), void_by = u.name, void_at = now()::text where id = p.id;
  update ebda.custodies set overrun_approved_by = '', overrun_approved_at = '', overrun_amount_approved = 0 where id = c.id;
  perform ebda.overrun_sync(c.id);
  return jsonb_build_object('ok', true, 'info', ebda.custody_overrun(c.id));
end $$;

create or replace function ebda.overrun_approve(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $$
declare c ebda.custodies; o jsonb; d text := coalesce(req->>'decision','approved');
begin
  select * into c from ebda.custodies where id = req->>'id' for update;
  if not found or not ebda.can_custody(u, c) then return ebda.err('العهدة غير موجودة أو ليست ضمن نطاقك'); end if;
  if not ebda.overrun_can_approve(u) then return ebda.err('اعتماد تسوية التجاوز للمدير المالى فقط (أو بصلاحية اعتماد التسويات الممنوحة صراحةً)'); end if;
  o := ebda.custody_overrun(c.id);
  if d = 'returned' then
    if length(btrim(coalesce(req->>'note',''))) < 3 then return ebda.err('اكتب سبب الإعادة / المطلوب استكماله'); end if;
    update ebda.custodies set overrun_approved_by = '', overrun_approved_at = '', overrun_amount_approved = 0, overrun_note = btrim(req->>'note') where id = c.id;
    perform ebda.overrun_sync(c.id);
    return jsonb_build_object('ok', true, 'info', ebda.custody_overrun(c.id));
  end if;
  if o->>'state' = 'approved' then return jsonb_build_object('ok', true, 'already', true, 'info', o); end if;
  if (o->>'overrun')::numeric <= 0 then return ebda.err('لا يوجد تجاوز يستلزم الاعتماد'); end if;
  if (o->>'remaining')::numeric > 0.004 then
    return ebda.err('لا يمكن الاعتماد — المتبقى من التجاوز ' || to_char((o->>'remaining')::numeric, 'FM999,999,990.00') || ' ج.م غير مسدد'); end if;
  update ebda.custodies set overrun_status = 'approved', overrun_approved_by = u.name, overrun_approved_at = now()::text,
    overrun_note = coalesce(btrim(req->>'note'),''), overrun_amount_approved = (o->>'overrun')::numeric where id = c.id;
  return jsonb_build_object('ok', true, 'info', ebda.custody_overrun(c.id));
end $$;

-- إنشاء عهدة جديدة: ممنوع لمسئول عليه عهدة سابقة بتجاوز لم تكتمل تسويته
create or replace function ebda.overrun_holder_block(cust jsonb) returns text language sql stable as $$
  select 'لا يمكن إنشاء عهدة جديدة لهذا المسئول — العهدة ' || coalesce(nullif(c.code,''), c.id) || ' عليها تجاوز لم تكتمل تسويته واعتماده (' ||
         ebda.overrun_label(ebda.custody_overrun(c.id)->>'state') || ')'
  from ebda.custodies c
  where coalesce(c.status,'open') in ('open','pending_settlement','settled')   -- العهد المغلقة قبل تفعيل الآلية لا تُحتسب
    and ((coalesce(cust->>'user','') <> '' and coalesce(c."user",'') = cust->>'user')
      or (coalesce(cust->>'holder_emp_id','') <> '' and coalesce(c.holder_emp_id,'') = cust->>'holder_emp_id')
      or (coalesce(btrim(cust->>'holder'),'') <> '' and ebda.pay2_loose(coalesce(c.holder,'')) = ebda.pay2_loose(btrim(cust->>'holder'))))
    and ebda.custody_overrun(c.id)->>'state' in ('required','partial','paid')
  order by c.opened_at limit 1 $$;

create or replace function ebda.observer_allowed(a text) returns boolean language sql immutable as $$
  select a in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','searchExpenses','report','payrollMonth',
               'importBatches','backupInfo','logExport','setPassword','logout','lineMapping','requestHtml','dashboard','cancelledRecords','budgetStatusReport','payrollReport','payslipItems',
               'custodyLedger','needsTable','priorExpenses','approvalsReport','itemHistory','reviewList','itemDetail','expenseDocs','archivedDoc',
               'custodyAmountInfo','pay2Load','pay2History','pay2Imports','rcData','rcEntities','rcSaved','reqItems','reqDepts','overrunInfo') $$;


-- ============================================================================================================================
--  v11 (1): العام المالى أساس النظام — من 1 يوليو حتى 30 يونيو · إنشاء تلقائى للعام الجديد · إغلاق/إعادة فتح بسبب مكتوب ·
--           منع أى تعديل على معاملات عام مغلق (على مستوى قاعدة البيانات لكل المسارات: الواجهة والاستيراد والدوال)
-- ============================================================================================================================
alter table ebda.fiscal_years add column if not exists status text default 'open';
alter table ebda.fiscal_years add column if not exists closed_at text default '';
alter table ebda.fiscal_years add column if not exists closed_by text default '';
alter table ebda.fiscal_years add column if not exists close_note text default '';
alter table ebda.fiscal_years add column if not exists reopened_at text default '';
alter table ebda.fiscal_years add column if not exists reopened_by text default '';
alter table ebda.fiscal_years add column if not exists reopen_reason text default '';
update ebda.fiscal_years set status = 'open' where status is null or status = '';
create table if not exists ebda.fy_log(id text primary key, fy_id text, label text, action text, reason text default '', details jsonb,
  by_name text default '', by_id text default '', at text default now()::text);
create index if not exists fy_log_i on ebda.fy_log(fy_id, at);

-- العام المالى الذى يقع فيه تاريخ (من الأعوام المسجلة، وإلا بقاعدة يوليو ← يونيو)
create or replace function ebda.fy_label_for(d text) returns text language sql stable security definer set search_path = ebda as $$
  with x as (select ebda.safe_date(left(coalesce(d,''),10)) dd)
  select case when x.dd is null then '' else coalesce(
    (select f.label from ebda.fiscal_years f where x.dd between f.start_date and f.end_date order by f.start_date limit 1),
    (case when extract(month from x.dd) >= 7 then extract(year from x.dd)::int else extract(year from x.dd)::int - 1 end)::text || '/' ||
    (case when extract(month from x.dd) >= 7 then extract(year from x.dd)::int + 1 else extract(year from x.dd)::int end)::text) end
  from x $$;
create or replace function ebda.fy_closed_label_on(d text) returns text language sql stable security definer set search_path = ebda as $$
  select f.label from ebda.fiscal_years f where coalesce(f.status,'open') = 'closed'
     and ebda.safe_date(left(coalesce(d,''),10)) between f.start_date and f.end_date limit 1 $$;
-- «YYYY-YYYY» (مفتاح الرواتب) ← تاريخ بداية العام
create or replace function ebda.fy_key_date(k text) returns text language sql immutable as $$
  select case when coalesce(k,'') ~ '^\d{4}[-/]\d{4}$' then left(k,4) || '-07-01' else '' end $$;

-- حارس العام المغلق: يُستدعى من مشغّل الجداول. التجاوز فقط داخل ترحيل قاعدة البيانات (ebda.fy_override)
create or replace function ebda.fy_guard(d text, what text) returns void language plpgsql stable security definer set search_path = ebda as $$
declare lb text;
begin
  if coalesce(current_setting('ebda.fy_override', true),'') = '1' then return; end if;
  if coalesce(d,'') = '' then return; end if;
  lb := ebda.fy_closed_label_on(d);
  if lb is not null then
    raise exception using errcode = 'EB001', message = 'العام المالى ' || lb || ' مغلق — لا يمكن ' || what ||
      ' (يُعاد فتحه من «الإعدادات ← العام المالى» بسبب مكتوب لمن يملك الصلاحية)';
  end if;
end $$;

create or replace function ebda.fy_lock_trg() returns trigger language plpgsql security definer set search_path = ebda as $$
declare o jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end; n jsonb := case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) end;
  f text := tg_argv[0]; what text := coalesce(tg_argv[1], 'تعديل البيانات'); dv text;
begin
  if coalesce(current_setting('ebda.fy_override', true),'') = '1' then return coalesce(new, old); end if;
  foreach dv in array array[case when o is not null then o->>f end, case when n is not null then n->>f end] loop
    if dv is null or dv = '' then continue; end if;
    if f = 'period' or f = 'month' then dv := left(dv,7) || '-01';
    elsif f = 'fy' then dv := ebda.fy_key_date(dv);
    elsif f = 'request_id' then dv := (select left(coalesce(nullif(r.request_date,''), r.created_at),10) from ebda.requests r where r.id = dv); end if;
    perform ebda.fy_guard(dv, what);
  end loop;
  return coalesce(new, old);
end $$;

do $fy$
declare t text[]; begin
  foreach t slice 1 in array array[
    array['expenses','date','تعديل مصروفات'], array['tranches','date','تعديل دفعات العهد'], array['custodies','opened_at','تعديل العهد'],
    array['requests','request_date','تعديل طلبات العهد'], array['request_items','request_id','تعديل أصناف الطلبات'],
    array['pay2_effects','period','تعديل مؤثرات الرواتب'], array['pay2_sheets','period','تعديل حالة شهر الرواتب'], array['pay2_staff','fy','تعديل بيانات الموظفين'],
    array['payslips','month','تعديل قسائم الرواتب'], array['custody_overrun_payments','paid_at','تسجيل سداد']] loop
    if exists(select 1 from information_schema.columns where table_schema = 'ebda' and table_name = t[1] and column_name = t[2]) then
      execute format('drop trigger if exists trg_fy_lock on ebda.%I', t[1]);
      execute format('create trigger trg_fy_lock before insert or update or delete on ebda.%I for each row execute function ebda.fy_lock_trg(%L, %L)', t[1], t[2], t[3]);
    end if;
  end loop;
end $fy$;
-- الطلب بلا «تاريخ الطلب» يُحمَّل على تاريخ إنشائه
create or replace function ebda.fy_lock_req_trg() returns trigger language plpgsql security definer set search_path = ebda as $$
begin
  if coalesce(current_setting('ebda.fy_override', true),'') = '1' then return coalesce(new, old); end if;
  if tg_op in ('UPDATE','DELETE') and coalesce(old.request_date,'') = '' then perform ebda.fy_guard(left(old.created_at,10), 'تعديل طلبات العهد'); end if;
  if tg_op in ('UPDATE','INSERT') and coalesce(new.request_date,'') = '' then perform ebda.fy_guard(left(new.created_at,10), 'تعديل طلبات العهد'); end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_fy_lock_rc on ebda.requests;
create trigger trg_fy_lock_rc before insert or update or delete on ebda.requests for each row execute function ebda.fy_lock_req_trg();

-- إنشاء العام المالى الجارى (والتالى قبل نهاية الحالى بشهرين) تلقائياً — دون تغيير أى عام قائم أو تداخل مع فترة معرّفة
create or replace function ebda.fy_ensure() returns jsonb language plpgsql security definer set search_path = ebda as $$
declare y int; sd date; ed date; lb text; made jsonb := '[]'::jsonb; cur ebda.fiscal_years; i int; nid text; sw text := '';
begin
  y := case when extract(month from current_date) >= 7 then extract(year from current_date)::int else extract(year from current_date)::int - 1 end;
  for i in 0..1 loop
    sd := make_date(y + i, 7, 1); ed := make_date(y + i + 1, 6, 30); lb := (y + i)::text || '/' || (y + i + 1)::text;
    if i = 1 and current_date < sd - 60 then continue; end if;
    if exists(select 1 from ebda.fiscal_years f where daterange(f.start_date, f.end_date, '[]') && daterange(sd, ed, '[]'))
       or exists(select 1 from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(lb)) then continue; end if;
    nid := ebda.uid();
    insert into ebda.fiscal_years(id, label, start_date, end_date, is_current, note, created_at, created_by, status)
    values(nid, lb, sd, ed, 'لا', 'أُنشئ تلقائياً (1 يوليو ← 30 يونيو)', now()::text, 'النظام', 'open');
    insert into ebda.fy_log(id, fy_id, label, action, reason, by_name, at) values(ebda.uid(), nid, lb, 'create', 'إنشاء تلقائى', 'النظام', now()::text);
    made := made || to_jsonb(lb);
  end loop;
  select * into cur from ebda.fiscal_years where coalesce(is_current,'') like '%نعم%' order by start_date desc limit 1;
  if (cur.id is null or cur.end_date < current_date) and exists(select 1 from ebda.fiscal_years where current_date between start_date and end_date) then
    update ebda.fiscal_years set is_current = case when current_date between start_date and end_date then 'نعم' else 'لا' end;
    select label into sw from ebda.fiscal_years where current_date between start_date and end_date limit 1;
    insert into ebda.fy_log(id, fy_id, label, action, reason, by_name, at)
    values(ebda.uid(), (select id from ebda.fiscal_years where label = sw limit 1), sw, 'current', 'بداية العام المالى — أصبح العام الحالى تلقائياً', 'النظام', now()::text);
    perform ebda.rebuild_line_agg();
  end if;
  return jsonb_build_object('created', made, 'switched', sw);
end $$;

-- إحصاءات عام مالى: المعاملات المرتبطة به والإجراءات المعلّقة (قبل الإغلاق)
create or replace function ebda.fy_stats(f ebda.fiscal_years) returns jsonb language sql stable security definer set search_path = ebda as $$
  select jsonb_build_object(
    'expenses', (select count(*) from ebda.expenses e where ebda.safe_date(e.date) between f.start_date and f.end_date),
    'expenses_amount', (select coalesce(sum(e.amount),0) from ebda.expenses e where ebda.safe_date(e.date) between f.start_date and f.end_date and ebda.active_on_custody(e)),
    'custodies', (select count(*) from ebda.custodies c where ebda.safe_date(left(c.opened_at,10)) between f.start_date and f.end_date),
    'requests', (select count(*) from ebda.requests r where ebda.safe_date(left(coalesce(nullif(r.request_date,''), r.created_at),10)) between f.start_date and f.end_date),
    'payroll_months', (select count(*) from ebda.pay2_sheets h where ebda.safe_date(h.period || '-01') between f.start_date and f.end_date
                         and exists(select 1 from ebda.pay2_effects e where e.school_id = h.school_id and e.period = h.period)),
    'pending', jsonb_build_object(
      'expenses', (select count(*) from ebda.expenses e where ebda.safe_date(e.date) between f.start_date and f.end_date and ebda.active_on_custody(e)
                     and (coalesce(e.approval,'pending') not in ('approved','rejected') or coalesce(e.fin_approval,'') not in ('approved','rejected'))),
      'custodies', (select count(*) from ebda.custodies c where ebda.safe_date(left(c.opened_at,10)) between f.start_date and f.end_date
                     and coalesce(c.status,'open') in ('open','pending_settlement')),
      'requests', (select count(*) from ebda.requests r where ebda.safe_date(left(coalesce(nullif(r.request_date,''), r.created_at),10)) between f.start_date and f.end_date
                     and r.status in ('draft','pending_supervisor','pending_accountant','returned','needs_info')),
      'payroll', (select count(*) from ebda.pay2_sheets h where ebda.safe_date(h.period || '-01') between f.start_date and f.end_date
                     and coalesce(h.status,'draft') <> 'fin_approved' and exists(select 1 from ebda.pay2_effects e where e.school_id = h.school_id and e.period = h.period))))
$$;

create or replace function ebda.fy_can_close(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and ('fy.close' = any(ebda.perms_of(u)))) $$;
create or replace function ebda.fy_can_reopen(u ebda.users) returns boolean language sql stable as $$
  select ebda.rk(u) = 'admin' or (ebda.rk(u) <> 'observer' and ('fy.reopen' = any(ebda.perms_of(u)))) $$;

create or replace function ebda.fy_info(u ebda.users) returns jsonb language sql stable security definer set search_path = ebda as $$
  select jsonb_build_object('ok', true, 'can_close', ebda.fy_can_close(u), 'can_reopen', ebda.fy_can_reopen(u), 'today', current_date::text,
    'years', coalesce((select jsonb_agg(to_jsonb(f) || jsonb_build_object('stats', ebda.fy_stats(f), 'key', to_char(f.start_date,'YYYY') || '-' || to_char(f.end_date,'YYYY'))
                       order by f.start_date desc) from ebda.fiscal_years f), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.at desc) from (select * from ebda.fy_log order by at desc limit 200) l), '[]'::jsonb)) $$;

create or replace function ebda.fy_close(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $$
declare f ebda.fiscal_years; st jsonb; pend int;
begin
  if not ebda.fy_can_close(u) then return ebda.err('إغلاق العام المالى للأدمن أو بصلاحية «fy.close»'); end if;
  select * into f from ebda.fiscal_years where id = req->>'id' for update;
  if not found then return ebda.err('العام المالى غير موجود'); end if;
  if f.status = 'closed' then return ebda.err('العام المالى مغلق بالفعل'); end if;
  if f.end_date >= current_date then return ebda.err('لا يُغلق العام المالى قبل انتهائه (ينتهى ' || f.end_date || ')'); end if;
  st := ebda.fy_stats(f);
  pend := (st#>>'{pending,expenses}')::int + (st#>>'{pending,custodies}')::int + (st#>>'{pending,requests}')::int + (st#>>'{pending,payroll}')::int;
  if coalesce(req->>'mode','preview') <> 'commit' then return jsonb_build_object('ok', true, 'mode', 'preview', 'label', f.label, 'stats', st, 'pending', pend); end if;
  if pend > 0 and coalesce(req->>'ack','') <> 'true' then
    return ebda.err('توجد ' || pend || ' إجراءات معلّقة فى هذا العام — راجعها أو أكّد الإغلاق صراحةً (تبقى كما هى ولا يمكن تعديلها بعد الإغلاق)'); end if;
  update ebda.fiscal_years set status = 'closed', closed_at = now()::text, closed_by = u.name, close_note = btrim(coalesce(req->>'note','')) where id = f.id;
  insert into ebda.fy_log(id, fy_id, label, action, reason, details, by_name, by_id, at)
  values(ebda.uid(), f.id, f.label, 'close', btrim(coalesce(req->>'note','')), st, u.name, u.id, now()::text);
  return jsonb_build_object('ok', true, 'label', f.label, 'stats', st);
end $$;

create or replace function ebda.fy_reopen(u ebda.users, req jsonb) returns jsonb language plpgsql security definer set search_path = ebda as $$
declare f ebda.fiscal_years;
begin
  if not ebda.fy_can_reopen(u) then return ebda.err('إعادة فتح العام المالى للأدمن أو بصلاحية «fy.reopen»'); end if;
  select * into f from ebda.fiscal_years where id = req->>'id' for update;
  if not found then return ebda.err('العام المالى غير موجود'); end if;
  if coalesce(f.status,'open') <> 'closed' then return ebda.err('العام المالى مفتوح بالفعل'); end if;
  if length(btrim(coalesce(req->>'reason',''))) < 5 then return ebda.err('اكتب سبب إعادة الفتح (يُسجَّل فى سجل التعديلات)'); end if;
  update ebda.fiscal_years set status = 'open', reopened_at = now()::text, reopened_by = u.name, reopen_reason = btrim(req->>'reason') where id = f.id;
  insert into ebda.fy_log(id, fy_id, label, action, reason, by_name, by_id, at) values(ebda.uid(), f.id, f.label, 'reopen', btrim(req->>'reason'), u.name, u.id, now()::text);
  return jsonb_build_object('ok', true, 'label', f.label);
end $$;

-- لا حذف لعام مالى مغلق أو مرتبط بمعاملات (الأرشيف يبقى)
create or replace function ebda.fy_delete_block(fid text) returns text language sql stable security definer set search_path = ebda as $$
  select case when f.status = 'closed' then 'العام المالى مغلق — لا يُحذف (يبقى فى الأرشيف)'
              when (s->>'expenses')::int + (s->>'custodies')::int + (s->>'requests')::int + (s->>'payroll_months')::int > 0
                then 'العام المالى مرتبط بمعاملات (' || (s->>'expenses') || ' مصروف · ' || (s->>'custodies') || ' عهدة · ' || (s->>'requests') || ' طلب · '
                     || (s->>'payroll_months') || ' شهر رواتب) — لا يُحذف' end
  from ebda.fiscal_years f, lateral (select ebda.fy_stats(f) s) x where f.id = fid $$;

select 'الجزء 11 من 15 تم ✓ — شغّل الجزء 12' as result;
