-- Manchester: proefdiensten en verplichte beoordeling
--
-- 1. Iemand zonder beoordeling kan op maximaal 2 Manchester-diensten staan.
--    Dat wordt bewaakt in de database (trigger op klus_gebruikers), dus het
--    geldt voor elke manier van indelen: los, in bulk, via een ruil.
-- 2. Het planbord krijgt per persoon het totaal aantal Manchester-diensten
--    (mcr_totaal), zodat de app de grens al vooraf kan tonen.
-- 3. mcr_dag_te_beoordelen geeft voor een kraam en dag wie daar werkte en nog
--    geen beoordeling heeft. Het dagrapport vraagt die beoordeling en
--    mcr_dagrapport_opslaan weigert op te slaan zolang die ontbreekt.

-- ── 1. Grens bij indelen ──────────────────────────────────────────
create or replace function public.mcr_proef_bewaken()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare g record; v_n int;
begin
  if new.shift_id is null then return new; end if;
  if not exists (select 1 from public.klussen where id = new.klus_id and kraam_id is not null) then
    return new;
  end if;
  select naam, beoordeling into g from public.gebruikers where id = new.gebruiker_id;
  if not found or g.beoordeling is not null then return new; end if;
  if tg_op = 'UPDATE' and new.shift_id is not distinct from old.shift_id then return new; end if;
  -- staat al op deze dienst: niets nieuws
  if exists (select 1 from public.klus_gebruikers kg
              where kg.gebruiker_id = new.gebruiker_id and kg.shift_id = new.shift_id) then
    return new;
  end if;
  -- bij een wijziging telt de oude dienst van deze rij niet mee
  select count(*)::int into v_n
    from public.klus_gebruikers kg
    join public.klussen kl on kl.id = kg.klus_id
   where kg.gebruiker_id = new.gebruiker_id
     and kg.shift_id is not null
     and kl.kraam_id is not null
     and not (tg_op = 'UPDATE' and kg.shift_id = old.shift_id and kg.klus_id = old.klus_id);
  if v_n >= 2 then
    raise exception '% heeft nog geen beoordeling en staat al op 2 diensten. Geef % eerst een beoordeling (dat vraagt het dagrapport na de eerste dienst).',
      coalesce(g.naam,'Deze persoon'), split_part(coalesce(g.naam,'diegene'),' ',1)
      using errcode = 'check_violation';
  end if;
  return new;
end $function$;
alter function public.mcr_proef_bewaken() owner to postgres;
revoke all on function public.mcr_proef_bewaken() from public, anon, authenticated;

drop trigger if exists ac_mcr_proef_bewaken on public.klus_gebruikers;
create trigger ac_mcr_proef_bewaken
  before insert or update of shift_id on public.klus_gebruikers
  for each row execute function public.mcr_proef_bewaken();

-- ── 3. Wie moet er vandaag beoordeeld worden ──────────────────────
create or replace function public.mcr_dag_te_beoordelen(p_kraam uuid, p_datum date)
returns table(id uuid, naam text, diensten integer, tijden text)
language sql stable security definer
set search_path to 'public'
as $function$
  select g.id, g.naam,
         (select count(*)::int from public.klus_gebruikers k2 join public.klussen l2 on l2.id = k2.klus_id
           where k2.gebruiker_id = g.id and k2.shift_id is not null and l2.kraam_id is not null) as diensten,
         string_agg(distinct to_char(s.start_tijd,'HH24:MI') || '–' || coalesce(to_char(s.eind_tijd,'HH24:MI'),'sluit'), ', ') as tijden
    from public.klus_gebruikers kg
    join public.klussen kl on kl.id = kg.klus_id
    join public.klus_shifts s on s.id = kg.shift_id
    join public.gebruikers g on g.id = kg.gebruiker_id
   where public.mag_kraambeheer()
     and kl.kraam_id = p_kraam and kl.datum = p_datum
     and p_datum <= current_date
     and g.beoordeling is null
     and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
   group by g.id, g.naam
   order by g.naam
$function$;
alter function public.mcr_dag_te_beoordelen(uuid, date) owner to postgres;
revoke all on function public.mcr_dag_te_beoordelen(uuid, date) from public, anon;
grant execute on function public.mcr_dag_te_beoordelen(uuid, date) to authenticated, service_role;

-- Dagrapport: niet opslaan zolang er iemand zonder beoordeling werkte.
create or replace function public.mcr_dagrapport_opslaan(p_kraam uuid, p_datum date, p_forecast numeric, p_contant numeric, p_weer text, p_temp numeric, p_neerslag numeric, p_wachtrij text, p_incident text, p_event text, p_voorraad text, p_opmerking text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_namen text;
begin
  if not public.is_beheerder() then raise exception 'alleen een beheerder'; end if;
  select string_agg(t.naam, ', ') into v_namen from public.mcr_dag_te_beoordelen(p_kraam, p_datum) t;
  if v_namen is not null then
    raise exception 'Geef eerst een beoordeling aan: %.', v_namen using errcode='P0002';
  end if;
  insert into public.dagrapporten (kraam_id, datum, forecast, omzet_contant, weer, temperatuur,
                                   neerslag_mm, wachtrij_piek, incident, event_stad, voorraad_op,
                                   opmerking, bijgewerkt_door)
  values (p_kraam, p_datum, p_forecast, p_contant,
          nullif(public.schoon_kort(p_weer),''), p_temp, p_neerslag,
          nullif(public.schoon_kort(p_wachtrij),''), nullif(public.schoon_kort(p_incident),''),
          nullif(public.schoon_kort(p_event),''), nullif(public.schoon_kort(p_voorraad),''),
          nullif(public.schoon_kort(p_opmerking),''), public.huidige_gebruiker())
  on conflict (kraam_id, datum) do update set
    forecast = excluded.forecast, omzet_contant = excluded.omzet_contant,
    weer = excluded.weer, temperatuur = excluded.temperatuur, neerslag_mm = excluded.neerslag_mm,
    wachtrij_piek = excluded.wachtrij_piek, incident = excluded.incident,
    event_stad = excluded.event_stad, voorraad_op = excluded.voorraad_op,
    opmerking = excluded.opmerking, bijgewerkt_op = now(),
    bijgewerkt_door = excluded.bijgewerkt_door;
end $function$;

-- ── 2. Planbord: totaal aantal Manchester-diensten per persoon ───────
create or replace function public.mcr_planbord(p_van date)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $function$
declare v_tot date := p_van + 6; v jsonb;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan plannen.' using errcode='P0002';
  end if;
  with k as (
    select k.* from public.kramen k
     where k.actief and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
  ), sh as (
    select s.id, s.naam, s.start_tijd, s.eind_tijd, s.personeel_nodig, kl.id klus_id, kl.datum, kl.kraam_id,
           coalesce(s.eind_tijd, public.kraam_eindtijd(kl.kraam_id, kl.datum), '23:59'::time) eind_echt
      from public.klus_shifts s
      join public.klussen kl on kl.id = s.klus_id
     where kl.kraam_id in (select id from k)
       and kl.datum between p_van and v_tot
  ), inn as (
    select kg.shift_id, kg.gebruiker_id from public.klus_gebruikers kg where kg.shift_id in (select id from sh)
  ), aanv as (
    select a.id, a.shift_id, a.gebruiker_id, a.notitie, a.aangemaakt_op
      from public.klus_aanmeldingen a
     where a.shift_id in (select id from sh) and a.status = 'aangemeld'
  ), ruil as (
    select x.shift_id, x.gebruiker_id, x.status from public.mcr_shift_ruil x
     where x.shift_id in (select id from sh) and x.status in ('open','gevraagd')
  ), m as (
    select g.id, g.naam, g.beoordeling, g.werkt_sinds, g.max_dagen_per_week, g.vroegste_start, g.eigen_opmerking,
           (select count(*)::int from public.klus_gebruikers k2 join public.klussen l2 on l2.id = k2.klus_id
             where k2.gebruiker_id = g.id and k2.shift_id is not null and l2.kraam_id is not null) as mcr_totaal,
           (coalesce(g.goedgekeurd,false) and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
             and g.gearchiveerd_op is null) as kan
      from public.gebruikers g
     where public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
       and ((coalesce(g.goedgekeurd,false) and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
              and g.gearchiveerd_op is null)
            or g.id in (select gebruiker_id from inn) or g.id in (select gebruiker_id from aanv))
  )
  select jsonb_build_object(
    'van', p_van, 'tot', v_tot,
    'aanmelden_tot', public.mcr_aanmelden_tot(),
    'kramen', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'naam', k.naam,
                 'kleur', coalesce(k.kleur,'#6B6A66'), 'code', k.code) order by k.volgorde, k.naam) from k), '[]'::jsonb),
    'dagen', coalesce((select jsonb_agg(jsonb_build_object(
                 'kraam', k.id, 'datum', d::date,
                 'dicht', coalesce(u.dicht,false) or d::date < k.seizoen_start or d::date > k.seizoen_eind,
                 'open', coalesce(u.open_van, k.open_van), 'sluit', coalesce(u.open_tot, k.open_tot)))
               from k cross join generate_series(p_van, v_tot, interval '1 day') d
               left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d::date), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', sh.id, 'klus', sh.klus_id, 'kraam', sh.kraam_id, 'datum', sh.datum, 'naam', sh.naam,
                 'start', sh.start_tijd, 'eind', sh.eind_tijd, 'eind_echt', sh.eind_echt, 'nodig', sh.personeel_nodig,
                 'inn', coalesce((select jsonb_agg(inn.gebruiker_id) from inn where inn.shift_id = sh.id), '[]'::jsonb),
                 'aanv', coalesce((select jsonb_agg(jsonb_build_object('id', aanv.id, 'g', aanv.gebruiker_id,
                            'notitie', aanv.notitie, 'op', aanv.aangemaakt_op) order by aanv.aangemaakt_op)
                          from aanv where aanv.shift_id = sh.id), '[]'::jsonb),
                 'ruil', coalesce((select jsonb_agg(jsonb_build_object('g', ruil.gebruiker_id, 'status', ruil.status))
                          from ruil where ruil.shift_id = sh.id), '[]'::jsonb))
               order by sh.datum, sh.start_tijd) from sh), '[]'::jsonb),
    'mensen', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', m.id, 'naam', m.naam, 'oordeel', m.beoordeling, 'sinds', m.werkt_sinds,
                 'max_dagen', m.max_dagen_per_week, 'vroegst', m.vroegste_start,
                 'opmerking', m.eigen_opmerking, 'kan', m.kan, 'totaal', m.mcr_totaal) order by m.naam) from m), '[]'::jsonb),
    'besch', coalesce((select jsonb_agg(jsonb_build_object(
                 'g', b.gebruiker_id, 'van', b.datum_start, 'tot', coalesce(b.datum_eind, b.datum_start),
                 'soort', b.soort, 'ts', b.tijd_start, 'te', b.tijd_eind))
               from public.beschikbaarheid b
              where b.gebruiker_id in (select id from m)
                and b.datum_start <= v_tot and coalesce(b.datum_eind, b.datum_start) >= p_van
                and coalesce(b.status,'goedgekeurd') <> 'afgewezen'), '[]'::jsonb)
  ) into v;
  return v;
end $function$;
alter function public.mcr_planbord(date) owner to postgres;
revoke all on function public.mcr_planbord(date) from public, anon;
grant execute on function public.mcr_planbord(date) to authenticated, service_role;
