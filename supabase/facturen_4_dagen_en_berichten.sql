-- 1) Facturen pas maken vanaf 4 dagen voor de uitbetaaldatum
--    (en nooit voordat de periode voorbij is). Een factuur die al bestaat,
--    kan altijd opnieuw worden gedownload.
select public._fn_vervang('public.mcr_betaalrondes()'::regprocedure,
  '(b.periode_tot < (now() at time zone public.mijn_tijdzone())::date)',
  '(greatest(b.periode_tot + 1, b.betaaldatum - 4) <= (now() at time zone public.mijn_tijdzone())::date)');

select public._fn_vervang('public.mcr_factuur_maken(uuid)'::regprocedure,
$o$    raise exception 'This period is not finished yet.' using errcode='P0002';
  end if;$o$,
$n$    raise exception 'This period is not finished yet.' using errcode='P0002';
  end if;
  if greatest(v_b.periode_tot + 1, v_b.betaaldatum - 4) > (now() at time zone public.mijn_tijdzone())::date
     and not exists (select 1 from public.facturen f0 where f0.gebruiker_id = v_uid and f0.ronde_id = p_ronde) then
    raise exception 'Your invoice will be ready on %.',
      to_char(greatest(v_b.periode_tot + 1, v_b.betaaldatum - 4), 'FMDD FMMonth') using errcode='P0002';
  end if;$n$);


-- 2) Algemene berichten van de beheerder aan iedereen in een of meer markten.
--    Elk bericht moet echt gelezen worden: het blijft in beeld tot de ontvanger
--    op "Gelezen" tikt, en de beheerder ziet wie het gelezen heeft.
create table if not exists public.berichten (
  id             uuid primary key default gen_random_uuid(),
  titel_nl       text,
  tekst_nl       text,
  titel_en       text,
  tekst_en       text,
  vestigingen    text[] not null,
  verstuurd_door uuid references public.gebruikers(id) on delete set null,
  verstuurd_op   timestamptz not null default now(),
  ingetrokken_op timestamptz
);
create table if not exists public.bericht_ontvangers (
  bericht_id   uuid not null references public.berichten(id) on delete cascade,
  gebruiker_id uuid not null references public.gebruikers(id) on delete cascade,
  gelezen_op   timestamptz,
  primary key (bericht_id, gebruiker_id)
);
create index if not exists bericht_ontvangers_gebruiker on public.bericht_ontvangers (gebruiker_id) where gelezen_op is null;
alter table public.berichten enable row level security;
alter table public.bericht_ontvangers enable row level security;
-- Geen policies: alles loopt via de functies hieronder.

-- Versturen (alleen beheerder). Ontvangers: goedgekeurde, niet-gearchiveerde
-- mensen van die markten (ook wie er tijdelijk een tweede markt heeft).
create or replace function public.bericht_versturen(p_titel_nl text, p_tekst_nl text,
                                                    p_titel_en text, p_tekst_en text, p_vestigingen text[])
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; n int;
begin
  if not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan een bericht sturen.' using errcode='P0002';
  end if;
  p_titel_nl := nullif(btrim(p_titel_nl),''); p_tekst_nl := nullif(btrim(p_tekst_nl),'');
  p_titel_en := nullif(btrim(p_titel_en),''); p_tekst_en := nullif(btrim(p_tekst_en),'');
  if (p_titel_nl is null or p_tekst_nl is null) and (p_titel_en is null or p_tekst_en is null) then
    raise exception 'Vul een titel en een tekst in (Nederlands, Engels of allebei).' using errcode='P0002';
  end if;
  if (p_titel_nl is null) <> (p_tekst_nl is null) or (p_titel_en is null) <> (p_tekst_en is null) then
    raise exception 'Vul per taal zowel de titel als de tekst in.' using errcode='P0002';
  end if;
  if coalesce(array_length(p_vestigingen,1),0) = 0 then
    raise exception 'Kies minstens één markt.' using errcode='P0002';
  end if;

  insert into public.berichten (titel_nl, tekst_nl, titel_en, tekst_en, vestigingen, verstuurd_door)
  values (p_titel_nl, p_tekst_nl, p_titel_en, p_tekst_en, p_vestigingen, public.huidige_gebruiker())
  returning id into v_id;

  insert into public.bericht_ontvangers (bericht_id, gebruiker_id)
  select v_id, g.id from public.gebruikers g
   where g.gearchiveerd_op is null and coalesce(g.goedgekeurd,false)
     and g.id <> public.huidige_gebruiker()
     and (g.vestiging = any(p_vestigingen)
          or g.plant_vestiging = any(p_vestigingen)
          or (g.tweede_vestiging = any(p_vestigingen) and coalesce(g.tweede_tot, current_date) >= current_date));
  get diagnostics n = row_count;

  -- Pushmelding, met de titel in de taal van de ontvanger
  insert into public.push_wachtrij (gebruiker_id, soort, regel)
  select o.gebruiker_id, 'bericht',
         case when coalesce(g.taal, v.taal, 'en') = 'nl' then coalesce(p_titel_nl, p_titel_en)
              else coalesce(p_titel_en, p_titel_nl) end
    from public.bericht_ontvangers o
    join public.gebruikers g on g.id = o.gebruiker_id
    left join public.vestigingen v on v.code = g.vestiging
   where o.bericht_id = v_id and g.push_token is not null;
  return n;
end $$;

-- Ongelezen berichten voor wie ingelogd is, in de eigen taal (anders de andere)
create or replace function public.mijn_berichten()
returns table(id uuid, titel text, tekst text, verstuurd_op timestamptz, van text)
language sql stable security definer set search_path to 'public' as $$
  select b.id,
         case when t.nl then coalesce(b.titel_nl, b.titel_en) else coalesce(b.titel_en, b.titel_nl) end,
         case when t.nl then coalesce(b.tekst_nl, b.tekst_en) else coalesce(b.tekst_en, b.tekst_nl) end,
         b.verstuurd_op, (select a.naam from public.gebruikers a where a.id = b.verstuurd_door)
    from public.bericht_ontvangers o
    join public.berichten b on b.id = o.bericht_id and b.ingetrokken_op is null
    cross join lateral (select coalesce(g.taal, v.taal, 'en') = 'nl' as nl
                          from public.gebruikers g left join public.vestigingen v on v.code = g.vestiging
                         where g.id = o.gebruiker_id) t
   where o.gebruiker_id = public.huidige_gebruiker() and o.gelezen_op is null
   order by b.verstuurd_op
$$;

create or replace function public.bericht_gelezen(p_bericht uuid)
returns void language sql security definer set search_path to 'public' as $$
  update public.bericht_ontvangers set gelezen_op = now()
   where bericht_id = p_bericht and gebruiker_id = public.huidige_gebruiker() and gelezen_op is null
$$;

-- Overzicht voor de beheerder
create or replace function public.berichten_overzicht()
returns table(id uuid, titel_nl text, tekst_nl text, titel_en text, tekst_en text, vestigingen text[],
              verstuurd_op timestamptz, van text, ontvangers int, gelezen int, ingetrokken_op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select b.id, b.titel_nl, b.tekst_nl, b.titel_en, b.tekst_en, b.vestigingen, b.verstuurd_op,
         (select a.naam from public.gebruikers a where a.id = b.verstuurd_door),
         (select count(*)::int from public.bericht_ontvangers o where o.bericht_id = b.id),
         (select count(*)::int from public.bericht_ontvangers o where o.bericht_id = b.id and o.gelezen_op is not null),
         b.ingetrokken_op
    from public.berichten b
   where public.is_beheerder()
   order by b.verstuurd_op desc
$$;

create or replace function public.bericht_lezers(p_bericht uuid)
returns table(naam text, vestiging text, gelezen_op timestamptz)
language sql stable security definer set search_path to 'public' as $$
  select g.naam, g.vestiging, o.gelezen_op
    from public.bericht_ontvangers o join public.gebruikers g on g.id = o.gebruiker_id
   where o.bericht_id = p_bericht and public.is_beheerder()
   order by o.gelezen_op nulls first, g.naam
$$;

create or replace function public.bericht_intrekken(p_bericht uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_beheerder() then
    raise exception 'Alleen een beheerder kan een bericht intrekken.' using errcode='P0002';
  end if;
  update public.berichten set ingetrokken_op = now() where id = p_bericht and ingetrokken_op is null;
  update public.push_wachtrij w set verwerkt_op = now(), uitslag = 'vervallen'
   where w.soort = 'bericht' and w.verwerkt_op is null
     and w.gebruiker_id in (select o.gebruiker_id from public.bericht_ontvangers o
                             where o.bericht_id = p_bericht and o.gelezen_op is null);
end $$;

revoke all on function public.bericht_versturen(text,text,text,text,text[]) from public, anon;
revoke all on function public.mijn_berichten() from public, anon;
revoke all on function public.bericht_gelezen(uuid) from public, anon;
revoke all on function public.berichten_overzicht() from public, anon;
revoke all on function public.bericht_lezers(uuid) from public, anon;
revoke all on function public.bericht_intrekken(uuid) from public, anon;
grant execute on function public.bericht_versturen(text,text,text,text,text[]) to authenticated;
grant execute on function public.mijn_berichten() to authenticated;
grant execute on function public.bericht_gelezen(uuid) to authenticated;
grant execute on function public.berichten_overzicht() to authenticated;
grant execute on function public.bericht_lezers(uuid) to authenticated;
grant execute on function public.bericht_intrekken(uuid) to authenticated;

-- Pushmelding: titel en tekst voor soort 'bericht'
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$           else 'TC Group' end,$o$,
  $n$           when 'bericht' then case when t.n = 1 then t.regels
                                    when t.nl then t.n || ' nieuwe berichten' else t.n || ' new messages' end
           else 'TC Group' end,$n$);
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$           else t.regels end,$o$,
  $n$           when 'bericht' then case when t.nl then 'Je hebt een nieuw bericht. Open de app om het te lezen.'
                                    else 'You have a new message. Open the app to read it.' end
           else t.regels end,$n$);
select public._fn_vervang('public.push_wachtrij_bundels()'::regprocedure,
  $o$              else 'mcr-shifts' end$o$,
  $n$              when t.soort = 'bericht' then 'bericht'
              else 'mcr-shifts' end$n$);
