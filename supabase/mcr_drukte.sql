-- Manchester: drukte per uur — betalingen per uur en advies erbij/eraf (10 nov 2026)
--
-- Bram: "kunnen we ook kijken met het schema als we zien hoeveel transacties
-- er per uur worden gedaan en dat je dan kan adviseren wanneer er iemand bij
-- moet of af". Gekozen: in het planbord per kraam per uur de verwachte drukte
-- + advies, en op Overzicht vandaag live per uur de betalingen per kraam met
-- een seintje als een kraam nu te druk is. Overal BETALINGEN PER UUR (aantal
-- pinbetalingen uit myPOS, pin_uur) en het aantal mensen als los getal; geen
-- "per persoon"-getallen in beeld. Het advies gebruikt intern wel een
-- verhouding.
--
-- * Vier instellingen in vestiging_instellingen (MCR), alleen als ze er nog
--   niet zijn: drukte_per_persoon (30), drukte_erbij (35), drukte_af (15),
--   min_bezetting (2).
-- * mcr_drukte_advies(verwacht, mensen, ...): de rekenregel, los zodat de app
--   precies hetzelfde kan doen (planbord rekent zelf na indelen/weghalen).
-- * mcr_drukte(p_van, p_tot) → jsonb, per kraam per dag per uur: echt,
--   verwacht (+ basis), gepland, geklokt, advies en achteraf. Alleen Bram
--   (mag_kraambeheer() én mag_omzet_zien(): betalingen horen bij de omzet,
--   die alleen Bram mag zien). Hooguit 62 dagen.
--
-- Bijgesteld na Brams reactie (10 nov):
-- * "Er zijn altijd bakkers aan, dus soms staan er 0 mensen als het rustig
--   is." min_bezetting standaard 0. De bakkers vangen tot "erbij" betalingen
--   per uur op als er niemand aan de kassa staat: capaciteit =
--   max(mensen,1) × erbij. +n zolang verwacht boven de capaciteit zit
--   (n = betalingen / per_persoon naar boven − mensen, minstens 1); −1 alleen
--   als er meer dan min_bezetting staan en verwacht < mensen × af.
-- * "neem als referentie de omzetten van vorig jaar en dan de afgelopen
--   dagen": verwacht = pin-omzet vorig jaar (zelfde weekdag, datum − 364,
--   mcr_omzet_historie) ÷ gemiddelde bon (afgelopen 14 dagen) × groei
--   (afgelopen 7 dagen tegen dezelfde dagen vorig jaar, tussen 0,5 en 2),
--   verdeeld over de uren zoals de afgelopen dagen van die kraam. Geen
--   cijfer van vorig jaar: gemiddelde van dezelfde weekdag (zoals eerst).
--   Eigenaar postgres (zoals mcr_omzet_dagen): met app_rpc als eigenaar
--   liepen de regels op pin_uur/urenregistraties per rij mee en duurde een
--   week ~330 ms, nu ~50 ms. De functie controleert zelf wie het mag en
--   leest alleen kramen van de actieve vestiging.
--
-- Let op: geen enkele regel in dit bestand gebruikt het woord voor weghalen.

-- ── 1. Instellingen ───────────────────────────────────────────────────────
insert into public.vestiging_instellingen (vestiging, sleutel, waarde, omschrijving)
select 'MCR', x.sleutel, x.waarde, x.omschrijving
  from (values
    ('drukte_per_persoon', '30', 'Betalingen per uur die één persoon goed aankan (voor het aantal mensen dat nodig is)'),
    ('drukte_erbij',       '35', 'Komen er per persoon meer betalingen per uur dan dit, dan advies: iemand erbij'),
    ('drukte_af',          '15', 'Komen er per persoon minder betalingen per uur dan dit, dan advies: er kan iemand af'),
    ('min_bezetting',      '0',  'Minimaal aantal mensen aan de kassa (bakkers niet meegeteld), het advies gaat hier nooit onder')
  ) as x(sleutel, waarde, omschrijving)
 where exists (select 1 from public.vestigingen v where v.code = 'MCR')
   and not exists (select 1 from public.vestiging_instellingen i
                    where i.vestiging = 'MCR' and i.sleutel = x.sleutel);
-- Stond de eerste versie (min_bezetting 2) er al, dan naar 0: de bakkers staan er altijd.
update public.vestiging_instellingen
   set waarde = '0', omschrijving = 'Minimaal aantal mensen aan de kassa (bakkers niet meegeteld), het advies gaat hier nooit onder'
 where vestiging = 'MCR' and sleutel = 'min_bezetting' and waarde = '2'
   and omschrijving like 'Minimaal aantal mensen in een open kraam%';

-- ── 2. De rekenregel ──────────────────────────────────────────────────────
-- De bakkers staan er altijd: met niemand aan de kassa vangen zij tot "erbij"
-- betalingen per uur op. Capaciteit = max(mensen,1) × erbij.
-- +n zolang verwacht boven de capaciteit zit: n = verwacht / per_persoon naar
-- boven − mensen, minstens 1. −1 alleen als er meer dan min_bezetting staan
-- en verwacht < mensen × af (bij 1 persoon: < af, dan nemen de bakkers het over).
create or replace function public.mcr_drukte_advies(p_verwacht numeric, p_mensen integer,
                                                     p_per_persoon numeric, p_erbij numeric,
                                                     p_af numeric, p_min integer)
returns integer
language sql immutable set search_path to 'public'
as $function$
  select case
    when p_verwacht is null or p_mensen is null then 0
    when p_verwacht > greatest(p_mensen,1) * p_erbij then
      greatest(1, ceil(p_verwacht / nullif(p_per_persoon,0))::int - p_mensen)
    when p_mensen > coalesce(p_min,0) and p_verwacht < p_mensen * p_af then -1
    else 0
  end
$function$;

-- ── 3. Drukte per kraam per dag per uur ───────────────────────────────────
-- Uren: binnen de openingstijd van die dag (afwijkende dag telt), plus het
-- uur ervoor als er toen al betalingen waren (dan zonder advies).
-- echt     = betalingen in dat uur; null als het nog moet komen of als er die
--            (afgelopen) dag geen pindata is.
-- verwacht = pin vorig jaar ÷ gemiddelde bon × groei, verdeeld over de uren
--            (zie boven); zonder cijfer van vorig jaar het gemiddelde van
--            dezelfde weekdag (max 4), anders zelfde soort dag, anders de
--            laatste 7 dagen met data.
--            basis = {soort: vorig_jaar|weekdag|dagtype|alles|geen, dagen,
--            data, en bij vorig_jaar: vj_datum, vj_pin, bon, factor,
--            factor_dagen, dagtotaal, verdeling {soort, dagen, data}}.
-- gepland  = mensen ingedeeld voor minstens 30 minuten van dat uur
--            (eind leeg = sluiting + opruimtijd).
-- geklokt  = mensen ingeklokt voor minstens 30 minuten van dat uur; in het
--            lopende uur ook wie nu binnen is. Alleen verleden/nu.
-- advies   = rekenregel op verwacht en gepland (alleen binnen openingstijd).
-- achteraf = rekenregel op echt en geklokt, voor uren die al voorbij zijn.
create or replace function public.mcr_drukte(p_van date, p_tot date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v jsonb; v_vest text; v_nu timestamp; v_vandaag date; v_nu_uur int;
        v_pp numeric; v_erbij numeric; v_af numeric; v_min int;
begin
  if not (public.mag_kraambeheer() and public.mag_omzet_zien()) then
    raise exception 'Alleen Bram kan de drukte per uur zien.' using errcode='P0002';
  end if;
  if p_van is null or p_tot is null or p_tot < p_van then
    raise exception 'Kies een begin- en einddatum.' using errcode='P0002';
  end if;
  if p_tot - p_van > 62 then raise exception 'Kies hooguit twee maanden.' using errcode='P0002'; end if;
  v_vest := coalesce(public.actieve_vestiging(), 'MCR');
  v_nu := now() at time zone 'Europe/London';
  v_vandaag := v_nu::date;
  v_nu_uur := extract(hour from v_nu)::int;
  select coalesce(max(case when i.sleutel='drukte_per_persoon' then nullif(replace(i.waarde,',','.'),'')::numeric end), 30),
         coalesce(max(case when i.sleutel='drukte_erbij'       then nullif(replace(i.waarde,',','.'),'')::numeric end), 35),
         coalesce(max(case when i.sleutel='drukte_af'          then nullif(replace(i.waarde,',','.'),'')::numeric end), 15),
         coalesce(max(case when i.sleutel='min_bezetting'      then nullif(replace(i.waarde,',','.'),'')::numeric end), 0)::int
    into v_pp, v_erbij, v_af, v_min
    from public.vestiging_instellingen i
   where i.vestiging = v_vest and i.sleutel in ('drukte_per_persoon','drukte_erbij','drukte_af','min_bezetting');
  if v_pp <= 0 then v_pp := 30; end if;

  with k as (
    select k.* from public.kramen k
     where k.actief and public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging)
  ), dag as (
    select k.id kid, d::date datum,
           coalesce(u.dicht,false) or d::date < k.seizoen_start or d::date > k.seizoen_eind dicht,
           coalesce(u.open_van, k.open_van) open_van, coalesce(u.open_tot, k.open_tot) open_tot,
           (extract(epoch from coalesce(public.kraam_eindtijd(k.id, d::date), '23:59'::time))/60)::int eind_min
      from k cross join generate_series(p_van, p_tot, interval '1 day') d
      left join public.kraam_uitzonderingen u on u.kraam_id = k.id and u.datum = d::date
  ), uurdata as (
    -- Betalingen per kraam per dag per uur: de gevraagde dagen plus genoeg
    -- geschiedenis voor de verwachting.
    select pd.kraam_id kid, pu.datum, pu.uur, sum(pu.transacties)::int tr
      from public.pin_uur pu
      join public.pin_dag pd on pd.vestiging = pu.vestiging and pd.tid = pu.tid and pd.datum = pu.datum
     where pu.vestiging = v_vest
       and pu.datum between p_van - 70 and least(p_tot, v_vandaag)
       and pd.kraam_id in (select id from k)
     group by pd.kraam_id, pu.datum, pu.uur
  ), metdata as (
    select distinct kid, datum from uurdata
  ), hdag as (
    -- Afgelopen dagen met betalingen (vandaag loopt nog en telt niet mee).
    select kid, datum, extract(dow from datum)::int wd from uurdata
     where datum < v_vandaag group by kid, datum having sum(tr) > 0
  ), oud as (
    -- Terugval zonder cijfer van vorig jaar: gemiddelde van dezelfde weekdag
    -- (max 4), anders zelfde soort dag (ma–do / vr / za / zo), anders de
    -- laatste 7 dagen met data.
    select d.kid, d.datum,
           coalesce(w.arr, t.arr, a.arr, '{}'::date[]) dagen,
           case when w.arr is not null then 'weekdag' when t.arr is not null then 'dagtype'
                when a.arr is not null then 'alles' else 'geen' end soort
      from dag d
      left join lateral (select array_agg(x.datum order by x.datum) arr from (
          select h.datum from hdag h where h.kid = d.kid and h.datum < least(d.datum, v_vandaag)
             and h.wd = extract(dow from d.datum)::int
           order by h.datum desc limit 4) x having count(*) > 0) w on true
      left join lateral (select array_agg(x.datum order by x.datum) arr from (
          select h.datum from hdag h where h.kid = d.kid and h.datum < least(d.datum, v_vandaag)
             and (case when h.wd between 1 and 4 then 1 else h.wd end)
               = (case when extract(dow from d.datum)::int between 1 and 4 then 1 else extract(dow from d.datum)::int end)
           order by h.datum desc limit 4) x having count(*) > 0) t on true
      left join lateral (select array_agg(x.datum order by x.datum) arr from (
          select h.datum from hdag h where h.kid = d.kid and h.datum < least(d.datum, v_vandaag)
           order by h.datum desc limit 7) x having count(*) > 0) a on true
     where not d.dicht
  ), pdag as (
    -- Pin per kraam per afgelopen dag (omzet en aantal betalingen).
    select pd.kraam_id kid, pd.datum, sum(pd.omzet) omzet, sum(pd.transacties) tr
      from public.pin_dag pd
     where pd.vestiging = v_vest and pd.datum between p_van - 70 and least(p_tot, v_vandaag)
       and pd.kraam_id in (select id from k)
     group by pd.kraam_id, pd.datum having sum(pd.transacties) > 0
  ), vj as (
    -- Vorig jaar: zelfde weekdag (datum − 364), zelfde kraam (of op naam).
    select d.kid, d.datum, d.datum - 364 vj_datum,
           (select sum(h.pin) from public.mcr_omzet_historie h
             where h.datum = d.datum - 364
               and (h.kraam_id = d.kid or (h.kraam_id is null and lower(h.kraam_naam) = lower(kk.naam)))) vj_pin,
           b.bon, f.nu_pin, f.toen_pin, f.n factor_dagen,
           coalesce(v1.arr, v2.arr, '{}'::date[]) vdagen,
           case when v1.arr is not null then 'dagtype' when v2.arr is not null then 'alles' end vsoort
      from dag d
      join k kk on kk.id = d.kid
      -- gemiddelde bon: afgelopen 14 dagen met data
      left join lateral (select sum(x.omzet) / nullif(sum(x.tr),0) bon from (
          select p.omzet, p.tr from pdag p where p.kid = d.kid and p.datum < least(d.datum, v_vandaag)
           order by p.datum desc limit 14) x) b on true
      -- groei: afgelopen 7 dagen met data tegen dezelfde dagen vorig jaar
      left join lateral (select sum(x.omzet) nu_pin, sum(x.vj) toen_pin, count(*) n from (
          select p.omzet, (select sum(h.pin) from public.mcr_omzet_historie h
                            where h.datum = p.datum - 364
                              and (h.kraam_id = d.kid or (h.kraam_id is null and lower(h.kraam_naam) = lower(kk.naam)))) vj
            from pdag p where p.kid = d.kid and p.datum < least(d.datum, v_vandaag)
           order by p.datum desc limit 7) x where x.vj > 0) f on true
      -- verdeling over de uren: zelfde soort dag in de laatste 4 weken, anders de laatste 14 dagen
      left join lateral (select array_agg(h.datum order by h.datum) arr from hdag h
          where h.kid = d.kid and h.datum < least(d.datum, v_vandaag) and h.datum >= least(d.datum, v_vandaag) - 28
            and (case when h.wd between 1 and 4 then 1 else h.wd end)
              = (case when extract(dow from d.datum)::int between 1 and 4 then 1 else extract(dow from d.datum)::int end)
          having count(*) > 0) v1 on true
      left join lateral (select array_agg(h.datum order by h.datum) arr from hdag h
          where h.kid = d.kid and h.datum < least(d.datum, v_vandaag) and h.datum >= least(d.datum, v_vandaag) - 14
          having count(*) > 0) v2 on true
     where not d.dicht
  ), basis as (
    select o.kid, o.datum, o.dagen, o.soort,
           v.vj_datum, v.vj_pin, v.bon, v.factor_dagen, v.vdagen, v.vsoort,
           case when coalesce(v.factor_dagen,0) >= 2 and v.toen_pin > 0
                then least(2, greatest(0.5, v.nu_pin / v.toen_pin)) else 1 end factor,
           (v.vj_pin > 0 and v.bon > 0 and cardinality(v.vdagen) > 0) met_vj
      from oud o join vj v on v.kid = o.kid and v.datum = o.datum
  ), verdeling as (
    -- aandeel per uur in de verdeeldagen (alle uren samen = 1)
    select b.kid, b.datum, x.uur, sum(x.tr)::numeric / nullif(sum(sum(x.tr)) over (partition by b.kid, b.datum),0) aandeel
      from basis b join uurdata x on x.kid = b.kid and x.datum = any(b.vdagen)
     where b.met_vj
     group by b.kid, b.datum, x.uur
  ), uren as (
    select d.kid, d.datum, h.uur,
           h.uur < extract(hour from d.open_van)::int buiten
      from dag d
      cross join lateral generate_series(
        extract(hour from d.open_van)::int - 1,
        case when d.open_tot <= d.open_van then 23
             else extract(hour from (d.open_tot - interval '1 minute'))::int end) h(uur)
     where not d.dicht and h.uur >= 0
  ), echt as (
    select u.kid, u.datum, u.uur,
           case when u.datum > v_vandaag then null
                when u.datum = v_vandaag then case when u.uur <= v_nu_uur then coalesce(x.tr,0) end
                when md.kid is not null then coalesce(x.tr,0)
           end echt
      from uren u left join uurdata x on x.kid = u.kid and x.datum = u.datum and x.uur = u.uur
      left join metdata md on md.kid = u.kid and md.datum = u.datum
  ), verw as (
    select u.kid, u.datum, u.uur,
           case when b.met_vj then
                  round(b.vj_pin / b.bon * b.factor * coalesce((select vd.aandeel from verdeling vd
                          where vd.kid = u.kid and vd.datum = u.datum and vd.uur = u.uur),0))::int
                when cardinality(b.dagen) > 0 then
                  round(coalesce(sum(x.tr),0)::numeric / cardinality(b.dagen))::int end verwacht
      from uren u
      join basis b on b.kid = u.kid and b.datum = u.datum
      left join uurdata x on not b.met_vj and x.kid = u.kid and x.uur = u.uur and x.datum = any(b.dagen)
     group by u.kid, u.datum, u.uur, b.met_vj, b.vj_pin, b.bon, b.factor, b.dagen
  ), plan as (
    select kl.kraam_id kid, kl.datum, kg.gebruiker_id,
           (extract(epoch from s.start_tijd)/60)::int st,
           coalesce((extract(epoch from s.eind_tijd)/60)::int, d.eind_min) et
      from public.klussen kl
      join dag d on d.kid = kl.kraam_id and d.datum = kl.datum
      join public.klus_shifts s on s.klus_id = kl.id
      join public.klus_gebruikers kg on kg.shift_id = s.id
     where kl.kraam_id in (select id from k) and kl.datum between p_van and p_tot and s.start_tijd is not null
  ), gepl as (
    select u.kid, u.datum, u.uur, count(distinct p.gebruiker_id)::int gepland
      from uren u
      left join plan p on p.kid = u.kid and p.datum = u.datum
                      and least(p.et, (u.uur+1)*60) - greatest(p.st, u.uur*60) >= 30
     group by u.kid, u.datum, u.uur
  ), klok as (
    select kl.kraam_id kid, kl.datum, ur.gebruiker_id, ur.ingeklokt_op inn,
           coalesce(ur.uitgeklokt_op, now()) uit, ur.uitgeklokt_op is null and ur.status = 'lopend' binnen
      from public.klussen kl
      join public.urenregistraties ur on ur.klus_id = kl.id
     where kl.kraam_id in (select id from k) and kl.datum between p_van and least(p_tot, v_vandaag)
       and ur.ingeklokt_op is not null
  ), gekl as (
    select u.kid, u.datum, u.uur,
           case when u.datum > v_vandaag or (u.datum = v_vandaag and u.uur > v_nu_uur) then null
                else count(distinct c.gebruiker_id)::int end geklokt
      from uren u
      left join klok c on c.kid = u.kid and c.datum = u.datum
             and ( extract(epoch from (least(c.uit, (u.datum + make_time(u.uur,0,0) + interval '1 hour') at time zone 'Europe/London')
                                      - greatest(c.inn, (u.datum + make_time(u.uur,0,0)) at time zone 'Europe/London')))/60 >= 30
                or (u.datum = v_vandaag and u.uur = v_nu_uur and c.binnen))
     group by u.kid, u.datum, u.uur
  ), rij as (
    select u.kid, u.datum, u.uur, u.buiten, e.echt, vw.verwacht, g.gepland, gk.geklokt,
           case when u.buiten then 0
                else public.mcr_drukte_advies(vw.verwacht, g.gepland, v_pp, v_erbij, v_af, v_min) end advies,
           case when u.buiten or e.echt is null or gk.geklokt is null
                     or (u.datum = v_vandaag and u.uur >= v_nu_uur) then null
                else public.mcr_drukte_advies(e.echt, gk.geklokt, v_pp, v_erbij, v_af, v_min) end achteraf
      from uren u
      join echt e on e.kid = u.kid and e.datum = u.datum and e.uur = u.uur
      left join verw vw on vw.kid = u.kid and vw.datum = u.datum and vw.uur = u.uur
      join gepl g on g.kid = u.kid and g.datum = u.datum and g.uur = u.uur
      join gekl gk on gk.kid = u.kid and gk.datum = u.datum and gk.uur = u.uur
     -- Het uur vóór opening alleen als er toen al betaald is.
     where not u.buiten or coalesce(e.echt,0) > 0
  ), perdag as (
    select r.kid, r.datum, jsonb_agg(jsonb_build_object(
             'uur', r.uur, 'buiten', r.buiten, 'echt', r.echt, 'verwacht', r.verwacht,
             'gepland', r.gepland, 'geklokt', r.geklokt, 'advies', r.advies, 'achteraf', r.achteraf)
             order by r.uur) uren
      from rij r group by r.kid, r.datum
  ), binnen as (
    select c.kid, count(distinct c.gebruiker_id)::int n from klok c
     where c.datum = v_vandaag and c.binnen group by c.kid
  )
  select jsonb_build_object(
    'van', p_van, 'tot', p_tot, 'vandaag', v_vandaag,
    'nu', to_char(v_nu, 'HH24:MI'), 'nu_uur', v_nu_uur,
    'instellingen', jsonb_build_object('drukte_per_persoon', v_pp, 'drukte_erbij', v_erbij,
                                       'drukte_af', v_af, 'min_bezetting', v_min),
    'dagen', coalesce((select jsonb_agg(jsonb_build_object(
        'kraam', d.kid, 'datum', d.datum, 'dicht', d.dicht,
        'open', to_char(d.open_van, 'HH24:MI'), 'sluit', to_char(d.open_tot, 'HH24:MI'),
        'basis', case when b.kid is null then null
                      when b.met_vj then jsonb_build_object('soort', 'vorig_jaar',
                        'dagen', cardinality(b.vdagen), 'data', to_jsonb(b.vdagen),
                        'vj_datum', b.vj_datum, 'vj_pin', round(b.vj_pin), 'bon', round(b.bon,2),
                        'factor', round(b.factor,2), 'factor_dagen', coalesce(b.factor_dagen,0),
                        'dagtotaal', round(b.vj_pin / b.bon * b.factor),
                        'verdeling', jsonb_build_object('soort', b.vsoort, 'dagen', cardinality(b.vdagen), 'data', to_jsonb(b.vdagen)))
                      else jsonb_build_object('dagen', cardinality(b.dagen), 'soort', b.soort, 'data', to_jsonb(b.dagen)) end,
        'nu_binnen', case when d.datum = v_vandaag then coalesce(bn.n, 0) end,
        'uren', coalesce(pd.uren, '[]'::jsonb))
        order by d.datum, kk.volgorde, kk.naam)
      from dag d join k kk on kk.id = d.kid
      left join basis b on b.kid = d.kid and b.datum = d.datum
      left join perdag pd on pd.kid = d.kid and pd.datum = d.datum
      left join binnen bn on bn.kid = d.kid), '[]'::jsonb)
  ) into v;
  return v;
end $function$;

alter function public.mcr_drukte_advies(numeric,integer,numeric,numeric,numeric,integer) owner to app_rpc;
alter function public.mcr_drukte(date,date) owner to postgres;
revoke all on function public.mcr_drukte_advies(numeric,integer,numeric,numeric,numeric,integer) from public, anon;
revoke all on function public.mcr_drukte(date,date) from public, anon;
grant execute on function public.mcr_drukte_advies(numeric,integer,numeric,numeric,numeric,integer) to authenticated, service_role;
grant execute on function public.mcr_drukte(date,date) to authenticated, service_role;
