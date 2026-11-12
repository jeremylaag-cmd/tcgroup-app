-- Te laat ingeklokt: de manager hoeft niet meer "te laat / niet te laat" te kiezen.
-- 'ok' (Looks right) mag nu ook als iemand later inklokte; de uren tellen vanaf het inklokken.
select public._fn_vervang('public.mgr_controle_zetten(uuid,date,uuid,text)'::regprocedure,
$o$if p_uitkomst = 'ok' and m.minuten_te_laat > 0 then
      raise exception 'Clocked in late. Choose late or not late.' using errcode='P0002';
    end if;$o$,
$n$null;$n$);
