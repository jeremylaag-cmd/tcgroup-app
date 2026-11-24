// Bewaakt de ene rekenregel voor "is deze klus vol?" (klusPlekken in
// www/index.html). Draait vóór elke publicatie; klopt een uitkomst niet meer,
// dan stopt de publicatie. Zelf draaien: node .github/scripts/bezettingtest.js
// De database rekent hetzelfde in klus_open_plekken()
// (supabase/nl_bezetting_een_regel.sql) — pas je de regel aan, doe het dan op
// beide plekken én hier.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2] || 'www/index.html', 'utf8');
const a = html.indexOf('// BEZETTING-BEGIN'), b = html.indexOf('// BEZETTING-EIND');
if (a < 0 || b < 0) { console.error('FOUT: het blok BEZETTING-BEGIN/EIND staat niet meer in de app.'); process.exit(1); }
const { klusPlekken, klusBezetting, openKlusBezetting } =
  new Function(html.slice(a, b) + '\nreturn {klusPlekken,klusBezetting,openKlusBezetting};')();

// [omschrijving, nodig op de klus, shifts [nodig,bezet], totaal bezet, kraam?, verwacht open, verwacht open "Hele klus"]
const gevallen = [
  ['zonder shifts, 7 van 10',                    10, [],            7, false, 3, 3],
  ['zonder shifts, vol',                          5, [],            5, false, 0, 0],
  ['zonder shifts, meer mensen dan gevraagd',     2, [],            3, false, 0, 0],
  ['Winterspektakel 17 dec (nov): shift vol, hele klus 5 van 7', 11, [[4, 4]], 9, false, 2, 2],
  ['shift vol 6/6, hele klus 5 van 6',           12, [[6, 6]],     11, false, 1, 1],
  ['shift 1/1, hele klus 10 van 11',             12, [[1, 1]],     11, false, 1, 1],
  ['shift overvol 5/4 neemt een plek mee',       12, [[4, 5]],     11, false, 1, 1],
  ['shift overvol, hele klus ook vol',            8, [[4, 5]],      9, false, 0, 0],
  ['shift nog open, hele klus vol',              10, [[5, 3]],      8, false, 2, 0],
  ['shifts vragen meer dan het totaal (Franklins)', 2, [[1, 1], [1, 1], [1, 0]], 2, false, 1, 0],
  ['overvolle shift vult een lege shift niet',    2, [[1, 2], [1, 0]], 2, false, 1, 0],
  ['geen aantal ingevuld',                        0, [],            0, false, 0, 0],
  ['kraam: geen "Hele klus"',                     4, [[1, 0], [1, 1]], 1, true, 1, 0],
];
let fout = 0;
for (const [naam, nodig, sh, bezet, kraam, open, restOpen] of gevallen) {
  const r = klusPlekken(nodig, sh.map(([n, b], i) => ({ id: 's' + i, nodig: n, bezet: b })), bezet, kraam);
  const goed = r.open === open && r.rest.open === restOpen && r.totaal - r.bezet === r.open && r.bezet === bezet;
  if (!goed) { fout++; console.error(`FOUT: ${naam}: open ${r.open} (verwacht ${open}), hele klus ${r.rest.open} (verwacht ${restOpen})`); }
}
// De twee ingangen (planbord met namen, Open klussen met aantallen) geven hetzelfde.
const k = { personeel_nodig: 12, shifts: [{ id: 'a', personeel_nodig: 6 }],
  personeel: [1, 2, 3, 4, 5].map(i => ({ id: 'p' + i, shift_id: null })),
  losse: [1, 2, 3, 4, 5, 6].map(i => ({ id: 'l' + i, shift_id: 'a' })) };
const o = { personeel_nodig: 12, bezet_aantal: 11, shifts: [{ id: 'a', personeel_nodig: 6, bezet: 6 }] };
if (klusBezetting(k).open !== 1 || openKlusBezetting(o).open !== 1) { fout++; console.error('FOUT: planbord en Open klussen rekenen niet hetzelfde.'); }

// Nergens anders mag de app zelf "nodig − bezet" uitrekenen voor NL-klussen.
const buiten = html.slice(0, a) + html.slice(b);
const verdacht = buiten.split('\n').map((r, i) => [i + 1, r])
  .filter(([, r]) => /\(k(lus)?\.personeel_nodig\|\|0\)\s*(>|-|<=|>=|<)/.test(r));
for (const [nr, r] of verdacht) { fout++; console.error(`FOUT: regel ${nr} rekent zelf met personeel_nodig; gebruik klusBezetting(): ${r.trim().slice(0, 120)}`); }

console.log(`${gevallen.length + 1} gevallen bekeken, ${fout} fout.`);
process.exit(fout ? 1 : 0);
