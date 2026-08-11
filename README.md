# TC Group Planning

iOS-app voor de personeelsplanning van TC Group. Capacitor-schil om één webapp
(`www/index.html`) heen, met Supabase als backend.

- App-ID: `com.tcgroup.planning`
- Backend: Supabase project **TC group Rooster** (`rxfrdocioodfxrnjtipa`)
- Distributie: unlisted in de App Store

## Een update uitrollen

Pas `www/index.html` aan en push naar `main`:

```bash
git add -A
git commit -m "Beschrijf kort wat je veranderd hebt"
git push
```

Dat is alles. De GitHub Action pakt de app in, geeft hem een nieuw versienummer
en zet hem op GitHub Pages. Zodra iemand de app opent, ziet die dat er een
nieuwe versie is, downloadt hem en herlaadt direct. **Geen App Store nodig.**

Volgen kan onder het tabblad **Actions** hier op GitHub. Het versienummer dat
draait staat onderaan het profielscherm in de app.

## Wanneer moet het tóch via de App Store?

Alleen als je iets aan de *native* laag verandert:

- een Capacitor-plugin toevoegen of updaten
- iets in `ios/` aanpassen (app-icoon, rechten, Info.plist)
- de Capacitor-versie ophogen

Alles wat in `www/index.html` zit — schermen, knoppen, logica, styling,
database-queries — gaat via GitHub.

## Terugrollen als een update stuk is

De app heeft een ingebouwd vangnet: start een nieuwe bundel niet goed op, dan
draait iOS automatisch terug naar de vorige werkende versie. Wil je het zelf
terugdraaien, dan draai je de wijziging in git terug en push je opnieuw:

```bash
git revert HEAD
git push
```

Binnen een paar minuten staat de vorige versie weer op alle telefoons.

## Lokaal draaien

```bash
npm install
npx cap sync ios
npx cap open ios
```

## Let op

- Supabase pauzeert dit project na ongeveer een week zonder gebruik. Staat de
  app stil, kijk dan eerst of het Supabase-project nog actief is.
- De regel `const APP_VERSION = '0.0.0-dev';` onderaan `www/index.html` niet
  aanpassen — die vult de GitHub Action automatisch in bij het publiceren.
