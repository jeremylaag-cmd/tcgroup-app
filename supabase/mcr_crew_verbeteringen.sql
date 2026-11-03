-- Manchester crew-app: in- en uitklokken en live bijwerken (3 nov 2026)
--
-- Waarom (analyse vóór de opening op vrijdag 6 november):
-- 1. Wie dubbel tikt bij het inklokken kreeg de databasefout
--    'duplicate key value violates unique constraint "één_lopende_per_gebruiker"'.
--    Nu: gewoon "You are already clocked in."
-- 2. Wie vergeet uit te klokken en de volgende dag uitklokt met de code van
--    vandaag, kreeg ±23 uur in 'wacht'. Nu: is het later dan het einde van de
--    dienst + 2 uur, dan komt de eindtijd op het einde van de dienst (sluiting +
--    opruimtijd bij een shift "tot sluiting"), met een notitie voor de manager en
--    Bram. Wie het vergat kan zonder code afsluiten (mcr_vergeten_uitklokken), en
--    bij het inklokken voor de volgende dienst wordt een vergeten klok vanzelf
--    afgesloten in plaats van "You are already clocked in".
--    De automatische uitklok grijpt voor Manchester al 4 uur na het einde van de
--    dienst (mcr_auto_uitklokken), niet pas na 24 uur. Nederland blijft gelijk.
-- 3. Elk signaal in wijziging_signalen liet alle apps herladen, ook van de
--    andere vestiging (667 van 680 signalen kwamen van Manchester-crew en lieten
--    de NL-planning steeds opnieuw laden). Nu krijgt elk signaal de vestiging
--    van wie de wijziging deed; de app slaat signalen van een andere vestiging over.
--
-- Geen enkele regel in dit bestand haalt objecten of rijen weg; alles is
-- "create or replace" of "add column if not exists".

-- ── 1. Signalen met vestiging ─────────────────────────────────────
alter table public.wijziging_signalen add column if not exists vestiging text;

-- De triggers zijn per opdracht (for each statement), dus er is geen rij om de
-- vestiging uit te halen. We nemen de vestiging van wie de wijziging doet:
-- actieve_vestiging() geeft voor Bram (alle vestigingen) de vestiging waar hij
-- nu in werkt, null bij "beide" en null zonder ingelogde gebruiker (cron).
-- Null = voor iedereen.
create or replace function public.signaal_geven()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into public.wijziging_signalen (tabel, door, vestiging)
  values (TG_TABLE_NAME, public.huidige_gebruiker(), public.actieve_vestiging());
  return null;
exception when others then
  return null;   -- een signaal mag nooit de oorzaak zijn dat iets anders mislukt
end $function$;
alter function public.signaal_geven() owner to postgres;

-- ── 2. Het einde van de dienst bij een klokregistratie ────────────
-- Shift met eindtijd → die eindtijd. Shift "tot sluiting" → sluiting (of de
-- afwijkende sluiting van die dag) + opruimtijd. Anders de eindtijd van de klus.
-- Over middernacht → de volgende dag. Alleen voor kramen (Manchester).
-- Geeft null als er geen redelijke eindtijd is (vóór het inklokken of meer dan
-- 18 uur erna, dezelfde grens als mgr_uur_zetten).
create or replace function public.mcr_dienst_eind(p_uren uuid)
 returns timestamp with time zone
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select case when x.eind > x.ingeklokt_op and x.eind <= x.ingeklokt_op + interval '18 hours' then x.eind end
    from (
      select u.ingeklokt_op,
             (kl.datum + t.eind_t
               + case when t.start_t is not null and t.eind_t < t.start_t then interval '1 day' else interval '0' end)
               at time zone coalesce(v.tijdzone, 'Europe/London') as eind
        from public.urenregistraties u
        join public.klussen kl on kl.id = u.klus_id
        join public.kramen k on k.id = kl.kraam_id
        left join public.vestigingen v on v.code = k.vestiging
        left join public.kraam_uitzonderingen ku on ku.kraam_id = k.id and ku.datum = kl.datum
        left join public.klus_gebruikers kg on kg.klus_id = kl.id and kg.gebruiker_id = u.gebruiker_id
        left join public.klus_shifts sh on sh.id = kg.shift_id
        cross join lateral (
          select coalesce(sh.start_tijd, kl.start_tijd) as start_t,
                 coalesce(sh.eind_tijd,
                          (coalesce(ku.open_tot, k.open_tot)
                             + make_interval(mins => coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric
                                 from public.vestiging_instellingen i
                                where i.vestiging = k.vestiging and i.sleutel = 'opruimtijd_minuten'), 0)::int))::time,
                          kl.eind_tijd, kl.einde_klus) as eind_t) t
       where u.id = p_uren
    ) x
$function$;
-- Eigenaar postgres: de automatische uitklok draait zonder ingelogde gebruiker
-- en app_rpc ziet dan door de rijbeveiliging niets. Niet aan te roepen vanuit
-- de app; alleen vanuit de functies hieronder.
alter function public.mcr_dienst_eind(uuid) owner to postgres;
revoke all on function public.mcr_dienst_eind(uuid) from public, anon, authenticated;
grant execute on function public.mcr_dienst_eind(uuid) to app_rpc, service_role;

-- ── 3. Een vergeten klok afsluiten op het einde van de dienst ─────
-- Eén plek voor alle gevallen. p_soort: 'laat' (later uitgeklokt met code of
-- tag), 'app' (zelf afgesloten in de app), 'inklok' (afgesloten bij het
-- inklokken voor een volgende dienst), 'auto' (door de server).
-- Pauze volgens de afspraak van de vestiging, berekend op de nieuwe lengte.
-- Alleen 'auto' zet de vlag auto_uitgeklokt; die mag alleen de server zetten
-- (zonder ingelogde gebruiker, zie urenregistratie_locatie_bewaken).
create or replace function public.mcr_vergeten_sluiten(p_uren uuid, p_soort text, p_na_uren integer DEFAULT 4)
 returns TABLE(uitgeklokt_op timestamp with time zone, pauze integer, minuten integer, kraam text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  r record; v_eind timestamptz; v_geschat boolean; v_min int; v_pauze int; v_drempel numeric; v_norm int;
  v_tz text; v_tekst text; v_auto boolean := (p_soort = 'auto');
begin
  select u.id, u.ingeklokt_op, u.uitgeklokt_op as uit, k.vestiging as kv, k.naam as kraamnaam,
         coalesce(v.tijdzone, 'Europe/London') as tz
    into r
    from public.urenregistraties u
    join public.klussen kl on kl.id = u.klus_id
    join public.kramen k on k.id = kl.kraam_id
    left join public.vestigingen v on v.code = k.vestiging
   where u.id = p_uren
   for update of u;
  if not found or r.uit is not null then return; end if;

  v_tz := r.tz;
  v_eind := public.mcr_dienst_eind(r.id);
  v_geschat := v_eind is null;
  if v_geschat then v_eind := r.ingeklokt_op + interval '8 hours'; end if;

  v_min := greatest(0, (extract(epoch from (v_eind - r.ingeklokt_op))/60)::int);
  select coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                    where i.vestiging = r.kv and i.sleutel = 'pauze_drempel_uren'), 6),
         coalesce((select nullif(replace(i.waarde,',','.'),'')::int from public.vestiging_instellingen i
                    where i.vestiging = r.kv and i.sleutel = 'pauze_minuten'), 30)
    into v_drempel, v_norm;
  v_pauze := least(v_min, case when v_min > v_drempel * 60 then v_norm else 0 end);

  v_tekst := case p_soort
      when 'auto' then 'Automatically clocked out: still clocked in ' || coalesce(p_na_uren,4) || ' hours after the end of the shift.'
      when 'inklok' then 'Forgot to clock out; closed when clocking in again (' || to_char(now() at time zone v_tz, 'Dy FMDD Mon HH24:MI') || ').'
      when 'app' then 'Forgot to clock out; closed in the app (' || to_char(now() at time zone v_tz, 'Dy FMDD Mon HH24:MI') || ').'
      else 'Clocked out late (' || to_char(now() at time zone v_tz, 'Dy FMDD Mon HH24:MI') || ').' end
    || ' Finish time set to ' || case when v_geschat then 'eight hours after clocking in' else 'the end of the shift' end
    || ' (' || to_char(v_eind at time zone v_tz, 'HH24:MI') || '), break ' || v_pauze || ' min. Please check.';

  update public.urenregistraties u
     set uitgeklokt_op = v_eind,
         pauze_minuten = v_pauze,
         totaal_minuten = greatest(0, v_min - v_pauze),
         status = 'wacht',
         auto_uitgeklokt = case when v_auto then true else u.auto_uitgeklokt end,
         locatie_uit = case when v_auto then coalesce(u.locatie_uit, 'automatisch') else u.locatie_uit end,
         locatie_uit_ok = case when v_auto then coalesce(u.locatie_uit_ok, false) else u.locatie_uit_ok end,
         notitie_beh = case when u.notitie_beh is null or u.notitie_beh = '' then v_tekst else u.notitie_beh || ' — ' || v_tekst end
   where u.id = r.id;

  uitgeklokt_op := v_eind; pauze := v_pauze; minuten := greatest(0, v_min - v_pauze); kraam := r.kraamnaam;
  return next;
end $function$;
alter function public.mcr_vergeten_sluiten(uuid, text, integer) owner to postgres;
revoke all on function public.mcr_vergeten_sluiten(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.mcr_vergeten_sluiten(uuid, text, integer) to app_rpc, service_role;

-- ── 4. Uitklokken met tag of code: met bovengrens ─────────────────
-- Alles van de vorige versie blijft. Nieuw: bij een kraam en later dan het einde
-- van de dienst + 2 uur → eindtijd op het einde van de dienst (mcr_vergeten_sluiten).
create or replace function public.tag_uitklokken(p_code text DEFAULT NULL::text, p_geen_pauze boolean DEFAULT false, p_notitie text DEFAULT NULL::text, p_pauze integer DEFAULT NULL::integer)
 returns TABLE(uren_id uuid, kraam text, minuten integer, pauze integer, uren numeric)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid; v_reg record; v_hash text; v_tag record; v_kraam_id uuid; v_in text;
  v_drempel numeric; v_pauze int; v_min int; v_kraamnaam text; v_ok boolean := false;
  v_laat record;
begin
  v_uid := public.huidige_gebruiker();
  if v_uid is null then raise exception 'niet ingelogd'; end if;

  select * into v_reg from public.urenregistraties u
   where u.gebruiker_id = v_uid and u.uitgeklokt_op is null
   order by u.ingeklokt_op desc limit 1;
  if not found then
    raise exception 'You are not clocked in.' using errcode='P0002';
  end if;

  select kl.kraam_id, k.naam into v_kraam_id, v_kraamnaam
    from public.klussen kl left join public.kramen k on k.id = kl.kraam_id
   where kl.id = v_reg.klus_id;

  -- Bij een kraam: de tag of de dagcode van díe kraam is verplicht.
  if v_kraam_id is not null then
    if coalesce(p_code,'') = '' then
      raise exception 'To clock out, tap the tag or type the code in the stall. Forgot? Ask the stand manager.' using errcode='P0002';
    end if;
    v_hash := public.tag_hash(p_code);
    select * into v_tag from public.nfc_tags t where t.code_hash = v_hash and t.ingetrokken_op is null;
    if found then
      if v_tag.kraam_id <> v_kraam_id then
        raise exception 'That is the tag of another stall. Use the tag at %.', coalesce(v_kraamnaam,'your stall') using errcode='P0002';
      end if;
      update public.nfc_tags set keer_gebruikt = keer_gebruikt + 1, laatst_gebruikt = now() where id = v_tag.id;
      v_ok := true;
    else
      v_in := upper(regexp_replace(p_code, '[^0-9A-Za-z]', '', 'g'));
      if public.kraam_dagcode(v_kraam_id) = v_in then v_ok := true; end if;
    end if;
    if not v_ok then
      raise exception 'That code is not right. Tap the tag or check the code in the stall for today.' using errcode='P0002';
    end if;

    -- Vergeten uit te klokken? Dan niet tot nu, maar tot het einde van de dienst.
    if now() > coalesce(public.mcr_dienst_eind(v_reg.id), v_reg.ingeklokt_op + interval '8 hours') + interval '2 hours' then
      select * into v_laat from public.mcr_vergeten_sluiten(v_reg.id, 'laat');
      if p_notitie is not null and p_notitie <> '' then
        update public.urenregistraties set notitie_pers = p_notitie where id = v_reg.id;
      end if;
      uren_id := v_reg.id; kraam := v_kraamnaam; minuten := v_laat.minuten;
      pauze := v_laat.pauze; uren := round(v_laat.minuten::numeric/60, 2);
      return next;
      return;
    end if;
  end if;

  v_min := greatest(0, (extract(epoch from (now() - v_reg.ingeklokt_op))/60)::int);
  v_drempel := public.vest_getal('pauze_drempel_uren', 6);
  if p_pauze is not null then
    v_pauze := least(600, greatest(0, p_pauze));
  elsif p_geen_pauze then
    v_pauze := 0;
  elsif v_min > v_drempel*60 then
    v_pauze := public.vest_getal('pauze_minuten', 30)::int;
  else
    v_pauze := 0;
  end if;
  v_pauze := least(v_pauze, v_min);

  update public.urenregistraties
     set uitgeklokt_op = now(),
         pauze_minuten = v_pauze,
         totaal_minuten = greatest(0, v_min - v_pauze),
         status = 'wacht',
         notitie_pers = coalesce(nullif(p_notitie,''), notitie_pers)
   where id = v_reg.id;

  uren_id := v_reg.id; kraam := v_kraamnaam; minuten := greatest(0, v_min - v_pauze);
  pauze := v_pauze; uren := round((greatest(0, v_min - v_pauze))::numeric/60, 2);
  return next;
end $function$;
alter function public.tag_uitklokken(text, boolean, text, integer) owner to app_rpc;
revoke all on function public.tag_uitklokken(text, boolean, text, integer) from public, anon;
grant execute on function public.tag_uitklokken(text, boolean, text, integer) to authenticated, service_role;

-- ── 5. Pauzevoorstel: bij een vergeten klok de lengte tot het einde van de dienst ──
create or replace function public.mcr_pauze_voorstel()
 returns TABLE(minuten integer, pauze integer, drempel_uren numeric, pauze_regel integer)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_uid uuid; v_reg record; v_min int; v_eind timestamptz;
begin
  if not public.mag_werken() then raise exception 'Your account has not been approved yet.' using errcode='P0002'; end if;
  v_uid := public.huidige_gebruiker();
  select * into v_reg from public.urenregistraties u
   where u.gebruiker_id = v_uid and u.uitgeklokt_op is null
   order by u.ingeklokt_op desc limit 1;
  if not found then return; end if;
  v_eind := now();
  if exists (select 1 from public.klussen kl where kl.id = v_reg.klus_id and kl.kraam_id is not null) then
    v_eind := coalesce(public.mcr_dienst_eind(v_reg.id), v_reg.ingeklokt_op + interval '8 hours');
    if now() <= v_eind + interval '2 hours' then v_eind := now(); end if;
  end if;
  v_min := greatest(0, (extract(epoch from (v_eind - v_reg.ingeklokt_op))/60)::int);
  drempel_uren := public.vest_getal('pauze_drempel_uren', 6);
  pauze_regel := public.vest_getal('pauze_minuten', 30)::int;
  minuten := v_min;
  pauze := case when v_min > drempel_uren*60 then pauze_regel else 0 end;
  return next;
end $function$;
alter function public.mcr_pauze_voorstel() owner to app_rpc;
revoke all on function public.mcr_pauze_voorstel() from public, anon;
grant execute on function public.mcr_pauze_voorstel() to authenticated, service_role;

-- ── 6. Klokstatus voor het inklokscherm ───────────────────────────
-- Alles van mcr_status, plus het einde van de dienst en of de klok "vergeten" is
-- (later dan einde + 2 uur) of van een eerdere dag is (Londense tijd).
-- Nieuwe naam omdat het een ander soort antwoord geeft (jsonb).
create or replace function public.mcr_klok_status()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare r record; v_eind timestamptz; v_schatting timestamptz; v_tz text := 'Europe/London';
begin
  select * into r from public.mcr_status() limit 1;
  if r.uren_id is not null then
    select coalesce(v.tijdzone, 'Europe/London') into v_tz
      from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
      left join public.kramen k on k.id = kl.kraam_id
      left join public.vestigingen v on v.code = k.vestiging
     where u.id = r.uren_id;
    v_tz := coalesce(v_tz, 'Europe/London');
    if exists (select 1 from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
                where u.id = r.uren_id and kl.kraam_id is not null) then
      v_eind := public.mcr_dienst_eind(r.uren_id);
      v_schatting := coalesce(v_eind, r.ingeklokt_op + interval '8 hours');
    end if;
  end if;
  return jsonb_build_object(
    'uren_id', r.uren_id, 'kraam', r.kraam, 'ingeklokt_op', r.ingeklokt_op, 'minuten', r.minuten,
    'volgende_datum', r.volgende_datum, 'volgende_kraam', r.volgende_kraam, 'volgende_start', r.volgende_start,
    'vandaag', r.vandaag,
    'dienst_eind', v_eind,
    'eind_schatting', v_schatting,
    'vergeten', coalesce(v_schatting is not null and now() > v_schatting + interval '2 hours', false),
    'vorige_dag', coalesce(r.ingeklokt_op is not null
                  and (r.ingeklokt_op at time zone v_tz)::date < (now() at time zone v_tz)::date, false));
end $function$;
alter function public.mcr_klok_status() owner to app_rpc;
revoke all on function public.mcr_klok_status() from public, anon;
grant execute on function public.mcr_klok_status() to authenticated, service_role;

-- ── 7. Zelf een vergeten klok afsluiten (zonder code) ─────────────
-- Kan alleen als de dienst al 2 uur voorbij is; de eindtijd wordt dan het
-- einde van de dienst, nooit "nu". De manager en Bram zien de notitie.
create or replace function public.mcr_vergeten_uitklokken()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid; v_reg record; v_uit record;
begin
  if not public.mag_werken() then
    raise exception 'Your account has not been approved yet. You can fill in your own details in the meantime.' using errcode='P0002';
  end if;
  v_uid := public.huidige_gebruiker();
  if v_uid is null then raise exception 'niet ingelogd'; end if;
  select u.* into v_reg from public.urenregistraties u
    join public.klussen kl on kl.id = u.klus_id
   where u.gebruiker_id = v_uid and u.uitgeklokt_op is null and kl.kraam_id is not null
   order by u.ingeklokt_op desc limit 1;
  if not found then
    raise exception 'You are not clocked in.' using errcode='P0002';
  end if;
  if now() <= coalesce(public.mcr_dienst_eind(v_reg.id), v_reg.ingeklokt_op + interval '8 hours') + interval '2 hours' then
    raise exception 'Your shift has not finished yet. Clock out at the stall with the tag or the code.' using errcode='P0002';
  end if;
  select * into v_uit from public.mcr_vergeten_sluiten(v_reg.id, 'app');
  return jsonb_build_object('uren_id', v_reg.id, 'kraam', v_uit.kraam, 'uitgeklokt_op', v_uit.uitgeklokt_op,
                            'pauze', v_uit.pauze, 'minuten', v_uit.minuten, 'uren', round(coalesce(v_uit.minuten,0)::numeric/60, 2));
end $function$;
alter function public.mcr_vergeten_uitklokken() owner to app_rpc;
revoke all on function public.mcr_vergeten_uitklokken() from public, anon;
grant execute on function public.mcr_vergeten_uitklokken() to authenticated, service_role;

-- ── 8. Inklokken: vergeten klok eerst afsluiten, dubbel tikken opvangen ──
-- Alles van de vorige versie blijft. Nieuw: (a) staat er nog een vergeten klok
-- van een eerdere dienst open (einde + 2 uur voorbij), dan wordt die afgesloten op
-- het einde van die dienst; (b) twee keer tegelijk inklokken geeft niet meer de
-- databasefout over "één_lopende_per_gebruiker" maar "You are already clocked in."
create or replace function public.tag_inklokken(p_code text)
 returns TABLE(uren_id uuid, kraam text, klus_id uuid, ingeklokt_op timestamp with time zone, shift_naam text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_hash text; v_tag record; v_kraam record; v_vandaag date;
  v_klus uuid; v_shift record; v_venster int; v_start timestamptz; v_uid uuid;
begin
  if not public.mag_werken() then raise exception 'Your account has not been approved yet. You can fill in your own details in the meantime.' using errcode='P0002'; end if;
  v_uid := public.huidige_gebruiker();
  if v_uid is null then raise exception 'niet ingelogd'; end if;

  v_hash := public.tag_hash(p_code);
  select * into v_tag from public.nfc_tags t
   where t.code_hash = v_hash and t.ingetrokken_op is null;
  if not found then
    raise exception 'This tag is not in use. Ask the stand manager to clock you in.' using errcode='P0002';
  end if;

  select * into v_kraam from public.kramen where id = v_tag.kraam_id;

  -- De dag volgens de tijdzone van de vestiging, niet die van de server.
  select (now() at time zone v.tijdzone)::date into v_vandaag
    from public.vestigingen v where v.code = v_kraam.vestiging;

  select k.id into v_klus from public.klussen k
   where k.kraam_id = v_kraam.id and k.datum = v_vandaag;
  if v_klus is null then
    raise exception 'There is no shift at this stall today.' using errcode='P0002';
  end if;

  if not exists (select 1 from public.klus_gebruikers kg
                  where kg.klus_id = v_klus and kg.gebruiker_id = v_uid) then
    raise exception 'You are not on the rota here today. Ask the stand manager.' using errcode='P0002';
  end if;

  -- Vergeten uit te klokken bij een vorige dienst? Eerst die afsluiten.
  perform public.mcr_vergeten_sluiten(u.id, 'inklok')
     from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
    where u.gebruiker_id = v_uid and u.uitgeklokt_op is null and kl.kraam_id is not null
      and now() > coalesce(public.mcr_dienst_eind(u.id), u.ingeklokt_op + interval '8 hours') + interval '2 hours';

  if exists (select 1 from public.urenregistraties u
              where u.gebruiker_id = v_uid and u.uitgeklokt_op is null) then
    raise exception 'You are already clocked in.' using errcode='P0002';
  end if;

  v_venster := public.vest_getal('inklok_venster_min', 30)::int;

  select s.* into v_shift from public.klus_shifts s
    join public.klus_gebruikers kg on kg.shift_id = s.id and kg.gebruiker_id = v_uid
   where s.klus_id = v_klus
   order by s.start_tijd limit 1;
  if v_shift.id is null then
    select s.* into v_shift from public.klus_shifts s where s.klus_id = v_klus order by s.start_tijd limit 1;
  end if;

  if v_shift.start_tijd is not null then
    select (v_vandaag + v_shift.start_tijd) at time zone v.tijdzone into v_start
      from public.vestigingen v where v.code = v_kraam.vestiging;
    if now() < v_start - make_interval(mins => v_venster) then
      raise exception 'It is too early to clock in. Your shift starts at %.', to_char(v_shift.start_tijd,'HH24:MI')
        using errcode='P0002';
    end if;
  end if;

  begin
    insert into public.urenregistraties (gebruiker_id, klus_id, ingeklokt_op, status, handmatig)
    values (v_uid, v_klus, now(), 'lopend', false)
    returning id, urenregistraties.ingeklokt_op into uren_id, ingeklokt_op;
  exception when unique_violation then
    raise exception 'You are already clocked in.' using errcode='P0002';
  end;

  update public.nfc_tags set keer_gebruikt = keer_gebruikt + 1, laatst_gebruikt = now()
   where id = v_tag.id;

  kraam := v_kraam.naam; klus_id := v_klus; shift_naam := v_shift.naam;
  return next;
end $function$;
alter function public.tag_inklokken(text) owner to app_rpc;
revoke all on function public.tag_inklokken(text) from public, anon;
grant execute on function public.tag_inklokken(text) to authenticated, service_role;

create or replace function public.code_inklokken(p_code text)
 returns TABLE(uren_id uuid, kraam text, klus_id uuid, ingeklokt_op timestamp with time zone, shift_naam text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := public.huidige_gebruiker(); v_kraam record; v_vandaag date;
  v_klus uuid; v_shift record; v_venster int; v_start timestamptz; v_in text;
begin
  if not public.mag_werken() then raise exception 'Your account has not been approved yet. You can fill in your own details in the meantime.' using errcode='P0002'; end if;
  if v_uid is null then raise exception 'niet ingelogd'; end if;
  v_in := upper(regexp_replace(coalesce(p_code,''), '[^0-9A-Za-z]', '', 'g'));

  select k.* into v_kraam from public.kramen k
    join public.gebruikers g on g.id = v_uid and g.vestiging = k.vestiging
   where k.actief and public.kraam_dagcode(k.id) = v_in
   limit 1;
  if not found then
    raise exception 'That code is not right. Check the code in the stall for today.' using errcode='P0002';
  end if;

  select (now() at time zone v.tijdzone)::date into v_vandaag
    from public.vestigingen v where v.code = v_kraam.vestiging;

  select k.id into v_klus from public.klussen k
   where k.kraam_id = v_kraam.id and k.datum = v_vandaag;
  if v_klus is null then
    raise exception 'There is no shift at this stall today.' using errcode='P0002';
  end if;
  if not exists (select 1 from public.klus_gebruikers kg
                  where kg.klus_id = v_klus and kg.gebruiker_id = v_uid) then
    raise exception 'You are not on the rota here today. Ask the stand manager.' using errcode='P0002';
  end if;

  -- Vergeten uit te klokken bij een vorige dienst? Eerst die afsluiten.
  perform public.mcr_vergeten_sluiten(u.id, 'inklok')
     from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
    where u.gebruiker_id = v_uid and u.uitgeklokt_op is null and kl.kraam_id is not null
      and now() > coalesce(public.mcr_dienst_eind(u.id), u.ingeklokt_op + interval '8 hours') + interval '2 hours';

  if exists (select 1 from public.urenregistraties u
              where u.gebruiker_id = v_uid and u.uitgeklokt_op is null) then
    raise exception 'You are already clocked in.' using errcode='P0002';
  end if;

  v_venster := public.vest_getal('inklok_venster_min', 30)::int;
  select s.* into v_shift from public.klus_shifts s
    join public.klus_gebruikers kg on kg.shift_id = s.id and kg.gebruiker_id = v_uid
   where s.klus_id = v_klus order by s.start_tijd limit 1;
  if v_shift.id is null then
    select s.* into v_shift from public.klus_shifts s where s.klus_id = v_klus order by s.start_tijd limit 1;
  end if;
  if v_shift.start_tijd is not null then
    select (v_vandaag + v_shift.start_tijd) at time zone v.tijdzone into v_start
      from public.vestigingen v where v.code = v_kraam.vestiging;
    if now() < v_start - make_interval(mins => v_venster) then
      raise exception 'It is too early to clock in. Your shift starts at %.', to_char(v_shift.start_tijd,'HH24:MI')
        using errcode='P0002';
    end if;
  end if;

  begin
    insert into public.urenregistraties (gebruiker_id, klus_id, ingeklokt_op, status, handmatig)
    values (v_uid, v_klus, now(), 'lopend', false)
    returning id, urenregistraties.ingeklokt_op into uren_id, ingeklokt_op;
  exception when unique_violation then
    raise exception 'You are already clocked in.' using errcode='P0002';
  end;

  kraam := v_kraam.naam; klus_id := v_klus; shift_naam := v_shift.naam;
  return next;
end  $function$;
alter function public.code_inklokken(text) owner to app_rpc;
revoke all on function public.code_inklokken(text) from public, anon;
grant execute on function public.code_inklokken(text) to authenticated, service_role;

-- ── 9. Automatisch uitklokken voor Manchester: 4 uur na het einde van de dienst ──
-- Draait naast uren_auto_uitklokken(24), die voor Nederland (en als vangnet)
-- ongewijzigd blijft. Alleen klokregistraties bij een kraam.
create or replace function public.mcr_auto_uitklokken(p_na_uren integer DEFAULT 4)
 returns TABLE(uren_id uuid, gebruiker uuid, uitgeklokt_op timestamp with time zone, pauze integer)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare r record; v record;
begin
  for r in
    select u.id, u.gebruiker_id
      from public.urenregistraties u
      join public.klussen kl on kl.id = u.klus_id
     where u.uitgeklokt_op is null and kl.kraam_id is not null
       and now() > coalesce(public.mcr_dienst_eind(u.id), u.ingeklokt_op + interval '8 hours')
                   + make_interval(hours => greatest(1, coalesce(p_na_uren, 4)))
     order by u.ingeklokt_op
  loop
    select * into v from public.mcr_vergeten_sluiten(r.id, 'auto', greatest(1, coalesce(p_na_uren, 4)));
    if v.uitgeklokt_op is not null then
      uren_id := r.id; gebruiker := r.gebruiker_id; uitgeklokt_op := v.uitgeklokt_op; pauze := v.pauze;
      return next;
    end if;
  end loop;
end $function$;
alter function public.mcr_auto_uitklokken(integer) owner to postgres;
revoke all on function public.mcr_auto_uitklokken(integer) from public, anon, authenticated;
grant execute on function public.mcr_auto_uitklokken(integer) to service_role;

-- Elk kwartier (op 7, 22, 37 en 52 minuten, zodat het niet samenvalt met de rest).
-- cron.schedule met een naam werkt een bestaande taak met die naam bij.
select cron.schedule('mcr-auto-uitklokken', '7,22,37,52 * * * *', $c$select public.mcr_auto_uitklokken(4);$c$);
