-- nl_ziek_verlof_crm.sql — 3 november 2026
-- Nederlandse kant: ziekmelding als volledige flow, CRM-opties met vervaldatum,
-- veilig restant meenemen en verlof per soort (wettelijk / bovenwettelijk).
--
-- Waarom:
--  1. Ziekmelden stuurde vanuit de app een push naar de beheerders, maar de
--     server weigert dat voor een gewone medewerker (alleen een beheerder mag
--     anderen een melding sturen). De fout werd weggeslikt: niemand wist het
--     en de medewerker bleef ingepland. Nu zet de server zelf de melding klaar
--     (push_wachtrij, soort 'nl_ziek') en ziet de planner het op het dashboard.
--  2. "Zet als optie" maakte eerst een klus en daarna de koppeling; ging het
--     tweede mis, dan bleef er een losse optie staan. Nu één serverfunctie,
--     met een vervaldatum en herinneringen.
--  3. Restant meenemen rekende altijd "vorig jaar" uit en overschreef het
--     beginsaldo. Nu: jaar kiezen, eerst een voorbeeld, alleen als het jaar
--     voorbij is, en een handmatig beginsaldo blijft staan.
--
-- Geen tabellen of functies worden weggehaald. Alles is create or replace of
-- "add column if not exists".

-- ════════════════════════════════════════════════════════════════════
-- 1. ZIEKMELDING
-- ════════════════════════════════════════════════════════════════════

-- Op welke klussen staat iemand op een dag? Met de tijden van zijn shift,
-- anders die van de klus. Alleen voor gebruik binnen andere functies.
create or replace function public.ziek_klussen_op(p_gebruiker uuid, p_datum date)
 returns table(klus_id uuid, naam text, van text, tot text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select k.id,
         coalesce(nullif(btrim(k.naam),''), nullif(btrim(k.food),''), 'Klus'),
         to_char(coalesce(s.start_tijd, k.start_tijd, k.vertrek_tijd, k.start_opbouw),'HH24:MI'),
         to_char(coalesce(s.eind_tijd, k.einde_klus, k.einde_feest, k.eind_tijd),'HH24:MI')
    from public.klus_gebruikers kg
    join public.klussen k on k.id = kg.klus_id
    left join public.klus_shifts s on s.id = kg.shift_id
   where kg.gebruiker_id = p_gebruiker
     and p_datum between k.datum and coalesce(k.datum_eind, k.datum)
   order by coalesce(s.start_tijd, k.start_tijd, k.vertrek_tijd, k.start_opbouw) nulls last, k.naam
$function$;
alter function public.ziek_klussen_op(uuid, date) owner to postgres;
revoke all on function public.ziek_klussen_op(uuid, date) from public, anon, authenticated;
grant execute on function public.ziek_klussen_op(uuid, date) to service_role;

-- Wie krijgt een ziekmelding? De beheerders van die vestiging (of van alle
-- vestigingen) die verlofmeldingen krijgen: hun rol heeft 'meld_verlof' aan
-- bij Dashboard per rol, of ze zijn administrator. Is dat niemand, dan alle
-- beheerders van de vestiging, zodat een melding nooit in het niets valt.
create or replace function public.ziek_ontvangers(p_vestiging text)
 returns table(id uuid)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with alle as (
    select g.id, g.beheer_rol
      from public.gebruikers g
     where g.rol = 'beheerder' and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null
       and (coalesce(g.alle_vestigingen,false) or coalesce(g.vestiging,'NL') = coalesce(p_vestiging,'NL'))
  ), planners as (
    select a.id from alle a
     where a.beheer_rol = 'administrator'
        or exists (select 1 from public.dashboard_rechten r
                    where r.beheer_rol = a.beheer_rol and r.aan and r.blok = 'meld_verlof')
  )
  select p.id from planners p
  union all
  select a.id from alle a where not exists (select 1 from planners)
$function$;
alter function public.ziek_ontvangers(text) owner to postgres;
revoke all on function public.ziek_ontvangers(text) from public, anon, authenticated;
grant execute on function public.ziek_ontvangers(text) to service_role;

-- meld_ziek: alles van vroeger blijft (zelfde controles, zelfde regel in
-- beschikbaarheid, 'stond al'), plus: de melding voor de planners gaat in de
-- pushwachtrij. Eigenaar postgres: hij moet beheerders kunnen bereiken die
-- de medewerker zelf niet mag zien.
create or replace function public.meld_ziek(p_datum date default current_date, p_notitie text default null::text)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid := public.huidige_gebruiker(); v_rol text; v_bestaat boolean;
        v_naam text; v_vest text; v_vandaag date; v_dag text; v_klussen text; v_eerste uuid; v_regel text;
begin
  if v_id is null then raise exception 'Niet ingelogd.'; end if;
  select public.mijn_rol() into v_rol;
  if v_rol is null then raise exception 'Je account is nog niet vrijgegeven.' using errcode='P0002'; end if;

  select g.naam, coalesce(g.vestiging,'NL') into v_naam, v_vest from public.gebruikers g where g.id = v_id;
  v_vandaag := (now() at time zone case when v_vest = 'MCR' then 'Europe/London' else 'Europe/Amsterdam' end)::date;
  p_datum := coalesce(p_datum, v_vandaag);

  if p_datum > v_vandaag + 1 then
    raise exception 'Je kunt je alleen voor vandaag of morgen ziek melden.' using errcode='P0002';
  end if;

  select exists(
    select 1 from public.beschikbaarheid b
    where b.gebruiker_id = v_id and b.verlofsoort = 'ziek'
      and p_datum between b.datum_start and coalesce(b.datum_eind,b.datum_start)
  ) into v_bestaat;
  if v_bestaat then return 'stond al'; end if;

  perform set_config('app.ziekmelding','1',true);
  insert into public.beschikbaarheid
    (gebruiker_id, datum_start, datum_eind, soort, verlofsoort, status, reden)
  values (v_id, p_datum, p_datum, 'onbeschikbaar', 'ziek', 'goedgekeurd',
          coalesce(nullif(btrim(p_notitie),''), 'Ziekmelding via de app'));
  perform set_config('app.ziekmelding','0',true);

  -- Melding voor de planners: "Jan heeft zich ziek gemeld voor vandaag —
  -- staat op: Bruiloft Utrecht 14:00–22:00". Verstuurd door de herinneringen-
  -- functie (elke 5 minuten) via push_wachtrij_bundels.
  if p_datum >= v_vandaag then
    v_dag := case when p_datum = v_vandaag then 'vandaag' else 'morgen' end;
    select string_agg(z.naam || coalesce(' ' || z.van || coalesce('–' || z.tot, ''), ''), '; '),
           (array_agg(z.klus_id))[1]
      into v_klussen, v_eerste
      from public.ziek_klussen_op(v_id, p_datum) z;
    v_regel := coalesce(nullif(btrim(v_naam),''), 'Een medewerker') || ' heeft zich ziek gemeld voor ' || v_dag || ' — '
            || case when v_klussen is null then 'staat niet ingepland.' else 'staat op: ' || v_klussen end;
    insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
    select o.id, 'nl_ziek', v_eerste, v_regel
      from public.ziek_ontvangers(v_vest) o
     where o.id <> v_id;
  end if;

  return 'gemeld';
end $function$;
alter function public.meld_ziek(date, text) owner to postgres;
revoke all on function public.meld_ziek(date, text) from public, anon;
grant execute on function public.meld_ziek(date, text) to authenticated, service_role;

-- Dashboard: wie is vandaag of morgen ziek en staat nog op een klus? Eén regel
-- per klus. Mensen zonder klus alleen als de melding van de laatste 24 uur is
-- (anders staat iemand die lang ziek is er elke dag weer). Verdwijnt vanzelf
-- zodra de planner hem van de klus haalt.
create or replace function public.dashboard_ziek()
 returns table(beschikbaarheid_id uuid, gebruiker_id uuid, naam text, telefoon text, datum date,
               gemeld_op timestamptz, klus_id uuid, klus_naam text, van text, tot text)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
declare v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date;
begin
  if not public.is_beheerder() then return; end if;
  return query
  select b.id, g.id, g.naam, g.telefoon, d.dag, b.aangemaakt_op, z.klus_id, z.naam, z.van, z.tot
    from public.beschikbaarheid b
    join public.gebruikers g on g.id = b.gebruiker_id
    cross join lateral (
      select x::date as dag
        from generate_series(greatest(b.datum_start, v_vandaag)::timestamp,
                             least(coalesce(b.datum_eind, b.datum_start), v_vandaag + 1)::timestamp,
                             interval '1 day') x
    ) d
    left join lateral public.ziek_klussen_op(g.id, d.dag) z on true
   where b.verlofsoort = 'ziek' and b.status = 'goedgekeurd' and b.soort = 'onbeschikbaar'
     and coalesce(b.datum_eind, b.datum_start) >= v_vandaag and b.datum_start <= v_vandaag + 1
     and public.vest_ok(coalesce(g.vestiging,'NL'))
     and (z.klus_id is not null or b.aangemaakt_op > now() - interval '24 hours')
   order by d.dag, g.naam, z.van nulls last;
end $function$;
alter function public.dashboard_ziek() owner to postgres;
revoke all on function public.dashboard_ziek() from public, anon;
grant execute on function public.dashboard_ziek() to authenticated, service_role;

-- Rode bolletjes: alles van vroeger, plus 'ziek' onder meld_verlof: zoveel
-- ziekmeldingen (vandaag/morgen) waarbij iemand nog op een klus staat. Telt
-- vanzelf af zodra de planner vervanging heeft geregeld. Bolletje op Dashboard.
create or replace function public.meldingen_voor(p_uid uuid)
 returns table(soort text, aantal integer, pagina text)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
#variable_conflict use_column
declare g record; v_aan text[]; v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date;
begin
  select x.rol, x.beheer_rol, coalesce(x.goedgekeurd,false) ok into g from public.gebruikers x where x.id = p_uid and x.gearchiveerd_op is null;
  if not found or not g.ok then return; end if;

  if g.rol = 'beheerder' then
    v_aan := array(select r.blok from public.dashboard_rechten r where r.beheer_rol = g.beheer_rol and r.aan and r.blok like 'meld_%');

    if 'meld_aanmeldingen' = any(v_aan) then
      return query select 'aanmeldingen'::text, count(*)::int, 'planning-beheer'::text
        from public.klus_aanmeldingen a join public.klussen k on k.id = a.klus_id
       where a.status = 'aangemeld' and k.datum >= v_vandaag and coalesce(k.vestiging,'NL') = 'NL';
    end if;
    if 'meld_verlof' = any(v_aan) then
      return query select 'verlof'::text, count(*)::int, 'beschikbaarheid-beheer'::text
        from public.beschikbaarheid b join public.gebruikers u on u.id = b.gebruiker_id
       where b.soort = 'onbeschikbaar' and b.status = 'wacht' and coalesce(u.vestiging,'NL') = 'NL';
      return query select 'ziek'::text, count(*)::int, 'dashboard'::text
        from public.beschikbaarheid b
        join public.gebruikers u on u.id = b.gebruiker_id
        cross join lateral (
          select x::date as dag
            from generate_series(greatest(b.datum_start, v_vandaag)::timestamp,
                                 least(coalesce(b.datum_eind, b.datum_start), v_vandaag + 1)::timestamp,
                                 interval '1 day') x
        ) d
        cross join lateral public.ziek_klussen_op(b.gebruiker_id, d.dag) z
       where b.verlofsoort = 'ziek' and b.status = 'goedgekeurd' and b.soort = 'onbeschikbaar'
         and coalesce(b.datum_eind, b.datum_start) >= v_vandaag and b.datum_start <= v_vandaag + 1
         and coalesce(u.vestiging,'NL') = 'NL';
    end if;
    if 'meld_uren' = any(v_aan) then
      return query select 'uren'::text, count(*)::int, 'uren-beheer'::text
        from public.urenregistraties u join public.gebruikers x on x.id = u.gebruiker_id
       where u.status = 'wacht' and coalesce(x.vestiging,'NL') = 'NL';
    end if;
    if 'meld_taken' = any(v_aan) then
      return query select 'taken'::text, count(*)::int, 'beheer'::text
        from public.taak_regels r join public.taken t on t.id = r.taak_id
       where r.status = 'afgevinkt' and t.goedkeuring_nodig and coalesce(t.vestiging,'NL') = 'NL';
    end if;
    if 'meld_accounts' = any(v_aan) then
      return query select 'accounts'::text, count(*)::int, 'accounts'::text
        from public.gebruikers x where coalesce(x.goedgekeurd, true) = false and x.gearchiveerd_op is null;
    end if;
    if 'meld_tekorten' = any(v_aan) then
      return query select 'tekorten'::text, count(*)::int, 'dashboard'::text
        from public.bestelregels r join public.bestellingen b on b.id = r.bestelling_id
       where b.vestiging = 'NL' and public.bestel_tekort_actief(r, b);
    end if;
    if 'meld_mcr' = any(v_aan) then
      return query select 'mcr_aanmeldingen'::text, count(*)::int, 'mcr:shifts'::text
        from public.klus_aanmeldingen a
        join public.klus_shifts s on s.id = a.shift_id
        join public.klussen kl on kl.id = s.klus_id
       where a.status = 'aangemeld' and kl.vestiging = 'MCR'
         and kl.datum >= (now() at time zone 'Europe/London')::date
         and not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = s.id and kg.gebruiker_id = a.gebruiker_id);
    end if;
  elsif g.rol in ('part-timer','full-timer') then
    return query select 'open_klussen'::text, count(*)::int, 'open-klussen'::text
      from public.klussen k
     where coalesce(k.vestiging,'NL') = coalesce((select x.vestiging from public.gebruikers x where x.id = p_uid),'NL')
       and k.datum between v_vandaag and v_vandaag + 45
       and coalesce(k.is_optie,false) = false and k.categorie not in ('intern','franklins')
       and not exists (select 1 from public.klus_gebruikers kg where kg.klus_id = k.id and kg.gebruiker_id = p_uid)
       and not exists (select 1 from public.klus_aanmeldingen a where a.klus_id = k.id and a.gebruiker_id = p_uid)
       and not exists (select 1 from public.klus_reacties r where r.klus_id = k.id and r.gebruiker_id = p_uid and r.reactie is not null)
       and not exists (select 1 from public.beschikbaarheid b where b.gebruiker_id = p_uid and b.soort = 'onbeschikbaar'
                         and b.status in ('goedgekeurd','wacht') and k.datum between b.datum_start and coalesce(b.datum_eind, b.datum_start))
       and (
         (exists (select 1 from public.klus_shifts s where s.klus_id = k.id)
           and exists (select 1 from public.klus_shifts s where s.klus_id = k.id and coalesce(s.personeel_nodig,0) >
                (select count(*) from public.klus_gebruikers kg where kg.shift_id = s.id) + (select count(*) from public.klus_losse_personen l where l.shift_id = s.id)))
         or (not exists (select 1 from public.klus_shifts s where s.klus_id = k.id)
           and coalesce(k.personeel_nodig,0) > (select count(*) from public.klus_gebruikers kg where kg.klus_id = k.id) + (select count(*) from public.klus_losse_personen l where l.klus_id = k.id))
       );
  elsif g.rol = 'hal' then
    return query select 'bestellingen'::text, count(*)::int, 'taken'::text
      from public.bestellingen b where b.vestiging = 'NL' and b.status in ('verstuurd','wordt_gepakt');
  elsif g.rol = 'manager-franklins' then
    return query select 'tekorten'::text, count(*)::int, 'bestellen'::text
      from public.bestelregels r join public.bestellingen b on b.id = r.bestelling_id
     where b.vestiging = 'NL' and public.bestel_tekort_actief(r, b);
  end if;
end $function$;

-- ════════════════════════════════════════════════════════════════════
-- 2. CRM: OPTIE MET VERVALDATUM
-- ════════════════════════════════════════════════════════════════════

-- De vervaldatum staat bij de klus zelf, zodat hij ook in de planning (klus
-- openen) te zien is en er maar één plek is waar hij staat.
alter table public.klussen add column if not exists optie_tot date;

-- "Zet als optie": klus maken én koppelen in één keer. Lukt een stap niet,
-- dan gebeurt er niets. Twee keer tikken of opnieuw proberen maakt geen
-- tweede optie: heeft de aanvraag al een klus, dan wordt alleen de
-- vervaldatum bijgewerkt.
create or replace function public.crm_maak_optie(p_aanvraag uuid, p_tot date default null)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare a public.crm_aanvragen%rowtype; v_klus uuid; v_tot date; v_naam text; v_cap text;
        v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date;
begin
  if not public.crm_mag() then raise exception 'Je hebt geen toegang tot de aanvragen.' using errcode='P0002'; end if;
  select * into a from public.crm_aanvragen where id = p_aanvraag for update;
  if not found then raise exception 'Deze aanvraag bestaat niet meer.' using errcode='P0002'; end if;
  if a.datum is null then raise exception 'Vul eerst een datum in.' using errcode='P0002'; end if;
  v_tot := coalesce(p_tot, v_vandaag + 7);
  if v_tot < v_vandaag then raise exception 'De vervaldatum ligt in het verleden.' using errcode='P0002'; end if;

  -- Al een klus gekoppeld? Dan niets nieuws maken.
  if a.klus_id is not null and exists (select 1 from public.klussen k where k.id = a.klus_id) then
    update public.klussen set optie_tot = v_tot where id = a.klus_id and is_optie;
    return a.klus_id;
  end if;

  v_cap := nullif(btrim(coalesce(a.gelegenheid,'')),'');
  v_cap := upper(left(v_cap,1)) || substr(v_cap,2);
  v_naam := concat_ws(' ', v_cap, nullif(btrim(coalesce(a.contact_naam,'')),''),
                      case when nullif(btrim(coalesce(a.plaats,'')),'') is not null then '· ' || btrim(a.plaats) end);
  insert into public.klussen (naam, datum, notitie, personen, personeel_nodig, food, adres, contactpersoon, telefoon,
                              klant, categorie, start_feest, einde_feest, is_optie, optie_tot, vestiging)
  values (coalesce(nullif(v_naam,''),'Aanvraag'), a.datum,
          concat_ws(E'\n',
            'Uit CRM' || coalesce(' · ref. ' || nullif(a.ref,''),'') || coalesce(' · formulier #' || nullif(a.formulier_nr,''),''),
            'Food: ' || nullif(a.soort_food,''), nullif(a.wensen,''), 'Mail: ' || nullif(a.email,'')),
          coalesce(a.gasten,0), 0, coalesce(a.soort_food,''), coalesce(a.adres,''), coalesce(a.contact_naam,''),
          coalesce(a.telefoon,''), nullif(a.contact_naam,''), 'klus', a.start_tijd, a.eind_tijd, true, v_tot,
          coalesce(a.vestiging,'NL'))
  returning id into v_klus;

  update public.crm_aanvragen
     set klus_id = v_klus,
         status = case when status in ('nieuw','vragen','offerte') then 'optie' else status end
   where id = p_aanvraag;
  insert into public.crm_berichten (aanvraag_id, soort, samenvatting)
  values (p_aanvraag, 'status', 'Als optie in de planning gezet, tot ' || to_char(v_tot,'DD-MM-YYYY'));
  return v_klus;
end $function$;
alter function public.crm_maak_optie(uuid, date) owner to postgres;
revoke all on function public.crm_maak_optie(uuid, date) from public, anon;
grant execute on function public.crm_maak_optie(uuid, date) to authenticated, service_role;

-- Datum of tijden van een aanvraag gewijzigd? Dan schuift een gekoppelde
-- OPTIE mee (een bevestigde klus niet: daar staat misschien al personeel op;
-- het CRM-scherm waarschuwt dan). Tijden alleen als de klus nog de oude
-- tijden uit de aanvraag had.
create or replace function public.crm_aanvraag_optie_mee()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.klus_id is null then return null; end if;
  update public.klussen k
     set datum       = case when new.datum is not null then new.datum else k.datum end,
         datum_eind  = case when new.datum is not null and old.datum is not null and k.datum_eind is not null
                            then k.datum_eind + (new.datum - old.datum) else k.datum_eind end,
         start_feest = case when k.start_feest is not distinct from old.start_tijd then new.start_tijd else k.start_feest end,
         einde_feest = case when k.einde_feest is not distinct from old.eind_tijd then new.eind_tijd else k.einde_feest end
   where k.id = new.klus_id and k.is_optie
     and (new.datum is distinct from old.datum or new.start_tijd is distinct from old.start_tijd
          or new.eind_tijd is distinct from old.eind_tijd);
  return null;
end $function$;
alter function public.crm_aanvraag_optie_mee() owner to postgres;
revoke all on function public.crm_aanvraag_optie_mee() from public, anon, authenticated;

create or replace trigger crm_aanvragen_optie_mee
  after update of datum, start_tijd, eind_tijd on public.crm_aanvragen
  for each row execute function public.crm_aanvraag_optie_mee();

-- Herinneringen: 3 dagen voor de vervaldatum en op de dag zelf, aan de
-- eigenaar van de aanvraag (of, zonder eigenaar, iedereen met CRM-toegang).
-- Gaat via de pushwachtrij (soort 'nl_crm_optie'), één keer per dag per optie.
create or replace function public.crm_opties_herinneren()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_vandaag date := (now() at time zone 'Europe/Amsterdam')::date; n int;
begin
  with opties as (
    select a.id, a.eigenaar_id, k.id as klus_id, k.optie_tot,
           coalesce(nullif(btrim(a.contact_naam),''), nullif(btrim(k.naam),''), 'een klant') as klant
      from public.crm_aanvragen a
      join public.klussen k on k.id = a.klus_id
     where k.is_optie and k.optie_tot in (v_vandaag, v_vandaag + 3)
       and a.status not in ('bevestigd','verloren')
  ), crm as (
    select t.gebruiker_id as id
      from public.crm_toegang t join public.gebruikers g on g.id = t.gebruiker_id
     where g.rol = 'beheerder' and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null
  ), ontv as (
    select o.*, c.id as gid
      from opties o join crm c on c.id = o.eigenaar_id
    union all
    select o.*, c.id
      from opties o cross join crm c
     where o.eigenaar_id is null or not exists (select 1 from crm c2 where c2.id = o.eigenaar_id)
  )
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
  select x.gid, 'nl_crm_optie', x.klus_id,
         'Optie voor ' || x.klant || case when x.optie_tot = v_vandaag then ' loopt vandaag af.'
                                          else ' loopt over 3 dagen af (' || to_char(x.optie_tot,'DD-MM') || ').' end
    from ontv x
   where not exists (select 1 from public.push_wachtrij w
                      where w.soort = 'nl_crm_optie' and w.klus_id = x.klus_id and w.gebruiker_id = x.gid
                        and w.aangemaakt_op > now() - interval '20 hours');
  get diagnostics n = row_count;
  return n;
end $function$;
alter function public.crm_opties_herinneren() owner to postgres;
revoke all on function public.crm_opties_herinneren() from public, anon, authenticated;
grant execute on function public.crm_opties_herinneren() to service_role;

-- Elke ochtend om 7:12 UTC (8:12 of 9:12 Nederlandse tijd) klaarzetten. De
-- herinneringen-functie verstuurt de wachtrij vanaf 8 uur Engelse tijd.
select cron.schedule('crm-opties-herinneren', '12 7 * * *', $$select public.crm_opties_herinneren();$$);
