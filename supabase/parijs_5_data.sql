-- Parijs (deel 5): kraam, openingstijden, instellingen, huisregels, diensten, Benedek.

insert into public.kramen (vestiging, code, naam, adres, kleur, seizoen_start, seizoen_eind, open_van, open_tot, volgorde, actief)
select 'PAR', 'PAR', 'Paris', 'Champs-Élysées, Paris', '#0E7490', date '2026-11-22', date '2027-01-04',
       time '10:00', time '22:00', 1, true
 where not exists (select 1 from public.kramen where vestiging = 'PAR' and code = 'PAR');

-- Vrijdag t/m zondag tot 23:00; 24 december tot 20:00; 31 december dicht
insert into public.kraam_uitzonderingen (kraam_id, datum, dicht, open_van, open_tot, reden)
select k.id, d::date, false, time '10:00', time '23:00', 'Vrijdag t/m zondag tot 23:00'
  from public.kramen k
  cross join generate_series(date '2026-11-22', date '2027-01-04', interval '1 day') d
 where k.vestiging = 'PAR' and k.code = 'PAR' and extract(isodow from d) in (5,6,7)
   and d::date not in (date '2026-12-31')
   and not exists (select 1 from public.kraam_uitzonderingen u where u.kraam_id = k.id and u.datum = d::date);
insert into public.kraam_uitzonderingen (kraam_id, datum, dicht, open_van, open_tot, reden)
select k.id, x.datum, x.dicht, x.van, x.tot, x.reden
  from public.kramen k
  cross join (values
    (date '2026-12-24', false, time '10:00', time '20:00', 'Kerstavond'),
    (date '2026-12-31', true,  null::time,   null::time,   'Oudjaarsdag: dicht')
  ) as x(datum, dicht, van, tot, reden)
 where k.vestiging = 'PAR' and k.code = 'PAR'
   and not exists (select 1 from public.kraam_uitzonderingen u where u.kraam_id = k.id and u.datum = x.datum);

insert into public.kraam_patronen (kraam_id, weekdag, start_tijd, personeel_nodig, naam, volgorde, actief)
select k.id, wd, p.start, 2, p.naam, p.volg, true
  from public.kramen k
  cross join generate_series(0,6) wd
  cross join (values (time '10:00', 'Opening', 1), (time '15:00', 'Middag', 2)) as p(start, naam, volg)
 where k.vestiging = 'PAR' and k.code = 'PAR'
   and not exists (select 1 from public.kraam_patronen x where x.kraam_id = k.id);

-- Instellingen: van Manchester, met wat in Parijs anders is
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving, bijgewerkt_op)
select 'PAR', i.sleutel, i.waarde, i.omschrijving, now()
  from public.vestiging_instellingen i
 where i.vestiging = 'MCR'
on conflict do nothing;
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving, bijgewerkt_op) values
  ('PAR', 'contant',      'ja',     'Wordt er contant betaald? nee = geen kasvelden in dagrapport en omzet', now()),
  ('PAR', 'pin_bron',     'mypos',  'myPOS = automatisch ophalen; handmatig = dagtotalen per terminal van de bon invullen', now()),
  ('PAR', 'afdracht_pct', '0',      'Percentage van de omzet dat naar de markt gaat', now()),
  ('PAR', 'vraag_fruit',  'ja',     'Bij het afsluiten vragen hoeveel aardbeien en bananen er nodig zijn', now()),
  ('PAR', 'prijs_portie', '8.00',   null, now()),
  ('PAR', 'factuur_naam', 'The Creperie Group B.V.', null, now()),
  ('PAR', 'factuur_adres','Het Steenland 39, 3751 LA Bunschoten, Netherlands', null, now())
on conflict (vestiging, sleutel) do update set waarde = excluded.waarde, bijgewerkt_op = now();

-- Huisregels: de Engelse versie van Manchester, met Paris erin
insert into public.huisregels (vestiging, taal, versie, titel, tekst, actief)
select 'PAR', h.taal, h.versie, replace(h.titel, 'Manchester', 'Paris'), replace(h.tekst, 'Manchester', 'Paris'), true
  from public.huisregels h
 where h.vestiging = 'MCR' and h.actief
   and not exists (select 1 from public.huisregels x where x.vestiging = 'PAR');

-- Basisdiensten: vanaf opening en vanaf 15:00, elk 2 mensen, tot sluiting
do $$
declare k record; d date; v_open time; v_sluit time; v_dicht boolean; v_klus uuid; s time;
begin
  select * into k from public.kramen where vestiging = 'PAR' and code = 'PAR';
  if exists (select 1 from public.klussen where kraam_id = k.id) then return; end if;
  d := k.seizoen_start;
  while d <= k.seizoen_eind loop
    select coalesce(u.dicht,false), coalesce(u.open_van, k.open_van), coalesce(u.open_tot, k.open_tot)
      into v_dicht, v_open, v_sluit
      from (select 1) x left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d;
    if not v_dicht then
      insert into public.klussen (naam, datum, personen, food, adres, categorie, vestiging,
                                  kraam_id, start_tijd, einde_klus, eind_tijd, personeel_nodig, buiten)
      values (k.naam, d, 0, 'poffertjes', k.adres, 'klus', k.vestiging, k.id, v_open, v_sluit, v_sluit, 0, true)
      returning id into v_klus;
      foreach s in array array[v_open, time '15:00'] loop
        insert into public.klus_shifts (klus_id, naam, start_tijd, eind_tijd, personeel_nodig, volgorde)
        values (v_klus, to_char(s,'HH24:MI') || '–close', s, null, 2, (extract(hour from s)*60 + extract(minute from s))::int);
      end loop;
      update public.klussen set personeel_nodig = 4 where id = v_klus;
    end if;
    d := d + 1;
  end loop;
end $$;

-- Benedek: thuis Parijs en planner daar; tot en met 21 november ook Manchester
-- (daar kraammanager, zoals nu). Als Bram, want alleen de administrator mag dit.
select set_config('request.jwt.claims', '{"sub":"adb8bd40-f0b6-4aa2-a16d-a67932202c02","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'adb8bd40-f0b6-4aa2-a16d-a67932202c02', true);
update public.gebruikers
   set vestiging = 'PAR', tweede_vestiging = 'MCR', tweede_tot = date '2026-11-21',
       plant_vestiging = 'PAR', actieve_vestiging = null
 where id = '050e6f7f-9f99-4b1e-80b4-85a914386858' and vestiging = 'MCR';
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);

notify pgrst, 'reload schema';
