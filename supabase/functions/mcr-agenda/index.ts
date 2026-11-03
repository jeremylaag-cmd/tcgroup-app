// Manchester: een shift in je eigen agenda zetten (3 nov 2026).
//
// De app opent https://…/functions/v1/mcr-agenda?s=<shift>&u=<gebruiker>. Op een
// iPhone vraagt Safari dan meteen "Toevoegen aan agenda"; Android downloadt het
// bestand en opent het met de agenda-app.
//
// Er is geen inlog nodig (verify_jwt uit), want de agenda-app stuurt geen
// sessie mee. Daarom geeft de functie alleen iets terug als die gebruiker echt
// op die shift staat (mcr_ics_data, alleen voor service_role). Beide id's zijn
// lange willekeurige uuid's die alleen in de app van die persoon staan.

import { createClient } from "jsr:@supabase/supabase-js@2";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function esc(t: string): string {
  return String(t ?? "").replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// Regels in een agenda-bestand mogen maximaal 75 bytes zijn; langer wordt gevouwen.
function vouw(regel: string): string {
  const bytes = new TextEncoder().encode(regel);
  if (bytes.length <= 75) return regel;
  const delen: string[] = [];
  let huidig = "";
  let lengte = 0;
  for (const teken of regel) {
    const n = new TextEncoder().encode(teken).length;
    if (lengte + n > (delen.length ? 74 : 75)) { delen.push(huidig); huidig = ""; lengte = 0; }
    huidig += teken; lengte += n;
  }
  delen.push(huidig);
  return delen.join("\r\n ");
}

const nietGevonden = () => new Response("This shift could not be found.", { status: 404, headers: { "Content-Type": "text/plain; charset=utf-8" } });

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const s = url.searchParams.get("s") ?? "";
  const u = url.searchParams.get("u") ?? "";
  if (!UUID.test(s) || !UUID.test(u)) return nietGevonden();

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await db.rpc("mcr_ics_data", { p_shift: s, p_gebruiker: u });
  if (error || !data) return nietGevonden();
  const d = data as Record<string, string | boolean | null>;

  const tijden = `${d.start}–${d.tot_sluit ? "close" : d.eind}`;
  const beschrijving = [
    `Dutch Mini Pancakes · ${d.kraam}`,
    `Shift ${tijden}${d.tot_sluit ? ` (clean-up until about ${d.eind})` : ""}`,
    d.managers ? `Stall manager: ${d.managers}` : "",
    "Be there 10 minutes before your shift starts.",
    "Clock in by tapping the tag at the stall.",
    "Shifts can change: check the TC Group app for the latest rota.",
  ].filter(Boolean).join("\n");
  const nu = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");

  const regels = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//TC Group//Manchester rota//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${s}-${u}@tcgroup.nl`,
    `DTSTAMP:${nu}`,
    `DTSTART:${d.start_utc}`,
    `DTEND:${d.eind_utc}`,
    `SUMMARY:${esc(`Dutch Mini Pancakes · ${d.kraam}`)}`,
    `LOCATION:${esc(String(d.adres ?? ""))}`,
    `DESCRIPTION:${esc(beschrijving)}`,
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "DESCRIPTION:Your shift starts in 1 hour",
    "TRIGGER:-PT60M",
    "END:VALARM",
    "END:VEVENT",
    "END:VCALENDAR",
  ].map(vouw);

  return new Response(regels.join("\r\n") + "\r\n", {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": `inline; filename="shift-${d.datum}.ics"`,
      "Cache-Control": "no-store",
    },
  });
});
