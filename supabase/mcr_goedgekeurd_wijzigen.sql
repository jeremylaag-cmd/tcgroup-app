-- Goedgekeurde uren van een kraam wijzigen zonder ze eerst terug te draaien.
-- Alleen de administrator. De uren blijven goedgekeurd; het totaal wordt net als
-- bij goedkeuren op een kwartier afgerond. Staan de uren op een factuur die nog
-- niet als ontvangen is gestempeld, dan wordt die factuur meteen herberekend.
-- Niet mogelijk bij een ontvangen factuur of een vastgezette betaalronde.
create or replace function public.uur_goedgekeurd_wijzigen(
  p_uren uuid, p_in text, p_uit text, p_pauze integer,
  p_volgende_dag boolean default false, p_reden text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare u record; v_tz text; v_dag date; v_tin time; v_tuit time;
        v_in timestamptz; v_uit timestamptz; v_min int; v_pauze int; v_tot int;
        v_naam text; v_reden text; v_ontvangen timestamptz; v_was text;
begin
  if not public.is_administrator() then
    raise exception 'Alleen de administrator kan goedgekeurde uren wijzigen.' using errcode='P0002';
  end if;
  select ur.*, kl.datum as kdatum, kl.vestiging as kvest, kl.kraam_id as kid into u
    from public.urenregistraties ur
    join public.gebruikers g on g.id = ur.gebruiker_id
    join public.klussen kl on kl.id = ur.klus_id
   where ur.id = p_uren and public.in_actieve_vestiging(g.vestiging);
  if not found then raise exception 'Die registratie bestaat niet.' using errcode='P0002'; end if;
  if u.kid is null then raise exception 'Dit kan alleen bij uren van een kraam.' using errcode='P0002'; end if;
  if u.status <> 'goedgekeurd' then raise exception 'Deze uren zijn niet goedgekeurd.' using errcode='P0002'; end if;
  if nullif(btrim(coalesce(p_in,'')),'') is null or nullif(btrim(coalesce(p_uit,'')),'') is null then
    raise exception 'Vul een begin- en eindtijd in.' using errcode='P0002';
  end if;
  begin v_tin := p_in::time; v_tuit := p_uit::time;
  exception when others then raise exception 'Die tijd begrijp ik niet. Gebruik bv. 09:30.' using errcode='P0002'; end;

  v_tz  := coalesce((select v.tijdzone from public.vestigingen v where v.code = u.kvest), 'Europe/London');
  v_dag := coalesce((u.ingeklokt_op at time zone v_tz)::date, u.kdatum);
  v_in  := (v_dag + v_tin) at time zone v_tz;
  v_uit := (v_dag + v_tuit + case when coalesce(p_volgende_dag,false) then interval '1 day' else interval '0' end) at time zone v_tz;
  if v_uit <= v_in then raise exception 'De eindtijd moet na de begintijd liggen.' using errcode='P0002'; end if;
  if v_uit - v_in > interval '16 hours' then raise exception 'Dat is langer dan 16 uur. Klopt de tijd?' using errcode='P0002'; end if;
  v_pauze := greatest(0, least(240, coalesce(p_pauze, u.pauze_minuten, 0)));
  v_min := (extract(epoch from (v_uit - v_in))/60)::int;
  if v_pauze >= v_min then raise exception 'De pauze is langer dan de dienst.' using errcode='P0002'; end if;
  if v_in = u.ingeklokt_op and v_uit = u.uitgeklokt_op and v_pauze = coalesce(u.pauze_minuten,0) then return; end if;

  if u.factuur_id is not null then
    select f.ontvangen_op into v_ontvangen from public.facturen f where f.id = u.factuur_id;
    if v_ontvangen is not null then
      raise exception 'Deze uren staan op een factuur die al als ontvangen is gestempeld. Verreken het verschil in de volgende betaalronde.' using errcode='P0002';
    end if;
  end if;
  if exists (select 1 from public.mcr_ronde_verrekening v
               join public.betaalrondes r on r.id = v.ronde_id
              where v.gebruiker_id = u.gebruiker_id and v.ingetrokken_op is null
                and r.vestiging = u.kvest and u.kdatum between r.periode_van and r.periode_tot) then
    raise exception 'De betaalronde van deze uren staat al vast. Zet de ronde eerst terug.' using errcode='P0002';
  end if;

  v_tot   := (round((v_min - v_pauze) / 15.0) * 15)::int;
  v_reden := nullif(public.schoon_kort(p_reden),'');
  select naam into v_naam from public.gebruikers where id = public.huidige_gebruiker();
  v_was := to_char(u.ingeklokt_op at time zone v_tz,'HH24:MI') || '–' || to_char(u.uitgeklokt_op at time zone v_tz,'HH24:MI')
           || ', ' || coalesce(u.pauze_minuten,0) || ' min pauze';

  update public.urenregistraties
     set ingeklokt_op = v_in, uitgeklokt_op = v_uit, pauze_minuten = v_pauze, totaal_minuten = v_tot,
         notitie_beh = concat_ws(' — ', nullif(notitie_beh,''),
                        'tijden aangepast door ' || coalesce(v_naam,'administrator') || ' (was ' || v_was || ')'
                        || coalesce(': ' || v_reden, ''))
   where id = p_uren;

  if v_in is distinct from u.ingeklokt_op then
    insert into public.mcr_wijzigingen (door, gebruiker_id, uren_id, soort, van, naar, reden)
    values (public.huidige_gebruiker(), u.gebruiker_id, p_uren, 'inkloktijd',
            to_char(u.ingeklokt_op at time zone v_tz,'HH24:MI'), to_char(v_in at time zone v_tz,'HH24:MI'), v_reden);
  end if;
  if v_uit is distinct from u.uitgeklokt_op then
    insert into public.mcr_wijzigingen (door, gebruiker_id, uren_id, soort, van, naar, reden)
    values (public.huidige_gebruiker(), u.gebruiker_id, p_uren, 'uitkloktijd',
            to_char(u.uitgeklokt_op at time zone v_tz,'HH24:MI'), to_char(v_uit at time zone v_tz,'HH24:MI'), v_reden);
  end if;
  if v_pauze <> coalesce(u.pauze_minuten,0) then
    insert into public.mcr_wijzigingen (door, gebruiker_id, uren_id, soort, van, naar, reden)
    values (public.huidige_gebruiker(), u.gebruiker_id, p_uren, 'pauze',
            coalesce(u.pauze_minuten,0)::text, v_pauze::text, v_reden);
  end if;

  -- Factuur (nog niet ontvangen) opnieuw optellen uit de uren die erop staan.
  if u.factuur_id is not null then
    update public.facturen f
       set uren = x.uren, bedrag = x.bedrag, regels = x.regels
      from (select jsonb_agg(jsonb_build_object(
                     'datum', kl.datum, 'kraam', coalesce(kr.naam, kl.naam),
                     'van', to_char(ur.ingeklokt_op at time zone v_tz,'HH24:MI'),
                     'tot', to_char(ur.uitgeklokt_op at time zone v_tz,'HH24:MI'),
                     'pauze', coalesce(ur.pauze_minuten,0),
                     'uren', round(ur.totaal_minuten::numeric/60,2),
                     'bedrag', round(ur.totaal_minuten::numeric/60*coalesce(ff.tarief,0),2)) order by kl.datum) as regels,
                   round(sum(ur.totaal_minuten)::numeric/60,2) as uren,
                   round(sum(ur.totaal_minuten)::numeric/60*coalesce(max(ff.tarief),0),2) as bedrag
              from public.urenregistraties ur
              join public.facturen ff on ff.id = ur.factuur_id
              join public.klussen kl on kl.id = ur.klus_id
              left join public.kramen kr on kr.id = kl.kraam_id
             where ur.factuur_id = u.factuur_id and ur.status = 'goedgekeurd') x
     where f.id = u.factuur_id and x.regels is not null;
    perform public.factuur_inhouding(u.factuur_id);
  end if;
end $function$;
