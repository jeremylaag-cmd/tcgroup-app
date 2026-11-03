-- Manchester: huisregels 2026.3, huisregels voor Bram, en details van een shift (3 nov 2026)
--
-- Bram: "al het personeel moet de eerst volgende keer dat ze inloggen de huis
-- regels nog 1x voor hun zien en hier moeten ze weer akkoord op geven."
-- Nieuw: drankjes £0,50 per drankje; geen gratis pancakes voor vrienden, familie
-- of andere markthandelaren (alleen de stall manager mag dat). Daarnaast de
-- kledingborg gelijkgetrokken met de app: iedereen krijgt een polo én een schort,
-- £25 per stuk (£50 samen).
-- "ik zelf kan ze volgens mij niet snel erbij pakken" → mcr_huisregels_overzicht.
-- "mensen wat meer info wanneer ze op een shift worden gezet" → mcr_shift_info.
--
-- Geen enkele regel in dit bestand gebruikt het woord voor weghalen of het
-- weghalen van objecten; de database-tool annuleert zulke migraties.

-- ── Huisregels 2026.3 ─────────────────────────────────────────────
do $hr$
declare v_oud text; v_nieuw text; v_titel text;
begin
  if exists (select 1 from public.huisregels where vestiging = 'MCR' and taal = 'en' and versie = '2026.3') then
    return;
  end if;
  select tekst, titel into v_oud, v_titel from public.huisregels where vestiging = 'MCR' and taal = 'en' and versie = '2026.2';
  if v_oud is null then raise exception 'Versie 2026.2 niet gevonden'; end if;
  v_nieuw := replace(v_oud,
    '- Customer friendliness: if a discussion arises, refer the customer to the stand manager.',
    '- Customer friendliness: if a discussion arises, refer the customer to the stand manager.' || E'\n'
    || '- All drinks need to be paid for: £0.50 for every drink.' || E'\n'
    || '- We don''t give out free pancakes to friends, family or other market traders. Only the stall manager can do this.');
  if v_nieuw = v_oud then raise exception 'Regel over klantvriendelijkheid niet gevonden'; end if;
  v_oud := v_nieuw;
  v_nieuw := replace(v_oud,
    '- £30 will be withheld from your first pay as a deposit for your clothing.' || E'\n'
    || '- Want 2 pieces of clothing? This will cost you another £30 extra.',
    '- You get a long sleeve polo and an apron. £25 per piece (£50 in total) will be withheld from your pay as a deposit.');
  if v_nieuw = v_oud then raise exception 'Regels over de kledingborg niet gevonden'; end if;

  update public.huisregels set actief = false where vestiging = 'MCR' and taal = 'en' and actief;
  insert into public.huisregels (vestiging, taal, versie, titel, tekst, actief)
  values ('MCR', 'en', '2026.3', v_titel, v_nieuw, true);
end $hr$;

-- ── Bram: de huisregels en wie er akkoord op gaf ──────────────────
create or replace function public.mcr_huisregels_overzicht()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare h record; v jsonb;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  select x.* into h from public.huisregels x
   where x.vestiging = 'MCR' and x.taal = 'en' and x.actief
   order by x.aangemaakt_op desc limit 1;
  select jsonb_build_object(
    'id', h.id, 'versie', h.versie, 'titel', h.titel, 'tekst', h.tekst, 'sinds', h.aangemaakt_op,
    'versies', (select coalesce(jsonb_agg(jsonb_build_object('versie', o.versie, 'sinds', o.aangemaakt_op, 'actief', o.actief) order by o.aangemaakt_op desc), '[]')
                  from public.huisregels o where o.vestiging = 'MCR' and o.taal = 'en'),
    'mensen', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', g.id, 'naam', g.naam, 'goedgekeurd', coalesce(g.goedgekeurd,false),
                  'kraammanager', coalesce(g.kraammanager,false),
                  'akkoord_op', (select max(a.op) from public.huisregels_akkoord a where a.gebruiker_id = g.id and a.huisregels_id = h.id),
                  'eerder', (select o.versie from public.huisregels_akkoord a join public.huisregels o on o.id = a.huisregels_id
                              where a.gebruiker_id = g.id and a.huisregels_id <> h.id order by a.op desc limit 1)
                ) order by g.naam), '[]')
                 from public.gebruikers g
                where g.vestiging = 'MCR' and g.rol <> 'beheerder' and g.gearchiveerd_op is null)
  ) into v;
  return v;
end $$;
revoke all on function public.mcr_huisregels_overzicht() from public, anon;
grant execute on function public.mcr_huisregels_overzicht() to authenticated, service_role;

-- ── Kramen: adres zichtbaar voor het personeel ────────────────────
-- mcr_kraam_opslaan maakte het adres leeg als de app niets meestuurde; nu
-- blijft het staan tenzij er echt een (lege) waarde komt.
update public.kramen set adres = naam || ', Manchester'
 where vestiging = 'MCR' and nullif(btrim(coalesce(adres,'')),'') is null;

create or replace function public.mcr_kraam_opslaan(p_id uuid, p_naam text, p_adres text, p_start date, p_eind date, p_open_van time without time zone, p_open_tot time without time zone)
 returns void
 language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public.is_beheerder() then raise exception 'alleen een beheerder'; end if;
  update public.kramen
     set naam = coalesce(nullif(public.schoon_kort(p_naam),''), naam),
         adres = case when p_adres is null then adres else nullif(public.schoon_kort(p_adres),'') end,
         seizoen_start = coalesce(p_start, seizoen_start),
         seizoen_eind  = coalesce(p_eind,  seizoen_eind),
         open_van = coalesce(p_open_van, open_van),
         open_tot = coalesce(p_open_tot, open_tot)
   where id = p_id and public.vest_ok(vestiging);
end $function$;

-- ── Personeel: alles over één eigen shift ─────────────────────────
-- Alleen voor wie op die shift staat. Bram: geen collega's tonen, alleen de manager.
create or replace function public.mcr_shift_info(p_shift uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker(); s record; v jsonb;
  inst jsonb;
begin
  if not public.mag_werken() then
    raise exception 'You are not signed in.' using errcode='P0002';
  end if;
  select sh.id, sh.naam as shift_naam, kl.id as klus_id, kl.datum, k.id as kraam_id, k.naam as kraam, coalesce(k.kleur,'#6B6A66') as kleur,
         k.adres, k.vestiging,
         coalesce(sh.start_tijd, kl.start_tijd) as start_tijd,
         coalesce(sh.eind_tijd, (coalesce(u.open_tot, k.open_tot) + make_interval(mins => coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric
            from public.vestiging_instellingen i where i.vestiging = k.vestiging and i.sleutel = 'opruimtijd_minuten'), 0)::int))::time) as eind_tijd,
         sh.eind_tijd is null as tot_sluit,
         coalesce(u.open_van, k.open_van) as open_van, coalesce(u.open_tot, k.open_tot) as open_tot,
         coalesce(u.dicht,false) as dicht
    into s
    from public.klus_gebruikers kg
    join public.klus_shifts sh on sh.id = kg.shift_id
    join public.klussen kl on kl.id = kg.klus_id
    join public.kramen k on k.id = kl.kraam_id
    left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = kl.datum
   where kg.shift_id = p_shift and kg.gebruiker_id = v_uid;
  if not found then
    raise exception 'You are not on this shift.' using errcode='P0002';
  end if;
  select coalesce(jsonb_object_agg(i.sleutel, i.waarde), '{}') into inst
    from public.vestiging_instellingen i
   where i.vestiging = s.vestiging
     and i.sleutel in ('pauze_drempel_uren','pauze_minuten','inklok_venster_min','noodnummer_1','noodnummer_2','afzegtermijn_uren');
  select jsonb_build_object(
    'shift_id', s.id, 'shift_naam', s.shift_naam, 'datum', s.datum, 'kraam', s.kraam, 'kleur', s.kleur, 'adres', s.adres,
    'start', s.start_tijd, 'eind', s.eind_tijd, 'tot_sluit', s.tot_sluit,
    'open_van', s.open_van, 'open_tot', s.open_tot, 'dicht', s.dicht,
    'instellingen', inst,
    'managers', coalesce((
      select jsonb_agg(x.j order by x.o) from (
        select 1 as o, jsonb_build_object('soort','manager','naam', g.naam, 'telefoon', g.telefoon) j
          from public.mcr_manager_week mw join public.gebruikers g on g.id = mw.gebruiker_id
         where mw.kraam_id = s.kraam_id and mw.week_start = date_trunc('week', s.datum)::date
           and g.kraammanager and g.gearchiveerd_op is null
        union all
        select 2, jsonb_build_object('soort','weekend','naam', w.naam, 'telefoon', w.telefoon)
          from public.mcr_manager_dag md join public.mcr_weekendmanagers w on w.id = md.weekendmanager_id
         where md.kraam_id = s.kraam_id and md.datum = s.datum) x), '[]'::jsonb),
    'kleding', (select jsonb_build_object('polo', g.kleding_polo, 'schort', g.kleding_schort, 'maat', g.shirtmaat)
                  from public.gebruikers g where g.id = v_uid),
    'klok', (select jsonb_build_object('in', ur.ingeklokt_op, 'uit', ur.uitgeklokt_op, 'pauze', ur.pauze_minuten, 'status', ur.status)
               from public.urenregistraties ur where ur.klus_id = s.klus_id and ur.gebruiker_id = v_uid
              order by ur.ingeklokt_op limit 1)
  ) into v;
  return v;
end $$;
alter function public.mcr_shift_info(uuid) owner to app_rpc;
revoke all on function public.mcr_shift_info(uuid) from public, anon;
grant execute on function public.mcr_shift_info(uuid) to authenticated, service_role;

-- ── Agenda: gegevens voor het agenda-bestand (.ics) ───────────────
-- Alleen voor de edge-functie mcr-agenda (service_role). Die krijgt de shift en
-- de gebruiker in de link; beide zijn lange willekeurige id's, en de functie
-- geeft alleen iets terug als die persoon echt op die shift staat.
create or replace function public.mcr_ics_data(p_shift uuid, p_gebruiker uuid)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  -- Eindtijd hier zelf uitgerekend (sluiting die dag + opruimtijd): kraam_eindtijd
  -- geeft zonder ingelogde gebruiker niets terug, en deze functie draait zonder.
  select jsonb_build_object(
    'shift_id', sh.id, 'datum', kl.datum, 'kraam', k.naam, 'adres', coalesce(k.adres, k.naam || ', Manchester'),
    'start', to_char(sh.start_tijd,'HH24:MI'),
    'eind', to_char(e.eind,'HH24:MI'),
    'tot_sluit', sh.eind_tijd is null,
    'start_utc', to_char(((kl.datum + sh.start_tijd) at time zone 'Europe/London') at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
    'eind_utc', to_char((((kl.datum + e.eind) + case when e.eind <= sh.start_tijd then interval '1 day' else interval '0' end)
                          at time zone 'Europe/London') at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
    'managers', (select string_agg(x.t, ', ' order by x.o) from (
        select 1 o, g.naam || coalesce(' ' || g.telefoon, '') t
          from public.mcr_manager_week mw join public.gebruikers g on g.id = mw.gebruiker_id
         where mw.kraam_id = k.id and mw.week_start = date_trunc('week', kl.datum)::date and g.kraammanager and g.gearchiveerd_op is null
        union all
        select 2, w.naam || coalesce(' ' || w.telefoon, '') || ' (weekend)'
          from public.mcr_manager_dag md join public.mcr_weekendmanagers w on w.id = md.weekendmanager_id
         where md.kraam_id = k.id and md.datum = kl.datum) x))
    from public.klus_gebruikers kg
    join public.klus_shifts sh on sh.id = kg.shift_id
    join public.klussen kl on kl.id = kg.klus_id
    join public.kramen k on k.id = kl.kraam_id
    left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = kl.datum
    cross join lateral (select coalesce(sh.eind_tijd,
        (coalesce(u.open_tot, k.open_tot) + make_interval(mins => coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric
            from public.vestiging_instellingen i where i.vestiging = k.vestiging and i.sleutel = 'opruimtijd_minuten'), 0)::int))::time) as eind) e
   where kg.shift_id = p_shift and kg.gebruiker_id = p_gebruiker
$$;
revoke all on function public.mcr_ics_data(uuid,uuid) from public, anon, authenticated;
grant execute on function public.mcr_ics_data(uuid,uuid) to service_role;

-- ── Meldingen: de avond ervoor + melding opent de shift ───────────
-- * mcr_morgen: vanaf 19:00 Engelse tijd één melding per shift van morgen, met
--   tijden, kraam en manager. Vervalt na middernacht of als je eraf bent.
-- * mcr_erop en mcr_morgen met één shift openen bij aantikken die shift
--   (pagina 'mcr-shift:<id>'); bij meer shifts de lijst.
CREATE OR REPLACE FUNCTION public.push_wachtrij_bundels()
 RETURNS TABLE(gebruiker_id uuid, push_token text, push_platform text, ids bigint[], soort text, titel text, bericht text, pagina text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_nu timestamp := (now() at time zone 'Europe/London');
        v_uur int := extract(hour from (now() at time zone 'Europe/London'))::int;
begin
  with dag as (
    select kl.id as klus_id, k.id as kid, k.naam, k.vestiging, kl.datum
      from public.kramen k
      join public.klussen kl on kl.kraam_id = k.id and kl.datum = v_nu::date
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = kl.datum
     where k.actief and not coalesce(u.dicht,false)
       and kl.datum between k.seizoen_start and k.seizoen_eind
       and coalesce(u.open_tot,k.open_tot) > coalesce(u.open_van,k.open_van)
       and coalesce(u.open_tot,k.open_tot) < time '23:15'
       and v_nu::time >= coalesce(u.open_tot,k.open_tot) + interval '45 minutes'
       and exists (select 1 from public.klus_shifts s join public.klus_gebruikers kg on kg.shift_id = s.id where s.klus_id = kl.id)
       and not exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = k.id and a.datum = kl.datum and a.afgesloten_op is not null)
  ), ontv as (
    select d.klus_id, x.gid, 'mcr_dag_open'::text as sr, d.naam || ' isn''t closed yet. Go through Close day before you leave.' as rg
      from dag d cross join lateral (select public.mcr_afsluiters(d.kid, d.datum) as gid) x
    union all
    select d.klus_id, b.id, 'mcr_dag_open_b', d.naam || ' is nog niet afgesloten.'
      from dag d join public.gebruikers b on b.rol = 'beheerder' and b.gearchiveerd_op is null
                  and (coalesce(b.alle_vestigingen,false) or b.vestiging = d.vestiging)
  )
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
  select o.gid, o.sr, o.klus_id, o.rg from ontv o
   where o.gid is not null
     and not exists (select 1 from public.push_wachtrij w where w.soort = o.sr and w.klus_id = o.klus_id and w.gebruiker_id = o.gid);

  -- De avond ervoor (vanaf 19:00): je shift(s) van morgen.
  if v_nu::time >= time '19:00' then
    insert into public.push_wachtrij (gebruiker_id, soort, klus_id, shift_id, regel)
    select kg.gebruiker_id, 'mcr_morgen', kl.id, sh.id,
           to_char(sh.start_tijd,'HH24:MI') || '–' || coalesce(to_char(sh.eind_tijd,'HH24:MI'),'close') || ' · ' || k.naam
           || coalesce(' · manager ' || (
                select string_agg(x.t, ', ' order by x.o) from (
                  select 1 o, g.naam || coalesce(' ' || g.telefoon,'') t
                    from public.mcr_manager_week mw join public.gebruikers g on g.id = mw.gebruiker_id
                   where mw.kraam_id = k.id and mw.week_start = date_trunc('week', kl.datum)::date
                     and g.kraammanager and g.gearchiveerd_op is null
                  union all
                  select 2, wm.naam || coalesce(' ' || wm.telefoon,'')
                    from public.mcr_manager_dag md join public.mcr_weekendmanagers wm on wm.id = md.weekendmanager_id
                   where md.kraam_id = k.id and md.datum = kl.datum) x), '')
      from public.klus_gebruikers kg
      join public.klus_shifts sh on sh.id = kg.shift_id
      join public.klussen kl on kl.id = kg.klus_id
      join public.kramen k on k.id = kl.kraam_id
      join public.gebruikers pg on pg.id = kg.gebruiker_id and pg.push_token is not null and pg.gearchiveerd_op is null
     where kl.datum = v_nu::date + 1
       and not exists (select 1 from public.push_wachtrij w where w.soort = 'mcr_morgen' and w.shift_id = sh.id and w.gebruiker_id = kg.gebruiker_id);
  end if;

  update public.push_wachtrij w set verwerkt_op = now(), uitslag = 'vervallen'
   where w.verwerkt_op is null and (
         w.regel is null
      or (w.soort = 'mcr_erop' and not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id))
      or (w.soort = 'mcr_eraf' and exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id))
      or (w.soort = 'mcr_eraf' and exists (select 1 from public.push_wachtrij e where e.soort = 'mcr_erop' and e.shift_id = w.shift_id
                                            and e.gebruiker_id = w.gebruiker_id and e.aangemaakt_op > now() - interval '1 day'
                                            and coalesce(e.uitslag,'') <> 'verstuurd' and e.id < w.id))
      or (w.soort = 'mcr_ruil_ok' and not exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.gebruiker_id = w.gebruiker_id and r.status = 'open'))
      or (w.soort = 'mcr_ruil_open' and (
             exists (select 1 from public.klus_gebruikers kg join public.klussen k2 on k2.id = kg.klus_id
                      where kg.gebruiker_id = w.gebruiker_id and k2.id = w.klus_id)
          or not ( (select count(*) from public.klus_gebruikers kg where kg.shift_id = w.shift_id)
                     < coalesce((select s.personeel_nodig from public.klus_shifts s where s.id = w.shift_id),0)
                   or exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.status = 'open'))))
      or (w.soort = 'mcr_ruil_gevraagd' and not exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.status = 'gevraagd'))
      or (w.soort = 'mcr_agenda_manager' and not exists (select 1 from public.mcr_agenda a where a.id = w.agenda_id))
      or (w.soort in ('mcr_dag_open','mcr_dag_open_b') and (
             w.aangemaakt_op < (v_nu::date::timestamp at time zone 'Europe/London')
          or exists (select 1 from public.mcr_dagafsluiting a join public.klussen k3 on k3.kraam_id = a.kraam_id and k3.datum = a.datum
                      where k3.id = w.klus_id and a.afgesloten_op is not null)))
      or (w.soort = 'mcr_morgen' and (
             w.aangemaakt_op < (v_nu::date::timestamp at time zone 'Europe/London')
          or not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id)))
      or not exists (select 1 from public.gebruikers g where g.id = w.gebruiker_id and g.push_token is not null and g.gearchiveerd_op is null)
      or w.aangemaakt_op < now() - interval '3 days');

  if v_uur < 8 then return; end if;

  return query
  with w as (
    select x.*,
           exists (select 1 from public.mcr_shift_ruil r where r.shift_id = x.shift_id and r.gebruiker_id = x.gebruiker_id
                     and r.status in ('overgenomen','vrijgegeven')) as via_ruil
      from public.push_wachtrij x
     where x.verwerkt_op is null and x.aangemaakt_op < now() - interval '2 minutes'
       and (v_uur < 22 or x.soort in ('mcr_dag_open','mcr_dag_open_b','mcr_dag_dicht'))
  ), g as (
    select w.gebruiker_id, w.soort, array_agg(w.id order by w.id) as ids, count(*)::int as n,
           string_agg(w.regel, E'\n' order by w.id) as regels, bool_and(w.via_ruil) as via_ruil,
           (array_agg(w.shift_id order by w.id))[1] as sid
      from w group by w.gebruiker_id, w.soort
  )
  select g.gebruiker_id, u.push_token, u.push_platform, g.ids, g.soort,
         case g.soort
           when 'mcr_erop' then case when g.n = 1 then 'You''re on the rota' else 'You''re on the rota for ' || g.n || ' shifts' end
           when 'mcr_eraf' then case when g.via_ruil then 'Swap done' else 'Rota change' end
           when 'mcr_ruil_ok' then 'Your shift is open for a swap'
           when 'mcr_ruil_nee' then 'Swap not approved'
           when 'mcr_ruil_open' then case when g.n = 1 then 'Shift available' else g.n || ' shifts available' end
           when 'mcr_ruil_gevraagd' then case when g.n = 1 then 'Manchester: shift ruilen gevraagd' else 'Manchester: ' || g.n || ' keer shift ruilen gevraagd' end
           when 'mcr_agenda_manager' then case when g.n = 1 then 'Manchester: nieuw in de agenda' else 'Manchester: ' || g.n || ' nieuwe agenda-items' end
           when 'mcr_dag_open' then 'Close the day'
           when 'mcr_dag_open_b' then case when g.n = 1 then 'Manchester: kraam nog niet afgesloten' else 'Manchester: ' || g.n || ' kramen nog niet afgesloten' end
           when 'mcr_dag_dicht' then case when g.n = 1 then 'Manchester: kraam afgesloten' else 'Manchester: ' || g.n || ' kramen afgesloten' end
           when 'mcr_morgen' then case when g.n = 1 then 'Tomorrow: your shift' else 'Tomorrow: ' || g.n || ' shifts' end
           else 'TC Group' end,
         case g.soort
           when 'mcr_eraf' then 'You''re off the rota for: ' || replace(g.regels, E'\n', '; ')
           when 'mcr_ruil_ok' then g.regels || E'\nYou stay on the rota until someone takes over.'
           when 'mcr_ruil_nee' then g.regels || E'\nYou''re still on the rota for this shift.'
           when 'mcr_ruil_open' then g.regels || E'\nTap to ask for it.'
           when 'mcr_ruil_gevraagd' then g.regels || E'\nKeur goed of af bij Manchester → Shifts.'
           when 'mcr_agenda_manager' then g.regels || E'\nBekijk het bij Manchester → Agenda.'
           when 'mcr_dag_open_b' then g.regels
           when 'mcr_morgen' then g.regels || E'\nBe there 10 minutes early. Tap for the details.'
           else g.regels end,
         case when g.soort in ('mcr_erop','mcr_morgen') and g.n = 1 and g.sid is not null then 'mcr-shift:' || g.sid::text
              when g.soort = 'mcr_ruil_open' then 'mcr-open'
              when g.soort = 'mcr_ruil_gevraagd' then 'mcr-beheer'
              when g.soort = 'mcr_agenda_manager' then 'mcr-agenda'
              when g.soort = 'mcr_dag_open' then 'mcr-close'
              when g.soort in ('mcr_dag_open_b','mcr_dag_dicht') then 'mcr-afsluiting'
              else 'mcr-shifts' end
    from g join public.gebruikers u on u.id = g.gebruiker_id
   where u.push_token is not null;
end $function$;
