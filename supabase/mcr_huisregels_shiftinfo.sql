-- Manchester: huisregels 2026.3, huisregels voor Bram, en details van een shift (3 nov 2026)
--
-- Bram: "al het personeel moet de eerst volgende keer dat ze inloggen de huis
-- regels nog 1x voor hun zien en hier moeten ze weer akkoord op geven."
-- Nieuw: drankjes £0,50 per drankje; geen gratis pancakes voor vrienden, familie
-- of andere markthandelaren (alleen de stall manager mag dat). Daarnaast de
-- kledingborg gelijkgetrokken met de app: £25 per stuk (polo of schort).
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
    '- £25 will be withheld from your pay as a deposit for every piece of work clothing you get (long sleeve polo or apron).');
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
-- Alleen voor wie op die shift staat. Collega's alleen met voornaam en tijden.
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
         coalesce(sh.eind_tijd, public.kraam_eindtijd(k.id, kl.datum)) as eind_tijd,
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
    'collegas', coalesce((
      select jsonb_agg(jsonb_build_object('naam', split_part(btrim(g.naam),' ',1),
                                          'start', sh.start_tijd, 'eind', sh.eind_tijd) order by sh.start_tijd, g.naam)
        from public.klus_gebruikers kg
        join public.klus_shifts sh on sh.id = kg.shift_id
        join public.gebruikers g on g.id = kg.gebruiker_id
       where kg.klus_id = s.klus_id and kg.gebruiker_id <> v_uid), '[]'::jsonb),
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
