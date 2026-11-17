-- EBDA_FINANCE_INSTALL_v10.57 — الجزء 13 من 15. شغّل الأجزاء بالترتيب (1 ثم 2 …) كل جزء Run مستقل فى SQL Editor. لا تتخطَّ جزءاً.
set search_path = ebda, public, extensions;
select set_config('ebda.fy_override', '1', false);

create or replace function ebda.import_custodies(u ebda.users, req jsonb) returns jsonb
language plpgsql security definer set search_path = ebda as $ic$
declare
  urole text := ebda.rk(u);
  commit_ boolean := coalesce(req->>'mode','preview') = 'commit';
  fname text := left(coalesce(req->>'file_name',''), 200);
  bid text := ebda.uid();
  sch text[] := ebda.scope_arr(u);
  rw jsonb; i int := 0; st text; errs jsonb; warns jsonb; out jsonb := '[]'::jsonb;
  sid text; sname text; k text; n int; cno text; hold text; cname text; amt numeric; d text; key text;
  ex ebda.custodies; hu ebda.users; cid text; ccode text;
  seen text[] := '{}';
  self_only boolean := ebda.rk(u) = 'custody_officer' and ebda.can(u,'custody.import') and not (ebda.can(u,'custody.create') and ebda.can(u,'custody.approve'));
  c_new int := 0; c_exist int := 0; c_dup int := 0; c_err int := 0; c_warn int := 0; tot numeric := 0;
begin
  if not (urole = 'admin' or (ebda.can(u,'custody.create') and ebda.can(u,'custody.approve')) or self_only) then
    return ebda.err('صلاحية إنشاء العهد واعتمادها مطلوبة'); end if;
  if jsonb_typeof(coalesce(req->'rows','null'::jsonb)) <> 'array' or jsonb_array_length(req->'rows') = 0 then
    return ebda.err('لم يُتعرَّف على أى عهدة فى الورقة'); end if;
  for rw in select * from jsonb_array_elements(req->'rows') loop
    i := i + 1; errs := '[]'::jsonb; warns := case when jsonb_typeof(rw->'warnings') = 'array' then rw->'warnings' else '[]'::jsonb end;
    st := 'new'; sid := null; sname := ''; ex := null; hu := null; cid := null; ccode := '';
    -- المدرسة
    if coalesce(rw->>'school_id','') <> '' and exists(select 1 from ebda.schools s where s.id = rw->>'school_id') then sid := rw->>'school_id';
    elsif btrim(coalesce(rw->>'school','')) <> '' then
      k := ebda.norm_txt(rw->>'school');
      select min(s.id), count(*) into sid, n from ebda.schools s where ebda.norm_txt(s.name) = k;
      if n <> 1 then sid := null; errs := errs || to_jsonb('المدرسة غير معروفة: '||btrim(rw->>'school')); end if;
    elsif urole <> 'admin' and coalesce(u.schools,'') <> '*' and cardinality(sch) = 1 then sid := sch[1];
    else errs := errs || to_jsonb('المدرسة غير محددة'::text);
    end if;
    if sid is not null and not ebda.can_school(u, sid) then errs := errs || to_jsonb('المدرسة ليست ضمن نطاقك'::text); sid := null; end if;
    if sid is not null then select s.name into sname from ebda.schools s where s.id = sid; end if;
    cno := btrim(translate(coalesce(rw->>'custody_no',''), '٠١٢٣٤٥٦٧٨٩', '0123456789'));
    hold := btrim(regexp_replace(coalesce(rw->>'holder',''), '\s+', ' ', 'g'));
    if self_only and hold = '' then hold := u.name; end if;   -- مسئول العهدة: العهدة باسمه
    cname := btrim(coalesce(rw->>'custody_name',''));
    if cno = '' and hold = '' and cname = '' then errs := errs || to_jsonb('لا يوجد رقم عهدة ولا مسئول ولا اسم عهدة'::text); end if;
    amt := case when btrim(coalesce(rw->>'amount','')) = '' then 0 else ebda.imp_num(rw->>'amount') end;
    if amt is null or amt < 0 then errs := errs || to_jsonb('قيمة العهدة غير صحيحة: '||coalesce(rw->>'amount','')); amt := 0;
    elsif amt = 0 then warns := warns || to_jsonb('العهدة بدون قيمة — تُنشأ بدون دفعة'::text); end if;
    d := btrim(coalesce(rw->>'date',''));
    if d <> '' and not ebda.imp_date_ok(d) then warns := warns || to_jsonb('تاريخ العهدة غير مفهوم — استُخدم تاريخ اليوم'::text); d := ''; end if;
    if d > to_char(now() + interval '1 day','YYYY-MM-DD') then errs := errs || to_jsonb('تاريخ العهدة فى المستقبل: '||d); end if;
    if jsonb_array_length(errs) = 0 then
      key := sid || '|' || case when cno <> '' then 'n:'||upper(cno) else 'h:'||ebda.norm_txt(hold)||'|'||ebda.norm_txt(cname)||'|'||d end;
      if key = any(seen) then st := 'duplicate'; warns := warns || to_jsonb('مكررة داخل الملف'::text);
      else
        if cno <> '' then
          select * into ex from ebda.custodies c where c.school_id = sid and c.ext_ref = cno and coalesce(c.status,'') <> 'cancelled' order by c.opened_at desc limit 1;
          if ex.id is null then select * into ex from ebda.custodies c where upper(c.code) = upper(cno) limit 1; end if;
          if ex.id is not null and ex.school_id is distinct from sid then errs := errs || to_jsonb('رقم العهدة '||cno||' تابع لمدرسة أخرى'); end if;
        else
          select * into ex from ebda.custodies c where c.school_id = sid and coalesce(c.status,'open') <> 'cancelled'
            and (ebda.norm_txt(ebda.person_name(c.user_id, c.holder_emp_id, c.holder, c.label)) = ebda.norm_txt(hold)
                 or (coalesce(c.holder,'') <> '' and ebda.norm_txt(c.holder) = ebda.norm_txt(hold)))
            and (cname = '' or ebda.norm_txt(ebda.custody_name(c.title, c.label, c.code)) = ebda.norm_txt(cname))
            and (d = '' or left(coalesce(c.opened_at,''),10) = d) order by c.opened_at desc limit 1;
        end if;
        if ex.id is not null then
          st := 'exists'; cid := ex.id; ccode := ex.code;
          if amt > 0 and abs(amt - (select coalesce(sum(t.amount),0) from ebda.tranches t where t.custody_id = ex.id)) > 0.5 then
            warns := warns || to_jsonb('القيمة فى الملف ('||amt||') تختلف عن المسجلة ('||(select coalesce(sum(t.amount),0) from ebda.tranches t where t.custody_id = ex.id)||') — لم تُعدَّل'); end if;
        end if;
      end if;
      seen := seen || key;
    end if;
    if self_only and st = 'new' and hold <> '' and ebda.norm_txt(hold) <> ebda.norm_txt(u.name) then
      errs := errs || to_jsonb('العهدة باسم مسئول آخر ('||hold||') — يمكنك استيراد عهدك أنت فقط');
    end if;
    if self_only and st = 'exists' and coalesce(ex.user_id,'') <> u.id and coalesce(ex."user",'') <> u.username then
      errs := errs || to_jsonb('العهدة '||coalesce(ex.code,'')||' ليست عهدتك'); end if;
    if jsonb_array_length(errs) > 0 then st := 'error'; end if;
    if self_only and st = 'new' then
      hu := u; warns := warns || to_jsonb('عهدة جديدة باسمك — تُرسل للاعتماد (المدير المالى) ولا تُعتمد تلقائياً'::text);
    elsif st = 'new' and hold <> '' then
      select * into hu from ebda.users z where coalesce(z.active,'نعم') like '%نعم%' and ebda.norm_txt(z.name) = ebda.norm_txt(hold)
        and (coalesce(z.schools,'') = '*' or sid = any(ebda.scope_arr(z))) order by case when ebda.rk(z) = 'custody_officer' then 0 else 1 end limit 1;
      if hu.id is null then warns := warns || to_jsonb('مسئول العهدة «'||hold||'» غير مسجل كمستخدم — تُنشأ العهدة باسمه بدون حساب دخول'); end if;
    elsif st = 'new' then
      warns := warns || to_jsonb('مسئول العهدة غير مذكور — حدّده لاحقاً من شاشة العهد'::text);
    end if;
    if st = 'new' then c_new := c_new + 1; tot := tot + amt; elsif st = 'exists' then c_exist := c_exist + 1;
    elsif st = 'duplicate' then c_dup := c_dup + 1; else c_err := c_err + 1; end if;
    if st in ('new','exists') and jsonb_array_length(warns) > 0 then c_warn := c_warn + 1; end if;
    if commit_ and st = 'new' then
      cid := ebda.uid();
      insert into ebda.custodies(id,label,holder,school_id,note,"user",code,status,opened_at,kind,purpose)
      values(cid, coalesce(nullif(cname,''), 'عهدة '||coalesce(nullif(hold,''), cno)), coalesce(nullif(hold,''), hu.name, ''), sid,
             concat_ws(' · ', 'أُنشئت من استيراد ملف العهد: '||fname, nullif(left(coalesce(rw->>'note',''),1000),'')),
             coalesce(hu.username,''), 'CUST-'||lpad(nextval('ebda.seq_cust')::text,3,'0'), 'open',
             coalesce(nullif(d,''), to_char(now(),'YYYY-MM-DD')), coalesce(rw->>'kind',''), coalesce(rw->>'purpose',''));
      update ebda.custodies set user_id = coalesce(hu.id,''),
        approval = case when self_only then 'review' else 'approved' end, approved_by = case when self_only then '' else u.name end,
        approved_at = case when self_only then '' else now()::text end, submitted_by = case when self_only then u.name else submitted_by end,
        ext_ref = cno, import_batch = bid, title = cname where id = cid;
      if amt > 0 then
        insert into ebda.tranches(id,custody_id,date,amount,note)
        values(ebda.uid(), cid, coalesce(nullif(d,''), to_char(now(),'YYYY-MM-DD')), amt, 'القيمة الأساسية للعهدة (من ملف الاستيراد)');
      end if;
      select code into ccode from ebda.custodies where id = cid;
    end if;
    out := out || jsonb_build_object('i', i, 'r', coalesce(rw->>'r',''), 'status', st, 'errors', errs, 'warnings', warns,
      'school_id', sid, 'school', coalesce(sname, rw->>'school', ''), 'custody_no', cno, 'code', ccode, 'custody_id', cid,
      'holder', coalesce(nullif(hold,''), hu.name, ''), 'linked_user', hu.id is not null, 'custody_name', cname, 'amount', amt, 'date', d);
  end loop;
  if commit_ then
    insert into ebda.import_batches(id,kind,file_name,actor,actor_id,approve_mode,rows_n,imported_n,amount,summary,exceptions)
    values(bid, 'custodies', fname, u.name, u.id, case when self_only then 'workflow' else 'approved' end, i, c_new, tot,
           jsonb_build_object('rows', i, 'new', c_new, 'exists', c_exist, 'duplicate', c_dup, 'error', c_err),
           coalesce((select jsonb_agg(x) from jsonb_array_elements(out) x where x->>'status' in ('error','duplicate') or jsonb_array_length(x->'warnings') > 0), '[]'::jsonb));
  end if;
  return jsonb_build_object('ok', true, 'mode', case when commit_ then 'commit' else 'preview' end, 'batch_id', case when commit_ then bid end,
    'summary', jsonb_build_object('rows', i, 'new', c_new, 'exists', c_exist, 'duplicate', c_dup, 'error', c_err, 'warning', c_warn, 'amount', tot),
    'rows', out);
end $ic$;

select 'الجزء 13 من 15 تم ✓ — شغّل الجزء 14' as result;
