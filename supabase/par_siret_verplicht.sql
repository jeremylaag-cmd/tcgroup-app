-- Parijs: een factuur maken kan pas met een SIRET-nummer (14 cijfers). 23 nov 2026.
-- Het SIRET staat in gebruikers.utr (belastingnummer; in het VK is dat het UTR).
do $m$
declare def text; nieuw text;
begin
  select pg_get_functiondef(oid) into def from pg_proc where pronamespace='public'::regnamespace and proname='mcr_factuur_maken';
  nieuw := replace(def,
    $a$  select * into v_b from public.betaalrondes where id = p_ronde and vestiging = v_g.vestiging;$a$,
    $a$  if v_g.vestiging = 'PAR' and coalesce(v_g.utr,'') !~ '^[0-9]{14}$' then
    raise exception 'Add your SIRET number (14 digits) first, under Me. In France you need one to send an invoice.' using errcode='P0002';
  end if;
  select * into v_b from public.betaalrondes where id = p_ronde and vestiging = v_g.vestiging;$a$);
  if nieuw = def then raise notice 'mcr_factuur_maken was al aangepast'; else execute nieuw; end if;
end $m$;
