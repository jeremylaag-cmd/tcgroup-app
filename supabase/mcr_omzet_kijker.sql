-- Manchester: Patrick mag de omzet per dag zien, verder niets (7 nov 2026)
--
-- Bram: "kun jij nu het account van patrick@tc ook toegang geven tot de
-- manchester kant van de app. hij moet alleen zien wat de omzetten per dag
-- zijn. dus het tabblad wat net gemaakt is."
--
-- Patrick krijgt GEEN "alle vestigingen" (dan zou hij heel Manchester zien:
-- mensen, tarieven, uren). In plaats daarvan:
-- * gebruikers.mag_mcr_omzet: los recht "Manchester-omzet bekijken".
--   Alleen Bram kan het aan- of uitzetten (trigger mcr_omzet_recht_bewaken);
--   vanuit de SQL-editor (geen inlog) kan het ook.
-- * mag_mcr_omzet(): Bram (mag_omzet_zien) of een goedgekeurde beheerder met
--   dat recht.
-- * mcr_omzet_kramen() en mcr_omzet_dagen(van, tot): alleen kraam, kleur,
--   seizoen, datum, dicht, pin, contant en totaal. Geen forecast, uren, loon,
--   transacties of terminals. Eigenaar postgres, dus ze lezen langs de regels
--   uit mcr_omzet_alleen_bram.sql heen, maar geven alleen iets terug als
--   mag_mcr_omzet() waar is.
-- * Patrick (patrick@tcgroup.nl) krijgt het recht.
--
-- Let op: geen enkele regel in dit bestand gebruikt het woord voor weghalen.

alter table public.gebruikers add column if not exists mag_mcr_omzet boolean not null default false;

create or replace function public.mcr_omzet_recht_bewaken()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if (tg_op = 'INSERT' and new.mag_mcr_omzet)
     or (tg_op = 'UPDATE' and new.mag_mcr_omzet is distinct from old.mag_mcr_omzet) then
    if public.huidige_gebruiker() is not null and not public.mag_omzet_zien() then
      raise exception 'Alleen Bram kan toegang tot de Manchester-omzet geven.' using errcode = 'P0002';
    end if;
  end if;
  return new;
end $$;

create trigger zz_mcr_omzet_recht before insert or update on public.gebruikers
  for each row execute function public.mcr_omzet_recht_bewaken();

create or replace function public.mag_mcr_omzet()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.mag_omzet_zien()
      or exists (select 1 from public.gebruikers g
                  where g.id = public.huidige_gebruiker() and g.mag_mcr_omzet
                    and g.rol = 'beheerder' and coalesce(g.goedgekeurd,false) and g.gearchiveerd_op is null)
$$;

create or replace function public.mcr_omzet_kramen()
returns table(id uuid, naam text, kleur text, seizoen_start date, seizoen_eind date)
language sql stable security definer set search_path to 'public'
as $$
  select k.id, k.naam, coalesce(k.kleur,'#6B6A66'), k.seizoen_start, k.seizoen_eind
    from public.kramen k
   where k.actief and k.vestiging = 'MCR' and public.mag_mcr_omzet()
   order by k.naam
$$;

create or replace function public.mcr_omzet_dagen(p_van date default null, p_tot date default null)
returns table(kraam_id uuid, kraam text, kleur text, datum date, dicht boolean,
              omzet_pin numeric, omzet_contant numeric, omzet_totaal numeric)
language sql stable security definer set search_path to 'public'
as $$
  select k.id, k.naam, coalesce(k.kleur,'#6B6A66'), d::date,
         coalesce(u.dicht,false),
         coalesce(p.omzet,0), r.omzet_contant, coalesce(p.omzet,0) + coalesce(r.omzet_contant,0)
    from public.kramen k
    cross join lateral generate_series(
      greatest(k.seizoen_start, coalesce(p_van, k.seizoen_start)),
      least(k.seizoen_eind,  coalesce(p_tot, k.seizoen_eind)), interval '1 day') d
    left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d::date
    left join public.dagrapporten r on r.kraam_id = k.id and r.datum = d::date
    left join lateral (select sum(pd.omzet) omzet from public.pin_dag pd
                        where pd.kraam_id = k.id and pd.datum = d::date) p on true
   where k.actief and k.vestiging = 'MCR' and public.mag_mcr_omzet()
   order by d, k.naam
$$;

revoke all on function public.mag_mcr_omzet() from public, anon;
revoke all on function public.mcr_omzet_kramen() from public, anon;
revoke all on function public.mcr_omzet_dagen(date,date) from public, anon;
grant execute on function public.mag_mcr_omzet() to authenticated, service_role;
grant execute on function public.mcr_omzet_kramen() to authenticated, service_role;
grant execute on function public.mcr_omzet_dagen(date,date) to authenticated, service_role;

update public.gebruikers set mag_mcr_omzet = true where lower(email) = 'patrick@tcgroup.nl';
