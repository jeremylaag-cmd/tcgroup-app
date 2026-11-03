-- Manchester: de kraammanager en "vandaag" (3 nov 2026)
--
-- Waarom: de app zegt tegen crew "Ask the stand manager to clock you in", maar
-- een manager kon niemand inklokken of uren toevoegen. Er is maar één actieve
-- NFC-tag (Exchange Square); de andere kramen klokken met de dagcode, en die
-- zag alleen Bram. En niemand merkte het als iemand niet kwam of vergat uit te
-- klokken tot de dagafsluiting.
--
-- * urenregistraties.in_door / in_op: wie iemand inklokte of uren toevoegde
--   (een kraammanager). Alleen de server zet ze (trigger).
-- * mgr_inklokken: "Clock in now" voor iemand op het rooster van de eigen kraam
--   vandaag die nog niet geklokt is.
-- * mgr_uren_toevoegen: "Worked – add hours" (begin, eind, pauze, reden) voor
--   iemand op het rooster van die kraam/dag zonder registratie; status 'wacht',
--   met notitie voor Bram.
-- * mgr_dagcodes: de code van vandaag voor de eigen kramen.
-- * mgr_vandaag: het blok "Today" bovenaan Rota (code, wie er is, wie niet).
-- * mgr_borg: borg per polo/schort uit de instellingen (tekst bij Team).
-- * mgr_afsluiting: geeft nu ook door wie iemand inklokte/uren toevoegde.
-- * Meldingen (push_wachtrij_bundels → mcr_klok_meldingen):
--     mcr_niet_in  aan de manager(s): "Anna isn't clocked in yet", 10 min na de
--                  start van haar dienst, één keer per persoon per dienst.
--     mcr_nog_in   aan crew: "You're still clocked in", 30 min na het eind van
--                  de dienst (bij 'tot sluit': sluiting + opruimtijd), één keer;
--                  mag tot middernacht.
--   Beide vervallen zodra het niet meer klopt.
-- * mcr_afsluiters krijgt eigenaar postgres: vanuit de meldingenklok (geen
--   ingelogde gebruiker) gaf hij niemand terug, dus ook "Close the day" kwam
--   nooit bij de managers aan.
--
-- Let op: dit bestand gebruikt het woord voor weghalen nergens; de
-- database-tool annuleert zulke migraties.

-- ── Kolommen ──────────────────────────────────────────────────────
alter table public.urenregistraties add column if not exists in_door uuid;
alter table public.urenregistraties add column if not exists in_op   timestamptz;
alter table public.push_wachtrij    add column if not exists over_gebruiker uuid;

-- Crew mag via de tabel zelf (eigen lopende uren) niet doen alsof een manager
-- ze inklokte. De RPC's draaien als app_rpc en mogen het wel.
create or replace function public.uren_in_door_bewaken()
returns trigger
language plpgsql set search_path to 'public'
as $$
begin
  if current_user in ('authenticated','anon') then
    if TG_OP = 'INSERT' and (new.in_door is not null or new.in_op is not null) then
      raise exception 'Only the server sets this.' using errcode='P0002';
    end if;
    if TG_OP = 'UPDATE' and (new.in_door is distinct from old.in_door or new.in_op is distinct from old.in_op) then
      raise exception 'Only the server sets this.' using errcode='P0002';
    end if;
  end if;
  return new;
end $$;
create or replace trigger uren_in_door_bewaken before insert or update on public.urenregistraties
  for each row execute function public.uren_in_door_bewaken();

-- ── Hulp: een oude "No-show/Cancelled/Sent home" klopt niet meer ──
-- Heeft de manager iemand als niet gekomen gemarkeerd en klokt hij hem daarna
-- toch in (of voegt hij uren toe), dan wordt die controle bijgewerkt: op tijd
-- = gecontroleerd, later = te laat (de manager kan het daarna nog wijzigen).
create or replace function public.mcr_controle_na_uren(p_kraam uuid, p_datum date, p_gebruiker uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare m record;
begin
  select * into m from public.mcr_dagmensen(p_kraam, p_datum) x where x.gebruiker_id = p_gebruiker;
  if not found or m.uren_id is null then return; end if;
  update public.mcr_dagcontrole c
     set uren_id = m.uren_id,
         uitkomst = case when m.minuten_te_laat > 0 then 'te_laat' else 'ok' end,
         minuten_te_laat = m.minuten_te_laat,
         door = public.huidige_gebruiker(), op = now()
   where c.kraam_id = p_kraam and c.datum = p_datum and c.gebruiker_id = p_gebruiker
     and c.uitkomst in ('niet_gekomen','afgemeld','naar_huis') and c.voorval_id is null;
end $$;

-- ── Clock in now ──────────────────────────────────────────────────
create or replace function public.mgr_inklokken(p_kraam uuid, p_gebruiker uuid)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker();
        v_dag date := (now() at time zone 'Europe/London')::date;
        v_klus uuid; v_start time; v_naam text; v_mgr text; v_id uuid; v_venster int; v_vest text;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only do this for your own stall.' using errcode='P0002';
  end if;
  if p_gebruiker = v_uid then
    raise exception 'You cannot clock yourself in.' using errcode='P0002';
  end if;
  select g.naam into v_naam from public.gebruikers g
   where g.id = p_gebruiker and g.rol <> 'beheerder' and coalesce(g.goedgekeurd,false)
     and g.gearchiveerd_op is null and public.vest_ok(g.vestiging);
  if not found then raise exception 'That person does not exist.' using errcode='P0002'; end if;

  select kl.id, k.vestiging into v_klus, v_vest
    from public.klussen kl join public.kramen k on k.id = kl.kraam_id
   where kl.kraam_id = p_kraam and kl.datum = v_dag;
  select min(s.start_tijd) into v_start
    from public.klus_gebruikers kg join public.klus_shifts s on s.id = kg.shift_id
   where kg.klus_id = v_klus and kg.gebruiker_id = p_gebruiker;
  if v_klus is null or not exists (select 1 from public.klus_gebruikers kg
                                    where kg.klus_id = v_klus and kg.gebruiker_id = p_gebruiker and kg.shift_id is not null) then
    raise exception '% is not on the rota at this stall today.', v_naam using errcode='P0002';
  end if;
  if exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = p_kraam and a.datum = v_dag and a.afgesloten_op is not null) then
    raise exception 'This day is already closed. Ask Bram if something needs to change.' using errcode='P0002';
  end if;
  if exists (select 1 from public.urenregistraties u where u.gebruiker_id = p_gebruiker and u.uitgeklokt_op is null) then
    raise exception '% is already clocked in.', v_naam using errcode='P0002';
  end if;
  if exists (select 1 from public.urenregistraties u where u.gebruiker_id = p_gebruiker and u.klus_id = v_klus) then
    raise exception '% already has hours for today. Check them under Close day.', v_naam using errcode='P0002';
  end if;
  if exists (select 1 from public.urenregistraties u
              where u.gebruiker_id = p_gebruiker and u.ingeklokt_op <= now() and u.uitgeklokt_op > now()) then
    raise exception 'This overlaps with other hours of %.', v_naam using errcode='P0002';
  end if;
  v_venster := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                          where i.vestiging = v_vest and i.sleutel = 'inklok_venster_min'), 30)::int;
  if v_start is not null and now() < ((v_dag + v_start) at time zone 'Europe/London') - make_interval(mins => v_venster) then
    raise exception 'Too early: the shift of % starts at %.', v_naam, to_char(v_start,'HH24:MI') using errcode='P0002';
  end if;

  select g.naam into v_mgr from public.gebruikers g where g.id = v_uid;
  -- handmatig = true: geen tag/code, en de klusdatum-controle (Amsterdamse
  -- datum) zou na 23:00 Engelse tijd ten onrechte weigeren.
  insert into public.urenregistraties (gebruiker_id, klus_id, ingeklokt_op, status, handmatig, in_door, in_op, notitie_beh)
  values (p_gebruiker, v_klus, now(), 'lopend', true, v_uid, now(),
          'Ingeklokt door kraammanager ' || coalesce(v_mgr,'?') || ' om ' || to_char(now() at time zone 'Europe/London','HH24:MI'))
  returning id into v_id;
  perform public.mcr_controle_na_uren(p_kraam, v_dag, p_gebruiker);
  return v_id;
end $$;

-- ── Worked – add hours ────────────────────────────────────────────
-- Tijden als 'HH:MM' (Engelse tijd) op p_datum; een eindtijd vóór 05:00 die
-- vóór de begintijd ligt, valt op de dag erna.
create or replace function public.mgr_uren_toevoegen(p_kraam uuid, p_datum date, p_gebruiker uuid,
  p_van text, p_tot text, p_pauze integer default 0, p_reden text default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker();
        v_vandaag date := (now() at time zone 'Europe/London')::date;
        v_klus uuid; v_naam text; v_mgr text; v_id uuid; v_t1 time; v_t2 time;
        v_van timestamptz; v_tot timestamptz; v_min int; v_pauze int; v_reden text; o record;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only do this for your own stall.' using errcode='P0002';
  end if;
  if p_gebruiker = v_uid then
    raise exception 'You cannot add your own hours. Ask Bram.' using errcode='P0002';
  end if;
  if p_datum is null or p_datum > v_vandaag or p_datum < v_vandaag - 7 then
    raise exception 'You can only add hours for today and the last 7 days.' using errcode='P0002';
  end if;
  select g.naam into v_naam from public.gebruikers g
   where g.id = p_gebruiker and g.rol <> 'beheerder' and coalesce(g.goedgekeurd,false)
     and g.gearchiveerd_op is null and public.vest_ok(g.vestiging);
  if not found then raise exception 'That person does not exist.' using errcode='P0002'; end if;

  select kl.id into v_klus from public.klussen kl where kl.kraam_id = p_kraam and kl.datum = p_datum;
  if v_klus is null or not exists (select 1 from public.klus_gebruikers kg
                                    where kg.klus_id = v_klus and kg.gebruiker_id = p_gebruiker and kg.shift_id is not null) then
    raise exception '% was not on the rota at this stall that day.', v_naam using errcode='P0002';
  end if;
  if exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = p_kraam and a.datum = p_datum and a.afgesloten_op is not null) then
    raise exception 'This day is already closed. Ask Bram if something needs to change.' using errcode='P0002';
  end if;
  if exists (select 1 from public.urenregistraties u where u.gebruiker_id = p_gebruiker and u.klus_id = v_klus) then
    raise exception '% already has hours for this day. Change those instead.', v_naam using errcode='P0002';
  end if;

  if coalesce(p_van,'') !~ '^\d{1,2}:\d{2}$' or coalesce(p_tot,'') !~ '^\d{1,2}:\d{2}$' then
    raise exception 'Fill in the start and finish time.' using errcode='P0002';
  end if;
  begin
    v_t1 := p_van::time; v_t2 := p_tot::time;
  exception when others then
    raise exception 'That is not a valid time.' using errcode='P0002';
  end;
  v_van := (p_datum + v_t1) at time zone 'Europe/London';
  if v_t2 < v_t1 and v_t2 <= time '05:00' then
    v_tot := ((p_datum + 1) + v_t2) at time zone 'Europe/London';
  else
    v_tot := (p_datum + v_t2) at time zone 'Europe/London';
  end if;
  if v_tot <= v_van then
    raise exception 'The finish time must be after the start time.' using errcode='P0002';
  end if;
  if v_tot - v_van > interval '18 hours' then
    raise exception 'That is more than 18 hours. Check the times.' using errcode='P0002';
  end if;
  if v_tot > now() then
    raise exception 'The finish time has not happened yet. If they are working now, use Clock in now on the Rota.' using errcode='P0002';
  end if;
  v_min := (extract(epoch from (v_tot - v_van))/60)::int;
  v_pauze := coalesce(p_pauze, 0);
  if v_pauze < 0 or v_pauze > 240 or v_pauze >= v_min then
    raise exception 'Check the break (0 to 240 minutes, shorter than the shift).' using errcode='P0002';
  end if;
  v_reden := nullif(btrim(public.schoon_kort(p_reden)),'');
  if v_reden is null or length(v_reden) < 2 then
    raise exception 'Say why (Bram sees it).' using errcode='P0002';
  end if;
  v_reden := left(v_reden, 200);

  select u.ingeklokt_op, u.uitgeklokt_op into o from public.urenregistraties u
   where u.gebruiker_id = p_gebruiker and u.ingeklokt_op < v_tot and coalesce(u.uitgeklokt_op, 'infinity'::timestamptz) > v_van
   order by u.ingeklokt_op limit 1;
  if found then
    raise exception 'This overlaps with other hours of % (% – %).', v_naam,
      to_char(o.ingeklokt_op at time zone 'Europe/London','DD Mon HH24:MI'),
      coalesce(to_char(o.uitgeklokt_op at time zone 'Europe/London','HH24:MI'),'still clocked in') using errcode='P0002';
  end if;

  select g.naam into v_mgr from public.gebruikers g where g.id = v_uid;
  insert into public.urenregistraties (gebruiker_id, klus_id, ingeklokt_op, uitgeklokt_op, pauze_minuten, totaal_minuten,
                                       status, handmatig, in_door, in_op, uit_door, uit_op, pauze_door, pauze_op, notitie_beh)
  values (p_gebruiker, v_klus, v_van, v_tot, v_pauze, greatest(0, v_min - v_pauze),
          'wacht', true, v_uid, now(), v_uid, now(),
          case when v_pauze > 0 then v_uid end, case when v_pauze > 0 then now() end,
          'Uren toegevoegd door kraammanager ' || coalesce(v_mgr,'?') || ': ' || v_reden)
  returning id into v_id;
  perform public.mcr_controle_na_uren(p_kraam, p_datum, p_gebruiker);
  return v_id;
end $$;

-- ── De dagcode van vandaag voor de eigen kramen ───────────────────
create or replace function public.mgr_dagcodes()
returns table(kraam_id uuid, kraam text, kleur text, code text, mijn boolean)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select k.id, k.naam, coalesce(k.kleur,'#6B6A66'), public.kraam_dagcode(k.id),
         public.huidige_gebruiker() in (select public.mcr_afsluiters(k.id, d.dag)) as mijn
    from public.kramen k
    cross join (select (now() at time zone 'Europe/London')::date as dag) d
    join public.klussen kl on kl.kraam_id = k.id and kl.datum = d.dag
    left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d.dag
   where public.mgr_kraam_ok(k.id) and not coalesce(u.dicht,false)
   order by 5 desc, k.volgorde, k.naam
 ) _r where public.is_kraammanager() $$;

-- ── Today: per kraam van vandaag de code en wie er is ─────────────
-- Kraammanagers zelf staan er niet in (die klokken niet).
create or replace function public.mgr_vandaag()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_dag date := (now() at time zone 'Europe/London')::date; v jsonb;
begin
  if not public.is_kraammanager() then
    raise exception 'Only a stall manager can see this.' using errcode='P0002';
  end if;
  select coalesce(jsonb_agg(x.j order by x.mijn desc, x.volgorde, x.naam), '[]'::jsonb) into v from (
    select k.volgorde, k.naam,
           public.huidige_gebruiker() in (select public.mcr_afsluiters(k.id, v_dag)) as mijn,
           jsonb_build_object(
             'kraam_id', k.id, 'kraam', k.naam, 'kleur', coalesce(k.kleur,'#6B6A66'),
             'open_van', coalesce(u.open_van, k.open_van), 'open_tot', coalesce(u.open_tot, k.open_tot),
             'code', public.kraam_dagcode(k.id),
             'tag', exists (select 1 from public.nfc_tags t where t.kraam_id = k.id and t.ingetrokken_op is null),
             'mijn', public.huidige_gebruiker() in (select public.mcr_afsluiters(k.id, v_dag)),
             'afgesloten', exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = k.id and a.datum = v_dag and a.afgesloten_op is not null),
             'mensen', coalesce((
               select jsonb_agg(jsonb_build_object(
                 'id', g.id, 'naam', g.naam, 'telefoon', g.telefoon,
                 'start', r.st, 'eind', r.et, 'tot_sluit', coalesce(r.tot_sluit,false),
                 'start_ts', case when r.st is not null then (v_dag + r.st) at time zone 'Europe/London' end,
                 'eind_ts', case when r.st is null then null
                                 when r.tot_sluit or r.et is null then (v_dag + coalesce(u.open_tot, k.open_tot)) at time zone 'Europe/London'
                                 else (v_dag + r.et) at time zone 'Europe/London' end,
                 'uren_id', ur.id, 'in', ur.ingeklokt_op, 'uit', ur.uitgeklokt_op,
                 'in_door', idr.naam, 'controle', c.uitkomst)
                 order by r.st nulls last, g.naam)
                 from (select ids.gid, rr.st, rr.et, rr.tot_sluit
                         from (select kg.gebruiker_id gid from public.klus_gebruikers kg where kg.klus_id = kl.id and kg.shift_id is not null
                               union select u2.gebruiker_id from public.urenregistraties u2 where u2.klus_id = kl.id) ids
                         left join (select kg.gebruiker_id gid, min(s.start_tijd) st, max(s.eind_tijd) et, bool_or(s.eind_tijd is null) tot_sluit
                                      from public.klus_gebruikers kg join public.klus_shifts s on s.id = kg.shift_id
                                     where kg.klus_id = kl.id group by kg.gebruiker_id) rr on rr.gid = ids.gid) r
                 join public.gebruikers g on g.id = r.gid and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
                 left join lateral (select u3.* from public.urenregistraties u3 where u3.gebruiker_id = g.id and u3.klus_id = kl.id
                                     order by u3.ingeklokt_op desc limit 1) ur on true
                 left join public.gebruikers idr on idr.id = ur.in_door
                 left join public.mcr_dagcontrole c on c.kraam_id = k.id and c.datum = v_dag and c.gebruiker_id = g.id), '[]'::jsonb)
           ) as j
      from public.kramen k
      join public.klussen kl on kl.kraam_id = k.id and kl.datum = v_dag
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = v_dag
     where public.mgr_kraam_ok(k.id) and not coalesce(u.dicht,false)
  ) x;
  return jsonb_build_object('nu', now(), 'datum', v_dag, 'kramen', v);
end $$;

-- ── Borg per stuk (voor de tekst bij Team) ────────────────────────
create or replace function public.mgr_borg()
returns table(polo numeric, schort numeric)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select public.mcr_kleding_borg(g.vestiging, 1, 0), public.mcr_kleding_borg(g.vestiging, 0, 1)
    from public.gebruikers g where g.id = public.huidige_gebruiker()
 ) _r where public.is_kraammanager() $$;

-- ── Close day: ook laten zien wie iemand inklokte/uren toevoegde ──
-- (Gelijk aan mcr_dagafsluiting.sql, plus 'in_door'.)
create or replace function public.mgr_afsluiting(p_kraam uuid, p_datum date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v jsonb; k record; a record;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only close your own stall.' using errcode='P0002';
  end if;
  select kr.id, kr.naam, coalesce(kr.kleur,'#6B6A66') kleur, coalesce(u.open_tot, kr.open_tot) sluit into k
    from public.kramen kr left join public.kraam_uitzonderingen u on u.kraam_id = kr.id and u.datum = p_datum
   where kr.id = p_kraam;
  select x.*, d.naam as door_naam into a from public.mcr_dagafsluiting x
    left join public.gebruikers d on d.id = x.afgesloten_door
   where x.kraam_id = p_kraam and x.datum = p_datum;
  select jsonb_build_object(
    'kraam_id', k.id, 'kraam', k.naam, 'kleur', k.kleur, 'datum', p_datum, 'sluit', k.sluit,
    'toekomst', p_datum > (now() at time zone 'Europe/London')::date,
    'afgesloten', case when a.afgesloten_op is null then null else jsonb_build_object(
        'op', a.afgesloten_op, 'door', a.door_naam, 'schoonmaak', a.schoonmaak, 'gas', a.gas,
        'voorraad_nodig', a.voorraad_nodig, 'voorraad', a.voorraad, 'voorraad_tekst', a.voorraad_tekst) end,
    'mensen', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id, 'naam', g.naam, 'telefoon', g.telefoon, 'start', m.start_tijd, 'eind', m.eind_tijd,
        'uren_id', m.uren_id, 'in', m.ingeklokt_op, 'uit', m.uitgeklokt_op, 'pauze', m.pauze, 'uren_status', m.uren_status,
        'te_laat', m.minuten_te_laat, 'beoordeling', g.beoordeling,
        'diensten', (select count(*)::int from public.klus_gebruikers k2 join public.klussen l2 on l2.id = k2.klus_id
                      where k2.gebruiker_id = g.id and l2.kraam_id is not null and l2.datum <= p_datum),
        'polo', g.kleding_polo, 'schort', g.kleding_schort, 'maat', g.shirtmaat,
        'controle', c.uitkomst, 'controle_min', c.minuten_te_laat, 'controle_door', cd.naam, 'controle_op', c.op,
        'in_door', idr.naam)
        order by m.start_tijd nulls last, g.naam)
        from public.mcr_dagmensen(p_kraam, p_datum) m
        join public.gebruikers g on g.id = m.gebruiker_id
        left join public.mcr_dagcontrole c on c.kraam_id = p_kraam and c.datum = p_datum and c.gebruiker_id = g.id
        left join public.gebruikers cd on cd.id = c.door
        left join public.urenregistraties ur on ur.id = m.uren_id
        left join public.gebruikers idr on idr.id = ur.in_door), '[]'::jsonb)
  ) into v;
  return v;
end $$;

-- ── Meldingen: niet ingeklokt / nog ingeklokt ─────────────────────
-- Los van push_wachtrij_bundels zodat het met een andere tijd te testen is.
create or replace function public.mcr_klok_meldingen(p_nu timestamptz default now())
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_dag date := (p_nu at time zone 'Europe/London')::date;
        v_begin timestamptz := (((p_nu at time zone 'Europe/London')::date)::timestamp at time zone 'Europe/London');
begin
  -- a) Aan de manager(s): iemand staat al 10 minuten op het rooster en is niet ingeklokt.
  with dienst as (
    select kl.id as klus_id, k.id as kid, k.naam as kraam, s.id as sid, s.start_tijd, kg.gebruiker_id as gid, g.naam,
           (v_dag + s.start_tijd) at time zone 'Europe/London' as start_ts,
           (v_dag + coalesce(s.eind_tijd, coalesce(u.open_tot, k.open_tot))) at time zone 'Europe/London' as eind_ts
      from public.kramen k
      join public.klussen kl on kl.kraam_id = k.id and kl.datum = v_dag
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = v_dag
      join public.klus_shifts s on s.klus_id = kl.id
      join public.klus_gebruikers kg on kg.shift_id = s.id
      join public.gebruikers g on g.id = kg.gebruiker_id and g.rol <> 'beheerder'
                               and not coalesce(g.kraammanager,false) and g.gearchiveerd_op is null
     where k.actief and not coalesce(u.dicht,false) and v_dag between k.seizoen_start and k.seizoen_eind
       and s.start_tijd is not null
       and not exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = k.id and a.datum = v_dag and a.afgesloten_op is not null)
  ), mist as (
    select d.* from dienst d
     where p_nu >= d.start_ts + interval '10 minutes' and p_nu < d.eind_ts
       and not exists (select 1 from public.urenregistraties ur where ur.gebruiker_id = d.gid and ur.klus_id = d.klus_id)
       and not exists (select 1 from public.mcr_dagcontrole c where c.kraam_id = d.kid and c.datum = v_dag and c.gebruiker_id = d.gid)
  ), ontv as (
    select m.*, x.mid from mist m cross join lateral (select public.mcr_afsluiters(m.kid, v_dag) as mid) x
  )
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, shift_id, over_gebruiker, regel, aangemaakt_op)
  select o.mid, 'mcr_niet_in', o.klus_id, o.sid, o.gid,
         o.naam || ' · ' || o.kraam || ' · shift started ' || to_char(o.start_tijd,'HH24:MI'), p_nu
    from ontv o
    join public.gebruikers r on r.id = o.mid and r.push_token is not null and r.gearchiveerd_op is null
   where o.mid is not null and o.mid <> o.gid
     and not exists (select 1 from public.push_wachtrij w where w.soort = 'mcr_niet_in' and w.shift_id = o.sid
                       and w.over_gebruiker = o.gid and w.gebruiker_id = o.mid);

  -- b) Aan crew: 30 minuten na het eind van de dienst nog ingeklokt.
  --    Tot sluit: sluitingstijd + opruimtijd is het eind.
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, shift_id, over_gebruiker, regel, aangemaakt_op)
  select x.gid, 'mcr_nog_in', x.klus_id, x.sid, x.gid,
         x.kraam || ' · clocked in at ' || to_char(x.ingeklokt_op at time zone 'Europe/London','HH24:MI'), p_nu
    from (
      select ur.gebruiker_id as gid, kl.id as klus_id, kg.shift_id as sid, k.naam as kraam, ur.ingeklokt_op,
             case when s.eind_tijd is not null then (v_dag + s.eind_tijd) at time zone 'Europe/London'
                  else ((v_dag + coalesce(u.open_tot, k.open_tot)) at time zone 'Europe/London')
                       + make_interval(mins => coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric
                                                           from public.vestiging_instellingen i
                                                          where i.vestiging = k.vestiging and i.sleutel = 'opruimtijd_minuten'), 30)::int)
             end as eind_ts
        from public.urenregistraties ur
        join public.klussen kl on kl.id = ur.klus_id and kl.datum = v_dag
        join public.kramen k on k.id = kl.kraam_id
        left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = v_dag
        left join public.klus_gebruikers kg on kg.klus_id = kl.id and kg.gebruiker_id = ur.gebruiker_id
        left join public.klus_shifts s on s.id = kg.shift_id
        join public.gebruikers g on g.id = ur.gebruiker_id and g.push_token is not null and g.gearchiveerd_op is null
       where ur.status = 'lopend' and ur.uitgeklokt_op is null
    ) x
   where p_nu >= x.eind_ts + interval '30 minutes'
     and not exists (select 1 from public.push_wachtrij w where w.soort = 'mcr_nog_in' and w.klus_id = x.klus_id and w.gebruiker_id = x.gid);

  -- c) Vervallen als het niet meer klopt.
  update public.push_wachtrij w set verwerkt_op = now(), uitslag = 'vervallen'
   where w.verwerkt_op is null and w.soort in ('mcr_niet_in','mcr_nog_in') and (
         w.aangemaakt_op < v_begin
      or (w.soort = 'mcr_niet_in' and (
             exists (select 1 from public.urenregistraties ur where ur.gebruiker_id = w.over_gebruiker and ur.klus_id = w.klus_id)
          or not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.over_gebruiker)
          or exists (select 1 from public.mcr_dagcontrole c join public.klussen k3 on k3.kraam_id = c.kraam_id and k3.datum = c.datum
                      where k3.id = w.klus_id and c.gebruiker_id = w.over_gebruiker)
          or exists (select 1 from public.mcr_dagafsluiting a join public.klussen k4 on k4.kraam_id = a.kraam_id and k4.datum = a.datum
                      where k4.id = w.klus_id and a.afgesloten_op is not null)))
      or (w.soort = 'mcr_nog_in' and not exists (
             select 1 from public.urenregistraties ur where ur.gebruiker_id = w.gebruiker_id and ur.klus_id = w.klus_id
                and ur.status = 'lopend' and ur.uitgeklokt_op is null)));
end $$;

-- ── push_wachtrij_bundels: de huidige definitie (3 nov, met mcr_morgen),
--    plus mcr_klok_meldingen, en titels/pagina's voor mcr_niet_in en mcr_nog_in.
CREATE OR REPLACE FUNCTION public.push_wachtrij_bundels()
 RETURNS TABLE(gebruiker_id uuid, push_token text, push_platform text, ids bigint[], soort text, titel text, bericht text, pagina text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_nu timestamp := (now() at time zone 'Europe/London');
        v_uur int := extract(hour from (now() at time zone 'Europe/London'))::int;
begin
  -- Niet ingeklokt / nog ingeklokt. Gaat daar iets mis, dan gaan de andere
  -- meldingen gewoon door.
  begin
    perform public.mcr_klok_meldingen(now());
  exception when others then
    raise warning 'mcr_klok_meldingen: %', sqlerrm;
  end;
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
      or (w.soort = 'nl_crm_optie' and not exists (select 1 from public.klussen k where k.id = w.klus_id and k.is_optie))
      or w.aangemaakt_op < now() - interval '3 days');
  -- Ziekmeldingen (NL) mogen al vanaf 06:00 Engelse tijd (07:00 in NL).
  if v_uur < 6 then return; end if;
  return query
  with w as (
    select x.*,
           exists (select 1 from public.mcr_shift_ruil r where r.shift_id = x.shift_id and r.gebruiker_id = x.gebruiker_id
                     and r.status in ('overgenomen','vrijgegeven')) as via_ruil
      from public.push_wachtrij x
     where x.verwerkt_op is null
       -- niet_in/nog_in hoeven niet te wachten: ze zijn al op tijd gemaakt.
       and (x.aangemaakt_op < now() - interval '2 minutes' or x.soort in ('mcr_niet_in','mcr_nog_in'))
       and (v_uur < 22 or x.soort in ('mcr_dag_open','mcr_dag_open_b','mcr_dag_dicht','mcr_nog_in'))
       and (v_uur >= 8 or x.soort = 'nl_ziek')
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
           when 'mcr_niet_in' then case when g.n = 1 then split_part(g.regels, ' ', 1) || ' isn''t clocked in yet'
                                        else g.n || ' people aren''t clocked in yet' end
           when 'mcr_nog_in' then 'You''re still clocked in'
           when 'nl_ziek' then case when g.n = 1 then 'Ziekmelding' else g.n || ' ziekmeldingen' end
           when 'nl_crm_optie' then case when g.n = 1 then 'Optie loopt af' else g.n || ' opties lopen af' end
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
           when 'mcr_niet_in' then g.regels || E'\nTap to call them or clock them in.'
           when 'mcr_nog_in' then 'Don''t forget to clock out.' || E'\n' || g.regels
           else g.regels end,
         case when g.soort in ('mcr_erop','mcr_morgen') and g.n = 1 and g.sid is not null then 'mcr-shift:' || g.sid::text
              when g.soort = 'mcr_ruil_open' then 'mcr-open'
              when g.soort = 'mcr_ruil_gevraagd' then 'mcr-beheer'
              when g.soort = 'mcr_agenda_manager' then 'mcr-agenda'
              when g.soort = 'mcr_dag_open' then 'mcr-close'
              when g.soort in ('mcr_dag_open_b','mcr_dag_dicht') then 'mcr-afsluiting'
              when g.soort = 'mcr_niet_in' then 'mcr-today'
              when g.soort = 'mcr_nog_in' then 'mcr-clock'
              when g.soort = 'nl_ziek' then 'nl-ziek'
              when g.soort = 'nl_crm_optie' then 'nl-crm'
              else 'mcr-shifts' end
    from g join public.gebruikers u on u.id = g.gebruiker_id
   where u.push_token is not null;
end $function$;

-- ── Eigenaars en rechten ──────────────────────────────────────────
alter function public.mcr_controle_na_uren(uuid,date,uuid) owner to app_rpc;
alter function public.mgr_inklokken(uuid,uuid) owner to app_rpc;
alter function public.mgr_uren_toevoegen(uuid,date,uuid,text,text,integer,text) owner to app_rpc;
alter function public.mgr_dagcodes() owner to app_rpc;
alter function public.mgr_vandaag() owner to app_rpc;
alter function public.mgr_borg() owner to app_rpc;
alter function public.mgr_afsluiting(uuid,date) owner to app_rpc;
-- mcr_afsluiters wordt ook door de meldingenklok gebruikt, zonder ingelogde
-- gebruiker. Als app_rpc zag hij dan door de rij-beveiliging niemand (de
-- herinnering "Close the day" kwam daardoor nooit bij de managers aan). Als
-- postgres werkt het altijd; hij blijft alleen intern aan te roepen.
alter function public.mcr_afsluiters(uuid,date) owner to postgres;
-- mcr_klok_meldingen hoort bij push_wachtrij_bundels (ook postgres).
alter function public.mcr_klok_meldingen(timestamptz) owner to postgres;
alter function public.push_wachtrij_bundels() owner to postgres;

revoke all on function public.uren_in_door_bewaken() from public, anon, authenticated;
revoke all on function public.mcr_controle_na_uren(uuid,date,uuid) from public, anon, authenticated;
revoke all on function public.mcr_klok_meldingen(timestamptz) from public, anon, authenticated;
revoke all on function public.push_wachtrij_bundels() from public, anon, authenticated;
grant execute on function public.mcr_controle_na_uren(uuid,date,uuid) to app_rpc, service_role;
grant execute on function public.mcr_klok_meldingen(timestamptz) to service_role;
grant execute on function public.push_wachtrij_bundels() to app_rpc, service_role;

revoke all on function public.mgr_inklokken(uuid,uuid) from public, anon;
revoke all on function public.mgr_uren_toevoegen(uuid,date,uuid,text,text,integer,text) from public, anon;
revoke all on function public.mgr_dagcodes() from public, anon;
revoke all on function public.mgr_vandaag() from public, anon;
revoke all on function public.mgr_borg() from public, anon;
revoke all on function public.mgr_afsluiting(uuid,date) from public, anon;
grant execute on function public.mgr_inklokken(uuid,uuid) to authenticated, service_role;
grant execute on function public.mgr_uren_toevoegen(uuid,date,uuid,text,text,integer,text) to authenticated, service_role;
grant execute on function public.mgr_dagcodes() to authenticated, service_role;
grant execute on function public.mgr_vandaag() to authenticated, service_role;
grant execute on function public.mgr_borg() to authenticated, service_role;
grant execute on function public.mgr_afsluiting(uuid,date) to authenticated, service_role;
