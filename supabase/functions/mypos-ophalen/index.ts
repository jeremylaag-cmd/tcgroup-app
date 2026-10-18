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
// myPOS Transactions API (v1):
//   token:  POST https://auth-api.mypos.com/oauth/token  (Basic client_id:secret, grant_type=client_credentials)
//   lijst:  POST https://transactions-api.mypos.com/v1/transactions?page=&size=
//           headers Authorization: Bearer, API-Key: client_id, X-Request-ID, Content-Type: application/json
//           body {"from_date":"YYYY-MM-DD","to_date":"YYYY-MM-DD"}
//   per regel: payment_reference, transaction_type, transaction_currency, transaction_amount (met teken),
//           original_currency, original_amount, date (UTC), sign (C/D), terminal_id, serial_number
//   Een pinbetaling is een C-regel met terminal_id; de myPOS-kosten staan als aparte D-regel
//   (transaction_type 001) met dezelfde terminal en hetzelfde tijdstip.
//
// Proef: {"proef":"sandbox"} gebruikt de openbare test-sleutels van myPOS en
// schrijft niets weg; je krijgt alleen een samenvatting terug.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const PROD = { auth: "https://auth-api.mypos.com/oauth/token", api: "https://transactions-api.mypos.com/v1" };
const SANDBOX = { auth: "https://sandbox-auth-api.mypos.com/oauth/token", api: "https://sandbox-transactions-api.mypos.com/v1" };
const SANDBOX_ID = "MP_TRANSACTIONS_API_CLIENT";
const SANDBOX_GEHEIM = "aECDmr6LYidRxdZfiZckPyxswq3xL5Fr"; // openbaar, uit de myPOS-documentatie

type Tx = {
  payment_reference: string; transaction_type: string; transaction_currency: string;
  transaction_amount: number; original_currency: string; original_amount: number;
  date: string; sign: string; terminal_id: string; serial_number?: string;
};
type Rij = { ref: string; tid: string; dag: string; uur: number; bedrag: number; kosten: number; fooi: number; merk: string };

const wacht = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function haalToken(urls: typeof PROD, id: string, geheim: string): Promise<string> {
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

// Alle transacties tussen twee datums (myPOS-datums, inclusief). Bladert tot
// alles binnen is; stopt ook als een pagina niets nieuws meer oplevert.
async function haalTransacties(urls: typeof PROD, token: string, id: string, van: string, tot: string) {
  const alle = new Map<string, Tx>();
  let totaal = 0, paginas = 0;
  for (let p = 1; p <= 200; p++) {
    const r = await fetch(`${urls.api}/transactions?page=${p}&size=100&page_size=100`, {
      method: "POST",
      headers: {
        Authorization: "Bearer " + token, "API-Key": id, "X-Request-ID": crypto.randomUUID(),
        Accept: "application/json", "Content-Type": "application/json",
      },
      body: JSON.stringify({ from_date: van, to_date: tot }),
    });
    paginas++;
    if (r.status === 429) { await wacht(20000); p--; continue; }
    const t = await r.text();
    if (!r.ok) throw new Error(`myPOS gaf een fout bij het ophalen (${r.status}): ${t.slice(0, 200)}`);
    const j = JSON.parse(t);
    const lijst: Tx[] = j.transactions || [];
    totaal = Number(j.pagination?.total) || totaal;
    let nieuw = 0;
    for (const x of lijst) if (x.payment_reference && !alle.has(x.payment_reference)) { alle.set(x.payment_reference, x); nieuw++; }
    if (!lijst.length || !nieuw || (totaal && alle.size >= totaal)) break;
    await wacht(1100); // ruim onder de 60 verzoeken per minuut
  }
  return { transacties: [...alle.values()], totaal, paginas };
}

// Dag en uur in Engelse tijd (de markt rekent in Britse tijd).
const LONDEN = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23",
});
function dagUur(utc: string) {
  const d: Record<string, string> = {};
  for (const p of LONDEN.formatToParts(new Date(utc))) d[p.type] = p.value;
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
    const b = bedragVan(x);
    if (b === null) { andereMunt++; continue; }
    const teken = x.sign === "D" ? -1 : 1; // D met terminal = terugbetaling
    if (teken < 0) terug++;
    const { dag, uur } = dagUur(x.date);
    const ta = Math.abs(Number(x.transaction_amount) || 0);
    betalingen.push({
      ref: x.payment_reference, tid, dag, uur, bedrag: Math.round(teken * b * 100) / 100, kosten: 0, fooi: 0, merk: "",
      _sleutel: sleutel, _koers: ta ? b / ta : 1,
    });
  }
  // Kosten bij de betaling van hetzelfde moment zetten (omgerekend als de rekening in een andere munt is).
  let kostenLos = 0;
  const perSleutel = new Map<string, (typeof betalingen)[number]>();
  for (const b of betalingen) if (!perSleutel.has(b._sleutel)) perSleutel.set(b._sleutel, b);
  for (const [s, k] of kostenPer) {
    const b = perSleutel.get(s);
    if (b) b.kosten = Math.round((b.kosten + k * b._koers) * 100) / 100;
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
    per[k].omzet = Math.round((per[k].omzet + r.bedrag) * 100) / 100;
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
      return json({ proef: true, opgehaald: h.transacties.length, totaal: h.totaal, paginas: h.paginas,
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
  for (const a of accounts ?? []) {
    const start = new Date();
    try {
      // Vanaf de laatst opgehaalde dag (één dag terug voor de zekerheid); dubbel tellen kan
      // niet, want elke betalingsreferentie wordt maar één keer opgeslagen.
      const basis = a.opgehaald_tot ? new Date(new Date(a.opgehaald_tot).getTime() - 86400000) : new Date(a.vanaf ?? start);
      const vanaf = a.vanaf && datum(basis) < a.vanaf ? a.vanaf : datum(basis);
      const tot = datum(new Date(start.getTime() + 86400000));
      const token = await haalToken(PROD, a.client_id, a.client_geheim);
      const h = await haalTransacties(PROD, token, a.client_id, vanaf, tot);
      const r = naarRijen(h.transacties, (a.valuta || "GBP").toUpperCase());
      let nieuw = 0, door = 0;
      for (let i = 0; i < r.rijen.length; i += 800) {
        const { data, error: f } = await db.rpc("mypos_verwerk", { p_account: a.id, p_rijen: r.rijen.slice(i, i + 800) });
        if (f) throw new Error("Wegschrijven lukte niet: " + f.message);
        const x = (data && data[0]) || {};
        nieuw += x.opgeslagen || 0; door += x.doorgezet || 0;
      }
      const status = `${nieuw} nieuwe betalingen · ${door} in het dagrapport gezet`
        + (r.andereMunt ? ` · ${r.andereMunt} in een andere munt overgeslagen` : "");
      await db.from("mypos_accounts").update({
        laatst_gedraaid: start.toISOString(), opgehaald_tot: start.toISOString(), laatste_status: status, laatste_fout: null,
        laatst_nieuw: nieuw,
      }).eq("id", a.id);
      uitslagen.push({ account: a.naam, nieuw, door, bekeken: h.transacties.length });
    } catch (e) {
      const fout = String((e as Error)?.message ?? e).slice(0, 500);
      await db.from("mypos_accounts").update({ laatst_gedraaid: start.toISOString(), laatste_fout: fout }).eq("id", a.id);
      uitslagen.push({ account: a.naam, fout });
    }
  }
  console.log("MYPOS", JSON.stringify(uitslagen));
  return json({ accounts: uitslagen.length, uitslagen });
});
