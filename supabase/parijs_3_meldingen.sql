-- Parijs (deel 3): pushmeldingen in de taal van de ontvanger, met de naam van
-- de juiste markt (niet altijd "Manchester"), en "kraam nog niet afgesloten" in
-- de tijdzone van de kraam.
create or replace function public.push_wachtrij_bundels()
returns table(gebruiker_id uuid, push_token text, push_platform text, ids bigint[], soort text, titel text, bericht text, pagina text)
language plpgsql security definer set search_path to 'public'
as $function$
#variable_conflict use_column
declare v_nu timestamp := (now() at time zone 'Europe/London');
        v_uur int := extract(hour from (now() at time zone 'Europe/London'))::int;
begin
  begin
    perform public.mcr_klok_meldingen(now());
  exception when others then
    raise warning 'mcr_klok_meldingen: %', sqlerrm;
  end;
  with dag as (
    select kl.id as klus_id, k.id as kid, k.naam, k.vestiging, kl.datum
      from public.kramen k
      join public.klussen kl on kl.kraam_id = k.id and kl.datum = (now() at time zone public.mkt_tz(k.vestiging))::date
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = kl.datum
     where k.actief and not coalesce(u.dicht,false)
       and kl.datum between k.seizoen_start and k.seizoen_eind
       and coalesce(u.open_tot,k.open_tot) > coalesce(u.open_van,k.open_van)
       and coalesce(u.open_tot,k.open_tot) < time '23:15'
       and (now() at time zone public.mkt_tz(k.vestiging))::time >= coalesce(u.open_tot,k.open_tot) + interval '45 minutes'
       and exists (select 1 from public.klus_shifts s join public.klus_gebruikers kg on kg.shift_id = s.id where s.klus_id = kl.id)
       and not exists (select 1 from public.mcr_dagafsluiting a where a.kraam_id = k.id and a.datum = kl.datum and a.afgesloten_op is not null)
  ), ontv as (
    select d.klus_id, x.gid, 'mcr_dag_open'::text as sr, d.naam as rg
      from dag d cross join lateral (select public.mcr_afsluiters(d.kid, d.datum) as gid) x
    union all
    select d.klus_id, b.id, 'mcr_dag_open_b', d.naam
      from dag d join public.gebruikers b on b.gearchiveerd_op is null
                  and ((b.rol = 'beheerder' and (coalesce(b.alle_vestigingen,false) or b.vestiging = d.vestiging))
                       or (b.plant_vestiging = d.vestiging and coalesce(b.goedgekeurd,false)))
  )
  insert into public.push_wachtrij (gebruiker_id, soort, klus_id, regel)
  select o.gid, o.sr, o.klus_id, o.rg from ontv o
   where o.gid is not null
     and not exists (select 1 from public.push_wachtrij w where w.soort = o.sr and w.klus_id = o.klus_id and w.gebruiker_id = o.gid);
  if v_nu::time >= time '19:00' then
    insert into public.push_wachtrij (gebruiker_id, soort, klus_id, shift_id, regel)
    select kg.gebruiker_id, 'mcr_morgen', kl.id, sh.id,
           to_char(sh.start_tijd,'HH24:MI') || '–' || coalesce(to_char(sh.eind_tijd,'HH24:MI'),'close') || ' · ' || k.naam
           || coalesce(' · manager ' || (
                select string_agg(x.t, ', ' order by x.o) from (
                  select 1 o, g.naam || coalesce(' ' || g.telefoon,'') t
                    from public.mcr_manager_week mw join public.gebruikers g on g.id = mw.gebruiker_id
                   where mw.kraam_id = k.id and mw.week_start = date_trunc('week', kl.datum)::date
                     and g.kraammanager and g.gearchiveerd_op is null
                  union all
                  select 2, wm.naam || coalesce(' ' || wm.telefoon,'')
                    from public.mcr_manager_dag md join public.mcr_weekendmanagers wm on wm.id = md.weekendmanager_id
                   where md.kraam_id = k.id and md.datum = kl.datum) x), '')
      from public.klus_gebruikers kg
      join public.klus_shifts sh on sh.id = kg.shift_id
      join public.klussen kl on kl.id = kg.klus_id
      join public.kramen k on k.id = kl.kraam_id
      join public.gebruikers pg on pg.id = kg.gebruiker_id and pg.push_token is not null and pg.gearchiveerd_op is null
     where kl.datum = v_nu::date + 1
       and not exists (select 1 from public.push_wachtrij w where w.soort = 'mcr_morgen' and w.shift_id = sh.id and w.gebruiker_id = kg.gebruiker_id);
  end if;
  update public.push_wachtrij w set verwerkt_op = now(), uitslag = 'vervallen'
   where w.verwerkt_op is null and (
         w.regel is null
      or (w.soort = 'mcr_erop' and not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id))
      or (w.soort = 'mcr_eraf' and exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id))
      or (w.soort = 'mcr_eraf' and exists (select 1 from public.push_wachtrij e where e.soort = 'mcr_erop' and e.shift_id = w.shift_id
                                            and e.gebruiker_id = w.gebruiker_id and e.aangemaakt_op > now() - interval '1 day'
                                            and coalesce(e.uitslag,'') <> 'verstuurd' and e.id < w.id))
      or (w.soort = 'mcr_ruil_ok' and not exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.gebruiker_id = w.gebruiker_id and r.status = 'open'))
      or (w.soort = 'mcr_ruil_open' and (
             exists (select 1 from public.klus_gebruikers kg join public.klussen k2 on k2.id = kg.klus_id
                      where kg.gebruiker_id = w.gebruiker_id and k2.id = w.klus_id)
          or not ( (select count(*) from public.klus_gebruikers kg where kg.shift_id = w.shift_id)
                     < coalesce((select s.personeel_nodig from public.klus_shifts s where s.id = w.shift_id),0)
                   or exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.status = 'open'))))
      or (w.soort = 'mcr_ruil_gevraagd' and not exists (select 1 from public.mcr_shift_ruil r where r.shift_id = w.shift_id and r.status = 'gevraagd'))
      or (w.soort = 'mcr_agenda_manager' and not exists (select 1 from public.mcr_agenda a where a.id = w.agenda_id))
      or (w.soort in ('mcr_dag_open','mcr_dag_open_b') and (
             w.aangemaakt_op < now() - interval '14 hours'
          or exists (select 1 from public.mcr_dagafsluiting a join public.klussen k3 on k3.kraam_id = a.kraam_id and k3.datum = a.datum
                      where k3.id = w.klus_id and a.afgesloten_op is not null)))
      or (w.soort = 'mcr_morgen' and (
             w.aangemaakt_op < (v_nu::date::timestamp at time zone 'Europe/London')
          or not exists (select 1 from public.klus_gebruikers kg where kg.shift_id = w.shift_id and kg.gebruiker_id = w.gebruiker_id)))
      or (w.soort = 'mcr_voorraad' and w.aangemaakt_op < now() - interval '10 hours')
      or not exists (select 1 from public.gebruikers g where g.id = w.gebruiker_id and g.push_token is not null and g.gearchiveerd_op is null)
      or (w.soort = 'nl_crm_optie' and not exists (select 1 from public.klussen k where k.id = w.klus_id and k.is_optie))
      or w.aangemaakt_op < now() - interval '3 days');
  if v_uur < 6 then return; end if;
  return query
  with w as (
    select x.*,
           exists (select 1 from public.mcr_shift_ruil r where r.shift_id = x.shift_id and r.gebruiker_id = x.gebruiker_id
                     and r.status in ('overgenomen','vrijgegeven')) as via_ruil
      from public.push_wachtrij x
     where x.verwerkt_op is null
       and (x.aangemaakt_op < now() - interval '2 minutes' or x.soort in ('mcr_niet_in','mcr_nog_in'))
       and (v_uur < 22 or x.soort in ('mcr_dag_open','mcr_dag_open_b','mcr_dag_dicht','mcr_nog_in'))
       and (v_uur >= 8 or x.soort = 'nl_ziek')
  ), g as (
    select w.gebruiker_id, w.soort, array_agg(w.id order by w.id) as ids, count(*)::int as n,
           string_agg(w.regel, E'\n' order by w.id) as regels, bool_and(w.via_ruil) as via_ruil,
           (array_agg(w.shift_id order by w.id))[1] as sid,
           (array_agg(w.klus_id order by w.id) filter (where w.klus_id is not null))[1] as kid
      from w group by w.gebruiker_id, w.soort
  ), t as (
    select g.*, u.push_token, u.push_platform,
           coalesce(u.taal, (select v.taal from public.vestigingen v where v.code = u.vestiging), 'en') = 'nl' as nl,
           coalesce((select case when coalesce(u.taal, vu.taal, 'en') = 'nl' then vm.naam else coalesce(vm.naam_en, vm.naam) end
                       from public.klussen kx join public.vestigingen vm on vm.code = kx.vestiging
                       left join public.vestigingen vu on vu.code = u.vestiging
                      where kx.id = g.kid),
                    (select case when coalesce(u.taal, vm.taal, 'en') = 'nl' then vm.naam else coalesce(vm.naam_en, vm.naam) end
                       from public.vestigingen vm where vm.code = coalesce(u.plant_vestiging, u.vestiging)),
                    'Market') as markt
      from g join public.gebruikers u on u.id = g.gebruiker_id
     where u.push_token is not null
  )
  select t.gebruiker_id, t.push_token, t.push_platform, t.ids, t.soort,
         case t.soort
           when 'mcr_erop' then case when t.nl then case when t.n = 1 then 'Je staat op het rooster' else 'Je staat voor ' || t.n || ' diensten op het rooster' end
                                     else case when t.n = 1 then 'You''re on the rota' else 'You''re on the rota for ' || t.n || ' shifts' end end
           when 'mcr_eraf' then case when t.via_ruil then case when t.nl then 'Ruil gelukt' else 'Swap done' end
                                     else case when t.nl then 'Roosterwijziging' else 'Rota change' end end
           when 'mcr_ruil_ok' then case when t.nl then 'Je dienst staat open om te ruilen' else 'Your shift is open for a swap' end
           when 'mcr_ruil_nee' then case when t.nl then 'Ruil niet goedgekeurd' else 'Swap not approved' end
           when 'mcr_ruil_open' then case when t.nl then case when t.n = 1 then 'Dienst beschikbaar' else t.n || ' diensten beschikbaar' end
                                          else case when t.n = 1 then 'Shift available' else t.n || ' shifts available' end end
           when 'mcr_ruil_gevraagd' then t.markt || ': ' || case when t.nl then case when t.n = 1 then 'shift ruilen gevraagd' else t.n || ' keer shift ruilen gevraagd' end
                                                              else case when t.n = 1 then 'shift swap requested' else t.n || ' shift swaps requested' end end
           when 'mcr_agenda_manager' then t.markt || ': ' || case when t.nl then case when t.n = 1 then 'nieuw in de agenda' else t.n || ' nieuwe agenda-items' end
                                                               else case when t.n = 1 then 'new in the calendar' else t.n || ' new calendar items' end end
           when 'mcr_dag_open' then case when t.nl then 'Sluit de dag af' else 'Close the day' end
           when 'mcr_dag_open_b' then t.markt || ': ' || case when t.nl then case when t.n = 1 then 'kraam nog niet afgesloten' else t.n || ' kramen nog niet afgesloten' end
                                                           else case when t.n = 1 then 'stall not closed yet' else t.n || ' stalls not closed yet' end end
           when 'mcr_dag_dicht' then t.markt || ': ' || case when t.nl then case when t.n = 1 then 'kraam afgesloten' else t.n || ' kramen afgesloten' end
                                                          else case when t.n = 1 then 'stall closed' else t.n || ' stalls closed' end end
           when 'mcr_voorraad' then t.markt || ': ' || case when t.nl then 'voorraad nodig' else 'stock needed' end
           when 'mcr_morgen' then case when t.nl then case when t.n = 1 then 'Morgen: je dienst' else 'Morgen: ' || t.n || ' diensten' end
                                       else case when t.n = 1 then 'Tomorrow: your shift' else 'Tomorrow: ' || t.n || ' shifts' end end
           when 'mcr_niet_in' then case when t.nl then case when t.n = 1 then split_part(t.regels, ' ', 1) || ' is nog niet ingeklokt' else t.n || ' mensen zijn nog niet ingeklokt' end
                                        else case when t.n = 1 then split_part(t.regels, ' ', 1) || ' isn''t clocked in yet' else t.n || ' people aren''t clocked in yet' end end
           when 'mcr_nog_in' then case when t.nl then 'Je bent nog ingeklokt' else 'You''re still clocked in' end
           when 'nl_ziek' then case when t.nl then case when t.n = 1 then 'Ziekmelding' else t.n || ' ziekmeldingen' end
                                    else case when t.n = 1 then 'Sick report' else t.n || ' sick reports' end end
           when 'nl_crm_optie' then case when t.nl then case when t.n = 1 then 'Optie loopt af' else t.n || ' opties lopen af' end
                                         else case when t.n = 1 then 'Option expiring' else t.n || ' options expiring' end end
           else 'TC Group' end,
         case t.soort
           when 'mcr_eraf' then case when t.nl then 'Je staat niet meer ingeroosterd voor: ' else 'You''re off the rota for: ' end || replace(t.regels, E'\n', '; ')
           when 'mcr_ruil_ok' then t.regels || E'\n' || case when t.nl then 'Je blijft ingeroosterd tot iemand het overneemt.' else 'You stay on the rota until someone takes over.' end
           when 'mcr_ruil_nee' then t.regels || E'\n' || case when t.nl then 'Je staat nog steeds ingeroosterd voor deze dienst.' else 'You''re still on the rota for this shift.' end
           when 'mcr_ruil_open' then t.regels || E'\n' || case when t.nl then 'Tik om hem aan te vragen.' else 'Tap to ask for it.' end
           when 'mcr_ruil_gevraagd' then t.regels || E'\n' || case when t.nl then 'Keur goed of af bij ' || t.markt || ' → Shifts.' else 'Approve or reject it under ' || t.markt || ' → Shifts.' end
           when 'mcr_agenda_manager' then t.regels || E'\n' || case when t.nl then 'Bekijk het bij ' || t.markt || ' → Agenda.' else 'See it under ' || t.markt || ' → Calendar.' end
           when 'mcr_dag_open' then case when t.nl then t.regels || ' is nog niet afgesloten. Loop Dag afsluiten door voordat je weggaat.'
                                         else t.regels || ' isn''t closed yet. Go through Close day before you leave.' end
           when 'mcr_dag_open_b' then t.regels || case when t.nl then ' is nog niet afgesloten.' else ' isn''t closed yet.' end
           when 'mcr_voorraad' then t.regels
           when 'mcr_morgen' then t.regels || E'\n' || case when t.nl then 'Wees er 10 minuten van tevoren. Tik voor de details.' else 'Be there 10 minutes early. Tap for the details.' end
           when 'mcr_niet_in' then t.regels || E'\n' || case when t.nl then 'Tik om te bellen of in te klokken.' else 'Tap to call them or clock them in.' end
           when 'mcr_nog_in' then case when t.nl then 'Vergeet niet uit te klokken.' else 'Don''t forget to clock out.' end || E'\n' || t.regels
           else t.regels end,
         case when t.soort in ('mcr_erop','mcr_morgen') and t.n = 1 and t.sid is not null then 'mcr-shift:' || t.sid::text
              when t.soort = 'mcr_ruil_open' then 'mcr-open'
              when t.soort = 'mcr_ruil_gevraagd' then 'mcr-beheer'
              when t.soort = 'mcr_agenda_manager' then 'mcr-agenda'
              when t.soort = 'mcr_dag_open' then 'mcr-close'
              when t.soort in ('mcr_dag_open_b','mcr_dag_dicht','mcr_voorraad') then 'mcr-afsluiting'
              when t.soort = 'mcr_niet_in' then 'mcr-today'
              when t.soort = 'mcr_nog_in' then 'mcr-clock'
              when t.soort = 'nl_ziek' then 'nl-ziek'
              when t.soort = 'nl_crm_optie' then 'nl-crm'
              else 'mcr-shifts' end
    from t;
end $function$;
