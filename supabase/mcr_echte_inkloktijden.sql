-- De echte inkloktijd van wie te laat inklokte (zie mcr_te_laat_dubbel), voor de
-- beheerschermen en de kraammanager (17 nov 2026). Alleen lezen. Beheerder/planner: de
-- markt die hij bekijkt; kraammanager: zijn eigen kraam (zelfde afbakening als mgr_uren).
create or replace function public.mcr_echte_inkloktijden(p_van date default null, p_tot date default null)
returns table(uren_id uuid, gebruiker_id uuid, ingeklokt_op timestamptz, echt_ingeklokt_op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select u.id, u.gebruiker_id, u.ingeklokt_op, u.echt_ingeklokt_op
    from public.urenregistraties u
    join public.klussen kl on kl.id = u.klus_id
    join public.kramen kr on kr.id = kl.kraam_id
   where u.echt_ingeklokt_op is not null
     and kl.datum between coalesce(p_van, current_date - 60) and coalesce(p_tot, current_date + 1)
     and public.vest_ok(kr.vestiging) and public.in_actieve_vestiging(kr.vestiging)
     and (public.mag_planbeheer()
          or (public.is_kraammanager()
              and kr.id = coalesce((select m.manager_kraam_id from public.gebruikers m where m.id = public.huidige_gebruiker()), kr.id)))
$$;
alter function public.mcr_echte_inkloktijden(date,date) owner to app_rpc;
revoke all on function public.mcr_echte_inkloktijden(date,date) from public, anon;
grant execute on function public.mcr_echte_inkloktijden(date,date) to authenticated, service_role;
