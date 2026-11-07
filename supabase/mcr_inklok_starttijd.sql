-- Manchester: te vroeg inklokken telt vanaf de starttijd (7 nov 2026).
-- Bram: "als iemand 10 min of 5 min van te voren inklokt dat de geklokte shift
-- gewoon om zijn starttijd begint" — dienst 10:00-17:00, inklokken 09:53 → 10:00.
-- Geldt voor live inklokken (dagcode, NFC-tag, kraammanager); niet voor uren die
-- achteraf met de hand worden ingevoerd. Te laat blijft de echte tijd.
-- De echte inkloktijd komt in notitie_beh. Doorgevoerd 7 nov 22:2x.
create or replace function public.mcr_inklok_starttijd() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare v_start time; v_dag date; v_tz text; v_kraam uuid; v_begin timestamptz;
begin
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
  if new.ingeklokt_op < v_begin then
    new.notitie_beh := concat_ws(' · ', nullif(new.notitie_beh,''),
      'Klokte in om ' || to_char(new.ingeklokt_op at time zone v_tz,'HH24:MI')
      || ', telt vanaf de starttijd ' || to_char(v_start,'HH24:MI'));
    new.ingeklokt_op := v_begin;
  end if;
  return new;
end $$;

create trigger ab_mcr_inklok_starttijd before insert on public.urenregistraties
  for each row execute function public.mcr_inklok_starttijd();
