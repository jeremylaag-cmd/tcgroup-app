// Verwijdert een account volledig: het profiel én de inlog bij Supabase Auth.
//
// Zonder dat laatste blijft het e-mailadres bezet en kan iemand zich later niet
// opnieuw aanmelden met hetzelfde adres.
//
// Zonder `userId` verwijder je je eigen account. Met `userId` verwijder je dat
// van iemand anders — dat mag alleen een beheerder, alleen binnen de vestiging
// waar hij op dat moment naar kijkt, en alleen als er niets te bewaren valt.
//
// Heeft iemand uren geklokt of een factuur gemaakt, dan wordt hier niets
// gewist: die gegevens horen zeven jaar bewaard te blijven. De app zet zo
// iemand "uit dienst" via account_afsluiten(); dat haalt hem uit alle lijsten
// en uit de planning, maar laat de loonadministratie heel.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Methode niet toegestaan" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Niet geautoriseerd" }, 401);

    let doelId: string | null = null;
    try {
      const tekst = await req.text();
      if (tekst) doelId = (JSON.parse(tekst).userId ?? null) as string | null;
    } catch { /* geen of ongeldige body: dan je eigen account */ }

    const userClient = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "Sessie ongeldig of verlopen" }, 401);

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { autoRefreshToken: false, persistSession: false } },
    );

    const uid = doelId ?? user.id;

    if (uid !== user.id) {
      // Iemand anders weghalen mag alleen een beheerder, en alleen binnen de
      // vestiging waar hij nu naar kijkt. Zonder die tweede voorwaarde zou een
      // Nederlandse beheerder een Engels account kunnen wissen.
      const { data: ik } = await admin.from("gebruikers")
        .select("rol, vestiging, alle_vestigingen, actieve_vestiging, beheer_rol")
        .eq("id", user.id).single();
      if (ik?.rol !== "beheerder") {
        return json({ error: "Alleen een beheerder mag andere accounts verwijderen" }, 403);
      }
      const { data: doel } = await admin.from("gebruikers")
        .select("vestiging, rol, beheer_rol").eq("id", uid).single();
      if (!doel) return json({ error: "Dat account bestaat niet" }, 404);

      const zichtbaar: string[] = !ik.alle_vestigingen
        ? [ik.vestiging]
        : (ik.actieve_vestiging && ik.actieve_vestiging !== "*"
            ? [ik.actieve_vestiging]
            : []);           // leeg = alle vestigingen
      if (zichtbaar.length > 0 && !zichtbaar.includes(doel.vestiging)) {
        return json({ error: "Dat account hoort niet bij de vestiging waar je nu naar kijkt" }, 403);
      }
      if (doel.rol === "beheerder" && doel.beheer_rol === "administrator") {
        return json({ error: "Het administrator-account kan niet worden verwijderd" }, 403);
      }
    }

    // Is er iets te bewaren, dan wordt hier niets gewist. Dat geldt ook voor je
    // eigen account: gewerkte uren en verstuurde facturen horen in de
    // administratie te blijven staan.
    const { count: urenAantal } = await admin.from("urenregistraties")
      .select("id", { count: "exact", head: true }).eq("gebruiker_id", uid);
    const { count: factuurAantal } = await admin.from("facturen")
      .select("id", { count: "exact", head: true }).eq("gebruiker_id", uid);
    if ((urenAantal ?? 0) > 0 || (factuurAantal ?? 0) > 0) {
      return json({
        error: "Dit account heeft geklokte uren of facturen. Die moeten bewaard blijven, "
             + "dus dit account kan alleen uit dienst worden gezet.",
        uren: urenAantal ?? 0, facturen: factuurAantal ?? 0, bewaren: true,
      }, 409);
    }

    // Niets te bewaren: alles mag weg.
    await admin.from("klus_aanmeldingen").delete().eq("gebruiker_id", uid);
    await admin.from("klus_gebruikers").delete().eq("gebruiker_id", uid);
    await admin.from("beschikbaarheid").delete().eq("gebruiker_id", uid);
    await admin.from("huisregels_akkoord").delete().eq("gebruiker_id", uid);
    await admin.from("gebruikers").delete().eq("id", uid);

    const { error: delErr } = await admin.auth.admin.deleteUser(uid);
    if (delErr) {
      return json({ error: "Inlog verwijderen mislukt: " + delErr.message }, 500);
    }

    return json({ success: true, verwijderd: uid });
  } catch (e) {
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
