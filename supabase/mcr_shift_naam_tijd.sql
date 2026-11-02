-- Manchester: de naam van een dienst bevat vaak de tijd ("16:00–close").
-- Werd de starttijd later aangepast, dan bleef die naam staan en zag het
-- personeel twee verschillende tijden (13:00 – 21:00 · 16:00–close).
-- Deze trigger zet het tijd-stuk in de naam gelijk aan de echte tijden,
-- zodra tijden of naam van een Manchester-dienst veranderen.

create or replace function public.mcr_shift_tijdlabel(p_start time, p_eind time)
returns text language sql immutable as $$
  select to_char(p_start,'HH24:MI') || '–' || coalesce(to_char(p_eind,'HH24:MI'), 'close')
$$;

create or replace function public.mcr_shift_naam_bijwerken()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $function$
begin
  if new.naam is null or new.start_tijd is null then return new; end if;
  if tg_op = 'UPDATE'
     and new.start_tijd is not distinct from old.start_tijd
     and new.eind_tijd  is not distinct from old.eind_tijd
     and new.naam       is not distinct from old.naam then
    return new;
  end if;
  if not exists (select 1 from public.klussen k where k.id = new.klus_id and k.kraam_id is not null) then
    return new;
  end if;
  new.naam := regexp_replace(new.naam,
                '\d{1,2}[:.]\d{2}\s*[–-]\s*(close|sluit|\d{1,2}[:.]\d{2})',
                public.mcr_shift_tijdlabel(new.start_tijd, new.eind_tijd));
  return new;
end $function$;
alter function public.mcr_shift_naam_bijwerken() owner to postgres;

drop trigger if exists ac_mcr_shift_naam on public.klus_shifts;
create trigger ac_mcr_shift_naam
  before insert or update of start_tijd, eind_tijd, naam on public.klus_shifts
  for each row execute function public.mcr_shift_naam_bijwerken();

-- Bestaande diensten rechtzetten.
update public.klus_shifts s
   set naam = regexp_replace(s.naam,
                '\d{1,2}[:.]\d{2}\s*[–-]\s*(close|sluit|\d{1,2}[:.]\d{2})',
                public.mcr_shift_tijdlabel(s.start_tijd, s.eind_tijd))
  from public.klussen k
 where k.id = s.klus_id and k.kraam_id is not null
   and s.naam ~ '\d{1,2}[:.]\d{2}\s*[–-]\s*(close|sluit|\d{1,2}[:.]\d{2})'
   and s.naam !~ public.mcr_shift_tijdlabel(s.start_tijd, s.eind_tijd);
