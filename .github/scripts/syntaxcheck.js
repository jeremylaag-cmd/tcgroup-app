// Controleert of alle stukjes JavaScript in de HTML-bestanden geldig zijn.
// Wordt door de GitHub Action gedraaid vóór het publiceren: vindt hij een
// fout, dan stopt de publicatie en krijgt niemand een kapotte versie.
// Zelf draaien: node .github/scripts/syntaxcheck.js www/index.html web/open.html
const fs = require('fs');
const bestanden = process.argv.slice(2);
if (!bestanden.length) { console.error('Geef de bestanden mee.'); process.exit(2); }
let fouten = 0, blokken = 0;
for (const bestand of bestanden) {
  const html = fs.readFileSync(bestand, 'utf8');
  // Alleen gewone scriptblokken: geen src="", geen JSON en geen modules.
  const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let m, nr = 0;
  while ((m = re.exec(html))) {
    const attr = m[1] || '';
    if (/\bsrc\s*=/.test(attr)) continue;
    const type = (attr.match(/\btype\s*=\s*["']?([^"'\s>]+)/i) || [])[1];
    if (type && !/^(text|application)\/(javascript|ecmascript)$/i.test(type)) continue;
    nr++; blokken++;
    try { new Function(m[2]); }
    catch (e) {
      fouten++;
      const regel = html.slice(0, m.index).split('\n').length;
      console.error(`FOUT in ${bestand}, scriptblok ${nr} (begint op regel ${regel}): ${e.message}`);
    }
  }
}
console.log(`${blokken} scriptblokken bekeken, ${fouten} met een fout.`);
process.exit(fouten ? 1 : 0);
