-- Eén rekenregel voor "is deze klus vol?" (24 november 2026)
--
-- Het probleem dat steeds terugkwam: de app en de database rekenden op een
-- stuk of negen plekken elk op hun eigen manier uit of een klus vol was. Had
-- een klus shifts, dan keken de meeste alleen naar de shifts en vergaten ze de
-- plekken voor "Hele klus" (totaal op de klus − wat de shifts vragen). Gevolg:
-- "Deze klus is al vol" bij Vraag mensen, de klus weg uit Open klussen en geen
-- meldingen, terwijl er nog plek was.
--
-- Vanaf nu is er één regel. In de app: klusPlekken() in www/index.html.
-- Hier: klus_open_plekken(). Alles wat wil weten of er plek is, vraagt het
-- daar. De regel:
--   • zonder shifts: open = personeel nodig − wie erop staat;
--   • met shifts: elke shift open = nodig − bezet, en "Hele klus" heeft
--     plek = totaal op de klus − wat de shifts innemen (een shift met meer
--     mensen dan gevraagd neemt die extra plek mee) − wie zonder shift staat;
--   • losse krachten tellen mee; kramen (markten) hebben geen "Hele klus".

create or replace function public.klus_open_plekken(p_klus uuid)
 returns integer
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with sh as (
    select greatest(coalesce(s.personeel_nodig,0),0) as nodig,
           (select count(*) from public.klus_gebruikers kg where kg.klus_id = p_klus and kg.shift_id = s.id)
         + (select count(*) from public.klus_losse_personen l where l.klus_id = p_klus and l.shift_id = s.id) as bezet
      from public.klus_shifts s where s.klus_id = p_klus
  ), t as (
    select count(*) as aantal,
           coalesce(sum(greatest(0, nodig - bezet)),0) as shift_open,
           coalesce(sum(greatest(nodig, bezet)),0)     as neemt_in,
           coalesce(sum(bezet),0)                      as in_shift
      from sh
  )
  select (case when t.aantal = 0
            then greatest(0, greatest(coalesce(k.personeel_nodig,0),0) - m.bezet)
            else t.shift_open
               + case when k.kraam_id is not null then 0
                      else greatest(0, greatest(coalesce(k.personeel_nodig,0),0) - t.neemt_in
                                       - greatest(0, m.bezet - t.in_shift)) end
          end)::int
    from public.klussen k
    cross join t
    cross join lateral (
      select (select count(*) from public.klus_gebruikers kg where kg.klus_id = k.id)
           + (select count(*) from public.klus_losse_personen l where l.klus_id = k.id) as bezet
    ) m
   where k.id = p_klus
$function$;

-- Dashboard "Klussen die nog niet vol zijn": zelfde regel.
create or replace function public.dashboard_open_plekken(p_dagen integer default 14)
 returns table(klus_id uuid, naam text, datum date, nodig integer, ingedeeld integer, open integer, dagen integer)
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  if not public.is_beheerder() then return; end if;

  return query
  with bezet as (
    select k.id,
           (coalesce((select count(*) from public.klus_gebruikers kg where kg.klus_id = k.id),0)
          + coalesce((select count(*) from public.klus_losse_personen kl where kl.klus_id = k.id),0))::int as mensen,
           coalesce(public.klus_open_plekken(k.id),0) as vrij
    from public.klussen k
    where k.datum between current_date and current_date + p_dagen
      and coalesce(k.is_optie,false) = false
  )
  select k.id, k.naam, k.datum, (b.mensen + b.vrij)::int, b.mensen, b.vrij,
         (k.datum - current_date)::int
  from public.klussen k
  join bezet b on b.id = k.id
  where b.vrij > 0
  order by k.datum;
end $function$;

-- Het bolletje "klussen wachten op je antwoord" bij medewerkers: zelfde regel.
-- (De rest van meldingen_voor blijft zoals hij is; alleen het eigen rekenblok
-- wordt vervangen door de vraag aan klus_open_plekken.)
do $do$
declare v_def text; v_van int; v_tot int; v_eind text := E'l.klus_id = k.id))\n       );';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'meldingen_voor';
  if v_def like '%public.klus_open_plekken(k.id) > 0%' then return; end if;   -- al gedaan
  v_van := position(E'       and (\n         (exists (select 1 from public.klus_shifts s where s.klus_id = k.id)' in v_def);
  v_tot := position(v_eind in v_def);
  if v_van = 0 or v_tot = 0 or v_tot < v_van then
    raise exception 'meldingen_voor ziet er anders uit dan verwacht; niets aangepast.';
  end if;
  execute substr(v_def, 1, v_van - 1)
       || '       and public.klus_open_plekken(k.id) > 0;'
       || substr(v_def, v_tot + length(v_eind));
end $do$;
