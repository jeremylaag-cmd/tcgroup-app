-- Parijs (deel 2): dagafsluiting met gas, aardbeien en bananen; voorraad blijft
-- staan tot iemand hem regelt; pin per terminal bij het afsluiten (Liverpool);
-- meldingen in de taal van de ontvanger.

alter table public.mcr_dagafsluiting
  add column if not exists gas_flessen     integer,
  add column if not exists aardbeien       integer,
  add column if not exists bananen         integer,
  add column if not exists geregeld_op     timestamptz,
  add column if not exists geregeld_door   uuid references public.gebruikers(id),
  add column if not exists voorraad_notitie text,
  add column if not exists notitie_op      timestamptz;

-- Wordt bij de afsluiting naar fruit gevraagd? (Parijs: alleen poffertjes)
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving, bijgewerkt_op) values
  ('MCR', 'vraag_fruit', 'ja', 'Bij het afsluiten vragen hoeveel aardbeien en bananen er nodig zijn', now()),
  ('LPL', 'vraag_fruit', 'ja', 'Bij het afsluiten vragen hoeveel aardbeien en bananen er nodig zijn', now())
on conflict do nothing;

-- Terminals die bij een kraam horen (voor het invullen van de pin bij afsluiten)
create or replace function public.kraam_terminals(p_kraam uuid)
returns text[] language sql stable security definer set search_path to 'public' as $$
  select coalesce(array_agg(t order by t), '{}') from (
    select distinct x.tid t from public.terminals x where x.kraam_id = p_kraam and not coalesce(x.negeren,false)
    union
    select distinct d.tid from public.pin_dag d where d.kraam_id = p_kraam and d.datum >= current_date - 21
  ) y where t is not null and t <> ''
$$;
revoke all on function public.kraam_terminals(uuid) from public, anon, authenticated;
grant execute on function public.kraam_terminals(uuid) to app_rpc, service_role;

-- Pin per terminal wegschrijven (alleen vanuit mgr_dag_afsluiten, dat alles al controleerde)
create or replace function public._pin_dag_schrijven(p_kraam uuid, p_datum date, p_pin jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_vest text; r jsonb; v_tid text;
begin
  select k.vestiging into v_vest from public.kramen k where k.id = p_kraam;
  delete from public.pin_dag pd where pd.kraam_id = p_kraam and pd.datum = p_datum;
  for r in select * from jsonb_array_elements(p_pin) loop
    v_tid := nullif(left(btrim(coalesce(r->>'tid','')),40),'');
    if v_tid is null then continue; end if;
    insert into public.pin_dag (vestiging, tid, datum, kraam_id, omzet, transacties, kosten, bijgewerkt_op)
    values (v_vest, v_tid, p_datum, p_kraam, round(coalesce(nullif(r->>'omzet','')::numeric,0),2),
            coalesce(nullif(r->>'transacties','')::int,0), 0, now())
    on conflict (vestiging, tid, datum) do update set kraam_id = excluded.kraam_id, omzet = excluded.omzet,
           transacties = excluded.transacties, bijgewerkt_op = now();
  end loop;
end $$;
revoke all on function public._pin_dag_schrijven(uuid,date,jsonb) from public, anon, authenticated;
grant execute on function public._pin_dag_schrijven(uuid,date,jsonb) to app_rpc;

-- De dag afsluiten (kraammanager)
drop function if exists public.mgr_dag_afsluiten(uuid, date, boolean, boolean, boolean, text[], text);
create or replace function public.mgr_dag_afsluiten(p_kraam uuid, p_datum date, p_schoonmaak boolean, p_gas boolean,
  p_voorraad boolean, p_items text[] default '{}', p_tekst text default null,
  p_gas_flessen integer default null, p_aardbeien integer default null, p_bananen integer default null,
  p_pin jsonb default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $function$
declare v_uid uuid := public.huidige_gebruiker(); v_id uuid; v_namen text; v_vest text; v_klus uuid; v_van timestamptz;
        rc record; v_vv uuid; v_items text[]; v_tekst text; v_beo jsonb; v_kl jsonb; v_tz text;
        v_fruit boolean; v_handpin boolean; r jsonb; v_tid text; v_tids text[] := '{}';
        v_gasn int; v_aard int; v_ban int; v_nodig boolean;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only close your own stall.' using errcode='P0002';
  end if;
  select k.vestiging into v_vest from public.kramen k where k.id = p_kraam;
  v_tz := public.mkt_tz(v_vest);
  v_fruit := coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = v_vest and i.sleutel = 'vraag_fruit'),'nee') = 'ja';
  v_handpin := coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = v_vest and i.sleutel = 'pin_bron'),'mypos') = 'handmatig';
  if p_datum > (now() at time zone v_tz)::date then
    raise exception 'You can only close today or earlier.' using errcode='P0002';
  end if;
  if exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = p_kraam and a.datum = p_datum and a.afgesloten_op is not null) then
    raise exception 'This day is already closed.' using errcode='P0002';
  end if;
  if p_schoonmaak is null or p_gas is null or p_voorraad is null then
    raise exception 'Answer all three: cleaning list, gas and stock.' using errcode='P0002';
  end if;
  if not p_gas then
    raise exception 'Turn the gas off before you close the day.' using errcode='P0002';
  end if;
  v_gasn := nullif(greatest(coalesce(p_gas_flessen,0),0),0);
  v_aard := case when v_fruit then nullif(greatest(coalesce(p_aardbeien,0),0),0) end;
  v_ban  := case when v_fruit then nullif(greatest(coalesce(p_bananen,0),0),0) end;
  if coalesce(p_gas_flessen,0) < 0 or coalesce(p_aardbeien,0) < 0 or coalesce(p_bananen,0) < 0 then
    raise exception 'A number cannot be negative.' using errcode='P0002';
  end if;
  if greatest(coalesce(v_gasn,0), coalesce(v_aard,0), coalesce(v_ban,0)) > 99 then
    raise exception 'That number is too high. Check it again.' using errcode='P0002';
  end if;
  v_items := coalesce((select array_agg(x) from (select distinct left(btrim(x),40) x from unnest(coalesce(p_items,'{}')) x
                        where btrim(x) <> '' limit 30) y), '{}');
  v_tekst := nullif(left(btrim(coalesce(p_tekst,'')),300),'');
  if p_voorraad and coalesce(array_length(v_items,1),0) = 0 and v_tekst is null then
    raise exception 'Tell us which stock you need.' using errcode='P0002';
  end if;
  v_nodig := (p_voorraad and (coalesce(array_length(v_items,1),0) > 0 or v_tekst is not null))
             or v_gasn is not null or v_aard is not null or v_ban is not null;

  -- Pin per terminal (markten zonder myPOS-koppeling)
  if v_handpin then
    if jsonb_typeof(coalesce(p_pin,'null'::jsonb)) <> 'array'
       or not exists (select 1 from jsonb_array_elements(p_pin) e where nullif(btrim(coalesce(e->>'tid','')),'') is not null) then
      raise exception 'Fill in the card payment total of each terminal.' using errcode='P0002';
    end if;
    for r in select * from jsonb_array_elements(p_pin) loop
      v_tid := nullif(left(btrim(coalesce(r->>'tid','')),40),'');
      if v_tid is null then continue; end if;
      if v_tid = any(v_tids) then raise exception 'Terminal "%" is in the list twice.', v_tid using errcode='P0002'; end if;
      v_tids := v_tids || v_tid;
      if nullif(r->>'omzet','') is null then raise exception 'Fill in the total for terminal %.', v_tid using errcode='P0002'; end if;
      if (r->>'omzet')::numeric < 0 or coalesce(nullif(r->>'transacties','')::int,0) < 0 then
        raise exception 'A number cannot be negative.' using errcode='P0002';
      end if;
    end loop;
  end if;

  select string_agg(g.naam, ', ' order by g.naam) into v_namen
    from public.mcr_dagmensen(p_kraam, p_datum) m join public.gebruikers g on g.id = m.gebruiker_id
   where m.uren_id is not null and m.uitgeklokt_op is null;
  if v_namen is not null then
    raise exception 'Still clocked in: %. Fill in their finish time first.', v_namen using errcode='P0002';
  end if;
  select string_agg(g.naam, ', ' order by g.naam) into v_namen
    from public.mcr_dagmensen(p_kraam, p_datum) m join public.gebruikers g on g.id = m.gebruiker_id
   where not exists (select 1 from public.mcr_dagcontrole c where c.kraam_id = p_kraam and c.datum = p_datum and c.gebruiker_id = m.gebruiker_id);
  if v_namen is not null then
    raise exception 'Check the hours of % first.', v_namen using errcode='P0002';
  end if;
  select string_agg(g.naam, ', ' order by g.naam) into v_namen
    from public.mcr_dagmensen(p_kraam, p_datum) m join public.gebruikers g on g.id = m.gebruiker_id
   where g.beoordeling is null and not coalesce(g.kraammanager,false);
  if v_namen is not null then
    raise exception 'Give % a rating first.', v_namen using errcode='P0002';
  end if;

  select kl.id into v_klus from public.klussen kl where kl.kraam_id = p_kraam and kl.datum = p_datum;

  for rc in select dc.*, (select g.naam from public.gebruikers g where g.id = v_uid) mgr
             from public.mcr_dagcontrole dc
            where dc.kraam_id = p_kraam and dc.datum = p_datum and dc.voorval_id is null
              and dc.uitkomst in ('te_laat','niet_gekomen','afgemeld') loop
    insert into public.mcr_voorvallen (gebruiker_id, vestiging, datum, soort, klus_id, shift_id, notitie, boete, automatisch, aangemaakt_door)
    values (rc.gebruiker_id, v_vest, p_datum, rc.uitkomst, v_klus, rc.shift_id,
            case when rc.uitkomst = 'te_laat' then rc.minuten_te_laat || ' min te laat · ' else '' end
              || 'kraammanager ' || coalesce(rc.mgr, '?'),
            0, false, v_uid)
    returning id into v_vv;
    update public.mcr_dagcontrole set voorval_id = v_vv where id = rc.id;
  end loop;

  v_van := (p_datum::timestamp) at time zone v_tz;
  select coalesce(jsonb_agg(jsonb_build_object('naam', g.naam, 'van', w.van, 'naar', w.naar, 'reden', w.reden) order by w.op), '[]')
    into v_beo
    from public.mcr_wijzigingen w join public.gebruikers g on g.id = w.gebruiker_id
   where w.soort = 'beoordeling' and w.door = v_uid and w.op >= v_van
     and w.gebruiker_id in (select m.gebruiker_id from public.mcr_dagmensen(p_kraam, p_datum) m);
  select coalesce(jsonb_agg(jsonb_build_object('naam', g.naam, 'polo', l.polo_naar, 'schort', l.schort_naar,
                                               'polo_van', l.polo_van, 'schort_van', l.schort_van) order by l.op), '[]')
    into v_kl
    from public.mcr_kleding_log l join public.gebruikers g on g.id = l.gebruiker_id
   where l.door = v_uid and l.op >= v_van
     and l.gebruiker_id in (select m.gebruiker_id from public.mcr_dagmensen(p_kraam, p_datum) m);

  if v_handpin then perform public._pin_dag_schrijven(p_kraam, p_datum, p_pin); end if;

  insert into public.mcr_dagafsluiting (vestiging, kraam_id, datum, schoonmaak, gas, voorraad_nodig, voorraad, voorraad_tekst,
                                        gas_flessen, aardbeien, bananen, beoordelingen, kleding, afgesloten_door, afgesloten_op)
  values (v_vest, p_kraam, p_datum, p_schoonmaak, p_gas, v_nodig,
          case when p_voorraad then v_items else '{}' end, case when p_voorraad then v_tekst end,
          v_gasn, v_aard, v_ban, v_beo, v_kl, v_uid, now())
  on conflict (kraam_id, datum) do update
     set schoonmaak = excluded.schoonmaak, gas = excluded.gas, voorraad_nodig = excluded.voorraad_nodig,
         voorraad = excluded.voorraad, voorraad_tekst = excluded.voorraad_tekst,
         gas_flessen = excluded.gas_flessen, aardbeien = excluded.aardbeien, bananen = excluded.bananen,
         geregeld_op = null, geregeld_door = null,
         beoordelingen = public.mcr_dagafsluiting.beoordelingen || excluded.beoordelingen,
         kleding = public.mcr_dagafsluiting.kleding || excluded.kleding,
         afgesloten_door = excluded.afgesloten_door, afgesloten_op = excluded.afgesloten_op
  returning id into v_id;

  perform public.mcr_dag_dicht_melden(v_id);
  return v_id;
end $function$;
alter function public.mgr_dag_afsluiten(uuid,date,boolean,boolean,boolean,text[],text,integer,integer,integer,jsonb) owner to app_rpc;
revoke all on function public.mgr_dag_afsluiten(uuid,date,boolean,boolean,boolean,text[],text,integer,integer,integer,jsonb) from public, anon;
grant execute on function public.mgr_dag_afsluiten(uuid,date,boolean,boolean,boolean,text[],text,integer,integer,integer,jsonb) to authenticated;

-- Wat er nodig is, als één regel (nl / en)
create or replace function public.voorraad_regel(a public.mcr_dagafsluiting, p_taal text)
returns text language sql stable set search_path to 'public' as $$
  select nullif(array_to_string(array_remove(
           a.voorraad
           || case when a.gas_flessen > 0 then a.gas_flessen || case when p_taal = 'nl' then ' gasfles' || case when a.gas_flessen > 1 then 'sen' else '' end
                                                               else ' gas bottle' || case when a.gas_flessen > 1 then 's' else '' end end end
           || case when a.aardbeien > 0 then a.aardbeien || case when p_taal = 'nl' then case when a.aardbeien > 1 then ' dozen' else ' doos' end || ' aardbeien' else ' box' || case when a.aardbeien > 1 then 'es' else '' end || ' of strawberries' end end
           || case when a.bananen > 0 then a.bananen || case when p_taal = 'nl' then case when a.bananen > 1 then ' dozen' else ' doos' end || ' bananen' else ' box' || case when a.bananen > 1 then 'es' else '' end || ' of bananas' end end
           || nullif(a.voorraad_tekst,''), null), ', '), '')
$$;

-- Melding aan Bram en de planner van die markt, in hun eigen taal
create or replace function public.mcr_dag_dicht_melden(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare r record; a public.mcr_dagafsluiting;
begin
  select * into a from public.mcr_dagafsluiting where id = p_id and afgesloten_op is not null;
  if not found then return; end if;
  select k.naam kraam, g.naam door, kl.id klus_id into r
    from public.kramen k
    left join public.gebruikers g on g.id = a.afgesloten_door
    left join public.klussen kl on kl.kraam_id = a.kraam_id and kl.datum = a.datum
   where k.id = a.kraam_id;
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
  select b.id, 'mcr_dag_dicht', r.klus_id,
         r.kraam || coalesce(' (' || r.door || ')','')
         || case when a.voorraad_nodig then case when t.tl = 'nl' then ' · voorraad: ' else ' · stock: ' end
                                            || coalesce(public.voorraad_regel(a, t.tl),'') else '' end
         || case when not a.schoonmaak then case when t.tl = 'nl' then ' · schoonmaaklijst niet gedaan' else ' · cleaning list not done' end else '' end
    from public.gebruikers b
    cross join lateral (select coalesce(b.taal, (select v.taal from public.vestigingen v where v.code = b.vestiging), 'en') tl) t
   where b.gearchiveerd_op is null
     and ((b.rol = 'beheerder' and (coalesce(b.alle_vestigingen,false) or b.vestiging = a.vestiging))
          or (b.plant_vestiging = a.vestiging and coalesce(b.goedgekeurd,false)));
end $$;
revoke all on function public.mcr_dag_dicht_melden(uuid) from public, anon, authenticated;
grant execute on function public.mcr_dag_dicht_melden(uuid) to app_rpc, service_role;

-- Bij het afsluiten: wat de manager ziet
select public._fn_vervang('public.mgr_afsluiting(uuid,date)'::regprocedure,
  '''voorraad_nodig'', a.voorraad_nodig, ''voorraad'', a.voorraad, ''voorraad_tekst'', a.voorraad_tekst) end,',
  '''voorraad_nodig'', a.voorraad_nodig, ''voorraad'', a.voorraad, ''voorraad_tekst'', a.voorraad_tekst,
        ''gas_flessen'', a.gas_flessen, ''aardbeien'', a.aardbeien, ''bananen'', a.bananen,
        ''geregeld_op'', a.geregeld_op, ''geregeld_door'', (select gx.naam from public.gebruikers gx where gx.id = a.geregeld_door),
        ''notitie'', a.voorraad_notitie) end,
    ''vraag_fruit'', coalesce((select i.waarde from public.vestiging_instellingen i join public.kramen kx on kx.vestiging = i.vestiging
                               where kx.id = p_kraam and i.sleutel = ''vraag_fruit''),''nee'') = ''ja'',
    ''pin_handmatig'', coalesce((select i.waarde from public.vestiging_instellingen i join public.kramen kx on kx.vestiging = i.vestiging
                               where kx.id = p_kraam and i.sleutel = ''pin_bron''),''mypos'') = ''handmatig'',
    ''terminals'', to_jsonb(public.kraam_terminals(p_kraam)),
    ''valuta'', (select v.valuta from public.vestigingen v join public.kramen kx on kx.vestiging = v.code where kx.id = p_kraam),');

-- Overzicht dagafsluiting (Bram / planner)
select public._fn_vervang('public.mcr_afsluitingen(date)'::regprocedure,
  '''voorraad_nodig'', a.voorraad_nodig, ''voorraad'', a.voorraad, ''voorraad_tekst'', a.voorraad_tekst,',
  '''voorraad_nodig'', a.voorraad_nodig, ''voorraad'', a.voorraad, ''voorraad_tekst'', a.voorraad_tekst,
          ''gas_flessen'', a.gas_flessen, ''aardbeien'', a.aardbeien, ''bananen'', a.bananen, ''geregeld_op'', a.geregeld_op,');

create or replace function public.voorraad_json(a public.mcr_dagafsluiting)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('id', a.id, 'datum', a.datum, 'kraam_id', a.kraam_id,
    'kraam', k.naam, 'kleur', coalesce(k.kleur,'#6B6A66'),
    'afgesloten_op', a.afgesloten_op, 'door', d.naam,
    'voorraad', a.voorraad, 'tekst', a.voorraad_tekst,
    'gas_flessen', a.gas_flessen, 'aardbeien', a.aardbeien, 'bananen', a.bananen,
    'notitie', a.voorraad_notitie, 'geregeld_op', a.geregeld_op, 'geregeld_door', gd.naam)
    from public.kramen k
    left join public.gebruikers d on d.id = a.afgesloten_door
    left join public.gebruikers gd on gd.id = a.geregeld_door
   where k.id = a.kraam_id
$$;
revoke all on function public.voorraad_json(public.mcr_dagafsluiting) from public, anon, authenticated;
grant execute on function public.voorraad_json(public.mcr_dagafsluiting) to app_rpc, service_role;

-- Voorraad: alles wat nog open staat, ongeacht de datum, en wat de laatste 7 dagen geregeld is
create or replace function public.mcr_voorraad_lijst()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.mag_planbeheer() then '{"open":[],"klaar":[]}'::jsonb else jsonb_build_object(
    'open', coalesce((select jsonb_agg(public.voorraad_json(a) order by a.datum, k.volgorde, k.naam)
               from public.mcr_dagafsluiting a join public.kramen k on k.id = a.kraam_id
              where a.voorraad_nodig and a.afgesloten_op is not null and a.geregeld_op is null
                and a.datum >= current_date - 30
                and public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging)), '[]'::jsonb),
    'klaar', coalesce((select jsonb_agg(public.voorraad_json(a) order by a.geregeld_op desc)
               from public.mcr_dagafsluiting a
              where a.voorraad_nodig and a.geregeld_op >= now() - interval '7 days'
                and public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging)), '[]'::jsonb)) end
$$;
revoke all on function public.mcr_voorraad_lijst() from public, anon;
grant execute on function public.mcr_voorraad_lijst() to authenticated;

create or replace function public.mcr_voorraad_zetten(p_id uuid, p_geregeld boolean, p_notitie text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_vest text;
begin
  select a.vestiging into v_vest from public.mcr_dagafsluiting a where a.id = p_id;
  if v_vest is null or not public.mag_planbeheer() or not public.vest_ok(v_vest) or not public.in_actieve_vestiging(v_vest) then
    raise exception 'Je kunt deze aanvraag niet wijzigen.' using errcode='P0002';
  end if;
  update public.mcr_dagafsluiting
     set geregeld_op   = case when p_geregeld is null then geregeld_op when p_geregeld then now() else null end,
         geregeld_door = case when p_geregeld is null then geregeld_door when p_geregeld then public.huidige_gebruiker() else null end,
         voorraad_notitie = case when p_notitie is null then voorraad_notitie else nullif(left(btrim(p_notitie),300),'') end,
         notitie_op = case when p_notitie is null then notitie_op else now() end
   where id = p_id;
end $$;
revoke all on function public.mcr_voorraad_zetten(uuid,boolean,text) from public, anon;
grant execute on function public.mcr_voorraad_zetten(uuid,boolean,text) to authenticated;

-- Kraammanager: zijn eigen aanvragen van de laatste 7 dagen, met de status
create or replace function public.mgr_voorraad_status()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(public.voorraad_json(a) order by a.datum desc), '[]'::jsonb)
    from public.mcr_dagafsluiting a
   where a.voorraad_nodig and a.afgesloten_op is not null and a.datum >= current_date - 7
     and public.mgr_kraam_ok(a.kraam_id)
$$;
revoke all on function public.mgr_voorraad_status() from public, anon;
grant execute on function public.mgr_voorraad_status() to authenticated;

-- 's Ochtends om 09:00 één melding als er nog voorraad open staat
create or replace function public.mcr_voorraad_ochtend()
returns integer
language plpgsql security definer set search_path to 'public'
as $$
declare n int;
begin
  insert into public.push_wachtrij (gebruiker_id, soort, regel)
  select b.id, 'mcr_voorraad',
         string_agg(k.naam || ': ' || coalesce(public.voorraad_regel(a, t.tl),''), E'\n' order by k.volgorde, k.naam, a.datum)
    from public.mcr_dagafsluiting a
    join public.kramen k on k.id = a.kraam_id
    join public.gebruikers b on b.gearchiveerd_op is null and b.push_token is not null
         and ((b.rol = 'beheerder' and (coalesce(b.alle_vestigingen,false) or b.vestiging = a.vestiging))
              or (b.plant_vestiging = a.vestiging and coalesce(b.goedgekeurd,false)))
    cross join lateral (select coalesce(b.taal, (select v.taal from public.vestigingen v where v.code = b.vestiging), 'en') tl) t
   where a.voorraad_nodig and a.afgesloten_op is not null and a.geregeld_op is null and a.datum >= current_date - 30
     and not exists (select 1 from public.push_wachtrij w where w.soort = 'mcr_voorraad' and w.gebruiker_id = b.id
                       and w.aangemaakt_op > now() - interval '12 hours')
   group by b.id;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mcr_voorraad_ochtend() from public, anon, authenticated;
select cron.schedule('mcr-voorraad-ochtend', '0 9 * * *', 'select public.mcr_voorraad_ochtend();');
