-- Eigen rijen altijd zichtbaar, ook in een tweede vestiging.
--
-- Andras hoort bij Liverpool (LPL) maar werkt tot 21 november ook in
-- Manchester. In Manchester-modus is zichtbare_vestigingen() = {MCR}, terwijl
-- vest_gebruiker(Andras) = LPL. De RESTRICTIVE vestigingsregels op tabellen
-- met eigen rijen sloten daardoor zijn eigen rijen uit: hij kon de huisregels
-- niet accepteren (403) en kwam de app niet in. Eigen rijen (gebruiker_id =
-- auth.uid()) vallen voortaan altijd binnen de vestigingsgrens; wat iemand
-- ermee mag, bepalen de gewone (permissive) regels zoals voorheen.
do $$
declare t text;
begin
  foreach t in array array['beschikbaarheid','huisregels_akkoord','push_herinneringen','saldo_mutaties',
                           'taak_personen','uitdienst','uitgiftes','urenregistraties','verlof_saldo'] loop
    execute format($f$alter policy %I on public.%I
      using (gebruiker_id = auth.uid() or vest_gebruiker(gebruiker_id) in (select unnest(zichtbare_vestigingen())))
      with check (gebruiker_id = auth.uid() or vest_gebruiker(gebruiker_id) in (select unnest(zichtbare_vestigingen())))$f$,
      'zz vestiging '||t, t);
  end loop;
end $$;
