-- Kledingborg (en eventuele boetes) zichtbaar op de factuur, en de borg in één keer
-- bij de eerste betaling in plaats van verdeeld over twee rondes.

alter table public.facturen
  add column if not exists boetes     numeric not null default 0,
  add column if not exists borg_in    numeric not null default 0,
  add column if not exists borg_terug numeric not null default 0,
  add column if not exists te_betalen numeric;

-- Rekent voor één factuur uit wat er wordt ingehouden of terugkomt, met dezelfde
-- regels als de uitbetaling. Staat de ronde al vast, dan gelden de vastgezette bedragen.
create or replace function public.factuur_inhouding(p_factuur uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  f record; g record; b record; h record;
  v_borg_nu numeric; v_borg_al numeric; v_boete_al numeric; v_boetes_open numeric;
  v_terug numeric; v_boete numeric; v_borg_in numeric;
begin
  select * into f from public.facturen where id = p_factuur;
  if f.id is null then return; end if;
  select * into g from public.gebruikers where id = f.gebruiker_id;
  select * into b from public.betaalrondes where id = f.ronde_id;
  select * into h from public.mcr_ronde_verrekening v
   where v.ronde_id = f.ronde_id and v.gebruiker_id = f.gebruiker_id and v.ingetrokken_op is null;

  if h.ronde_id is not null then
    v_boete := coalesce(h.boetes,0); v_borg_in := coalesce(h.borg_in,0); v_terug := coalesce(h.borg_terug,0);
  else
    v_borg_nu := public.mcr_kleding_borg(g.vestiging, g.kleding_polo, g.kleding_schort);
    select coalesce(sum(v.borg_in - v.borg_terug),0), coalesce(sum(v.boetes),0)
      into v_borg_al, v_boete_al
      from public.mcr_ronde_verrekening v
     where v.gebruiker_id = f.gebruiker_id and v.ronde_id <> f.ronde_id and v.ingetrokken_op is null;
    v_boetes_open := greatest(0, coalesce((select sum(vv.boete) from public.mcr_voorvallen vv
                                            where vv.gebruiker_id = f.gebruiker_id and vv.datum <= b.periode_tot
                                              and coalesce(vv.boete,0) > 0),0) - v_boete_al);
    v_terug   := greatest(0, v_borg_al - v_borg_nu);
    v_boete   := least(v_boetes_open, f.bedrag + v_terug);
    v_borg_in := greatest(0, least(greatest(0, v_borg_nu - v_borg_al), f.bedrag + v_terug - v_boete));
  end if;

  update public.facturen
     set boetes = v_boete, borg_in = v_borg_in, borg_terug = v_terug,
         te_betalen = greatest(0, f.bedrag + v_terug - v_boete - v_borg_in)
   where id = p_factuur;
end $$;
revoke all on function public.factuur_inhouding(uuid) from public, anon, authenticated;
grant execute on function public.factuur_inhouding(uuid) to app_rpc, service_role;

-- Uitbetaling: borg in één keer (niet meer per ronde hooguit de helft)
select public._fn_vervang('public.mcr_ronde_uitbetaling(uuid)'::regprocedure,
  'least(greatest(0, y.borg_nu - y.borg_al), round(y.borg_nu / 2, 2), y.bruto + y.r_terug - y.r_boete)',
  'least(greatest(0, y.borg_nu - y.borg_al), y.bruto + y.r_terug - y.r_boete)');

-- Factuur maken: inhouding meteen op de factuur zetten
select public._fn_vervang('public.mcr_factuur_maken(uuid)'::regprocedure,
$o$     and u.factuur_id is null and kl.datum <= v_b.periode_tot;

  return next;$o$,
$n$     and u.factuur_id is null and kl.datum <= v_b.periode_tot;

  perform public.factuur_inhouding(v_id);
  return next;$n$);

-- Ronde vastzetten of terugzetten: facturen van die ronde bijwerken
select public._fn_vervang('public.mcr_ronde_vastzetten(uuid,boolean)'::regprocedure,
$o$  end if;
  return n;$o$,
$n$  end if;
  perform public.factuur_inhouding(f.id) from public.facturen f where f.ronde_id = p_ronde;
  return n;$n$);

-- Bestaande facturen meteen bijwerken
select public.factuur_inhouding(f.id) from public.facturen f;
