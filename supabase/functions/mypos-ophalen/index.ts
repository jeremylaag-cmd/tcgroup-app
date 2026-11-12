// Haalt de pinbetalingen van de myPOS-rekening(en) op. Alles van de rekening
// komt in mypos_transacties; alleen betalingen van terminals die aan een kraam
// hangen gaan door naar het Manchester-dagrapport (pin_dag, pin_uur), net als
// het handmatig inlezen van de myPOS-exportbestanden (rpc mypos_verwerk).
//
// Wordt elke 15 minuten aangeroepen door de klok in de database (pg_cron), en
// meteen via de knop "Nu ophalen" (rpc mypos_nu_ophalen). Beide sturen een
// wachtwoord mee dat alleen in systeem_geheimen staat (sleutel 'mypos').
//
// De sleutels per myPOS-rekening staan in de tabel mypos_accounts. Alleen deze
// functie (service_role) leest ze; de app krijgt ze nooit terug.
//
// myPOS Transactions API:
//   token:  POST https://auth-api.mypos.com/oauth/token  (Basic client_id:secret, grant_type=client_credentials)
//   v1.1:   GET  https://transactions-api.mypos.com/v1.1/transactions?page=&size=&order=0&from_date=&to_date=
//           (echte paginering; order=0 = oudste eerst; max 100 per pagina)
//   v1:     POST https://transactions-api.mypos.com/v1/transactions?size=  body {from_date,to_date,last_transaction_id}
//           v1 kent GEEN page-parameter: zonder last_transaction_id krijg je steeds dezelfde eerste
//           100 terug. Dat was de oorzaak dat alles na de 100e regel van de dag wegviel.
//   headers Authorization: Bearer, API-Key: client_id, X-Request-ID
//   per regel: id, payment_reference, transaction_type, transaction_currency, transaction_amount (met teken),
//           original_currency, original_amount, date (UTC), sign (C/D), terminal_id, serial_number
//   Een pinbetaling is een C-regel met terminal_id; de myPOS-kosten staan als aparte D-regel
//   (transaction_type 001) met dezelfde terminal en hetzelfde tijdstip.
//
// 7 nov 2026: elke ronde las gisteren + vandaag helemaal opnieuw (5.700+ regels,
// 58 pagina's). Op de drukke zaterdag duurde dat vanaf ±17:34 langer dan de
// 120 s van pg_net, de ronde werd afgebroken vóór het opslaan en er kwam niets
// meer binnen. Nu: haalNieuwV11 leest alleen de laatste pagina's (wat nieuw is),
// met een tijdslimiet van 75 s per ronde.
//
// Proef: {"proef":"sandbox"} gebruikt de openbare test-sleutels van myPOS en
// schrijft niets weg; je krijgt alleen een samenvatting terug.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const PROD = {
  auth: "https://auth-api.mypos.com/oauth/token",
  api: "https://transactions-api.mypos.com/v1",
  api11: "https://transactions-api.mypos.com/v1.1",
};
const SANDBOX = {
  auth: "https://sandbox-auth-api.mypos.com/oauth/token",
  api: "https://sandbox-transactions-api.mypos.com/v1",
  api11: "https://sandbox-transactions-api.mypos.com/v1.1",
};
const SANDBOX_ID = "MP_TRANSACTIONS_API_CLIENT";
const SANDBOX_GEHEIM = "aECDmr6LYidRxdZfiZckPyxswq3xL5Fr"; // openbaar, uit de myPOS-documentatie

const PAGINA = 100; // het maximum dat myPOS per verzoek teruggeeft

type Tx = {
  id?: number | string;
  payment_reference: string; transaction_type: string; transaction_currency: string;
  transaction_amount: number; original_currency: string; original_amount: number;
  date: string; sign: string; terminal_id: string; serial_number?: string;
};
type Rij = { ref: string; tid: string; dag: string; uur: number; bedrag: number | null; kosten: number; fooi: number; merk: string;
  // Voor de verdeling over markten (Parijs in euro's op dezelfde rekening):
  ts?: string; oc?: string; oa?: number; tc?: string; ta?: number; kt?: number };
type Urls = typeof PROD;

const wacht = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Unieke sleutel per regel. Liefst het myPOS-id; anders referentie + soort + tijdstip,
// zodat een betaling en de bijbehorende kostenregel elkaar nooit wegdrukken.
const sleutelVan = (x: Tx) =>
  x.id != null && x.id !== "" ? "id:" + x.id : [x.payment_reference, x.sign, x.transaction_type, x.date].join("|");

async function haalToken(urls: Urls, id: string, geheim: string): Promise<string> {
  const r = await fetch(urls.auth, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(id + ":" + geheim), "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials",
  });
  const t = await r.text();
  let j: any = {};
  try { j = JSON.parse(t); } catch { /* geen json */ }
  if (!r.ok || !j.access_token) {
    throw new Error(r.status === 401 || r.status === 400
      ? "myPOS weigert de sleutels (klantnummer of klantgeheim klopt niet)."
      : `Inloggen bij myPOS lukte niet (${r.status}).`);
  }
  return j.access_token;
}

const kop = (token: string, id: string) => ({
  Authorization: "Bearer " + token, "API-Key": id, "X-Request-ID": crypto.randomUUID(),
  Accept: "application/json", "Content-Type": "application/json",
});

class GeenV11 extends Error {}

type Uitkomst = { transacties: Tx[]; totaal: number; paginas: number; bron: string; compleet?: boolean };

// v1.1: gewone paginering met page=1,2,3 … oudste eerst.
async function haalV11(urls: Urls, token: string, id: string, van: string, tot: string): Promise<Uitkomst> {
  const alle = new Map<string, Tx>();
  let totaal = 0, paginas = 0;
  for (let p = 1; p <= 500; p++) {
    const q = new URLSearchParams({
      page: String(p), size: String(PAGINA), order: "0",
      from_date: van + "T00:00:00Z", to_date: tot + "T23:59:59Z",
    });
    const r = await fetch(`${urls.api11}/transactions?${q}`, { method: "GET", headers: kop(token, id) });
    paginas++;
    if (r.status === 429) { await wacht(20000); p--; continue; }
    const t = await r.text();
    if (!r.ok) {
      if (p === 1 && [400, 401, 403, 404, 405, 501].includes(r.status)) throw new GeenV11(`v1.1 gaf ${r.status}`);
      throw new Error(`myPOS gaf een fout bij het ophalen (${r.status}): ${t.slice(0, 200)}`);
    }
    const j = JSON.parse(t);
    const lijst: Tx[] = j.transactions || [];
    totaal = Number(j.pagination?.total) || totaal;
    let nieuw = 0;
    for (const x of lijst) { const k = sleutelVan(x); if (!alle.has(k)) { alle.set(k, x); nieuw++; } }
    if (!lijst.length) break;
    // Volle pagina zonder iets nieuws = myPOS negeert 'page'. Dan niet stil stoppen maar de v1-route proberen.
    if (!nieuw) { if (lijst.length >= PAGINA) throw new GeenV11("v1.1 bladert niet door"); break; }
    if (totaal && alle.size >= totaal) break;
    if (lijst.length < PAGINA && !totaal) break;
    await wacht(1100); // ruim onder de 60 verzoeken per minuut
  }
  return { transacties: [...alle.values()], totaal, paginas, bron: "v1.1" };
}

// v1.1, alleen wat nieuw is. myPOS geeft oudste eerst, dus nieuwe betalingen
// staan altijd achteraan. Pagina 1 geeft het totaal; daarna van de laatste
// pagina terug naar voren tot er een pagina komt waarvan alle betalingen al in
// mypos_transacties staan, plus één pagina extra zodat de kostenregels van de
// eerste nieuwe betalingen ook meekomen.
async function haalNieuwV11(urls: Urls, token: string, id: string, van: string, tot: string,
                            db: any, deadline: number): Promise<Uitkomst> {
  const alle = new Map<string, Tx>();
  let paginas = 0;
  const pagina = async (p: number) => {
    for (let poging = 0; poging < 3; poging++) {
      const q = new URLSearchParams({
        page: String(p), size: String(PAGINA), order: "0",
        from_date: van + "T00:00:00Z", to_date: tot + "T23:59:59Z",
      });
      const r = await fetch(`${urls.api11}/transactions?${q}`, { method: "GET", headers: kop(token, id) });
      paginas++;
      if (r.status === 429) { await wacht(15000); continue; }
      const t = await r.text();
      if (!r.ok) {
        if (p === 1 && [400, 401, 403, 404, 405, 501].includes(r.status)) throw new GeenV11(`v1.1 gaf ${r.status}`);
        throw new Error(`myPOS gaf een fout bij het ophalen (${r.status}): ${t.slice(0, 200)}`);
      }
      return JSON.parse(t);
    }
    throw new Error("myPOS blijft 'te veel verzoeken' geven; de volgende ronde probeert het opnieuw.");
  };
  const voegToe = (lijst: Tx[]) => { for (const x of lijst) { const k = sleutelVan(x); if (!alle.has(k)) alle.set(k, x); } };
  const allesBekend = async (lijst: Tx[]) => {
    const refs = [...new Set(lijst
      .filter((x) => x.sign !== "D" && (x.terminal_id || "").trim() && x.payment_reference)
      .map((x) => x.payment_reference))];
    if (!refs.length) return false; // alleen kostenregels: verder terug kijken
    const { data, error } = await db.from("mypos_transacties").select("referentie").in("referentie", refs);
    if (error) throw new Error("Controleren wat er al is lukte niet: " + error.message);
    return (data?.length ?? 0) >= refs.length;
  };

  const eerste = await pagina(1);
  const lijst1: Tx[] = eerste.transactions || [];
  const totaal = Number(eerste.pagination?.total) || 0;
  voegToe(lijst1);
  if (lijst1.length < PAGINA) return { transacties: [...alle.values()], totaal, paginas, bron: "v1.1-nieuw", compleet: true };
  if (!totaal) throw new GeenV11("v1.1 gaf geen totaal"); // dan de oude route
  const laatste = Math.ceil(totaal / PAGINA);

  let compleet = false, extra = false, afgebroken = false;
  for (let p = laatste; p >= 2; p--) {
    if (Date.now() > deadline) { afgebroken = true; break; }
    await wacht(1000); // ruim onder de 60 verzoeken per minuut
    const lijst: Tx[] = (await pagina(p)).transactions || [];
    voegToe(lijst);
    if (extra) { compleet = true; break; }
    if (await allesBekend(lijst)) extra = true;
  }
  if (!afgebroken) compleet = true; // tot pagina 2 teruggelezen (pagina 1 hadden we al)
  return { transacties: [...alle.values()], totaal, paginas, bron: "v1.1-nieuw", compleet };
}

// v1: bladeren met last_transaction_id (het id van de laatste regel van de vorige pagina).
async function haalV1(urls: Urls, token: string, id: string, van: string, tot: string): Promise<Uitkomst> {
  const alle = new Map<string, Tx>();
  let totaal = 0, paginas = 0;
  let laatste: string | null = null;
  for (let p = 1; p <= 500; p++) {
    const body: Record<string, string> = { from_date: van, to_date: tot };
    if (laatste) body.last_transaction_id = laatste;
    const r = await fetch(`${urls.api}/transactions?size=${PAGINA}`, {
      method: "POST", headers: kop(token, id), body: JSON.stringify(body),
    });
    paginas++;
    if (r.status === 429) { await wacht(20000); p--; continue; }
    const t = await r.text();
    if (!r.ok) throw new Error(`myPOS gaf een fout bij het ophalen (${r.status}): ${t.slice(0, 200)}`);
    const j = JSON.parse(t);
    const lijst: Tx[] = j.transactions || [];
    totaal = Number(j.pagination?.total) || totaal;
    let nieuw = 0;
    for (const x of lijst) { const k = sleutelVan(x); if (!alle.has(k)) { alle.set(k, x); nieuw++; } }
    if (!lijst.length) break;
    if (!nieuw) {
      if (lijst.length >= PAGINA) {
        throw new Error(`myPOS geeft steeds dezelfde ${PAGINA} transacties terug; alles daarna wordt gemist. Neem contact op met Claude om de koppeling aan te passen.`);
      }
      break;
    }
    if (totaal && alle.size >= totaal) break;
    if (lijst.length < PAGINA) break;
    const z = lijst[lijst.length - 1];
    laatste = String(z.id ?? z.payment_reference);
    await wacht(1100);
  }
  return { transacties: [...alle.values()], totaal, paginas, bron: "v1" };
}

async function haalTransacties(urls: Urls, token: string, id: string, van: string, tot: string): Promise<Uitkomst> {
  try {
    return await haalV11(urls, token, id, van, tot);
  } catch (e) {
    if (!(e instanceof GeenV11)) throw e;
    console.log("MYPOS v1.1 niet bruikbaar, val terug op v1:", e.message);
  }
  return await haalV1(urls, token, id, van, tot);
}

// Dag en uur in Engelse tijd (de markt rekent in Britse tijd).
const LONDEN = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23",
});
function dagUur(utc: string) {
  const d: Record<string, string> = {};
  // myPOS geeft UTC zonder 'Z'; zonder Z zou JavaScript het als lokale tijd lezen.
  const s = /[zZ]|[+-]\d\d:?\d\d$/.test(utc) ? utc : utc + "Z";
  for (const p of LONDEN.formatToParts(new Date(s))) d[p.type] = p.value;
  return { dag: `${d.year}-${d.month}-${d.day}`, uur: Number(d.hour) };
}

// Van ruwe transacties naar regels voor mypos_verwerk.
function naarRijen(lijst: Tx[], valuta: string) {
  const bedragVan = (x: Tx) => {
    const oc = (x.original_currency || x.transaction_currency || "").toUpperCase();
    if (oc === valuta) return Math.abs(Number(x.original_amount ?? x.transaction_amount) || 0);
    if ((x.transaction_currency || "").toUpperCase() === valuta) return Math.abs(Number(x.transaction_amount) || 0);
    return null; // andere munt: niet meetellen
  };
  const betalingen: (Rij & { _sleutel: string; _koers: number })[] = [];
  const kostenPer = new Map<string, number>();
  let overgeslagen = 0, andereMunt = 0, terug = 0;
  for (const x of lijst) {
    const tid = (x.terminal_id || "").trim();
    if (!tid) { overgeslagen++; continue; } // geen pinautomaat (overboeking, maandkosten …)
    const sleutel = tid + "|" + x.date;
    const isKosten = x.sign === "D" && x.transaction_type === "001";
    if (isKosten) { kostenPer.set(sleutel, (kostenPer.get(sleutel) || 0) + Math.abs(Number(x.transaction_amount) || 0)); continue; }
    // Andere munt dan de rekening: niet meer overslaan. De database zet zo'n
    // betaling bij de markt van die munt (Parijs, euro) of van de terminal.
    const b = bedragVan(x);
    if (b === null) andereMunt++;
    const teken = x.sign === "D" ? -1 : 1; // D met terminal = terugbetaling
    if (teken < 0) terug++;
    const { dag, uur } = dagUur(x.date);
    const ta = Math.abs(Number(x.transaction_amount) || 0);
    const oa = Math.abs(Number(x.original_amount ?? x.transaction_amount) || 0);
    const utc = /[zZ]|[+-]\d\d:?\d\d$/.test(x.date) ? x.date : x.date + "Z";
    betalingen.push({
      ref: x.payment_reference, tid, dag, uur, bedrag: b === null ? null : Math.round(teken * b * 100) / 100, kosten: 0, fooi: 0, merk: "",
      ts: utc, oc: (x.original_currency || x.transaction_currency || "").toUpperCase(), oa: Math.round(teken * oa * 100) / 100,
      tc: (x.transaction_currency || "").toUpperCase(), ta: Math.round(teken * ta * 100) / 100, kt: 0,
      _sleutel: sleutel, _koers: ta && b !== null ? b / ta : 1,
    });
  }
  // Kosten bij de betaling van hetzelfde moment zetten (omgerekend als de rekening in een andere munt is).
  let kostenLos = 0;
  const perSleutel = new Map<string, (typeof betalingen)[number]>();
  for (const b of betalingen) if (!perSleutel.has(b._sleutel)) perSleutel.set(b._sleutel, b);
  for (const [s, k] of kostenPer) {
    const b = perSleutel.get(s);
    if (b) { b.kosten = Math.round((b.kosten + k * b._koers) * 100) / 100; b.kt = Math.round(((b.kt || 0) + k) * 100) / 100; }
    else kostenLos += k;
  }
  const rijen: Rij[] = betalingen.map(({ _sleutel, _koers, ...r }) => r);
  return { rijen, overgeslagen, andereMunt, terug, kostenLos: Math.round(kostenLos * 100) / 100 };
}

function samenvatting(rijen: Rij[]) {
  const per: Record<string, { omzet: number; aantal: number; kosten: number }> = {};
  for (const r of rijen) {
    const k = `${r.tid} ${r.dag}`;
    per[k] = per[k] || { omzet: 0, aantal: 0, kosten: 0 };
    per[k].omzet = Math.round((per[k].omzet + (r.bedrag ?? 0)) * 100) / 100;
    per[k].aantal++;
    per[k].kosten = Math.round((per[k].kosten + r.kosten) * 100) / 100;
  }
  return per;
}

const datum = (d: Date) => d.toISOString().slice(0, 10);

Deno.serve(async (req) => {
  let body: any = {};
  try { const t = await req.text(); body = t ? JSON.parse(t) : {}; } catch { /* leeg */ }

  // ── Proef in de myPOS-sandbox: openbare testgegevens, schrijft niets ──
  if (body.proef === "sandbox") {
    try {
      const token = await haalToken(SANDBOX, SANDBOX_ID, SANDBOX_GEHEIM);
      const van = body.van || "2024-01-01", tot = body.tot || datum(new Date(Date.now() + 86400000));
      const h = await haalTransacties(SANDBOX, token, SANDBOX_ID, van, tot);
      const r = naarRijen(h.transacties, (body.valuta || "EUR").toUpperCase());
      return json({ proef: true, bron: h.bron, opgehaald: h.transacties.length, totaal: h.totaal, paginas: h.paginas,
        betalingen: r.rijen.length, overgeslagen: r.overgeslagen, andere_munt: r.andereMunt, terugbetalingen: r.terug,
        kosten_los: r.kostenLos, per_terminal_dag: samenvatting(r.rijen), voorbeeld: r.rijen.slice(0, 3) });
    } catch (e) { return json({ proef: true, fout: String(e) }, 500); }
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // ── Wachtwoordcontrole ──
  const { data: geheim } = await db.from("systeem_geheimen").select("waarde").eq("sleutel", "mypos").single();
  if (!geheim?.waarde || body.sleutel !== geheim.waarde) return json({ error: "Geen toegang" }, 403);

  const { data: accounts, error } = await db.from("mypos_accounts")
    .select("id, naam, vestiging, valuta, client_id, client_geheim, vanaf, opgehaald_tot")
    .eq("actief", true).not("client_id", "is", null).not("client_geheim", "is", null);
  if (error) return json({ error: error.message }, 500);

  const uitslagen: unknown[] = [];
  // pg_net breekt na 120 s af en dan wordt er niets opgeslagen: ruim daarbinnen blijven.
  const deadline = Date.now() + 75000;
  // Wie het langst niet gelukt is eerst.
  const lijstAcc = [...(accounts ?? [])].sort((x: any, y: any) =>
    String(x.opgehaald_tot || "").localeCompare(String(y.opgehaald_tot || "")));
  for (const a of lijstAcc) {
    if (Date.now() > deadline) { uitslagen.push({ account: a.naam, overgeslagen: "geen tijd meer, volgende ronde" }); continue; }
    const start = new Date();
    try {
      // Vanaf de laatst opgehaalde dag (één dag terug voor de zekerheid); dubbel tellen kan
      // niet, want elke betalingsreferentie wordt maar één keer opgeslagen.
      // body.vanaf (YYYY-MM-DD) haalt eenmalig alles vanaf die dag opnieuw op, bijv. om gemiste dagen in te halen.
      const basis = a.opgehaald_tot ? new Date(new Date(a.opgehaald_tot).getTime() - 86400000) : new Date(a.vanaf ?? start);
      let vanaf = a.vanaf && datum(basis) < a.vanaf ? a.vanaf : datum(basis);
      const inhalen = typeof body.vanaf === "string" && /^\d{4}-\d\d-\d\d$/.test(body.vanaf);
      if (inhalen && body.vanaf < vanaf) {
        vanaf = a.vanaf && body.vanaf < a.vanaf ? a.vanaf : body.vanaf;
      }
      const tot = datum(new Date(start.getTime() + 86400000));
      const token = await haalToken(PROD, a.client_id, a.client_geheim);
      let h: Uitkomst;
      if (inhalen) {
        h = await haalTransacties(PROD, token, a.client_id, vanaf, tot); // bewust alles opnieuw
      } else {
        try { h = await haalNieuwV11(PROD, token, a.client_id, vanaf, tot, db, deadline); }
        catch (e) {
          if (!(e instanceof GeenV11)) throw e;
          h = await haalTransacties(PROD, token, a.client_id, vanaf, tot);
        }
      }
      const r = naarRijen(h.transacties, (a.valuta || "GBP").toUpperCase());
      let nieuw = 0, door = 0;
      for (let i = 0; i < r.rijen.length; i += 800) {
        const { data, error: f } = await db.rpc("mypos_verwerk", { p_account: a.id, p_rijen: r.rijen.slice(i, i + 800) });
        if (f) throw new Error("Wegschrijven lukte niet: " + f.message);
        const x = (data && data[0]) || {};
        nieuw += x.opgeslagen || 0; door += x.doorgezet || 0;
      }
      const status = `${nieuw} nieuwe betalingen · ${door} in het dagrapport gezet`
        + (r.andereMunt ? ` · ${r.andereMunt} in een andere munt (naar de markt van die munt)` : "");
      const klaar = h.compleet !== false;
      await db.from("mypos_accounts").update({
        laatst_gedraaid: start.toISOString(), laatste_status: status, laatst_nieuw: nieuw,
        // Alleen doorschuiven als alles nieuws gelezen is; anders gaat de volgende ronde verder.
        ...(klaar ? { opgehaald_tot: start.toISOString(), laatste_fout: null }
                  : { laatste_fout: "Nog niet alles ingehaald (te veel tegelijk); de volgende ronde gaat verder." }),
      }).eq("id", a.id);
      uitslagen.push({ account: a.naam, nieuw, door, bekeken: h.transacties.length, totaal: h.totaal,
        paginas: h.paginas, bron: h.bron, compleet: klaar, vanaf, tot });
    } catch (e) {
      const fout = String((e as Error)?.message ?? e).slice(0, 500);
      await db.from("mypos_accounts").update({ laatst_gedraaid: start.toISOString(), laatste_fout: fout }).eq("id", a.id);
      uitslagen.push({ account: a.naam, fout });
    }
  }
  console.log("MYPOS", JSON.stringify(uitslagen));
  return json({ accounts: uitslagen.length, uitslagen });
});
