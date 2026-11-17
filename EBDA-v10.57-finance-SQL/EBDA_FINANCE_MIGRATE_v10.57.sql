-- EBDA v10.57 — نقل بيانات النظام المالى المستقل إلى TEMS (شغّله بعد EBDA_FINANCE_INSTALL_v10.57.sql).
-- بعد التشغيل: select ebda.fin_migrate('<connection>','preview');  ثم  'commit'  — راجع docs/FINANCE_v10.57_AR.md
do $chk$ begin
  if to_regprocedure('public.ebda_fin_api(text,jsonb)') is null or to_regclass('ebda.audit_log') is null then
    raise exception 'شغّل ملفات EBDA_FINANCE_INSTALL_v10.57 (الأجزاء كلها بالترتيب) أولاً — ثم هذا الملف';
  end if;
end $chk$;
-- EBDA Finance → TEMS: moving the data of the separate finance project into the TEMS database (v10.57). Re-runnable.
-- Reads the OLD finance project directly (dblink, read only there) and copies EVERY table of its «ebda» schema as it is: same ids, numbers,
-- dates, amounts, notes, links, audit trail, archives, import batches, server backups — except the old sign-in sessions.
-- Nothing is changed or deleted in the OLD project. On the TEMS side only the finance schema «ebda» is written (TEMS tables untouched).
--
--   1) preview (writes nothing):  select ebda.fin_migrate('<connection>', 'preview');
--   2) copy:                      select ebda.fin_migrate('<connection>', 'commit');
--   <connection> = the OLD project's «Session pooler» connection (Supabase → old project → Connect):
--      host=aws-0-<region>.pooler.supabase.com port=5432 dbname=postgres user=postgres.<old-project-ref> password=<old database password> sslmode=require
--
-- Safety: the copy replaces the finance tables of THIS database only while they hold no work of their own (a fresh install, or a previous
-- copy not used since): if anything was recorded here after the copy, it stops and explains instead of overwriting. Each copy is checked:
-- for every table the number of rows and the total of every amount column, old vs new — the report is returned and kept (ebda.config).
create extension if not exists dblink with schema extensions;

create or replace function ebda.fin_migrate(p_conn text, p_mode text default 'preview') returns jsonb language plpgsql volatile security definer
set search_path = ebda, public, extensions as $mg$
declare
  t text; cols text; ncols text; numc text[]; c text; q text; n_old bigint; n_new bigint; s_old numeric; s_new numeric;
  rep jsonb := '[]'::jsonb; diffs int := 0; skip text[] := array['sessions','tems_grant_log'];
  old_tables text[]; new_tables text[]; missing text[]; prev text; used boolean; sv text; seqs record; v bigint;
  t0 timestamptz := clock_timestamp(); commit_ boolean := p_mode = 'commit';
begin
  if p_mode not in ('preview','commit') then return jsonb_build_object('error','mode = preview | commit'); end if;
  perform extensions.dblink_connect('fin_mig', p_conn);
  begin
    select array_agg(x) into old_tables from extensions.dblink('fin_mig', $q$select tablename::text from pg_tables where schemaname = 'ebda' order by 1$q$) as r(x text);
    select array_agg(tablename::text order by 1) into new_tables from pg_tables where schemaname = 'ebda';
    sv := (select x from extensions.dblink('fin_mig', $q$select value from ebda.config where key = 'schema_version'$q$) as r(x text) limit 1);
    select array_agg(x) into missing from unnest(old_tables) x where not (x = any(new_tables)) and not (x = any(skip));
    if missing is not null then
      perform extensions.dblink_disconnect('fin_mig');
      return jsonb_build_object('error', 'جداول فى النظام القديم غير موجودة هنا — شغّل EBDA_FINANCE_INSTALL أولاً', 'missing', to_jsonb(missing));
    end if;
    -- was a previous copy used here since? (any audit row that is not in the old project = work done here)
    prev := (select value from ebda.config where key = 'fin_migrated_at');
    used := false;
    if prev is not null then
      select exists (select 1 from ebda.audit_log a where a.id not in (select x from extensions.dblink('fin_mig', 'select id::text from ebda.audit_log') as r(x text))) into used;
    else
      select exists (select 1 from ebda.expenses) or exists (select 1 from ebda.custodies) or exists (select 1 from ebda.requests)
          or exists (select 1 from ebda.payslips) or exists (select 1 from ebda.pay2_effects) or exists (select 1 from ebda.tranches) into used;
    end if;
    if used and commit_ then
      perform extensions.dblink_disconnect('fin_mig');
      return jsonb_build_object('error', 'توجد بيانات مالية سُجّلت هنا بعد النسخ (أو قبل أول نقل) — لم يُنسخ شىء حتى لا تُستبدل. راجع قبل أى نقل جديد.', 'migrated_at', prev);
    end if;
    if commit_ then
      perform ebda.make_backup('safety', 'TEMS', 'قبل نقل بيانات النظام المالى المستقل');
      perform set_config('ebda.restoring', '1', true);
    end if;
    foreach t in array old_tables loop
      if t = any(skip) then continue; end if;
      -- the columns both sides have (a column only here keeps its default)
      select string_agg(format('%I', a.attname), ',' order by a.attnum), array_agg(a.attname::text order by a.attnum) filter (where format_type(a.atttypid, a.atttypmod) in ('numeric','integer','bigint','double precision','real','smallint'))
        into cols, numc
        from pg_attribute a where a.attrelid = ('ebda.'||t)::regclass and a.attnum > 0 and not a.attisdropped
         and a.attname::text in (select x from extensions.dblink('fin_mig', format('select column_name::text from information_schema.columns where table_schema = %L and table_name = %L', 'ebda', t)) as r(x text));
      q := format('select count(*)%s from ebda.%I', coalesce((select string_agg(format(', coalesce(sum(%I),0)', x), '') from unnest(numc) x), ''), t);
      select x into n_old from extensions.dblink('fin_mig', format('select count(*)::bigint from ebda.%I', t)) as r(x bigint);
      s_old := 0; s_new := 0;
      if numc is not null then
        select x into s_old from extensions.dblink('fin_mig', format('select (%s)::numeric from ebda.%I', (select string_agg(format('coalesce(sum(%I),0)', x), '+') from unnest(numc) x), t)) as r(x numeric);
      end if;
      if commit_ then
        execute format('delete from ebda.%I', t);
        execute format('insert into ebda.%1$I(%2$s) select %2$s from extensions.dblink(%3$L, %4$L) as r(j text), lateral jsonb_populate_record(null::ebda.%1$I, r.j::jsonb) z',
                       t, cols, 'fin_mig', format('select row_to_json(x)::text from ebda.%I x', t));
      end if;
      execute format('select count(*) from ebda.%I', t) into n_new;
      if numc is not null then
        execute format('select (%s)::numeric from ebda.%I', (select string_agg(format('coalesce(sum(%I),0)', x), '+') from unnest(numc) x), t) into s_new;
      end if;
      if commit_ and (n_new <> n_old or coalesce(s_new,0) <> coalesce(s_old,0)) then diffs := diffs + 1; end if;
      rep := rep || jsonb_build_object('table', t, 'old_rows', n_old, 'new_rows', n_new, 'old_amounts', s_old, 'new_amounts', s_new,
                                       'match', n_new = n_old and coalesce(s_new,0) = coalesce(s_old,0));
    end loop;
    if commit_ then
      -- the running numbers never go back (no repeated operation / document number)
      for seqs in select sequencename::text s from pg_sequences where schemaname = 'ebda' loop
        begin
          select x into v from extensions.dblink('fin_mig', format('select last_value from ebda.%I', seqs.s)) as r(x bigint);
          -- a column numbered by this sequence: never below its highest value either
          select (select format('select coalesce(max(%I),0)::bigint from %s', a.attname, d.refobjid::regclass) from pg_depend d join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
                   where d.objid = format('ebda.%I', seqs.s)::regclass and d.deptype in ('a','i') limit 1) into q;
          if q is not null then execute q into n_new; else n_new := 0; end if;
          perform setval(format('ebda.%I', seqs.s)::regclass, greatest(coalesce(v,1), coalesce((select last_value from pg_sequences where schemaname='ebda' and sequencename=seqs.s),1), n_new, 1));
        exception when others then null; end;
      end loop;
      perform set_config('ebda.restoring', '', true);
      begin perform ebda.catalog_link_all(); exception when undefined_function then null; end;
      begin perform ebda.rebuild_line_agg(); exception when undefined_function then null; end;
      -- this database stays closed to the old sign-in (the copy brought the old config back)
      insert into ebda.config(key, value) values ('allow_pin_auth', 'no') on conflict (key) do update set value = 'no';
      insert into ebda.config(key, value) values ('fin_migrated_at', now()::text) on conflict (key) do update set value = excluded.value;
      insert into ebda.config(key, value) values ('fin_migration_report', jsonb_build_object('at', now(), 'old_schema_version', sv, 'tables', rep, 'differences', diffs)::text)
        on conflict (key) do update set value = excluded.value;
    end if;
  exception when others then
    begin perform extensions.dblink_disconnect('fin_mig'); exception when others then null; end;
    raise;
  end;
  perform extensions.dblink_disconnect('fin_mig');
  return jsonb_build_object('ok', true, 'mode', p_mode, 'old_schema_version', sv, 'tables', jsonb_array_length(rep), 'differences', diffs,
                            'seconds', round(extract(epoch from clock_timestamp() - t0)::numeric, 1), 'report', rep,
                            'note', case when commit_ then 'تم النقل — كل جدول: عدد السجلات ومجموع المبالغ قبل/بعد' else 'معاينة فقط — لم يُكتب شىء' end);
end $mg$;
revoke all on function ebda.fin_migrate(text, text) from public, anon, authenticated;
select 'دالة النقل جاهزة ✓ — الآن: select ebda.fin_migrate(''<connection>'', ''preview'');' as result;
