-- Manchester: agenda voor Bram en de kraammanagers (16 okt 2026)
--
-- Bram: "in het manchester gedeelte wil ik een kalender/agenda voor alle
-- kraammanagers, waarin ik dus influencers kan zetten die langskomen en bijv.
-- leveringen of andere dingen." En: "kunnen managers ook een punt in de agenda
-- zetten. graag wel (alleen voor hun eigen kraam)". Managers van alle kramen
-- mogen voor elke kraam iets zetten; Bram krijgt een melding als een manager
-- iets toevoegt.
--
-- * Tabel mcr_agenda: dag, optioneel tijd van/tot (Engelse tijd), kraam (leeg =
--   alle kramen), soort, titel, contact, notitie. Alleen via de functies
--   hieronder bereikbaar (rol app_rpc), zoals de andere Manchester-tabellen.
-- * Bram (mag_kraambeheer): mcr_agenda_lijst / mcr_agenda_zetten / mcr_agenda_weg,
--   alles van alle kramen, ook wat managers zetten.
-- * Kraammanager (is_kraammanager): mgr_agenda leest alles van de eigen
--   vestiging. mgr_agenda_zetten / mgr_agenda_weg: alleen voor de eigen kraam
--   (manager_kraam_id) of, zonder gekozen kraam, voor elke kraam; wijzigen en
--   weghalen alleen van items die hij zelf heeft gezet.
-- * Nieuw item van een manager → push_wachtrij (soort mcr_agenda_manager) naar
--   de beheerders van MCR; push_wachtrij_bundels kent die soort (pagina
--   mcr-agenda). Is het item al weg voordat de melding uitgaat, dan vervalt hij.
-- * Audit en live-signaal zoals bij mcr_kosten.

create table public.mcr_agenda (
  id              uuid primary key default gen_random_uuid(),
  vestiging       text not null default 'MCR',
  datum           date not null,
  tijd_van        time,
  tijd_tot        time,
  kraam_id        uuid references public.kramen(id) on delete set null,
  soort           text not null default 'overig'
                  check (soort in ('influencer','levering','bezoek','overig')),
  titel           text not null check (length(btrim(titel)) > 0),
  contact         text,
  notitie         text,
  aangemaakt_door uuid,
  aangemaakt_op   timestamptz not null default now(),
  bijgewerkt_door uuid,
  bijgewerkt_op   timestamptz,
  check (tijd_tot is null or tijd_van is null or tijd_tot > tijd_van),
  check (tijd_tot is null or tijd_van is not null)
);
create index mcr_agenda_datum on public.mcr_agenda (vestiging, datum);

revoke all on public.mcr_agenda from anon, authenticated;
grant select, insert, update, delete on public.mcr_agenda to app_rpc, service_role;
alter table public.mcr_agenda enable row level security;
create policy "rpc mcr_agenda" on public.mcr_agenda for all to app_rpc using (true) with check (true);

create trigger zz_audit   after insert or update or delete on public.mcr_agenda
  for each row execute function public.audit_schrijf();
create trigger zz_signaal after insert or update or delete on public.mcr_agenda
  for each statement execute function public.signaal_geven();

-- Melding: welk agenda-item hoort bij een push (zodat hij vervalt als het item weg is).
alter table public.push_wachtrij add column if not exists agenda_id uuid;

-- ── gedeelde controle (Nederlands voor Bram, Engels voor managers) ─
create or replace function public.mcr_agenda_controle(p_datum date, p_van time, p_tot time,
  p_soort text, p_titel text, p_en boolean)
returns void
language plpgsql immutable set search_path to 'public'
as $$
begin
  if p_datum is null then
    raise exception '%', case when p_en then 'Choose a date.' else 'Kies een datum.' end using errcode='P0002'; end if;
  if nullif(btrim(coalesce(p_titel,'')),'') is null then
    raise exception '%', case when p_en then 'Enter a title.' else 'Vul een titel in.' end using errcode='P0002'; end if;
  if coalesce(p_soort,'overig') not in ('influencer','levering','bezoek','overig') then
    raise exception '%', case when p_en then 'Unknown type.' else 'Onbekende soort.' end using errcode='P0002'; end if;
  if p_tot is not null and p_van is null then
    raise exception '%', case when p_en then 'Enter a start time too.' else 'Vul ook een begintijd in.' end using errcode='P0002'; end if;
  if p_van is not null and p_tot is not null and p_tot <= p_van then
    raise exception '%', case when p_en then 'The end time must be after the start time.'
                              else 'De eindtijd moet na de begintijd liggen.' end using errcode='P0002'; end if;
end $$;

-- ── Bram: lijst ──────────────────────────────────────────────────
create or replace function public.mcr_agenda_lijst(p_van date default null, p_tot date default null)
returns table(id uuid, datum date, tijd_van time, tijd_tot time, kraam_id uuid, kraam text, kleur text,
              soort text, titel text, contact text, notitie text, door text, door_manager boolean, op timestamptz)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select a.id, a.datum, a.tijd_van, a.tijd_tot, a.kraam_id, k.naam, coalesce(k.kleur,'#6B6A66'),
         a.soort, a.titel, a.contact, a.notitie, pp.naam, coalesce(gm.kraammanager,false),
         coalesce(a.bijgewerkt_op, a.aangemaakt_op)
    from public.mcr_agenda a
    left join public.kramen k on k.id = a.kraam_id
    left join public.personeel_publiek pp on pp.id = a.aangemaakt_door
    left join public.gebruikers gm on gm.id = a.aangemaakt_door
   where public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging)
     and a.datum between coalesce(p_van, '1900-01-01') and coalesce(p_tot, '2999-12-31')
   order by a.datum, a.tijd_van nulls first, a.aangemaakt_op
) _rijen where public.mag_kraambeheer() $$;

-- ── Bram: toevoegen of wijzigen ──────────────────────────────────
create or replace function public.mcr_agenda_zetten(
  p_id uuid, p_datum date, p_van time, p_tot time, p_kraam uuid,
  p_soort text, p_titel text, p_contact text default null, p_notitie text default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_id uuid; v_vest text;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan de agenda bijwerken.' using errcode='P0002';
  end if;
  perform public.mcr_agenda_controle(p_datum, p_van, p_tot, p_soort, p_titel, false);
  select k.vestiging into v_vest from public.kramen k
   where (p_kraam is null or k.id = p_kraam)
     and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
   order by k.vestiging limit 1;
  if v_vest is null then raise exception 'Onbekende kraam.' using errcode='P0002'; end if;

  if p_id is null then
    insert into public.mcr_agenda (vestiging, datum, tijd_van, tijd_tot, kraam_id, soort, titel, contact, notitie, aangemaakt_door)
    values (v_vest, p_datum, p_van, p_tot, p_kraam, coalesce(p_soort,'overig'), btrim(p_titel),
            nullif(btrim(coalesce(p_contact,'')),''), nullif(btrim(coalesce(p_notitie,'')),''), public.huidige_gebruiker())
    returning id into v_id;
  else
    update public.mcr_agenda a
       set vestiging = v_vest, datum = p_datum, tijd_van = p_van, tijd_tot = p_tot, kraam_id = p_kraam,
           soort = coalesce(p_soort,'overig'), titel = btrim(p_titel),
           contact = nullif(btrim(coalesce(p_contact,'')),''), notitie = nullif(btrim(coalesce(p_notitie,'')),''),
           bijgewerkt_door = public.huidige_gebruiker(), bijgewerkt_op = now()
     where a.id = p_id and public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging)
    returning a.id into v_id;
    if v_id is null then raise exception 'Dit agenda-item bestaat niet meer.' using errcode='P0002'; end if;
  end if;
  return v_id;
end $$;

-- ── Bram: weghalen ───────────────────────────────────────────────
create or replace function public.mcr_agenda_weg(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan de agenda bijwerken.' using errcode='P0002';
  end if;
  delete from public.mcr_agenda a
   where a.id = p_id and public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging);
end $$;

-- ── Kraammanager: lezen (alle kramen van de eigen vestiging) ────
create or replace function public.mgr_agenda(p_van date default null, p_tot date default null)
returns table(id uuid, datum date, tijd_van time, tijd_tot time, kraam_id uuid, kraam text, kleur text,
              soort text, titel text, contact text, notitie text, door text, van_mij boolean)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select a.id, a.datum, a.tijd_van, a.tijd_tot, a.kraam_id, k.naam, coalesce(k.kleur,'#6B6A66'),
         a.soort, a.titel, a.contact, a.notitie, pp.naam,
         (a.aangemaakt_door = public.huidige_gebruiker())
    from public.mcr_agenda a
    left join public.kramen k on k.id = a.kraam_id
    left join public.personeel_publiek pp on pp.id = a.aangemaakt_door
   where a.vestiging = (select g.vestiging from public.gebruikers g where g.id = public.huidige_gebruiker())
     and a.datum between coalesce(p_van, current_date) and coalesce(p_tot, '2999-12-31')
   order by a.datum, a.tijd_van nulls first, a.aangemaakt_op
) _rijen where public.is_kraammanager() $$;

-- ── Melding naar de beheerders als een manager iets toevoegt ─────
-- Eigenaar postgres (niet app_rpc): de beheerders staan vaak bij vestiging NL
-- en zijn voor een MCR-manager onzichtbaar via de regels op gebruikers. Alleen
-- app_rpc mag hem aanroepen; hij doet alleen iets voor een bestaand item dat een
-- kraammanager heeft gezet, en maar één keer per item.
create or replace function public.mcr_agenda_melden(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  select a.id, a.titel, a.datum, a.tijd_van, a.vestiging, k.naam as kraam, g.naam as door
    into r
    from public.mcr_agenda a
    join public.gebruikers g on g.id = a.aangemaakt_door and g.kraammanager
    left join public.kramen k on k.id = a.kraam_id
   where a.id = p_id;
  if not found then return; end if;
  if exists (select 1 from public.push_wachtrij w where w.agenda_id = p_id) then return; end if;
  insert into public.push_wachtrij (gebruiker_id, soort, agenda_id, regel)
  select b.id, 'mcr_agenda_manager', r.id,
         coalesce(r.door,'Een kraammanager') || ': ' || r.titel
           || ' (' || to_char(r.datum,'DD-MM') || coalesce(' ' || to_char(r.tijd_van,'HH24.MI'),'')
           || ', ' || coalesce(r.kraam,'alle kramen') || ')'
    from public.gebruikers b
   where b.rol = 'beheerder' and b.gearchiveerd_op is null
     and (coalesce(b.alle_vestigingen,false) or b.vestiging = r.vestiging);
end $$;
revoke all on function public.mcr_agenda_melden(uuid) from public, anon, authenticated;
grant execute on function public.mcr_agenda_melden(uuid) to app_rpc, service_role;

-- ── Kraammanager: toevoegen of wijzigen (eigen kraam, eigen items) ─
create or replace function public.mgr_agenda_zetten(
  p_id uuid, p_datum date, p_van time, p_tot time, p_kraam uuid,
  p_soort text, p_titel text, p_contact text default null, p_notitie text default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker(); v_id uuid; v_vest text; v_mijn uuid; v_kraam uuid := p_kraam;
        v_naam text;
begin
  if not public.is_kraammanager() then
    raise exception 'Only stall managers can add to the calendar.' using errcode='P0002';
  end if;
  perform public.mcr_agenda_controle(p_datum, p_van, p_tot, p_soort, p_titel, true);
  select g.vestiging, g.manager_kraam_id, g.naam into v_vest, v_mijn, v_naam from public.gebruikers g where g.id = v_uid;
  -- Manager van één kraam: altijd die kraam. Manager van alle kramen: elke kraam (of alle).
  if v_mijn is not null then
    if v_kraam is not null and v_kraam <> v_mijn then
      raise exception 'You can only add things for your own stall.' using errcode='P0002';
    end if;
    v_kraam := v_mijn;
  elsif v_kraam is not null and not exists (select 1 from public.kramen k where k.id = v_kraam and k.vestiging = v_vest) then
    raise exception 'Unknown stall.' using errcode='P0002';
  end if;

  if p_id is null then
    insert into public.mcr_agenda (vestiging, datum, tijd_van, tijd_tot, kraam_id, soort, titel, contact, notitie, aangemaakt_door)
    values (v_vest, p_datum, p_van, p_tot, v_kraam, coalesce(p_soort,'overig'), btrim(p_titel),
            nullif(btrim(coalesce(p_contact,'')),''), nullif(btrim(coalesce(p_notitie,'')),''), v_uid)
    returning id into v_id;
    -- Bram (en wie MCR beheert) krijgt een melding.
    perform public.mcr_agenda_melden(v_id);
  else
    update public.mcr_agenda a
       set datum = p_datum, tijd_van = p_van, tijd_tot = p_tot, kraam_id = v_kraam,
           soort = coalesce(p_soort,'overig'), titel = btrim(p_titel),
           contact = nullif(btrim(coalesce(p_contact,'')),''), notitie = nullif(btrim(coalesce(p_notitie,'')),''),
           bijgewerkt_door = v_uid, bijgewerkt_op = now()
     where a.id = p_id and a.aangemaakt_door = v_uid and a.vestiging = v_vest
    returning a.id into v_id;
    if v_id is null then raise exception 'You can only change things you added yourself.' using errcode='P0002'; end if;
  end if;
  return v_id;
end $$;

create or replace function public.mgr_agenda_weg(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker(); n int;
begin
  if not public.is_kraammanager() then
    raise exception 'Only stall managers can change the calendar.' using errcode='P0002';
  end if;
  delete from public.mcr_agenda a where a.id = p_id and a.aangemaakt_door = v_uid;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'You can only remove things you added yourself.' using errcode='P0002'; end if;
end $$;

alter function public.mcr_agenda_controle(date,time,time,text,text,boolean) owner to app_rpc;
alter function public.mcr_agenda_lijst(date,date) owner to app_rpc;
alter function public.mcr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) owner to app_rpc;
alter function public.mcr_agenda_weg(uuid) owner to app_rpc;
alter function public.mgr_agenda(date,date) owner to app_rpc;
alter function public.mgr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) owner to app_rpc;
alter function public.mgr_agenda_weg(uuid) owner to app_rpc;
revoke all on function public.mcr_agenda_controle(date,time,time,text,text,boolean) from public, anon, authenticated;
revoke all on function public.mcr_agenda_lijst(date,date) from public, anon;
revoke all on function public.mcr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) from public, anon;
revoke all on function public.mcr_agenda_weg(uuid) from public, anon;
revoke all on function public.mgr_agenda(date,date) from public, anon;
revoke all on function public.mgr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) from public, anon;
revoke all on function public.mgr_agenda_weg(uuid) from public, anon;
grant execute on function public.mcr_agenda_lijst(date,date) to authenticated, service_role;
grant execute on function public.mcr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) to authenticated, service_role;
grant execute on function public.mcr_agenda_weg(uuid) to authenticated, service_role;
grant execute on function public.mgr_agenda(date,date) to authenticated, service_role;
grant execute on function public.mgr_agenda_zetten(uuid,date,time,time,uuid,text,text,text,text) to authenticated, service_role;
grant execute on function public.mgr_agenda_weg(uuid) to authenticated, service_role;

-- ── Meldingen: soort mcr_agenda_manager ──────────────────────────
create or replace function public.push_wachtrij_bundels()
 returns table(gebruiker_id uuid, push_token text, push_platform text, ids bigint[], soort text, titel text, bericht text, pagina text)
 language plpgsql security definer set search_path to 'public'
as $function$
#variable_conflict use_column
declare v_uur int := extract(hour from (now() at time zone 'Europe/London'))::int;
begin
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
      or not exists (select 1 from public.gebruikers g where g.id = w.gebruiker_id and g.push_token is not null and g.gearchiveerd_op is null)
      or w.aangemaakt_op < now() - interval '3 days');

  -- 's Nachts niets (Engelse tijd 22:00–08:00): het blijft staan tot de ochtend.
  if v_uur >= 22 or v_uur < 8 then return; end if;

  return query
  with w as (
    select x.*,
           exists (select 1 from public.mcr_shift_ruil r where r.shift_id = x.shift_id and r.gebruiker_id = x.gebruiker_id
                     and r.status in ('overgenomen','vrijgegeven')) as via_ruil
      from public.push_wachtrij x
     where x.verwerkt_op is null and x.aangemaakt_op < now() - interval '2 minutes'
  ), g as (
    select w.gebruiker_id, w.soort, array_agg(w.id order by w.id) as ids, count(*)::int as n,
           string_agg(w.regel, E'\n' order by w.id) as regels, bool_and(w.via_ruil) as via_ruil
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
           else 'TC Group' end,
         case g.soort
           when 'mcr_eraf' then 'You''re off the rota for: ' || replace(g.regels, E'\n', '; ')
           when 'mcr_ruil_ok' then g.regels || E'\nYou stay on the rota until someone takes over.'
           when 'mcr_ruil_nee' then g.regels || E'\nYou''re still on the rota for this shift.'
           when 'mcr_ruil_open' then g.regels || E'\nTap to ask for it.'
           when 'mcr_ruil_gevraagd' then g.regels || E'\nKeur goed of af bij Manchester → Shifts.'
           when 'mcr_agenda_manager' then g.regels || E'\nBekijk het bij Manchester → Agenda.'
           else g.regels end,
         case when g.soort = 'mcr_ruil_open' then 'mcr-open'
              when g.soort = 'mcr_ruil_gevraagd' then 'mcr-beheer'
              when g.soort = 'mcr_agenda_manager' then 'mcr-agenda'
              else 'mcr-shifts' end
    from g join public.gebruikers u on u.id = g.gebruiker_id
   where u.push_token is not null;
end $function$;
