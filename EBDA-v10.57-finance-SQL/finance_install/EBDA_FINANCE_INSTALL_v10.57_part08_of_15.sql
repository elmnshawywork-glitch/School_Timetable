-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 8 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;

-- ---------------------------------------------------------------- الإلغاء الفردى/الجماعى (معاينة ثم تنفيذ) — بدون حذف
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
        update ebda.request_items set decision = 'cancelled', cancelled_at = now()::text, cancelled_by = u.name, cancel_reason = rsn where id = ri.id;
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

-- لوحة البداية v9 = v8 + صندوق البريد (بدون نص الرسالة)
create or replace function ebda.bootstrap_v9(u ebda.users) returns jsonb
language plpgsql stable security definer set search_path = ebda as $b9$
declare res jsonb := ebda.bootstrap_v8(u);
begin
  if res ? 'error' then return res; end if;
  return res || jsonb_build_object('mail_outbox', coalesce((select jsonb_agg(to_jsonb(m) - 'html' order by m.created_at desc) from
    (select * from ebda.mail_outbox m where ebda.rk(u) = 'admin' or m.sender_id = u.id or m.to_user_id = u.id order by created_at desc limit 300) m), '[]'::jsonb))
    || jsonb_build_object('settings', coalesce(res->'settings','{}'::jsonb) || jsonb_build_object('app_url', coalesce((select value from ebda.config where key='app_url'),'')));
end $b9$;


-- ============================================================================
--  استيراد المصروفات (007 + بند العهدة الملغى لا يقبل مصروفات)
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

select 'الجزء 8 من 15 تم ✓ — شغّل الجزء 9' as result;
