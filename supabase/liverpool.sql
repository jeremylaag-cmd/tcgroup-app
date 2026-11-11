-- Liverpool als derde vestiging. Vier delen, in deze volgorde gedraaid als migraties lpl_1 t/m lpl_4.

-- ════════ m1_basis ════════
-- Liverpool (LPL) als derde vestiging, naast Nederland en Manchester.
-- Deel 1: vestiging, kolommen, toegangsregels.
--
-- Begrippen:
--   markt-vestiging   elke vestiging behalve NL (nu MCR en LPL)
--   tweede_vestiging  iemand hoort tijdelijk ook bij een tweede vestiging, tot en met tweede_tot
--                     (Andras: thuis LPL, tot en met 21 nov ook MCR). Hij wisselt met vestiging_kiezen.
--   plant_vestiging   iemand die geen beheerder is mag in deze vestiging plannen, uren goedkeuren
--                     en aanmeldingen goedkeuren (Andras: LPL). Geen omzet, kosten of betalingen.

insert into public.vestigingen (code, naam, land, tijdzone, valuta, taal, volgorde, actief)
values ('LPL', 'Liverpool', 'GB', 'Europe/London', 'GBP', 'en', 3, true)
on conflict (code) do nothing;

alter table public.gebruikers
  add column if not exists tweede_vestiging text references public.vestigingen(code),
  add column if not exists tweede_tot date,
  add column if not exists plant_vestiging text references public.vestigingen(code);

comment on column public.gebruikers.tweede_vestiging is 'Tijdelijk ook lid van deze vestiging (tot en met tweede_tot). Wisselen via vestiging_kiezen.';
comment on column public.gebruikers.plant_vestiging is 'Mag in deze vestiging plannen, uren en aanmeldingen goedkeuren zonder beheerder te zijn. Geen omzet, kosten of betalingen.';

-- ── Hulpjes ──────────────────────────────────────────────────────────
create or replace function public.is_markt(v text)
returns boolean language sql immutable
as $$ select coalesce(v,'NL') <> 'NL' $$;

create or replace function public.tweede_vestiging_nu()
returns text language sql stable security definer set search_path to 'public'
as $$
  select g.tweede_vestiging from public.gebruikers g
   where g.id = auth.uid() and g.tweede_vestiging is not null
     and (g.tweede_tot is null or (now() at time zone 'Europe/London')::date <= g.tweede_tot)
$$;

create or replace function public.actieve_vestiging()
returns text language sql stable security definer set search_path to 'public'
as $$
  select case
           when g.alle_vestigingen then
             case when g.actieve_vestiging is null then g.vestiging
                  when g.actieve_vestiging = '*'   then null       -- alle
                  else g.actieve_vestiging end
           when g.actieve_vestiging is not null
                and g.actieve_vestiging = g.tweede_vestiging
                and (g.tweede_tot is null or (now() at time zone 'Europe/London')::date <= g.tweede_tot)
             then g.tweede_vestiging
           else g.vestiging
         end
    from public.gebruikers g where g.id = auth.uid()
$$;

create or replace function public.zichtbare_vestigingen()
returns text[] language sql stable security definer set search_path to 'public'
as $$
  select case
           when not g.alle_vestigingen          then array[public.actieve_vestiging()]
           when g.actieve_vestiging = '*'       then (select array_agg(v.code) from public.vestigingen v)
           when g.actieve_vestiging is not null then array[g.actieve_vestiging]
           else array[g.vestiging]
         end
    from public.gebruikers g where g.id = auth.uid()
$$;

create or replace function public.vest_ok(v text)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select public.mag_alle_vestigingen()
      or (v is not null and (v = public.mijn_vestiging() or v = public.tweede_vestiging_nu()))
$$;

create or replace function public.vestiging_kiezen(p_code text)
returns text language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.mag_alle_vestigingen() then
    if p_code is null or p_code not in (
         select x from (select public.mijn_vestiging() as x union select public.tweede_vestiging_nu()) s
          where x is not null) then
      raise exception 'je mag maar naar een vestiging kijken';
    end if;
  end if;
  if p_code is not null and p_code <> '*'
     and not exists (select 1 from public.vestigingen v where v.code = p_code) then
    raise exception 'onbekende vestiging %', p_code;
  end if;
  update public.gebruikers set actieve_vestiging = p_code where id = auth.uid();
  return coalesce(public.actieve_vestiging(), 'beide');
end $$;

-- Planner: plant_vestiging gezet en die vestiging staat nu open.
create or replace function public.is_planner()
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select exists (select 1 from public.gebruikers g
                  where g.id = public.huidige_gebruiker()
                    and g.plant_vestiging is not null
                    and g.plant_vestiging = public.actieve_vestiging()
                    and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null
                    and exists (select 1 from public.kramen k where k.vestiging = g.plant_vestiging))
$$;

-- Heeft dit account ergens planrechten (ongeacht welke vestiging nu openstaat)?
create or replace function public.is_planner_account()
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select exists (select 1 from public.gebruikers g
                  where g.id = public.huidige_gebruiker()
                    and g.plant_vestiging is not null and g.rol <> 'beheerder')
$$;

-- Vervangt mag_kraambeheer() in de functies voor plannen, uren, mensen, agenda.
create or replace function public.mag_planbeheer()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.mag_kraambeheer() or public.is_planner() $$;

-- Vervangt is_beheerder() in de markt-functies voor uren en diensten.
create or replace function public.mag_plannen()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.is_beheerder() or public.is_planner() $$;

-- Mag de huidige gebruiker iets aan deze persoon wijzigen (uurloon, goedkeuren)?
-- Beheerder altijd; planner alleen voor anderen in zijn eigen vestiging.
create or replace function public.planner_mag_persoon(p_id uuid, p_vestiging text)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select public.is_beheerder()
      or (public.is_planner() and p_vestiging = public.actieve_vestiging()
          and p_id is distinct from public.huidige_gebruiker())
$$;

-- Voor lijsten: hoort deze markt-vestiging bij wat de gebruiker nu bekijkt?
-- Zonder ingelogde gebruiker (klok, achtergrondtaken) altijd ja.
create or replace function public.markt_zichtbaar(v text)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select public.huidige_gebruiker() is null
      or (public.vest_ok(v) and public.in_actieve_vestiging(v))
$$;

-- ── Slot: een planner raakt alleen rijen van de vestiging die hij open heeft ──
create or replace function public.planner_grens()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare j jsonb; jo jsonb; v text; vo text; v_act text;
begin
  if public.huidige_gebruiker() is null or not public.is_planner_account() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  v_act := public.actieve_vestiging();
  if tg_op = 'DELETE' then j := to_jsonb(old); else j := to_jsonb(new); end if;
  if tg_op = 'UPDATE' then jo := to_jsonb(old); end if;

  if tg_table_name = 'gebruikers' then
    if (j->>'id')::uuid = public.huidige_gebruiker() then
      return case when tg_op = 'DELETE' then old else new end;
    end if;
    v := j->>'vestiging'; vo := jo->>'vestiging';
  elsif tg_table_name = 'klussen' then
    v := j->>'vestiging'; vo := jo->>'vestiging';
  elsif tg_table_name = 'kraam_uitzonderingen' then
    select k.vestiging into v from public.kramen k where k.id = (j->>'kraam_id')::uuid;
    if jo is not null then select k.vestiging into vo from public.kramen k where k.id = (jo->>'kraam_id')::uuid; end if;
  else
    if j ? 'klus_id' and j->>'klus_id' is not null then
      select kl.vestiging into v from public.klussen kl where kl.id = (j->>'klus_id')::uuid;
    end if;
    if v is null and j ? 'gebruiker_id' and j->>'gebruiker_id' is not null then
      select g.vestiging into v from public.gebruikers g where g.id = (j->>'gebruiker_id')::uuid;
    end if;
    if jo is not null and jo ? 'klus_id' and jo->>'klus_id' is not null then
      select kl.vestiging into vo from public.klussen kl where kl.id = (jo->>'klus_id')::uuid;
    end if;
  end if;

  if (v is not null and v is distinct from v_act) or (vo is not null and vo is distinct from v_act) then
    raise exception 'Dit hoort bij een andere vestiging (%).', coalesce(vo, v) using errcode = 'P0002';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['klussen','klus_shifts','klus_gebruikers','urenregistraties','klus_aanmeldingen',
                           'mcr_shift_ruil','kraam_uitzonderingen','mcr_voorvallen','gebruikers'] loop
    execute format('drop trigger if exists a0_planner_grens on public.%I', t);
    execute format('create trigger a0_planner_grens before insert or update or delete on public.%I
                    for each row execute function public.planner_grens()', t);
  end loop;
end $$;

-- ── Inplannen over de vestigingsgrens: alleen met een geldige tweede vestiging ──
create or replace function public.klus_gebruiker_vestiging_bewaken()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare v_g text; v_t text; v_tt date; v_k text; v_d date;
begin
  select coalesce(g.vestiging,'NL'), g.tweede_vestiging, g.tweede_tot into v_g, v_t, v_tt
    from public.gebruikers g where g.id = new.gebruiker_id;
  select coalesce(k.vestiging,'NL'), k.datum into v_k, v_d from public.klussen k where k.id = new.klus_id;
  if v_g is not null and v_k is not null and v_g <> v_k
     and not (v_t is not null and v_t = v_k and (v_tt is null or v_d <= v_tt)) then
    raise exception 'Deze persoon hoort bij een andere vestiging (%) en kan niet op deze klus (%).', v_g, v_k using errcode='P0002';
  end if;
  return new;
end $$;

-- ── Rechten op personen: planner mag uurloon en "werkt sinds" van anderen in zijn vestiging ──
create or replace function public.vestiging_bewaken()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    if new.alle_vestigingen and not public.is_administrator() then
      raise exception 'alle_vestigingen mag alleen een administrator zetten';
    end if;
    if (new.tweede_vestiging is not null or new.plant_vestiging is not null)
       and auth.uid() is not null and not public.is_administrator() then
      raise exception 'tweede vestiging en planrechten mag alleen een administrator zetten';
    end if;
  else
    if new.alle_vestigingen is distinct from old.alle_vestigingen
       and not public.is_administrator() then
      raise exception 'alle_vestigingen mag alleen een administrator zetten';
    end if;
    if (new.tweede_vestiging is distinct from old.tweede_vestiging
        or new.tweede_tot is distinct from old.tweede_tot
        or new.plant_vestiging is distinct from old.plant_vestiging)
       and auth.uid() is not null and not public.is_administrator() then
      raise exception 'tweede vestiging en planrechten mag alleen een administrator zetten';
    end if;
    if new.vestiging is distinct from old.vestiging
       and coalesce(old.goedgekeurd, false)
       and not public.is_administrator() then
      raise exception 'een goedgekeurd account kan alleen een administrator verplaatsen';
    end if;
  end if;

  -- De markten (Manchester, Liverpool) draaien op zelfstandigen. Staat er nog
  -- niets, dan vult de database dat in; een beheerder kan het daarna wijzigen.
  if public.is_markt(new.vestiging) and coalesce(new.contractvorm,'') = '' then
    new.contractvorm := 'zzp';
  end if;

  return new;
end $$;

-- ════════ m2b ════════
-- Liverpool deel 2: bestaande functies geschikt maken voor meerdere markten + planner.
-- Elke vervanging wordt in de huidige definitie gedaan; klopt het aantal treffers
-- niet (de functie is intussen veranderd), dan stopt de hele migratie.
do $do$
declare r record; v_oid oid; v_def text; v_n int;
begin
  create temp table _vervang(fn text, van text, naar text, aantal int, volg serial) on commit drop;
  insert into _vervang(fn, van, naar, aantal) values
  ($q$mcr_aandacht$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_aandacht$q$, $q$kl.kraam_id is not null$q$, $q$kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 2),
  ($q$mcr_aanmelding_afwijzen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_aanmeldingen_al_ingedeeld$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_aanmeldingen_open$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_agenda_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_agenda_weg$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_agenda_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_alleen_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_alleen_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_bezetting$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_bezetting_balk$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_bezetting_balk$q$, $q$kl.kraam_id is not null$q$, $q$kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 1),
  ($q$mcr_dag$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_dag_te_beoordelen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_diensten_gelijktrekken$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_ervaring$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_huisregels_overzicht$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_huisregels_overzicht$q$, $q$x.vestiging = 'MCR'$q$, $q$x.vestiging = coalesce(public.actieve_vestiging(),'MCR')$q$, 1),
  ($q$mcr_huisregels_overzicht$q$, $q$o.vestiging = 'MCR'$q$, $q$o.vestiging = coalesce(public.actieve_vestiging(),'MCR')$q$, 1),
  ($q$mcr_huisregels_overzicht$q$, $q$g.vestiging = 'MCR'$q$, $q$g.vestiging = coalesce(public.actieve_vestiging(),'MCR')$q$, 1),
  ($q$mcr_indelen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_indelen_bulk$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_kandidaten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_kleding_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_kleding_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_manager_dag_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_manager_keuze$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_manager_week_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_manager_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_managers_week$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_mensen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_persoon_gegevens_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_persoon_info$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_persoon_opslaan$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_persoon_planning$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_planbord$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_ruil_beslissen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_ruil_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_ruil_lijst$q$, $q$where x.status in ('gevraagd','open')$q$, $q$where x.status in ('gevraagd','open') and public.markt_zichtbaar(kl.vestiging)$q$, 1),
  ($q$mcr_shift_mensen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_shifts_toevoegen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_tags$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uitzondering$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uitzonderingen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uren_open$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uren_open$q$, $q$kl.kraam_id is not null$q$, $q$kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 1),
  ($q$mcr_uren_vraag$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uur_bezetting$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_voorval_weg$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_voorval_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_voorvallen_van$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_wacht_op_jou$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_wacht_op_jou$q$, $q$where kl.kraam_id is not null$q$, $q$where kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 5),
  ($q$mcr_wacht_op_jou$q$, $q$    coalesce((select round(sum(u.totaal_minuten::numeric/60*coalesce(g.uurloon,0)),0)$q$, $q$    case when public.is_beheerder() then coalesce((select round(sum(u.totaal_minuten::numeric/60*coalesce(g.uurloon,0)),0)$q$, 1),
  ($q$mcr_wacht_op_jou$q$, $q$      join public.gebruikers g on g.id=u.gebruiker_id
      where kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging) and u.status='goedgekeurd'),0),$q$, $q$      join public.gebruikers g on g.id=u.gebruiker_id
      where kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging) and u.status='goedgekeurd'),0) end,$q$, 1),
  ($q$mcr_week$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_werkt_sinds_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_wijzigingen_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_wm_lijst$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_wm_zetten$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_afsluitingen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_afsluiting_akkoord$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_afsluiting_heropenen$q$, $q$public.mag_kraambeheer()$q$, $q$public.mag_planbeheer()$q$, 1),
  ($q$mcr_uur_akkoord$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_uur_bijstellen$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_uur_tijden$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_uur_tijden_londen$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_uur_vastzetten$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_shift_opslaan$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_shift_weg$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_uitdelen$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_overzicht$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_vandaag$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_week_kopieren$q$, $q$public.is_beheerder()$q$, $q$public.mag_plannen()$q$, 1),
  ($q$mcr_week_kopieren$q$, $q$kl.kraam_id is not null$q$, $q$kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 1),
  ($q$mcr_uur_terug$q$, $q$kl.kraam_id is not null$q$, $q$kl.kraam_id is not null and public.markt_zichtbaar(kl.vestiging)$q$, 1),
  ($q$uren_auto_uitklokken$q$, $q$case when r.kv = 'MCR'$q$, $q$case when public.is_markt(r.kv)$q$, 1),
  ($q$meldingen_voor$q$, $q$kl.vestiging = 'MCR'$q$, $q$public.is_markt(kl.vestiging)$q$, 1),
  ($q$herinneringen_te_versturen_v2$q$, $q$case when coalesce(k.vestiging,'NL') = 'MCR' then 'Europe/London'$q$, $q$case when public.is_markt(k.vestiging) then 'Europe/London'$q$, 2),
  ($q$herinneringen_te_versturen_v2$q$, $q$(m.vest = 'MCR' or$q$, $q$(public.is_markt(m.vest) or$q$, 1),
  ($q$mcr_ruil_open_melden$q$, $q$where g.vestiging = 'MCR' and$q$, $q$where g.vestiging = (select kl2.vestiging from public.klussen kl2 where kl2.id = v_klus) and$q$, 1),
  ($q$mcr_ruil_vragen$q$, $q$where b.rol = 'beheerder' and b.gearchiveerd_op is null and (coalesce(b.alle_vestigingen,false) or b.vestiging = 'MCR');$q$, $q$where b.gearchiveerd_op is null
     and ((b.rol = 'beheerder' and (coalesce(b.alle_vestigingen,false) or b.vestiging = (select kl3.vestiging from public.klussen kl3 where kl3.id = r.klus_id)))
          or b.plant_vestiging = (select kl3.vestiging from public.klussen kl3 where kl3.id = r.klus_id));$q$, 1),
  ($q$meld_ziek$q$, $q$case when v_vest = 'MCR' then$q$, $q$case when public.is_markt(v_vest) then$q$, 1),
  ($q$mcr_omzet_kramen$q$, $q$k.vestiging = 'MCR'$q$, $q$public.is_markt(k.vestiging) and (public.actieve_vestiging() is null or not public.is_markt(public.actieve_vestiging()) or k.vestiging = public.actieve_vestiging())$q$, 1),
  ($q$mcr_omzet_dagen$q$, $q$k.vestiging = 'MCR'$q$, $q$public.is_markt(k.vestiging) and (public.actieve_vestiging() is null or not public.is_markt(public.actieve_vestiging()) or k.vestiging = public.actieve_vestiging())$q$, 1),
  ($q$gebruiker_goedkeuren_bewaken$q$, $q$if auth.uid() is not null and not public.is_beheerder() then
      raise exception 'Alleen een beheerder kan een account goedkeuren.'$q$, $q$if auth.uid() is not null and not public.planner_mag_persoon(new.id, new.vestiging) then
      raise exception 'Alleen een beheerder kan een account goedkeuren.'$q$, 1),
  ($q$gebruiker_goedkeuren_bewaken$q$, $q$if new.vestiging = 'MCR' then$q$, $q$if public.is_markt(new.vestiging) then$q$, 1),
  ($q$gebruiker_goedkeuren_bewaken$q$, $q$and auth.uid() is not null and not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan dit veranderen.'$q$, $q$and auth.uid() is not null and not public.planner_mag_persoon(new.id, new.vestiging) then
    raise exception 'Alleen een beheerder kan dit veranderen.'$q$, 1),
  ($q$bewaak_rol_wijziging$q$, $q$if NEW.uurloon is distinct from OLD.uurloon and not public.is_beheerder() then$q$, $q$if NEW.uurloon is distinct from OLD.uurloon and not public.planner_mag_persoon(NEW.id, NEW.vestiging) then$q$, 1),
  ($q$bewaak_rol_wijziging$q$, $q$if NEW.werkt_sinds is distinct from OLD.werkt_sinds and not public.is_beheerder() then$q$, $q$if NEW.werkt_sinds is distinct from OLD.werkt_sinds and not public.planner_mag_persoon(NEW.id, NEW.vestiging) then$q$, 1),
  ($q$ziek_ontvangers$q$, $q$  select p.id from planners p
  union all
  select a.id from alle a where not exists (select 1 from planners)$q$, $q$  select p.id from planners p
  union all
  select a.id from alle a where not exists (select 1 from planners)
  union
  select g.id from public.gebruikers g
   where g.plant_vestiging is not null and g.plant_vestiging = p_vestiging
     and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null$q$, 1);
  for r in select fn from _vervang group by fn order by min(volg) loop
    select p.oid into strict v_oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname = r.fn;
    v_def := pg_get_functiondef(v_oid);
    declare x record; begin
      for x in select * from _vervang where fn = r.fn order by volg loop
        v_n := (length(v_def) - length(replace(v_def, x.van, ''))) / greatest(length(x.van),1);
        if v_n <> x.aantal then
          raise exception 'Functie % is veranderd: % keer gevonden, % verwacht (%)', r.fn, v_n, x.aantal, left(x.van, 60);
        end if;
        v_def := replace(v_def, x.van, x.naar);
      end loop;
    end;
    execute v_def;
  end loop;
end $do$;

-- Omzet van de markten (Manchester én Liverpool): alleen Bram.
-- ALTER, zodat de policies RESTRICTIVE blijven met dezelfde rollen.
alter policy "omzet mcr alleen bram" on public.pin_dag
  using ((not public.is_markt(vestiging)) or public.mag_omzet_zien())
  with check ((not public.is_markt(vestiging)) or public.mag_omzet_zien());
alter policy "omzet mcr alleen bram" on public.pin_uur
  using ((not public.is_markt(vestiging)) or public.mag_omzet_zien())
  with check ((not public.is_markt(vestiging)) or public.mag_omzet_zien());
alter policy "omzet mcr alleen bram" on public.pin_referenties
  using ((not public.is_markt(vestiging)) or public.mag_omzet_zien())
  with check ((not public.is_markt(vestiging)) or public.mag_omzet_zien());
alter policy "omzet mcr alleen bram" on public.dagrapporten
  using ((not public.is_markt(public.vest_kraam(kraam_id))) or public.mag_omzet_zien())
  with check ((not public.is_markt(public.vest_kraam(kraam_id))) or public.mag_omzet_zien());

-- ════════ m3_data ════════
-- Liverpool deel 3: kraam, openingstijden, instellingen, huisregels, diensten, Andras.

-- Kraam
insert into public.kramen (vestiging, code, naam, adres, kleur, seizoen_start, seizoen_eind, open_van, open_tot, volgorde, actief)
select 'LPL', 'LPL', 'Liverpool', 'St George''s Quarter, Liverpool', '#7C3AED', date '2026-11-21', date '2027-01-03',
       time '10:00', time '22:00', 1, true
 where not exists (select 1 from public.kramen where vestiging = 'LPL' and code = 'LPL');

-- Afwijkende dagen
insert into public.kraam_uitzonderingen (kraam_id, datum, dicht, open_van, open_tot, reden)
select k.id, x.datum, x.dicht, x.van, x.tot, x.reden
  from public.kramen k
  cross join (values
    (date '2026-12-24', false, time '10:00', time '18:00', 'Kerstavond'),
    (date '2026-12-25', true,  null::time,   null::time,   'Eerste kerstdag'),
    (date '2026-12-26', false, time '12:00', time '22:00', 'Boxing Day'),
    (date '2027-01-01', false, time '12:00', time '22:00', 'Nieuwjaarsdag')
  ) as x(datum, dicht, van, tot, reden)
 where k.vestiging = 'LPL' and k.code = 'LPL'
   and not exists (select 1 from public.kraam_uitzonderingen u where u.kraam_id = k.id and u.datum = x.datum);

-- Standaardpatroon (zoals Manchester): Opening 10:00 en Middag 15:00, elk 2 mensen
insert into public.kraam_patronen (kraam_id, weekdag, start_tijd, personeel_nodig, naam, volgorde, actief)
select k.id, wd, p.start, 2, p.naam, p.volg, true
  from public.kramen k
  cross join generate_series(0,6) wd
  cross join (values (time '10:00', 'Opening', 1), (time '15:00', 'Middag', 2)) as p(start, naam, volg)
 where k.vestiging = 'LPL' and k.code = 'LPL'
   and not exists (select 1 from public.kraam_patronen x where x.kraam_id = k.id);

-- Instellingen: alles van Manchester overnemen
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving, bijgewerkt_op)
select 'LPL', i.sleutel, i.waarde, i.omschrijving, now()
  from public.vestiging_instellingen i
 where i.vestiging = 'MCR'
on conflict do nothing;

-- Wat in Liverpool anders is
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving, bijgewerkt_op) values
  ('LPL', 'contant',      'nee', 'Wordt er contant betaald? nee = geen kasvelden in dagrapport en omzet', now()),
  ('MCR', 'contant',      'ja',  'Wordt er contant betaald? nee = geen kasvelden in dagrapport en omzet', now()),
  ('LPL', 'pin_bron',     'handmatig', 'myPOS = automatisch ophalen; handmatig = dagtotalen per terminal van de bon invullen', now()),
  ('MCR', 'pin_bron',     'mypos',     'myPOS = automatisch ophalen; handmatig = dagtotalen per terminal van de bon invullen', now()),
  ('LPL', 'afdracht_pct', '28',  'Percentage van de omzet dat naar de markt gaat', now())
on conflict do nothing;

-- Huisregels: de Engelse versie van Manchester, met Liverpool erin
insert into public.huisregels (vestiging, taal, versie, titel, tekst, actief)
select 'LPL', h.taal, h.versie, replace(h.titel, 'Manchester', 'Liverpool'), replace(h.tekst, 'Manchester', 'Liverpool'), true
  from public.huisregels h
 where h.vestiging = 'MCR' and h.actief
   and not exists (select 1 from public.huisregels x where x.vestiging = 'LPL');

-- Basisdiensten voor het hele seizoen: vanaf opening en vanaf 15:00, elk 2 mensen,
-- tot sluiting (+ opruimtijd). Andras of Bram past ze daarna aan.
do $$
declare k record; d date; v_open time; v_sluit time; v_dicht boolean; v_klus uuid; s time;
begin
  select * into k from public.kramen where vestiging = 'LPL' and code = 'LPL';
  if exists (select 1 from public.klussen where kraam_id = k.id) then return; end if;
  d := k.seizoen_start;
  while d <= k.seizoen_eind loop
    select coalesce(u.dicht,false), coalesce(u.open_van, k.open_van), coalesce(u.open_tot, k.open_tot)
      into v_dicht, v_open, v_sluit
      from (select 1) x left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d;
    if not v_dicht then
      insert into public.klussen (naam, datum, personen, food, adres, categorie, vestiging,
                                  kraam_id, start_tijd, einde_klus, eind_tijd, personeel_nodig, buiten)
      values (k.naam, d, 0, 'poffertjes', k.adres, 'klus', k.vestiging, k.id, v_open, v_sluit, v_sluit, 0, true)
      returning id into v_klus;
      foreach s in array array[v_open, time '15:00'] loop
        insert into public.klus_shifts (klus_id, naam, start_tijd, eind_tijd, personeel_nodig, volgorde)
        values (v_klus, to_char(s,'HH24:MI') || '–close', s, null, 2, (extract(hour from s)*60 + extract(minute from s))::int);
      end loop;
      update public.klussen set personeel_nodig = 4 where id = v_klus;
    end if;
    d := d + 1;
  end loop;
end $$;

-- Andras: thuis Liverpool en planner daar; tot en met 21 november ook Manchester
-- (daar als kraammanager, zoals nu). Als Bram (administrator), want een
-- goedgekeurd account verplaatsen mag alleen de administrator.
select set_config('request.jwt.claims', '{"sub":"adb8bd40-f0b6-4aa2-a16d-a67932202c02","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'adb8bd40-f0b6-4aa2-a16d-a67932202c02', true);
update public.gebruikers
   set vestiging = 'LPL', tweede_vestiging = 'MCR', tweede_tot = date '2026-11-21',
       plant_vestiging = 'LPL', actieve_vestiging = null
 where naam = 'Andras Jadi' and vestiging = 'MCR';
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);

-- ════════ m4_pin_handmatig ════════
-- Liverpool deel 4: pin-dagtotalen met de hand (terminals van de organisatie,
-- geen myPOS). Komt in pin_dag, zodat dagrapport, omzet en cijfers gewoon werken.
-- Alleen wie omzet mag zien (Bram), en alleen bij vestigingen met pin_bron = handmatig.

create or replace function public.mcr_pin_handmatig_lijst(p_kraam uuid, p_datum date)
returns table(tid text, omzet numeric, transacties integer)
language sql stable security definer set search_path to 'public'
as $$
  select pd.tid, pd.omzet, pd.transacties
    from public.pin_dag pd
    join public.kramen k on k.id = pd.kraam_id
   where pd.kraam_id = p_kraam and pd.datum = p_datum
     and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
     and public.mag_kraambeheer() and public.mag_omzet_zien()
   order by pd.tid
$$;

create or replace function public.mcr_pin_handmatig_zetten(p_kraam uuid, p_datum date, p_regels jsonb)
returns numeric
language plpgsql security definer set search_path to 'public'
as $$
declare v_vest text; r jsonb; v_tid text; v_omzet numeric; v_tr int; v_som numeric := 0; v_namen text[] := '{}';
begin
  if not (public.mag_kraambeheer() and public.mag_omzet_zien()) then
    raise exception 'Alleen Bram kan de omzet invullen.' using errcode='P0002';
  end if;
  select k.vestiging into v_vest from public.kramen k
   where k.id = p_kraam and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging);
  if v_vest is null then raise exception 'Onbekende kraam.' using errcode='P0002'; end if;
  if coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = v_vest and i.sleutel = 'pin_bron'),'mypos') <> 'handmatig' then
    raise exception 'Bij deze vestiging komt de pin vanzelf binnen via myPOS.' using errcode='P0002';
  end if;
  if p_datum is null then raise exception 'Kies een datum.' using errcode='P0002'; end if;
  if jsonb_typeof(coalesce(p_regels,'[]'::jsonb)) <> 'array' then raise exception 'Ongeldige invoer.'; end if;

  for r in select * from jsonb_array_elements(coalesce(p_regels,'[]'::jsonb)) loop
    v_tid := nullif(left(btrim(coalesce(r->>'tid','')),40),'');
    if v_tid is null then continue; end if;
    if v_tid = any(v_namen) then raise exception 'De terminal "%" staat er twee keer in.', v_tid using errcode='P0002'; end if;
    v_namen := v_namen || v_tid;
    v_omzet := nullif(r->>'omzet','')::numeric;
    v_tr := nullif(r->>'transacties','')::int;
    if v_omzet is not null and v_omzet < 0 then raise exception 'Een bedrag kan niet negatief zijn.' using errcode='P0002'; end if;
    if v_tr is not null and v_tr < 0 then raise exception 'Het aantal transacties kan niet negatief zijn.' using errcode='P0002'; end if;
  end loop;

  delete from public.pin_dag pd where pd.kraam_id = p_kraam and pd.datum = p_datum;

  for r in select * from jsonb_array_elements(coalesce(p_regels,'[]'::jsonb)) loop
    v_tid := nullif(left(btrim(coalesce(r->>'tid','')),40),'');
    v_omzet := round(coalesce(nullif(r->>'omzet','')::numeric,0),2);
    v_tr := coalesce(nullif(r->>'transacties','')::int,0);
    if v_tid is null or (v_omzet = 0 and v_tr = 0) then continue; end if;
    insert into public.pin_dag (vestiging, tid, datum, kraam_id, omzet, transacties, kosten, bijgewerkt_op)
    values (v_vest, v_tid, p_datum, p_kraam, v_omzet, v_tr, 0, now());
    v_som := v_som + v_omzet;
  end loop;
  return v_som;
end $$;

grant execute on function public.mcr_pin_handmatig_lijst(uuid, date) to authenticated;
grant execute on function public.mcr_pin_handmatig_zetten(uuid, date, jsonb) to authenticated;

-- Per kraam: hoort er contant bij, waar komt de pin vandaan, welk deel gaat naar de markt.
create or replace function public.markt_kraam_info()
returns table(kraam_id uuid, vestiging text, contant boolean, pin_bron text, afdracht_pct numeric)
language sql stable security definer set search_path to 'public'
as $$
  select k.id, k.vestiging,
         coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = k.vestiging and i.sleutel = 'contant'),'ja') <> 'nee',
         coalesce((select i.waarde from public.vestiging_instellingen i where i.vestiging = k.vestiging and i.sleutel = 'pin_bron'),'mypos'),
         coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                    where i.vestiging = k.vestiging and i.sleutel = 'afdracht_pct'), 0)
    from public.kramen k
   where public.is_markt(k.vestiging) and public.mijn_rol() is not null
$$;
grant execute on function public.markt_kraam_info() to authenticated;

-- Iemand van de ene markt naar de andere verplaatsen (alleen de administrator).
-- Staat hij nog op toekomstige diensten in de oude vestiging, dan eerst die weghalen.
create or replace function public.mcr_persoon_verplaatsen(p_id uuid, p_vestiging text)
returns text
language plpgsql security definer set search_path to 'public'
as $$
declare g record; v_n int; v_oud text;
begin
  if not public.is_administrator() then
    raise exception 'Alleen de administrator kan iemand naar een andere vestiging verplaatsen.' using errcode='P0002';
  end if;
  if not exists (select 1 from public.vestigingen v where v.code = p_vestiging and public.is_markt(v.code)) then
    raise exception 'Onbekende vestiging.' using errcode='P0002';
  end if;
  select * into g from public.gebruikers where id = p_id;
  if not found or not public.is_markt(g.vestiging) then raise exception 'Die persoon bestaat niet.' using errcode='P0002'; end if;
  if g.vestiging = p_vestiging then return p_vestiging; end if;
  select count(*) into v_n
    from public.klus_gebruikers kg join public.klussen kl on kl.id = kg.klus_id
   where kg.gebruiker_id = p_id and kl.vestiging = g.vestiging
     and kl.datum >= (now() at time zone 'Europe/London')::date;
  if v_n > 0 then
    select naam into v_oud from public.vestigingen where code = g.vestiging;
    raise exception '% staat nog op % dienst% in %. Haal die eerst weg.', g.naam, v_n, case when v_n = 1 then '' else 'en' end, v_oud
      using errcode='P0002';
  end if;
  update public.gebruikers
     set vestiging = p_vestiging, actieve_vestiging = null, manager_kraam_id = null
   where id = p_id;
  return p_vestiging;
end $$;
grant execute on function public.mcr_persoon_verplaatsen(uuid, text) to authenticated;

-- ════════ bij het live zetten toegevoegd ════════
-- is_kraammanager: ook kraammanager in de tweede vestiging (Andras t/m 21 nov in Manchester).
--   exists (select 1 from public.kramen k where k.vestiging = g.vestiging)
--   → exists (select 1 from public.kramen k where k.vestiging in (g.vestiging, public.tweede_vestiging_nu()))
-- Live gezet als migratie lpl_liverpool_vestiging (alles hierboven in één keer).
