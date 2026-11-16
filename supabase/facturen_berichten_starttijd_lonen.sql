-- 1) Facturen staan klaar op de dag vóór de uitbetaling vanaf 15:00 (tijd van de
--    markt), en nooit voordat de periode voorbij is. Een factuur die al bestaat,
--    kan altijd opnieuw worden gedownload.
select public._fn_vervang('public.mcr_betaalrondes()'::regprocedure,
  '(b.periode_tot < (now() at time zone public.mijn_tijdzone())::date)',
  '(greatest((b.periode_tot + 1)::timestamp, (b.betaaldatum - 1) + time ''15:00'') <= (now() at time zone public.mijn_tijdzone()))');

select public._fn_vervang('public.mcr_factuur_maken(uuid)'::regprocedure,
$o$    raise exception 'This period is not finished yet.' using errcode='P0002';
  end if;$o$,
$n$    raise exception 'This period is not finished yet.' using errcode='P0002';
  end if;
  if greatest((v_b.periode_tot + 1)::timestamp, (v_b.betaaldatum - 1) + time '15:00') > (now() at time zone public.mijn_tijdzone())
     and not exists (select 1 from public.facturen f0 where f0.gebruiker_id = v_uid and f0.ronde_id = p_ronde) then
    raise exception 'Your invoice will be ready on %.',
      to_char(greatest((v_b.periode_tot + 1)::timestamp, (v_b.betaaldatum - 1) + time '15:00'), 'FMDD FMMonth "at" HH24:MI') using errcode='P0002';
  end if;$n$);


-- 2) Algemene berichten van de beheerder aan iedereen in een of meer markten.
--    Elk bericht moet echt gelezen worden: het blijft in beeld tot de ontvanger
--    op "Gelezen" tikt, en de beheerder ziet wie het gelezen heeft.
create table if not exists public.berichten (
  id             uuid primary key default gen_random_uuid(),
  titel_nl       text,
  tekst_nl       text,
  titel_en       text,
  tekst_en       text,
  vestigingen    text[] not null,
  verstuurd_door uuid references public.gebruikers(id) on delete set null,
  verstuurd_op   timestamptz not null default now(),
  ingetrokken_op timestamptz
);
create table if not exists public.bericht_ontvangers (
  bericht_id   uuid not null references public.berichten(id) on delete cascade,
  gebruiker_id uuid not null references public.gebruikers(id) on delete cascade,
  gelezen_op   timestamptz,
  primary key (bericht_id, gebruiker_id)
);
create index if not exists bericht_ontvangers_gebruiker on public.bericht_ontvangers (gebruiker_id) where gelezen_op is null;
alter table public.berichten enable row level security;
alter table public.bericht_ontvangers enable row level security;
-- Geen policies: alles loopt via de functies hieronder.

-- Versturen (alleen beheerder). Ontvangers: goedgekeurde, niet-gearchiveerde
-- mensen van die markten (ook wie er tijdelijk een tweede markt heeft).
create or replace function public.bericht_versturen(p_titel_nl text, p_tekst_nl text,
                                                    p_titel_en text, p_tekst_en text, p_vestigingen text[])
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; n int;
begin
  if not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan een bericht sturen.' using errcode='P0002';
  end if;
  p_titel_nl := nullif(btrim(p_titel_nl),''); p_tekst_nl := nullif(btrim(p_tekst_nl),'');
  p_titel_en := nullif(btrim(p_titel_en),''); p_tekst_en := nullif(btrim(p_tekst_en),'');
  if (p_titel_nl is null or p_tekst_nl is null) and (p_titel_en is null or p_tekst_en is null) then
    raise exception 'Vul een titel en een tekst in (Nederlands, Engels of allebei).' using errcode='P0002';
  end if;
  if (p_titel_nl is null) <> (p_tekst_nl is null) or (p_titel_en is null) <> (p_tekst_en is null) then
    raise exception 'Vul per taal zowel de titel als de tekst in.' using errcode='P0002';
  end if;
  if coalesce(array_length(p_vestigingen,1),0) = 0 then
    raise exception 'Kies minstens één markt.' using errcode='P0002';
  end if;

  insert into public.berichten (titel_nl, tekst_nl, titel_en, tekst_en, vestigingen, verstuurd_door)
  values (p_titel_nl, p_tekst_nl, p_titel_en, p_tekst_en, p_vestigingen, public.huidige_gebruiker())
  returning id into v_id;

  insert into public.bericht_ontvangers (bericht_id, gebruiker_id)
  select v_id, g.id from public.gebruikers g
   where g.gearchiveerd_op is null and coalesce(g.goedgekeurd,false)
     and g.id <> public.huidige_gebruiker()
     and (g.vestiging = any(p_vestigingen)
          or g.plant_vestiging = any(p_vestigingen)
          or (g.tweede_vestiging = any(p_vestigingen) and coalesce(g.tweede_tot, current_date) >= current_date));
  get diagnostics n = row_count;

  -- Pushmelding, met de titel in de taal van de ontvanger
  insert into public.push_wachtrij (gebruiker_id, soort, regel)
  select o.gebruiker_id, 'bericht',
         case when coalesce(g.taal, v.taal, 'en') = 'nl' then coalesce(p_titel_nl, p_titel_en)
              else coalesce(p_titel_en, p_titel_nl) end
    from public.bericht_ontvangers o
    join public.gebruikers g on g.id = o.gebruiker_id
    left join public.vestigingen v on v.code = g.vestiging
   where o.bericht_id = v_id and g.push_token is not null;
  return n;
end $$;

-- Ongelezen berichten voor wie ingelogd is, in de eigen taal (anders de andere)
create or replace function public.mijn_berichten()
returns table(id uuid, titel text, tekst text, verstuurd_op timestamptz, van text)
language sql stable security definer set search_path to 'public' as $$
  select b.id,
         case when t.nl then coalesce(b.titel_nl, b.titel_en) else coalesce(b.titel_en, b.titel_nl) end,
         case when t.nl then coalesce(b.tekst_nl, b.tekst_en) else coalesce(b.tekst_en, b.tekst_nl) end,
         b.verstuurd_op, (select a.naam from public.gebruikers a where a.id = b.verstuurd_door)
    from public.bericht_ontvangers o
    join public.berichten b on b.id = o.bericht_id and b.ingetrokken_op is null
    cross join lateral (select coalesce(g.taal, v.taal, 'en') = 'nl' as nl
                          from public.gebruikers g left join public.vestigingen v on v.code = g.vestiging
                         where g.id = o.gebruiker_id) t
   where o.gebruiker_id = public.huidige_gebruiker() and o.gelezen_op is null
   order by b.verstuurd_op
$$;

create or replace function public.bericht_gelezen(p_bericht uuid)
returns void language sql security definer set search_path to 'public' as $$
  update public.bericht_ontvangers set gelezen_op = now()
   where bericht_id = p_bericht and gebruiker_id = public.huidige_gebruiker() and gelezen_op is null
$$;

-- Overzicht voor de beheerder
create or replace function public.berichten_overzicht()
returns table(id uuid, titel_nl text, tekst_nl text, titel_en text, tekst_en text, vestigingen text[],
              verstuurd_op timestamptz, van text, ontvangers int, gelezen int, ingetrokken_op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.titel_nl, b.tekst_nl, b.titel_en, b.tekst_en, b.vestigingen, b.verstuurd_op,
         (select a.naam from public.gebruikers a where a.id = b.verstuurd_door),
         (select count(*)::int from public.bericht_ontvangers o where o.bericht_id = b.id),
         (select count(*)::int from public.bericht_ontvangers o where o.bericht_id = b.id and o.gelezen_op is not null),
         b.ingetrokken_op
    from public.berichten b
   where public.is_beheerder()
   order by b.verstuurd_op desc
$$;

create or replace function public.bericht_lezers(p_bericht uuid)
returns table(naam text, vestiging text, gelezen_op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select g.naam, g.vestiging, o.gelezen_op
    from public.bericht_ontvangers o join public.gebruikers g on g.id = o.gebruiker_id
   where o.bericht_id = p_bericht and public.is_beheerder()
   order by o.gelezen_op nulls first, g.naam
$$;

create or replace function public.bericht_intrekken(p_bericht uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan een bericht intrekken.' using errcode='P0002';
  end if;
  update public.berichten set ingetrokken_op = now() where id = p_bericht and ingetrokken_op is null;
  update public.push_wachtrij w set verwerkt_op = now(), uitslag = 'vervallen'
   where w.soort = 'bericht' and w.verwerkt_op is null
     and w.gebruiker_id in (select o.gebruiker_id from public.bericht_ontvangers o
                             where o.bericht_id = p_bericht and o.gelezen_op is null);
end $$;

revoke all on function public.bericht_versturen(text,text,text,text,text[]) from public, anon;
revoke all on function public.mijn_berichten() from public, anon;
revoke all on function public.bericht_gelezen(uuid) from public, anon;
revoke all on function public.berichten_overzicht() from public, anon;
revoke all on function public.bericht_lezers(uuid) from public, anon;
revoke all on function public.bericht_intrekken(uuid) from public, anon;
grant execute on function public.bericht_versturen(text,text,text,text,text[]) to authenticated;
grant execute on function public.mijn_berichten() to authenticated;
grant execute on function public.bericht_gelezen(uuid) to authenticated;
grant execute on function public.berichten_overzicht() to authenticated;
grant execute on function public.bericht_lezers(uuid) to authenticated;
grant execute on function public.bericht_intrekken(uuid) to authenticated;

-- Pushmelding: titel en tekst voor soort 'bericht'
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$           else 'TC Group' end,$o$,
  $n$           when 'bericht' then case when t.n = 1 then t.regels
                                    when t.nl then t.n || ' nieuwe berichten' else t.n || ' new messages' end
           else 'TC Group' end,$n$);
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$           else t.regels end,$o$,
  $n$           when 'bericht' then case when t.nl then 'Je hebt een nieuw bericht. Open de app om het te lezen.'
                                    else 'You have a new message. Open the app to read it.' end
           else t.regels end,$n$);
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$              else 'mcr-shifts' end$o$,
  $n$              when t.soort = 'bericht' then 'bericht'
              else 'mcr-shifts' end$n$);


-- 3) Kraammanagers mogen ook de inkloktijd (starttijd) aanpassen, met dezelfde
--    regels als de uitkloktijd: alleen op de eigen kraam, niet de eigen uren,
--    en alleen zolang Bram de uren nog niet heeft goedgekeurd.
alter table public.mcr_wijzigingen drop constraint mcr_wijzigingen_soort_check;
alter table public.mcr_wijzigingen add constraint mcr_wijzigingen_soort_check
  check (soort = any (array['pauze','beoordeling','uitkloktijd','inkloktijd']));

create or replace function public.mgr_starttijd_zetten(p_uren uuid, p_in timestamptz, p_reden text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare u record; v_mijn uuid;
begin
  if not public.is_kraammanager() then
    raise exception 'Only a stall manager can change hours.' using errcode='P0002';
  end if;
  if p_in is null then raise exception 'Enter the time they started.' using errcode='P0002'; end if;
  select g.manager_kraam_id into v_mijn from public.gebruikers g where g.id = public.huidige_gebruiker();
  select ur.*, kl.kraam_id as kid into u
    from public.urenregistraties ur
    join public.gebruikers g on g.id = ur.gebruiker_id
    join public.klussen kl on kl.id = ur.klus_id
   where ur.id = p_uren and kl.kraam_id is not null
     and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging);
  if not found then raise exception 'That clocking does not exist.' using errcode='P0002'; end if;
  if v_mijn is not null and u.kid <> v_mijn then
    raise exception 'This person worked at another stall; only that stall''s manager can change it.' using errcode='P0002';
  end if;
  if u.gebruiker_id = public.huidige_gebruiker() then
    raise exception 'You cannot change your own hours. Ask Bram.' using errcode='P0002';
  end if;
  if u.status not in ('lopend','wacht') or u.factuur_id is not null then
    raise exception 'These hours have already been approved; only Bram can change them now.' using errcode='P0002';
  end if;
  if p_in = u.ingeklokt_op then return; end if;
  if p_in >= coalesce(u.uitgeklokt_op, now()) then
    raise exception 'The start time must be before the finish time.' using errcode='P0002';
  end if;
  if coalesce(u.uitgeklokt_op, now()) - p_in > interval '18 hours' then
    raise exception 'That is more than 18 hours before they finished. Check the time.' using errcode='P0002';
  end if;
  if abs(extract(epoch from (p_in - u.ingeklokt_op))) > 12*3600 then
    raise exception 'That is more than 12 hours away from when they clocked in. Check the time.' using errcode='P0002';
  end if;

  update public.urenregistraties
     set ingeklokt_op = p_in,
         totaal_minuten = case when uitgeklokt_op is null then totaal_minuten
                               else greatest(0, (extract(epoch from (uitgeklokt_op - p_in))/60)::int - coalesce(pauze_minuten,0)) end,
         in_door = public.huidige_gebruiker(), in_op = now()
   where id = p_uren;

  insert into public.mcr_wijzigingen (door, gebruiker_id, uren_id, soort, van, naar, reden)
  values (public.huidige_gebruiker(), u.gebruiker_id, p_uren, 'inkloktijd',
          to_char(u.ingeklokt_op at time zone public.mijn_tijdzone(),'HH24:MI'),
          to_char(p_in at time zone public.mijn_tijdzone(),'HH24:MI'), nullif(public.schoon_kort(p_reden),''));
end $$;
alter function public.mgr_starttijd_zetten(uuid,timestamptz,text) owner to app_rpc;
revoke all on function public.mgr_starttijd_zetten(uuid,timestamptz,text) from public, anon;
grant execute on function public.mgr_starttijd_zetten(uuid,timestamptz,text) to authenticated;


-- 4) Lonen-overzicht voor Kosten: per betaalronde die nog niet betaald is,
--    wat er overgemaakt moet worden. De kledingborg telt maar één keer mee,
--    ook als eerdere rondes nog niet zijn vastgezet.
create or replace function public.mcr_loon_overzicht()
returns table(ronde_id uuid, nummer int, periode_van date, periode_tot date, betaaldatum date,
              afgelopen boolean, vastgezet int, mensen int, bruto numeric, borg_in numeric,
              borg_terug numeric, boetes numeric, netto numeric, open_uren numeric, open_bedrag numeric)
language plpgsql stable security definer set search_path to 'public' as $$
declare r record; x record; v_gepland jsonb := '{}'::jsonb; v_al numeric; v_borg numeric;
begin
  if not public.mag_kraambeheer() then return; end if;
  for r in select b.* from public.betaalrondes b
            where public.vest_ok(b.vestiging) and public.in_actieve_vestiging(b.vestiging)
              and b.betaald_op is null
              and b.periode_van <= (now() at time zone public.mijn_tijdzone())::date
            order by b.nummer loop
    ronde_id := r.id; nummer := r.nummer; periode_van := r.periode_van; periode_tot := r.periode_tot;
    betaaldatum := r.betaaldatum; afgelopen := r.periode_tot < (now() at time zone public.mijn_tijdzone())::date;
    vastgezet := 0; mensen := 0; bruto := 0; borg_in := 0; borg_terug := 0; boetes := 0; netto := 0;
    open_uren := 0; open_bedrag := 0;
    for x in select * from public.mcr_ronde_uitbetaling(r.id) loop
      if x.vastgezet_op is not null then
        vastgezet := vastgezet + 1;
        v_borg := coalesce(x.borg_in,0);
        netto := netto + coalesce(x.netto,0);
      else
        v_al := coalesce((v_gepland->>x.gebruiker_id::text)::numeric, 0);
        v_borg := greatest(0, least(greatest(0, x.borg_nu - x.borg_al - v_al),
                                    coalesce(x.bruto,0) + coalesce(x.borg_terug,0) - coalesce(x.boetes,0)));
        netto := netto + greatest(0, coalesce(x.bruto,0) + coalesce(x.borg_terug,0) - coalesce(x.boetes,0) - v_borg);
        v_gepland := jsonb_set(v_gepland, array[x.gebruiker_id::text], to_jsonb(v_al + v_borg));
      end if;
      bruto := bruto + coalesce(x.bruto,0);
      borg_in := borg_in + v_borg;
      borg_terug := borg_terug + coalesce(x.borg_terug,0);
      boetes := boetes + coalesce(x.boetes,0);
      open_uren := open_uren + coalesce(x.open_uren,0);
      open_bedrag := open_bedrag + round(coalesce(x.open_uren,0) * coalesce(x.tarief,0), 2);
      if coalesce(x.bruto,0) > 0 or coalesce(x.open_uren,0) > 0 then mensen := mensen + 1; end if;
    end loop;
    return next;
  end loop;
end $$;
revoke all on function public.mcr_loon_overzicht() from public, anon;
grant execute on function public.mcr_loon_overzicht() to authenticated;


-- 5) Notitie bij vroeg inklokken in het Engels (de markten zijn Engelstalig;
--    wie de app in het Nederlands heeft, krijgt hem vertaald in de app).
select public._fn_vervang('public.mcr_inklok_starttijd()'::regprocedure,
  $o$'Klokte in om ' || to_char(new.ingeklokt_op at time zone v_tz,'HH24:MI')
      || ', telt vanaf de starttijd ' || to_char(v_start,'HH24:MI'))$o$,
  $n$'Clocked in at ' || to_char(new.ingeklokt_op at time zone v_tz,'HH24:MI')
      || ', counted from the start time ' || to_char(v_start,'HH24:MI'))$n$);
update public.urenregistraties
   set notitie_beh = regexp_replace(notitie_beh, 'Klokte in om (\d\d:\d\d), telt vanaf de starttijd (\d\d:\d\d)',
                                    'Clocked in at \1, counted from the start time \2', 'g')
 where notitie_beh like '%Klokte in om%';
