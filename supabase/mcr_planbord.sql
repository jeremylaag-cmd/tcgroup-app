-- Manchester planbord: één RPC die de hele week voor het planbord ophaalt,
-- in één keer indelen vanuit het voorstel, en een einddatum voor het zelf
-- aanvragen van diensten (daarna alleen nog beschikbaarheid opgeven en
-- ruil-shifts overnemen).

-- ── Instelling: t/m welke datum personeel zelf om een dienst mag vragen ──
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving)
values ('MCR', 'aanmelden_tot', '2026-11-15',
        'Tot en met deze datum vraagt personeel zelf om diensten. Daarna alleen beschikbaarheid opgeven en ruil-shifts overnemen. Leeg = altijd.')
on conflict (vestiging, sleutel) do nothing;

create or replace function public.mcr_aanmelden_tot()
returns date
language sql stable security definer
set search_path to 'public'
as $$
  select case when trim(i.waarde) ~ '^\d{4}-\d{2}-\d{2}$' then trim(i.waarde)::date end
    from public.vestiging_instellingen i
   where i.vestiging = coalesce(public.actieve_vestiging(), 'MCR')
     and i.sleutel = 'aanmelden_tot'
$$;
alter function public.mcr_aanmelden_tot() owner to postgres;
revoke all on function public.mcr_aanmelden_tot() from public, anon;
grant execute on function public.mcr_aanmelden_tot() to authenticated, service_role, app_rpc;

-- Mag de ingelogde medewerker om deze dienst vragen? Vóór de einddatum altijd,
-- daarna alleen als iemand anders de dienst open heeft gezet om te ruilen.
create or replace function public.mcr_aanvragen_mag(p_shift uuid)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select public.mcr_aanmelden_tot() is null
      or kl.datum <= public.mcr_aanmelden_tot()
      or exists (select 1 from public.mcr_shift_ruil x
                  where x.shift_id = s.id and x.status = 'open'
                    and x.gebruiker_id <> public.huidige_gebruiker())
    from public.klus_shifts s
    join public.klussen kl on kl.id = s.klus_id
   where s.id = p_shift
$$;
alter function public.mcr_aanvragen_mag(uuid) owner to postgres;
revoke all on function public.mcr_aanvragen_mag(uuid) from public, anon;
grant execute on function public.mcr_aanvragen_mag(uuid) to authenticated, service_role, app_rpc;

-- ── Aanmelden: na de einddatum alleen nog ruil-shifts ──
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
alter function public.mcr_aanmelden(uuid, text) owner to app_rpc;

-- ── Open shifts voor personeel: na de einddatum alleen ruil-shifts ──
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
     and (public.mcr_aanmelden_tot() is null
          or kl.datum <= public.mcr_aanmelden_tot()
          or exists (select 1 from public.mcr_shift_ruil x where x.shift_id = s.id and x.status = 'open'
                       and x.gebruiker_id <> public.huidige_gebruiker()))
   order by kl.datum, s.start_tijd
  ) _rijen where public.mag_werken();
$function$;
alter function public.mcr_open_shifts2(integer) owner to postgres;

-- ── Planbord: alles voor één week in één keer ──
create or replace function public.mcr_planbord(p_van date)
returns jsonb
language plpgsql stable security definer
set search_path to 'public'
as $function$
declare v_tot date := p_van + 6; v jsonb;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan plannen.' using errcode='P0002';
  end if;
  with k as (
    select k.* from public.kramen k
     where k.actief and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
  ), sh as (
    select s.id, s.naam, s.start_tijd, s.eind_tijd, s.personeel_nodig, kl.id klus_id, kl.datum, kl.kraam_id,
           coalesce(s.eind_tijd, public.kraam_eindtijd(kl.kraam_id, kl.datum), '23:59'::time) eind_echt
      from public.klus_shifts s
      join public.klussen kl on kl.id = s.klus_id
     where kl.kraam_id in (select id from k)
       and kl.datum between p_van and v_tot
  ), inn as (
    select kg.shift_id, kg.gebruiker_id from public.klus_gebruikers kg where kg.shift_id in (select id from sh)
  ), aanv as (
    select a.id, a.shift_id, a.gebruiker_id, a.notitie, a.aangemaakt_op
      from public.klus_aanmeldingen a
     where a.shift_id in (select id from sh) and a.status = 'aangemeld'
  ), ruil as (
    select x.shift_id, x.gebruiker_id, x.status from public.mcr_shift_ruil x
     where x.shift_id in (select id from sh) and x.status in ('open','gevraagd')
  ), m as (
    select g.id, g.naam, g.beoordeling, g.werkt_sinds, g.max_dagen_per_week, g.vroegste_start, g.eigen_opmerking,
           (coalesce(g.goedgekeurd,false) and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
             and g.gearchiveerd_op is null) as kan
      from public.gebruikers g
     where public.vest_ok(g.vestiging) and public.in_actieve_vestiging(g.vestiging)
       and ((coalesce(g.goedgekeurd,false) and g.rol <> 'beheerder' and not coalesce(g.kraammanager,false)
              and g.gearchiveerd_op is null)
            or g.id in (select gebruiker_id from inn) or g.id in (select gebruiker_id from aanv))
  )
  select jsonb_build_object(
    'van', p_van, 'tot', v_tot,
    'aanmelden_tot', public.mcr_aanmelden_tot(),
    'kramen', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'naam', k.naam,
                 'kleur', coalesce(k.kleur,'#6B6A66'), 'code', k.code) order by k.volgorde, k.naam) from k), '[]'::jsonb),
    'dagen', coalesce((select jsonb_agg(jsonb_build_object(
                 'kraam', k.id, 'datum', d::date,
                 'dicht', coalesce(u.dicht,false) or d::date < k.seizoen_start or d::date > k.seizoen_eind,
                 'open', coalesce(u.open_van, k.open_van), 'sluit', coalesce(u.open_tot, k.open_tot)))
               from k cross join generate_series(p_van, v_tot, interval '1 day') d
               left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d::date), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', sh.id, 'klus', sh.klus_id, 'kraam', sh.kraam_id, 'datum', sh.datum, 'naam', sh.naam,
                 'start', sh.start_tijd, 'eind', sh.eind_tijd, 'eind_echt', sh.eind_echt, 'nodig', sh.personeel_nodig,
                 'inn', coalesce((select jsonb_agg(inn.gebruiker_id) from inn where inn.shift_id = sh.id), '[]'::jsonb),
                 'aanv', coalesce((select jsonb_agg(jsonb_build_object('id', aanv.id, 'g', aanv.gebruiker_id,
                            'notitie', aanv.notitie, 'op', aanv.aangemaakt_op) order by aanv.aangemaakt_op)
                          from aanv where aanv.shift_id = sh.id), '[]'::jsonb),
                 'ruil', coalesce((select jsonb_agg(jsonb_build_object('g', ruil.gebruiker_id, 'status', ruil.status))
                          from ruil where ruil.shift_id = sh.id), '[]'::jsonb))
               order by sh.datum, sh.start_tijd) from sh), '[]'::jsonb),
    'mensen', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', m.id, 'naam', m.naam, 'oordeel', m.beoordeling, 'sinds', m.werkt_sinds,
                 'max_dagen', m.max_dagen_per_week, 'vroegst', m.vroegste_start,
                 'opmerking', m.eigen_opmerking, 'kan', m.kan) order by m.naam) from m), '[]'::jsonb),
    'besch', coalesce((select jsonb_agg(jsonb_build_object(
                 'g', b.gebruiker_id, 'van', b.datum_start, 'tot', coalesce(b.datum_eind, b.datum_start),
                 'soort', b.soort, 'ts', b.tijd_start, 'te', b.tijd_eind))
               from public.beschikbaarheid b
              where b.gebruiker_id in (select id from m)
                and b.datum_start <= v_tot and coalesce(b.datum_eind, b.datum_start) >= p_van
                and coalesce(b.status,'goedgekeurd') <> 'afgewezen'), '[]'::jsonb)
  ) into v;
  return v;
end $function$;
alter function public.mcr_planbord(date) owner to postgres;
revoke all on function public.mcr_planbord(date) from public, anon;
grant execute on function public.mcr_planbord(date) to authenticated, service_role;

-- ── In één keer indelen (voorstel toepassen) ──
-- Elk paar apart: lukt er één niet (vol, botst, persoon niet in te delen),
-- dan gaan de andere gewoon door en komt de reden terug in 'fouten'.
create or replace function public.mcr_indelen_bulk(p_paren jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $function$
declare r record; v_ok int := 0; v_fout jsonb := '[]'::jsonb; v_bots text; v_nodig int; v_bezet int;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan indelen.' using errcode='P0002';
  end if;
  if p_paren is null or jsonb_typeof(p_paren) <> 'array' then
    raise exception 'Geen geldige lijst.' using errcode='P0002';
  end if;
  if jsonb_array_length(p_paren) > 500 then
    raise exception 'Te veel in één keer (max 500).' using errcode='P0002';
  end if;
  for r in
    select (e->>'shift')::uuid as shift, (e->>'gebruiker')::uuid as gebruiker
      from jsonb_array_elements(p_paren) e
  loop
    begin
      if exists (select 1 from public.klus_gebruikers kg where kg.shift_id = r.shift and kg.gebruiker_id = r.gebruiker) then
        continue;
      end if;
      select s.personeel_nodig into v_nodig from public.klus_shifts s where s.id = r.shift;
      select count(*)::int into v_bezet from public.klus_gebruikers kg where kg.shift_id = r.shift;
      if v_bezet >= coalesce(v_nodig, 0) then
        raise exception 'Die dienst is intussen al vol.' using errcode='P0002';
      end if;
      v_bots := public.mcr_botsing(r.gebruiker, r.shift);
      if v_bots is not null then
        raise exception 'Staat dan al ingedeeld (%).', v_bots using errcode='P0002';
      end if;
      perform public.mcr_indelen(r.shift, r.gebruiker);
      v_ok := v_ok + 1;
    exception when others then
      v_fout := v_fout || jsonb_build_object('shift', r.shift, 'gebruiker', r.gebruiker, 'fout', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('ingedeeld', v_ok, 'fouten', v_fout);
end $function$;
alter function public.mcr_indelen_bulk(jsonb) owner to app_rpc;
revoke all on function public.mcr_indelen_bulk(jsonb) from public, anon;
grant execute on function public.mcr_indelen_bulk(jsonb) to authenticated, service_role;
