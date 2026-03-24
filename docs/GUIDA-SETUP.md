# FIM Gestionale v2 - Guida Setup

## Panoramica Architettura

```
[Browser / PWA]
      |
[Supabase Client SDK]
      |
[Supabase]
  ├── PostgreSQL (Database)
  │   ├── Schema relazionale completo
  │   ├── Viste materializzate (dashboard)
  │   ├── Funzioni PL/pgSQL (automazioni)
  │   └── pg_cron (scheduler)
  ├── Auth (JWT, login team FIM)
  ├── Storage (documenti, polizze PDF)
  ├── Edge Functions (Deno)
  │   ├── invia-comunicazioni (email/SMS)
  │   ├── migra-firebase (importazione dati)
  │   └── agente-ai (Claude API)
  └── Realtime (notifiche live)
```

## Step 1: Creare Progetto Supabase

1. Vai su https://supabase.com e crea un account (piano gratuito ok per iniziare)
2. Crea un nuovo progetto: "fim-gestionale"
3. Scegli la regione "West EU (Ireland)" per bassa latenza dall'Italia
4. Salva la password del database in un posto sicuro

## Step 2: Eseguire lo Schema SQL

1. Dal dashboard Supabase, vai su **SQL Editor**
2. Apri il file `sql/001_schema_completo.sql`
3. Copia e incolla tutto il contenuto nel SQL Editor
4. Clicca **Run** - dovrebbe creare tutte le tabelle, viste, trigger e dati iniziali

### Verifica:
```sql
SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;
```
Dovresti vedere: `adeguatezza_idd`, `attivita_agenti_ai`, `clienti`, `collaboratori`, `comunicazioni`, `compagnie`, `documenti`, `polizze`, `provvigioni_log`, `rami_assicurativi`, `sinistri`, `tabelle_provvigioni`, `workflow_scadenze`

## Step 3: Migrare Dati da Firebase

1. Vai su Firebase Console > Realtime Database
2. Clicca i 3 puntini > **Export JSON** per ciascun nodo (clienti, collaboratori, polizze)
3. Nel SQL Editor di Supabase, apri `sql/002_migrazione_firebase.sql` e eseguilo
4. Poi usa le funzioni di migrazione:

```sql
-- Sostituisci con il tuo JSON esportato da Firebase
SELECT fn_migra_collaboratori_firebase('{ CONTENUTO JSON COLLABORATORI }'::JSONB);
SELECT fn_migra_clienti_firebase('{ CONTENUTO JSON CLIENTI }'::JSONB);
SELECT fn_migra_polizze_firebase('{ CONTENUTO JSON POLIZZE }'::JSONB);

-- Verifica migrazione
SELECT 'clienti' AS tabella, COUNT(*) AS righe FROM clienti UNION ALL
SELECT 'collaboratori', COUNT(*) FROM collaboratori UNION ALL
SELECT 'polizze', COUNT(*) FROM polizze;
```

## Step 4: Configurare Automazione Scadenze

1. Nel SQL Editor, esegui `automazioni/workflow-scadenze.sql`
2. Abilita l'estensione pg_cron: Dashboard > Database > Extensions > cerca "pg_cron" > Enable
3. Crea il cron job:

```sql
SELECT cron.schedule(
    'fim-scadenze-giornaliere',
    '0 7 * * *',
    $$SELECT fn_processa_scadenze_giornaliere()$$
);

SELECT cron.schedule(
    'fim-provvigioni-mensili',
    '0 8 1 * *',
    $$SELECT fn_calcola_provvigioni_mensili()$$
);
```

## Step 5: Configurare Invio Email

1. Crea account su https://resend.com (piano gratuito: 100 email/giorno)
2. Verifica il dominio fimbroker.it su Resend
3. Copia la API key
4. Su Supabase: Dashboard > Edge Functions > Secrets, aggiungi:
   - `RESEND_API_KEY` = la tua API key Resend

5. Deploy della Edge Function:
```bash
supabase functions deploy invia-comunicazioni
```

6. Crea un cron che la invoca ogni 15 minuti:
```sql
SELECT cron.schedule(
    'fim-invio-comunicazioni',
    '*/15 7-20 * * *',  -- ogni 15 min dalle 7 alle 20
    $$SELECT net.http_post(
        url := 'https://TUO-PROGETTO.supabase.co/functions/v1/invia-comunicazioni',
        headers := '{"Authorization": "Bearer TUA-ANON-KEY"}'::JSONB
    )$$
);
```

## Step 6: Testare

### Test scadenze:
```sql
-- Inserisci una polizza di test che scade tra 30 giorni
INSERT INTO polizze (numero_polizza, cliente_id, compagnia_id, ramo_id,
    data_emissione, data_effetto, data_scadenza, premio_lordo)
VALUES ('TEST-001', 1, 1, 1, CURRENT_DATE - 335, CURRENT_DATE - 335, CURRENT_DATE + 30, 500.00);

-- Esegui il workflow manualmente
SELECT * FROM fn_processa_scadenze_giornaliere();

-- Verifica comunicazioni generate
SELECT * FROM comunicazioni ORDER BY creato_il DESC LIMIT 10;
```

### Test provvigioni:
```sql
SELECT * FROM fn_calcola_provvigioni_mensili();
SELECT * FROM v_provvigioni_mese;
```

### Test compliance IDD:
```sql
SELECT * FROM fn_verifica_compliance_idd();
```

### Dashboard KPI:
```sql
SELECT * FROM v_dashboard_kpi;
SELECT * FROM v_portafoglio_attivo WHERE semaforo IN ('CRITICA','URGENTE') ORDER BY giorni_alla_scadenza;
SELECT * FROM v_opportunita_cross_selling WHERE ramo_suggerito IS NOT NULL;
```

## Costi Stimati

| Servizio | Piano | Costo Mensile |
|----------|-------|---------------|
| Supabase | Free (500MB DB, 1GB storage) | 0 EUR |
| Supabase | Pro (8GB DB, 100GB storage) | ~25 EUR |
| Resend | Free (100 email/giorno) | 0 EUR |
| Resend | Pro (50K email/mese) | ~20 EUR |
| **Totale iniziale** | **Free tier** | **0 EUR** |
| **Totale produzione** | **Pro** | **~45 EUR/mese** |

## Struttura File

```
fim-gestionale-v2/
├── sql/
│   ├── 001_schema_completo.sql       # Schema database completo
│   └── 002_migrazione_firebase.sql   # Funzioni migrazione dati
├── automazioni/
│   ├── workflow-scadenze.sql         # Logica scadenze + provvigioni + IDD
│   └── edge-function-invia-email.ts  # Invio email/SMS via Resend
└── docs/
    └── GUIDA-SETUP.md                # Questa guida
```
