-- Markten: te laat inklokken telt dubbel (17 nov 2026).
-- Bram: "als mensen 1 minuut te laat zijn werken ze die tijd gratis. dus stel je voor ze
-- klokken om 17:10 in terwijl ze om 17:00 moesten beginnen moeten de timer in gaan om 17:20".
-- Regel: wat je te laat bent, werk je nog een keer onbetaald. Dienst 17:00, inklokken
-- 17:10 → uren tellen vanaf 17:20; 17:01 → 17:02. Geldt voor alle markten (MCR, LPL, PAR),
-- alleen bij live inklokken (dagcode, NFC-tag, kraammanager) en alleen bij de eerste
-- registratie van die dag: wie uitklokt en weer inklokt krijgt geen tweede aftrek.
-- De echte inkloktijd blijft bewaard in echt_ingeklokt_op en in notitie_beh; "minuten te
-- laat" (dagafsluiting, Aandacht nodig) rekent met die echte tijd. Zet een beheerder of
-- kraammanager de starttijd daarna met de hand, dan vervalt de aftrek.
-- Niet met terugwerkende kracht: bestaande registraties blijven zoals ze zijn.

alter table public.urenregistraties add column if not exists echt_ingeklokt_op timestamptz;
comment on column public.urenregistraties.echt_ingeklokt_op is
  'Echte inkloktijd als de betaalde tijd later begint omdat iemand te laat inklokte (ingeklokt_op = echte tijd + de vertraging). Leeg als ingeklokt_op de echte tijd is of met de hand is gezet.';

create or replace function public.mcr_inklok_starttijd() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare v_start time; v_dag date; v_tz text; v_kraam uuid; v_begin timestamptz; v_in timestamptz; v_laat interval;
begin
  -- De starttijd is daarna met de hand gezet: de echte inkloktijd hoort er niet meer bij.
  if TG_OP = 'UPDATE' then
    if new.ingeklokt_op is distinct from old.ingeklokt_op
       and new.echt_ingeklokt_op is not distinct from old.echt_ingeklokt_op then
      new.echt_ingeklokt_op := null;
    end if;
    return new;
  end if;
  if new.klus_id is null or new.ingeklokt_op is null or new.uitgeklokt_op is not null then return new; end if;
  -- alleen live inklokken (nu), geen achteraf ingevoerde uren
  if abs(extract(epoch from (new.ingeklokt_op - now()))) > 120 then return new; end if;
  select kl.kraam_id, kl.datum, coalesce(v.tijdzone,'Europe/London') into v_kraam, v_dag, v_tz
    from public.klussen kl join public.kramen k on k.id = kl.kraam_id
    left join public.vestigingen v on v.code = k.vestiging
   where kl.id = new.klus_id;
  if v_kraam is null then return new; end if;
  select min(s.start_tijd) into v_start
    from public.klus_gebruikers kg join public.klus_shifts s on s.id = kg.shift_id
   where kg.klus_id = new.klus_id and kg.gebruiker_id = new.gebruiker_id;
  if v_start is null then return new; end if;
  v_begin := (v_dag + v_start) at time zone v_tz;
  v_in := date_trunc('minute', new.ingeklokt_op);
  if new.ingeklokt_op < v_begin then
    new.notitie_beh := concat_ws(' · ', nullif(new.notitie_beh,''),
      'Clocked in at ' || to_char(new.ingeklokt_op at time zone v_tz,'HH24:MI')
      || ', counted from the start time ' || to_char(v_start,'HH24:MI'));
    new.ingeklokt_op := v_begin;
  elsif v_in > date_trunc('minute', v_begin)
        and not exists (select 1 from public.urenregistraties u
                         where u.klus_id = new.klus_id and u.gebruiker_id = new.gebruiker_id) then
    -- Te laat: de vertraging telt dubbel. Alleen bij de eerste keer inklokken die dag.
    v_laat := v_in - date_trunc('minute', v_begin);
    new.echt_ingeklokt_op := v_in;
    new.ingeklokt_op := v_in + v_laat;
    new.notitie_beh := concat_ws(' · ', nullif(new.notitie_beh,''),
      'Clocked in at ' || to_char(v_in at time zone v_tz,'HH24:MI')
      || ', ' || (extract(epoch from v_laat)/60)::int || ' min late (shift starts ' || to_char(v_start,'HH24:MI')
      || '), counted from ' || to_char(new.ingeklokt_op at time zone v_tz,'HH24:MI'));
  end if;
  return new;
end $$;

drop trigger if exists ab_mcr_inklok_starttijd_upd on public.urenregistraties;
create trigger ab_mcr_inklok_starttijd_upd before update of ingeklokt_op on public.urenregistraties
  for each row execute function public.mcr_inklok_starttijd();

-- "Minuten te laat" en de status van de crew-app rekenen met de echte inkloktijd.
do $$
declare v_def text; v_nieuw text;
begin
  -- dagafsluiting / manager vandaag
  v_def := pg_get_functiondef('public.mcr_dagmensen(uuid,date)'::regprocedure);
  v_nieuw := replace(v_def, 'extract(epoch from (ur.ingeklokt_op - ((p_datum + r.st)',
                            'extract(epoch from (coalesce(ur.echt_ingeklokt_op, ur.ingeklokt_op) - ((p_datum + r.st)');
  if v_nieuw = v_def then raise exception 'mcr_dagmensen: regel niet gevonden'; end if;
  execute v_nieuw;

  -- Uren > Aandacht nodig (later begonnen dan ingeroosterd)
  v_def := pg_get_functiondef('public.mcr_aandacht()'::regprocedure);
  v_nieuw := replace(v_def, 'greatest(0,(extract(epoch from ((u.ingeklokt_op at time zone',
                            'greatest(0,(extract(epoch from ((coalesce(u.echt_ingeklokt_op, u.ingeklokt_op) at time zone');
  v_nieuw := replace(v_nieuw, 'and (u.ingeklokt_op at time zone public.mijn_tijdzone())::time > s.start_tijd',
                              'and (coalesce(u.echt_ingeklokt_op, u.ingeklokt_op) at time zone public.mijn_tijdzone())::time > s.start_tijd');
  if v_nieuw = v_def or v_nieuw not like '%and (coalesce(u.echt_ingeklokt_op%' then raise exception 'mcr_aandacht: regel niet gevonden'; end if;
  execute v_nieuw;

  -- crew-app: de echte inkloktijd erbij, zodat het scherm kan uitleggen vanaf wanneer de uren tellen
  v_def := pg_get_functiondef('public.mcr_klok_status()'::regprocedure);
  v_nieuw := replace(v_def, '''uren_id'', r.uren_id, ''kraam'', r.kraam,',
    '''uren_id'', r.uren_id, ''echt_ingeklokt_op'', (select u.echt_ingeklokt_op from public.urenregistraties u where u.id = r.uren_id), ''kraam'', r.kraam,');
  if v_nieuw = v_def then raise exception 'mcr_klok_status: regel niet gevonden'; end if;
  execute v_nieuw;
end $$;
