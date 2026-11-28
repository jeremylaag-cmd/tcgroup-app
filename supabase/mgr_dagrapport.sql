-- Kraammanager kan bij het afsluiten van de dag een dagrapport (vrije tekst) meegeven. 28 nov 2026.
-- Toegepast als migratie `mgr_dagrapport`: kolom mcr_dagafsluiting.dagrapport, extra parameter
-- p_dagrapport op mgr_dag_afsluiten (oude functie gedropt, eigenaar app_rpc, execute voor
-- authenticated/service_role), 'dagrapport' in mcr_afsluitingen en mgr_afsluiting, en de
-- pushmelding "dag dicht" krijgt "· day report: <eerste 140 tekens>".
alter table public.mcr_dagafsluiting add column if not exists dagrapport text;
-- De functies zijn aangepast met replace() op pg_get_functiondef; zie de migratie in Supabase.
