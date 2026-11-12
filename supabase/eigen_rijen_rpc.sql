-- Ook binnen de app-functies (rol app_rpc) is iemands eigen rij altijd zichtbaar,
-- ook als hij in zijn tweede vestiging werkt (Benedek: Parijs, tot 21 nov ook
-- Manchester). Zonder dit zag is_kraammanager() zijn eigen gebruikersrij niet en
-- kreeg hij in Manchester de gewone personeelsapp in plaats van de managerapp.
alter policy "rpc gebruikers" on public.gebruikers
  using (id = public.huidige_gebruiker() or vestiging in (select unnest(zichtbare_vestigingen())))
  with check (id = public.huidige_gebruiker() or vestiging in (select unnest(zichtbare_vestigingen())));
do $$
declare t text;
begin
  foreach t in array array['uitgiftes','uitdienst','beschikbaarheid','urenregistraties','saldo_mutaties','verlof_saldo',
                           'push_herinneringen','taak_personen','huisregels_akkoord'] loop
    execute format($f$alter policy %I on public.%I
      using (gebruiker_id = public.huidige_gebruiker() or vest_gebruiker(gebruiker_id) in (select unnest(zichtbare_vestigingen())))
      with check (gebruiker_id = public.huidige_gebruiker() or vest_gebruiker(gebruiker_id) in (select unnest(zichtbare_vestigingen())))$f$,
      'rpc '||t, t);
  end loop;
end $$;
