-- Manchester: de omzet is alleen voor Bram (7 nov 2026)
--
-- Bram: "zorg dat alleen mijn account (bram@tcgroup) dit allemaal kan zien."
-- Tot nu toe kon elke beheerder met recht op Manchester (mag_kraambeheer) de
-- omzet zien. Dat was in de praktijk alleen Bram, maar het hing af van wie
-- er later "alle vestigingen" of beheerdersrechten in Manchester krijgt.
--
-- * mag_omzet_zien(): waar alleen voor Bram's account (administrator én dit
--   ene gebruikers-id). Een tweede administrator ziet de omzet dus ook niet.
-- * Leesfuncties met omzet eisen het nu naast mag_kraambeheer():
--   mcr_dagrapport, mcr_cijfers, mcr_dagtotalen, mcr_uuromzet,
--   mcr_uur_bezetting, mcr_bezetting, mypos_terminals_gezien,
--   mypos_tid_kiezen, mypos_accounts_lijst, mypos_nu_ophalen.
-- * Restrictieve regels op dagrapporten, pin_dag, pin_uur en pin_referenties
--   voor authenticated en app_rpc: Manchester-rijen alleen voor Bram. Ook wie
--   rechtstreeks met de server praat krijgt dus niets. De myPOS-import
--   (service_role) en postgres staan er los van en blijven werken.
--
-- Let op: geen enkele regel in dit bestand gebruikt het woord voor weghalen.

create or replace function public.mag_omzet_zien()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.huidige_gebruiker() = 'adb8bd40-f0b6-4aa2-a16d-a67932202c02'::uuid
     and public.is_administrator()
$$;
revoke all on function public.mag_omzet_zien() from public, anon;
grant execute on function public.mag_omzet_zien() to authenticated, app_rpc, service_role;

-- Functies: "public.mag_kraambeheer()" → "(public.mag_kraambeheer() and public.mag_omzet_zien())".
do $$
declare f text; d text;
begin
  foreach f in array array[
    'public.mcr_dagrapport(date,date,uuid)', 'public.mcr_cijfers(date,date)', 'public.mcr_dagtotalen(date,date)',
    'public.mcr_uuromzet(date,date,uuid)', 'public.mcr_uur_bezetting(date,date,uuid)', 'public.mcr_bezetting(date,date)',
    'public.mypos_terminals_gezien()', 'public.mypos_tid_kiezen(text,uuid)', 'public.mypos_accounts_lijst()',
    'public.mypos_nu_ophalen()']
  loop
    d := pg_get_functiondef(f::regprocedure);
    if position('mag_omzet_zien' in d) > 0 then continue; end if;
    if position('public.mag_kraambeheer()' in d) = 0 then
      raise exception 'mag_kraambeheer() niet gevonden in %', f;
    end if;
    execute replace(d, 'public.mag_kraambeheer()', '(public.mag_kraambeheer() and public.mag_omzet_zien())');
  end loop;
end $$;

-- Tabellen: Manchester-rijen alleen voor Bram.
create policy "omzet mcr alleen bram" on public.dagrapporten as restrictive for all to authenticated, app_rpc
  using (public.vest_kraam(kraam_id) is distinct from 'MCR' or public.mag_omzet_zien())
  with check (public.vest_kraam(kraam_id) is distinct from 'MCR' or public.mag_omzet_zien());
create policy "omzet mcr alleen bram" on public.pin_dag as restrictive for all to authenticated, app_rpc
  using (vestiging is distinct from 'MCR' or public.mag_omzet_zien())
  with check (vestiging is distinct from 'MCR' or public.mag_omzet_zien());
create policy "omzet mcr alleen bram" on public.pin_uur as restrictive for all to authenticated, app_rpc
  using (vestiging is distinct from 'MCR' or public.mag_omzet_zien())
  with check (vestiging is distinct from 'MCR' or public.mag_omzet_zien());
create policy "omzet mcr alleen bram" on public.pin_referenties as restrictive for all to authenticated, app_rpc
  using (vestiging is distinct from 'MCR' or public.mag_omzet_zien())
  with check (vestiging is distinct from 'MCR' or public.mag_omzet_zien());
