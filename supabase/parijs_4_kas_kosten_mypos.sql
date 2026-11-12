-- Parijs (deel 4): contante omzet en kosten voor de planner van een markt;
-- myPOS per terminal naar de juiste markt.

-- ── Contante omzet (planner van een markt met contant geld, en Bram) ──────
create or replace function public.mag_kas(p_vest text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_vest is not null and public.in_actieve_vestiging(p_vest) and public.vest_ok(p_vest)
     and coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = p_vest and i.sleutel = 'contant'),'ja') = 'ja'
     and (public.mag_omzet_zien() or (public.is_planner() and p_vest = public.actieve_vestiging()))
$$;

create or replace function public.mcr_kas_lijst(p_van date, p_tot date)
returns table(kraam_id uuid, kraam text, kleur text, datum date, contant numeric, door text, op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select k.id, k.naam, coalesce(k.kleur,'#6B6A66'), d.datum, r.omzet_contant, g.naam, r.bijgewerkt_op
    from public.kramen k
    cross join generate_series(greatest(p_van, k.seizoen_start), least(p_tot, k.seizoen_eind), interval '1 day') d0
    cross join lateral (select d0::date as datum) d
    left join public.dagrapporten r on r.kraam_id = k.id and r.datum = d.datum
    left join public.gebruikers g on g.id = r.bijgewerkt_door
   where k.actief and public.mag_kas(k.vestiging) and (p_tot - p_van) <= 92
   order by d.datum desc, k.volgorde, k.naam
$$;
revoke all on function public.mcr_kas_lijst(date,date) from public, anon;
grant execute on function public.mcr_kas_lijst(date,date) to authenticated;

create or replace function public.mcr_kas_zetten(p_kraam uuid, p_datum date, p_bedrag numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_vest text; v_tz text;
begin
  select k.vestiging into v_vest from public.kramen k where k.id = p_kraam;
  if not public.mag_kas(v_vest) then
    raise exception 'Je kunt de contante omzet van deze kraam niet invullen.' using errcode='P0002';
  end if;
  v_tz := public.mkt_tz(v_vest);
  if p_datum is null or p_datum > (now() at time zone v_tz)::date then
    raise exception 'Kies vandaag of een eerdere dag.' using errcode='P0002';
  end if;
  if p_bedrag is not null and (p_bedrag < 0 or p_bedrag > 100000) then
    raise exception 'Dat bedrag klopt niet.' using errcode='P0002';
  end if;
  insert into public.dagrapporten (kraam_id, datum, omzet_contant, bijgewerkt_op, bijgewerkt_door)
  values (p_kraam, p_datum, round(p_bedrag,2), now(), public.huidige_gebruiker())
  on conflict (kraam_id, datum) do update
     set omzet_contant = excluded.omzet_contant, bijgewerkt_op = now(), bijgewerkt_door = excluded.bijgewerkt_door;
end $$;
revoke all on function public.mcr_kas_zetten(uuid,date,numeric) from public, anon;
grant execute on function public.mcr_kas_zetten(uuid,date,numeric) to authenticated;

-- ── Kosten: ook de planner van een markt (eigen markt; wijzigen alleen eigen posten) ──
select public._fn_vervang('public.mcr_kosten_lijst2(date,date)'::regprocedure,
  ') _rijen where public.mag_kraambeheer() and public.mag_cijfers_zien();',
  ') _rijen where (public.mag_kraambeheer() and public.mag_cijfers_zien()) or public.is_planner();');
select public._fn_vervang('public.mcr_kosten_zetten2(uuid,date,uuid,text,text,numeric,text,text,text,numeric,text)'::regprocedure,
  'if not (public.mag_kraambeheer() and public.mag_cijfers_zien()) then
    raise exception ''Je hebt geen toegang tot de kosten van Manchester.'';',
  'if not ((public.mag_kraambeheer() and public.mag_cijfers_zien()) or public.is_planner()) then
    raise exception ''Je hebt geen toegang tot deze kosten.'';
  end if;
  if public.is_planner() and not (public.mag_kraambeheer() and public.mag_cijfers_zien()) and p_id is not null
     and not exists (select 1 from public.mcr_kosten c where c.id = p_id and c.aangemaakt_door = v_uid) then
    raise exception ''Je kunt alleen je eigen kostenposten wijzigen.'';');
select public._fn_vervang('public.mcr_kosten_zetten2(uuid,date,uuid,text,text,numeric,text,text,text,numeric,text)'::regprocedure,
  'coalesce(p_valuta,''GBP'')', 'coalesce(p_valuta,(select v.valuta from public.vestigingen v where v.code = v_vest),''GBP'')');
select public._fn_vervang('public.mcr_kosten_zetten2(uuid,date,uuid,text,text,numeric,text,text,text,numeric,text)'::regprocedure,
  'public.in_actieve_vestiging(k.vestiging) limit 1), ''MCR'');',
  'public.in_actieve_vestiging(k.vestiging) limit 1), public.actieve_vestiging());');
select public._fn_vervang('public.mcr_kosten_weg(uuid)'::regprocedure,
  'if not (public.mag_kraambeheer() and public.mag_cijfers_zien()) then
    raise exception ''Je hebt geen toegang tot de kosten van Manchester.'';
  end if;
  delete from public.mcr_kosten c where c.id = p_id and public.vest_ok(c.vestiging);',
  'if not ((public.mag_kraambeheer() and public.mag_cijfers_zien()) or public.is_planner()) then
    raise exception ''Je hebt geen toegang tot deze kosten.'';
  end if;
  delete from public.mcr_kosten c where c.id = p_id and public.vest_ok(c.vestiging) and public.in_actieve_vestiging(c.vestiging)
     and ((public.mag_kraambeheer() and public.mag_cijfers_zien()) or c.aangemaakt_door = public.huidige_gebruiker());');

-- ── myPOS: elke betaling naar de markt van zijn terminal ─────────────────
-- De rekening "TC group" levert nu ook de terminals van Parijs (in euro's).
-- Een terminal die aan een kraam gekoppeld is, bepaalt de markt. Nog niet
-- gekoppeld: een betaling in de munt van een andere markt (euro) gaat naar die
-- markt, de rest naar de markt van de rekening. Bedrag en dag/uur worden in de
-- munt en tijdzone van die markt genomen.
create or replace function public.mypos_verwerk(p_account uuid, p_rijen jsonb)
returns table(opgeslagen integer, doorgezet integer)
language plpgsql security definer set search_path to 'public'
as $function$
declare v_vest text; v_val text; v_vestn text[]; v text; n int;
begin
  select a.vestiging, upper(coalesce(a.valuta,'GBP')) into v_vest, v_val from public.mypos_accounts a where a.id = p_account;
  if v_vest is null then raise exception 'onbekende rekening'; end if;
  with rij as (
    select r, r->>'tid' as tid,
           coalesce((select t.vestiging from public.terminals t
                      where t.tid = r->>'tid' and t.kraam_id is not null and not coalesce(t.negeren,false)
                      order by t.vanaf desc nulls last limit 1),
                    case when upper(coalesce(r->>'oc','')) <> v_val
                         then (select m.code from public.vestigingen m
                                where m.valuta = upper(r->>'oc') and public.is_markt(m.code) and m.actief
                                order by m.volgorde limit 1) end,
                    v_vest) as vest
      from jsonb_array_elements(p_rijen) r
     where r->>'ref' is not null and r->>'tid' is not null and r->>'dag' is not null
  ), bedrag as (
    select x.*, m.valuta as mval, m.tijdzone as mtz,
           case when x.r ? 'ts' then (x.r->>'ts')::timestamptz end as ts,
           case
             when upper(coalesce(x.r->>'oc','')) = m.valuta and x.r ? 'oa' then (x.r->>'oa')::numeric
             when upper(coalesce(x.r->>'tc','')) = m.valuta and x.r ? 'ta' then (x.r->>'ta')::numeric
             when m.valuta = v_val then coalesce((x.r->>'bedrag')::numeric,0)
           end as b,
           case
             when m.valuta = v_val then coalesce((x.r->>'kosten')::numeric,0)
             when upper(coalesce(x.r->>'tc','')) = m.valuta then coalesce((x.r->>'kt')::numeric,0)
             when coalesce((x.r->>'ta')::numeric,0) <> 0 and x.r ? 'oa'
               then round(coalesce((x.r->>'kt')::numeric,0) * abs((x.r->>'oa')::numeric / (x.r->>'ta')::numeric), 2)
             else 0
           end as k
      from rij x join public.vestigingen m on m.code = x.vest
  )
  insert into public.mypos_transacties (referentie, account_id, vestiging, tid, dag, uur, bedrag, kosten)
  select b.r->>'ref', p_account, b.vest, b.tid,
         coalesce((b.ts at time zone b.mtz)::date, (b.r->>'dag')::date),
         coalesce(extract(hour from (b.ts at time zone b.mtz))::int, (b.r->>'uur')::int, 0),
         round(b.b,2), round(b.k,2)
    from bedrag b
   where b.b is not null
  on conflict (referentie) do nothing;
  get diagnostics opgeslagen = row_count;
  doorgezet := 0;
  for v in select distinct t.vestiging from public.mypos_transacties t where t.account_id = p_account and not t.ingelezen loop
    n := public.mypos_doorzetten(v); doorgezet := doorgezet + coalesce(n,0);
  end loop;
  return next;
end $function$;

-- Nieuwe terminals: Bram ziet een nog niet gekoppelde terminal in elke markt,
-- zodat hij een Parijse terminal vanuit Parijs aan de kraam kan koppelen.
select public._fn_vervang('public.mypos_terminals_gezien()'::regprocedure,
  'where public.vest_ok(x.vestiging) and public.in_actieve_vestiging(x.vestiging)',
  'where public.vest_ok(x.vestiging) and (public.in_actieve_vestiging(x.vestiging)
          or not exists (select 1 from public.terminals t2 where t2.tid = x.tid))');

create or replace function public.mypos_tid_kiezen(p_tid text, p_kraam uuid)
returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_vest text := public.actieve_vestiging(); v_id uuid; v_tid text := btrim(coalesce(p_tid,'')); v text;
begin
  if not (public.mag_kraambeheer() and public.mag_omzet_zien()) then
    raise exception 'Alleen een beheerder van deze vestiging.' using errcode='P0002'; end if;
  if v_tid = '' then raise exception 'Geen terminal.' using errcode='P0002'; end if;
  if p_kraam is not null and not exists (select 1 from public.kramen k where k.id = p_kraam and k.vestiging = v_vest) then
    raise exception 'Onbekende kraam.' using errcode='P0002'; end if;
  -- Hoort de terminal nu bij deze markt, dan verhuizen de betalingen mee
  if p_kraam is not null and exists (select 1 from public.mypos_transacties t where t.tid = v_tid and t.vestiging <> v_vest) then
    if exists (select 1 from public.terminals t where t.tid = v_tid and t.vestiging <> v_vest and t.kraam_id is not null and not coalesce(t.negeren,false)) then
      raise exception 'Deze terminal hoort al bij een kraam in een andere markt. Ontkoppel hem daar eerst.' using errcode='P0002';
    end if;
    for v in select distinct t.vestiging from public.mypos_transacties t where t.tid = v_tid and t.vestiging <> v_vest loop
      delete from public.pin_dag d where d.vestiging = v and d.tid = v_tid;
      delete from public.pin_uur d where d.vestiging = v and d.tid = v_tid;
    end loop;
    update public.mypos_transacties t set vestiging = v_vest, ingelezen = false where t.tid = v_tid and t.vestiging <> v_vest;
  end if;
  select t.id into v_id from public.terminals t
   where t.vestiging = v_vest and t.tid = v_tid order by t.vanaf desc nulls last limit 1;
  if v_id is null then
    insert into public.terminals (vestiging, tid, kraam_id, negeren) values (v_vest, v_tid, p_kraam, p_kraam is null);
  else
    update public.terminals set kraam_id = p_kraam, negeren = (p_kraam is null) where id = v_id;
  end if;
  update public.pin_dag d set kraam_id = public.kraam_van_tid(v_vest, d.tid, d.datum)
   where d.vestiging = v_vest and d.tid = v_tid;
  perform public.mypos_doorzetten(v_vest);
end $function$;
