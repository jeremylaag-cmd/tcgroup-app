-- Manchester: nieuwe accounts (goedgekeurd vanaf 20 okt 2026, 22.40) vragen
-- niet zelf om diensten, ook niet om ruil-shifts. Ze geven alleen hun
-- beschikbaarheid op. Per persoon aan/uit te zetten bij Mensen.

alter table public.gebruikers add column if not exists alleen_beschikbaarheid boolean not null default false;

-- Wie vanavond al is goedgekeurd hoort er ook bij.
update public.gebruikers set alleen_beschikbaarheid = true
 where vestiging = 'MCR' and goedgekeurd and goedgekeurd_op >= '2026-10-20 20:40:00+00';

-- Bij goedkeuren van een Manchester-account gaat het vinkje vanzelf aan;
-- alleen een beheerder mag het veranderen.
create or replace function public.gebruiker_goedkeuren_bewaken()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $function$
begin
  if new.goedgekeurd is distinct from old.goedgekeurd then
    if auth.uid() is not null and not public.is_beheerder() then
      raise exception 'Alleen een beheerder kan een account goedkeuren.' using errcode = 'P0002';
    end if;
    if new.goedgekeurd then
      if new.rol is null or btrim(new.rol) = '' then
        raise exception 'Kies eerst een rol voor dit account.' using errcode = 'P0002';
      end if;
      if new.uurloon is null then
        raise exception 'Vul eerst een uurloon in voor dit account.' using errcode = 'P0002';
      end if;
      new.goedgekeurd_door := auth.uid();
      new.goedgekeurd_op := now();
      if new.vestiging = 'MCR' then
        new.alleen_beschikbaarheid := true;
      end if;
    else
      new.goedgekeurd_door := null;
      new.goedgekeurd_op := null;
    end if;
  end if;
  if new.alleen_beschikbaarheid is distinct from old.alleen_beschikbaarheid
     and new.goedgekeurd is not distinct from old.goedgekeurd
     and auth.uid() is not null and not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan dit veranderen.' using errcode = 'P0002';
  end if;
  return new;
end $function$;

-- Voor de personeelsapp: geldt dit voor mij?
create or replace function public.mcr_alleen_beschikbaarheid()
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select coalesce((select g.alleen_beschikbaarheid from public.gebruikers g where g.id = public.huidige_gebruiker()), false)
$$;
alter function public.mcr_alleen_beschikbaarheid() owner to postgres;
revoke all on function public.mcr_alleen_beschikbaarheid() from public, anon;
grant execute on function public.mcr_alleen_beschikbaarheid() to authenticated, service_role, app_rpc;

-- Mag de ingelogde medewerker om deze dienst vragen?
create or replace function public.mcr_aanvragen_mag(p_shift uuid)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select case
           when public.mcr_alleen_beschikbaarheid() then false
           else public.mcr_aanmelden_tot() is null
             or kl.datum <= public.mcr_aanmelden_tot()
             or exists (select 1 from public.mcr_shift_ruil x
                         where x.shift_id = s.id and x.status = 'open'
                           and x.gebruiker_id <> public.huidige_gebruiker())
         end
    from public.klus_shifts s
    join public.klussen kl on kl.id = s.klus_id
   where s.id = p_shift
$$;
alter function public.mcr_aanvragen_mag(uuid) owner to postgres;

create or replace function public.mcr_aanmelden(p_shift uuid, p_notitie text default null::text)
returns void
language plpgsql security definer
set search_path to 'public'
as $function$
declare v_klus uuid; v_uid uuid := public.huidige_gebruiker(); a record; v_bots text; v_tot date;
begin
  if not public.mag_werken() then raise exception 'Your account has not been approved yet. You can fill in your own details in the meantime.' using errcode='P0002'; end if;
  if v_uid is null then raise exception 'niet ingelogd'; end if;
  select klus_id into v_klus from public.klus_shifts where id = p_shift;
  if v_klus is null then raise exception 'That shift does not exist.' using errcode='P0002'; end if;
  if public.mcr_alleen_beschikbaarheid() then
    raise exception 'You do not need to ask for shifts. Fill in your availability and we will put you on the rota.' using errcode='P0002';
  end if;
  if not coalesce(public.mcr_aanvragen_mag(p_shift), false) then
    v_tot := public.mcr_aanmelden_tot();
    raise exception 'From % you can no longer ask for shifts. Fill in your availability instead and we will put you on the rota.',
      trim(to_char(v_tot + 1, 'FMDay FMDD FMMonth')) using errcode='P0002';
  end if;
  if exists (select 1 from public.klus_gebruikers g where g.shift_id = p_shift and g.gebruiker_id = v_uid) then
    raise exception 'You are already on this shift.' using errcode='P0002';
  end if;
  v_bots := public.mcr_botsing(v_uid, p_shift, true);
  if v_bots is not null then
    raise exception 'You are already on the rota at that time (%).', v_bots using errcode='P0002';
  end if;
  select * into a from public.klus_aanmeldingen x where x.klus_id = v_klus and x.gebruiker_id = v_uid;
  if found then
    if a.status = 'afgewezen' and a.shift_id = p_shift then
      raise exception 'Bram has already answered this one: not this time.' using errcode='P0002';
    elsif a.status = 'afgewezen' then
      update public.klus_aanmeldingen set shift_id = p_shift, status = 'aangemeld',
             notitie = nullif(p_notitie,''), aangemaakt_op = now() where id = a.id;
      return;
    else
      raise exception 'You have already asked for a shift at this stall on this day.' using errcode='P0002';
    end if;
  end if;
  insert into public.klus_aanmeldingen (klus_id, gebruiker_id, shift_id, notitie, status)
  values (v_klus, v_uid, p_shift, nullif(p_notitie,''), 'aangemeld');
end $function$;

create or replace function public.mcr_open_shifts2(p_dagen integer default 45)
returns table(klus_id uuid, shift_id uuid, datum date, kraam text, kleur text, start_tijd time without time zone, eind_tijd time without time zone, shift_naam text, nodig integer, bezet integer, aangemeld boolean, afgewezen boolean, ruil boolean)
language sql stable security definer
set search_path to 'public'
as $function$
  select * from (
    select kl.id, s.id, kl.datum, coalesce(kr.naam, kl.naam), coalesce(kr.kleur,'#6B6A66'),
           s.start_tijd, s.eind_tijd, s.naam, s.personeel_nodig,
           (select count(*)::int from public.klus_gebruikers g where g.shift_id = s.id),
           exists (select 1 from public.klus_aanmeldingen a where a.shift_id = s.id and a.gebruiker_id = public.huidige_gebruiker() and a.status <> 'afgewezen'),
           exists (select 1 from public.klus_aanmeldingen a where a.shift_id = s.id and a.gebruiker_id = public.huidige_gebruiker() and a.status = 'afgewezen'),
           (select count(*) from public.klus_gebruikers g where g.shift_id = s.id) >= s.personeel_nodig
    from public.klus_shifts s
    join public.klussen kl on kl.id = s.klus_id
    left join public.kramen kr on kr.id = kl.kraam_id
   where kl.kraam_id is not null
     and kl.datum >= current_date
     and kl.datum <= (select public.mcr_peildatum()) + p_dagen
     and ((select count(*) from public.klus_gebruikers g where g.shift_id = s.id) < s.personeel_nodig
          or exists (select 1 from public.mcr_shift_ruil x where x.shift_id = s.id and x.status = 'open'
                       and x.gebruiker_id <> public.huidige_gebruiker()))
     and not exists (select 1 from public.klus_gebruikers g where g.shift_id = s.id and g.gebruiker_id = public.huidige_gebruiker())
     and public.mcr_botsing(public.huidige_gebruiker(), s.id) is null
     and coalesce(public.mcr_aanvragen_mag(s.id), false)
   order by kl.datum, s.start_tijd
  ) _rijen where public.mag_werken();
$function$;

-- Beheer: lijst en aan/uit per persoon.
create or replace function public.mcr_alleen_lijst()
returns setof uuid
language sql stable security definer
set search_path to 'public'
as $$
  select g.id from public.gebruikers g
   where g.alleen_beschikbaarheid and public.mag_kraambeheer()
     and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
$$;
alter function public.mcr_alleen_lijst() owner to postgres;
revoke all on function public.mcr_alleen_lijst() from public, anon;
grant execute on function public.mcr_alleen_lijst() to authenticated, service_role;

create or replace function public.mcr_alleen_zetten(p_id uuid, p_aan boolean)
returns void
language plpgsql security definer
set search_path to 'public'
as $function$
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit veranderen.' using errcode='P0002';
  end if;
  update public.gebruikers g set alleen_beschikbaarheid = coalesce(p_aan, false)
   where g.id = p_id and public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging);
  if not found then raise exception 'Die persoon bestaat niet.' using errcode='P0002'; end if;
end $function$;
alter function public.mcr_alleen_zetten(uuid, boolean) owner to postgres;
revoke all on function public.mcr_alleen_zetten(uuid, boolean) from public, anon;
grant execute on function public.mcr_alleen_zetten(uuid, boolean) to authenticated, service_role;
