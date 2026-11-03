-- Manchester: kleding per stuk en de dagafsluiting door de kraammanager (3 nov 2026)
--
-- Bram: "Ik wil dat zij ook kleding kunnen toewijzen aan mensen: long sleeve polo
-- £25 p/stuk, schort £25 p/stuk" (borg). En: "elke dag de dag moeten afsluiten
-- met een check list: schoonmaaklijst ingevuld, gas dicht, voorraad nodig?,
-- beoordeling invullen bij wie er geen heeft (Bram ziet wat is ingevuld),
-- beoordeling aanpassen, uren accorderen (pauzes, te laat, niet komen opdagen)."
-- Antwoorden: £25 is borg; manager controleert, Bram geeft nog steeds akkoord;
-- in het weekend sluit de weekmanager af; 1 minuut is al te laat; schoonmaaklijst
-- is alleen een vinkje.
--
-- * gebruikers.kleding_polo / kleding_schort (+ door/op). kleding_uit blijft de
--   som, zodat bestaande schermen kloppen. Borg = polo × borg_polo + schort ×
--   borg_schort (instellingen MCR, standaard 25). Log in mcr_kleding_log.
-- * mcr_dagcontrole: per kraam, dag en persoon wat de manager vond (ok, te laat,
--   niet te laat, niet gekomen, afgemeld, naar huis gestuurd).
-- * mcr_dagafsluiting: per kraam en dag de checklist en de voorraad. Bij het
--   afsluiten worden voorvallen gemaakt (te laat / niet gekomen / afgemeld,
--   zonder boete) en krijgt Bram een melding.
-- * Herinnering 45 minuten na sluiting (manager in het Engels, Bram in het
--   Nederlands) via push_wachtrij_bundels; die soorten mogen tot middernacht.
--
-- Let op: geen enkele regel in dit bestand gebruikt het woord voor weghalen of
-- het weghalen van objecten; de database-tool annuleert zulke migraties.

-- ── Kleding ───────────────────────────────────────────────────────
alter table public.gebruikers add column if not exists kleding_polo   integer not null default 0;
alter table public.gebruikers add column if not exists kleding_schort integer not null default 0;
alter table public.gebruikers add column if not exists kleding_door   uuid;
alter table public.gebruikers add column if not exists kleding_gewijzigd_op timestamptz;

-- Wat er al stond (alleen een aantal) telt als polo's.
update public.gebruikers set kleding_polo = kleding_uit
 where coalesce(kleding_uit,0) > 0 and kleding_polo = 0 and kleding_schort = 0;

insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving)
select 'MCR', x.s, '25', x.o
  from (values ('borg_polo','Borg per long sleeve polo (£)'), ('borg_schort','Borg per schort (£)')) x(s,o)
 where exists (select 1 from public.vestigingen v where v.code = 'MCR')
   and not exists (select 1 from public.vestiging_instellingen i where i.vestiging = 'MCR' and i.sleutel = x.s);

create table if not exists public.mcr_kleding_log (
  id           uuid primary key default gen_random_uuid(),
  gebruiker_id uuid not null,
  door         uuid,
  op           timestamptz not null default now(),
  polo_van     integer not null, polo_naar   integer not null,
  schort_van   integer not null, schort_naar integer not null
);
create index if not exists mcr_kleding_log_g on public.mcr_kleding_log (gebruiker_id, op);
revoke all on public.mcr_kleding_log from anon, authenticated;
grant select, insert, update on public.mcr_kleding_log to app_rpc, service_role;
alter table public.mcr_kleding_log enable row level security;
create policy "rpc mcr_kleding_log" on public.mcr_kleding_log for all to app_rpc using (true) with check (true);
create trigger zz_audit after insert or update on public.mcr_kleding_log
  for each row execute function public.audit_schrijf();

create or replace function public.mcr_kleding_borg(p_vest text, p_polo integer, p_schort integer)
returns numeric
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(p_polo,0) * coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                                         where i.vestiging = p_vest and i.sleutel = 'borg_polo'), 25)
       + coalesce(p_schort,0) * coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                                           where i.vestiging = p_vest and i.sleutel = 'borg_schort'), 25)
$$;

-- Gedeeld: zet de stuks, houdt kleding_uit/kleding_op bij en logt. Alleen via de
-- twee functies hieronder (die de rechten controleren).
create or replace function public.mcr_kleding_bijwerken(p_id uuid, p_polo integer, p_schort integer)
returns boolean
language plpgsql security definer set search_path to 'public'
as $$
declare g record; v_polo int := coalesce(p_polo,0); v_schort int := coalesce(p_schort,0);
begin
  if v_polo not between 0 and 5 or v_schort not between 0 and 5 then
    raise exception 'Choose 0 to 5 pieces.' using errcode='P0002';
  end if;
  select * into g from public.gebruikers x where x.id = p_id;
  if not found then return false; end if;
  if g.kleding_polo = v_polo and g.kleding_schort = v_schort then return false; end if;
  update public.gebruikers
     set kleding_polo = v_polo, kleding_schort = v_schort, kleding_uit = v_polo + v_schort,
         kleding_op = case when v_polo + v_schort = 0 then null else coalesce(kleding_op, current_date) end,
         kleding_door = public.huidige_gebruiker(), kleding_gewijzigd_op = now()
   where id = p_id;
  insert into public.mcr_kleding_log (gebruiker_id, door, polo_van, polo_naar, schort_van, schort_naar)
  values (p_id, public.huidige_gebruiker(), g.kleding_polo, v_polo, g.kleding_schort, v_schort);
  return true;
end $$;

-- Kraammanager: kleding van iemand van de eigen vestiging (niet van zichzelf).
create or replace function public.mgr_kleding_zetten(p_id uuid, p_polo integer, p_schort integer)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.is_kraammanager() then
    raise exception 'Only a stall manager can hand out uniform.' using errcode='P0002';
  end if;
  if not exists (select 1 from public.gebruikers x
                  where x.id = p_id and x.rol <> 'beheerder' and x.id <> public.huidige_gebruiker()
                    and coalesce(x.goedgekeurd,false) and x.gearchiveerd_op is null
                    and public.vest_ok(x.vestiging) and public.in_actieve_vestiging(x.vestiging)) then
    raise exception 'That person does not exist.' using errcode='P0002';
  end if;
  perform public.mcr_kleding_bijwerken(p_id, p_polo, p_schort);
end $$;

-- Bram: hetzelfde, in het Nederlands.
create or replace function public.mcr_kleding_zetten(p_id uuid, p_polo integer, p_schort integer)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  if not exists (select 1 from public.gebruikers x
                  where x.id = p_id and x.vestiging in (select unnest(public.zichtbare_vestigingen()))) then
    raise exception 'Die persoon bestaat niet.' using errcode='P0002';
  end if;
  if coalesce(p_polo,0) not between 0 and 5 or coalesce(p_schort,0) not between 0 and 5 then
    raise exception 'Kies 0 tot 5 stuks.' using errcode='P0002';
  end if;
  perform public.mcr_kleding_bijwerken(p_id, p_polo, p_schort);
end $$;

-- Bram: kleding per persoon (los van mcr_mensen, waarvan de kolommen vastliggen).
create or replace function public.mcr_kleding_lijst()
returns table(id uuid, polo integer, schort integer, maat text, borg numeric, door text, op timestamptz)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select g.id, g.kleding_polo, g.kleding_schort, g.shirtmaat,
         public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort), d.naam, g.kleding_gewijzigd_op
    from public.gebruikers g
    left join public.gebruikers d on d.id = g.kleding_door
   where g.rol <> 'beheerder' and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
 ) _r where public.mag_kraambeheer() $$;

-- Kraammanager: het team (beoordeling + kleding).
create or replace function public.mgr_team()
returns table(id uuid, naam text, telefoon text, beoordeling text, beoordeling_door text, beoordeling_op timestamptz,
              shifts integer, laatste date, maat text, polo integer, schort integer, borg numeric,
              kleding_door text, kleding_op timestamptz)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select g.id, g.naam, g.telefoon, g.beoordeling, bd.naam, g.beoordeling_op,
         (select count(*)::int from public.klus_gebruikers kg join public.klussen kl on kl.id = kg.klus_id
           where kg.gebruiker_id = g.id and kl.kraam_id is not null),
         (select max(kl.datum) from public.klus_gebruikers kg join public.klussen kl on kl.id = kg.klus_id
           where kg.gebruiker_id = g.id and kl.kraam_id is not null and kl.datum <= current_date),
         g.shirtmaat, g.kleding_polo, g.kleding_schort,
         public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort), kd.naam, g.kleding_gewijzigd_op
    from public.gebruikers g
    left join public.gebruikers bd on bd.id = g.beoordeling_door
    left join public.gebruikers kd on kd.id = g.kleding_door
   where g.rol <> 'beheerder' and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null
     and not coalesce(g.kraammanager,false)
     and g.id <> public.huidige_gebruiker()
     and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
   order by g.naam
 ) _r where public.is_kraammanager() $$;

-- Bestaand: Bram zet bij Mensen het aantal op 0 → ook polo en schort op 0.
create or replace function public.mcr_persoon_opslaan(p_id uuid, p_uurloon numeric, p_beoordeling text, p_goedkeuren boolean, p_kleding integer DEFAULT NULL::integer)
 returns void
 language plpgsql security definer set search_path to 'public'
as $function$
declare g record; v_b text;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  select * into g from public.gebruikers x
   where x.id = p_id and x.vestiging in (select unnest(public.zichtbare_vestigingen()));
  if not found then raise exception 'Die persoon bestaat niet.' using errcode='P0002'; end if;
  v_b := nullif(btrim(coalesce(p_beoordeling,'')),'');

  update public.gebruikers
     set uurloon     = coalesce(p_uurloon, uurloon),
         beoordeling = coalesce(v_b, beoordeling),
         beoordeling_door = case when v_b is not null and v_b is distinct from beoordeling then public.huidige_gebruiker() else beoordeling_door end,
         beoordeling_op   = case when v_b is not null and v_b is distinct from beoordeling then now() else beoordeling_op end,
         kleding_uit = coalesce(p_kleding, kleding_uit),
         kleding_op  = case when p_kleding is not null and p_kleding > 0 and kleding_op is null
                            then current_date
                            when p_kleding = 0 then null
                            else kleding_op end,
         kleding_polo   = case when p_kleding = 0 then 0 else kleding_polo end,
         kleding_schort = case when p_kleding = 0 then 0 else kleding_schort end,
         goedgekeurd = case when p_goedkeuren then true else goedgekeurd end
   where id = p_id;
end $function$;

-- ── Dagcontrole en dagafsluiting ──────────────────────────────────
create table if not exists public.mcr_dagcontrole (
  id              uuid primary key default gen_random_uuid(),
  kraam_id        uuid not null references public.kramen(id),
  datum           date not null,
  gebruiker_id    uuid not null,
  shift_id        uuid,
  uren_id         uuid,
  uitkomst        text not null check (uitkomst in ('ok','te_laat','niet_te_laat','niet_gekomen','afgemeld','naar_huis')),
  minuten_te_laat integer not null default 0,
  voorval_id      uuid,
  door            uuid,
  op              timestamptz not null default now(),
  unique (kraam_id, datum, gebruiker_id)
);
revoke all on public.mcr_dagcontrole from anon, authenticated;
grant select, insert, update on public.mcr_dagcontrole to app_rpc, service_role;
alter table public.mcr_dagcontrole enable row level security;
create policy "rpc mcr_dagcontrole" on public.mcr_dagcontrole for all to app_rpc using (true) with check (true);
create trigger zz_audit   after insert or update on public.mcr_dagcontrole for each row execute function public.audit_schrijf();
create trigger zz_signaal after insert or update on public.mcr_dagcontrole for each statement execute function public.signaal_geven();

create table if not exists public.mcr_dagafsluiting (
  id              uuid primary key default gen_random_uuid(),
  vestiging       text not null default 'MCR',
  kraam_id        uuid not null references public.kramen(id),
  datum           date not null,
  schoonmaak      boolean not null,
  gas             boolean not null,
  voorraad_nodig  boolean not null,
  voorraad        text[] not null default '{}',
  voorraad_tekst  text,
  beoordelingen   jsonb not null default '[]',
  kleding         jsonb not null default '[]',
  afgesloten_door uuid,
  afgesloten_op   timestamptz,
  heropend_door   uuid,
  heropend_op     timestamptz,
  unique (kraam_id, datum)
);
revoke all on public.mcr_dagafsluiting from anon, authenticated;
grant select, insert, update on public.mcr_dagafsluiting to app_rpc, service_role;
alter table public.mcr_dagafsluiting enable row level security;
create policy "rpc mcr_dagafsluiting" on public.mcr_dagafsluiting for all to app_rpc using (true) with check (true);
create trigger zz_audit   after insert or update on public.mcr_dagafsluiting for each row execute function public.audit_schrijf();
create trigger zz_signaal after insert or update on public.mcr_dagafsluiting for each statement execute function public.signaal_geven();

-- Mag de ingelogde manager deze kraam afsluiten? (eigen kraam, of alle kramen)
create or replace function public.mgr_kraam_ok(p_kraam uuid)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.is_kraammanager() and exists (
    select 1 from public.kramen k, public.gebruikers m
     where k.id = p_kraam and k.actief and m.id = public.huidige_gebruiker()
       and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
       and (m.manager_kraam_id is null or m.manager_kraam_id = k.id))
$$;

-- Wie moet deze kraam op deze dag afsluiten? De weekmanager(s); is er geen,
-- dan de manager van die kraam; is die er ook niet, dan de managers van alle kramen.
create or replace function public.mcr_afsluiters(p_kraam uuid, p_datum date)
returns setof uuid
language sql stable security definer set search_path to 'public'
as $$
  with wk as (
    select w.gebruiker_id from public.mcr_manager_week w join public.gebruikers g on g.id = w.gebruiker_id
     where w.kraam_id = p_kraam and w.week_start = date_trunc('week', p_datum)::date
       and g.kraammanager and g.gearchiveerd_op is null),
  eigen as (
    select g.id from public.gebruikers g
     where g.kraammanager and g.gearchiveerd_op is null and g.manager_kraam_id = p_kraam),
  alle as (
    select g.id from public.gebruikers g join public.kramen k on k.id = p_kraam and k.vestiging = g.vestiging
     where g.kraammanager and g.gearchiveerd_op is null and g.manager_kraam_id is null)
  select gebruiker_id from wk
  union all select id from eigen where not exists (select 1 from wk)
  union all select id from alle  where not exists (select 1 from wk) and not exists (select 1 from eigen)
$$;

-- Wie hoort er bij een kraamdag: ingedeeld of geklokt (beheerders tellen niet mee).
create or replace function public.mcr_dagmensen(p_kraam uuid, p_datum date)
returns table(gebruiker_id uuid, shift_id uuid, start_tijd time, eind_tijd time, uren_id uuid,
              ingeklokt_op timestamptz, uitgeklokt_op timestamptz, pauze integer, uren_status text, minuten_te_laat integer)
language sql stable security definer set search_path to 'public'
as $$
  with kl as (select k.id from public.klussen k where k.kraam_id = p_kraam and k.datum = p_datum),
  r as (select kg.gebruiker_id gid, (array_agg(s.id order by s.start_tijd))[1] sid,
               min(s.start_tijd) st, max(s.eind_tijd) et
          from public.klus_gebruikers kg join public.klus_shifts s on s.id = kg.shift_id
         where kg.klus_id in (select id from kl) group by kg.gebruiker_id),
  u as (select ur.gebruiker_id gid, (array_agg(ur.id order by ur.ingeklokt_op))[1] uid
          from public.urenregistraties ur where ur.klus_id in (select id from kl) group by ur.gebruiker_id),
  ids as (select gid from r union select gid from u)
  select ids.gid, r.sid, r.st, r.et, ur.id, ur.ingeklokt_op, ur.uitgeklokt_op, coalesce(ur.pauze_minuten,0), ur.status,
         case when r.st is null or ur.ingeklokt_op is null then 0
              else greatest(0, floor(extract(epoch from (ur.ingeklokt_op - ((p_datum + r.st) at time zone 'Europe/London')))/60))::int end
    from ids
    join public.gebruikers g on g.id = ids.gid and g.rol <> 'beheerder'
    left join r on r.gid = ids.gid
    left join u on u.gid = ids.gid
    left join public.urenregistraties ur on ur.id = u.uid
$$;

-- Manager: welke kraamdagen staan open of zijn gesloten (vandaag en 7 dagen terug).
create or replace function public.mgr_afsluit_overzicht()
returns table(kraam_id uuid, kraam text, kleur text, datum date, mensen integer, afgesloten_op timestamptz,
              door text, mijn_taak boolean)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select k.id, k.naam, coalesce(k.kleur,'#6B6A66'), kl.datum,
         (select count(*)::int from public.mcr_dagmensen(k.id, kl.datum)),
         a.afgesloten_op, d.naam,
         public.huidige_gebruiker() in (select public.mcr_afsluiters(k.id, kl.datum))
    from public.kramen k
    join public.klussen kl on kl.kraam_id = k.id
         and kl.datum between (now() at time zone 'Europe/London')::date - 7 and (now() at time zone 'Europe/London')::date
    left join public.mcr_dagafsluiting a on a.kraam_id = k.id and a.datum = kl.datum
    left join public.gebruikers d on d.id = a.afgesloten_door
   where public.mgr_kraam_ok(k.id)
     and exists (select 1 from public.klus_shifts s join public.klus_gebruikers kg on kg.shift_id = s.id where s.klus_id = kl.id)
   order by kl.datum desc, k.volgorde, k.naam
 ) _r where public.is_kraammanager() $$;

-- Manager: alles voor de afsluiting van één kraamdag.
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
        'controle', c.uitkomst, 'controle_min', c.minuten_te_laat, 'controle_door', cd.naam, 'controle_op', c.op)
        order by m.start_tijd nulls last, g.naam)
        from public.mcr_dagmensen(p_kraam, p_datum) m
        join public.gebruikers g on g.id = m.gebruiker_id
        left join public.mcr_dagcontrole c on c.kraam_id = p_kraam and c.datum = p_datum and c.gebruiker_id = g.id
        left join public.gebruikers cd on cd.id = c.door), '[]'::jsonb)
  ) into v;
  return v;
end $$;

-- Manager: één persoon controleren.
create or replace function public.mgr_controle_zetten(p_kraam uuid, p_datum date, p_gebruiker uuid, p_uitkomst text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare m record;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only close your own stall.' using errcode='P0002';
  end if;
  if p_datum > (now() at time zone 'Europe/London')::date then
    raise exception 'You can only check today or earlier.' using errcode='P0002';
  end if;
  if exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = p_kraam and a.datum = p_datum and a.afgesloten_op is not null) then
    raise exception 'This day is already closed. Ask Bram if something needs to change.' using errcode='P0002';
  end if;
  if p_gebruiker = public.huidige_gebruiker() then
    raise exception 'You cannot check your own hours.' using errcode='P0002';
  end if;
  select * into m from public.mcr_dagmensen(p_kraam, p_datum) x where x.gebruiker_id = p_gebruiker;
  if not found then raise exception 'This person did not work at this stall that day.' using errcode='P0002'; end if;
  if m.uren_id is not null then
    if p_uitkomst not in ('ok','te_laat','niet_te_laat') then
      raise exception 'This person clocked in.' using errcode='P0002';
    end if;
    if m.uitgeklokt_op is null then
      raise exception 'Still clocked in. Fill in the finish time first.' using errcode='P0002';
    end if;
    if p_uitkomst = 'ok' and m.minuten_te_laat > 0 then
      raise exception 'Clocked in late. Choose late or not late.' using errcode='P0002';
    end if;
  elsif p_uitkomst not in ('niet_gekomen','afgemeld','naar_huis') then
    raise exception 'This person never clocked in.' using errcode='P0002';
  end if;

  insert into public.mcr_dagcontrole (kraam_id, datum, gebruiker_id, shift_id, uren_id, uitkomst, minuten_te_laat, door, op)
  values (p_kraam, p_datum, p_gebruiker, m.shift_id, m.uren_id, p_uitkomst,
          case when p_uitkomst = 'te_laat' then m.minuten_te_laat else 0 end, public.huidige_gebruiker(), now())
  on conflict (kraam_id, datum, gebruiker_id) do update
     set uitkomst = excluded.uitkomst, minuten_te_laat = excluded.minuten_te_laat, shift_id = excluded.shift_id,
         uren_id = excluded.uren_id, door = excluded.door, op = excluded.op;
end $$;

-- Melding aan Bram (eigenaar postgres: Bram staat bij een andere vestiging).
create or replace function public.mcr_dag_dicht_melden(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_regel text;
begin
  select a.*, k.naam kraam, g.naam door, kl.id klus_id into r
    from public.mcr_dagafsluiting a
    join public.kramen k on k.id = a.kraam_id
    left join public.gebruikers g on g.id = a.afgesloten_door
    left join public.klussen kl on kl.kraam_id = a.kraam_id and kl.datum = a.datum
   where a.id = p_id and a.afgesloten_op is not null;
  if not found then return; end if;
  v_regel := r.kraam || coalesce(' (' || r.door || ')','')
          || case when r.voorraad_nodig then ' · voorraad: '
                  || coalesce(nullif(array_to_string(r.voorraad, ', '),''), '')
                  || coalesce(case when array_length(r.voorraad,1) > 0 then ' — ' else '' end || nullif(r.voorraad_tekst,''), '')
                  else '' end
          || case when not r.schoonmaak then ' · schoonmaaklijst niet gedaan' else '' end;
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
  select b.id, 'mcr_dag_dicht', r.klus_id, v_regel
    from public.gebruikers b
   where b.rol = 'beheerder' and b.gearchiveerd_op is null
     and (coalesce(b.alle_vestigingen,false) or b.vestiging = r.vestiging);
end $$;
revoke all on function public.mcr_dag_dicht_melden(uuid) from public, anon, authenticated;
grant execute on function public.mcr_dag_dicht_melden(uuid) to app_rpc, service_role;

-- Manager: de dag afsluiten.
create or replace function public.mgr_dag_afsluiten(p_kraam uuid, p_datum date, p_schoonmaak boolean, p_gas boolean,
  p_voorraad boolean, p_items text[] default '{}', p_tekst text default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_uid uuid := public.huidige_gebruiker(); v_id uuid; v_namen text; v_vest text; v_klus uuid; v_van timestamptz;
        rc record; v_vv uuid; v_items text[]; v_tekst text; v_beo jsonb; v_kl jsonb;
begin
  if not public.mgr_kraam_ok(p_kraam) then
    raise exception 'You can only close your own stall.' using errcode='P0002';
  end if;
  if p_datum > (now() at time zone 'Europe/London')::date then
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
  v_items := coalesce((select array_agg(x) from (select distinct left(btrim(x),40) x from unnest(coalesce(p_items,'{}')) x
                        where btrim(x) <> '' limit 30) y), '{}');
  v_tekst := nullif(left(btrim(coalesce(p_tekst,'')),300),'');
  if p_voorraad and coalesce(array_length(v_items,1),0) = 0 and v_tekst is null then
    raise exception 'Tell Bram which stock you need.' using errcode='P0002';
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

  select k.vestiging into v_vest from public.kramen k where k.id = p_kraam;
  select kl.id into v_klus from public.klussen kl where kl.kraam_id = p_kraam and kl.datum = p_datum;

  -- Voorvallen (zonder boete; daar beslist Bram over).
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

  -- Wat de manager vandaag aan beoordelingen en kleding veranderde bij de mensen van deze dag.
  v_van := (p_datum::timestamp) at time zone 'Europe/London';
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

  insert into public.mcr_dagafsluiting (vestiging, kraam_id, datum, schoonmaak, gas, voorraad_nodig, voorraad, voorraad_tekst,
                                        beoordelingen, kleding, afgesloten_door, afgesloten_op)
  values (v_vest, p_kraam, p_datum, p_schoonmaak, p_gas, p_voorraad,
          case when p_voorraad then v_items else '{}' end, case when p_voorraad then v_tekst end, v_beo, v_kl, v_uid, now())
  on conflict (kraam_id, datum) do update
     set schoonmaak = excluded.schoonmaak, gas = excluded.gas, voorraad_nodig = excluded.voorraad_nodig,
         voorraad = excluded.voorraad, voorraad_tekst = excluded.voorraad_tekst,
         beoordelingen = public.mcr_dagafsluiting.beoordelingen || excluded.beoordelingen,
         kleding = public.mcr_dagafsluiting.kleding || excluded.kleding,
         afgesloten_door = excluded.afgesloten_door, afgesloten_op = excluded.afgesloten_op
  returning id into v_id;

  perform public.mcr_dag_dicht_melden(v_id);
  return v_id;
end $$;

-- Bram: de afsluitingen van één dag, per kraam met diensten.
create or replace function public.mcr_afsluitingen(p_datum date)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(x.j order by x.volgorde, x.naam), '[]'::jsonb) from (
    select k.volgorde, k.naam, jsonb_build_object(
      'kraam_id', k.id, 'kraam', k.naam, 'kleur', coalesce(k.kleur,'#6B6A66'), 'datum', p_datum,
      'afsluiters', (select string_agg(g.naam, ', ') from public.gebruikers g where g.id in (select public.mcr_afsluiters(k.id, p_datum))),
      'afgesloten', case when a.afgesloten_op is null then null else jsonb_build_object(
          'op', a.afgesloten_op, 'door', d.naam, 'schoonmaak', a.schoonmaak, 'gas', a.gas,
          'voorraad_nodig', a.voorraad_nodig, 'voorraad', a.voorraad, 'voorraad_tekst', a.voorraad_tekst,
          'beoordelingen', a.beoordelingen, 'kleding', a.kleding) end,
      'heropend', case when a.heropend_op is null then null else jsonb_build_object('op', a.heropend_op, 'door', hd.naam) end,
      'controles', coalesce((
        select jsonb_agg(jsonb_build_object('gebruiker_id', g.id, 'naam', g.naam, 'uitkomst', c.uitkomst,
                 'minuten', c.minuten_te_laat, 'uren_id', c.uren_id, 'uren_status', u.status,
                 'voorval_id', c.voorval_id, 'boete', v.boete, 'door', cd.naam) order by g.naam)
          from public.mcr_dagcontrole c join public.gebruikers g on g.id = c.gebruiker_id
          left join public.urenregistraties u on u.id = c.uren_id
          left join public.mcr_voorvallen v on v.id = c.voorval_id
          left join public.gebruikers cd on cd.id = c.door
         where c.kraam_id = k.id and c.datum = p_datum), '[]'::jsonb),
      'mensen', (select count(*)::int from public.mcr_dagmensen(k.id, p_datum)),
      'te_akkoord', (select count(*)::int from public.mcr_dagcontrole c join public.urenregistraties u on u.id = c.uren_id
                      where c.kraam_id = k.id and c.datum = p_datum and c.uitkomst in ('ok','te_laat','niet_te_laat')
                        and u.status = 'wacht' and u.uitgeklokt_op is not null and u.factuur_id is null)) j
      from public.kramen k
      join public.klussen kl on kl.kraam_id = k.id and kl.datum = p_datum
      left join public.mcr_dagafsluiting a on a.kraam_id = k.id and a.datum = p_datum
      left join public.gebruikers d on d.id = a.afgesloten_door
      left join public.gebruikers hd on hd.id = a.heropend_door
     where k.actief and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
       and exists (select 1 from public.klus_shifts s join public.klus_gebruikers kg on kg.shift_id = s.id where s.klus_id = kl.id)
  ) x where public.mag_kraambeheer()
$$;

-- Bram: akkoord op alle uren die de manager heeft gecontroleerd.
create or replace function public.mcr_afsluiting_akkoord(p_kraam uuid, p_datum date)
returns integer
language plpgsql security definer set search_path to 'public'
as $$
declare n int;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  update public.urenregistraties u set status = 'goedgekeurd'
    from public.mcr_dagcontrole c
   where c.uren_id = u.id and c.kraam_id = p_kraam and c.datum = p_datum
     and c.uitkomst in ('ok','te_laat','niet_te_laat')
     and u.status = 'wacht' and u.uitgeklokt_op is not null and u.factuur_id is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Bram: boete op een voorval zetten (bv. £50 bij niet komen opdagen).
create or replace function public.mcr_voorval_boete(p_id uuid, p_boete numeric)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  if coalesce(p_boete,0) < 0 or coalesce(p_boete,0) > 500 then
    raise exception 'Boete tussen 0 en 500.' using errcode='P0002';
  end if;
  update public.mcr_voorvallen v set boete = coalesce(p_boete,0)
   where v.id = p_id and v.vestiging in (select unnest(public.zichtbare_vestigingen()));
end $$;

-- Bram: een afgesloten dag weer openzetten (de manager kan dan opnieuw controleren en afsluiten).
create or replace function public.mcr_afsluiting_heropenen(p_kraam uuid, p_datum date)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  update public.mcr_dagafsluiting
     set afgesloten_op = null, heropend_op = now(), heropend_door = public.huidige_gebruiker()
   where kraam_id = p_kraam and datum = p_datum and afgesloten_op is not null;
end $$;

alter function public.mcr_kleding_borg(text,integer,integer) owner to app_rpc;
alter function public.mcr_kleding_bijwerken(uuid,integer,integer) owner to app_rpc;
alter function public.mgr_kleding_zetten(uuid,integer,integer) owner to app_rpc;
alter function public.mcr_kleding_zetten(uuid,integer,integer) owner to app_rpc;
alter function public.mcr_kleding_lijst() owner to app_rpc;
alter function public.mgr_team() owner to app_rpc;
alter function public.mgr_kraam_ok(uuid) owner to app_rpc;
alter function public.mcr_afsluiters(uuid,date) owner to app_rpc;
alter function public.mcr_dagmensen(uuid,date) owner to app_rpc;
alter function public.mgr_afsluit_overzicht() owner to app_rpc;
alter function public.mgr_afsluiting(uuid,date) owner to app_rpc;
alter function public.mgr_controle_zetten(uuid,date,uuid,text) owner to app_rpc;
alter function public.mgr_dag_afsluiten(uuid,date,boolean,boolean,boolean,text[],text) owner to app_rpc;
alter function public.mcr_afsluitingen(date) owner to app_rpc;
alter function public.mcr_afsluiting_akkoord(uuid,date) owner to app_rpc;
alter function public.mcr_voorval_boete(uuid,numeric) owner to app_rpc;
alter function public.mcr_afsluiting_heropenen(uuid,date) owner to app_rpc;

-- Interne hulpfuncties: niet direct aan te roepen vanuit de app.
revoke all on function public.mcr_kleding_bijwerken(uuid,integer,integer) from public, anon, authenticated;
revoke all on function public.mcr_afsluiters(uuid,date) from public, anon, authenticated;
revoke all on function public.mcr_dagmensen(uuid,date) from public, anon, authenticated;
grant execute on function public.mcr_kleding_bijwerken(uuid,integer,integer) to app_rpc, service_role;
grant execute on function public.mcr_afsluiters(uuid,date) to app_rpc, service_role;
grant execute on function public.mcr_dagmensen(uuid,date) to app_rpc, service_role;

grant execute on function public.mgr_kleding_zetten(uuid,integer,integer) to authenticated, service_role;
grant execute on function public.mcr_kleding_zetten(uuid,integer,integer) to authenticated, service_role;
grant execute on function public.mcr_kleding_lijst() to authenticated, service_role;
grant execute on function public.mgr_team() to authenticated, service_role;
grant execute on function public.mgr_afsluit_overzicht() to authenticated, service_role;
grant execute on function public.mgr_afsluiting(uuid,date) to authenticated, service_role;
grant execute on function public.mgr_controle_zetten(uuid,date,uuid,text) to authenticated, service_role;
grant execute on function public.mgr_dag_afsluiten(uuid,date,boolean,boolean,boolean,text[],text) to authenticated, service_role;
grant execute on function public.mcr_afsluitingen(date) to authenticated, service_role;
grant execute on function public.mcr_afsluiting_akkoord(uuid,date) to authenticated, service_role;
grant execute on function public.mcr_voorval_boete(uuid,numeric) to authenticated, service_role;
grant execute on function public.mcr_afsluiting_heropenen(uuid,date) to authenticated, service_role;

-- ── Borg in Mensen: per stuk (polo en schort) ─────────────────────
CREATE OR REPLACE FUNCTION public.mcr_mensen()
 RETURNS TABLE(id uuid, naam text, email text, telefoon text, geboortedatum date, leeftijd integer, uurloon numeric, goedgekeurd boolean, iban text, utr text, aangebracht_door text, beoordeling text, eigen_opmerking text, max_dagen integer, vroegste_start time without time zone, shifts integer, uren numeric, verdiend numeric, beschikbaar integer, huisregels_op timestamp with time zone, gearchiveerd_op timestamp with time zone, archief_reden text, kleding_uit integer, kleding_op date, borg numeric, niet_gekomen integer, afgemeld integer, te_laat integer, boete_open numeric, kraammanager boolean, beoordeling_door text, beoordeling_op timestamp with time zone, manager_kraam_id uuid, manager_kraam text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select * from (
  select g.id, g.naam, g.email, g.telefoon, g.geboortedatum,
         case when g.geboortedatum is not null
              then extract(year from age(current_date, g.geboortedatum))::int end,
         g.uurloon, g.goedgekeurd, g.iban, g.utr, g.aangebracht_door, g.beoordeling,
         g.eigen_opmerking, g.max_dagen_per_week, g.vroegste_start,
         (select count(*)::int from public.klus_gebruikers kg
            join public.klussen kl on kl.id = kg.klus_id
           where kg.gebruiker_id = g.id and kl.kraam_id is not null),
         coalesce((select round(sum(u.totaal_minuten)::numeric/60,2) from public.urenregistraties u
            join public.klussen kl on kl.id = u.klus_id
           where u.gebruiker_id = g.id and kl.kraam_id is not null and u.status='goedgekeurd'),0),
         coalesce((select round(sum(u.totaal_minuten)::numeric/60*coalesce(g.uurloon,0),2)
            from public.urenregistraties u join public.klussen kl on kl.id = u.klus_id
           where u.gebruiker_id = g.id and kl.kraam_id is not null and u.status='goedgekeurd'),0),
         (select count(*)::int from public.beschikbaarheid b
           where b.gebruiker_id = g.id and b.soort='beschikbaar' and b.datum_start >= current_date),
         (select max(a.op) from public.huisregels_akkoord a where a.gebruiker_id = g.id),
         g.gearchiveerd_op, g.archief_reden,
         coalesce(g.kleding_uit,0), g.kleding_op,
         public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort),
         (select count(*)::int from public.mcr_voorvallen v where v.gebruiker_id=g.id and v.soort='niet_gekomen'),
         (select count(*)::int from public.mcr_voorvallen v where v.gebruiker_id=g.id and v.soort='afgemeld'),
         (select count(*)::int from public.mcr_voorvallen v where v.gebruiker_id=g.id and v.soort='te_laat'),
         coalesce((select sum(v.boete) from public.mcr_voorvallen v where v.gebruiker_id=g.id),0),
         g.kraammanager, bd.naam, g.beoordeling_op, g.manager_kraam_id, mk.naam
    from public.gebruikers g
    left join public.gebruikers bd on bd.id = g.beoordeling_door
    left join public.kramen mk on mk.id = g.manager_kraam_id
   where g.rol <> 'beheerder'
     and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
   order by (g.gearchiveerd_op is not null), g.goedgekeurd nulls first, g.naam
 ) _rijen where public.mag_kraambeheer()
$function$;

-- ── Meldingen: herinnering 45 min na sluiting + "kraam afgesloten" ─
-- Deze drie soorten mogen tot middernacht (de manager is dan nog bij de kraam);
-- de rest blijft 's nachts (22:00–08:00) wachten zoals altijd.
CREATE OR REPLACE FUNCTION public.push_wachtrij_bundels()
 RETURNS TABLE(gebruiker_id uuid, push_token text, push_platform text, ids bigint[], soort text, titel text, bericht text, pagina text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare v_nu timestamp := (now() at time zone 'Europe/London');
        v_uur int := extract(hour from (now() at time zone 'Europe/London'))::int;
begin
  -- Herinnering: 45 minuten na sluiting nog niet afgesloten (één keer per kraam per dag).
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
      or not exists (select 1 from public.gebruikers g where g.id = w.gebruiker_id and g.push_token is not null and g.gearchiveerd_op is null)
      or w.aangemaakt_op < now() - interval '3 days');

  -- 's Nachts niets (Engelse tijd 22:00–08:00): het blijft staan tot de ochtend.
  -- Uitzondering: de afsluiting van de kraam (tot middernacht).
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
           when 'mcr_dag_open' then 'Close the day'
           when 'mcr_dag_open_b' then case when g.n = 1 then 'Manchester: kraam nog niet afgesloten' else 'Manchester: ' || g.n || ' kramen nog niet afgesloten' end
           when 'mcr_dag_dicht' then case when g.n = 1 then 'Manchester: kraam afgesloten' else 'Manchester: ' || g.n || ' kramen afgesloten' end
           else 'TC Group' end,
         case g.soort
           when 'mcr_eraf' then 'You''re off the rota for: ' || replace(g.regels, E'\n', '; ')
           when 'mcr_ruil_ok' then g.regels || E'\nYou stay on the rota until someone takes over.'
           when 'mcr_ruil_nee' then g.regels || E'\nYou''re still on the rota for this shift.'
           when 'mcr_ruil_open' then g.regels || E'\nTap to ask for it.'
           when 'mcr_ruil_gevraagd' then g.regels || E'\nKeur goed of af bij Manchester → Shifts.'
           when 'mcr_agenda_manager' then g.regels || E'\nBekijk het bij Manchester → Agenda.'
           when 'mcr_dag_open_b' then g.regels
           else g.regels end,
         case when g.soort = 'mcr_ruil_open' then 'mcr-open'
              when g.soort = 'mcr_ruil_gevraagd' then 'mcr-beheer'
              when g.soort = 'mcr_agenda_manager' then 'mcr-agenda'
              when g.soort = 'mcr_dag_open' then 'mcr-close'
              when g.soort in ('mcr_dag_open_b','mcr_dag_dicht') then 'mcr-afsluiting'
              else 'mcr-shifts' end
    from g join public.gebruikers u on u.id = g.gebruiker_id
   where u.push_token is not null;
end $function$;
