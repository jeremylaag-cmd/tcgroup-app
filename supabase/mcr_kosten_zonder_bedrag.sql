-- Kostenpost zonder bedrag (23 nov 2026)
-- Bram weet sommige kosten nog niet en wil de post alvast neerzetten.
-- Bedrag 0 betekent: "nog in te vullen". Negatief blijft geweigerd.
alter table public.mcr_kosten drop constraint mcr_kosten_bedrag_check;
alter table public.mcr_kosten add constraint mcr_kosten_bedrag_check check (bedrag >= 0 and bedrag < 1000000);

do $m$
declare def text; nieuw text;
begin
  select pg_get_functiondef(p.oid) into def from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='mcr_kosten_zetten2';
  nieuw := replace(def,
    'if p_bedrag is null or p_bedrag <= 0 then raise exception ''Vul een bedrag groter dan 0 in.''; end if;',
    'p_bedrag := coalesce(p_bedrag, 0);
  if p_bedrag < 0 then raise exception ''Een bedrag kan niet negatief zijn.''; end if;');
  if nieuw = def then raise notice 'mcr_kosten_zetten2 was al aangepast'; else execute nieuw; end if;
end $m$;
