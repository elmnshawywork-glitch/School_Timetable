-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 9 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;

-- ============================================================================
--  الدالة الأساسية (قواعد 001 → 007 + إضافات v9)
-- ============================================================================
create or replace function ebda.api_core(req jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ebda
as $fn$
declare
  action text := req->>'action';
  a_user text := req#>>'{auth,username}';
  a_pin  text := req#>>'{auth,pin}';
  u ebda.users;
  xu ebda.users;
  observer boolean := false;
  cust ebda.custodies;
  ex ebda.expenses;
  rq ebda.requests;
  sid text;
  newid text;
  patch jsonb;
  ln jsonb;
  res jsonb;
  catv text;
  dj jsonb;
  urole text;
  n numeric;
  tok text;
  n_new int := 0;
  n_upd int := 0;
  n_same int := 0;
  lrow ebda.lines;
  lid text;
  nk text;
  pid text;
  n_emp int := 0;
begin
  -- ------------------------------------------------------------ النسخ الاحتياطى (برمز سرّى)
  if action in ('dumpAll','syncExport') then
    tok := coalesce((select value from ebda.config where key='backup_token'),'');
    if tok = '' or tok = 'CHANGE_ME_TO_A_SECRET' then
      return ebda.err('غيّر رمز النسخ الاحتياطى أولاً: update ebda.config set value=''<رمز سرى طويل>'' where key=''backup_token''');
    end if;
    if coalesce(req->>'token','') <> tok then return ebda.err('رمز النسخ الاحتياطى غير صحيح'); end if;
    if action = 'dumpAll' then
      return jsonb_build_object('ok',true,
        'users',(select coalesce(jsonb_agg(ebda.user_public(x)),'[]') from ebda.users x),
        'schools',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.schools x),
        'lines',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.lines x),
        'custodies',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.custodies x),
        'tranches',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.tranches x),
        'expenses',(select coalesce(jsonb_agg(to_jsonb(x) - 'doc_url' || jsonb_build_object('doc_url', case when x.doc_is_link like '%نعم%' then x.doc_url else '' end)),'[]') from ebda.expenses x),
        'spend_items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.spend_items x),
        'holders',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.holders x),
        'approvers',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.approvers x),
        'emails',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.emails x),
        'salaries',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.salaries x),
        'employees',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.employees x),
        'payslips',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.payslips x),
        'temp_budgets',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.temp_budgets x),
        'requests',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.requests x),
        'request_items',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.request_items x),
        'audit_log',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from ebda.audit_log x));
    end if;
    return ebda.sync_export();
  end if;

  -- ------------------------------------------------------------ تسجيل الدخول
  if action = 'login' then
    select * into u from ebda.users
      where username = (req->>'username') and coalesce(active,'') like '%نعم%' order by id limit 1;
    if not found or not ebda.pin_ok(u.pin, req->>'pin') then
      perform ebda.audit(jsonb_populate_record(null::ebda.users, jsonb_build_object('username', req->>'username', 'name', coalesce(req->>'username',''))),
                         'loginFailed', '', jsonb_build_object('username', req->>'username'));
      return ebda.err('بيانات الدخول غير صحيحة');
    end if;
    if u.pin not like '$2%' then update ebda.users set pin = ebda.pin_hash(req->>'pin') where id=u.id; end if;
    update ebda.users set last_login = now()::text where id=u.id;
    perform ebda.audit(u, 'login', u.id, '{}'::jsonb);
    return jsonb_build_object('ok',true,'user',jsonb_build_object('id',u.id,'username',u.username,'name',u.name,
      'role',coalesce(ebda.role_legacy(u.role),u.role),'role_key',ebda.role_key(u.role),'role_label',ebda.role_label(u.role),
      'schools',u.schools,'perms',coalesce(u.perms,''),'must_reset',coalesce(u.must_reset,'لا')));
  end if;

  -- ------------------------------------------------------------ التحقق لبقية الإجراءات (كل طلب)
  if coalesce(current_setting('ebda.auth_uid', true),'') <> '' then
    select * into u from ebda.users where id=current_setting('ebda.auth_uid', true) and coalesce(active,'') like '%نعم%';
    if not found then return ebda.err('انتهت الجلسة — سجّل الدخول من جديد'); end if;
  else
    if coalesce((select value from ebda.config where key='allow_pin_auth'),'yes') = 'no' then
      return ebda.err('انتهت الجلسة — سجّل الدخول من جديد'); end if;
    select * into u from ebda.users where username=a_user and coalesce(active,'') like '%نعم%' order by id limit 1;
    if not found or not ebda.pin_ok(u.pin, a_pin) then return ebda.err('انتهت الجلسة — سجّل الدخول من جديد'); end if;
  end if;
  urole := ebda.rk(u);
  if urole = '' then return ebda.err('دور المستخدم غير معروف — راجع الأدمن'); end if;
  -- v7: المتابع يرى كل ما يراه الأدمن ولا ينفّذ أى تعديل (المنع هنا قبل أى إجراء — ليس إخفاء أزرار فقط)
  if urole = 'observer' then
    if not ebda.observer_allowed(action) then return ebda.err('حساب «متابع» للعرض فقط — لا يملك صلاحية التعديل'); end if;
    if action not in ('setPassword','logExport','logout') then
      observer := true; u.role := 'manager'; u.schools := '*'; u.perms := ''; urole := 'admin';
    end if;
  end if;

  -- سجل التدقيق لكل إجراء تعديلى
  if action not in ('bootstrap','ping','lineStatus','notifyInfo','docAuth','getDoc','expenseHistory','backupInfo','searchExpenses','report','payrollMonth','importBatches',
                    'lineMapping','requestHtml','requestMailInfo','outboxInfo')
     and not (action in ('importExpensesFile','importEmployeesSafe','importCustodiesFile','bulkCancel') and coalesce(req->>'mode','preview') <> 'commit') then
    dj := req - 'auth' - 'pin' - 'dataBase64' - 'dataUrl' - 'html' - 'attachment';
    if dj ? 'user' then dj := dj #- '{user,pin}'; end if;
    if action in ('importExpensesFile','importEmployeesSafe','importCustodiesFile') then dj := (dj - 'rows') || jsonb_build_object('rows_n', jsonb_array_length(coalesce(req->'rows','[]'::jsonb))); end if;
    if dj ? 'patch' then dj := dj #- '{patch,pin}'; end if;
    -- لقطة من السجل قبل الحذف
    if action = 'deleteExpense' then dj := dj || jsonb_build_object('before', (select to_jsonb(e) - 'doc_url' from ebda.expenses e where e.id=req->>'id')); end if;
    if action = 'deleteCustody' then dj := dj || jsonb_build_object('before', (select to_jsonb(c) from ebda.custodies c where c.id=req->>'id')); end if;
    if action = 'renameCustody' then dj := dj || jsonb_build_object('old_title', (select ebda.custody_name(c.title, c.label, c.code) from ebda.custodies c where c.id=req->>'id')); end if;
    if action in ('saveFiscalYear','deleteFiscalYear','setCurrentFiscalYear') then
      dj := dj || jsonb_build_object('before', (select to_jsonb(f) from ebda.fiscal_years f where f.id = coalesce(req#>>'{fy,id}', req->>'id'))); end if;
    if action = 'bulkCancel' then
      dj := dj || jsonb_build_object('affected', (select ebda.bulk_cancel(u, coalesce(req->>'kind',''), array(select jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb))), coalesce(req->>'reason','x'), false)) - 'rows' - 'skipped' - 'ok');
    end if;
    if action in ('returnRequestItems','returnExpenses') then
      dj := dj || jsonb_build_object('before', case when action = 'returnExpenses'
        then (select jsonb_agg(jsonb_build_object('txn_no', e.txn_no, 'stage', ebda.expense_stage(e), 'amount', e.amount)) from ebda.expenses e
              where e.id in (select jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb))))
        else (select jsonb_agg(jsonb_build_object('item', it.name, 'amount', it.amount, 'state', it.review_state)) from ebda.request_items it
              where it.id in (select jsonb_array_elements_text(coalesce(req->'items','[]'::jsonb)))) end);
    end if;
    if action = 'saveLineCatalog' then dj := dj || jsonb_build_object('before', (select to_jsonb(c) from ebda.line_catalog c where c.id=req#>>'{item,id}')); end if;
    if action = 'cancelCustody' then dj := dj || jsonb_build_object('expenses_cancelled', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(e.amount),0))
        from ebda.expenses e where e.custody_id = req->>'id' and coalesce(e.cancelled_at,'') = '')); end if;
    if action in ('deleteLine','updateLine') then dj := dj || jsonb_build_object('before', (select to_jsonb(l) from ebda.lines l where l.id=req->>'id')); end if;
    if action in ('updateUser','deleteUser') then dj := dj || jsonb_build_object('before', (select ebda.user_public(z) from ebda.users z where z.id=req->>'id')); end if;
    perform ebda.audit(u, action, coalesce(req->>'id',''), dj);
  end if;

  if action = 'setPassword' then
    if length(coalesce(req->>'pin',''))<4 then return ebda.err('كلمة السر 4 خانات على الأقل'); end if;
    update ebda.users set pin=ebda.pin_hash(req->>'pin'), must_reset='لا' where id=u.id;
    delete from ebda.sessions where user_id=u.id and token_hash <> coalesce(current_setting('ebda.session_hash', true),'');
    return jsonb_build_object('ok',true);
  end if;

  if action = 'logExport' then  -- تسجيل عملية تصدير تقرير فى «تتبع التعديلات»
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ مساعدات القراءة (بدون سجل تدقيق)
  if action = 'lineStatus' then   -- تنبيه تجاوز البند قبل/بعد التسجيل
    return ebda.line_status(u, req->>'line_id', coalesce((req->>'amount')::numeric,0), coalesce(req->>'exclude_id',''));
  end if;
  if action = 'notifyInfo' then   -- يستدعيه Edge Function «notify» بتوكن المستخدم نفسه
    return ebda.notify_info(u, req->>'event', req->>'id');
  end if;
  if action = 'docAuth' then      -- يستدعيه Edge Function «docs» للتحقق قبل رفع/قراءة مستند من Storage
    select * into ex from ebda.expenses where id=(req->>'expense_id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    select * into cust from ebda.custodies where id=ex.custody_id;
    if (req->>'mode')='upload' then
      if not (urole='admin' or (cust.id is not null and ebda.owns_custody(u, cust))
              or (urole='finance_manager' and ebda.can_expense(u, ex))) then return ebda.err('لا صلاحية لرفع مستند'); end if;
    elsif not ebda.can_expense(u, ex) then return ebda.err('لا صلاحية على هذا المستند');
    end if;
    return jsonb_build_object('ok',true,'path', coalesce(nullif(ex.school_id,''),'central')||'/'||ex.id||'/',
      'current', case when ex.doc_url like 'storage:%' then substr(ex.doc_url, 9) else '' end);
  end if;

  -- ================================================================ v9: صندوق البريد (يستدعيه Edge Function «request-mail» بتوكن المرسل)
  if action in ('outboxInfo','outboxResult') then
    declare m ebda.mail_outbox;
    begin
      select * into m from ebda.mail_outbox where id = req->>'id';
      if m.id is null then return ebda.err('الرسالة غير موجودة'); end if;
      if m.sender_id <> u.id and urole <> 'admin' then return ebda.err('الرسالة ليست لك'); end if;
      if action = 'outboxInfo' then
        if m.status = 'sent' then return ebda.err('الرسالة أُرسلت بالفعل'); end if;
        if not ebda.email_ok(m.to_addr) then
          -- البريد ربما أضيف للمستخدم بعد تسجيل الرسالة: يُقرأ من جديد
          update ebda.mail_outbox set to_addr = lower(btrim(z.email)), status = 'pending', error = '' from ebda.users z
           where mail_outbox.id = m.id and z.id = m.to_user_id and ebda.email_ok(z.email);
          select * into m from ebda.mail_outbox where id = req->>'id';
          if not ebda.email_ok(m.to_addr) then return ebda.err('لا يوجد بريد إلكترونى رسمى للمستلم «' || m.to_name || '» — أضفه من الإعدادات > المستخدمون'); end if;
        end if;
        return jsonb_build_object('ok', true, 'to', m.to_addr, 'cc', '[]'::jsonb, 'subject', m.subject, 'html', m.html);
      end if;
      if m.status = 'sent' then return ebda.err('الرسالة مسجّلة كمُرسلة بالفعل'); end if;
      if coalesce(req->>'status','') not in ('sent','failed','manual') then return ebda.err('حالة غير صحيحة'); end if;
      update ebda.mail_outbox set status = req->>'status', provider_id = left(coalesce(req->>'provider_id',''),200), error = left(coalesce(req->>'error',''),500),
        sent_at = case when req->>'status' = 'sent' then now()::text else sent_at end where id = m.id;
      if m.kind = 'request_return' then
        perform ebda.req_event(m.ref_id, u, case req->>'status' when 'sent' then 'أُرسل بريد الإعادة لمسئول العهدة' when 'manual' then 'بريد الإعادة: فُتح فى برنامج البريد (غير مؤكد)'
                               else 'فشل إرسال بريد الإعادة' end, '', '', m.to_addr || case when coalesce(req->>'error','') <> '' then ' — ' || (req->>'error') else '' end);
      end if;
      return jsonb_build_object('ok', true);
    end;
  end if;

  -- ================================================================ v9: إعادة بند/عدة بنود من الطلب للاستكمال (ليست رفضاً ولا إلغاءً)
  if action = 'returnRequestItems' then
    select * into rq from ebda.requests where id = req->>'id';
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not ebda.can_request(u, rq) then return ebda.err('لا صلاحية على هذا الطلب'); end if;
    if urole <> 'admin' and ebda.is_requester(u, rq) then return ebda.err('لا يمكنك مراجعة طلبك بنفسك'); end if;
    if rq.status = 'pending_supervisor' then
      if not ebda.can(u,'request.approve') then return ebda.err('صلاحية اعتماد الطلبات (المدير المباشر) مطلوبة'); end if;
      if urole<>'admin' and exists(select 1 from ebda.users z where z.id=rq.requester_id and coalesce(z.manager_id,'')<>'' and z.manager_id<>u.id) then
        return ebda.err('هذا الطلب تابع لمدير مباشر آخر'); end if;
    elsif rq.status = 'pending_accountant' then
      if not ebda.can(u,'request.fin_approve') then return ebda.err('صلاحية الاعتماد المالى للطلبات مطلوبة'); end if;
    else
      return ebda.err('الإعادة للاستكمال أثناء مراجعة المدير المباشر أو المدير المالى فقط');
    end if;
    if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الإعادة والمطلوب استكماله'); end if;
    declare ids text[] := array(select jsonb_array_elements_text(coalesce(req->'items','[]'::jsonb))); n_ok int; mid text; stg text := case when rq.status = 'pending_supervisor' then 'supervisor' else 'accountant' end;
    begin
      if cardinality(ids) = 0 then return ebda.err('حدّد بنداً واحداً على الأقل'); end if;
      if exists(select 1 from unnest(ids) x where not exists(select 1 from ebda.request_items it where it.id = x and it.request_id = rq.id
                and coalesce(it.decision,'') not in ('rejected','cancelled'))) then return ebda.err('بند غير تابع لهذا الطلب أو ملغى/مرفوض'); end if;
      update ebda.request_items set review_state = 'returned', review_reason = btrim(req->>'reason'), review_needed = btrim(coalesce(req->>'needed','')),
        review_by = u.name, review_by_id = u.id, review_at = now()::text, review_stage = stg,
        review_log = coalesce(review_log,'[]'::jsonb) || jsonb_build_object('ts', now()::text, 'by', u.name, 'action', 'إعادة للاستكمال',
          'reason', btrim(req->>'reason'), 'needed', btrim(coalesce(req->>'needed','')), 'note', btrim(coalesce(req->>'note','')))
      where request_id = rq.id and id = any(ids);
      get diagnostics n_ok = row_count;
      update ebda.requests set status = 'needs_info', return_stage = stg, returned_at = now()::text where id = rq.id;
      perform ebda.req_event(rq.id, u, 'إعادة ' || n_ok || ' بند للاستكمال', rq.status, 'needs_info',
        btrim(req->>'reason') || case when coalesce(req->>'needed','') <> '' then ' · المطلوب: ' || btrim(req->>'needed') else '' end
        || ' · البنود: ' || (select string_agg(name, '، ') from ebda.request_items where id = any(ids)));
      mid := ebda.queue_request_return(u, rq.id, ids, btrim(req->>'reason'), btrim(coalesce(req->>'needed','')), btrim(coalesce(req->>'note','')));
      return jsonb_build_object('ok', true, 'returned', n_ok, 'outbox_ids', jsonb_build_array(mid),
        'mail', (select jsonb_build_object('status', status, 'to', to_addr, 'to_name', to_name, 'error', error) from ebda.mail_outbox where id = mid));
    end;
  end if;

  if action = 'completeRequestItems' then   -- مسئول العهدة يستكمل البنود المعادة فقط ثم يعيد الإرسال لنفس مرحلة المراجعة
    select * into rq from ebda.requests where id = req->>'id';
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not (ebda.is_requester(u, rq) or (coalesce(rq.holder_id,'') <> '' and rq.holder_id = u.id) or urole = 'admin') then
      return ebda.err('الاستكمال لمقدم الطلب أو مسئول العهدة فقط'); end if;
    if rq.status <> 'needs_info' then return ebda.err('الطلب ليس بحاجة لاستكمال'); end if;
    for ln in select * from jsonb_array_elements(coalesce(req->'items','[]'::jsonb)) loop
      declare it ebda.request_items; p jsonb := coalesce(ln->'patch','{}'::jsonb); q numeric; pr numeric;
      begin
        select * into it from ebda.request_items where id = ln->>'id' and request_id = rq.id;
        if it.id is null then return ebda.err('بند غير تابع لهذا الطلب'); end if;
        if it.review_state not in ('returned','resubmitted') then return ebda.err('البند «' || it.name || '» لم يُعَد للاستكمال — لا يُعدَّل'); end if;
        if p ? 'name' and btrim(p->>'name') = '' then return ebda.err('اسم الصنف مطلوب'); end if;
        q := ebda.numv(p->>'qty', it.qty); pr := ebda.numv(p->>'unit_price', it.unit_price);
        if (p ? 'qty' or p ? 'unit_price') and (q <= 0 or pr <= 0) then return ebda.err('الصنف «' || it.name || '»: الكمية والقيمة يجب أن تكونا أكبر من صفر'); end if;
        if p ? 'line_id' and not exists(select 1 from ebda.lines l where l.id = p->>'line_id' and l.school_id = rq.school_id and coalesce(l.deleted_at,'') = ''
                                         and coalesce(l.active,'نعم') like '%نعم%') then return ebda.err('البند المالى غير تابع للجهة أو معطّل'); end if;
        update ebda.request_items set name = coalesce(nullif(btrim(p->>'name'),''), name), unit = coalesce(p->>'unit', unit), qty = q, unit_price = pr,
          amount = case when q > 0 and pr > 0 then round(q * pr, 2) else amount end, line_id = coalesce(p->>'line_id', line_id),
          stock_check = coalesce(p->>'stock_check', stock_check), stock_result = coalesce(p->>'stock_result', stock_result), item_note = coalesce(p->>'item_note', item_note),
          review_state = 'resubmitted',
          review_log = coalesce(review_log,'[]'::jsonb) || jsonb_build_object('ts', now()::text, 'by', u.name, 'action', 'استكمال', 'note', btrim(coalesce(ln->>'note', req->>'note','')))
        where id = it.id;
      end;
    end loop;
    update ebda.requests set total = coalesce((select sum(amount) from ebda.request_items where request_id = rq.id and decision not in ('rejected','deferred','cancelled')),0),
      updated_at = now()::text where id = rq.id;
    if coalesce(req->>'submit','') not in ('1','true') then
      perform ebda.req_event(rq.id, u, 'حفظ استكمال البنود', rq.status, rq.status, btrim(coalesce(req->>'note','')));
      return jsonb_build_object('ok', true);
    end if;
    if exists(select 1 from ebda.request_items where request_id = rq.id and review_state = 'returned') then
      return ebda.err('استكمل كل البنود المعادة قبل إعادة الإرسال: ' || (select string_agg(name, '، ') from ebda.request_items where request_id = rq.id and review_state = 'returned'));
    end if;
    update ebda.requests set status = case rq.return_stage when 'accountant' then 'pending_accountant' else 'pending_supervisor' end where id = rq.id;
    perform ebda.req_event(rq.id, u, 'إعادة الإرسال للمراجعة بعد الاستكمال', 'needs_info',
      case rq.return_stage when 'accountant' then 'pending_accountant' else 'pending_supervisor' end, btrim(coalesce(req->>'note','')));
    -- إخطار المراجع الذى أعاد البنود
    declare rv text := (select review_by_id from ebda.request_items where request_id = rq.id and review_by_id <> '' order by review_at desc limit 1); mid text;
    begin
      if rv is not null then
        mid := ebda.queue_mail(u, 'request_completed', rq.id, rq.req_no, (select name from ebda.schools where id = rq.school_id), rv,
          'تم استكمال بيانات الطلب ' || coalesce(rq.req_no,''),
          ebda.mail_wrap('تم استكمال البنود المعادة — ' || coalesce(rq.req_no,''), '<p>أعاد ' || ebda.esc(u.name) || ' إرسال الطلب للمراجعة بعد استكمال البنود.</p>'
            || case when coalesce(req->>'note','') <> '' then '<p><b>ملاحظات:</b> ' || ebda.esc(req->>'note') || '</p>' else '' end, ebda.app_link('req', rq.req_no)));
        return jsonb_build_object('ok', true, 'status', case rq.return_stage when 'accountant' then 'pending_accountant' else 'pending_supervisor' end, 'outbox_ids', jsonb_build_array(mid));
      end if;
    end;
    return jsonb_build_object('ok', true);
  end if;

  -- ================================================================ v9: إعادة مصروفات (واحد أو عدة) للاستكمال — المدير المباشر أو المدير المالى
  if action = 'returnExpenses' then
    if length(btrim(coalesce(req->>'reason',''))) < 3 then return ebda.err('اكتب سبب الإعادة والمطلوب استكماله'); end if;
    declare ids text[] := array(select distinct jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb))); x text; done text[] := '{}'; skipped jsonb := '[]'::jsonb; st text;
    begin
      if cardinality(ids) = 0 then return ebda.err('حدّد مصروفاً واحداً على الأقل'); end if;
      if cardinality(ids) > 500 then return ebda.err('500 مصروف كحد أقصى'); end if;
      foreach x in array ids loop
        select * into ex from ebda.expenses where id = x;
        if ex.id is null then skipped := skipped || jsonb_build_object('id', x, 'reason', 'غير موجود'); continue; end if;
        if not ebda.can_expense(u, ex) then skipped := skipped || jsonb_build_object('id', x, 'label', ex.txn_no, 'reason', 'خارج نطاقك'); continue; end if;
        select * into cust from ebda.custodies where id = ex.custody_id;
        if cust.id is null then skipped := skipped || jsonb_build_object('id', x, 'label', ex.txn_no, 'reason', 'شراء مركزى بلا مسئول عهدة'); continue; end if;
        if urole <> 'admin' and (ebda.owns_custody(u, cust) or coalesce(ex.created_by_id,'') = u.id) then
          skipped := skipped || jsonb_build_object('id', x, 'label', ex.txn_no, 'reason', 'لا تراجع مصروفك بنفسك'); continue; end if;
        st := ebda.expense_stage(ex);
        if st = 'pending_manager' and ebda.can(u,'expense.approve') and (urole = 'admin' or ebda.is_assigned_manager(u, cust)) then
          update ebda.expenses set approval = 'returned', approved_by = u.name, approved_by_id = u.id, approved_at = now()::text, approval_note = btrim(req->>'reason'),
            returned_by = u.name, returned_at = now()::text, return_reason = btrim(req->>'reason'), return_needed = btrim(coalesce(req->>'needed','')),
            updated_by = u.name, updated_at = now()::text where id = ex.id;
          done := done || x;
        elsif st in ('pending_finance','reviewed') and ebda.can(u,'expense.fin_approve') then
          update ebda.expenses set fin_approval = 'returned', fin_by = u.name, fin_by_id = u.id, fin_at = now()::text, fin_note = btrim(req->>'reason'),
            returned_by = u.name, returned_at = now()::text, return_reason = btrim(req->>'reason'), return_needed = btrim(coalesce(req->>'needed','')),
            updated_by = u.name, updated_at = now()::text where id = ex.id;
          done := done || x;
        else
          skipped := skipped || jsonb_build_object('id', x, 'label', ex.txn_no, 'reason', 'ليس فى مرحلة مراجعتك (' || st || ')');
        end if;
      end loop;
      return jsonb_build_object('ok', true, 'returned', cardinality(done), 'skipped', skipped,
        'outbox_ids', case when cardinality(done) > 0 then ebda.queue_expense_return(u, done, btrim(req->>'reason'), btrim(coalesce(req->>'needed',''))) else '[]'::jsonb end);
    end;
  end if;

  -- ================================================================ v9: الإلغاء الفردى/الجماعى (معاينة ثم تنفيذ) — للأدمن أو بصلاحية صريحة records.cancel
  if action = 'bulkCancel' then
    if not ebda.can(u,'records.cancel') then return ebda.err('الإلغاء للأدمن فقط (أو بصلاحية «إلغاء السجلات» الممنوحة صراحةً)'); end if;
    return ebda.bulk_cancel(u, coalesce(req->>'kind',''), array(select jsonb_array_elements_text(coalesce(req->'ids','[]'::jsonb))),
                            coalesce(req->>'reason',''), coalesce(req->>'mode','preview') = 'commit');
  end if;

  -- ================================================================ v8: إعدادات العام المالى (صلاحية settings.fiscal) — تُسجَّل فى تتبع التعديلات
  if action = 'saveFiscalYear' then
    if not ebda.can(u,'settings.fiscal') then return ebda.err('صلاحية «تعديل العام المالى» مطلوبة'); end if;
    return ebda.save_fiscal_year(u, coalesce(req->'fy','{}'::jsonb));
  end if;
  if action = 'setCurrentFiscalYear' then
    if not ebda.can(u,'settings.fiscal') then return ebda.err('صلاحية «تعديل العام المالى» مطلوبة'); end if;
    if not exists(select 1 from ebda.fiscal_years where id = req->>'id') then return ebda.err('العام المالى غير موجود'); end if;
    update ebda.fiscal_years set is_current = case when id = req->>'id' then 'نعم' else 'لا' end,
      updated_at = case when id = req->>'id' then now()::text else updated_at end, updated_by = case when id = req->>'id' then u.name else updated_by end;
    perform ebda.rebuild_line_agg();
    return jsonb_build_object('ok',true);
  end if;
  if action = 'deleteFiscalYear' then
    if not ebda.can(u,'settings.fiscal') then return ebda.err('صلاحية «تعديل العام المالى» مطلوبة'); end if;
    select f.label, f.is_current into sid, newid from ebda.fiscal_years f where f.id = req->>'id';
    if sid is null then return ebda.err('العام المالى غير موجود'); end if;
    if newid like '%نعم%' then return ebda.err('لا يمكن حذف العام المالى الحالى — اختر عاماً آخر كحالى أولاً'); end if;
    if exists(select 1 from ebda.schools s where ebda.norm_txt(s.period) = ebda.norm_txt(sid)) then
      return ebda.err('هذا العام مرتبط بموازنات جهات — لا يمكن حذفه'); end if;
    delete from ebda.fiscal_years where id = req->>'id';
    perform ebda.rebuild_line_agg();
    return jsonb_build_object('ok',true);
  end if;
  if action = 'setSchoolPeriod' then   -- ربط موازنة جهة بعام مالى معرّف (بدون تغيير أى حركة)
    if not ebda.can(u,'settings.fiscal') then return ebda.err('صلاحية «تعديل العام المالى» مطلوبة'); end if;
    if not exists(select 1 from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(req->>'period')) then return ebda.err('العام المالى غير معرّف'); end if;
    if not ebda.can_school(u, req->>'school_id') then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    update ebda.schools set period = (select f.label from ebda.fiscal_years f where ebda.norm_txt(f.label) = ebda.norm_txt(req->>'period') limit 1) where id = req->>'school_id';
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ v8: قائمة البنود الموحدة (دمياط/بدر/كل الجهات)
  if action = 'lineMapping' then
    if not ebda.sees_budgets(u) then return ebda.err('لا صلاحية'); end if;
    return ebda.line_mapping(u);
  end if;
  if action = 'saveLineCatalog' then   -- إضافة بند موحد / تعديل اسمه (ينعكس فى كل الجهات) / تصنيف فرعى
    if not ebda.can(u,'lines.manage') then return ebda.err('صلاحية «إدارة قائمة البنود الموحدة» مطلوبة'); end if;
    declare c jsonb := coalesce(req->'item','{}'::jsonb); cid text := nullif(req#>>'{item,id}',''); nm text := btrim(coalesce(req#>>'{item,name}',''));
            dup text; par text := coalesce(nullif(req#>>'{item,parent_id}',''),'');
    begin
      if nm = '' then return ebda.err('اكتب اسم البند'); end if;
      -- منع التكرار: نفس الاسم بعد التطبيع، أو مسمى بديل مسجّل لبند آخر
      dup := ebda.catalog_resolve(nm);
      if dup is not null and dup is distinct from cid then
        return ebda.err('يوجد بند مماثل بالفعل: «'||(select name from ebda.line_catalog where id = dup)||'» — اختره من القائمة بدلاً من إنشاء بند جديد'); end if;
      if par <> '' then
        if not exists(select 1 from ebda.line_catalog p where p.id = par and coalesce(p.parent_id,'') = '') then return ebda.err('البند الرئيسى غير موجود'); end if;
        if par = cid then return ebda.err('لا يكون البند فرعاً من نفسه'); end if;
        if cid is not null and exists(select 1 from ebda.line_catalog z where z.parent_id = cid) then return ebda.err('هذا البند له تصنيفات فرعية — لا يصير فرعاً'); end if;
      end if;
      if cid is null then
        cid := 'lc_' || substr(md5(ebda.line_norm(nm) || clock_timestamp()::text), 1, 10);
        insert into ebda.line_catalog(id, name, section, parent_id, sort, note, source, created_by)
        values (cid, nm, coalesce(c->>'section',''), par, coalesce(nullif(c->>'sort','')::int, 900), coalesce(c->>'note',''), 'manual', u.name);
      else
        if not exists(select 1 from ebda.line_catalog where id = cid) then return ebda.err('البند غير موجود'); end if;
        -- الاسم القديم يبقى مسمى بديلاً (حتى تُطابَق الملفات القديمة عليه)
        insert into ebda.line_aliases(norm, alias, catalog_id, source)
        select ebda.line_norm(z.name), z.name, z.id, 'rename' from ebda.line_catalog z where z.id = cid and ebda.line_norm(z.name) <> ebda.line_norm(nm)
        on conflict (norm) do update set catalog_id = excluded.catalog_id, alias = excluded.alias, source = 'rename';
        update ebda.line_catalog set name = nm, section = coalesce(c->>'section', section), parent_id = par,
          note = coalesce(c->>'note', note), active = coalesce(nullif(c->>'active',''), active) where id = cid;
        delete from ebda.line_aliases where norm = ebda.line_norm(nm);
        update ebda.lines set name = nm where catalog_id = cid;   -- الاسم المعتمد يظهر فى كل الشاشات والتقارير (الحركات كما هى)
      end if;
      return jsonb_build_object('ok', true, 'id', cid, 'item', (select to_jsonb(z) from ebda.line_catalog z where z.id = cid));
    end;
  end if;
  if action = 'saveLineAlias' then   -- ربط مسمى قديم ببند موحد
    if not ebda.can(u,'lines.manage') then return ebda.err('صلاحية «إدارة قائمة البنود الموحدة» مطلوبة'); end if;
    if coalesce(btrim(req->>'alias'),'') = '' then return ebda.err('اكتب المسمى القديم'); end if;
    if not exists(select 1 from ebda.line_catalog where id = req->>'catalog_id') then return ebda.err('البند الموحد غير موجود'); end if;
    if exists(select 1 from ebda.line_catalog z where ebda.line_norm(z.name) = ebda.line_norm(req->>'alias')) then
      return ebda.err('هذا الاسم بند معتمد بالفعل — استخدم «دمج» للبنود المكررة داخل الجهة'); end if;
    insert into ebda.line_aliases(norm, alias, catalog_id, source) values (ebda.line_norm(req->>'alias'), btrim(req->>'alias'), req->>'catalog_id', 'manual')
    on conflict (norm) do update set catalog_id = excluded.catalog_id, alias = excluded.alias, source = 'manual';
    return jsonb_build_object('ok', true);
  end if;
  if action = 'relinkLine' then   -- ربط بند جهة ببند موحد آخر (يغيّر التسمية فقط؛ الحركات والمخصص كما هى)
    if not ebda.can(u,'lines.manage') then return ebda.err('صلاحية «إدارة قائمة البنود الموحدة» مطلوبة'); end if;
    select * into lrow from ebda.lines where id = req->>'id';
    if lrow.id is null then return ebda.err('البند غير موجود'); end if;
    if not ebda.can_school(u, lrow.school_id) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if not exists(select 1 from ebda.line_catalog where id = req->>'catalog_id') then return ebda.err('البند الموحد غير موجود'); end if;
    if exists(select 1 from ebda.lines l where l.school_id = lrow.school_id and l.id <> lrow.id and coalesce(l.deleted_at,'') = '' and l.catalog_id = req->>'catalog_id') then
      return ebda.err('يوجد بند بنفس البند الموحد فى هذه الجهة — استخدم «دمج البنود» بدلاً من الربط'); end if;
    update ebda.lines set catalog_id = req->>'catalog_id' where id = lrow.id;
    insert into ebda.line_map_log(id, line_id, school_id, old_name, catalog_id, new_name, method)
    values (ebda.uid(), lrow.id, lrow.school_id, lrow.name, req->>'catalog_id', (select name from ebda.lines where id = lrow.id), 'manual');
    return jsonb_build_object('ok', true);
  end if;
  if action = 'mergeLines' then
    if urole <> 'admin' then return ebda.err('دمج البنود للأدمن فقط'); end if;
    return ebda.merge_lines(req->>'from_id', req->>'into_id', u.name, coalesce(req->>'reason',''));
  end if;

  -- ================================================================ v8: تغيير اسم العهدة (اسم العهدة فقط — النوع والمسئول والأرصدة كما هى)
  if action = 'renameCustody' then
    if not ebda.can(u,'custody.rename') then return ebda.err('صلاحية «تغيير اسم العهدة» مطلوبة'); end if;
    select * into cust from ebda.custodies where id = req->>'id';
    if not found then return ebda.err('العهدة غير موجودة'); end if;
    if not ebda.can_custody(u, cust) then return ebda.err('هذه العهدة ليست ضمن نطاقك'); end if;
    if length(btrim(coalesce(req->>'title',''))) < 2 then return ebda.err('اكتب اسم العهدة الجديد'); end if;
    if length(btrim(req->>'title')) > 120 then return ebda.err('اسم العهدة طويل جداً (120 حرفاً كحد أقصى)'); end if;
    if btrim(req->>'title') = ebda.custody_name(cust.title, cust.label, cust.code) then return ebda.err('الاسم الجديد مطابق للاسم الحالى'); end if;
    update ebda.custodies set title = btrim(req->>'title') where id = cust.id;
    return jsonb_build_object('ok', true, 'old', ebda.custody_name(cust.title, cust.label, cust.code), 'title', btrim(req->>'title'));
  end if;

  -- ================================================================ v8: طلب العهدة / الاحتياجات — المسودة والإرسال والتعديل
  if action in ('updateRequest','submitRequest','deleteRequest') then
    select * into rq from ebda.requests where id = req->>'id';
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not (ebda.is_requester(u, rq) or urole = 'admin') then return ebda.err('التعديل لمقدم الطلب فقط'); end if;
    if rq.status not in ('draft','returned') then return ebda.err('لا يمكن تعديل الطلب بعد إرساله — إلا إذا أعاده المدير المباشر للتعديل'); end if;
    if action = 'deleteRequest' then
      if rq.status <> 'draft' then return ebda.err('حذف الطلب متاح للمسودة فقط'); end if;
      delete from ebda.request_items where request_id = rq.id;
      delete from ebda.request_events where request_id = rq.id;
      delete from ebda.requests where id = rq.id;
      return jsonb_build_object('ok', true);
    end if;
    if action = 'updateRequest' then
      sid := coalesce(nullif(req#>>'{request,school_id}',''), rq.school_id);
      if not ebda.can_school(u, sid) then return ebda.err('لا صلاحية على هذه الجهة'); end if;
      if ebda.req_header_err(req->'request') is not null then return ebda.err(ebda.req_header_err(req->'request')); end if;
      if req#>'{request,items}' is not null then   -- التحقق من كل الأصناف قبل أى حفظ
        declare e text;
        begin
          e := ebda.req_items_save(rq.id, sid, req#>'{request,items}');
          if e is not null then return ebda.err(e); end if;
        end;
      end if;
      update ebda.requests set school_id = sid, note = coalesce(req#>>'{request,note}', note), reason = btrim(req#>>'{request,reason}'),
        request_date = coalesce(nullif(req#>>'{request,request_date}',''), request_date), dept = coalesce(req#>>'{request,dept}', dept),
        description = coalesce(req#>>'{request,description}', description), priority = coalesce(req#>>'{request,priority}', priority),
        holder_id = coalesce(req#>>'{request,holder_id}', holder_id),
        holder_name = coalesce((select z.name from ebda.users z where z.id = req#>>'{request,holder_id}'), nullif(req#>>'{request,holder_name}',''), holder_name),
        updated_at = now()::text where id = rq.id;
      perform ebda.req_event(rq.id, u, 'تعديل الطلب', rq.status, rq.status, '');
      if coalesce(req->>'submit','') not in ('1','true') then return jsonb_build_object('ok', true, 'id', rq.id); end if;
    end if;
    -- الإرسال للمدير المباشر المرتبط بمقدم الطلب
    select * into rq from ebda.requests where id = rq.id;
    if not exists(select 1 from ebda.request_items where request_id = rq.id) then return ebda.err('أضف صنفاً واحداً على الأقل'); end if;
    update ebda.requests set status = 'pending_supervisor', submitted_at = now()::text,
      mgr_id = coalesce((select z.manager_id from ebda.users z where z.id = coalesce(nullif(rq.requester_id,''), u.id)), ''),
      mgr_name = coalesce((select m.name from ebda.users z join ebda.users m on m.id = z.manager_id where z.id = coalesce(nullif(rq.requester_id,''), u.id)), '')
    where id = rq.id;
    perform ebda.req_event(rq.id, u, case when rq.status = 'returned' then 'إعادة الإرسال بعد التعديل' else 'إرسال للمدير المباشر' end, rq.status, 'pending_supervisor', '');
    return jsonb_build_object('ok', true, 'id', rq.id, 'status', 'pending_supervisor');
  end if;

  if action = 'setRequestSettlement' then   -- التسوية المالية للطلب (المدير المالى)
    if not ebda.can(u,'request.fin_approve') then return ebda.err('صلاحية الاعتماد المالى للطلبات مطلوبة'); end if;
    select * into rq from ebda.requests where id = req->>'id';
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not ebda.can_school(u, rq.school_id) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if rq.status not in ('transferred','spent','settled') then return ebda.err('التسوية بعد الاعتماد المالى وتحويل العهدة فقط'); end if;
    if coalesce(req->>'settlement','') not in ('لم تتم','تمت جزئياً','تمت') then return ebda.err('حالة تسوية غير صحيحة'); end if;
    update ebda.requests set settlement = req->>'settlement', settlement_note = coalesce(req->>'note',''), settled_at = now()::text, settled_by = u.name where id = rq.id;
    perform ebda.req_event(rq.id, u, 'التسوية المالية: '||(req->>'settlement'), rq.status, rq.status, coalesce(req->>'note',''));
    return jsonb_build_object('ok', true);
  end if;

  -- ================================================================ v8: نسخة الطلب والإرسال للمدير المالى بالبريد
  if action in ('requestHtml','requestMailPrepare','requestMailInfo','requestMailResult') then
    if action in ('requestMailInfo','requestMailResult') then
      select r.* into rq from ebda.requests r join ebda.request_mails m on m.request_id = r.id where m.id = req->>'mail_id';
    else
      select * into rq from ebda.requests where id = req->>'id';
    end if;
    if rq.id is null then return ebda.err('الطلب غير موجود'); end if;
    if not ebda.can_request(u, rq) then return ebda.err('لا صلاحية على هذا الطلب'); end if;
    if action = 'requestHtml' then
      return jsonb_build_object('ok', true, 'html', ebda.request_html(rq.id), 'req_no', rq.req_no);
    end if;
    if not ebda.can(u,'request.mail') then return ebda.err('صلاحية «إرسال الطلب للمدير المالى بالبريد» مطلوبة'); end if;
    -- لا يُرسل للمدير المالى قبل موافقة المدير المباشر (الموافقة لا تعنى الاعتماد المالى)
    if rq.status not in ('pending_accountant','transferred','spent','settled') then
      return ebda.err('لا يمكن الإرسال للمدير المالى قبل موافقة المدير المباشر على الطلب'); end if;
    if action = 'requestMailPrepare' then
      declare toa text := lower(btrim(coalesce(req->>'to',''))); ccs jsonb := '[]'::jsonb; x text; mid text := ebda.uid(); att jsonb := '[]'::jsonb; s text;
      begin
        if toa !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then return ebda.err('البريد الإلكترونى للمدير المالى غير صحيح'); end if;
        for x in select lower(btrim(v)) from jsonb_array_elements_text(coalesce(req->'cc','[]'::jsonb)) v loop
          if x = '' then continue; end if;
          if x !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then return ebda.err('بريد غير صحيح فى النسخة (CC): '||x); end if;
          if x <> toa and not (ccs ? x) then ccs := ccs || to_jsonb(x); end if;
        end loop;
        if jsonb_array_length(ccs) > 20 then return ebda.err('20 عنواناً كحد أقصى فى النسخة (CC)'); end if;
        if length(btrim(coalesce(req->>'subject',''))) < 3 then return ebda.err('اكتب عنوان الرسالة'); end if;
        att := coalesce((select jsonb_agg(jsonb_build_object('name', left(coalesce(v->>'name',''),150), 'size', coalesce(nullif(v->>'size','')::bigint,0)))
                         from jsonb_array_elements(coalesce(req->'attachments','[]'::jsonb)) v), '[]'::jsonb);
        if (select coalesce(sum((v->>'size')::bigint),0) from jsonb_array_elements(att) v) > 15 * 1024 * 1024 then
          return ebda.err('حجم المرفقات أكبر من 15 ميجابايت'); end if;
        s := ebda.request_html(rq.id);
        insert into ebda.request_mails(id, request_id, sender, sender_id, to_addr, cc, subject, message, body_html, attachments, status)
        values (mid, rq.id, u.name, u.id, toa, ccs, btrim(req->>'subject'), coalesce(req->>'message',''),
                '<div dir="rtl" style="font-family:Arial,Tahoma,sans-serif;font-size:14px;line-height:1.7;white-space:pre-line">'||ebda.esc(coalesce(req->>'message',''))||'</div><hr>'||s,
                att, case when coalesce(req->>'mode','') = 'manual' then 'manual' else 'prepared' end);
        update ebda.requests set mail_status = case when coalesce(req->>'mode','') = 'manual' then 'manual' else 'prepared' end, mail_at = now()::text where id = rq.id;
        perform ebda.req_event(rq.id, u, case when coalesce(req->>'mode','') = 'manual' then 'تجهيز رسالة للمدير المالى (برنامج البريد — غير مؤكد الإرسال)'
                                          else 'تجهيز الإرسال للمدير المالى بالبريد' end, rq.status, rq.status,
                               'إلى: '||toa||case when jsonb_array_length(ccs) > 0 then ' · نسخة: '||(select string_agg(v,', ') from jsonb_array_elements_text(ccs) v) else '' end);
        return jsonb_build_object('ok', true, 'mail_id', mid, 'html', s, 'to', toa, 'cc', ccs);
      end;
    end if;
    select * into patch from (select to_jsonb(m) j from ebda.request_mails m where m.id = req->>'mail_id') q;
    if action = 'requestMailInfo' then   -- يستدعيه Edge Function «request-mail» بتوكن المرسل نفسه
      if (patch->>'sender_id') <> u.id then return ebda.err('الرسالة ليست لك'); end if;
      if (patch->>'status') not in ('prepared','failed') then return ebda.err('الرسالة أُرسلت بالفعل'); end if;
      return jsonb_build_object('ok', true, 'to', patch->>'to_addr', 'cc', patch->'cc', 'subject', patch->>'subject', 'html', patch->>'body_html',
        'req_no', rq.req_no, 'copy_html', ebda.request_html(rq.id));
    end if;
    -- requestMailResult: النتيجة الفعلية من خدمة البريد — لا نجاح بدون تأكيد
    if (patch->>'sender_id') <> u.id and urole <> 'admin' then return ebda.err('الرسالة ليست لك'); end if;
    if coalesce(req->>'status','') not in ('sent','failed') then return ebda.err('حالة غير صحيحة'); end if;
    if (patch->>'status') = 'sent' then return ebda.err('الرسالة مسجّلة كمُرسلة بالفعل'); end if;
    update ebda.request_mails set status = req->>'status', provider_id = left(coalesce(req->>'provider_id',''),200), error = left(coalesce(req->>'error',''),500),
      sent_at = case when req->>'status' = 'sent' then now()::text else sent_at end where id = req->>'mail_id';
    update ebda.requests set mail_status = req->>'status', mail_at = now()::text where id = rq.id;
    perform ebda.req_event(rq.id, u, case when req->>'status' = 'sent' then 'تم الإرسال للمدير المالى بالبريد' else 'فشل الإرسال بالبريد' end,
                           rq.status, rq.status, case when req->>'status' = 'sent' then 'معرّف الرسالة: '||coalesce(req->>'provider_id','') else coalesce(req->>'error','') end);
    return jsonb_build_object('ok', true);
  end if;

  -- ================================================================ طلبات العهد
  if action = 'addRequest' then
    if not (urole in ('custody_officer','admin') or ebda.can(u,'request.create')) then return ebda.err('لا صلاحية لإنشاء طلب عهدة'); end if;
    sid := req#>>'{request,school_id}';
    if not ebda.can_school(u, sid) then return ebda.err('لا صلاحية على هذه الجهة'); end if;
    if ebda.req_header_err(req->'request') is not null then return ebda.err(ebda.req_header_err(req->'request')); end if;
    newid := ebda.uid();
    insert into ebda.requests(id,school_id,requester,requester_name,status,note,total,created_at,req_no,reason,
                              request_date,dept,description,priority,holder_id,holder_name)
    values(newid, sid, u.username, u.name, 'draft', coalesce(req#>>'{request,note}',''), 0, now()::text,
      'REQ-'||lpad(nextval('ebda.seq_req')::text,4,'0'), btrim(coalesce(req#>>'{request,reason}','')),
      coalesce(nullif(req#>>'{request,request_date}',''), to_char(now() at time zone 'Africa/Cairo','YYYY-MM-DD')),
      coalesce(req#>>'{request,dept}',''), coalesce(req#>>'{request,description}',''), coalesce(req#>>'{request,priority}',''),
      coalesce(nullif(req#>>'{request,holder_id}',''), case when urole='custody_officer' then u.id else '' end),
      coalesce((select z.name from ebda.users z where z.id = nullif(req#>>'{request,holder_id}','')), nullif(req#>>'{request,holder_name}',''),
               case when urole='custody_officer' then u.name else '' end));
    declare e text;
    begin
      e := ebda.req_items_save(newid, sid, req#>'{request,items}');
      if e is not null then
        delete from ebda.requests where id = newid;
        return ebda.err(e);
      end if;
    end;
    perform ebda.req_event(newid, u, 'إنشاء الطلب', '', 'draft', '');
    if coalesce(req#>>'{request,draft}','') in ('1','true') then
      return jsonb_build_object('ok',true,'id',newid,'status','draft');
    end if;
    update ebda.requests set status='pending_supervisor', submitted_at=now()::text,
      mgr_id = coalesce(u.manager_id,''), mgr_name = coalesce((select m.name from ebda.users m where m.id = u.manager_id),'')
    where id=newid;
    perform ebda.req_event(newid, u, 'إرسال للمدير المباشر', 'draft', 'pending_supervisor', '');
    return jsonb_build_object('ok',true,'id',newid,'status','pending_supervisor');
  end if;

  if action in ('updateRequestItem','deleteRequestItem') then
    if not ebda.can(u,'request.approve') then return ebda.err('صلاحية اعتماد الطلبات مطلوبة'); end if;
    select r.* into rq from ebda.requests r join ebda.request_items it on it.request_id=r.id where it.id=(req->>'id');
    if not found then return ebda.err('البند غير موجود'); end if;
    if not ebda.can_school(u, rq.school_id) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if rq.status <> 'pending_supervisor' and urole<>'admin' then return ebda.err('لا يمكن التعديل بعد اتخاذ القرار'); end if;
    if action = 'updateRequestItem' then
      patch := req->'patch';
      if patch ? 'decision' and coalesce(patch->>'decision','') not in ('approved','partial','rejected','deferred','cancelled') then return ebda.err('قرار غير صحيح'); end if;
      if patch ? 'line_id' and not exists(select 1 from ebda.lines l where l.id=patch->>'line_id' and l.school_id=rq.school_id) then
        return ebda.err('البند غير تابع لهذه الجهة'); end if;
      if (patch ? 'qty' and ebda.numv(patch->>'qty', -1) <= 0) or (patch ? 'unit_price' and ebda.numv(patch->>'unit_price', -1) <= 0)
         or (patch ? 'amount' and ebda.numv(patch->>'amount', -1) <= 0) then return ebda.err('القيم يجب أن تكون أرقاماً أكبر من صفر'); end if;
      update ebda.request_items set line_id=coalesce(patch->>'line_id',line_id), name=coalesce(patch->>'name',name),
        amount=coalesce((patch->>'amount')::numeric,amount), sup_note=coalesce(patch->>'sup_note',sup_note), decision=coalesce(patch->>'decision',decision),
        unit=coalesce(patch->>'unit',unit), qty=ebda.numv(patch->>'qty',qty), unit_price=ebda.numv(patch->>'unit_price',unit_price),
        stock_check=coalesce(patch->>'stock_check',stock_check), stock_result=coalesce(patch->>'stock_result',stock_result)
      where id=(req->>'id');
      update ebda.request_items set amount = round(qty * unit_price, 2) where id=(req->>'id') and coalesce(qty,0) > 0 and coalesce(unit_price,0) > 0;
    else
      delete from ebda.request_items where id=(req->>'id');
    end if;
    update ebda.requests set total=coalesce((select sum(amount) from ebda.request_items where request_id=rq.id and decision not in ('rejected','deferred','cancelled')),0) where id=rq.id;
    perform ebda.req_event(rq.id, u, case when action = 'deleteRequestItem' then 'حذف صنف' else 'تعديل صنف' end, rq.status, rq.status, coalesce(req#>>'{patch,sup_note}',''));
    return jsonb_build_object('ok',true);
  end if;

  if action = 'decideRequest' then
    if not ebda.can(u,'request.approve') then return ebda.err('صلاحية اعتماد الطلبات مطلوبة'); end if;
    select * into rq from ebda.requests where id=(req->>'id');
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not ebda.can_school(u, rq.school_id) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if urole<>'admin' and ((coalesce(rq.requester_id,'')<>'' and rq.requester_id=u.id) or rq.requester = u.username) then return ebda.err('لا يمكنك اعتماد طلبك بنفسك'); end if;
    if rq.status <> 'pending_supervisor' then return ebda.err('الطلب ليس فى مرحلة اعتماد المدير المباشر'); end if;
    if urole<>'admin' and exists(select 1 from ebda.users z where z.id=rq.requester_id and coalesce(z.manager_id,'')<>'' and z.manager_id<>u.id) then
      return ebda.err('هذا الطلب تابع لمسئول عهدة مرتبط بمدير مباشر آخر'); end if;
    if coalesce(req->>'decision','') not in ('approve','reject','return') then return ebda.err('قرار غير صحيح'); end if;
    if req->>'decision' in ('reject','return') and length(btrim(coalesce(req->>'note','')))<3 then
      return ebda.err('اكتب مبررات القرار (سبب الرفض أو المطلوب تعديله)'); end if;
    update ebda.requests set status = case req->>'decision' when 'approve' then 'pending_accountant' when 'return' then 'returned' else 'rejected' end,
      decided_by=u.name, decided_at=now()::text, decision_note=btrim(coalesce(req->>'note','')),
      returned_at = case when req->>'decision'='return' then now()::text else returned_at end where id=rq.id;
    perform ebda.req_event(rq.id, u, case req->>'decision' when 'approve' then 'موافقة المدير المباشر' when 'return' then 'إعادة للتعديل' else 'رفض المدير المباشر' end,
                           rq.status, case req->>'decision' when 'approve' then 'pending_accountant' when 'return' then 'returned' else 'rejected' end, btrim(coalesce(req->>'note','')));
    return jsonb_build_object('ok',true);
  end if;

  if action = 'transferRequest' then
    if not ebda.can(u,'request.fin_approve') then return ebda.err('صلاحية الاعتماد المالى للطلبات مطلوبة'); end if;
    select * into rq from ebda.requests where id=(req->>'id');
    if not found then return ebda.err('الطلب غير موجود'); end if;
    if not ebda.can_school(u, rq.school_id) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if rq.status <> 'pending_accountant' then return ebda.err('الطلب ليس فى مرحلة الاعتماد المالى'); end if;
    if urole<>'admin' and ((coalesce(rq.requester_id,'')<>'' and rq.requester_id=u.id) or rq.requester = u.username) then return ebda.err('لا يمكنك اعتماد طلبك بنفسك'); end if;
    if (req->>'decision')<>'approve' then
      update ebda.requests set status='rejected', acc_by=u.name, fin_at=now()::text where id=rq.id;
      perform ebda.req_event(rq.id, u, 'رفض المدير المالى', rq.status, 'rejected', coalesce(req->>'note',''));
      return jsonb_build_object('ok',true);
    end if;
    n := coalesce((select sum(amount) from ebda.request_items where request_id=rq.id and decision not in ('rejected','deferred','cancelled')),0);
    -- عهدة مفتوحة لنفس المسئول والجهة، وإلا عهدة جديدة (بعد تسوية/إغلاق السابقة)
    select * into cust from ebda.custodies where school_id=rq.school_id and "user"=rq.requester
      and coalesce(status,'open') in ('open','') order by code desc limit 1;
    if not found then
      newid := ebda.uid();
      insert into ebda.custodies(id,label,holder,school_id,note,"user",code,status,opened_at)
      values(newid, 'عهدة '||rq.requester_name, rq.requester_name, rq.school_id, 'من طلب عهدة '||coalesce(rq.req_no,''), rq.requester,
             'CUST-'||lpad(nextval('ebda.seq_cust')::text,3,'0'), 'open', now()::text);
      select * into cust from ebda.custodies where id=newid;
    end if;
    insert into ebda.tranches(id,custody_id,date,amount,note)
    values(ebda.uid(), cust.id, to_char(now(),'YYYY-MM-DD'), n, 'تحويل طلب عهدة '||coalesce(rq.req_no,''));
    update ebda.requests set status='transferred', acc_by=u.name, fin_at=now()::text, custody_id=cust.id, total=n where id=rq.id;
    perform ebda.req_event(rq.id, u, 'الاعتماد المالى وتحويل العهدة', rq.status, 'transferred', 'العهدة '||coalesce(cust.code,'')||' · '||ebda.fmt_num(n)||' ج.م');
    return jsonb_build_object('ok',true,'custody_id',cust.id,'custody_code',cust.code);
  end if;

  if action = 'ping' then
    return jsonb_build_object('ok',true,'connected',true,'db','supabase','schema_version',1,
      'users',(select count(*) from ebda.users),'schools',(select count(*) from ebda.schools));
  end if;

  -- ================================================================ bootstrap (كل البيانات المسموح بها فقط)
  if action = 'bootstrap' then
    if observer then return ebda.observer_view(ebda.bootstrap_v9(u)); end if;
    return ebda.bootstrap_v9(u);
  end if;

  -- ================================================================ المصروفات
  if action = 'addExpense' then
    select * into cust from ebda.custodies where id = (req#>>'{expense,custody_id}');
    if not found then return ebda.err('العهدة غير موجودة'); end if;
    if not (urole='admin' or ebda.owns_custody(u, cust)) then return ebda.err('لا صلاحية على هذه العهدة'); end if;
    if coalesce(cust.status,'open') in ('settled','closed') then return ebda.err('العهدة '||coalesce(cust.code,'')||' مسوّاة/مغلقة — اطلب عهدة جديدة'); end if;
    if coalesce(cust.status,'open')='cancelled' then return ebda.err('العهدة ملغاة — لا يمكن الصرف منها'); end if;
    if coalesce(cust.approval,'approved')<>'approved' then return ebda.err('العهدة لم تُعتمد بعد — لا يمكن الصرف منها'); end if;
    if not ebda.can(u,'expense.record') then return ebda.err('لا صلاحية لتسجيل المصروفات'); end if;
    if exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and cl.line_id=coalesce(req#>>'{expense,line_id}','') and coalesce(cl.cancelled_at,'')<>'') then
      return ebda.err('هذا البند ملغى داخل العهدة — لا يقبل مصروفات جديدة'); end if;
    if exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and coalesce(cl.cancelled_at,'')='')
       and not exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and cl.line_id=coalesce(req#>>'{expense,line_id}','') and coalesce(cl.cancelled_at,'')='') then
      return ebda.err('هذا البند غير مخصص لهذه العهدة — اختر بنداً من بنود العهدة'); end if;
    if coalesce(req#>>'{expense,date}','') > to_char(now() + interval '1 day','YYYY-MM-DD') then return ebda.err('تاريخ المصروف فى المستقبل'); end if;
    if coalesce(req#>>'{expense,line_id}','')<>'' and exists(select 1 from ebda.lines l where l.id=req#>>'{expense,line_id}' and coalesce(l.deleted_at,'')<>'') then
      return ebda.err('بند الموازنة محذوف'); end if;
    if coalesce(req#>>'{expense,line_id}','')<>'' and exists(select 1 from ebda.lines l where l.id=req#>>'{expense,line_id}' and coalesce(l.active,'نعم') not like '%نعم%') then
      return ebda.err('بند الموازنة معطّل — لا يقبل مصروفات جديدة'); end if;
    if coalesce(btrim(req#>>'{expense,doc_link}'),'')<>'' and btrim(req#>>'{expense,doc_link}') !~* '^https?://' then
      return ebda.err('رابط المستند يجب أن يبدأ بـ http:// أو https://'); end if;
    if coalesce((req#>>'{expense,amount}')::numeric,0) <= 0 then return ebda.err('قيمة المصروف يجب أن تكون أكبر من صفر'); end if;
    if coalesce(req#>>'{expense,line_id}','')<>'' and not exists(select 1 from ebda.lines l where l.id=req#>>'{expense,line_id}' and l.school_id=cust.school_id) then
      return ebda.err('بند الموازنة غير تابع لجهة هذه العهدة'); end if;
    newid := ebda.uid();
    insert into ebda.expenses(id,date,school_id,custody_id,line_id,spend_item,description,amount,
       approval,approved_by,doc_url,doc_name,review_status,review_note,settled,ref,note,created_by,created_at,txn_no)
    values(newid, req#>>'{expense,date}', cust.school_id, cust.id,
       req#>>'{expense,line_id}', coalesce(req#>>'{expense,spend_item}',''), coalesce(req#>>'{expense,description}',''),
       (req#>>'{expense,amount}')::numeric, case when coalesce(req#>>'{expense,draft}','') in ('1','true','نعم') then 'draft' else 'pending' end,
       '', '','','','','','',coalesce(req#>>'{expense,note}',''), u.name, now()::text,
       'EXP-'||lpad(nextval('ebda.seq_exp')::text,5,'0'));
    if ebda.valid_sub(req#>>'{expense,line_id}', req#>>'{expense,catalog_sub_id}') = '!' then
      delete from ebda.expenses where id=newid; return ebda.err('التصنيف الفرعى غير تابع لبند المصروف'); end if;
    update ebda.expenses set pay_method=coalesce(req#>>'{expense,pay_method}',''), created_by_id=u.id,
      catalog_sub_id=ebda.valid_sub(req#>>'{expense,line_id}', req#>>'{expense,catalog_sub_id}'),
      submitted_at=case when approval='pending' then now()::text else '' end where id=newid;
    -- رابط المستند المؤيد (فاتورة/إيصال/Drive/OneDrive/SharePoint...) يُسجَّل مع المصروف
    if coalesce(btrim(req#>>'{expense,doc_link}'),'') ~* '^https?://' then
      update ebda.expenses set doc_url=btrim(req#>>'{expense,doc_link}'), doc_is_link='نعم',
        doc_name=coalesce(nullif(req#>>'{expense,doc_name}',''),'رابط مستند'), doc_type=coalesce(req#>>'{expense,doc_type}','') where id=newid;
    end if;
    return jsonb_build_object('ok',true,'item',(select to_jsonb(e) - 'doc_url' || jsonb_build_object('doc_url', case when e.doc_url like 'data:%' then 'inline:' else coalesce(e.doc_url,'') end)
                                                from ebda.expenses e where e.id=newid))
           || ebda.over_warning(u, req#>>'{expense,line_id}');
  end if;

  if action = 'addCentral' then  -- شراء مركزى: يُخصم من الموازنة مباشرة
    if urole not in ('admin','finance_manager') then return ebda.err('صلاحية المدير المالى مطلوبة'); end if;
    sid := req#>>'{expense,school_id}';
    if not ebda.can_school(u, sid) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if coalesce(req#>>'{expense,line_id}','')<>'' and not exists(select 1 from ebda.lines l where l.id=req#>>'{expense,line_id}' and l.school_id=sid) then
      return ebda.err('بند الموازنة غير تابع لهذه الجهة'); end if;
    newid := ebda.uid();
    insert into ebda.expenses(id,date,school_id,custody_id,line_id,spend_item,description,amount,
       approval,approved_by,approved_at,doc_url,doc_name,review_status,review_note,settled,settled_at,ref,note,created_by,created_at,
       fin_approval,fin_by,fin_at,txn_no,doc_type)
    values(newid, req#>>'{expense,date}', sid, '', req#>>'{expense,line_id}', '',
       coalesce(req#>>'{expense,description}',''), coalesce((req#>>'{expense,amount}')::numeric,0),
       'approved', u.name, now()::text, coalesce(req->>'dataUrl',''), coalesce(req->>'filename',''),
       'مستوفى','', 'نعم', now()::text, '','', u.name, now()::text, 'approved', u.name, now()::text,
       'EXP-'||lpad(nextval('ebda.seq_exp')::text,5,'0'), coalesce(req->>'doc_type',''));
    update ebda.expenses set pay_method=coalesce(req#>>'{expense,pay_method}',''), created_by_id=u.id, approved_by_id=u.id, fin_by_id=u.id,
      settled_by=u.name, settled_by_id=u.id where id=newid;
    return jsonb_build_object('ok',true,'item',(select to_jsonb(e) from ebda.expenses e where e.id=newid))
           || ebda.over_warning(u, req#>>'{expense,line_id}');
  end if;

  if action = 'updateExpense' then
    select * into ex from ebda.expenses where id = (req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if not ebda.can_expense(u, ex) then return ebda.err('لا صلاحية على هذا المصروف'); end if;
    select * into cust from ebda.custodies where id = ex.custody_id;
    patch := req->'patch';
    if patch ? 'approval' then
      -- اعتماد المدير المباشر: يغيّر حالة الاعتماد فقط (لا يُسمح بتعديل المبلغ أثناء الاعتماد)
      if not ebda.can(u,'expense.approve') then return ebda.err('صلاحية اعتماد المصروفات مطلوبة'); end if;
      if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى'); end if;
      -- الفصل بين المهام: لا يعتمد أحد مصروفاً هو صاحب عهدته أو منشئه (إلا الأدمن)
      if urole<>'admin' and (ebda.owns_custody(u, cust) or coalesce(ex.created_by_id,'')=u.id) then return ebda.err('لا يمكنك اعتماد مصروفك بنفسك'); end if;
      if urole<>'admin' and cust.id is not null and not ebda.is_assigned_manager(u, cust) then
        return ebda.err('هذا المصروف تابع لمسئول عهدة مرتبط بمدير مباشر آخر'); end if;
      if urole<>'admin' and ex.approval<>'pending' then return ebda.err('تم اتخاذ القرار على هذا المصروف من قبل'); end if;
      if patch->>'approval' not in ('approved','rejected','returned','pending') then return ebda.err('قيمة اعتماد غير صحيحة'); end if;
      if patch->>'approval' in ('rejected','returned') and length(btrim(coalesce(patch->>'note','')))<2 then
        return ebda.err('اكتب سبب الرفض أو الإعادة للتعديل'); end if;
      update ebda.expenses set approval=patch->>'approval', approved_by=u.name, approved_by_id=u.id, approved_at=now()::text,
        approval_note=coalesce(patch->>'note',''),
        returned_by=case when patch->>'approval'='returned' then u.name else returned_by end,
        returned_at=case when patch->>'approval'='returned' then now()::text else returned_at end,
        return_reason=case when patch->>'approval'='returned' then btrim(patch->>'note') else return_reason end,
        return_needed=case when patch->>'approval'='returned' then btrim(coalesce(patch->>'needed','')) else return_needed end,
        updated_by=u.name, updated_at=now()::text
      where id=ex.id;
      if patch->>'approval'='returned' and cust.id is not null then
        return jsonb_build_object('ok',true,'mail','','outbox_ids', ebda.queue_expense_return(u, array[ex.id], btrim(patch->>'note'), btrim(coalesce(patch->>'needed',''))));
      end if;
      return jsonb_build_object('ok',true,'mail','');
    end if;
    -- تعديل بيانات المصروف: الأدمن دائماً، أو صاحب العهدة قبل الاعتماد فقط
    if not (urole='admin' or (ebda.owns_custody(u, cust) and coalesce(ex.cancelled_at,'')=''
            and (ex.approval in ('pending','draft','returned') or (ex.approval='approved' and ex.fin_approval='returned')))) then
      return ebda.err('لا يمكن التعديل بعد اعتماد الصرف'); end if;
    if patch ? 'date' and coalesce(patch->>'date','') > to_char(now() + interval '1 day','YYYY-MM-DD') then return ebda.err('تاريخ المصروف فى المستقبل'); end if;
    if patch ? 'line_id' and patch->>'line_id' is distinct from ex.line_id and exists(select 1 from ebda.lines l where l.id=patch->>'line_id' and coalesce(l.active,'نعم') not like '%نعم%') then
      return ebda.err('بند الموازنة معطّل — لا يقبل مصروفات جديدة'); end if;
    -- تغيير المبلغ أو البند بعد اعتماد المدير المباشر يعيد المصروف لاعتماده من جديد
    if urole<>'admin' and ex.approval='approved' and ((patch ? 'amount' and (patch->>'amount')::numeric is distinct from ex.amount)
                                                   or (patch ? 'line_id' and patch->>'line_id' is distinct from ex.line_id)) then
      update ebda.expenses set approval='returned', fin_approval='', return_reason='تم تعديل المبلغ/البند بعد الاعتماد — يلزم اعتماد جديد' where id=ex.id;
    end if;
    if patch ? 'line_id' and coalesce(patch->>'line_id','')<>'' and not exists(select 1 from ebda.lines l where l.id=patch->>'line_id' and l.school_id=ex.school_id) then
      return ebda.err('بند الموازنة غير تابع لجهة المصروف'); end if;
    if patch ? 'amount' and coalesce((patch->>'amount')::numeric,0) <= 0 then return ebda.err('قيمة المصروف يجب أن تكون أكبر من صفر'); end if;
    if patch ? 'catalog_sub_id' and ebda.valid_sub(coalesce(patch->>'line_id', ex.line_id), patch->>'catalog_sub_id') = '!' then
      return ebda.err('التصنيف الفرعى غير تابع لبند المصروف'); end if;
    update ebda.expenses set
      catalog_sub_id = case when patch ? 'catalog_sub_id' then ebda.valid_sub(coalesce(patch->>'line_id', ex.line_id), patch->>'catalog_sub_id')
                            when patch ? 'line_id' and patch->>'line_id' is distinct from ex.line_id then '' else catalog_sub_id end,
      date = coalesce(patch->>'date', date), line_id = coalesce(patch->>'line_id', line_id),
      amount = coalesce((patch->>'amount')::numeric, amount), description = coalesce(patch->>'description', description),
      spend_item = coalesce(patch->>'spend_item', spend_item), note = coalesce(patch->>'note', note),
      pay_method = coalesce(patch->>'pay_method', pay_method),
      settled = case when urole='admin' then coalesce(patch->>'settled', settled) else settled end,
      updated_by=u.name, updated_at=now()::text
    where id = ex.id;
    return jsonb_build_object('ok',true,'mail','');
  end if;

  -- المراجعة المالية: اعتماد مالى + مراجعة المستند + التسوية مع الحسابات
  if action = 'reviewExpense' then
    if not ebda.can(u,'expense.fin_approve') then return ebda.err('صلاحية الاعتماد المالى مطلوبة'); end if;
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if not ebda.can_expense(u, ex) then return ebda.err('هذا المصروف ليس ضمن نطاقك'); end if;
    select * into cust from ebda.custodies where id = ex.custody_id;
    if urole<>'admin' and ((cust.id is not null and ebda.owns_custody(u, cust)) or coalesce(ex.created_by_id,'')=u.id) then
      return ebda.err('لا يمكنك مراجعة مصروف أنت صاحبه أو منشئه'); end if;
    if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى'); end if;
    patch := req->'patch';
    if patch ? 'fin_approval' and coalesce(patch->>'fin_approval','') in ('rejected','returned') and length(btrim(coalesce(patch->>'fin_note','')))<2 then
      return ebda.err('اكتب سبب الرفض أو الإعادة للتعديل'); end if;
    if coalesce(patch->>'settled','') like '%نعم%' and coalesce(patch->>'fin_approval', ex.fin_approval)='returned' then
      return ebda.err('لا يمكن تسوية مصروف معاد للتعديل'); end if;
    if coalesce(patch->>'settled','') like '%نعم%' and urole<>'admin' and coalesce(ex.doc_url,'')=''
       and coalesce((select value from ebda.config where key='require_doc_to_settle'),'no')='yes' then
      return ebda.err('لا يمكن التسوية بدون المستند المؤيد'); end if;
    if (patch ? 'fin_approval' or coalesce(patch->>'settled','') like '%نعم%') and ex.approval<>'approved' and urole<>'admin' then
      return ebda.err('يجب اعتماد المدير المباشر أولاً'); end if;
    if patch ? 'fin_approval' and coalesce(patch->>'fin_approval','') not in ('','approved','rejected','returned') then return ebda.err('قيمة اعتماد مالى غير صحيحة'); end if;
    if coalesce(patch->>'settled','') like '%نعم%' and coalesce(patch->>'fin_approval', ex.fin_approval)='rejected' then
      return ebda.err('لا يمكن تسوية مصروف مرفوض مالياً'); end if;
    update ebda.expenses set
      fin_approval = case when patch ? 'fin_approval' then patch->>'fin_approval'
                          when coalesce(patch->>'settled','') like '%نعم%' and coalesce(fin_approval,'')='' then 'approved'   -- التسوية تتضمن الاعتماد المالى
                          else fin_approval end,
      fin_by = case when patch ? 'fin_approval' or (coalesce(patch->>'settled','') like '%نعم%' and coalesce(fin_approval,'')='') then u.name else fin_by end,
      fin_at = case when patch ? 'fin_approval' or (coalesce(patch->>'settled','') like '%نعم%' and coalesce(fin_approval,'')='') then now()::text else fin_at end,
      fin_note = coalesce(patch->>'fin_note', fin_note),
      review_status = coalesce(patch->>'review_status', review_status),
      review_note = coalesce(patch->>'review_note', review_note),
      settled = coalesce(patch->>'settled', settled),
      settled_at = case when patch ? 'settled' then case when coalesce(patch->>'settled','') like '%نعم%' then now()::text else '' end else settled_at end,
      updated_by=u.name, updated_at=now()::text
    where id = ex.id;
    update ebda.expenses set
      fin_by_id = case when patch ? 'fin_approval' or coalesce(patch->>'settled','') like '%نعم%' then u.id else fin_by_id end,
      settled_by = case when patch ? 'settled' then case when coalesce(patch->>'settled','') like '%نعم%' then u.name else '' end else settled_by end,
      settled_by_id = case when patch ? 'settled' then case when coalesce(patch->>'settled','') like '%نعم%' then u.id else '' end else settled_by_id end,
      returned_by = case when patch->>'fin_approval'='returned' then u.name else returned_by end,
      returned_at = case when patch->>'fin_approval'='returned' then now()::text else returned_at end,
      return_reason = case when patch->>'fin_approval'='returned' then btrim(patch->>'fin_note') else return_reason end,
      return_needed = case when patch->>'fin_approval'='returned' then btrim(coalesce(patch->>'needed','')) else return_needed end
    where id = ex.id;
    return jsonb_build_object('ok',true,'mail','') || case when patch->>'fin_approval'='approved' then ebda.over_warning(u, ex.line_id) else '{}'::jsonb end
      || case when patch->>'fin_approval'='returned' and cust.id is not null
              then jsonb_build_object('outbox_ids', ebda.queue_expense_return(u, array[ex.id], btrim(patch->>'fin_note'), btrim(coalesce(patch->>'needed','')))) else '{}'::jsonb end;
  end if;

  if action = 'uploadDoc' then
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى'); end if;
    if coalesce(req->>'link','')<>'' and btrim(req->>'link') !~* '^(https?://|storage:)' then return ebda.err('رابط المستند يجب أن يبدأ بـ http:// أو https://'); end if;
    select * into cust from ebda.custodies where id=ex.custody_id;
    if not (urole='admin'
            or (cust.id is not null and ebda.owns_custody(u, cust))
            or (urole='finance_manager' and ebda.can_expense(u, ex)))
    then return ebda.err('لا صلاحية لرفع مستند'); end if;
    if coalesce(req->>'link','')<>'' then
      update ebda.expenses set doc_url=req->>'link', doc_name=coalesce(req->>'filename','رابط مستند'), doc_type=coalesce(req->>'doc_type', doc_type), doc_is_link='نعم',
        updated_by=u.name, updated_at=now()::text where id=ex.id;
      return jsonb_build_object('ok',true,'url',req->>'link');
    end if;
    update ebda.expenses set doc_url=coalesce(req->>'dataUrl',''), doc_name=coalesce(req->>'filename',''), doc_type=coalesce(req->>'doc_type', doc_type), doc_is_link='لا',
      updated_by=u.name, updated_at=now()::text where id=ex.id;
    return jsonb_build_object('ok',true,'url',coalesce(req->>'dataUrl',''));
  end if;

  if action = 'deleteExpense' then
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if urole<>'admin' then
      select * into cust from ebda.custodies where id=ex.custody_id;
      if not (ebda.owns_custody(u, cust) and ex.approval in ('pending','draft','returned') and coalesce(ex.fin_approval,'')='') then
        return ebda.err('لا يمكن الحذف بعد اعتماد الصرف'); end if;
    elsif coalesce(ex.fin_approval,'')='approved' or coalesce(ex.settled,'') like '%نعم%' then
      return ebda.err('المصروف معتمد مالياً/مسوّى — استخدم «إلغاء المصروف» حتى يبقى أثره فى التقارير وتتبع التعديلات');
    end if;
    delete from ebda.expenses where id=ex.id;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'emailReport' then
    if not ebda.sees_budgets(u) then return ebda.err('لا صلاحية'); end if;
    return jsonb_build_object('ok',true,'note','الإرسال بالإيميل يتم عبر Apps Script أو Edge Function');
  end if;

  -- ================================================================ العهد والدفعات
  if action = 'addTranche' then
    if not ebda.can(u,'custody.create') then return ebda.err('لا صلاحية لإضافة دفعات للعهد'); end if;
    select * into cust from ebda.custodies where id=req#>>'{tranche,custody_id}';
    if not ebda.can_custody(u, cust) then return ebda.err('هذه العهدة ليست ضمن نطاقك'); end if;
    if coalesce(cust.status,'open') in ('settled','closed','cancelled') then return ebda.err('العهدة مسوّاة/مغلقة/ملغاة — أنشئ عهدة جديدة'); end if;
    newid := ebda.uid();
    insert into ebda.tranches(id,custody_id,date,amount,note)
    values(newid, cust.id, req#>>'{tranche,date}', coalesce((req#>>'{tranche,amount}')::numeric,0), coalesce(req#>>'{tranche,note}',''));
    return jsonb_build_object('ok',true,'item',(select to_jsonb(t) from ebda.tranches t where t.id=newid));
  end if;

  if action = 'addCustody' then
    if not ebda.can(u,'custody.create') then return ebda.err('لا صلاحية لإنشاء العهد'); end if;
    for ln in select * from jsonb_array_elements(coalesce(req#>'{custody,lines}','[]'::jsonb)) loop
      if not exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and l.school_id=req#>>'{custody,school_id}' and coalesce(l.deleted_at,'')='') then
        return ebda.err('بند غير تابع لمكان العهدة'); end if;
      if exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and coalesce(l.active,'نعم') not like '%نعم%') then
        return ebda.err('بند معطّل — لا يمكن التوزيع عليه'); end if;
      if not ebda.num_ok(ln->>'amount') then return ebda.err('مبلغ توزيع غير صحيح'); end if;
    end loop;
    if not ebda.can_school(u, req#>>'{custody,school_id}') then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    newid := ebda.uid();
    if coalesce(req#>>'{custody,amount}','') !~ '^\s*[0-9]*\.?[0-9]*\s*$' or coalesce((nullif(btrim(req#>>'{custody,amount}'),''))::numeric,0) < 0 then
      return ebda.err('قيمة العهدة غير صحيحة'); end if;
    if coalesce(btrim(req#>>'{custody,holder}'),'')='' and coalesce(btrim(req#>>'{custody,label}'),'')='' then
      return ebda.err('اكتب اسم مسئول العهدة'); end if;
    insert into ebda.custodies(id,label,holder,school_id,note,"user",code,status,opened_at,kind,purpose)
    values(newid, coalesce(nullif(req#>>'{custody,label}',''), 'عهدة '||coalesce(req#>>'{custody,holder}','')), req#>>'{custody,holder}', req#>>'{custody,school_id}', coalesce(req#>>'{custody,note}',''),
           coalesce(req#>>'{custody,user}',''), 'CUST-'||lpad(nextval('ebda.seq_cust')::text,3,'0'), 'open',
           coalesce(nullif(req#>>'{custody,date}',''), now()::text), coalesce(req#>>'{custody,kind}',''), coalesce(req#>>'{custody,purpose}',''));
    -- الاسم/المسئول من العاملين/حالة الاعتماد (المسودة لمن لا يملك صلاحية الاعتماد)
    update ebda.custodies set title=coalesce(req#>>'{custody,title}',''), holder_emp_id=coalesce(req#>>'{custody,holder_emp_id}',''),
      approval = case when coalesce(req#>>'{custody,approval}','approved') in ('draft','review') then req#>>'{custody,approval}'
                      when ebda.can(u,'custody.approve') then 'approved' else 'draft' end
    where id=newid;
    update ebda.custodies set approved_by=u.name, approved_at=now()::text where id=newid and approval='approved';
    for ln in select * from jsonb_array_elements(coalesce(req#>'{custody,lines}','[]'::jsonb)) loop
      if not exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and l.school_id=req#>>'{custody,school_id}' and coalesce(l.deleted_at,'')='') then
        raise exception 'بند غير تابع لمكان العهدة'; end if;
      insert into ebda.custody_lines(id,custody_id,line_id,amount) values(ebda.uid(), newid, ln->>'line_id', coalesce(nullif(btrim(ln->>'amount'),'')::numeric,0))
      on conflict (custody_id,line_id) do update set amount=excluded.amount;
    end loop;
    if coalesce((nullif(btrim(req#>>'{custody,amount}'),''))::numeric,0) > 0 then
      insert into ebda.tranches(id,custody_id,date,amount,note)
      values(ebda.uid(), newid, coalesce(nullif(req#>>'{custody,date}',''), to_char(now(),'YYYY-MM-DD')),
             (req#>>'{custody,amount}')::numeric, 'القيمة الأساسية للعهدة');
    end if;
    return jsonb_build_object('ok',true,'item',(select to_jsonb(c) || jsonb_build_object(
        'received',(select coalesce(sum(t.amount),0) from ebda.tranches t where t.custody_id=c.id),'spent',0,'exp_count',0)
      from ebda.custodies c where c.id=newid),
      'tranches', coalesce((select jsonb_agg(to_jsonb(t)) from ebda.tranches t where t.custody_id=newid),'[]'::jsonb),
      'custody_lines', coalesce((select jsonb_agg(to_jsonb(t)) from ebda.custody_lines t where t.custody_id=newid),'[]'::jsonb));
  end if;

  if action = 'updateCustody' then
    select * into cust from ebda.custodies where id=(req->>'id');
    if not found then return ebda.err('العهدة غير موجودة'); end if;
    patch := req->'patch';
    -- مسئول العهدة: يقدّم عهدته للتسوية فقط
    if urole='custody_officer' then
      if not ebda.owns_custody(u, cust) then return ebda.err('لا صلاحية على هذه العهدة'); end if;
      if (patch - 'status' - 'id') <> '{}'::jsonb or coalesce(patch->>'status','')<>'pending_settlement' then
        return ebda.err('مسئول العهدة يستطيع تقديم العهدة للتسوية فقط'); end if;
      update ebda.custodies set status='pending_settlement' where id=cust.id and coalesce(status,'open')='open';
      return jsonb_build_object('ok',true);
    end if;
    if not (ebda.can(u,'custody.create') or ebda.can(u,'custody.approve')) then return ebda.err('لا صلاحية لتعديل العهد'); end if;
    if not ebda.can_custody(u, cust) then return ebda.err('هذه العهدة ليست ضمن نطاقك'); end if;
    if coalesce(cust.status,'open')='cancelled' then return ebda.err('العهدة ملغاة — لا يمكن تعديلها'); end if;
    if coalesce(cust.approval,'approved')='approved' and urole<>'admin'
       and (patch ? 'school_id' or patch ? 'holder' or patch ? 'user' or patch ? 'title' or patch ? 'kind' or patch ? 'label') then
      return ebda.err('العهدة معتمدة — تعديل بياناتها الأساسية للأدمن فقط'); end if;
    if patch ? 'school_id' and not ebda.can_school(u, patch->>'school_id') then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if patch ? 'status' and coalesce(patch->>'status','') not in ('open','pending_settlement','settled','closed') then return ebda.err('حالة عهدة غير صحيحة'); end if;
    if coalesce(patch->>'status','') in ('settled','closed') and exists(select 1 from ebda.expenses e where e.custody_id=cust.id
         and e.approval<>'rejected' and coalesce(e.fin_approval,'')<>'rejected' and not (coalesce(e.settled,'') like '%نعم%')) then
      return ebda.err('توجد مصروفات غير مسوّاة على هذه العهدة — سوِّها أو ارفضها أولاً'); end if;
    update ebda.custodies set label=coalesce(patch->>'label',label), holder=coalesce(patch->>'holder',holder),
      school_id=coalesce(patch->>'school_id',school_id), note=coalesce(patch->>'note',note), "user"=coalesce(patch->>'user',"user"),
      kind=coalesce(patch->>'kind',kind), purpose=coalesce(patch->>'purpose',purpose),
      title=coalesce(patch->>'title',title), holder_emp_id=coalesce(patch->>'holder_emp_id',holder_emp_id),
      status=coalesce(patch->>'status',status),
      settled_at = case when patch->>'status'='settled' then now()::text else settled_at end,
      settled_by = case when patch->>'status'='settled' then u.name else settled_by end,
      closed_at  = case when patch->>'status'='closed' then now()::text else closed_at end
    where id=cust.id;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'deleteCustody' then
    if urole<>'admin' then return ebda.err('حذف العهدة للأدمن فقط — استخدم «إغلاق العهدة»'); end if;
    if exists(select 1 from ebda.expenses e where e.custody_id=(req->>'id') and e.approval='approved') then
      return ebda.err('لا يمكن حذف عهدة عليها مصروفات معتمدة — أغلقها بدلاً من الحذف'); end if;
    delete from ebda.expenses where custody_id=(req->>'id');
    delete from ebda.tranches where custody_id=(req->>'id');
    delete from ebda.custodies where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ بنود الموازنة
  if action = 'addLine' then
    if not ebda.can(u,'budget.edit') then return ebda.err('لا صلاحية لإضافة بنود الموازنة'); end if;
    if not ebda.can_school(u, req#>>'{line,school_id}') then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if not exists(select 1 from ebda.schools s where s.id=req#>>'{line,school_id}') then return ebda.err('الجهة غير موجودة'); end if;
    if coalesce(req#>>'{line,catalog_id}','')<>'' then
      if not exists(select 1 from ebda.line_catalog c where c.id=req#>>'{line,catalog_id}') then return ebda.err('البند الموحد غير موجود'); end if;
      req := jsonb_set(req, '{line,name}', to_jsonb((select c.name from ebda.line_catalog c where c.id=req#>>'{line,catalog_id}')));
    end if;
    if coalesce(btrim(req#>>'{line,name}'),'')='' then return ebda.err('اكتب اسم البند'); end if;
    if exists(select 1 from ebda.lines l where l.school_id=req#>>'{line,school_id}' and coalesce(l.deleted_at,'')=''
              and l.catalog_id = coalesce(nullif(req#>>'{line,catalog_id}',''), ebda.catalog_resolve(req#>>'{line,name}'))) then
      return ebda.err('هذا البند موجود بالفعل لهذه الجهة (نفس البند الموحد «'||coalesce((select c.name from ebda.line_catalog c
        where c.id = coalesce(nullif(req#>>'{line,catalog_id}',''), ebda.catalog_resolve(req#>>'{line,name}'))),'')||'») — عدّل مخصصه بدلاً من إضافته مرة أخرى'); end if;
    if coalesce(req#>>'{line,allocated}','0') !~ '^\s*[0-9]*\.?[0-9]*\s*$' then return ebda.err('المبلغ يجب أن يكون رقماً موجباً'); end if;
    if exists(select 1 from ebda.lines l where l.school_id=req#>>'{line,school_id}' and coalesce(l.deleted_at,'')=''
              and ebda.norm_txt(l.name)=ebda.norm_txt(req#>>'{line,name}') and ebda.norm_txt(l.section)=ebda.norm_txt(coalesce(req#>>'{line,section}',''))) then
      return ebda.err('هذا البند موجود بالفعل فى نفس القسم لهذه الجهة — عدّل مخصصه بدلاً من إضافته مرة أخرى'); end if;
    newid := ebda.uid();
    insert into ebda.lines(id,school_id,section,name,allocated,note,monthly_plan,catalog_id)
    values(newid, req#>>'{line,school_id}', coalesce(req#>>'{line,section}',''), req#>>'{line,name}', coalesce((req#>>'{line,allocated}')::numeric,0),
           coalesce(req#>>'{line,note}',''), coalesce(req#>>'{line,monthly_plan}',''), coalesce(req#>>'{line,catalog_id}',''));
    return jsonb_build_object('ok',true,'item',(select to_jsonb(l) from ebda.lines l where l.id=newid));
  end if;

  if action in ('updateLine','deleteLine') then
    if not ebda.can(u,'budget.edit') then return ebda.err('لا صلاحية لتعديل الموازنة'); end if;
    sid := (select school_id from ebda.lines where id=(req->>'id'));
    if sid is null then return ebda.err('البند غير موجود'); end if;
    if not ebda.can_school(u, sid) then return ebda.err('هذه الجهة ليست ضمن نطاقك'); end if;
    if action='updateLine' then
      patch := req->'patch';
      if patch ? 'allocated' and coalesce(patch->>'allocated','0') !~ '^\s*[0-9]*\.?[0-9]*\s*$' then return ebda.err('المبلغ يجب أن يكون رقماً موجباً'); end if;
      if patch ? 'name' and exists(select 1 from ebda.lines l, ebda.lines me where me.id=(req->>'id')
            and l.school_id=me.school_id and l.id<>me.id and coalesce(l.deleted_at,'')=''
            and l.catalog_id = ebda.catalog_resolve(patch->>'name')) then
        return ebda.err('يوجد بند بنفس البند الموحد لهذه الجهة'); end if;
      if (patch ? 'name' or patch ? 'section') and exists(select 1 from ebda.lines l, ebda.lines me where me.id=(req->>'id')
            and l.school_id=me.school_id and l.id<>me.id and coalesce(l.deleted_at,'')=''
            and ebda.norm_txt(l.name)=ebda.norm_txt(coalesce(patch->>'name',me.name))
            and ebda.norm_txt(l.section)=ebda.norm_txt(coalesce(patch->>'section',me.section))) then
        return ebda.err('يوجد بند بنفس الاسم فى نفس القسم لهذه الجهة'); end if;
      update ebda.lines set section=coalesce(patch->>'section',section), name=coalesce(patch->>'name',name),
        allocated=coalesce((patch->>'allocated')::numeric,allocated), note=coalesce(patch->>'note',note),
        monthly_plan=coalesce(patch->>'monthly_plan',monthly_plan)
      where id=(req->>'id');
    else
      if exists(select 1 from ebda.expenses e where e.line_id=(req->>'id')) then
        return ebda.err('لا يمكن حذف بند عليه مصروفات — عدّل اسمه أو مخصصه بدلاً من ذلك'); end if;
      delete from ebda.lines where id=(req->>'id');
    end if;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'importBudget' and coalesce(req->>'mode','') = 'merge' then
    if not ebda.can(u,'budget.edit') then return ebda.err('لا صلاحية لاستيراد الموازنة'); end if;
    if jsonb_typeof(coalesce(req->'lines','null'::jsonb)) <> 'array' or jsonb_array_length(req->'lines') = 0 then
      return ebda.err('لا توجد بنود للاستيراد'); end if;
    -- (1) التحقق من كل السطور قبل أى حفظ
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
    -- (2) التنفيذ: تحديث المطابق / إضافة الجديد فقط
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
        insert into ebda.lines(id,school_id,section,name,allocated,note,monthly_plan)
        values(ebda.uid(), sid, coalesce(ln->>'section',''), btrim(ln->>'name'), coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0),
               coalesce(ln->>'note',''), coalesce(ln->>'monthly_plan',''));
        n_new := n_new + 1;
      else
        select * into lrow from ebda.lines where id=lid;
        if lrow.allocated is distinct from coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0)
           or (coalesce(ln->>'note','')<>'' and coalesce(lrow.note,'')<>(ln->>'note'))
           or (coalesce(ln->>'monthly_plan','')<>'' and coalesce(lrow.monthly_plan,'')<>(ln->>'monthly_plan'))
           or (coalesce(ln->>'rename','')='1' and (lrow.name<>btrim(ln->>'name') or coalesce(lrow.section,'')<>coalesce(ln->>'section',''))) then
          update ebda.lines set allocated=coalesce((nullif(btrim(ln->>'allocated'),''))::numeric,0),
            note=case when coalesce(ln->>'note','')<>'' then ln->>'note' else note end,
            monthly_plan=case when coalesce(ln->>'monthly_plan','')<>'' then ln->>'monthly_plan' else monthly_plan end,
            name=case when coalesce(ln->>'rename','')='1' then btrim(ln->>'name') else name end,
            section=case when coalesce(ln->>'rename','')='1' then coalesce(ln->>'section',section) else section end
          where id=lid;
          n_upd := n_upd + 1;
        else
          n_same := n_same + 1;
        end if;
      end if;
    end loop;
    return jsonb_build_object('ok',true,'added',n_new,'updated',n_upd,'unchanged',n_same,'count',n_new+n_upd+n_same);
  end if;

  if action = 'importBudget' then
    if not ebda.can(u,'budget.edit') then return ebda.err('لا صلاحية لاستيراد الموازنة'); end if;
    sid := req->>'school_id';
    if req ? 'newSchool' then
      if urole<>'admin' then return ebda.err('إنشاء جهة جديدة للأدمن فقط'); end if;
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
    delete from ebda.lines where school_id = sid;
    for ln in select * from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) loop
      insert into ebda.lines(id,school_id,section,name,allocated,note)
      values(ebda.uid(), sid, coalesce(ln->>'section',''), coalesce(ln->>'name',''), coalesce((ln->>'allocated')::numeric,0), '');
    end loop;
    return jsonb_build_object('ok',true,'school_id',sid,'count',jsonb_array_length(coalesce(req->'lines','[]'::jsonb)));
  end if;

  if action in ('addSpendItem','deleteSpendItem','addHolder','deleteHolder') then
    if urole not in ('admin','finance_manager') then return ebda.err('صلاحية الأدمن أو المدير المالى مطلوبة'); end if;
    if action = 'addSpendItem' then newid:=ebda.uid(); insert into ebda.spend_items(id,name) values(newid, req#>>'{item,name}'); return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.spend_items z where z.id=newid)); end if;
    if action = 'deleteSpendItem' then delete from ebda.spend_items where id=(req->>'id'); return jsonb_build_object('ok',true); end if;
    if action = 'addHolder' then newid:=ebda.uid(); insert into ebda.holders(id,name,title) values(newid, req#>>'{item,name}', coalesce(req#>>'{item,title}','')); return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.holders z where z.id=newid)); end if;
    delete from ebda.holders where id=(req->>'id'); return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ إدارة المستخدمين
  if action in ('addUser','updateUser','deleteUser','resetPin') then
    if not ebda.can_manage_users(u) then return ebda.err('إدارة المستخدمين للأدمن فقط'); end if;
    if action <> 'addUser' then
      select * into xu from ebda.users where id=(req->>'id');
      if not found then return ebda.err('المستخدم غير موجود'); end if;
      if urole<>'admin' and ebda.role_key(xu.role)='admin' then return ebda.err('لا يمكن تعديل حساب الأدمن'); end if;
    end if;
    if action = 'resetPin' then
      update ebda.users set pin=ebda.pin_hash('0000'), must_reset='نعم' where id=xu.id;
      delete from ebda.sessions where user_id=xu.id;
      return jsonb_build_object('ok',true);
    end if;
    if action = 'deleteUser' then
      if xu.id = u.id then return ebda.err('لا يمكنك حذف حسابك'); end if;
      if ebda.role_key(xu.role)='admin' and (select count(*) from ebda.users z where ebda.role_key(z.role)='admin' and coalesce(z.active,'') like '%نعم%')<=1 then
        return ebda.err('لا يمكن حذف آخر أدمن'); end if;
      if exists(select 1 from ebda.custodies c where c.user_id=xu.id) or exists(select 1 from ebda.expenses e where e.created_by_id=xu.id)
         or exists(select 1 from ebda.users z where z.manager_id=xu.id) then
        return ebda.err('لا يمكن حذف مستخدم له عهد أو مصروفات أو فريق — عطّله بدلاً من الحذف'); end if;
      delete from ebda.sessions where user_id=xu.id;
      delete from ebda.users where id=xu.id;
      return jsonb_build_object('ok',true);
    end if;
    dj := case when action='addUser' then req->'user' else req->'patch' end;
    if dj ? 'role' and ebda.role_key(dj->>'role')='' then return ebda.err('دور غير معروف'); end if;
    -- v9: البريد الرسمى إلزامى وبتنسيق صحيح (تعديل كلمة السر/التفعيل/الصلاحيات وحدها لا يُعطَّل بسببه)
    if (action = 'addUser' or dj ? 'email') and not ebda.email_ok(dj->>'email') then
      return ebda.err('البريد الإلكترونى الرسمى إلزامى وبتنسيق صحيح (مثال: name@ebda-edu.com)'); end if;
    if action = 'updateUser' and not ebda.email_ok(coalesce(dj->>'email', xu.email))
       and exists(select 1 from jsonb_object_keys(dj) k where k not in ('pin','active','perms','must_reset')) then
      return ebda.err('أضف البريد الإلكترونى الرسمى لهذا المستخدم قبل حفظ التعديل'); end if;
    if dj ? 'email' then dj := jsonb_set(dj, '{email}', to_jsonb(lower(btrim(dj->>'email')))); end if;
    if urole<>'admin' and (ebda.role_key(dj->>'role')='admin' or dj ? 'perms') then return ebda.err('منح صلاحيات الأدمن للأدمن فقط'); end if;
    if (ebda.role_key(dj->>'role') = 'observer' or (action <> 'addUser' and ebda.role_key(xu.role) = 'observer')) and urole <> 'admin' then
      return ebda.err('حسابات «المتابع» يديرها الأدمن فقط'); end if;
    if action = 'addUser' then
      if coalesce(dj->>'username','')='' or length(coalesce(dj->>'pin',''))<4 then return ebda.err('اسم المستخدم وكلمة سر من 4 خانات على الأقل مطلوبان'); end if;
      if exists(select 1 from ebda.users z where z.username=dj->>'username') then return ebda.err('اسم المستخدم مستخدم من قبل'); end if;
      newid := ebda.uid();
      if coalesce(dj->>'manager_id','')<>'' and not exists(select 1 from ebda.users z where z.id=dj->>'manager_id') then return ebda.err('المدير المباشر غير موجود'); end if;
      insert into ebda.users(id,username,pin,name,role,schools,active,email,perms,must_reset,manager_id,dept)
      values(newid, dj->>'username', ebda.pin_hash(dj->>'pin'), dj->>'name', coalesce(ebda.role_legacy(dj->>'role'),'custody'),
         coalesce(dj->>'schools',''), coalesce(dj->>'active','نعم'), coalesce(dj->>'email',''), coalesce(dj->>'perms',''), 'نعم',
         coalesce(dj->>'manager_id',''), coalesce(dj->>'dept',''));
      return jsonb_build_object('ok',true,'item',(select ebda.user_public(z) from ebda.users z where z.id=newid));
    end if;
    if xu.id = u.id and dj ? 'role' and ebda.role_key(dj->>'role')<>urole then return ebda.err('لا يمكنك تغيير دورك بنفسك'); end if;
    if dj ? 'username' and exists(select 1 from ebda.users z where z.username=dj->>'username' and z.id<>xu.id) then return ebda.err('اسم المستخدم مستخدم من قبل'); end if;
    if coalesce(dj->>'manager_id','')<>'' and (dj->>'manager_id'=xu.id or not exists(select 1 from ebda.users z where z.id=dj->>'manager_id')) then
      return ebda.err('المدير المباشر غير صحيح'); end if;
    update ebda.users set username=coalesce(nullif(dj->>'username',''),username),
      pin = case when length(coalesce(dj->>'pin',''))>=4 and coalesce(dj->>'pin','') not like '$2%' then ebda.pin_hash(dj->>'pin') else pin end,
      name=coalesce(dj->>'name',name), role=coalesce(ebda.role_legacy(dj->>'role'),role), schools=coalesce(dj->>'schools',schools),
      active=coalesce(dj->>'active',active), email=coalesce(dj->>'email',email), perms=coalesce(dj->>'perms',perms),
      manager_id=coalesce(dj->>'manager_id',manager_id), dept=coalesce(dj->>'dept',dept)
    where id=xu.id;
    if length(coalesce(dj->>'pin',''))>=4 or coalesce(dj->>'active','نعم') not like '%نعم%' or dj ? 'role' or dj ? 'username' then
      delete from ebda.sessions where user_id=xu.id;
    end if;
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ v4: أسماء العهد (Master Data)
  if action = 'saveCustodyName' then
    if urole<>'admin' then return ebda.err('إدارة أسماء العهد للأدمن فقط'); end if;
    dj := req->'item';
    if coalesce(btrim(dj->>'name'),'')='' then return ebda.err('اكتب اسم العهدة'); end if;
    if exists(select 1 from ebda.custody_names z where ebda.norm_txt(z.name)=ebda.norm_txt(dj->>'name') and z.id<>coalesce(dj->>'id','')) then
      return ebda.err('هذا الاسم موجود بالفعل'); end if;
    if coalesce(dj->>'id','')='' then
      newid := ebda.uid();
      insert into ebda.custody_names(id,name,active,sort,sections)
      values(newid, btrim(dj->>'name'), coalesce(nullif(dj->>'active',''),'نعم'), coalesce(nullif(dj->>'sort','')::int, 99), coalesce(dj->>'sections',''));
    else
      newid := dj->>'id';
      update ebda.custody_names set name=btrim(dj->>'name'), active=coalesce(nullif(dj->>'active',''),active),
        sort=coalesce(nullif(dj->>'sort','')::int,sort), sections=coalesce(dj->>'sections',sections) where id=newid;
      if not found then return ebda.err('الاسم غير موجود'); end if;
    end if;
    return jsonb_build_object('ok',true,'id',newid);
  end if;

  -- ================================================================ v4: دورة اعتماد العهدة · الإلغاء · التوزيع على البنود
  if action in ('submitCustody','approveCustody','cancelCustody','setCustodyLines') then
    select * into cust from ebda.custodies where id=coalesce(req->>'id', req->>'custody_id');
    if not found then return ebda.err('العهدة غير موجودة'); end if;
    if not ebda.can_custody(u, cust) then return ebda.err('هذه العهدة ليست ضمن نطاقك'); end if;
    if coalesce(cust.status,'open')='cancelled' then return ebda.err('العهدة ملغاة بالفعل'); end if;

    if action = 'submitCustody' then  -- مسودة ← مراجعة
      if not ebda.can(u,'custody.create') then return ebda.err('لا صلاحية'); end if;
      if coalesce(cust.approval,'approved')<>'draft' then return ebda.err('العهدة ليست مسودة'); end if;
      update ebda.custodies set approval='review', submitted_by=u.name where id=cust.id;
      return jsonb_build_object('ok',true);
    end if;

    if action = 'approveCustody' then  -- مراجعة/مسودة ← معتمدة
      if not ebda.can(u,'custody.approve') then return ebda.err('صلاحية اعتماد العهد مطلوبة (الأدمن أو المدير المالى)'); end if;
      if coalesce(cust.approval,'approved')='approved' then return ebda.err('العهدة معتمدة بالفعل'); end if;
      if not exists(select 1 from ebda.tranches t where t.custody_id=cust.id and t.amount>0) then return ebda.err('لا يمكن اعتماد عهدة بدون قيمة'); end if;
      update ebda.custodies set approval='approved', approved_by=u.name, approved_at=now()::text where id=cust.id;
      return jsonb_build_object('ok',true);
    end if;

    if action = 'cancelCustody' then  -- للأدمن فقط، حتى بعد الاعتماد — لا حذف: الحالة «ملغاة» مع السبب
      if not ebda.can(u,'records.cancel') then return ebda.err('إلغاء العهدة للأدمن فقط'); end if;
      if length(coalesce(btrim(req->>'reason'),''))<3 then return ebda.err('اكتب سبب الإلغاء'); end if;
      if coalesce(cust.status,'')='cancelled' then return ebda.err('العهدة ملغاة بالفعل'); end if;
      update ebda.custodies set status='cancelled', cancel_reason=btrim(req->>'reason'), cancelled_by=u.name, cancelled_at=now()::text where id=cust.id;
      update ebda.expenses set cancelled_at=now()::text, cancelled_by=u.name,
        cancel_reason='ضمن إلغاء العهدة '||coalesce(cust.code,'')||': '||btrim(req->>'reason'), updated_by=u.name, updated_at=now()::text
      where custody_id=cust.id and coalesce(cancelled_at,'')='';
      get diagnostics n_emp = row_count;
      return jsonb_build_object('ok',true,'expenses_cancelled',n_emp);
    end if;

    -- setCustodyLines: المخصص داخل العهدة لكل بند
    if not ebda.can(u,'custody.create') then return ebda.err('لا صلاحية لتعديل توزيع العهدة'); end if;
    if coalesce(cust.approval,'approved')='approved' and urole<>'admin' then return ebda.err('العهدة معتمدة — تعديل توزيعها للأدمن فقط'); end if;
    if coalesce(cust.status,'open') in ('closed','settled') then return ebda.err('لا يمكن تعديل عهدة مسوّاة/مغلقة'); end if;
    for ln in select * from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) loop
      if not exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and l.school_id=cust.school_id and coalesce(l.deleted_at,'')='') then
        return ebda.err('بند غير تابع لمكان العهدة'); end if;
      if exists(select 1 from ebda.lines l where l.id=ln->>'line_id' and coalesce(l.active,'نعم') not like '%نعم%')
         and not exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and cl.line_id=ln->>'line_id') then
        return ebda.err('بند معطّل — لا يمكن التوزيع عليه'); end if;
      if not ebda.num_ok(ln->>'amount') or coalesce(nullif(btrim(ln->>'amount'),'')::numeric,0) < 0 then return ebda.err('مبلغ توزيع غير صحيح'); end if;
      if exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and cl.line_id=ln->>'line_id' and coalesce(cl.cancelled_at,'')<>'') then
        return ebda.err('البند «'||coalesce((select name from ebda.lines where id=ln->>'line_id'),'')||'» ملغى داخل هذه العهدة'); end if;
    end loop;
    if exists(select 1 from ebda.custody_lines cl where cl.custody_id=cust.id and coalesce(cl.cancelled_at,'')=''
              and not exists(select 1 from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) x where x->>'line_id'=cl.line_id)
              and exists(select 1 from ebda.expenses e where e.custody_id=cust.id and e.line_id=cl.line_id)) then
      return ebda.err('لا يمكن إزالة بند عليه مصروفات من توزيع العهدة'); end if;
    delete from ebda.custody_lines cl where cl.custody_id=cust.id and coalesce(cl.cancelled_at,'')=''
      and not exists(select 1 from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) x where x->>'line_id'=cl.line_id);
    for ln in select * from jsonb_array_elements(coalesce(req->'lines','[]'::jsonb)) loop
      insert into ebda.custody_lines(id,custody_id,line_id,amount,note)
      values(ebda.uid(), cust.id, ln->>'line_id', coalesce(nullif(btrim(ln->>'amount'),'')::numeric,0), coalesce(ln->>'note',''))
      on conflict (custody_id,line_id) do update set amount=excluded.amount, note=excluded.note;
    end loop;
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ v4: حذف الموازنة (حذف منطقى للأدمن فقط) واسترجاعها
  if action in ('deleteBudget','restoreBudget') then
    if urole<>'admin' then return ebda.err('حذف الموازنة للأدمن فقط'); end if;
    sid := req->>'school_id';
    if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then return ebda.err('المكان غير موجود'); end if;
    if action = 'deleteBudget' then
      if length(coalesce(btrim(req->>'reason'),''))<3 then return ebda.err('اكتب سبب الحذف'); end if;
      n := (select count(*) from ebda.expenses e join ebda.lines l on l.id=e.line_id where l.school_id=sid and coalesce(l.deleted_at,'')='');
      if n > 0 then return ebda.err('لا يمكن حذف موازنة مرتبط بها '||n||' مصروف — المصروفات والتقارير تعتمد عليها'); end if;
      if exists(select 1 from ebda.custody_lines cl join ebda.lines l on l.id=cl.line_id where l.school_id=sid and coalesce(l.deleted_at,'')='') then
        return ebda.err('لا يمكن حذف موازنة موزعة على عهد'); end if;
      if exists(select 1 from ebda.request_items it join ebda.lines l on l.id=it.line_id join ebda.requests r on r.id=it.request_id
                where l.school_id=sid and coalesce(l.deleted_at,'')='' and r.status in ('pending_supervisor','pending_accountant')) then
        return ebda.err('توجد طلبات عهد معلّقة على بنود هذه الموازنة'); end if;
      n := (select count(*) from ebda.lines l where l.school_id=sid and coalesce(l.deleted_at,'')='');
      if n = 0 then return ebda.err('لا توجد موازنة لحذفها'); end if;
      update ebda.lines set deleted_at=now()::text, deleted_by=u.name, delete_reason=btrim(req->>'reason')
      where school_id=sid and coalesce(deleted_at,'')='';
      return jsonb_build_object('ok',true,'count',n);
    end if;
    -- استرجاع: البنود التى لا يوجد مثلها حالياً فقط (لا تكرار)
    update ebda.lines l set deleted_at='', deleted_by='', delete_reason=''
    where l.school_id=sid and coalesce(l.deleted_at,'')<>''
      and not exists(select 1 from ebda.lines a where a.school_id=sid and coalesce(a.deleted_at,'')='' and a.id<>l.id
                     and ebda.norm_txt(a.name)=ebda.norm_txt(l.name) and ebda.norm_txt(a.section)=ebda.norm_txt(l.section));
    get diagnostics n_new = row_count;
    return jsonb_build_object('ok',true,'count',n_new);
  end if;

  -- ================================================================ v4: الرواتب الشهرية (Payroll)
  if action = 'importPayroll' then
    if not ebda.can(u,'payroll.import') then return ebda.err('صلاحية استيراد الرواتب مطلوبة'); end if;
    sid := req->>'school_id';
    if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then return ebda.err('المكان غير موجود'); end if;
    if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
    if coalesce(req->>'month','') !~ '^[0-9]{4}-[0-9]{2}$' then return ebda.err('الشهر غير صحيح'); end if;
    if exists(select 1 from ebda.payroll_periods p where p.school_id=sid and p.month=req->>'month' and p.status='approved') then
      return ebda.err('رواتب هذا الشهر معتمدة — يجب إعادة فتحها (للأدمن) قبل الاستيراد'); end if;
    if jsonb_typeof(coalesce(req->'rows','null'::jsonb))<>'array' or jsonb_array_length(req->'rows')=0 then return ebda.err('لا توجد بيانات'); end if;
    -- (1) تحقق كامل قبل أى حفظ
    for ln in select * from jsonb_array_elements(req->'rows') loop
      if coalesce(btrim(ln->>'name'),'')='' then return ebda.err('يوجد سطر بدون اسم موظف'); end if;
      if not (ebda.num_ok(ln->>'salary') and ebda.num_ok(ln->>'net') and ebda.num_ok(ln->>'ded_total') and ebda.num_ok(ln->>'absent_days')
              and ebda.num_ok(ln->>'permissions') and ebda.num_ok(ln->>'deduct_days') and ebda.num_ok(ln->>'month_days') and ebda.num_ok(ln->>'allowances')
              and ebda.num_ok(ln->>'direct_ded') and ebda.num_ok(ln->>'leave_opening') and ebda.num_ok(ln->>'leave_used') and ebda.num_ok(ln->>'leave_balance')) then
        return ebda.err('قيمة رقمية غير صحيحة للموظف: '||(ln->>'name')); end if;
      if coalesce(ln->>'employee_id','')<>'' and not exists(select 1 from ebda.employees e where e.id=ln->>'employee_id' and e.school_id=sid) then
        return ebda.err('الموظف المطابق غير تابع لهذا المكان: '||(ln->>'name')); end if;
    end loop;
    -- (2) الموظف: مطابقة بالمعرّف ثم الرقم القومى ثم الاسم — لا يُنشأ الموظف مرة أخرى كل شهر
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
      -- بيانات العاملين فقط (مثل شيت «مؤثرات الرواتب»: الكود والحالة التأمينية) — بدون قسيمة شهرية
      if coalesce(ln->>'employee_only','')='1' then continue; end if;
      -- (3) قسيمة الشهر: سطر واحد لكل موظف لكل شهر (تحديث عند إعادة الاستيراد مع الإبقاء على المؤثرات)
      pid := null;
      select p.id into pid from ebda.payslips p where p.employee_id=lid and p.month=req->>'month' order by p.id limit 1;
      if pid is null then
        pid := ebda.uid();
        insert into ebda.payslips(id,employee_id,emp_name,school_id,month,created_by,created_at,adjustments) values(pid, lid, btrim(ln->>'name'), sid, req->>'month', u.name, now()::text, '{}'::jsonb);
        n_new := n_new + 1;
      else
        n_upd := n_upd + 1;
      end if;
      update ebda.payslips set emp_name=btrim(ln->>'name'), staff_group=coalesce(ln->>'staff_group',''), job=coalesce(ln->>'job',''),
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
        net_import=coalesce(nullif(btrim(ln->>'net'),'')::numeric,0), note=coalesce(ln->>'note',''), source_file=coalesce(req->>'file_name',''),
        updated_at=now()::text
      where id=pid;
      update ebda.payslips set net=ebda.payslip_net(net_import, adjustments) where id=pid;
    end loop;
    if n_new + n_upd > 0 then
      insert into ebda.payroll_periods(id,school_id,month,status,file_name,imported_at,imported_by)
      values(ebda.uid(), sid, req->>'month', 'draft', coalesce(req->>'file_name',''), now()::text, u.name)
      on conflict (school_id,month) do update set file_name=excluded.file_name, imported_at=excluded.imported_at, imported_by=excluded.imported_by;
    end if;
    return jsonb_build_object('ok',true,'employees_added',n_emp,'payslips_added',n_new,'payslips_updated',n_upd);
  end if;

  if action = 'adjustPayslip' then  -- المؤثرات على الراتب (عناصر الراتب من Master Data)
    if not ebda.can(u,'payroll.import') then return ebda.err('صلاحية تعديل الرواتب مطلوبة'); end if;
    select p.school_id, p.month into sid, nk from ebda.payslips p where p.id=(req->>'id');
    if sid is null then return ebda.err('السطر غير موجود'); end if;
    if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
    if exists(select 1 from ebda.payroll_periods pp where pp.school_id=sid and pp.month=nk and pp.status='approved') then
      return ebda.err('رواتب هذا الشهر معتمدة — لا يمكن التعديل'); end if;
    if jsonb_typeof(coalesce(req->'adjustments','{}'::jsonb))<>'object' then return ebda.err('بيانات غير صحيحة'); end if;
    if exists(select 1 from jsonb_each_text(req->'adjustments') a where not ebda.num_ok(a.value) or coalesce(nullif(btrim(a.value),'')::numeric,0)<0
              or not exists(select 1 from ebda.payroll_components c where c.code=a.key and c.active like '%نعم%')) then
      return ebda.err('عنصر راتب غير معروف أو قيمة غير صحيحة'); end if;
    update ebda.payslips set adjustments=(select coalesce(jsonb_object_agg(a.key, a.value::numeric),'{}'::jsonb)
                                         from jsonb_each_text(req->'adjustments') a where coalesce(nullif(btrim(a.value),'')::numeric,0)<>0),
      note=coalesce(req->>'note', note), updated_at=now()::text
    where id=(req->>'id');
    update ebda.payslips set net=ebda.payslip_net(net_import, adjustments) where id=(req->>'id');
    return jsonb_build_object('ok',true,'net',(select net from ebda.payslips where id=(req->>'id')));
  end if;

  if action in ('approvePayroll','reopenPayroll') then
    sid := req->>'school_id';
    if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
    select p.id into pid from ebda.payroll_periods p where p.school_id=sid and p.month=req->>'month';
    if pid is null then return ebda.err('لا توجد رواتب مستوردة لهذا الشهر'); end if;
    if action='approvePayroll' then
      if not ebda.can(u,'payroll.approve') then return ebda.err('صلاحية اعتماد الرواتب مطلوبة'); end if;
      update ebda.payroll_periods set status='approved', approved_by=u.name, approved_at=now()::text where id=pid;
    else
      if urole<>'admin' then return ebda.err('إعادة فتح رواتب معتمدة للأدمن فقط'); end if;
      update ebda.payroll_periods set status='draft', approved_by='', approved_at='' where id=pid;
    end if;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'savePayrollComponent' then
    if urole<>'admin' then return ebda.err('إدارة عناصر الراتب للأدمن فقط'); end if;
    dj := req->'item';
    if coalesce(btrim(dj->>'name'),'')='' then return ebda.err('اكتب اسم العنصر'); end if;
    if coalesce(dj->>'kind','') not in ('earning','deduction') then return ebda.err('نوع العنصر: إضافة أو خصم'); end if;
    if coalesce(dj->>'id','')='' then
      if coalesce(dj->>'code','') !~ '^[a-z][a-z0-9_]{1,30}$' then return ebda.err('الرمز بالإنجليزية الصغيرة (مثال: transport)'); end if;
      if exists(select 1 from ebda.payroll_components c where c.code=dj->>'code') then return ebda.err('الرمز موجود بالفعل'); end if;
      insert into ebda.payroll_components(id,code,name,kind,active,sort,system)
      values(ebda.uid(), dj->>'code', btrim(dj->>'name'), dj->>'kind', coalesce(nullif(dj->>'active',''),'نعم'), coalesce(nullif(dj->>'sort','')::int,99), 'لا');
    else
      update ebda.payroll_components set name=btrim(dj->>'name'), kind=dj->>'kind', active=coalesce(nullif(dj->>'active',''),active),
        sort=coalesce(nullif(dj->>'sort','')::int,sort) where id=dj->>'id';
    end if;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'savePayrollMap' then
    if not ebda.can(u,'payroll.import') then return ebda.err('لا صلاحية'); end if;
    update ebda.config set value=coalesce(req->>'map','') where key='payroll_map';
    return jsonb_build_object('ok',true);
  end if;
  -- ================================================================ v6: دورة المصروف
  if action = 'submitExpense' then   -- مسودة / معاد للتعديل ← بانتظار المدير المباشر · معاد من المدير المالى ← المراجعة المالية
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    select * into cust from ebda.custodies where id=ex.custody_id;
    if not (urole='admin' or ebda.owns_custody(u, cust)) then return ebda.err('الإرسال لصاحب المصروف فقط'); end if;
    if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى'); end if;
    if ex.approval in ('draft','returned') then
      update ebda.expenses set approval='pending', submitted_at=now()::text, updated_by=u.name, updated_at=now()::text where id=ex.id;
      return jsonb_build_object('ok',true,'stage','pending_manager');
    elsif ex.approval='approved' and ex.fin_approval='returned' then
      update ebda.expenses set fin_approval='', submitted_at=now()::text, updated_by=u.name, updated_at=now()::text where id=ex.id;
      return jsonb_build_object('ok',true,'stage','pending_finance');
    end if;
    return ebda.err('المصروف ليس مسودة ولا معاداً للتعديل');
  end if;

  if action = 'cancelExpense' then   -- للأدمن فقط، فى أى مرحلة: لا حذف — الحالة «ملغى» مع السبب (يخرج من الموازنة ورصيد العهدة)
    if not ebda.can(u,'records.cancel') then return ebda.err('إلغاء المصروف للأدمن فقط'); end if;
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى بالفعل'); end if;
    if length(coalesce(btrim(req->>'reason'),''))<3 then return ebda.err('اكتب سبب الإلغاء'); end if;
    update ebda.expenses set cancelled_at=now()::text, cancelled_by=u.name, cancel_reason=btrim(req->>'reason'),
      updated_by=u.name, updated_at=now()::text where id=ex.id;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'unapproveExpense' then   -- إلغاء الاعتماد (للأدمن): يعود المصروف لاعتماد المدير المباشر
    if urole<>'admin' then return ebda.err('إلغاء الاعتماد للأدمن فقط'); end if;
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if coalesce(ex.cancelled_at,'')<>'' then return ebda.err('المصروف ملغى'); end if;
    if length(coalesce(btrim(req->>'reason'),''))<3 then return ebda.err('اكتب سبب إلغاء الاعتماد'); end if;
    update ebda.expenses set approval='pending', approved_by='', approved_by_id='', approved_at='', approval_note='',
      fin_approval='', fin_by='', fin_by_id='', fin_at='', settled='', settled_at='', settled_by='', settled_by_id='',
      return_reason='إلغاء اعتماد بواسطة الأدمن: '||btrim(req->>'reason'), updated_by=u.name, updated_at=now()::text
    where id=ex.id;
    return jsonb_build_object('ok',true);
  end if;

  if action = 'getDoc' then   -- فتح مستند مرفوع داخل النظام (لا يُرسَل محتوى الملفات مع تحميل الصفحة)
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if not ebda.can_expense(u, ex) then return ebda.err('لا صلاحية على هذا المستند'); end if;
    return jsonb_build_object('ok',true,'url',coalesce(ex.doc_url,''),'name',coalesce(ex.doc_name,''));
  end if;

  if action = 'expenseHistory' then   -- كل خطوات المصروف من «تتبع التعديلات»
    select * into ex from ebda.expenses where id=(req->>'id');
    if not found then return ebda.err('المصروف غير موجود'); end if;
    if not ebda.can_expense(u, ex) then return ebda.err('لا صلاحية على هذا المصروف'); end if;
    return jsonb_build_object('ok',true,'items', coalesce((
      select jsonb_agg(jsonb_build_object('ts', l.ts, 'actor', l.actor, 'role', l.actor_role, 'action', l.action,
                                          'old', c.old_v - 'doc_url', 'new', c.new_v - 'doc_url') order by l.ts)
      from ebda.audit_changes c join ebda.audit_log l on l.txid = c.txid
      where c.tbl='expenses' and c.row_id=ex.id),'[]'::jsonb));
  end if;

  -- ================================================================ v6: Master Data (أنواع العهد · أنواع الموازنات/الجهات)
  if action = 'saveCustodyKind' then
    if urole<>'admin' then return ebda.err('إدارة أنواع العهد للأدمن فقط'); end if;
    dj := req->'item';
    if coalesce(btrim(dj->>'name'),'')='' then return ebda.err('اكتب اسم النوع'); end if;
    if exists(select 1 from ebda.custody_kinds z where ebda.norm_txt(z.name)=ebda.norm_txt(dj->>'name') and z.id<>coalesce(dj->>'id','')) then
      return ebda.err('هذا النوع موجود بالفعل'); end if;
    if coalesce(dj->>'id','')='' then
      newid := ebda.uid();
      insert into ebda.custody_kinds(id,name,active,sort) values(newid, btrim(dj->>'name'), coalesce(nullif(dj->>'active',''),'نعم'), coalesce(nullif(dj->>'sort','')::int,99));
    else
      newid := dj->>'id';
      -- تغيير الاسم ينعكس على العهد القديمة (التصنيف مخزّن كنص)
      update ebda.custodies c set kind=btrim(dj->>'name') from ebda.custody_kinds z where z.id=newid and c.kind=z.name and z.name<>btrim(dj->>'name');
      update ebda.custody_kinds set name=btrim(dj->>'name'), active=coalesce(nullif(dj->>'active',''),active), sort=coalesce(nullif(dj->>'sort','')::int,sort) where id=newid;
      if not found then return ebda.err('النوع غير موجود'); end if;
    end if;
    return jsonb_build_object('ok',true,'id',newid);
  end if;

  if action = 'saveEntityType' then
    if urole<>'admin' then return ebda.err('إدارة أنواع الموازنات للأدمن فقط'); end if;
    dj := req->'item';
    if coalesce(btrim(dj->>'label'),'')='' then return ebda.err('اكتب اسم النوع'); end if;
    if coalesce(dj->>'code','')='' then
      newid := 'et_'||substr(md5(dj->>'label'||clock_timestamp()::text),1,8);
      insert into ebda.entity_types(code,label,active,sort) values(newid, btrim(dj->>'label'), coalesce(nullif(dj->>'active',''),'نعم'), coalesce(nullif(dj->>'sort','')::int,99));
    else
      newid := dj->>'code';
      update ebda.entity_types set label=btrim(dj->>'label'), active=coalesce(nullif(dj->>'active',''),active), sort=coalesce(nullif(dj->>'sort','')::int,sort) where code=newid;
      if not found then return ebda.err('النوع غير موجود'); end if;
    end if;
    return jsonb_build_object('ok',true,'code',newid);
  end if;

  if action = 'setLineActive' then   -- تعطيل/تفعيل بند (للأدمن): المعطّل لا يقبل إدخالات جديدة ويبقى بتاريخه فى التقارير
    if urole<>'admin' then return ebda.err('تعطيل البنود للأدمن فقط'); end if;
    if not exists(select 1 from ebda.lines where id=(req->>'id')) then return ebda.err('البند غير موجود'); end if;
    update ebda.lines set active=case when coalesce(req->>'active','') like '%نعم%' then 'نعم' else 'لا' end where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;

  if action = 'setSetting' then   -- إعدادات يغيّرها الأدمن من الواجهة (قائمة محددة فقط)
    if urole<>'admin' then return ebda.err('الإعدادات للأدمن فقط'); end if;
    if coalesce(req->>'key','') not in ('require_doc_to_settle','custody_overdue_days','finance_email','mail_cc_default') then return ebda.err('إعداد غير معروف'); end if;
    if req->>'key'='finance_email' and coalesce(req->>'value','')<>'' and lower(btrim(req->>'value')) !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then
      return ebda.err('البريد الإلكترونى غير صحيح'); end if;
    if req->>'key'='require_doc_to_settle' and coalesce(req->>'value','') not in ('yes','no') then return ebda.err('قيمة غير صحيحة'); end if;
    if req->>'key'='custody_overdue_days' and coalesce(req->>'value','') !~ '^[0-9]{1,4}$' then return ebda.err('عدد أيام غير صحيح'); end if;
    insert into ebda.config(key,value) values(req->>'key', req->>'value') on conflict (key) do update set value=excluded.value;
    return jsonb_build_object('ok',true);
  end if;

  -- ================================================================ v6: النسخ الاحتياطى والاستعادة (للأدمن فقط)
  if action in ('createBackup','downloadBackup','restoreBackup','backupInfo') then
    if urole<>'admin' then return ebda.err('النسخ الاحتياطى للأدمن فقط'); end if;
    if action = 'createBackup' then
      return jsonb_build_object('ok',true,'backup', ebda.make_backup('manual', u.name, coalesce(req->>'note','')));
    end if;
    if action = 'backupInfo' then
      return jsonb_build_object('ok',true,'item',(select jsonb_build_object('id',b.id,'name',b.name,'kind',b.kind,'created_at',b.created_at,'created_by',b.created_by,
             'size_bytes',b.size_bytes,'counts',b.counts,'note',b.note,'schema_version',b.data#>>'{_meta,schema_version}') from ebda.backups b where b.id=(req->>'id')));
    end if;
    if action = 'downloadBackup' then
      return jsonb_build_object('ok',true,'name',(select name from ebda.backups where id=(req->>'id')),
                                'data',(select data from ebda.backups where id=(req->>'id')));
    end if;
    -- restoreBackup: يتطلب كتابة اسم النسخة للتأكيد
    if coalesce(req->>'confirm','') <> coalesce((select name from ebda.backups where id=(req->>'id')),'~') then
      return ebda.err('للتأكيد اكتب اسم النسخة كما هو'); end if;
    nk := (select value from ebda.config where key='schema_version');
    res := ebda.restore_backup(req->>'id', u.name);
    if res ? 'error' then return res; end if;
    update ebda.config set value=nk where key='schema_version';   -- إصدار قاعدة البيانات الحالى لا يتغير بالاستعادة
    return res;
  end if;

  -- ================================================================ v6: استيراد العاملين الآمن (معاينة ← تحقق ← تأكيد) — بدون تكرار وبدون حذف
  -- الموظف له معرّف ثابت: يُطابَق بالرقم القومى (فى كل الأماكن) ثم بالرقم الوظيفى ثم بالاسم داخل المكان.
  -- ---------------------------------------------------------------- استيراد ملف المصروفات والعهد (معاينة ← استيراد)
  -- ---------------------------------------------------------------- v7: استيراد ورقة «العهد» من Excel (معاينة ← استيراد)
  if action = 'importCustodiesFile' then
    return ebda.import_custodies(u, req);
  end if;

  if action = 'importExpensesFile' then
    return ebda.import_expenses(u, req);
  end if;
  if action = 'importBatches' then
    if not (urole = 'admin' or ebda.can(u,'expense.import')) then return ebda.err('صلاحية استيراد المصروفات مطلوبة'); end if;
    return jsonb_build_object('ok', true, 'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'file_name', b.file_name, 'actor', b.actor,
        'created_at', b.created_at, 'approve_mode', b.approve_mode, 'rows_n', b.rows_n, 'imported_n', b.imported_n, 'amount', b.amount,
        'summary', b.summary, 'exceptions_n', jsonb_array_length(b.exceptions), 'reverted_at', b.reverted_at, 'reverted_by', b.reverted_by,
        'exceptions', case when b.id = req->>'id' then b.exceptions else null end) order by b.created_at desc)
      from (select * from ebda.import_batches z where urole = 'admin' or z.actor_id = u.id order by z.created_at desc limit 100) b), '[]'::jsonb));
  end if;
  if action = 'revertImport' then
    if urole <> 'admin' then return ebda.err('التراجع عن الاستيراد للأدمن فقط'); end if;
    return ebda.revert_import(u, req->>'id', req->>'reason');
  end if;

  if action = 'importEmployeesSafe' then
    if not (ebda.can(u,'payroll.import') or urole='admin') then return ebda.err('صلاحية استيراد العاملين مطلوبة'); end if;
    sid := req->>'school_id';
    if sid is null or not exists(select 1 from ebda.schools s where s.id=sid) then return ebda.err('اختر المكان'); end if;
    if not ebda.can_school(u, sid) then return ebda.err('هذا المكان ليس ضمن نطاقك'); end if;
    if jsonb_typeof(coalesce(req->'rows','null'::jsonb))<>'array' then return ebda.err('لا توجد بيانات'); end if;
    catv := case when req->>'category'='gov' then 'gov' else 'contract' end;
    declare
      fields text[] := array['serial_no','emp_no','name','job','job_type','qualification','grad_year','national_id','birth_date','birth_place','phone',
                             'hire_date','work_start','gender','secondment_status','address','retire_date','email','bank','account_no','branch',
                             'insurance_no','base_salary','contract_type','dept','note',
                             'net_before','increase_pct','increase_value','adjustment','si_employee','si_company','medical_ins','income_tax','other_ded',
                             'gross_file','salary_notes'];
      numf text[] := array['base_salary','net_before','increase_pct','increase_value','adjustment','si_employee','si_company','medical_ins','income_tax',
                           'other_ded','gross_file'];
      salary_kind boolean := coalesce(req->>'kind','') = 'salaries';
      rcat text;
      f text; nm text; ek ebda.employees; eid text; st text; reasons jsonb; changes jsonb; out jsonb := '[]'::jsonb;
      seen_nk text[] := '{}'; seen_nm text[] := '{}'; i int := 0;
      c_new int := 0; c_upd int := 0; c_same int := 0; c_dup int := 0; c_err int := 0; c_warn int := 0;
      commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
      rw jsonb;
    begin
      for rw in select * from jsonb_array_elements(req->'rows') loop
        i := i + 1; reasons := '[]'::jsonb; changes := '[]'::jsonb; eid := null; ek := null;
        nm := btrim(coalesce(rw->>'name',''));
        nk := regexp_replace(translate(coalesce(rw->>'national_id',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g');
        if nm = '' then
          st := 'error'; reasons := reasons || to_jsonb('اسم الموظف مطلوب'::text);
        elsif coalesce(rw->>'base_salary','') <> '' and not ebda.num_ok(rw->>'base_salary') then
          st := 'error'; reasons := reasons || to_jsonb('الراتب/الحافز ليس رقماً'::text);
        elsif exists(select 1 from unnest(numf) x where coalesce(btrim(rw->>x),'') <> '' and not ebda.num_ok(rw->>x)) then
          st := 'error'; reasons := reasons || to_jsonb(('قيمة غير رقمية فى: ' || (select string_agg(x, '، ') from unnest(numf) x
                                                          where coalesce(btrim(rw->>x),'') <> '' and not ebda.num_ok(rw->>x)))::text);
        elsif (nk <> '' and nk = any(seen_nk)) or (nk = '' and ebda.norm_txt(nm) = any(seen_nm)) then
          st := 'duplicate'; reasons := reasons || to_jsonb(case when nk<>'' then 'الرقم القومى مكرر داخل الملف' else 'الاسم مكرر داخل الملف' end);
        else
          if nk <> '' and length(nk) <> 14 then reasons := reasons || to_jsonb('الرقم القومى ليس 14 رقماً'::text); end if;
          -- كشف الرواتب لا يحتوى رقماً قومياً ولا هاتفاً: لا تحذير، والمطابقة بالكود ثم الاسم داخل نفس المكان
          if nk = '' and not salary_kind then reasons := reasons || to_jsonb('الرقم القومى غير موجود'::text); end if;
          if coalesce(rw->>'phone','') = '' and not salary_kind then reasons := reasons || to_jsonb('رقم الهاتف غير موجود'::text); end if;
          if nk <> '' then select * into ek from ebda.employees e where e.national_key = nk order by e.id limit 1; end if;
          if ek.id is null and coalesce(rw->>'emp_no','')<>'' then
            select * into ek from ebda.employees e where e.school_id=sid and e.emp_no = rw->>'emp_no' order by e.id limit 1; end if;
          if ek.id is null then
            select * into ek from ebda.employees e where e.school_id=sid and ebda.norm_txt(e.name)=ebda.norm_txt(nm) order by e.id limit 1; end if;
          if ek.id is null then
            st := 'new';
          else
            eid := ek.id;
            foreach f in array fields loop
              if coalesce(btrim(rw->>f),'') <> '' and coalesce(to_jsonb(ek)->>f,'') is distinct from btrim(rw->>f)
                 and not (f = any(numf) and ebda.num_ok(rw->>f) and coalesce(nullif(to_jsonb(ek)->>f,'')::numeric,0) = nullif(btrim(rw->>f),'')::numeric) then
                changes := changes || to_jsonb(f);
              end if;
            end loop;
            if ek.school_id is distinct from sid then
              changes := changes || to_jsonb('school_id'::text);
              reasons := reasons || to_jsonb(('مسجل فى مكان آخر: ' || coalesce((select s.name from ebda.schools s where s.id=ek.school_id),'—') || ' — سيُنقل لهذا المكان')::text);
            end if;
            st := case when jsonb_array_length(changes) > 0 then 'updated' else 'same' end;
          end if;
          if nk <> '' then seen_nk := seen_nk || nk; else seen_nm := seen_nm || ebda.norm_txt(nm); end if;
        end if;
        if st = 'new' then c_new := c_new + 1; elsif st = 'updated' then c_upd := c_upd + 1; elsif st = 'same' then c_same := c_same + 1;
        elsif st = 'duplicate' then c_dup := c_dup + 1; else c_err := c_err + 1; end if;
        if st in ('new','updated','same') and jsonb_array_length(reasons) > 0 then c_warn := c_warn + 1; end if;
        rcat := case rw->>'category' when 'gov' then 'gov' when 'contract' then 'contract' else catv end;
        if commit_ and st = 'new' then
          eid := ebda.uid();
          insert into ebda.employees(id,school_id,category,emp_no,serial_no,name,job,job_type,qualification,grad_year,national_id,national_key,birth_date,birth_place,phone,
              hire_date,work_start,gender,secondment_status,address,retire_date,email,bank,account_no,branch,insurance_no,base_salary,contract_type,dept,note,
              staff_group,active,archived)
          values(eid, sid, rcat, coalesce(rw->>'emp_no',''), coalesce(rw->>'serial_no',''), nm, coalesce(rw->>'job',''), coalesce(rw->>'job_type',''),
              coalesce(rw->>'qualification',''), coalesce(rw->>'grad_year',''), coalesce(rw->>'national_id',''), nk, coalesce(rw->>'birth_date',''),
              coalesce(rw->>'birth_place',''), coalesce(rw->>'phone',''), coalesce(rw->>'hire_date',''), coalesce(rw->>'work_start',''), coalesce(rw->>'gender',''),
              coalesce(rw->>'secondment_status',''), coalesce(rw->>'address',''), coalesce(rw->>'retire_date',''), coalesce(rw->>'email',''), coalesce(rw->>'bank',''),
              coalesce(rw->>'account_no',''), coalesce(rw->>'branch',''), coalesce(rw->>'insurance_no',''), coalesce(nullif(btrim(rw->>'base_salary'),'')::numeric,0),
              coalesce(nullif(rw->>'contract_type',''), case when rcat='gov' then 'منتدب' else '' end), coalesce(rw->>'dept',''), coalesce(rw->>'note',''),
              case when rcat='gov' then 'gov' else '' end, 'نعم', 'لا');
        elsif commit_ and st = 'updated' then
          -- تحديث الحقول القادمة فى الملف فقط — لا يُمسح أى حقل موجود بقيمة فارغة
          update ebda.employees set school_id=sid,
            emp_no=coalesce(nullif(btrim(rw->>'emp_no'),''),emp_no), serial_no=coalesce(nullif(btrim(rw->>'serial_no'),''),serial_no),
            name=nm, job=coalesce(nullif(btrim(rw->>'job'),''),job), job_type=coalesce(nullif(btrim(rw->>'job_type'),''),job_type),
            qualification=coalesce(nullif(btrim(rw->>'qualification'),''),qualification), grad_year=coalesce(nullif(btrim(rw->>'grad_year'),''),grad_year),
            national_id=coalesce(nullif(btrim(rw->>'national_id'),''),national_id), national_key=coalesce(nullif(nk,''),national_key),
            birth_date=coalesce(nullif(btrim(rw->>'birth_date'),''),birth_date), birth_place=coalesce(nullif(btrim(rw->>'birth_place'),''),birth_place),
            phone=coalesce(nullif(btrim(rw->>'phone'),''),phone), hire_date=coalesce(nullif(btrim(rw->>'hire_date'),''),hire_date),
            work_start=coalesce(nullif(btrim(rw->>'work_start'),''),work_start), gender=coalesce(nullif(btrim(rw->>'gender'),''),gender),
            secondment_status=coalesce(nullif(btrim(rw->>'secondment_status'),''),secondment_status), address=coalesce(nullif(btrim(rw->>'address'),''),address),
            retire_date=coalesce(nullif(btrim(rw->>'retire_date'),''),retire_date), email=coalesce(nullif(btrim(rw->>'email'),''),email),
            bank=coalesce(nullif(btrim(rw->>'bank'),''),bank), account_no=coalesce(nullif(btrim(rw->>'account_no'),''),account_no),
            branch=coalesce(nullif(btrim(rw->>'branch'),''),branch), insurance_no=coalesce(nullif(btrim(rw->>'insurance_no'),''),insurance_no),
            base_salary=coalesce(nullif(btrim(rw->>'base_salary'),'')::numeric,base_salary), contract_type=coalesce(nullif(btrim(rw->>'contract_type'),''),contract_type),
            dept=coalesce(nullif(btrim(rw->>'dept'),''),dept), note=coalesce(nullif(btrim(rw->>'note'),''),note),
            category=case when rw->>'category' in ('gov','contract') then rw->>'category' else category end
          where id=eid;
        end if;
        -- هيكل الراتب (الحقول القادمة فى الملف فقط؛ المحسوب يُحسب تلقائياً بالـ trigger)
        if commit_ and st in ('new','updated') then
          update ebda.employees set
            net_before=coalesce(nullif(btrim(rw->>'net_before'),'')::numeric,net_before), increase_pct=coalesce(nullif(btrim(rw->>'increase_pct'),'')::numeric,increase_pct),
            increase_value=coalesce(nullif(btrim(rw->>'increase_value'),'')::numeric,increase_value), adjustment=coalesce(nullif(btrim(rw->>'adjustment'),'')::numeric,adjustment),
            si_employee=coalesce(nullif(btrim(rw->>'si_employee'),'')::numeric,si_employee), si_company=coalesce(nullif(btrim(rw->>'si_company'),'')::numeric,si_company),
            medical_ins=coalesce(nullif(btrim(rw->>'medical_ins'),'')::numeric,medical_ins), income_tax=coalesce(nullif(btrim(rw->>'income_tax'),'')::numeric,income_tax),
            other_ded=coalesce(nullif(btrim(rw->>'other_ded'),'')::numeric,other_ded), gross_file=coalesce(nullif(btrim(rw->>'gross_file'),'')::numeric,gross_file),
            salary_notes=coalesce(nullif(btrim(rw->>'salary_notes'),''),salary_notes)
          where id=eid;
        end if;
        out := out || jsonb_build_object('i', i, 'name', nm, 'national_id', coalesce(rw->>'national_id',''), 'status', st, 'reasons', reasons,
                                         'changes', changes, 'employee_id', coalesce(eid,''));
      end loop;
      return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end,
        'counts', jsonb_build_object('new', c_new, 'updated', c_upd, 'same', c_same, 'duplicate', c_dup, 'error', c_err, 'warnings', c_warn),
        'rows', out);
    end;
  end if;

  if action = 'payrollMonth' then   -- قسائم شهر أقدم من نافذة التحميل (تُطلب عند اختياره فقط)
    if not (ebda.sees_budgets(u) or ebda.can(u,'payroll.view')) then return ebda.err('لا صلاحية لعرض الرواتب'); end if;
    if coalesce(req->>'month','') !~ '^[0-9]{4}-[0-9]{2}$' then return ebda.err('الشهر غير صحيح'); end if;
    return jsonb_build_object('ok',true,'payslips', coalesce((select jsonb_agg(to_jsonb(z)) from ebda.payslips z
      where z.month = req->>'month' and ebda.can_school(u, z.school_id)),'[]'::jsonb));
  end if;

  -- ================================================================ v6: البحث فى المصروفات والتقارير الديناميكية — على الخادم
  -- (فلترة + تجميع + ترقيم صفحات داخل قاعدة البيانات، وتُرسل النتائج المطلوبة فقط، وكل ذلك داخل نطاق المستخدم)
  if action in ('searchExpenses','report') then
    declare
      f jsonb := coalesce(req->'filters','{}'::jsonb);
      rkind text := coalesce(req->>'kind', 'expenses');
      star boolean := coalesce(u.schools,'')='*' or urole='admin';
      sch text[] := ebda.scope_arr(u);
      lo text := coalesce(nullif(req#>>'{filters,from}',''), '0000');
      hi text := coalesce(nullif(req#>>'{filters,to}',''), '9999');
      ps int := least(greatest(coalesce(nullif(req->>'page_size','')::int, 50), 1), case when action='report' then 5000 else 500 end);
      pg int := greatest(coalesce(nullif(req->>'page','')::int, 1) - 1, 0);
      odays int := ebda.cfg_int('custody_overdue_days', 30);
      can_appr boolean := ebda.can(u,'expense.approve');
      can_fin boolean := ebda.can(u,'expense.fin_approve');
      stages text[] := case when jsonb_typeof(req#>'{filters,stages}')='array' then array(select jsonb_array_elements_text(req#>'{filters,stages}')) else '{}'::text[] end;
    begin
    if action = 'searchExpenses' or rkind = 'expenses' then
      return (with v as materialized (
        select e.id, e.date, e.txn_no, e.amount, e.custody_id, e.school_id, e.line_id, e.created_by_id, ebda.expense_stage(e) stage
        from (select * from ebda.expenses where urole = 'admin' union all select * from ebda.vis_expenses(u) where urole <> 'admin') e
        where true
          and (coalesce(f->>'school_id','') = '' or e.school_id = f->>'school_id')
          and (coalesce(f->>'custody_id','') = '' or e.custody_id = f->>'custody_id')
          and (coalesce(f->>'line_id','') = '' or e.line_id = f->>'line_id')
          and (coalesce(f->>'catalog_id','') = '' or exists(select 1 from ebda.lines lc where lc.id = e.line_id
               and (lc.catalog_id = f->>'catalog_id' or ebda.catalog_main(lc.catalog_id) = f->>'catalog_id' or e.catalog_sub_id = f->>'catalog_id')))
          and (coalesce(f->>'spend_item','') = '' or e.spend_item = f->>'spend_item')
          and (coalesce(f->>'from','') = '' or e.date >= f->>'from')
          and (coalesce(f->>'to','') = '' or e.date <= f->>'to')
          and (coalesce(f->>'q','') = '' or e.txn_no ilike '%'||(f->>'q')||'%' or e.description ilike '%'||(f->>'q')||'%'
               or coalesce(e.supplier,'') ilike '%'||(f->>'q')||'%' or coalesce(e.doc_no,'') ilike '%'||(f->>'q')||'%')
          and (coalesce(f->>'import_batch','') = '' or e.import_batch = f->>'import_batch')
          and (cardinality(stages) = 0 or ebda.expense_stage(e) = any(stages))
          and (coalesce(f->>'no_doc','') <> '1' or coalesce(e.doc_url,'') = '')
          and (coalesce(f->>'incomplete','') <> '1' or coalesce(e.review_status,'') like '%ناقص%')
      ), base as (
        select v.*, o.manager_id as mgr_id from v
        left join ebda.custodies c on c.id = v.custody_id
        left join ebda.users o on o.id = c.user_id
        where (coalesce(f->>'holder_id','') = '' or c.user_id = f->>'holder_id')
          and (coalesce(f->>'holder','') = '' or ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) = f->>'holder')
          and (coalesce(f->>'custody_name','') = '' or ebda.custody_name(c.title, c.label, c.code) = f->>'custody_name')
          and (coalesce(f->>'manager_id','') = '' or o.manager_id = f->>'manager_id')
          and (coalesce(f->>'kind','') = '' or c.kind = f->>'kind')
          and (coalesce(f->>'title','') = '' or c.title = f->>'title')
          and (coalesce(f->>'mine','') <> '1' or c.user_id = u.id)
          and (coalesce(f->>'my_queue','') <> '1' or (
                 (v.stage = 'pending_manager' and can_appr and c.id is not null
                   and not ebda.owns_custody(u, c) and coalesce(v.created_by_id,'') <> u.id
                   and (urole = 'admin' or (coalesce(o.manager_id,'') <> '' and o.manager_id = u.id)
                        or (coalesce(o.manager_id,'') = '' and (star or c.school_id = any(sch)))))
              or (v.stage in ('pending_finance','reviewed') and can_fin
                   and not (c.id is not null and ebda.owns_custody(u, c)) and coalesce(v.created_by_id,'') <> u.id)
              or (v.stage in ('draft','returned','fin_returned') and c.id is not null and ebda.owns_custody(u, c))))
      ), page as (
        select base.id, base.stage, base.mgr_id from base
        order by case when coalesce(req->>'sort','') = 'amount' then null else base.date end desc nulls last,
                 case when coalesce(req->>'sort','') = 'amount' then base.amount end desc nulls last,
                 base.txn_no desc
        limit ps offset pg * ps
      )
      select jsonb_build_object('ok', true,
        'total', (select count(*) from base),
        'sum', (select coalesce(sum(amount),0) from base where stage not in ('cancelled','rejected','fin_rejected')),
        'by_stage', coalesce((select jsonb_object_agg(stage, jsonb_build_object('n', cnt, 'amount', amt)) from
                     (select stage, count(*) cnt, sum(amount) amt from base group by stage) z), '{}'::jsonb),
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
            'id', e.id, 'txn_no', e.txn_no, 'date', e.date, 'school_id', e.school_id, 'school', s.name, 'category', s.category,
            'custody_id', e.custody_id, 'custody_code', coalesce(c.code, 'شراء مركزى'), 'custody_title', coalesce(nullif(c.title,''), c.label, ''),
            'custody_kind', coalesce(c.kind,''), 'holder', coalesce(ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label), ''), 'holder_id', coalesce(c.user_id,''),
            'custody_name', case when c.id is null then '' else ebda.custody_name(c.title, c.label, c.code) end,
            'responsible', case when c.id is null then coalesce(e.created_by,'') else ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) end,
            'manager_id', coalesce(p.mgr_id,''), 'manager', coalesce(m.name,''),
            'line_id', e.line_id, 'line', coalesce(l.name,''), 'section', coalesce(l.section,''), 'spend_item', coalesce(e.spend_item,''),
            'description', e.description, 'amount', e.amount, 'pay_method', coalesce(e.pay_method,''), 'stage', p.stage,
            'approval', e.approval, 'approved_by', coalesce(e.approved_by,''), 'approved_at', coalesce(e.approved_at,''), 'approval_note', coalesce(e.approval_note,''),
            'fin_approval', coalesce(e.fin_approval,''), 'fin_by', coalesce(e.fin_by,''), 'fin_at', coalesce(e.fin_at,''), 'fin_note', coalesce(e.fin_note,''),
            'settled', coalesce(e.settled,''), 'settled_by', coalesce(e.settled_by,''), 'settled_at', coalesce(e.settled_at,''),
            'review_status', coalesce(e.review_status,''), 'review_note', coalesce(e.review_note,''),
            'return_reason', coalesce(e.return_reason,''), 'returned_by', coalesce(e.returned_by,''), 'returned_at', coalesce(e.returned_at,''),
            'cancel_reason', coalesce(e.cancel_reason,''), 'cancelled_by', coalesce(e.cancelled_by,''), 'cancelled_at', coalesce(e.cancelled_at,''),
            'created_by', coalesce(e.created_by,''), 'created_by_id', coalesce(e.created_by_id,''), 'created_at', coalesce(e.created_at,''),
            'submitted_at', coalesce(e.submitted_at,''), 'doc_name', coalesce(e.doc_name,''), 'doc_type', coalesce(e.doc_type,''),
            'doc_url', case when e.doc_url like 'data:%' then 'inline:' else coalesce(e.doc_url,'') end)
            || jsonb_build_object('supplier', coalesce(e.supplier,''), 'doc_no', coalesce(e.doc_no,''), 'import_batch', coalesce(e.import_batch,''),
            'catalog_id', coalesce(l.catalog_id,''), 'catalog_main', coalesce((select mc.name from ebda.line_catalog mc where mc.id = ebda.catalog_main(l.catalog_id)),''),
            'sub', coalesce((select sc.name from ebda.line_catalog sc where sc.id = nullif(e.catalog_sub_id,'')),''), 'return_needed', coalesce(e.return_needed,''))
            order by case when coalesce(req->>'sort','') = 'amount' then null else e.date end desc nulls last,
                     case when coalesce(req->>'sort','') = 'amount' then e.amount end desc nulls last, e.txn_no desc)
          from page p join ebda.expenses e on e.id = p.id
          left join ebda.custodies c on c.id = e.custody_id left join ebda.schools s on s.id = e.school_id
          left join ebda.lines l on l.id = e.line_id left join ebda.users m on m.id = p.mgr_id), '[]'::jsonb)));
    end if;

    if rkind = 'custodyHolder' then   -- تقرير حالة عهد مسئول/مسئولين (فلتر واحد أو أكثر)
      return (with vc as materialized (
        select c.* from ebda.vis_custodies(u) c
        where (coalesce(f->>'holder_id','')='' or c.user_id = f->>'holder_id')
          and (coalesce(f->>'holder','')='' or ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label) = f->>'holder')
          and (coalesce(f->>'custody_name','')='' or ebda.custody_name(c.title, c.label, c.code) = f->>'custody_name')
          and (coalesce(f->>'school_id','')='' or c.school_id = f->>'school_id')
          and (coalesce(f->>'title','')='' or c.title = f->>'title')
          and (coalesce(f->>'kind','')='' or c.kind = f->>'kind')
      ), tr as (
        select t.custody_id, sum(t.amount) s, bool_or(t.date between lo and hi) inr from ebda.tranches t where t.custody_id = any(array(select id from vc)) group by 1
      ), ea as (
        select e.custody_id,
          sum(e.amount) filter (where ebda.active_on_custody(e)) spent,
          sum(e.amount) filter (where ebda.active_on_custody(e) and (coalesce(f->>'line_id','')='' or e.line_id=f->>'line_id') and e.date between lo and hi) f_spent,
          count(*) filter (where coalesce(e.cancelled_at,'')='' and ebda.expense_stage(e) in ('pending_manager','pending_finance')) under_review,
          count(*) filter (where ebda.active_on_custody(e) and e.approval='approved' and coalesce(e.settled,'') not like '%نعم%') unsettled,
          count(*) filter (where coalesce(e.cancelled_at,'')='' and coalesce(e.settled,'') not like '%نعم%'
             and (e.approval in ('rejected','returned') or e.fin_approval in ('rejected','returned') or coalesce(e.review_status,'') like '%ناقص%' or coalesce(e.review_note,'')<>'')) notes,
          bool_or(e.date between lo and hi) inr, bool_or(e.line_id = f->>'line_id') has_line
        from ebda.expenses e where e.custody_id = any(array(select id from vc)) group by 1
      ), cs as (
        select vc.*, s.name as s_name, coalesce(tr.s,0) received, coalesce(ea.spent,0) spent, coalesce(ea.f_spent,0) f_spent,
               coalesce(ea.under_review,0) under_review, coalesce(ea.unsettled,0) unsettled, coalesce(ea.notes,0) notes,
               greatest(ebda.days_since(vc.opened_at), 0) as age
        from vc left join ebda.schools s on s.id = vc.school_id left join tr on tr.custody_id = vc.id left join ea on ea.custody_id = vc.id
        where (coalesce(f->>'line_id','')='' or coalesce(ea.has_line,false)
               or exists(select 1 from ebda.custody_lines cl where cl.custody_id = vc.id and cl.line_id = f->>'line_id'))
          and ((coalesce(f->>'from','')='' and coalesce(f->>'to','')='') or left(coalesce(vc.opened_at,''),10) between lo and hi
               or coalesce(ea.inr,false) or coalesce(tr.inr,false))
      ), st as (
        select cs.*, case
            when coalesce(nullif(cs.status,''),'open') = 'open' and coalesce(cs.approval,'approved') = 'approved' and cs.notes > 0 then 'notes'
            when coalesce(nullif(cs.status,''),'open') = 'open' and coalesce(cs.approval,'approved') = 'approved' and cs.age > odays then 'overdue'
            else coalesce(nullif(cs.status,''),'open') end as state
        from cs
      ), fl as (
        select * from st
        where (coalesce(f->>'state','')='' or st.state = f->>'state')
          and (coalesce(f->>'settle','')='' or (f->>'settle'='settled' and st.state in ('settled','closed'))
               or (f->>'settle'='unsettled' and st.state not in ('settled','closed','cancelled')))
      )
      select jsonb_build_object('ok', true, 'kind', 'custodyHolder',
        'summary', jsonb_build_object(
          'holders', coalesce((select jsonb_agg(distinct ebda.person_name(user_id, holder_emp_id, holder, label)) from fl where ebda.person_name(user_id, holder_emp_id, holder, label) <> ''), '[]'::jsonb),
          'count', (select count(*) from fl),
          'received', (select coalesce(sum(received),0) from fl where state <> 'cancelled'),
          'spent', (select coalesce(sum(spent),0) from fl where state <> 'cancelled'),
          'remaining', (select coalesce(sum(received - spent),0) from fl where state <> 'cancelled'),
          'filtered_spent', (select coalesce(sum(f_spent),0) from fl where state <> 'cancelled'),
          'open', (select count(*) from fl where state in ('open','notes','overdue','pending_settlement')),
          'settled', (select count(*) from fl where state in ('settled','closed')),
          'overdue', (select count(*) from fl where state = 'overdue'),
          'cancelled', (select count(*) from fl where state = 'cancelled'),
          'under_review', (select coalesce(sum(under_review),0) from fl where state <> 'cancelled'),
          'unsettled', (select coalesce(sum(unsettled),0) from fl where state <> 'cancelled'),
          'overdue_days', odays),
        'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'title', coalesce(title,''), 'kind', coalesce(kind,''),
            'school_id', school_id, 'school', s_name, 'holder', ebda.person_name(user_id, holder_emp_id, holder, label), 'holder_id', coalesce(user_id,''),
            'custody_name', ebda.custody_name(title, label, code),
            'opened_at', coalesce(opened_at,''), 'approval', coalesce(approval,'approved'), 'state', state, 'age', age,
            'received', received, 'spent', spent, 'remaining', received - spent, 'filtered_spent', f_spent,
            'under_review', under_review, 'unsettled', unsettled, 'notes', notes) order by code)
            from (select * from fl order by code limit 5000) z), '[]'::jsonb)));
    end if;

    if rkind = 'budget' then   -- تقرير الموازنة: المكان · السنة · النوع · البند · المخصص · المصروف · المتبقى · النسبة · الحالة (شهر أو سنة)
      return (with ents as materialized (
        select s.* from ebda.schools s where (star or s.id = any(sch))
          and (coalesce(f->>'school_id','')='' or s.id = f->>'school_id')
          and (coalesce(f->>'period','')='' or f->>'period'='all' or s.period = f->>'period')
          and (coalesce(f->>'category','')='' or f->>'category'='all' or coalesce(nullif(s.category,''),'school') = f->>'category')
      ), ls as (
        select l.*, e.name as e_name, e.period as e_period, coalesce(nullif(e.category,''),'school') as e_cat,
               ebda.fy_from(e.period) as f_from, ebda.fy_to(e.period) as f_to
        from ebda.lines l join ents e on e.id = l.school_id
        where coalesce(l.deleted_at,'')=''
          and (coalesce(f->>'line_id','')='' or l.id = f->>'line_id')
          and (coalesce(f->>'section','')='' or l.section = f->>'section')
      ), sp as (
        select z.line_id, sum(z.amount) filter (where coalesce(nullif(f->>'month',''),'0')::int = 0 or z.m = (f->>'month')::int) as amt
        from ebda.line_fy_spend(u) z group by 1
      ), r as (
        select ls.*, case when coalesce(nullif(f->>'month',''),'0')::int = 0 then coalesce(ls.allocated,0)
                          else ebda.plan_month(ls.monthly_plan, ls.allocated, (f->>'month')::int) end as alloc,
               coalesce(sp.amt,0) as spent
        from ls left join sp on sp.line_id = ls.id
      ), fs as (
        select r.*, ebda.budget_state(r.alloc, r.spent) as state from r
      ), gs as (
        select * from fs where coalesce(f->>'state','')='' or fs.state = f->>'state'
      )
      select jsonb_build_object('ok', true, 'kind', 'budget',
        'summary', jsonb_build_object('lines', (select count(*) from gs), 'alloc', (select coalesce(sum(alloc),0) from gs),
          'spent', (select coalesce(sum(spent),0) from gs), 'remaining', (select coalesce(sum(alloc - spent),0) from gs),
          'over', (select count(*) from gs where state='over'), 'reached', (select count(*) from gs where state='reached'),
          'near', (select count(*) from gs where state='near'), 'within', (select count(*) from gs where state='within')),
        'rows', coalesce((select jsonb_agg(jsonb_build_object('line_id', id, 'school_id', school_id, 'school', e_name, 'period', coalesce(e_period,''),
            'category', e_cat, 'section', coalesce(section,''), 'line', name, 'active', coalesce(active,'نعم'),
            'alloc', alloc, 'spent', spent, 'remaining', alloc - spent,
            'pct', case when alloc > 0.5 then spent / alloc when spent > 0.5 then 1 else 0 end, 'state', state)
            order by e_name, section, name) from gs), '[]'::jsonb)));
    end if;

    if rkind = 'financial' then   -- التقرير المالى الشامل: الموازنات + العهد + المصروفات + التسويات
      return (with ents as materialized (
        select s.* from ebda.schools s where (star or s.id = any(sch))
          and (coalesce(f->>'school_id','')='' or s.id = f->>'school_id')
          and (coalesce(f->>'period','')='' or f->>'period'='all' or s.period = f->>'period')
      ), ls as (
        select l.id, l.name, coalesce(l.allocated,0) alloc, ebda.fy_from(e.period) f_from, ebda.fy_to(e.period) f_to, e.name e_name
        from ebda.lines l join ents e on e.id=l.school_id where coalesce(l.deleted_at,'')=''
      ), lspent as (
        select z.line_id, sum(z.amount) s from ebda.line_fy_spend(u) z group by 1
      ), lsp as (
        select ls.id, ls.name, ls.e_name, ls.alloc, coalesce(lspent.s,0) spent from ls left join lspent on lspent.line_id = ls.id
      ), exx as materialized (
        select e.amount, ebda.expense_stage(e) stage
        from (select * from ebda.expenses where urole = 'admin' union all select * from ebda.vis_expenses(u) where urole <> 'admin') e
        where e.school_id in (select id from ents)
          and (coalesce(f->>'from','')='' or e.date >= f->>'from') and (coalesce(f->>'to','')='' or e.date <= f->>'to')
      ), vc as materialized (
        select c.* from ebda.vis_custodies(u) c where c.school_id in (select id from ents) and coalesce(c.status,'') <> 'cancelled'
      ), tr as (select t.custody_id, sum(t.amount) s from ebda.tranches t where t.custody_id = any(array(select id from vc)) group by 1
      ), ea as (
        select e.custody_id, sum(e.amount) filter (where ebda.active_on_custody(e)) spent,
          count(*) filter (where coalesce(e.cancelled_at,'')='' and coalesce(e.settled,'') not like '%نعم%'
             and (e.approval in ('rejected','returned') or e.fin_approval in ('rejected','returned') or coalesce(e.review_status,'') like '%ناقص%' or coalesce(e.review_note,'')<>'')) notes
        from ebda.expenses e where e.custody_id = any(array(select id from vc)) group by 1
      ), cu as (
        select vc.*, coalesce(tr.s,0) received, coalesce(ea.spent,0) spent, coalesce(ea.notes,0) notes
        from vc left join tr on tr.custody_id = vc.id left join ea on ea.custody_id = vc.id
      ), od as (
        select cu.* from cu where coalesce(nullif(cu.status,''),'open')='open' and coalesce(cu.approval,'approved')='approved'
          and greatest(ebda.days_since(cu.opened_at),0) > odays and cu.notes = 0
      )
      select jsonb_build_object('ok', true, 'kind', 'financial', 'summary', jsonb_build_object(
          'budget_total', (select coalesce(sum(alloc),0) from lsp),
          'budget_spent', (select coalesce(sum(spent),0) from lsp),
          'budget_remaining', (select coalesce(sum(alloc - spent),0) from lsp),
          'custody_total', (select coalesce(sum(received),0) from cu),
          'custody_spent', (select coalesce(sum(spent),0) from cu),
          'custody_remaining', (select coalesce(sum(received - spent),0) from cu),
          'expenses_total', (select coalesce(sum(amount),0) from exx where stage not in ('cancelled','rejected','fin_rejected')),
          'expenses_count', (select count(*) from exx where stage not in ('cancelled','rejected','fin_rejected')),
          'pending_manager', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage='pending_manager'),
          'pending_finance', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage='pending_finance'),
          'returned', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage in ('returned','fin_returned','draft')),
          'settled', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage='settled'),
          'unsettled', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage in ('pending_finance','reviewed')),
          'cancelled', (select jsonb_build_object('n', count(*), 'amount', coalesce(sum(amount),0)) from exx where stage='cancelled'),
          'over_lines', (select count(*) from lsp where ebda.budget_state(alloc, spent)='over'),
          'overdue_custodies', (select count(*) from od)),
        'over_lines', coalesce((select jsonb_agg(jsonb_build_object('line_id', id, 'line', name, 'school', e_name, 'alloc', alloc, 'spent', spent, 'over', spent - alloc)
                         order by spent - alloc desc) from (select * from lsp where ebda.budget_state(alloc, spent)='over' order by spent - alloc desc limit 500) z), '[]'::jsonb),
        'overdue_custodies', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'holder', ebda.person_name(user_id, holder_emp_id, holder, label), 'custody_name', ebda.custody_name(title, label, code),
                         'age', greatest(ebda.days_since(opened_at),0), 'remaining', received - spent) order by opened_at) from (select * from od order by opened_at limit 500) z), '[]'::jsonb)));
    end if;

    if rkind = 'lineMonths' then   -- المصروف المحتسب لكل بند لكل شهر من السنة المالية (للوحة المتابعة — يُحسب على الخادم)
      return jsonb_build_object('ok', true, 'line_months', ebda.line_months(u));
    end if;
    return ebda.err('نوع تقرير غير معروف');
    end;
  end if;

  -- ================================================================ باقى الإجراءات للأدمن فقط (كما فى النظام الحالى)
  if urole<>'admin' then return ebda.err('صلاحية الأدمن مطلوبة'); end if;

  if action = 'addSalary' then
    newid := ebda.uid();
    insert into ebda.salaries(id,school_id,name,job,monthly,months,note)
    values(newid, req#>>'{salary,school_id}', req#>>'{salary,name}', coalesce(req#>>'{salary,job}',''),
      coalesce((req#>>'{salary,monthly}')::numeric,0), coalesce((req#>>'{salary,months}')::numeric,12), coalesce(req#>>'{salary,note}',''));
    return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.salaries z where z.id=newid));
  end if;
  if action = 'updateSalary' then
    patch := req->'patch';
    update ebda.salaries set name=coalesce(patch->>'name',name), job=coalesce(patch->>'job',job),
      monthly=coalesce((patch->>'monthly')::numeric,monthly), months=coalesce((patch->>'months')::numeric,months), note=coalesce(patch->>'note',note)
    where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'deleteSalary' then delete from ebda.salaries where id=(req->>'id'); return jsonb_build_object('ok',true); end if;

  if action = 'importSalaries' then
    sid := req->>'school_id';
    if (req->>'replace') is distinct from 'no' then delete from ebda.salaries where school_id = sid; end if;
    for ln in select * from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) loop
      insert into ebda.salaries(id,school_id,name,job,monthly,months,note)
      values(ebda.uid(), sid, coalesce(ln->>'name',''), coalesce(ln->>'job',''),
        coalesce((ln->>'monthly')::numeric,0), coalesce((ln->>'months')::numeric,12), coalesce(ln->>'note',''));
    end loop;
    return jsonb_build_object('ok',true,'count',jsonb_array_length(coalesce(req->'rows','[]'::jsonb)));
  end if;

  if action = 'addEmployee' then
    newid := ebda.uid(); dj := req->'emp';
    -- منع تكرار الموظف عند الإضافة اليدوية أيضاً (نفس الرقم القومى)
    nk := regexp_replace(translate(coalesce(dj->>'national_id',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g');
    if nk <> '' and exists(select 1 from ebda.employees z where z.national_key = nk) then
      return ebda.err('يوجد موظف مسجل بنفس الرقم القومى — عدّل بياناته بدلاً من إضافته مرة أخرى'); end if;
    insert into ebda.employees(id,school_id,category,emp_no,name,job,job_type,qualification,grad_year,national_id,birth_date,phone,hire_date,work_start,insurance_no,account_no,bank,branch,email,ebda_start,base_salary,contract_type,gender,address,retire_date,note,active,archived)
    values(newid, dj->>'school_id', coalesce(dj->>'category','contract'), coalesce(dj->>'emp_no',''), dj->>'name', coalesce(dj->>'job',''), coalesce(dj->>'job_type',''), coalesce(dj->>'qualification',''), coalesce(dj->>'grad_year',''), coalesce(dj->>'national_id',''), coalesce(dj->>'birth_date',''), coalesce(dj->>'phone',''), coalesce(dj->>'hire_date',''), coalesce(dj->>'work_start',''), coalesce(dj->>'insurance_no',''), coalesce(dj->>'account_no',''), coalesce(dj->>'bank',''), coalesce(dj->>'branch',''), coalesce(dj->>'email',''), coalesce(dj->>'ebda_start',''), coalesce((dj->>'base_salary')::numeric,0), coalesce(dj->>'contract_type',''), coalesce(dj->>'gender',''), coalesce(dj->>'address',''), coalesce(dj->>'retire_date',''), coalesce(dj->>'note',''), 'نعم','لا');
    update ebda.employees set dept=coalesce(dj->>'dept',''), manager_user_id=coalesce(dj->>'manager_user_id',''), birth_place=coalesce(dj->>'birth_place',''),
      secondment_status=coalesce(dj->>'secondment_status',''), serial_no=coalesce(dj->>'serial_no',''),
      national_key=regexp_replace(translate(coalesce(dj->>'national_id',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g') where id=newid;
    return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.employees z where z.id=newid));
  end if;
  if action = 'updateEmployee' then
    patch := req->'patch';
    update ebda.employees set
      category=coalesce(patch->>'category',category), emp_no=coalesce(patch->>'emp_no',emp_no), name=coalesce(patch->>'name',name),
      job=coalesce(patch->>'job',job), job_type=coalesce(patch->>'job_type',job_type), qualification=coalesce(patch->>'qualification',qualification),
      grad_year=coalesce(patch->>'grad_year',grad_year), national_id=coalesce(patch->>'national_id',national_id), birth_date=coalesce(patch->>'birth_date',birth_date),
      phone=coalesce(patch->>'phone',phone), hire_date=coalesce(patch->>'hire_date',hire_date), work_start=coalesce(patch->>'work_start',work_start),
      insurance_no=coalesce(patch->>'insurance_no',insurance_no), account_no=coalesce(patch->>'account_no',account_no), bank=coalesce(patch->>'bank',bank),
      branch=coalesce(patch->>'branch',branch), email=coalesce(patch->>'email',email), ebda_start=coalesce(patch->>'ebda_start',ebda_start),
      base_salary=coalesce((patch->>'base_salary')::numeric,base_salary), contract_type=coalesce(patch->>'contract_type',contract_type),
      gender=coalesce(patch->>'gender',gender), address=coalesce(patch->>'address',address), retire_date=coalesce(patch->>'retire_date',retire_date),
      note=coalesce(patch->>'note',note), school_id=coalesce(patch->>'school_id',school_id),
      dept=coalesce(patch->>'dept',dept), manager_user_id=coalesce(patch->>'manager_user_id',manager_user_id),
      birth_place=coalesce(patch->>'birth_place',birth_place), secondment_status=coalesce(patch->>'secondment_status',secondment_status),
      serial_no=coalesce(patch->>'serial_no',serial_no),
      net_before=ebda.numv(patch->>'net_before',net_before), increase_pct=ebda.numv(patch->>'increase_pct',increase_pct),
      increase_value=ebda.numv(patch->>'increase_value',increase_value), adjustment=ebda.numv(patch->>'adjustment',adjustment),
      si_employee=ebda.numv(patch->>'si_employee',si_employee), si_company=ebda.numv(patch->>'si_company',si_company),
      medical_ins=ebda.numv(patch->>'medical_ins',medical_ins), income_tax=ebda.numv(patch->>'income_tax',income_tax),
      other_ded=ebda.numv(patch->>'other_ded',other_ded), gross_file=ebda.numv(patch->>'gross_file',gross_file),
      salary_notes=coalesce(patch->>'salary_notes',salary_notes),
      national_key=case when patch ? 'national_id' then regexp_replace(translate(coalesce(patch->>'national_id',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g') else national_key end
    where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'linkEmployee' then
    update ebda.employees set dept=coalesce(req#>>'{patch,dept}',dept), manager_user_id=coalesce(req#>>'{patch,manager_user_id}',manager_user_id),
      school_id=coalesce(req#>>'{patch,school_id}',school_id), job=coalesce(req#>>'{patch,job}',job), contract_type=coalesce(req#>>'{patch,contract_type}',contract_type)
    where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'archiveEmployee' then
    update ebda.employees set archived='نعم', active='لا', archived_at=now()::text, archived_by=u.name where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'restoreEmployee' then
    update ebda.employees set archived='لا', active='نعم', archived_at='', archived_by='' where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'deleteEmployee' then delete from ebda.employees where id=(req->>'id'); return jsonb_build_object('ok',true); end if;
  if action = 'importEmployees' then
    sid := req->>'school_id';
    for ln in select * from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) loop
      insert into ebda.employees(id,school_id,category,emp_no,name,job,job_type,qualification,grad_year,national_id,birth_date,phone,hire_date,work_start,insurance_no,account_no,bank,branch,email,ebda_start,base_salary,contract_type,gender,address,retire_date,note,active,archived)
      values(ebda.uid(), sid, coalesce(ln->>'category','contract'), coalesce(ln->>'emp_no',''), coalesce(ln->>'name',''), coalesce(ln->>'job',''), coalesce(ln->>'job_type',''), coalesce(ln->>'qualification',''), coalesce(ln->>'grad_year',''), coalesce(ln->>'national_id',''), coalesce(ln->>'birth_date',''), coalesce(ln->>'phone',''), coalesce(ln->>'hire_date',''), coalesce(ln->>'work_start',''), coalesce(ln->>'insurance_no',''), coalesce(ln->>'account_no',''), coalesce(ln->>'bank',''), coalesce(ln->>'branch',''), coalesce(ln->>'email',''), coalesce(ln->>'ebda_start',''), coalesce((ln->>'base_salary')::numeric,0), coalesce(ln->>'contract_type',''), coalesce(ln->>'gender',''), coalesce(ln->>'address',''), coalesce(ln->>'retire_date',''), coalesce(ln->>'note',''), 'نعم','لا');
    end loop;
    return jsonb_build_object('ok',true,'count',jsonb_array_length(coalesce(req->'rows','[]'::jsonb)));
  end if;
  if action = 'addPayslip' then
    newid := ebda.uid(); dj := req->'slip';
    insert into ebda.payslips(id,employee_id,emp_name,school_id,month,base,incentive,allowances,gross,ded_medical,ded_social,ded_tax,ded_other,ded_total,net,note,created_by,created_at)
    values(newid, dj->>'employee_id', coalesce(dj->>'emp_name',''), dj->>'school_id', coalesce(dj->>'month',''),
      coalesce((dj->>'base')::numeric,0), coalesce((dj->>'incentive')::numeric,0), coalesce((dj->>'allowances')::numeric,0), coalesce((dj->>'gross')::numeric,0),
      coalesce((dj->>'ded_medical')::numeric,0), coalesce((dj->>'ded_social')::numeric,0), coalesce((dj->>'ded_tax')::numeric,0), coalesce((dj->>'ded_other')::numeric,0),
      coalesce((dj->>'ded_total')::numeric,0), coalesce((dj->>'net')::numeric,0), coalesce(dj->>'note',''), u.name, now()::text);
    return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.payslips z where z.id=newid));
  end if;
  if action = 'updatePayslip' then
    patch := req->'patch';
    update ebda.payslips set base=coalesce((patch->>'base')::numeric,base), incentive=coalesce((patch->>'incentive')::numeric,incentive),
      allowances=coalesce((patch->>'allowances')::numeric,allowances), gross=coalesce((patch->>'gross')::numeric,gross),
      ded_medical=coalesce((patch->>'ded_medical')::numeric,ded_medical), ded_social=coalesce((patch->>'ded_social')::numeric,ded_social),
      ded_tax=coalesce((patch->>'ded_tax')::numeric,ded_tax), ded_other=coalesce((patch->>'ded_other')::numeric,ded_other),
      ded_total=coalesce((patch->>'ded_total')::numeric,ded_total), net=coalesce((patch->>'net')::numeric,net), note=coalesce(patch->>'note',note)
    where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'deletePayslip' then delete from ebda.payslips where id=(req->>'id'); return jsonb_build_object('ok',true); end if;
  if action = 'addPayslipsBatch' then
    for ln in select * from jsonb_array_elements(coalesce(req->'rows','[]'::jsonb)) loop
      insert into ebda.payslips(id,employee_id,emp_name,school_id,month,base,incentive,allowances,gross,ded_medical,ded_social,ded_tax,ded_other,ded_total,net,note,created_by,created_at)
      values(ebda.uid(), ln->>'employee_id', coalesce(ln->>'emp_name',''), ln->>'school_id', coalesce(ln->>'month',''),
        coalesce((ln->>'base')::numeric,0), coalesce((ln->>'incentive')::numeric,0), coalesce((ln->>'allowances')::numeric,0), coalesce((ln->>'gross')::numeric,0),
        coalesce((ln->>'ded_medical')::numeric,0), coalesce((ln->>'ded_social')::numeric,0), coalesce((ln->>'ded_tax')::numeric,0), coalesce((ln->>'ded_other')::numeric,0),
        coalesce((ln->>'ded_total')::numeric,0), coalesce((ln->>'net')::numeric,0), coalesce(ln->>'note',''), u.name, now()::text);
    end loop;
    return jsonb_build_object('ok',true,'count',jsonb_array_length(coalesce(req->'rows','[]'::jsonb)));
  end if;

  if action = 'addTempBudget' then
    newid := ebda.uid();
    insert into ebda.temp_budgets(id,school_id,name,dfrom,dto,amount,note)
    values(newid, req#>>'{tb,school_id}', req#>>'{tb,name}', req#>>'{tb,dfrom}', req#>>'{tb,dto}',
      coalesce((req#>>'{tb,amount}')::numeric,0), coalesce(req#>>'{tb,note}',''));
    return jsonb_build_object('ok',true,'item',(select to_jsonb(z) from ebda.temp_budgets z where z.id=newid));
  end if;
  if action = 'deleteTempBudget' then delete from ebda.temp_budgets where id=(req->>'id'); return jsonb_build_object('ok',true); end if;

  if action = 'addSchool' then
    newid := ebda.uid();
    insert into ebda.schools(id,name,type,period,students,active,category)
    values(newid, req#>>'{school,name}', coalesce(req#>>'{school,type}',''), coalesce(req#>>'{school,period}',''),
       coalesce((req#>>'{school,students}')::numeric,0), 'نعم', coalesce(req#>>'{school,category}','school'));
    return jsonb_build_object('ok',true,'item',(select to_jsonb(s) from ebda.schools s where s.id=newid));
  end if;
  if action = 'updateSchool' then
    patch := req->'patch';
    update ebda.schools set name=coalesce(patch->>'name',name), type=coalesce(patch->>'type',type),
      period=coalesce(patch->>'period',period), students=coalesce((patch->>'students')::numeric,students),
      category=coalesce(patch->>'category',category), active=coalesce(patch->>'active',active)
    where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;
  if action = 'deleteSchool' then
    if exists(select 1 from ebda.custodies c where c.school_id=(req->>'id')) or exists(select 1 from ebda.expenses e where e.school_id=(req->>'id')) then
      return ebda.err('لا يمكن حذف جهة عليها عهد أو مصروفات — عطّلها بدلاً من الحذف'); end if;
    delete from ebda.lines where school_id=(req->>'id');
    delete from ebda.schools where id=(req->>'id');
    return jsonb_build_object('ok',true);
  end if;

  return ebda.err('إجراء غير معروف: '||coalesce(action,''));
end;
$fn$;

-- ---------------------------------------------------------------- الصلاحيات: الدالة العامة فقط (كما فى 002) — جداول النسخ الاحتياطى غير متاحة لأى دور عام
revoke all on all tables in schema ebda from anon, authenticated;
revoke all on all sequences in schema ebda from anon, authenticated;
revoke execute on all functions in schema ebda from public, anon, authenticated;
grant usage on schema ebda to anon, authenticated;
grant execute on function ebda.api(jsonb) to anon, authenticated;
grant execute on function public.api(jsonb) to anon, authenticated;

insert into ebda.config(key,value) values ('schema_version','8') on conflict (key) do update set value='8';

-- ===================== 9_run_ninth_009.sql =====================
do $ov$ begin perform set_config('ebda.fy_override', '1', false); end $ov$;   -- v11: الترحيل نفسه لا يُمنع بسبب عام مغلق
-- ============================================================================
--  ابدأ إديو للتطوير والتدريب — Migration 009 (v10)
--  (1) إدارة الأدمن للسجلات المستوردة/المضافة: إلغاء دفعة استيراد كاملة (رواتب · موازنات · مصروفات) مع معاينة العدد والقيمة،
--      إلغاء محدد (قسائم · كشف شهر كامل · بنود موازنة · موازنة كاملة) وتعديل جماعى لحقل واحد مع السبب والقيم السابقة
--  (2) مؤثرات الرواتب: ربط بالموظف بمعرّف ثابت + الشهر + المدرسة، قواعد حساب قابلة للضبط (بدون قيمة افتراضية)،
--      معاينة وتحقق قبل الحفظ، ومنع الاحتساب المزدوج عند إعادة الاستيراد
--  (3) «داش بورد»: مؤشرات الموازنة والعهد والمصروفات والرواتب + «تنبيهات وقرارات مطلوبة» محسوبة على الخادم
--  آمن للتكرار. إضافى فقط: لا يحذف بيانات — الملغى يبقى تاريخياً ويخرج من الإجماليات النشطة. يُشغَّل بعد 001 → 008.
-- ============================================================================
set search_path = ebda, public, extensions;

-- ---------------------------------------------------------------- الأعمدة الجديدة
alter table ebda.payslips add column if not exists import_batch text default '';     -- الدفعة التى أنشأت القسيمة
alter table ebda.payslips add column if not exists last_batch text default '';       -- آخر دفعة عدّلتها (لا تُلغى دفعة أقدم ما عدّلته دفعة لاحقة)
alter table ebda.payslips add column if not exists cancelled_at text default '';
alter table ebda.payslips add column if not exists cancelled_by text default '';
alter table ebda.payslips add column if not exists cancel_reason text default '';
-- المؤثرات (ملف «مؤثرات رواتب …»): صافى الراتب التعاقدى منفصل عن الصافى النهائى
alter table ebda.payslips add column if not exists emp_code text default '';
alter table ebda.payslips add column if not exists insurance_status text default '';
alter table ebda.payslips add column if not exists hire_date text default '';
alter table ebda.payslips add column if not exists contract_net numeric;              -- null = لا توجد بيانات مؤثرات لهذه القسيمة
alter table ebda.payslips add column if not exists eff_work_days numeric;             -- «عدد أيام العمل» من ملف المؤثرات
alter table ebda.payslips add column if not exists effects_summary text default '';
alter table ebda.payslips add column if not exists effects_note text default '';
alter table ebda.payslips add column if not exists ot_hours numeric default 0;
alter table ebda.payslips add column if not exists ot_days numeric default 0;
alter table ebda.payslips add column if not exists ded_hours numeric default 0;
alter table ebda.payslips add column if not exists ded_days numeric default 0;
alter table ebda.payslips add column if not exists base_due numeric;                  -- الراتب المستحق قبل المؤثرات (بعد التناسب إن كانت القاعدة تطبّقه)
alter table ebda.payslips add column if not exists ot_amount numeric default 0;
alter table ebda.payslips add column if not exists ded_amount numeric default 0;
alter table ebda.payslips add column if not exists effects_state text default '';     -- '' · no_effects · pending_rule · computed
alter table ebda.payslips add column if not exists effects_batch text default '';
alter table ebda.payslips add column if not exists effects_rule jsonb;                -- لقطة القاعدة المستخدمة فى الحساب

select 'الجزء 9 من 15 تم ✓ — شغّل الجزء 10' as result;
