-- Manchester: pinomzet automatisch uit myPOS (19 okt 2026)
--
-- Bram: "ik kan met mypos een API genereren. wat kan ik hiermee doen?" → "ja werk
-- maar uit." Hij heeft twee myPOS-rekeningen; elke rekening krijgt eigen sleutels.
--
-- * mypos_accounts: per myPOS-rekening naam, vestiging, valuta, klantnummer
--   (client_id) en klantgeheim, vanaf welke dag, en de laatste uitslag.
--   Alleen postgres/service_role kunnen erbij (geen beleid voor de app, geen
--   audit-trigger: het geheim mag niet in het logboek). De app gebruikt de
--   functies hieronder en krijgt het geheim nooit terug.
-- * pin_import_kern(p_vest, p_rijen): hetzelfde als pin_import (handmatig
--   inlezen), maar voor de server: zonder inlog, vestiging als parameter, prijzen
--   van die vestiging. Alleen service_role.
-- * Edge-functie mypos-ophalen (supabase/functions/mypos-ophalen) haalt elke
--   15 minuten de nieuwe transacties op en roept pin_import_kern aan. Dubbel
--   tellen kan niet: pin_referenties onthoudt elke betalingsreferentie, ook van
--   handmatig ingelezen bestanden.
-- * mypos_nu_ophalen(): knop "Nu ophalen".
--
-- Daarna (zelfde avond): "ik heb best wel wat terminals op 1 account alleen zijn
-- maar een aantal terminals van toepassing. kan ik kiezen welke terminals bij
-- welke stand horen?" De API levert per rekening alles, niet per terminal. Dus:
-- * mypos_transacties: elke pinbetaling van de rekening (alleen referentie, TID,
--   dag, uur, bedrag, kosten; geen kaartgegevens) komt eerst hier.
-- * mypos_doorzetten(vestiging): alleen betalingen van een terminal die aan een
--   kraam hangt gaan door naar het dagrapport (pin_import_kern). Koppel je later
--   een terminal, dan zet een trigger op terminals zijn eerdere betalingen alsnog
--   door; opnieuw ophalen bij myPOS is niet nodig.
-- * terminals.negeren: "hoort niet bij Manchester"; verdwijnt uit de lijsten.
-- * mypos_terminals_gezien(): welke terminals de rekeningen hebben, met aantal,
--   omzet en kraam. mypos_tid_kiezen(tid, kraam): kraam kiezen of negeren.

create table public.mypos_accounts (
  id              uuid primary key default gen_random_uuid(),
  naam            text not null check (length(btrim(naam)) > 0),
  vestiging       text not null default 'MCR' references public.vestigingen(code),
  valuta          text not null default 'GBP' check (valuta in ('GBP','EUR')),
  client_id       text,
  client_geheim   text,
  vanaf           date,
  actief          boolean not null default true,
  opgehaald_tot   timestamptz,
  laatst_gedraaid timestamptz,
  laatste_status  text,
  laatste_fout    text,
  laatst_nieuw    integer,
  onbekende_tids  text,
  aangemaakt_op   timestamptz not null default now(),
  aangemaakt_door uuid
);
revoke all on public.mypos_accounts from anon, authenticated, app_rpc;
grant select, insert, update, delete on public.mypos_accounts to service_role;
alter table public.mypos_accounts enable row level security;
-- Geen beleid: via de app (anon/authenticated/app_rpc) is de tabel dicht.

-- Wachtwoord voor de aanroep van de edge-functie (net als 'herinnering').
insert into public.systeem_geheimen (sleutel, waarde, omschrijving)
values ('mypos', replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''),
        'Wachtwoord waarmee de klok en de knop Nu ophalen de edge-functie mypos-ophalen aanroepen')
on conflict (sleutel) do nothing;

-- ── Kern van het inlezen, voor de server ─────────────────────────
create or replace function public.pin_import_kern(p_vest text, p_rijen jsonb)
returns table(dagen integer, transacties integer, dubbel integer, omzet numeric, kosten numeric, onbekende_tids text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  r jsonb; v_ref text; v_tid text; v_dag date; v_uur int;
  v_bedrag numeric; v_kosten numeric; v_fooi numeric; v_merk text;
  v_nieuw int := 0; v_dubbel int := 0; v_omzet numeric := 0; v_kost numeric := 0;
  v_onbekend text[] := '{}';
  v_prijs numeric; v_top numeric;
begin
  if p_vest is null or not exists (select 1 from public.vestigingen v where v.code = p_vest) then
    raise exception 'onbekende vestiging';
  end if;

  drop table if exists _in;
  create temp table _in (tid text, dag date, uur int, bedrag numeric, kosten numeric,
                         fooi numeric, merk text, ref text) on commit drop;

  for r in select * from jsonb_array_elements(p_rijen) loop
    v_ref := r->>'ref'; v_tid := r->>'tid'; v_dag := (r->>'dag')::date;
    v_uur := coalesce((r->>'uur')::int, 0);
    v_bedrag := coalesce((r->>'bedrag')::numeric, 0);
    v_kosten := coalesce((r->>'kosten')::numeric, 0);
    v_fooi   := coalesce((r->>'fooi')::numeric, 0);
    v_merk   := coalesce(r->>'merk','');
    if v_ref is null or v_tid is null or v_dag is null then continue; end if;
    begin
      insert into public.pin_referenties (vestiging, referentie, datum) values (p_vest, v_ref, v_dag);
    exception when unique_violation then
      v_dubbel := v_dubbel + 1; continue;
    end;
    insert into _in values (v_tid, v_dag, v_uur, v_bedrag, v_kosten, v_fooi, v_merk, v_ref);
    v_nieuw := v_nieuw + 1; v_omzet := v_omzet + v_bedrag; v_kost := v_kost + v_kosten;
  end loop;

  v_prijs := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                        where i.vestiging = p_vest and i.sleutel = 'prijs_portie'), 7);
  v_top   := coalesce((select nullif(replace(i.waarde,',','.'),'')::numeric from public.vestiging_instellingen i
                        where i.vestiging = p_vest and i.sleutel = 'prijs_topping'), 1);

  insert into public.pin_dag (vestiging, tid, datum, kraam_id, omzet, transacties, kosten, fooi,
                              visa, mastercard, porties, toppings, onverklaard)
  select p_vest, i.tid, i.dag, public.kraam_van_tid(p_vest, i.tid, i.dag),
         sum(i.bedrag), count(*), sum(i.kosten), sum(i.fooi),
         count(*) filter (where lower(i.merk) like '%visa%'),
         count(*) filter (where lower(i.merk) like '%master%'),
         sum(floor(i.bedrag / v_prijs))::int,
         sum(round((i.bedrag - floor(i.bedrag / v_prijs) * v_prijs) / v_top))::int,
         sum(case when (i.bedrag - floor(i.bedrag/v_prijs)*v_prijs)
                       - round((i.bedrag - floor(i.bedrag/v_prijs)*v_prijs)/v_top)*v_top <> 0
                  then i.bedrag else 0 end)
    from _in i group by i.tid, i.dag
  on conflict (vestiging, tid, datum) do update set
    omzet = public.pin_dag.omzet + excluded.omzet,
    transacties = public.pin_dag.transacties + excluded.transacties,
    kosten = public.pin_dag.kosten + excluded.kosten,
    fooi = public.pin_dag.fooi + excluded.fooi,
    visa = public.pin_dag.visa + excluded.visa,
    mastercard = public.pin_dag.mastercard + excluded.mastercard,
    porties = coalesce(public.pin_dag.porties,0) + coalesce(excluded.porties,0),
    toppings = coalesce(public.pin_dag.toppings,0) + coalesce(excluded.toppings,0),
    onverklaard = public.pin_dag.onverklaard + excluded.onverklaard,
    kraam_id = coalesce(public.pin_dag.kraam_id, excluded.kraam_id),
    bijgewerkt_op = now();

  insert into public.pin_uur (vestiging, tid, datum, uur, omzet, transacties)
  select p_vest, i.tid, i.dag, i.uur, sum(i.bedrag), count(*)
    from _in i group by i.tid, i.dag, i.uur
  on conflict (vestiging, tid, datum, uur) do update set
    omzet = public.pin_uur.omzet + excluded.omzet,
    transacties = public.pin_uur.transacties + excluded.transacties;

  select array_agg(distinct i.tid) into v_onbekend from _in i
   where public.kraam_van_tid(p_vest, i.tid, i.dag) is null;

  select count(*)::int into dagen from (select distinct i.tid, i.dag from _in i) x;
  transacties := v_nieuw; dubbel := v_dubbel; omzet := v_omzet; kosten := v_kost;
  onbekende_tids := array_to_string(coalesce(v_onbekend,'{}'), ', ');
  drop table if exists _in;
  return next;
end $function$;
revoke all on function public.pin_import_kern(text, jsonb) from public, anon, authenticated;
grant execute on function public.pin_import_kern(text, jsonb) to service_role;

-- ── Alles van de rekening eerst hier; alleen gekoppelde terminals gaan door ──
alter table public.terminals add column if not exists negeren boolean not null default false;

create table public.mypos_transacties (
  referentie   text primary key,
  account_id   uuid not null references public.mypos_accounts(id) on delete cascade,
  vestiging    text not null references public.vestigingen(code),
  tid          text not null,
  dag          date not null,
  uur          integer not null,
  bedrag       numeric not null,
  kosten       numeric not null default 0,
  ingelezen    boolean not null default false,
  opgehaald_op timestamptz not null default now()
);
create index mypos_transacties_tid on public.mypos_transacties (vestiging, tid, dag);
create index mypos_transacties_wacht on public.mypos_transacties (vestiging) where not ingelezen;
revoke all on public.mypos_transacties from anon, authenticated, app_rpc;
grant select, insert, update, delete on public.mypos_transacties to service_role;
alter table public.mypos_transacties enable row level security;

create or replace function public.mypos_doorzetten(p_vest text)
returns integer
language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb; n int;
begin
  select jsonb_agg(jsonb_build_object('ref',t.referentie,'tid',t.tid,'dag',t.dag,'uur',t.uur,
                                      'bedrag',t.bedrag,'kosten',t.kosten,'fooi',0,'merk','')), count(*)
    into v, n
    from public.mypos_transacties t
   where t.vestiging = p_vest and not t.ingelezen
     and public.kraam_van_tid(p_vest, t.tid, t.dag) is not null;
  if coalesce(n,0) = 0 then return 0; end if;
  perform public.pin_import_kern(p_vest, v);
  update public.mypos_transacties t set ingelezen = true
   where t.vestiging = p_vest and not t.ingelezen
     and public.kraam_van_tid(p_vest, t.tid, t.dag) is not null;
  return n;
end $$;
revoke all on function public.mypos_doorzetten(text) from public, anon, authenticated;
grant execute on function public.mypos_doorzetten(text) to service_role;

-- Door de edge-functie: nieuwe betalingen opslaan en doorzetten wat bij een kraam hoort.
create or replace function public.mypos_verwerk(p_account uuid, p_rijen jsonb)
returns table(opgeslagen integer, doorgezet integer)
language plpgsql security definer set search_path to 'public'
as $$
declare v_vest text;
begin
  select a.vestiging into v_vest from public.mypos_accounts a where a.id = p_account;
  if v_vest is null then raise exception 'onbekende rekening'; end if;
  insert into public.mypos_transacties (referentie, account_id, vestiging, tid, dag, uur, bedrag, kosten)
  select r->>'ref', p_account, v_vest, r->>'tid', (r->>'dag')::date, coalesce((r->>'uur')::int,0),
         coalesce((r->>'bedrag')::numeric,0), coalesce((r->>'kosten')::numeric,0)
    from jsonb_array_elements(p_rijen) r
   where r->>'ref' is not null and r->>'tid' is not null and r->>'dag' is not null
  on conflict (referentie) do nothing;
  get diagnostics opgeslagen = row_count;
  doorgezet := public.mypos_doorzetten(v_vest);
  return next;
end $$;
revoke all on function public.mypos_verwerk(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.mypos_verwerk(uuid, jsonb) to service_role;

-- Koppel je (ook via het bestaande Terminals-blok) een terminal aan een kraam,
-- dan gaan zijn eerder opgehaalde betalingen meteen door.
create or replace function public.terminals_mypos_doorzetten()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.kraam_id is not null and not new.negeren then
    perform public.mypos_doorzetten(new.vestiging);
  end if;
  return null;
end $$;
create trigger zz_mypos_doorzetten after insert or update of kraam_id, negeren, vanaf, tot on public.terminals
  for each row execute function public.terminals_mypos_doorzetten();

-- Welke terminals de gekoppelde rekeningen hebben.
create or replace function public.mypos_terminals_gezien()
returns table(tid text, rekening text, aantal integer, omzet numeric, eerste date, laatste date,
              kraam_id uuid, kraam text, negeren boolean, naam text)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select x.tid, string_agg(distinct a.naam, ', '), sum(x.n)::int, sum(x.som), min(x.eerste), max(x.laatste),
         t.kraam_id, k.naam, coalesce(t.negeren,false), t.naam
    from (select m.account_id, m.vestiging, m.tid, count(*) n, sum(m.bedrag) som, min(m.dag) eerste, max(m.dag) laatste
            from public.mypos_transacties m group by 1,2,3) x
    join public.mypos_accounts a on a.id = x.account_id
    left join lateral (select tt.kraam_id, tt.negeren, tt.naam from public.terminals tt
                        where tt.vestiging = x.vestiging and tt.tid = x.tid
                        order by tt.vanaf desc nulls last limit 1) t on true
    left join public.kramen k on k.id = t.kraam_id
   where public.vest_ok(x.vestiging) and public.in_actieve_vestiging(x.vestiging)
   group by x.tid, t.kraam_id, k.naam, t.negeren, t.naam
   order by coalesce(t.negeren,false), (t.kraam_id is null) desc, max(x.laatste) desc
) _r where public.mag_kraambeheer() $$;

-- Kraam kiezen (p_kraam) of "hoort niet bij Manchester" (p_kraam leeg).
create or replace function public.mypos_tid_kiezen(p_tid text, p_kraam uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_vest text := public.actieve_vestiging(); v_id uuid;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging.' using errcode='P0002'; end if;
  if nullif(btrim(coalesce(p_tid,'')),'') is null then raise exception 'Geen terminal.' using errcode='P0002'; end if;
  if p_kraam is not null and not exists (select 1 from public.kramen k where k.id = p_kraam and k.vestiging = v_vest) then
    raise exception 'Onbekende kraam.' using errcode='P0002'; end if;
  select t.id into v_id from public.terminals t
   where t.vestiging = v_vest and t.tid = btrim(p_tid) order by t.vanaf desc nulls last limit 1;
  if v_id is null then
    insert into public.terminals (vestiging, tid, kraam_id, negeren) values (v_vest, btrim(p_tid), p_kraam, p_kraam is null);
  else
    update public.terminals set kraam_id = p_kraam, negeren = (p_kraam is null) where id = v_id;
  end if;
  update public.pin_dag d set kraam_id = public.kraam_van_tid(v_vest, d.tid, d.datum)
   where d.vestiging = v_vest and d.tid = btrim(p_tid);
end $$;

-- Genegeerde terminals niet meer in het Terminals-blok.
create or replace function public.terminals_lijst()
 returns table(tid text, naam text, kraam_id uuid, kraam text, vanaf date, tot date, dagen integer, omzet numeric)
 language sql stable security definer set search_path to 'public'
as $function$
  select * from (
    with uit_data as (
      select d.tid, (array_agg(d.kraam_id))[1] kraam_id, count(*)::int dagen, sum(d.omzet) omzet
        from public.pin_dag d
       where d.vestiging = public.actieve_vestiging()
       group by d.tid
    ), klaargezet as (
      select t.tid, t.naam, t.kraam_id, t.vanaf, t.tot
        from public.terminals t
       where t.vestiging = public.actieve_vestiging() and not t.negeren
    )
    select coalesce(k.tid, u.tid),
           k.naam,
           coalesce(u.kraam_id, k.kraam_id),
           kr.naam,
           k.vanaf, k.tot,
           coalesce(u.dagen,0), coalesce(u.omzet,0)
      from klaargezet k
      full outer join uit_data u on u.tid = k.tid
      left join public.kramen kr on kr.id = coalesce(u.kraam_id, k.kraam_id)
     where not exists (select 1 from public.terminals n where n.vestiging = public.actieve_vestiging()
                         and n.tid = coalesce(k.tid, u.tid) and n.negeren)
     order by 1
  ) _rijen where public.mag_kraambeheer()
$function$;

-- ── App: lijst (zonder geheim) ───────────────────────────────────
create or replace function public.mypos_accounts_lijst()
returns table(id uuid, naam text, vestiging text, valuta text, klantnummer text, heeft_geheim boolean,
              vanaf date, actief boolean, opgehaald_tot timestamptz, laatst_gedraaid timestamptz,
              laatste_status text, laatste_fout text, laatst_nieuw integer, onbekende_tids text)
language sql stable security definer set search_path to 'public'
as $$ select * from (
  select a.id, a.naam, a.vestiging, a.valuta,
         case when a.client_id is null then null
              when length(a.client_id) <= 8 then a.client_id
              else left(a.client_id, 6) || '…' || right(a.client_id, 3) end,
         a.client_geheim is not null and a.client_geheim <> '',
         a.vanaf, a.actief, a.opgehaald_tot, a.laatst_gedraaid, a.laatste_status, a.laatste_fout,
         a.laatst_nieuw, a.onbekende_tids
    from public.mypos_accounts a
   where public.vest_ok(a.vestiging) and public.in_actieve_vestiging(a.vestiging)
   order by a.aangemaakt_op
) _r where public.mag_kraambeheer() $$;

-- ── App: toevoegen of wijzigen (alleen administrator) ────────────
create or replace function public.mypos_account_zetten(
  p_id uuid, p_naam text, p_klantnummer text, p_geheim text, p_vanaf date, p_actief boolean, p_valuta text default 'GBP')
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare v_id uuid; v_vest text; v_oud record;
        v_kn text := nullif(btrim(coalesce(p_klantnummer,'')),'');
        v_gh text := nullif(btrim(coalesce(p_geheim,'')),'');
begin
  if not (public.is_administrator() and public.mag_kraambeheer()) then
    raise exception 'Alleen een administrator kan myPOS-sleutels beheren.' using errcode='P0002';
  end if;
  if nullif(btrim(coalesce(p_naam,'')),'') is null then
    raise exception 'Geef de rekening een naam.' using errcode='P0002'; end if;
  if coalesce(p_valuta,'GBP') not in ('GBP','EUR') then
    raise exception 'Onbekende valuta.' using errcode='P0002'; end if;
  select k.vestiging into v_vest from public.kramen k
   where public.vest_ok(k.vestiging) and public.in_actieve_vestiging(k.vestiging) order by k.vestiging limit 1;
  if v_vest is null then raise exception 'Kies eerst Manchester.' using errcode='P0002'; end if;

  if p_id is null then
    if v_kn is null or v_gh is null then
      raise exception 'Vul het klantnummer en het klantgeheim in.' using errcode='P0002'; end if;
    insert into public.mypos_accounts (naam, vestiging, valuta, client_id, client_geheim, vanaf, actief, aangemaakt_door)
    values (btrim(p_naam), v_vest, coalesce(p_valuta,'GBP'), v_kn, v_gh,
            coalesce(p_vanaf, (now() at time zone 'Europe/London')::date), coalesce(p_actief,true), public.huidige_gebruiker())
    returning id into v_id;
  else
    select * into v_oud from public.mypos_accounts a where a.id = p_id and public.vest_ok(a.vestiging);
    if not found then raise exception 'Deze rekening bestaat niet meer.' using errcode='P0002'; end if;
    update public.mypos_accounts a set
      naam = btrim(p_naam), valuta = coalesce(p_valuta, a.valuta),
      client_id = coalesce(v_kn, a.client_id),
      client_geheim = coalesce(v_gh, a.client_geheim),       -- leeg laten = het oude geheim houden
      vanaf = coalesce(p_vanaf, a.vanaf), actief = coalesce(p_actief, a.actief),
      -- Andere sleutels of een eerdere startdag: opnieuw vanaf 'vanaf' ophalen (dubbel tellen kan niet).
      opgehaald_tot = case when v_kn is distinct from null and v_kn <> v_oud.client_id then null
                           when p_vanaf is not null and p_vanaf < coalesce(v_oud.vanaf, p_vanaf) then null
                           else a.opgehaald_tot end,
      laatste_fout = case when v_kn is not null or v_gh is not null then null else a.laatste_fout end
     where a.id = p_id
    returning a.id into v_id;
  end if;
  return v_id;
end $$;

create or replace function public.mypos_account_weg(p_id uuid)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not (public.is_administrator() and public.mag_kraambeheer()) then
    raise exception 'Alleen een administrator kan myPOS-sleutels beheren.' using errcode='P0002';
  end if;
  delete from public.mypos_accounts a where a.id = p_id and public.vest_ok(a.vestiging);
end $$;

-- ── App: knop "Nu ophalen" ───────────────────────────────────────
create or replace function public.mypos_nu_ophalen()
returns bigint
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging.' using errcode='P0002';
  end if;
  select net.http_post(
    url := 'https://rxfrdocioodfxrnjtipa.supabase.co/functions/v1/mypos-ophalen',
    headers := jsonb_build_object('Content-Type','application/json',
      'Authorization','Bearer '||(select waarde from public.systeem_geheimen where sleutel='anon_key')),
    body := jsonb_build_object('sleutel',(select waarde from public.systeem_geheimen where sleutel='mypos')),
    timeout_milliseconds := 120000) into v_id;
  return v_id;
end $$;

revoke all on function public.mypos_accounts_lijst() from public, anon;
revoke all on function public.mypos_account_zetten(uuid,text,text,text,date,boolean,text) from public, anon;
revoke all on function public.mypos_account_weg(uuid) from public, anon;
revoke all on function public.mypos_nu_ophalen() from public, anon;
revoke all on function public.mypos_terminals_gezien() from public, anon;
revoke all on function public.mypos_tid_kiezen(text, uuid) from public, anon;
grant execute on function public.mypos_terminals_gezien() to authenticated, service_role;
grant execute on function public.mypos_tid_kiezen(text, uuid) to authenticated, service_role;
grant execute on function public.mypos_accounts_lijst() to authenticated, service_role;
grant execute on function public.mypos_account_zetten(uuid,text,text,text,date,boolean,text) to authenticated, service_role;
grant execute on function public.mypos_account_weg(uuid) to authenticated, service_role;
grant execute on function public.mypos_nu_ophalen() to authenticated, service_role;

-- ── Klok: elke 15 minuten ophalen ────────────────────────────────
select cron.schedule('mypos-elke-15-min', '4,19,34,49 * * * *', $cron$
  select net.http_post(
    url := 'https://rxfrdocioodfxrnjtipa.supabase.co/functions/v1/mypos-ophalen',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||(select waarde from public.systeem_geheimen where sleutel='anon_key')),
    body := jsonb_build_object(
      'sleutel',(select waarde from public.systeem_geheimen where sleutel='mypos')),
    timeout_milliseconds := 120000
  );
$cron$);
