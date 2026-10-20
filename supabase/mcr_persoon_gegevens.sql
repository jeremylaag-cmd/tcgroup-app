-- Manchester beheer: alle gegevens van een medewerker aanpassen (Mensen ›
-- persoonskaart › Gegevens › Wijzigen). Alleen sleutels die in p_gegevens
-- staan worden aangepast; leeg = leegmaken. E-mail niet: dat is het inlogadres.
create or replace function public.mcr_persoon_gegevens_zetten(p_id uuid, p_gegevens jsonb)
returns void
language plpgsql security definer
set search_path to 'public'
as $function$
declare p jsonb := coalesce(p_gegevens, '{}'::jsonb); v_naam text; v_geb date; v_max int; v_start time;
        v_sinds int; v_loon numeric; v_t text;
begin
  if not public.mag_kraambeheer() then
    raise exception 'Alleen een beheerder van deze vestiging kan dit.' using errcode='P0002';
  end if;
  if not exists (select 1 from public.gebruikers x where x.id = p_id
                  and x.vestiging in (select unnest(public.zichtbare_vestigingen()))) then
    raise exception 'Die persoon bestaat niet.' using errcode='P0002';
  end if;

  if p ? 'naam' then
    v_naam := public.schoon_kort(p->>'naam');
    if coalesce(btrim(v_naam),'') = '' then raise exception 'Vul een naam in.' using errcode='P0002'; end if;
  end if;
  if p ? 'geboortedatum' then
    v_t := nullif(btrim(coalesce(p->>'geboortedatum','')),'');
    if v_t is not null then
      begin v_geb := v_t::date; exception when others then raise exception 'Geen geldige geboortedatum.' using errcode='P0002'; end;
      if v_geb < date '1930-01-01' or v_geb > current_date - interval '13 years' then
        raise exception 'Die geboortedatum klopt niet.' using errcode='P0002';
      end if;
    end if;
  end if;
  if p ? 'max_dagen' then
    v_t := nullif(btrim(coalesce(p->>'max_dagen','')),'');
    if v_t is not null then
      if v_t !~ '^\d+$' or v_t::int < 1 or v_t::int > 7 then raise exception 'Max dagen per week: 1 tot 7.' using errcode='P0002'; end if;
      v_max := v_t::int;
    end if;
  end if;
  if p ? 'vroegste_start' then
    v_t := nullif(btrim(coalesce(p->>'vroegste_start','')),'');
    if v_t is not null then
      begin v_start := v_t::time; exception when others then raise exception 'Geen geldige begintijd.' using errcode='P0002'; end;
    end if;
  end if;
  if p ? 'werkt_sinds' then
    v_t := nullif(btrim(coalesce(p->>'werkt_sinds','')),'');
    if v_t is not null then
      if v_t !~ '^\d{4}$' or v_t::int < 2000 or v_t::int > extract(year from current_date)::int then
        raise exception 'Kies een jaar tussen 2000 en nu.' using errcode='P0002';
      end if;
      v_sinds := v_t::int;
    end if;
  end if;
  if p ? 'uurloon' then
    v_t := nullif(replace(btrim(coalesce(p->>'uurloon','')),',','.'),'');
    if v_t is not null then
      if v_t !~ '^\d+(\.\d{1,2})?$' or v_t::numeric > 100 then raise exception 'Geen geldig uurloon.' using errcode='P0002'; end if;
      v_loon := v_t::numeric;
    end if;
  end if;

  update public.gebruikers g set
    naam             = case when p ? 'naam' then v_naam else g.naam end,
    telefoon         = case when p ? 'telefoon' then nullif(public.schoon_kort(p->>'telefoon'),'') else g.telefoon end,
    geboortedatum    = case when p ? 'geboortedatum' then v_geb else g.geboortedatum end,
    straat           = case when p ? 'straat' then nullif(public.schoon_kort(p->>'straat'),'') else g.straat end,
    postcode         = case when p ? 'postcode' then nullif(public.schoon_kort(p->>'postcode'),'') else g.postcode end,
    plaats           = case when p ? 'plaats' then nullif(public.schoon_kort(p->>'plaats'),'') else g.plaats end,
    shirtmaat        = case when p ? 'shirtmaat' then nullif(public.schoon_kort(p->>'shirtmaat'),'') else g.shirtmaat end,
    noodcontact_naam = case when p ? 'noodcontact_naam' then nullif(public.schoon_kort(p->>'noodcontact_naam'),'') else g.noodcontact_naam end,
    noodcontact_tel  = case when p ? 'noodcontact_tel' then nullif(public.schoon_kort(p->>'noodcontact_tel'),'') else g.noodcontact_tel end,
    bank_account     = case when p ? 'bank_account' then nullif(regexp_replace(coalesce(p->>'bank_account',''),'[^0-9]','','g'),'') else g.bank_account end,
    sort_code        = case when p ? 'sort_code' then nullif(regexp_replace(coalesce(p->>'sort_code',''),'[^0-9]','','g'),'') else g.sort_code end,
    iban             = case when p ? 'iban' then nullif(upper(regexp_replace(coalesce(p->>'iban',''),'[^0-9A-Za-z]','','g')),'') else g.iban end,
    utr              = case when p ? 'utr' then nullif(regexp_replace(coalesce(p->>'utr',''),'[^0-9]','','g'),'') else g.utr end,
    aangebracht_door = case when p ? 'aangebracht_door' then nullif(public.schoon_kort(p->>'aangebracht_door'),'') else g.aangebracht_door end,
    max_dagen_per_week = case when p ? 'max_dagen' then v_max else g.max_dagen_per_week end,
    vroegste_start   = case when p ? 'vroegste_start' then v_start else g.vroegste_start end,
    eigen_opmerking  = case when p ? 'eigen_opmerking' then nullif(public.schoon_kort(p->>'eigen_opmerking'),'') else g.eigen_opmerking end,
    werkt_sinds      = case when p ? 'werkt_sinds' then v_sinds else g.werkt_sinds end,
    uurloon          = case when p ? 'uurloon' and (v_loon is not null or not coalesce(g.goedgekeurd,false)) then v_loon else g.uurloon end
   where g.id = p_id;
end $function$;
alter function public.mcr_persoon_gegevens_zetten(uuid, jsonb) owner to app_rpc;
revoke all on function public.mcr_persoon_gegevens_zetten(uuid, jsonb) from public, anon;
grant execute on function public.mcr_persoon_gegevens_zetten(uuid, jsonb) to authenticated, service_role;
