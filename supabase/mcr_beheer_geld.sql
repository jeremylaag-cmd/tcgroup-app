-- Manchester-beheer (Bram): uren, betaalrondes, uitbetaling en loonkosten (3 nov 2026)
--
-- Waarom:
-- * Betaalrondes telden ook Nederlandse uren mee: rondes werden alleen op datum
--   gekoppeld. Nu alleen klussen met een kraam in de vestiging van de ronde.
-- * Bram zit vaak in Nederland (telefoon 1 uur voor). Tijden typen en tonen gaat
--   nu in Britse tijd: de app stuurt datum-loos 'HH:MM' en de server rekent om
--   met de tijdzone van de vestiging van de klus (Europe/London).
-- * "Akkoord" na het aanpassen van tijden in dezelfde rij: tijden + akkoord in
--   een keer (mcr_uur_tijden_londen met p_akkoord).
-- * "Vraag" (status 'afgewezen') verdween uit beeld. Nu een eigen lijst
--   (mcr_uren_vraag) en terugzetten (mcr_uur_terug); in rondes telt het als open.
-- * Aandacht > Vastzetten: pauze volgens de instellingen (pas vanaf x uur) en
--   een al ingevulde pauze blijft staan; eind voor begin geeft een foutmelding.
-- * Uitbetaling per ronde: bruto, boetes, kledingborg (in en terug), netto en
--   bankgegevens; vastzetten legt per persoon vast wat is ingehouden
--   (mcr_ronde_verrekening), zodat borg en boetes nooit twee keer worden
--   ingehouden en netto nooit onder 0 komt.
-- * Geplande loonkosten tegen de forecast (mcr_plan_loon), drempel instelbaar.
-- * myPOS: terugbetalingen komen als negatief bedrag binnen; pin_import telt die
--   niet meer als bon en leest de prijzen van de vestiging zelf (niet die van
--   de beheerder, die in NL staat).
--
-- De crew-factuur (mcr_factuur_maken) is bewust NIET aangepast.
-- Let op: in dit bestand staan de woorden voor weghalen niet; de migratietool
-- annuleert zulke bestanden.

-- ── 1. Betaalrondes: alleen uren van de kramen in die vestiging ───────────
create or replace function public.mcr_rondes()
returns table(ronde_id uuid, nummer integer, periode_van date, periode_tot date, betaaldatum date,
              notitie text, afgelopen boolean, mensen integer, uren numeric, bedrag numeric,
              facturen integer, ontvangen integer, wachtende_uren numeric)
language sql stable security definer set search_path to 'public'
as $function$  select * from (
  select b.id, b.nummer, b.periode_van, b.periode_tot, b.betaaldatum, b.notitie,
         (b.periode_tot < (now() at time zone public.mijn_tijdzone())::date),
         (select count(distinct u.gebruiker_id)::int from public.urenregistraties u
            join public.klussen kl on kl.id=u.klus_id
           where kl.kraam_id is not null and kl.vestiging = b.vestiging
             and kl.datum between b.periode_van and b.periode_tot),
         coalesce((select round(sum(u.totaal_minuten)::numeric/60,2) from public.urenregistraties u
            join public.klussen kl on kl.id=u.klus_id
           where u.status='goedgekeurd' and kl.kraam_id is not null and kl.vestiging = b.vestiging
             and kl.datum between b.periode_van and b.periode_tot),0),
         coalesce((select round(sum(u.totaal_minuten::numeric/60*coalesce(g.uurloon,0)),2)
            from public.urenregistraties u
            join public.klussen kl on kl.id=u.klus_id
            join public.gebruikers g on g.id=u.gebruiker_id
           where u.status='goedgekeurd' and kl.kraam_id is not null and kl.vestiging = b.vestiging
             and kl.datum between b.periode_van and b.periode_tot),0),
         (select count(*)::int from public.facturen f where f.ronde_id=b.id),
         (select count(*)::int from public.facturen f where f.ronde_id=b.id and f.ontvangen_op is not null),
         -- Open = nog te accorderen, nog bezig, of met een vraag teruggezet.
         coalesce((select round(sum(coalesce(u.totaal_minuten,0))::numeric/60,2) from public.urenregistraties u
            join public.klussen kl on kl.id=u.klus_id
           where u.status in ('lopend','wacht','afgewezen') and kl.kraam_id is not null and kl.vestiging = b.vestiging
             and kl.datum between b.periode_van and b.periode_tot),0)
    from public.betaalrondes b
   where public.vest_ok(b.vestiging) and public.in_actieve_vestiging(b.vestiging)
   order by b.nummer
 ) _rijen where public.mag_kraambeheer()  $function$;

create or replace function public.mcr_ronde_mensen(p_ronde uuid)
returns table(gebruiker_id uuid, naam text, uren numeric, wachtend numeric, bedrag numeric, iban text,
              factuur_id uuid, factuur_nummer text, gedownload_op timestamptz, ontvangen_op timestamptz,
              betaald_op timestamptz)
language sql stable security definer set search_path to 'public'
as $function$  select * from (
  select g.id, g.naam,
         coalesce(round(sum(case when u.status='goedgekeurd' then u.totaal_minuten else 0 end)::numeric/60,2),0),
         coalesce(round(sum(case when u.status in ('lopend','wacht','afgewezen') then coalesce(u.totaal_minuten,0) else 0 end)::numeric/60,2),0),
         coalesce(round(sum(case when u.status='goedgekeurd' then u.totaal_minuten else 0 end)::numeric/60
                        * coalesce(g.uurloon,0),2),0),
         g.iban, f.id, f.nummer, f.gedownload_op, f.ontvangen_op, f.betaald_op
    from public.betaalrondes b
    join public.klussen kl on kl.datum between b.periode_van and b.periode_tot
                          and kl.kraam_id is not null and kl.vestiging = b.vestiging
    join public.urenregistraties u on u.klus_id = kl.id
    join public.gebruikers g on g.id = u.gebruiker_id
    left join public.facturen f on f.ronde_id = b.id and f.gebruiker_id = g.id
   where b.id = p_ronde
   group by g.id, g.naam, g.iban, g.uurloon, f.id, f.nummer, f.gedownload_op, f.ontvangen_op, f.betaald_op
   order by g.naam
 ) _rijen where public.mag_kraambeheer()  $function$;

-- ── 2/3. Tijden in Britse tijd; tijden aanpassen en meteen akkoord ─────────
-- p_in / p_uit als 'HH:MM' in de tijd van de vestiging. De datum is de lokale
-- datum van het inklokken (meestal de klusdatum). Ligt de eindtijd niet na de
-- begintijd, dan moet p_volgende_dag aan staan (nachtdienst) — anders een fout.
create or replace function public.mcr_uur_tijden_londen(p_uren uuid, p_in text, p_uit text, p_pauze integer,
                                                         p_volgende_dag boolean default false,
                                                         p_akkoord boolean default false)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare v_r record; v_tz text; v_dag date; v_tin time; v_tuit time;
        v_in timestamptz; v_uit timestamptz; v_min int; v_pauze int;
begin
  if not public.is_beheerder() then raise exception 'Alleen een beheerder kan tijden aanpassen.' using errcode='P0002'; end if;
  select u.id, u.ingeklokt_op, u.pauze_minuten, u.status, kl.datum, kl.vestiging
    into v_r
    from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
   where u.id = p_uren;
  if v_r.id is null then raise exception 'Onbekende registratie.' using errcode='P0002'; end if;
  if nullif(btrim(coalesce(p_in,'')),'') is null or nullif(btrim(coalesce(p_uit,'')),'') is null then
    raise exception 'Vul een begin- en eindtijd in.' using errcode='P0002';
  end if;
  begin v_tin := p_in::time; v_tuit := p_uit::time;
  exception when others then raise exception 'Die tijd begrijp ik niet. Gebruik bv. 09:30.' using errcode='P0002'; end;
  v_tz  := coalesce((select v.tijdzone from public.vestigingen v where v.code = v_r.vestiging), 'Europe/London');
  v_dag := coalesce((v_r.ingeklokt_op at time zone v_tz)::date, v_r.datum);
  v_in  := (v_dag + v_tin) at time zone v_tz;
  v_uit := (v_dag + v_tuit + case when coalesce(p_volgende_dag,false) then interval '1 day' else interval '0' end) at time zone v_tz;
  if v_uit <= v_in then raise exception 'De eindtijd moet na de begintijd liggen.' using errcode='P0002'; end if;
  if v_uit - v_in > interval '16 hours' then raise exception 'Dat is langer dan 16 uur. Klopt de tijd?' using errcode='P0002'; end if;
  v_pauze := greatest(0, coalesce(p_pauze, v_r.pauze_minuten, 0));
  v_min := (extract(epoch from (v_uit - v_in))/60)::int;
  if v_pauze >= v_min then raise exception 'De pauze is langer dan de dienst.' using errcode='P0002'; end if;
  update public.urenregistraties
     set ingeklokt_op = v_in, uitgeklokt_op = v_uit, pauze_minuten = v_pauze,
         totaal_minuten = greatest(0, v_min - v_pauze),
         status = case when status = 'lopend' then 'wacht' else status end
   where id = p_uren;
  if coalesce(p_akkoord,false) then
    update public.urenregistraties set status = 'goedgekeurd', notitie_beh = null where id = p_uren;
  end if;
end $function$;

-- Akkoord / vraag: nu een duidelijke fout als er niets kon gebeuren (stond
-- stil niets te doen bij een registratie zonder eindtijd).
create or replace function public.mcr_uur_akkoord(p_uren uuid, p_akkoord boolean, p_notitie text default null)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare n int;
begin
  if not public.is_beheerder() then raise exception 'alleen een beheerder'; end if;
  update public.urenregistraties
     set status = case when p_akkoord then 'goedgekeurd' else 'afgewezen' end,
         notitie_beh = nullif(public.schoon_kort(p_notitie),'')
   where id = p_uren and uitgeklokt_op is not null;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'Deze registratie heeft nog geen eindtijd. Vul eerst de eindtijd in.' using errcode='P0002';
  end if;
end $function$;

-- ── 4. Uitgezocht / wacht op antwoord ─────────────────────────────────────
create or replace function public.mcr_uren_vraag()
returns table(uren_id uuid, gebruiker_id uuid, naam text, telefoon text, datum date, kraam text, kleur text,
              ingeklokt_op timestamptz, uitgeklokt_op timestamptz, pauze integer, uren numeric, bedrag numeric,
              vraag text, notitie_pers text)
language sql stable security definer set search_path to 'public'
as $function$  select * from (
  select u.id, g.id, g.naam, g.telefoon, kl.datum, coalesce(kr.naam, kl.naam), coalesce(kr.kleur,'#6B6A66'),
         u.ingeklokt_op, u.uitgeklokt_op, coalesce(u.pauze_minuten,0),
         round(coalesce(u.totaal_minuten,0)::numeric/60,2),
         round(coalesce(u.totaal_minuten,0)::numeric/60*coalesce(g.uurloon,0),2),
         u.notitie_beh, u.notitie_pers
    from public.urenregistraties u
    join public.klussen kl on kl.id = u.klus_id
    join public.gebruikers g on g.id = u.gebruiker_id
    left join public.kramen kr on kr.id = kl.kraam_id
   where kl.kraam_id is not null and u.status = 'afgewezen'
     and public.vest_ok(kl.vestiging) and public.in_actieve_vestiging(kl.vestiging)
   order by kl.datum, g.naam
 ) _rijen where public.mag_kraambeheer()  $function$;

create or replace function public.mcr_uur_terug(p_uren uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare n int;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  update public.urenregistraties u
     set status = case when u.uitgeklokt_op is null then 'lopend' else 'wacht' end
    from public.klussen kl
   where kl.id = u.klus_id and u.id = p_uren and u.status = 'afgewezen' and kl.kraam_id is not null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Deze registratie staat niet (meer) bij Uitgezocht.' using errcode='P0002'; end if;
end $function$;

-- ── 5. Aandacht > Vastzetten ──────────────────────────────────────────────
-- Eindtijd als 'HH:MM' Britse tijd. Pauze: een al ingevulde pauze blijft staan;
-- anders pas pauze vanaf pauze_drempel_uren (standaard 6) met pauze_minuten.
create or replace function public.mcr_uur_vastzetten(p_uren uuid, p_uit text, p_volgende_dag boolean default false)
returns integer
language plpgsql security definer set search_path to 'public'
as $function$
declare v_r record; v_tz text; v_dag date; v_tuit time; v_uit timestamptz; v_min int; v_pauze int;
        v_drempel numeric; v_pmin int;
begin
  if not public.is_beheerder() then raise exception 'Alleen een beheerder kan dit vastzetten.' using errcode='P0002'; end if;
  select u.id, u.ingeklokt_op, u.pauze_minuten, kl.datum, kl.vestiging into v_r
    from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
   where u.id = p_uren;
  if v_r.id is null then raise exception 'Onbekende registratie.' using errcode='P0002'; end if;
  begin v_tuit := p_uit::time;
  exception when others then raise exception 'Vul een eindtijd in, bv. 21:00.' using errcode='P0002'; end;
  v_tz  := coalesce((select v.tijdzone from public.vestigingen v where v.code = v_r.vestiging), 'Europe/London');
  v_dag := (v_r.ingeklokt_op at time zone v_tz)::date;
  v_uit := (v_dag + v_tuit + case when coalesce(p_volgende_dag,false) then interval '1 day' else interval '0' end) at time zone v_tz;
  if v_uit <= v_r.ingeklokt_op then
    raise exception 'De eindtijd moet na de begintijd (%) liggen.', to_char(v_r.ingeklokt_op at time zone v_tz,'HH24:MI') using errcode='P0002';
  end if;
  if v_uit - v_r.ingeklokt_op > interval '16 hours' then raise exception 'Dat is langer dan 16 uur. Klopt de tijd?' using errcode='P0002'; end if;
  v_min := (extract(epoch from (v_uit - v_r.ingeklokt_op))/60)::int;
  v_drempel := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                          where i.vestiging = v_r.vestiging and i.sleutel = 'pauze_drempel_uren'), 6);
  v_pmin := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                       where i.vestiging = v_r.vestiging and i.sleutel = 'pauze_minuten'), 30)::int;
  v_pauze := case when coalesce(v_r.pauze_minuten,0) > 0 then v_r.pauze_minuten
                  when v_min >= v_drempel * 60 then v_pmin else 0 end;
  update public.urenregistraties
     set uitgeklokt_op = v_uit, pauze_minuten = v_pauze,
         totaal_minuten = greatest(0, v_min - v_pauze),
         status = case when status = 'lopend' then 'wacht' else status end
   where id = p_uren;
  return v_pauze;
end $function$;

-- De oude functie blijft bestaan, maar zet nooit meer stil 0 minuten.
create or replace function public.mcr_uur_bijstellen(p_uren uuid, p_uit timestamptz, p_pauze integer)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare v_in timestamptz; v_min int;
begin
  if not public.is_beheerder() then raise exception 'alleen een beheerder'; end if;
  select ingeklokt_op into v_in from public.urenregistraties where id = p_uren;
  if v_in is null then raise exception 'onbekende regel'; end if;
  if p_uit is null or p_uit <= v_in then raise exception 'De eindtijd moet na de begintijd liggen.' using errcode='P0002'; end if;
  v_min := greatest(0, (extract(epoch from (p_uit - v_in))/60)::int);
  update public.urenregistraties
     set uitgeklokt_op = p_uit, pauze_minuten = greatest(0, coalesce(p_pauze,0)),
         totaal_minuten = greatest(0, v_min - greatest(0, coalesce(p_pauze,0))),
         status = case when status = 'lopend' then 'wacht' else status end
   where id = p_uren;
end $function$;

-- ── 11. Uitbetaling per betaalronde ───────────────────────────────────────
create table if not exists public.mcr_ronde_verrekening (
  id              uuid not null default gen_random_uuid() unique,
  ronde_id        uuid not null references public.betaalrondes(id),
  gebruiker_id    uuid not null,
  uren            numeric not null default 0,
  tarief          numeric,
  bruto           numeric not null default 0,
  boetes          numeric not null default 0,   -- ingehouden boetes
  borg_in         numeric not null default 0,   -- ingehouden kledingborg
  borg_terug      numeric not null default 0,   -- terugbetaalde kledingborg
  netto           numeric not null default 0,
  factuur_id      uuid,
  vastgezet_op    timestamptz not null default now(),
  vastgezet_door  uuid,
  ingetrokken_op  timestamptz,
  primary key (ronde_id, gebruiker_id)
);
create index if not exists mcr_ronde_verrekening_g on public.mcr_ronde_verrekening (gebruiker_id);
revoke all on public.mcr_ronde_verrekening from anon, authenticated;
grant select, insert, update on public.mcr_ronde_verrekening to app_rpc, service_role;
alter table public.mcr_ronde_verrekening enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'mcr_ronde_verrekening' and policyname = 'rpc mcr_ronde_verrekening') then
    create policy "rpc mcr_ronde_verrekening" on public.mcr_ronde_verrekening for all to app_rpc using (true) with check (true);
  end if;
end $$;
create or replace trigger zz_audit after insert or update on public.mcr_ronde_verrekening
  for each row execute function public.audit_schrijf();

-- Per persoon: wat er in deze ronde betaald moet worden. Is de ronde
-- vastgezet, dan komen boetes/borg/netto uit de vastgelegde regel.
-- Boetes: alle boetes t/m het einde van de ronde, min wat in andere
-- (vastgezette) rondes al is ingehouden. Borg: wat iemand nu aan kleding heeft
-- (polo/schort × borg) min wat al is ingehouden; heeft hij minder kleding dan
-- waarvoor is ingehouden, dan gaat het verschil terug.
create or replace function public.mcr_ronde_uitbetaling(p_ronde uuid)
returns table(gebruiker_id uuid, naam text, leeftijd integer, uren numeric, tarief numeric, bruto numeric,
              open_uren numeric, open_n integer, boetes_open numeric, boetes numeric, borg_nu numeric, borg_al numeric,
              borg_in numeric, borg_terug numeric, netto numeric,
              sort_code text, bank_account text, iban text, utr text,
              factuur_id uuid, factuur_nummer text, factuur_bedrag numeric, gedownload_op timestamptz,
              ontvangen_op timestamptz, betaald_op timestamptz, vastgezet_op timestamptz)
language sql stable security definer set search_path to 'public'
as $function$  select * from (
  with b as (
    select r.* from public.betaalrondes r
     where r.id = p_ronde and public.vest_ok(r.vestiging) and public.in_actieve_vestiging(r.vestiging)
  ), u as (
    select ur.gebruiker_id,
           sum(case when ur.status = 'goedgekeurd' then ur.totaal_minuten else 0 end) min_goed,
           sum(case when ur.status in ('lopend','wacht','afgewezen') then coalesce(ur.totaal_minuten,0) else 0 end) min_open,
           count(*) filter (where ur.status in ('lopend','wacht','afgewezen')) n_open
      from b
      join public.klussen kl on kl.datum between b.periode_van and b.periode_tot
                            and kl.kraam_id is not null and kl.vestiging = b.vestiging
      join public.urenregistraties ur on ur.klus_id = kl.id
     group by ur.gebruiker_id
  ), vast as (   -- wat in ANDERE rondes al is vastgelegd
    select v.gebruiker_id, sum(v.boetes) boetes, sum(v.borg_in - v.borg_terug) borg
      from public.mcr_ronde_verrekening v, b
     where v.ronde_id <> b.id and v.ingetrokken_op is null
     group by v.gebruiker_id
  ), hier as (   -- wat in DEZE ronde is vastgelegd
    select v.* from public.mcr_ronde_verrekening v, b where v.ronde_id = b.id and v.ingetrokken_op is null
  ), wie as (
    select u.gebruiker_id from u
    union select f.gebruiker_id from public.facturen f, b where f.ronde_id = b.id
    union select hier.gebruiker_id from hier
    union  -- borg terug voor wie kleding inleverde, ook zonder uren
    select g.id from public.gebruikers g join vast on vast.gebruiker_id = g.id, b
     where g.vestiging = b.vestiging
       and vast.borg > public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort)
  ), basis as (
    select g.id, g.naam, g.uurloon, g.sort_code, g.bank_account, g.iban, g.utr,
           case when g.geboortedatum is not null then extract(year from age(b.periode_tot, g.geboortedatum))::int end lft,
           round(coalesce(u.min_goed,0)::numeric/60,2) uren,
           round(coalesce(u.min_goed,0)::numeric/60*coalesce(g.uurloon,0),2) bruto,
           round(coalesce(u.min_open,0)::numeric/60,2) open_uren, coalesce(u.n_open,0)::int open_n,
           greatest(0, coalesce((select sum(vv.boete) from public.mcr_voorvallen vv
                                  where vv.gebruiker_id = g.id and vv.datum <= b.periode_tot and coalesce(vv.boete,0) > 0),0)
                       - coalesce(vast.boetes,0)) boetes_open,
           public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort) borg_nu,
           coalesce(vast.borg,0) borg_al,
           f.id f_id, f.nummer f_nr, f.bedrag f_bedrag, f.gedownload_op, f.ontvangen_op, f.betaald_op,
           h.vastgezet_op, h.boetes h_boetes, h.borg_in h_borg_in, h.borg_terug h_borg_terug, h.netto h_netto,
           h.bruto h_bruto, h.uren h_uren, h.tarief h_tarief
      from wie
      join public.gebruikers g on g.id = wie.gebruiker_id
      cross join b
      left join u on u.gebruiker_id = g.id
      left join vast on vast.gebruiker_id = g.id
      left join hier h on h.gebruiker_id = g.id
      left join public.facturen f on f.ronde_id = b.id and f.gebruiker_id = g.id
  ), reken as (
    select x.*,
           least(x.boetes_open, x.bruto + greatest(0, x.borg_al - x.borg_nu)) r_boete,
           greatest(0, x.borg_al - x.borg_nu) r_terug
      from basis x
  ), reken2 as (
    select y.*,
           -- Bram (5 nov): borg gespreid over twee rondes, dus per ronde hooguit de helft.
           least(greatest(0, y.borg_nu - y.borg_al), round(y.borg_nu / 2, 2), y.bruto + y.r_terug - y.r_boete) r_borg_in
      from reken y
  )
  select z.id, z.naam, z.lft,
         case when z.vastgezet_op is not null then z.h_uren else z.uren end,
         case when z.vastgezet_op is not null then z.h_tarief else z.uurloon end,
         case when z.vastgezet_op is not null then z.h_bruto else z.bruto end,
         z.open_uren, z.open_n, z.boetes_open,
         case when z.vastgezet_op is not null then z.h_boetes else z.r_boete end,
         z.borg_nu, z.borg_al,
         case when z.vastgezet_op is not null then z.h_borg_in else z.r_borg_in end,
         case when z.vastgezet_op is not null then z.h_borg_terug else z.r_terug end,
         case when z.vastgezet_op is not null then z.h_netto
              else greatest(0, z.bruto + z.r_terug - z.r_boete - z.r_borg_in) end,
         z.sort_code, z.bank_account, z.iban, z.utr,
         z.f_id, z.f_nr, z.f_bedrag, z.gedownload_op, z.ontvangen_op, z.betaald_op, z.vastgezet_op
    from reken2 z
   order by z.naam
 ) _rijen where public.mag_kraambeheer()  $function$;

-- Vastzetten legt per persoon vast wat er is ingehouden en uitbetaald.
-- Terugzetten trekt het in (wordt niet weggehaald, blijft zichtbaar in de
-- audit). Een ronde kan pas vast als hij voorbij is en er niets meer open staat.
create or replace function public.mcr_ronde_vastzetten(p_ronde uuid, p_aan boolean)
returns integer
language plpgsql security definer set search_path to 'public'
as $function$
declare v_b record; v_open int; v_later int; n int := 0;
begin
  if not (public.mag_kraambeheer() and public.is_beheerder()) then
    raise exception 'Alleen een beheerder van deze vestiging kan een ronde vastzetten.' using errcode='P0002';
  end if;
  select * into v_b from public.betaalrondes r
   where r.id = p_ronde and public.vest_ok(r.vestiging) and public.in_actieve_vestiging(r.vestiging);
  if v_b.id is null then raise exception 'Die betaalronde bestaat niet.' using errcode='P0002'; end if;

  if coalesce(p_aan,false) then
    if v_b.periode_tot >= (now() at time zone public.mijn_tijdzone())::date then
      raise exception 'Deze ronde loopt nog. Vastzetten kan vanaf de dag na %.', to_char(v_b.periode_tot,'DD-MM') using errcode='P0002';
    end if;
    select count(*)::int into v_open
      from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
     where kl.kraam_id is not null and kl.vestiging = v_b.vestiging
       and kl.datum between v_b.periode_van and v_b.periode_tot
       and u.status in ('lopend','wacht','afgewezen');
    if v_open > 0 then
      raise exception 'Er staan nog % urenregistraties open in deze ronde (te accorderen of uitgezocht). Handel die eerst af.', v_open using errcode='P0002';
    end if;
    insert into public.mcr_ronde_verrekening as v
           (ronde_id, gebruiker_id, uren, tarief, bruto, boetes, borg_in, borg_terug, netto, factuur_id,
            vastgezet_op, vastgezet_door, ingetrokken_op)
    select p_ronde, x.gebruiker_id, x.uren, x.tarief, x.bruto, x.boetes, x.borg_in, x.borg_terug, x.netto,
           x.factuur_id, now(), public.huidige_gebruiker(), null
      from public.mcr_ronde_uitbetaling(p_ronde) x
     where x.vastgezet_op is null
    on conflict (ronde_id, gebruiker_id) do update
       set uren = excluded.uren, tarief = excluded.tarief, bruto = excluded.bruto, boetes = excluded.boetes,
           borg_in = excluded.borg_in, borg_terug = excluded.borg_terug, netto = excluded.netto,
           factuur_id = excluded.factuur_id, vastgezet_op = now(),
           vastgezet_door = excluded.vastgezet_door, ingetrokken_op = null;
    get diagnostics n = row_count;
  else
    select count(*)::int into v_later
      from public.mcr_ronde_verrekening v join public.betaalrondes r on r.id = v.ronde_id
     where r.vestiging = v_b.vestiging and r.nummer > v_b.nummer and v.ingetrokken_op is null;
    if v_later > 0 then
      raise exception 'Een latere ronde staat al vast. Zet die eerst terug.' using errcode='P0002';
    end if;
    update public.mcr_ronde_verrekening set ingetrokken_op = now()
     where ronde_id = p_ronde and ingetrokken_op is null;
    get diagnostics n = row_count;
  end if;
  return n;
end $function$;

-- Welke rondes vastgezet zijn (voor de lijst).
create or replace function public.mcr_rondes_vast()
returns table(ronde_id uuid, vastgezet_op timestamptz, mensen integer, netto numeric, ingehouden numeric)
language sql stable security definer set search_path to 'public'
as $function$  select * from (
  select v.ronde_id, max(v.vastgezet_op), count(*)::int, sum(v.netto), sum(v.boetes + v.borg_in)
    from public.mcr_ronde_verrekening v
    join public.betaalrondes b on b.id = v.ronde_id
   where v.ingetrokken_op is null and public.vest_ok(b.vestiging) and public.in_actieve_vestiging(b.vestiging)
   group by v.ronde_id
 ) _rijen where public.mag_kraambeheer()  $function$;

-- ── 12. Geplande loonkosten tegen de forecast ─────────────────────────────
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving)
select 'MCR', 'loon_pct_drempel', '30', 'Loonkosten boven dit % van de (verwachte) omzet kleuren rood'
 where exists (select 1 from public.vestigingen v where v.code = 'MCR')
   and not exists (select 1 from public.vestiging_instellingen i where i.vestiging = 'MCR' and i.sleutel = 'loon_pct_drempel');

-- Per kraam per dag: gepland (ingedeelde mensen × diensturen × tarief, pauze
-- vanaf de drempel), forecast, en wat er echt was (omzet en geklokte loonkosten).
-- Plus de tarieven en de pauzeregel, zodat het planbord live kan meerekenen.
create or replace function public.mcr_plan_loon(p_van date, p_tot date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v jsonb; v_vest text; v_drempel numeric; v_pmin int; v_pct numeric;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit zien.' using errcode='P0002';
  end if;
  if p_tot - p_van > 62 then raise exception 'Kies hooguit twee maanden.' using errcode='P0002'; end if;
  v_vest := coalesce(public.actieve_vestiging(), 'MCR');
  v_drempel := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                          where i.vestiging = v_vest and i.sleutel = 'pauze_drempel_uren'), 6);
  v_pmin := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                       where i.vestiging = v_vest and i.sleutel = 'pauze_minuten'), 30)::int;
  v_pct := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                      where i.vestiging = v_vest and i.sleutel = 'loon_pct_drempel'), 30);
  with k as (
    select k.* from public.kramen k
     where k.actief and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
  ), dag as (
    select k.id kid, d::date datum,
           coalesce(u.dicht,false) or d::date < k.seizoen_start or d::date > k.seizoen_eind dicht
      from k cross join generate_series(p_van, p_tot, interval '1 day') d
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d::date
  ), plan as (
    select kl.kraam_id kid, kl.datum, g.id gid, coalesce(g.uurloon,0) tarief,
           (extract(epoch from (coalesce(s.eind_tijd, public.kraam_eindtijd(kl.kraam_id, kl.datum), '23:59'::time) - s.start_tijd))/60)::int mins
      from public.klus_shifts s
      join public.klussen kl on kl.id = s.klus_id
      join public.klus_gebruikers kg on kg.shift_id = s.id
      join public.gebruikers g on g.id = kg.gebruiker_id
     where kl.kraam_id in (select id from k) and kl.datum between p_van and p_tot and s.start_tijd is not null
  ), plan2 as (
    select p.kid, p.datum, p.gid, p.tarief,
           greatest(0, p.mins - case when p.mins >= v_drempel*60 then v_pmin else 0 end) netto_min
      from plan p where p.mins > 0
  ), plansom as (
    select kid, datum, count(distinct gid)::int mensen, round(sum(netto_min)::numeric/60,2) uren,
           round(sum(netto_min::numeric/60*tarief),2) loon
      from plan2 group by kid, datum
  ), echt as (
    select kl.kraam_id kid, kl.datum, round(sum(ur.totaal_minuten)::numeric/60,2) uren,
           round(sum(ur.totaal_minuten::numeric/60*coalesce(gb.uurloon,0)),2) loon
      from public.urenregistraties ur
      join public.klussen kl on kl.id = ur.klus_id
      join public.gebruikers gb on gb.id = ur.gebruiker_id
     where kl.kraam_id in (select id from k) and kl.datum between p_van and p_tot and ur.uitgeklokt_op is not null
     group by kl.kraam_id, kl.datum
  ), pin as (
    select pd.kraam_id kid, pd.datum, sum(pd.omzet) omzet
      from public.pin_dag pd where pd.kraam_id in (select id from k) and pd.datum between p_van and p_tot
     group by pd.kraam_id, pd.datum
  )
  select jsonb_build_object(
    'pauze_drempel_uren', v_drempel, 'pauze_minuten', v_pmin, 'loon_pct_drempel', v_pct,
    'tarieven', coalesce((select jsonb_object_agg(g.id, coalesce(g.uurloon,0)) from public.gebruikers g
                           where public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
                             and g.rol <> 'beheerder'), '{}'::jsonb),
    'dagen', coalesce((select jsonb_agg(jsonb_build_object(
        'kraam', d.kid, 'datum', d.datum, 'dicht', d.dicht,
        'gepland_mensen', coalesce(ps.mensen,0), 'gepland_uren', coalesce(ps.uren,0), 'gepland_loon', coalesce(ps.loon,0),
        'forecast', r.forecast,
        'omzet', case when pin.omzet is not null or r.omzet_contant is not null
                      then coalesce(pin.omzet,0) + coalesce(r.omzet_contant,0) end,
        'uren_echt', e.uren, 'loon_echt', e.loon) order by d.datum, d.kid)
      from dag d
      left join plansom ps on ps.kid = d.kid and ps.datum = d.datum
      left join echt e on e.kid = d.kid and e.datum = d.datum
      left join pin on pin.kid = d.kid and pin.datum = d.datum
      left join public.dagrapporten r on r.kraam_id = d.kid and r.datum = d.datum), '[]'::jsonb)
  ) into v;
  return v;
end $function$;

-- ── 10. myPOS-import: terugbetalingen ─────────────────────────────────────
-- De app stuurt een terugbetaling nu mee als negatief bedrag. Die telt niet als
-- bon (transacties), trekt wel van de omzet af, en porties/toppings tellen met
-- het teken mee. Prijzen komen uit de instellingen van de vestiging zelf.
-- Zelfde werking als voorheen, maar zonder tijdelijke tabel.
create or replace function public.pin_import(p_rijen jsonb)
returns table(dagen integer, transacties integer, dubbel integer, omzet numeric, kosten numeric, onbekende_tids text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_vest text; r jsonb; v_ref text; v_tid text; v_dag date; v_uur int;
  v_bedrag numeric; v_kosten numeric; v_fooi numeric; v_merk text;
  v_nieuw int := 0; v_dubbel int := 0; v_omzet numeric := 0; v_kost numeric := 0;
  v_onbekend text[] := '{}';
  v_prijs numeric; v_top numeric;
  v_in jsonb := '[]'::jsonb;
begin
  if not public.is_beheerder() then raise exception 'alleen een beheerder mag inlezen'; end if;
  v_vest := public.actieve_vestiging();
  if v_vest is null then raise exception 'kies eerst een vestiging'; end if;

  for r in select * from jsonb_array_elements(p_rijen) loop
    v_ref := r->>'ref'; v_tid := r->>'tid'; v_dag := (r->>'dag')::date;
    v_uur := coalesce((r->>'uur')::int, 0);
    v_bedrag := coalesce((r->>'bedrag')::numeric, 0);
    v_kosten := coalesce((r->>'kosten')::numeric, 0);
    v_fooi   := coalesce((r->>'fooi')::numeric, 0);
    v_merk   := coalesce(r->>'merk','');
    if v_ref is null or v_tid is null or v_dag is null then continue; end if;
    begin
      insert into public.pin_referenties (vestiging, referentie, datum) values (v_vest, v_ref, v_dag);
    exception when unique_violation then
      v_dubbel := v_dubbel + 1; continue;
    end;
    v_in := v_in || jsonb_build_array(jsonb_build_object('tid',v_tid,'dag',v_dag,'uur',v_uur,'bedrag',v_bedrag,
                                                         'kosten',v_kosten,'fooi',v_fooi,'merk',v_merk,'ref',v_ref));
    if v_bedrag > 0 then v_nieuw := v_nieuw + 1; end if;
    v_omzet := v_omzet + v_bedrag; v_kost := v_kost + v_kosten;
  end loop;

  v_prijs := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                        where i.vestiging = v_vest and i.sleutel = 'prijs_portie'), 7);
  v_top   := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                        where i.vestiging = v_vest and i.sleutel = 'prijs_topping'), 1);
  if coalesce(v_prijs,0) <= 0 then v_prijs := 7; end if;
  if coalesce(v_top,0) <= 0 then v_top := 1; end if;

  insert into public.pin_dag (vestiging, tid, datum, kraam_id, omzet, transacties, kosten, fooi,
                              visa, mastercard, porties, toppings, onverklaard)
  select v_vest, i.tid, i.dag, public.kraam_van_tid(v_vest, i.tid, i.dag),
         sum(i.bedrag), count(*) filter (where i.bedrag > 0), sum(i.kosten), sum(i.fooi),
         count(*) filter (where lower(i.merk) like '%visa%' and i.bedrag > 0),
         count(*) filter (where lower(i.merk) like '%master%' and i.bedrag > 0),
         sum(sign(i.bedrag) * floor(abs(i.bedrag) / v_prijs))::int,
         sum(sign(i.bedrag) * round((abs(i.bedrag) - floor(abs(i.bedrag) / v_prijs) * v_prijs) / v_top))::int,
         sum(case when (abs(i.bedrag) - floor(abs(i.bedrag)/v_prijs)*v_prijs)
                       - round((abs(i.bedrag) - floor(abs(i.bedrag)/v_prijs)*v_prijs)/v_top)*v_top <> 0
                  then i.bedrag else 0 end)
    from jsonb_to_recordset(v_in) as i(tid text, dag date, uur int, bedrag numeric, kosten numeric,
                                       fooi numeric, merk text, ref text)
   group by i.tid, i.dag
  on conflict (vestiging, tid, datum) do update set
    omzet = public.pin_dag.omzet + excluded.omzet,
    transacties = public.pin_dag.transacties + excluded.transacties,
    kosten = public.pin_dag.kosten + excluded.kosten,
    fooi = public.pin_dag.fooi + excluded.fooi,
    visa = public.pin_dag.visa + excluded.visa,
    mastercard = public.pin_dag.mastercard + excluded.mastercard,
    porties = coalesce(public.pin_dag.porties,0) + coalesce(excluded.porties,0),
    toppings = coalesce(public.pin_dag.toppings,0) + coalesce(excluded.toppings,0),
    onverklaard = public.pin_dag.onverklaard + excluded.onverklaard,
    kraam_id = coalesce(public.pin_dag.kraam_id, excluded.kraam_id),
    bijgewerkt_op = now();

  insert into public.pin_uur (vestiging, tid, datum, uur, omzet, transacties)
  select v_vest, i.tid, i.dag, i.uur, sum(i.bedrag), count(*) filter (where i.bedrag > 0)
    from jsonb_to_recordset(v_in) as i(tid text, dag date, uur int, bedrag numeric)
   group by i.tid, i.dag, i.uur
  on conflict (vestiging, tid, datum, uur) do update set
    omzet = public.pin_uur.omzet + excluded.omzet,
    transacties = public.pin_uur.transacties + excluded.transacties;

  select array_agg(distinct i.tid) into v_onbekend
    from jsonb_to_recordset(v_in) as i(tid text, dag date)
   where public.kraam_van_tid(v_vest, i.tid, i.dag) is null;

  select count(*)::int into dagen
    from (select distinct i.tid, i.dag from jsonb_to_recordset(v_in) as i(tid text, dag date)) x;
  transacties := v_nieuw; dubbel := v_dubbel; omzet := v_omzet; kosten := v_kost;
  onbekende_tids := array_to_string(coalesce(v_onbekend,'{}'), ', ');
  return next;
end $function$;

-- ── Eigenaar en rechten ───────────────────────────────────────────────────
alter function public.mcr_rondes() owner to app_rpc;
alter function public.mcr_ronde_mensen(uuid) owner to app_rpc;
alter function public.mcr_uur_tijden_londen(uuid,text,text,integer,boolean,boolean) owner to app_rpc;
alter function public.mcr_uur_akkoord(uuid,boolean,text) owner to app_rpc;
alter function public.mcr_uren_vraag() owner to app_rpc;
alter function public.mcr_uur_terug(uuid) owner to app_rpc;
alter function public.mcr_uur_vastzetten(uuid,text,boolean) owner to app_rpc;
alter function public.mcr_uur_bijstellen(uuid,timestamptz,integer) owner to app_rpc;
alter function public.mcr_ronde_uitbetaling(uuid) owner to app_rpc;
alter function public.mcr_ronde_vastzetten(uuid,boolean) owner to app_rpc;
alter function public.mcr_rondes_vast() owner to app_rpc;
alter function public.mcr_plan_loon(date,date) owner to app_rpc;
alter function public.pin_import(jsonb) owner to app_rpc;

revoke all on function public.mcr_rondes() from public, anon;
revoke all on function public.mcr_ronde_mensen(uuid) from public, anon;
revoke all on function public.mcr_uur_tijden_londen(uuid,text,text,integer,boolean,boolean) from public, anon;
revoke all on function public.mcr_uur_akkoord(uuid,boolean,text) from public, anon;
revoke all on function public.mcr_uren_vraag() from public, anon;
revoke all on function public.mcr_uur_terug(uuid) from public, anon;
revoke all on function public.mcr_uur_vastzetten(uuid,text,boolean) from public, anon;
revoke all on function public.mcr_uur_bijstellen(uuid,timestamptz,integer) from public, anon;
revoke all on function public.mcr_ronde_uitbetaling(uuid) from public, anon;
revoke all on function public.mcr_ronde_vastzetten(uuid,boolean) from public, anon;
revoke all on function public.mcr_rondes_vast() from public, anon;
revoke all on function public.mcr_plan_loon(date,date) from public, anon;
revoke all on function public.pin_import(jsonb) from public, anon;

grant execute on function public.mcr_rondes() to authenticated, service_role;
grant execute on function public.mcr_ronde_mensen(uuid) to authenticated, service_role;
grant execute on function public.mcr_uur_tijden_londen(uuid,text,text,integer,boolean,boolean) to authenticated, service_role;
grant execute on function public.mcr_uur_akkoord(uuid,boolean,text) to authenticated, service_role;
grant execute on function public.mcr_uren_vraag() to authenticated, service_role;
grant execute on function public.mcr_uur_terug(uuid) to authenticated, service_role;
grant execute on function public.mcr_uur_vastzetten(uuid,text,boolean) to authenticated, service_role;
grant execute on function public.mcr_uur_bijstellen(uuid,timestamptz,integer) to authenticated, service_role;
grant execute on function public.mcr_ronde_uitbetaling(uuid) to authenticated, service_role;
grant execute on function public.mcr_ronde_vastzetten(uuid,boolean) to authenticated, service_role;
grant execute on function public.mcr_rondes_vast() to authenticated, service_role;
grant execute on function public.mcr_plan_loon(date,date) to authenticated, service_role;
grant execute on function public.pin_import(jsonb) to authenticated, service_role;
