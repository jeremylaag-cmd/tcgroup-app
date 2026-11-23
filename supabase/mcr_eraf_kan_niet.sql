-- Markten: iemand van een dienst halen omdat hij niet kan (23 nov 2026).
-- Bram: "ik haal ze van de shift. en paar uur of dagen later zet ik ze weer op dezelfde
-- shift omdat ze zelf vergeten hun beschikbaarheid aan te passen."
-- mcr_eraf_kan_niet haalt iemand van de dienst (via mcr_uitdelen) en zet die dag op
-- "niet beschikbaar", tenzij hij die dag nog op een andere dienst staat. De app roept hem
-- aan als het vakje "kan die dag niet" aanstaat; een ruilverzoek dat eindigt met eraf
-- (Meteen eraf, of iemand neemt de shift over) doet het altijd.
create or replace function public.mcr_eraf_kan_niet(p_shift uuid, p_gebruiker uuid)
 returns void language plpgsql security definer set search_path to 'public' as $$
declare v_datum date; v_kraam uuid;
begin
  if not public.mag_plannen() then raise exception 'alleen een beheerder'; end if;
  select kl.datum, kl.kraam_id into v_datum, v_kraam
    from public.klus_shifts s join public.klussen kl on kl.id = s.klus_id where s.id = p_shift;
  perform public.mcr_uitdelen(p_shift, p_gebruiker);
  if v_datum is null or v_kraam is null then return; end if;
  if exists (select 1 from public.klus_gebruikers kg join public.klussen k2 on k2.id = kg.klus_id
              where kg.gebruiker_id = p_gebruiker and k2.datum = v_datum) then
    return;
  end if;
  delete from public.beschikbaarheid
   where gebruiker_id = p_gebruiker and datum_start = v_datum and coalesce(datum_eind, datum_start) = v_datum;
  insert into public.beschikbaarheid (gebruiker_id, datum_start, datum_eind, soort, status, verlofsoort, reden)
  values (p_gebruiker, v_datum, v_datum, 'onbeschikbaar', 'goedgekeurd', 'geen', 'Kan niet (van de shift gehaald)');
end $$;
alter function public.mcr_eraf_kan_niet(uuid,uuid) owner to app_rpc;
revoke all on function public.mcr_eraf_kan_niet(uuid,uuid) from public, anon;
grant execute on function public.mcr_eraf_kan_niet(uuid,uuid) to authenticated, service_role;

do $$
declare v_def text; v_nieuw text;
begin
  v_def := pg_get_functiondef('public.mcr_ruil_beslissen(uuid,text)'::regprocedure);
  v_nieuw := replace(v_def, 'perform public.mcr_uitdelen(x.shift_id, x.gebruiker_id);', 'perform public.mcr_eraf_kan_niet(x.shift_id, x.gebruiker_id);');
  if v_nieuw = v_def then raise exception 'mcr_ruil_beslissen: regel niet gevonden'; end if;
  execute v_nieuw;
  v_def := pg_get_functiondef('public.mcr_indelen(uuid,uuid)'::regprocedure);
  v_nieuw := replace(v_def, 'perform public.mcr_uitdelen(p_shift, rr.gebruiker_id);', 'perform public.mcr_eraf_kan_niet(p_shift, rr.gebruiker_id);');
  if v_nieuw = v_def then raise exception 'mcr_indelen: regel niet gevonden'; end if;
  execute v_nieuw;
end $$;
