-- Kledingborg (en boetes) niet nog een keer inhouden bij een volgende factuur (23 nov 2026).
-- Bram: "Bij de nieuwe facturen moet de borg niet nog een keer gerekend worden. Alleen bij
-- de eerste factuur."
-- Oorzaak: wat al is ingehouden werd alleen geteld uit vastgezette rondes
-- (mcr_ronde_verrekening). Ronde 1 was niet vastgezet, dus bij de facturen van ronde 2 ging
-- de borg er opnieuw af. Nu telt ook wat op een factuur van een eerdere, niet vastgezette
-- ronde is ingehouden — in factuur_inhouding (de factuur van de medewerker) en in
-- mcr_ronde_uitbetaling (het overzicht van de ronde).
do $$
declare v_def text; v_nieuw text;
begin
  v_def := pg_get_functiondef('public.factuur_inhouding(uuid)'::regprocedure);
  v_nieuw := replace(v_def,
    'where v.gebruiker_id = f.gebruiker_id and v.ronde_id <> f.ronde_id and v.ingetrokken_op is null;',
    'where v.gebruiker_id = f.gebruiker_id and v.ronde_id <> f.ronde_id and v.ingetrokken_op is null;
    -- Eerdere rondes die nog niet zijn vastgezet: wat daar al op de factuur is ingehouden telt ook,
    -- anders gaat de kledingborg er bij elke nieuwe factuur opnieuw af.
    select v_borg_al + coalesce(sum(coalesce(f2.borg_in,0) - coalesce(f2.borg_terug,0)),0),
           v_boete_al + coalesce(sum(coalesce(f2.boetes,0)),0)
      into v_borg_al, v_boete_al
      from public.facturen f2 join public.betaalrondes r2 on r2.id = f2.ronde_id
     where f2.gebruiker_id = f.gebruiker_id and f2.id <> f.id and r2.periode_van < b.periode_van
       and not exists (select 1 from public.mcr_ronde_verrekening v2
                        where v2.ronde_id = f2.ronde_id and v2.gebruiker_id = f2.gebruiker_id and v2.ingetrokken_op is null);');
  if v_nieuw = v_def then raise exception 'factuur_inhouding: regel niet gevonden'; end if;
  execute v_nieuw;

  v_def := pg_get_functiondef('public.mcr_ronde_uitbetaling(uuid)'::regprocedure);
  v_nieuw := regexp_replace(v_def,
    'select v\.gebruiker_id, sum\(v\.boetes\) boetes, sum\(v\.borg_in - v\.borg_terug\) borg\s+from public\.mcr_ronde_verrekening v, b\s+where v\.ronde_id <> b\.id and v\.ingetrokken_op is null\s+group by v\.gebruiker_id',
    'select x.gebruiker_id, sum(x.boetes) boetes, sum(x.borg) borg from (
      select v.gebruiker_id, v.boetes, v.borg_in - v.borg_terug as borg
        from public.mcr_ronde_verrekening v, b
       where v.ronde_id <> b.id and v.ingetrokken_op is null
      union all
      select f2.gebruiker_id, coalesce(f2.boetes,0), coalesce(f2.borg_in,0) - coalesce(f2.borg_terug,0)
        from public.facturen f2 join public.betaalrondes r2 on r2.id = f2.ronde_id, b
       where r2.periode_van < b.periode_van and r2.vestiging = b.vestiging
         and not exists (select 1 from public.mcr_ronde_verrekening v2
                          where v2.ronde_id = f2.ronde_id and v2.gebruiker_id = f2.gebruiker_id and v2.ingetrokken_op is null)
    ) x group by x.gebruiker_id');
  if v_nieuw = v_def then raise exception 'mcr_ronde_uitbetaling: regel niet gevonden'; end if;
  execute v_nieuw;
end $$;
-- De facturen van latere rondes die al gemaakt zijn opnieuw doorrekenen.
do $$
begin
  perform public.factuur_inhouding(f.id)
     from public.facturen f join public.betaalrondes b on b.id = f.ronde_id
    where exists (select 1 from public.betaalrondes b1 where b1.vestiging = b.vestiging and b1.periode_van < b.periode_van);
end $$;
