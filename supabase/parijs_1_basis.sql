-- Parijs (deel 1): vestiging, tijdzone per markt, taal per persoon, bankregels.
--
-- * Parijs (PAR) is een markt zoals Manchester: contant + myPOS, euro's,
--   tijdzone Europe/Paris.
-- * mkt_tz(v): de tijdzone van een markt. Tot nu toe stond 'Europe/London' vast
--   in de functies; in Parijs is het een uur later. Functies die door iemand in
--   de app worden aangeroepen gebruiken de tijdzone van zijn actieve vestiging,
--   functies die voor alle markten tegelijk draaien die van de kraam.
-- * Taal: iedereen kiest Nederlands of Engels (gebruikers.taal).
-- * Bank: in Groot-Brittannië IBAN + account number, in Nederland en Parijs
--   alleen IBAN.

-- Hulpje: vervang een stuk tekst in een functie, en stop als het er niet staat.
create or replace function public._fn_vervang(p_fn regprocedure, p_oud text, p_nieuw text, p_alle boolean default true)
returns void language plpgsql as $$
declare v text := pg_get_functiondef(p_fn);
begin
  if position(p_oud in v) = 0 then
    raise exception 'Tekst niet gevonden in %: %', p_fn, left(p_oud, 120);
  end if;
  if p_alle then v := replace(v, p_oud, p_nieuw);
  else v := overlay(v placing p_nieuw from position(p_oud in v) for length(p_oud)); end if;
  execute v;
end $$;
revoke all on function public._fn_vervang(regprocedure, text, text, boolean) from public, anon, authenticated;

-- Vestiging Parijs en Engelse namen
alter table public.vestigingen add column if not exists naam_en text;
update public.vestigingen set naam_en = case code when 'NL' then 'Netherlands' when 'MCR' then 'Manchester'
                                                   when 'LPL' then 'Liverpool' else naam end
 where naam_en is null;
insert into public.vestigingen (code, naam, naam_en, land, tijdzone, valuta, taal, volgorde, actief)
values ('PAR', 'Parijs', 'Paris', 'FR', 'Europe/Paris', 'EUR', 'en', 4, true)
on conflict (code) do nothing;

-- Tijdzone van een markt (zonder markt: de actieve vestiging van wie het vraagt)
create or replace function public.mkt_tz(p_v text default null)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select v.tijdzone from public.vestigingen v where v.code = coalesce(p_v, public.actieve_vestiging())),
                  'Europe/London')
$$;
grant execute on function public.mkt_tz(text) to authenticated, app_rpc, service_role;

-- Aangeroepen vanuit de app: tijdzone van de actieve vestiging
select public._fn_vervang(f::regprocedure, '''Europe/London''', 'public.mkt_tz()')
  from unnest(array[
    'public.mcr_aanmeldingen_al_ingedeeld()', 'public.mcr_aanmeldingen_open()', 'public.mcr_ervaring()',
    'public.mcr_persoon_planning(uuid)', 'public.mcr_ruil_lijst()', 'public.mgr_afsluit_overzicht()',
    'public.mgr_afsluiting(uuid,date)', 'public.mgr_controle_zetten(uuid,date,uuid,text)', 'public.mgr_dagcodes()',
    'public.mgr_inklokken(uuid,uuid)', 'public.mgr_uren_toevoegen(uuid,date,uuid,text,text,integer,text)',
    'public.mgr_vandaag()', 'public.mcr_drukte(date,date)', 'public.mcr_ruil_vragen(uuid,text)'
  ]) f;

-- Voor alle markten tegelijk: tijdzone van de kraam / klus
select public._fn_vervang('public.herinneringen_te_versturen_v2()'::regprocedure,
  'then ''Europe/London'' else', 'then public.mkt_tz(k.vestiging) else');
select public._fn_vervang('public.meld_ziek(date,text)'::regprocedure,
  'then ''Europe/London'' else', 'then public.mkt_tz(v_vest) else');
select public._fn_vervang('public.mcr_ics_data(uuid,uuid)'::regprocedure,
  'at time zone ''Europe/London''', 'at time zone public.mkt_tz(kl.vestiging)');
select public._fn_vervang('public.mcr_kg_push()'::regprocedure,
  '(now() at time zone ''Europe/London'')',
  '(now() at time zone public.mkt_tz((select kx.vestiging from public.kramen kx where kx.id = r.kraam_id)))');
select public._fn_vervang('public.meldingen_voor(uuid)'::regprocedure,
  'kl.datum >= (now() at time zone ''Europe/London'')::date', 'kl.datum >= (now() at time zone public.mkt_tz(kl.vestiging))::date');
select public._fn_vervang('public.mcr_dagmensen(uuid,date)'::regprocedure,
  'at time zone ''Europe/London''', 'at time zone public.mkt_tz((select kx.vestiging from public.kramen kx where kx.id = p_kraam))');
-- Klokmeldingen: de dag blijft Brits, de tijden per kraam
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  '(v_dag + s.start_tijd) at time zone ''Europe/London'' as start_ts',
  '(v_dag + s.start_tijd) at time zone public.mkt_tz(k.vestiging) as start_ts');
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  '(v_dag + coalesce(s.eind_tijd, coalesce(u.open_tot, k.open_tot))) at time zone ''Europe/London'' as eind_ts',
  '(v_dag + coalesce(s.eind_tijd, coalesce(u.open_tot, k.open_tot))) at time zone public.mkt_tz(k.vestiging) as eind_ts');
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  'k.naam as kraam, ur.ingeklokt_op,', 'k.naam as kraam, ur.ingeklokt_op, k.vestiging as kv,');
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  'to_char(x.ingeklokt_op at time zone ''Europe/London'',''HH24:MI'')', 'to_char(x.ingeklokt_op at time zone public.mkt_tz(x.kv),''HH24:MI'')');
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  'then (v_dag + s.eind_tijd) at time zone ''Europe/London''', 'then (v_dag + s.eind_tijd) at time zone public.mkt_tz(k.vestiging)');
select public._fn_vervang('public.mcr_klok_meldingen(timestamp with time zone)'::regprocedure,
  'else ((v_dag + coalesce(u.open_tot, k.open_tot)) at time zone ''Europe/London'')',
  'else ((v_dag + coalesce(u.open_tot, k.open_tot)) at time zone public.mkt_tz(k.vestiging))');
-- (push_wachtrij_bundels: zie deel 2, daar wordt hij helemaal herschreven)

-- Kraammanager: eigen kraam, of een kraam in de markt die hij plant
select public._fn_vervang('public.mgr_kraam_ok(uuid)'::regprocedure,
  'and (m.manager_kraam_id is null or m.manager_kraam_id = k.id))',
  'and (m.manager_kraam_id is null or m.manager_kraam_id = k.id or k.vestiging = m.plant_vestiging))');

-- Bank: account number alleen in Groot-Brittannië verplicht
create or replace function public.bank_compleet(p_iban text, p_account text, p_vest text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(p_iban,'') <> ''
     and (coalesce(p_account,'') <> ''
          or coalesce((select v.land from public.vestigingen v where v.code = p_vest),'GB') <> 'GB')
$$;
grant execute on function public.bank_compleet(text,text,text) to authenticated, app_rpc, service_role;
select public._fn_vervang('public.mcr_factuur_maken(uuid)'::regprocedure,
  'if coalesce(v_g.iban,'''') = '''' or coalesce(v_g.bank_account,'''') = '''' then',
  'if not public.bank_compleet(v_g.iban, v_g.bank_account, v_g.vestiging) then');
select public._fn_vervang('public.mcr_profiel()'::regprocedure,
  '(coalesce(g.iban,'''') <> '''' and coalesce(g.bank_account,'''') <> '''' and coalesce(g.straat,'''') <> '''')',
  '(public.bank_compleet(g.iban, g.bank_account, g.vestiging) and coalesce(g.straat,'''') <> '''')');

-- Taal per persoon
create or replace function public.mijn_taal_zetten(p_taal text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p_taal not in ('nl','en') then raise exception 'Onbekende taal / unknown language'; end if;
  update public.gebruikers set taal = p_taal where id = public.huidige_gebruiker();
end $$;
revoke all on function public.mijn_taal_zetten(text) from public, anon;
grant execute on function public.mijn_taal_zetten(text) to authenticated;

notify pgrst, 'reload schema';
