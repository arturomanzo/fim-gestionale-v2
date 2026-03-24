-- ============================================================
-- FIM INSURANCE BROKER - SCHEMA DATABASE POSTGRESQL
-- Versione: 2.0 | Data: 2026-03-24
-- Target: Supabase (PostgreSQL 15+)
-- ============================================================
-- Ordine esecuzione: questo file crea tutto lo schema da zero.
-- Per Supabase: incollare nel SQL Editor e eseguire.
-- ============================================================

-- Abilita estensioni necessarie
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- per ricerca fuzzy
CREATE EXTENSION IF NOT EXISTS "unaccent";        -- per ricerca senza accenti

-- ============================================================
-- TABELLE DI RIFERIMENTO (LOOKUP)
-- ============================================================

-- Compagnie assicurative partner FIM
CREATE TABLE compagnie (
    id              SERIAL PRIMARY KEY,
    codice          VARCHAR(20) UNIQUE NOT NULL,
    nome            VARCHAR(100) NOT NULL,
    nome_normalizzato VARCHAR(100) NOT NULL,  -- per matching (es. "Allianz" per tutte le varianti)
    tipo            VARCHAR(30) DEFAULT 'compagnia', -- compagnia, mga, coverholder
    email_ref       VARCHAR(150),
    telefono_ref    VARCHAR(30),
    portale_url     VARCHAR(300),
    note            TEXT,
    attiva          BOOLEAN DEFAULT TRUE,
    creato_il       TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il   TIMESTAMPTZ DEFAULT NOW()
);

-- Rami assicurativi
CREATE TABLE rami_assicurativi (
    id              SERIAL PRIMARY KEY,
    codice          VARCHAR(20) UNIQUE NOT NULL,
    nome            VARCHAR(100) NOT NULL,
    categoria       VARCHAR(30) NOT NULL CHECK (categoria IN ('auto','vita','danni','responsabilita','altro')),
    descrizione     TEXT,
    attivo          BOOLEAN DEFAULT TRUE
);

-- ============================================================
-- COLLABORATORI / SUBAGENTI
-- ============================================================

CREATE TABLE collaboratori (
    id              SERIAL PRIMARY KEY,
    uuid_firebase   VARCHAR(100) UNIQUE,  -- per migrazione da Firebase
    codice          VARCHAR(20) UNIQUE NOT NULL,
    cognome         VARCHAR(100) NOT NULL,
    nome            VARCHAR(100) NOT NULL,
    codice_rui      VARCHAR(30),          -- Sez. E del RUI
    ruolo           VARCHAR(30) NOT NULL DEFAULT 'subagente' CHECK (ruolo IN ('titolare','subagente','collaboratore','segnalatore')),
    email           VARCHAR(150),
    telefono        VARCHAR(30),
    indirizzo       VARCHAR(200),
    citta           VARCHAR(100),
    provincia       VARCHAR(2),
    data_nomina     DATE,
    data_cessazione DATE,
    attivo          BOOLEAN DEFAULT TRUE,
    -- Provvigioni base
    perc_provv_default DECIMAL(5,2) DEFAULT 7.00,
    note            TEXT,
    creato_il       TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il   TIMESTAMPTZ DEFAULT NOW()
);

-- Tabella provvigioni per collaboratore/ramo (sostituisce provTable + indivProvTables)
CREATE TABLE tabelle_provvigioni (
    id                  SERIAL PRIMARY KEY,
    collaboratore_id    INT REFERENCES collaboratori(id) ON DELETE CASCADE,
    ramo_id             INT REFERENCES rami_assicurativi(id) ON DELETE CASCADE,
    compagnia_id        INT REFERENCES compagnie(id) ON DELETE SET NULL,
    percentuale         DECIMAL(5,2) NOT NULL,
    valido_dal          DATE NOT NULL DEFAULT CURRENT_DATE,
    valido_al           DATE,  -- NULL = valido indefinitamente
    note                TEXT,
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(collaboratore_id, ramo_id, compagnia_id, valido_dal)
);

-- ============================================================
-- ANAGRAFICA CLIENTI
-- ============================================================

CREATE TABLE clienti (
    id                  SERIAL PRIMARY KEY,
    uuid_firebase       VARCHAR(100) UNIQUE,  -- per migrazione
    tipo                VARCHAR(20) NOT NULL CHECK (tipo IN ('privato','azienda','professionista')),
    -- Persona fisica
    cognome             VARCHAR(100),
    nome                VARCHAR(100),
    codice_fiscale      VARCHAR(16),
    data_nascita        DATE,
    luogo_nascita       VARCHAR(100),
    sesso               CHAR(1) CHECK (sesso IN ('M','F')),
    -- Azienda / Professionista
    ragione_sociale     VARCHAR(200),
    partita_iva         VARCHAR(11),
    codice_ateco        VARCHAR(10),
    pec                 VARCHAR(150),
    codice_sdi          VARCHAR(7),
    -- Contatti
    telefono            VARCHAR(30),
    cellulare           VARCHAR(30),
    email               VARCHAR(150),
    -- Indirizzo
    indirizzo           VARCHAR(200),
    cap                 VARCHAR(5),
    citta               VARCHAR(100),
    provincia           VARCHAR(2),
    -- Gestione FIM
    collaboratore_id    INT REFERENCES collaboratori(id) ON DELETE SET NULL,
    fonte_acquisizione  VARCHAR(50),  -- web, referral, subagente, evento, altro
    consenso_marketing  BOOLEAN DEFAULT FALSE,
    consenso_profilazione BOOLEAN DEFAULT FALSE,
    data_consenso       TIMESTAMPTZ,
    -- Score e analytics
    score_cliente       INT DEFAULT 50 CHECK (score_cliente BETWEEN 0 AND 100),
    lifetime_value      DECIMAL(12,2) DEFAULT 0,
    n_polizze_attive    INT DEFAULT 0,  -- campo calcolato, aggiornato da trigger
    -- Note e audit
    note                TEXT,
    tags                TEXT[],  -- array PostgreSQL per tag flessibili
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il       TIMESTAMPTZ DEFAULT NOW(),
    eliminato_il        TIMESTAMPTZ,  -- soft delete
    -- Indici per ricerca
    CONSTRAINT chk_cf_unique UNIQUE (codice_fiscale) DEFERRABLE,
    CONSTRAINT chk_piva_unique UNIQUE (partita_iva) DEFERRABLE
);

-- Indice full-text per ricerca clienti
CREATE INDEX idx_clienti_ricerca ON clienti USING GIN (
    to_tsvector('italian', COALESCE(cognome,'') || ' ' || COALESCE(nome,'') || ' ' || COALESCE(ragione_sociale,''))
);
CREATE INDEX idx_clienti_cf ON clienti(codice_fiscale) WHERE codice_fiscale IS NOT NULL;
CREATE INDEX idx_clienti_collaboratore ON clienti(collaboratore_id);
CREATE INDEX idx_clienti_attivi ON clienti(eliminato_il) WHERE eliminato_il IS NULL;

-- ============================================================
-- POLIZZE
-- ============================================================

CREATE TABLE polizze (
    id                  SERIAL PRIMARY KEY,
    uuid_firebase       VARCHAR(100) UNIQUE,
    numero_polizza      VARCHAR(50) NOT NULL,
    cliente_id          INT NOT NULL REFERENCES clienti(id) ON DELETE RESTRICT,
    compagnia_id        INT NOT NULL REFERENCES compagnie(id) ON DELETE RESTRICT,
    ramo_id             INT NOT NULL REFERENCES rami_assicurativi(id) ON DELETE RESTRICT,
    collaboratore_id    INT REFERENCES collaboratori(id) ON DELETE SET NULL,
    -- Date
    data_emissione      DATE NOT NULL,
    data_effetto        DATE NOT NULL,
    data_scadenza       DATE NOT NULL,
    data_disdetta       DATE,
    -- Tipo
    stato               VARCHAR(20) NOT NULL DEFAULT 'attiva' CHECK (stato IN ('attiva','scaduta','annullata','sospesa','in_rinnovo','disdettata')),
    tipo_emissione      VARCHAR(20) DEFAULT 'nuova' CHECK (tipo_emissione IN ('nuova','rinnovo','sostituzione','rata','appendice')),
    frazionamento       VARCHAR(15) DEFAULT 'annuale' CHECK (frazionamento IN ('annuale','semestrale','trimestrale','mensile','unica')),
    tacito_rinnovo      BOOLEAN DEFAULT TRUE,
    -- Importi
    premio_lordo        DECIMAL(10,2) NOT NULL,
    imposte             DECIMAL(10,2) DEFAULT 0,
    ssn                 DECIMAL(10,2) DEFAULT 0,
    imponibile          DECIMAL(10,2),  -- calcolato: premio_lordo - imposte - ssn
    -- Provvigioni
    perc_provvigione    DECIMAL(5,2),
    provvigione         DECIMAL(10,2),
    perc_provv_subagente DECIMAL(5,2),
    provv_subagente     DECIMAL(10,2),
    -- Dettagli specifici per ramo (JSON flessibile)
    dettagli_ramo       JSONB DEFAULT '{}',
    -- Es. per RCA: {"targa": "AB123CD", "classe_cu": "1", "marca": "Fiat", "modello": "500"}
    -- Es. per RC Prof: {"professione": "Avvocato", "fatturato": 150000, "retroattivita": "illimitata"}
    -- Documenti collegati
    note                TEXT,
    -- Rinnovo tracking
    polizza_precedente_id INT REFERENCES polizze(id) ON DELETE SET NULL,
    -- Audit
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il       TIMESTAMPTZ DEFAULT NOW(),
    eliminato_il        TIMESTAMPTZ,
    -- Indici
    CONSTRAINT uk_polizza_numero UNIQUE (numero_polizza, compagnia_id)
);

CREATE INDEX idx_polizze_cliente ON polizze(cliente_id);
CREATE INDEX idx_polizze_scadenza ON polizze(data_scadenza);
CREATE INDEX idx_polizze_stato ON polizze(stato);
CREATE INDEX idx_polizze_compagnia ON polizze(compagnia_id);
CREATE INDEX idx_polizze_collaboratore ON polizze(collaboratore_id);
CREATE INDEX idx_polizze_attive ON polizze(stato, data_scadenza) WHERE stato = 'attiva' AND eliminato_il IS NULL;
CREATE INDEX idx_polizze_dettagli ON polizze USING GIN (dettagli_ramo);

-- ============================================================
-- SINISTRI
-- ============================================================

CREATE TABLE sinistri (
    id                  SERIAL PRIMARY KEY,
    numero_sinistro     VARCHAR(50),
    polizza_id          INT NOT NULL REFERENCES polizze(id) ON DELETE RESTRICT,
    cliente_id          INT NOT NULL REFERENCES clienti(id) ON DELETE RESTRICT,
    compagnia_id        INT NOT NULL REFERENCES compagnie(id) ON DELETE RESTRICT,
    -- Date
    data_evento         DATE NOT NULL,
    data_denuncia       DATE,
    data_apertura       DATE DEFAULT CURRENT_DATE,
    data_chiusura       DATE,
    -- Dettagli
    descrizione         TEXT NOT NULL,
    tipo_sinistro       VARCHAR(50),  -- furto, incendio, rca_attivo, rca_passivo, rc_terzi, ecc.
    stato               VARCHAR(20) DEFAULT 'aperto' CHECK (stato IN ('aperto','in_istruttoria','liquidato','respinto','chiuso','riaperto')),
    -- Importi
    riserva             DECIMAL(12,2),
    importo_liquidato   DECIMAL(12,2),
    franchigia_applicata DECIMAL(10,2),
    -- Responsabilita' (per RCA)
    responsabilita      VARCHAR(20) CHECK (responsabilita IN ('totale','parziale','nessuna','in_valutazione')),
    controparte         TEXT,  -- dati controparte JSON
    -- Gestione
    perito_nome         VARCHAR(100),
    perito_contatto     VARCHAR(150),
    numero_pratica_compagnia VARCHAR(50),
    note                TEXT,
    -- Audit
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il       TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_sinistri_polizza ON sinistri(polizza_id);
CREATE INDEX idx_sinistri_cliente ON sinistri(cliente_id);
CREATE INDEX idx_sinistri_stato ON sinistri(stato);

-- ============================================================
-- PROVVIGIONI LOG (registro immutabile)
-- ============================================================

CREATE TABLE provvigioni_log (
    id                  SERIAL PRIMARY KEY,
    polizza_id          INT NOT NULL REFERENCES polizze(id) ON DELETE RESTRICT,
    collaboratore_id    INT REFERENCES collaboratori(id) ON DELETE SET NULL,
    -- Calcolo
    periodo             VARCHAR(7) NOT NULL,  -- es. '2026-03'
    tipo                VARCHAR(20) NOT NULL CHECK (tipo IN ('maturata','pagata','stornata','chargeback')),
    imponibile          DECIMAL(10,2) NOT NULL,
    percentuale         DECIMAL(5,2) NOT NULL,
    importo             DECIMAL(10,2) NOT NULL,
    -- Riferimento
    fonte_dati          VARCHAR(50),  -- 'calcolo_automatico', 'estratto_conto_compagnia', 'manuale'
    numero_quietanza    VARCHAR(50),
    data_incasso        DATE,
    -- Riconciliazione
    riconciliato        BOOLEAN DEFAULT FALSE,
    data_riconciliazione TIMESTAMPTZ,
    differenza_compagnia DECIMAL(10,2),  -- differenza vs estratto conto compagnia
    note                TEXT,
    -- Audit (immutabile - no UPDATE)
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    creato_da           VARCHAR(100) DEFAULT 'sistema'
);

CREATE INDEX idx_provvigioni_periodo ON provvigioni_log(periodo);
CREATE INDEX idx_provvigioni_collaboratore ON provvigioni_log(collaboratore_id, periodo);
CREATE INDEX idx_provvigioni_polizza ON provvigioni_log(polizza_id);
CREATE INDEX idx_provvigioni_non_riconciliate ON provvigioni_log(riconciliato) WHERE riconciliato = FALSE;

-- ============================================================
-- COMUNICAZIONI (log email/SMS)
-- ============================================================

CREATE TABLE comunicazioni (
    id                  SERIAL PRIMARY KEY,
    cliente_id          INT REFERENCES clienti(id) ON DELETE SET NULL,
    polizza_id          INT REFERENCES polizze(id) ON DELETE SET NULL,
    collaboratore_id    INT REFERENCES collaboratori(id) ON DELETE SET NULL,
    -- Comunicazione
    canale              VARCHAR(10) NOT NULL CHECK (canale IN ('email','sms','whatsapp','pec','telefono','posta')),
    tipo                VARCHAR(30) NOT NULL,  -- scadenza_60gg, scadenza_30gg, scadenza_7gg, benvenuto, rinnovo, cross_selling, auguri, sollecito, generico
    direzione           VARCHAR(10) DEFAULT 'uscita' CHECK (direzione IN ('uscita','entrata')),
    -- Contenuto
    oggetto             VARCHAR(200),
    corpo               TEXT,
    destinatario        VARCHAR(200),
    -- Stato
    stato               VARCHAR(15) DEFAULT 'inviato' CHECK (stato IN ('bozza','programmato','inviato','consegnato','letto','errore','annullato')),
    data_programmata    TIMESTAMPTZ,
    data_invio          TIMESTAMPTZ,
    errore_dettaglio    TEXT,
    -- Automazione
    generato_da         VARCHAR(50) DEFAULT 'manuale',  -- manuale, workflow_scadenze, workflow_benvenuto, agente_ai
    workflow_id         VARCHAR(100),
    -- Audit
    creato_il           TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_comunicazioni_cliente ON comunicazioni(cliente_id);
CREATE INDEX idx_comunicazioni_tipo ON comunicazioni(tipo, data_invio);
CREATE INDEX idx_comunicazioni_stato ON comunicazioni(stato);

-- ============================================================
-- ADEGUATEZZA IDD (compliance IVASS)
-- ============================================================

CREATE TABLE adeguatezza_idd (
    id                      SERIAL PRIMARY KEY,
    cliente_id              INT NOT NULL REFERENCES clienti(id) ON DELETE RESTRICT,
    polizza_id              INT REFERENCES polizze(id) ON DELETE SET NULL,
    collaboratore_id        INT REFERENCES collaboratori(id) ON DELETE SET NULL,
    -- Questionario
    data_compilazione       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    risposte_questionario   JSONB NOT NULL,
    -- Esigenze identificate
    profilo_rischio         VARCHAR(20) CHECK (profilo_rischio IN ('basso','medio','alto','molto_alto')),
    esigenze_identificate   TEXT[],
    coperture_richieste     TEXT[],
    -- Valutazione
    prodotto_proposto       VARCHAR(200),
    compagnia_proposta      VARCHAR(100),
    adeguato                BOOLEAN NOT NULL,
    motivazione_adeguatezza TEXT NOT NULL,
    gap_identificati        TEXT[],
    -- Documentazione consegnata
    dip_consegnato          BOOLEAN DEFAULT FALSE,
    kid_consegnato          BOOLEAN DEFAULT FALSE,
    ipid_consegnato         BOOLEAN DEFAULT FALSE,
    conflitti_dichiarati    BOOLEAN DEFAULT FALSE,
    remunerazione_comunicata BOOLEAN DEFAULT FALSE,
    -- Firma
    firma_cliente           BOOLEAN DEFAULT FALSE,
    data_firma              TIMESTAMPTZ,
    metodo_firma            VARCHAR(20) CHECK (metodo_firma IN ('cartacea','digitale','otp')),
    -- Documento PDF generato
    documento_url           VARCHAR(500),
    -- Audit (conservazione 10 anni - Reg. IVASS 41/2018)
    creato_il               TIMESTAMPTZ DEFAULT NOW(),
    creato_da               VARCHAR(100),
    -- Scadenza conservazione
    conservare_fino_al      DATE GENERATED ALWAYS AS (CAST(data_compilazione AS DATE) + INTERVAL '10 years') STORED
);

CREATE INDEX idx_idd_cliente ON adeguatezza_idd(cliente_id);
CREATE INDEX idx_idd_polizza ON adeguatezza_idd(polizza_id);
CREATE INDEX idx_idd_data ON adeguatezza_idd(data_compilazione);
CREATE INDEX idx_idd_non_firmati ON adeguatezza_idd(firma_cliente) WHERE firma_cliente = FALSE;

-- ============================================================
-- DOCUMENTI (repository centralizzato)
-- ============================================================

CREATE TABLE documenti (
    id                  SERIAL PRIMARY KEY,
    cliente_id          INT REFERENCES clienti(id) ON DELETE SET NULL,
    polizza_id          INT REFERENCES polizze(id) ON DELETE SET NULL,
    sinistro_id         INT REFERENCES sinistri(id) ON DELETE SET NULL,
    -- Documento
    nome_file           VARCHAR(200) NOT NULL,
    tipo_documento      VARCHAR(50) NOT NULL,  -- polizza, quietanza, denuncia_sinistro, idd, dip, carta_identita, visura, attestato_rischio, preventivo, altro
    mime_type           VARCHAR(100),
    dimensione_bytes    INT,
    storage_url         VARCHAR(500) NOT NULL,  -- URL Supabase Storage
    -- Metadata
    descrizione         TEXT,
    tags                TEXT[],
    versione            INT DEFAULT 1,
    -- Audit
    caricato_da         VARCHAR(100),
    creato_il           TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_documenti_cliente ON documenti(cliente_id);
CREATE INDEX idx_documenti_polizza ON documenti(polizza_id);
CREATE INDEX idx_documenti_tipo ON documenti(tipo_documento);

-- ============================================================
-- ATTIVITA' AGENTI AI (audit trail)
-- ============================================================

CREATE TABLE attivita_agenti_ai (
    id                  SERIAL PRIMARY KEY,
    agente              VARCHAR(50) NOT NULL,  -- fima_underwriting, fima_scadenze, fima_documenti, fima_crossselling, fima_sinistri
    azione              VARCHAR(100) NOT NULL,
    -- Contesto
    cliente_id          INT REFERENCES clienti(id) ON DELETE SET NULL,
    polizza_id          INT REFERENCES polizze(id) ON DELETE SET NULL,
    -- Input/Output
    input_dati          JSONB,
    output_dati         JSONB,
    decisione           TEXT,
    confidenza          DECIMAL(3,2),  -- 0.00 - 1.00
    -- Performance
    tempo_esecuzione_ms INT,
    tokens_utilizzati   INT,
    costo_stimato       DECIMAL(6,4),  -- in EUR
    -- Stato
    stato               VARCHAR(15) DEFAULT 'completato' CHECK (stato IN ('in_corso','completato','errore','annullato')),
    errore              TEXT,
    -- Revisione umana
    revisionato         BOOLEAN DEFAULT FALSE,
    revisionato_da      VARCHAR(100),
    data_revisione      TIMESTAMPTZ,
    esito_revisione     VARCHAR(20) CHECK (esito_revisione IN ('approvato','modificato','rifiutato')),
    -- Audit (EU AI Act compliance)
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    modello_ai          VARCHAR(50),  -- claude-sonnet-4-6, ecc.
    versione_prompt     VARCHAR(20)
);

CREATE INDEX idx_ai_agente ON attivita_agenti_ai(agente, creato_il);
CREATE INDEX idx_ai_cliente ON attivita_agenti_ai(cliente_id);
CREATE INDEX idx_ai_non_revisionati ON attivita_agenti_ai(revisionato) WHERE revisionato = FALSE;

-- ============================================================
-- WORKFLOW SCADENZE (configurazione automazioni)
-- ============================================================

CREATE TABLE workflow_scadenze (
    id                  SERIAL PRIMARY KEY,
    nome                VARCHAR(100) NOT NULL,
    attivo              BOOLEAN DEFAULT TRUE,
    -- Trigger
    giorni_prima_scadenza INT NOT NULL,  -- 60, 30, 7, 0, -7 (dopo scadenza)
    -- Azioni
    invia_email_cliente     BOOLEAN DEFAULT FALSE,
    invia_sms_cliente       BOOLEAN DEFAULT FALSE,
    invia_whatsapp_cliente  BOOLEAN DEFAULT FALSE,
    notifica_collaboratore  BOOLEAN DEFAULT FALSE,
    genera_preventivo       BOOLEAN DEFAULT FALSE,
    -- Template
    template_email      TEXT,
    template_sms        TEXT,
    -- Filtri
    solo_rami           INT[],  -- NULL = tutti i rami
    solo_compagnie      INT[],  -- NULL = tutte
    escludi_stati       TEXT[] DEFAULT ARRAY['annullata','disdettata'],
    -- Audit
    creato_il           TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il       TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- VISTE MATERIALIZZATE PER PERFORMANCE
-- ============================================================

-- Vista: portafoglio attivo con semaforo scadenza
CREATE OR REPLACE VIEW v_portafoglio_attivo AS
SELECT
    c.id AS cliente_id,
    COALESCE(CONCAT(c.cognome, ' ', c.nome), c.ragione_sociale) AS cliente,
    c.tipo AS tipo_cliente,
    c.email,
    c.cellulare,
    p.id AS polizza_id,
    p.numero_polizza,
    r.codice AS ramo_codice,
    r.nome AS ramo,
    comp.nome AS compagnia,
    comp.nome_normalizzato AS compagnia_normalizzata,
    p.data_effetto,
    p.data_scadenza,
    (p.data_scadenza - CURRENT_DATE) AS giorni_alla_scadenza,
    p.stato,
    p.frazionamento,
    p.premio_lordo,
    p.imponibile,
    p.provvigione,
    p.perc_provvigione,
    COALESCE(CONCAT(col.cognome, ' ', col.nome), 'Diretto FIM') AS collaboratore,
    col.id AS collaboratore_id,
    col.codice AS codice_collaboratore,
    CASE
        WHEN p.data_scadenza < CURRENT_DATE                    THEN 'SCADUTA'
        WHEN (p.data_scadenza - CURRENT_DATE) <= 7             THEN 'CRITICA'
        WHEN (p.data_scadenza - CURRENT_DATE) <= 30            THEN 'URGENTE'
        WHEN (p.data_scadenza - CURRENT_DATE) <= 60            THEN 'IN_SCADENZA'
        ELSE 'OK'
    END AS semaforo
FROM polizze p
JOIN clienti c ON c.id = p.cliente_id
JOIN compagnie comp ON comp.id = p.compagnia_id
JOIN rami_assicurativi r ON r.id = p.ramo_id
LEFT JOIN collaboratori col ON col.id = p.collaboratore_id
WHERE p.stato = 'attiva'
  AND p.eliminato_il IS NULL
  AND c.eliminato_il IS NULL;

-- Vista: riepilogo provvigioni per collaboratore e mese
CREATE OR REPLACE VIEW v_provvigioni_mese AS
SELECT
    col.id AS collaboratore_id,
    col.codice,
    CONCAT(col.cognome, ' ', col.nome) AS collaboratore,
    pl.periodo,
    pl.tipo,
    COUNT(*) AS n_movimenti,
    SUM(pl.imponibile) AS totale_imponibile,
    SUM(pl.importo) AS totale_provvigioni,
    SUM(CASE WHEN pl.riconciliato THEN pl.importo ELSE 0 END) AS provvigioni_riconciliate,
    SUM(CASE WHEN NOT pl.riconciliato THEN pl.importo ELSE 0 END) AS provvigioni_da_riconciliare
FROM provvigioni_log pl
LEFT JOIN collaboratori col ON col.id = pl.collaboratore_id
GROUP BY col.id, col.codice, col.cognome, col.nome, pl.periodo, pl.tipo;

-- Vista: dashboard KPI
CREATE OR REPLACE VIEW v_dashboard_kpi AS
SELECT
    -- Portafoglio
    COUNT(*) FILTER (WHERE stato = 'attiva') AS polizze_attive,
    COUNT(DISTINCT cliente_id) FILTER (WHERE stato = 'attiva') AS clienti_attivi,
    SUM(premio_lordo) FILTER (WHERE stato = 'attiva') AS premi_totali,
    SUM(provvigione) FILTER (WHERE stato = 'attiva') AS provvigioni_totali,
    -- Scadenze
    COUNT(*) FILTER (WHERE stato = 'attiva' AND data_scadenza BETWEEN CURRENT_DATE AND CURRENT_DATE + 7) AS scadenze_7gg,
    COUNT(*) FILTER (WHERE stato = 'attiva' AND data_scadenza BETWEEN CURRENT_DATE AND CURRENT_DATE + 30) AS scadenze_30gg,
    COUNT(*) FILTER (WHERE stato = 'attiva' AND data_scadenza BETWEEN CURRENT_DATE AND CURRENT_DATE + 60) AS scadenze_60gg,
    COUNT(*) FILTER (WHERE stato = 'attiva' AND data_scadenza < CURRENT_DATE) AS polizze_scadute,
    -- Performance
    AVG(premio_lordo) FILTER (WHERE stato = 'attiva') AS premio_medio,
    AVG(perc_provvigione) FILTER (WHERE stato = 'attiva') AS provvigione_media_perc
FROM polizze
WHERE eliminato_il IS NULL;

-- Vista: opportunita' cross-selling
CREATE OR REPLACE VIEW v_opportunita_cross_selling AS
WITH rami_cliente AS (
    SELECT
        c.id AS cliente_id,
        COALESCE(CONCAT(c.cognome, ' ', c.nome), c.ragione_sociale) AS cliente,
        c.tipo AS tipo_cliente,
        c.email,
        c.cellulare,
        COALESCE(CONCAT(col.cognome, ' ', col.nome), 'Diretto FIM') AS collaboratore,
        array_agg(DISTINCT r.codice) AS rami_attivi,
        COUNT(DISTINCT p.id) AS n_polizze,
        SUM(p.premio_lordo) AS premi_totali
    FROM clienti c
    JOIN polizze p ON p.cliente_id = c.id AND p.stato = 'attiva' AND p.eliminato_il IS NULL
    JOIN rami_assicurativi r ON r.id = p.ramo_id
    LEFT JOIN collaboratori col ON col.id = c.collaboratore_id
    WHERE c.eliminato_il IS NULL
    GROUP BY c.id, c.cognome, c.nome, c.ragione_sociale, c.tipo, c.email, c.cellulare, col.cognome, col.nome
)
SELECT
    rc.*,
    CASE
        WHEN rc.tipo_cliente = 'privato' AND NOT 'RCA' = ANY(rc.rami_attivi) THEN 'RCA Auto'
        WHEN rc.tipo_cliente = 'privato' AND NOT 'CASA' = ANY(rc.rami_attivi) THEN 'Casa e Patrimonio'
        WHEN rc.tipo_cliente = 'privato' AND NOT 'INFORTUNI' = ANY(rc.rami_attivi) THEN 'Infortuni'
        WHEN rc.tipo_cliente = 'privato' AND NOT 'VITA' = ANY(rc.rami_attivi) THEN 'Vita / Previdenza'
        WHEN rc.tipo_cliente IN ('azienda','professionista') AND NOT 'RC_PROF' = ANY(rc.rami_attivi) THEN 'RC Professionale'
        WHEN rc.tipo_cliente = 'azienda' AND NOT 'MULTIRISCHIO' = ANY(rc.rami_attivi) THEN 'Multirischio Impresa'
        ELSE NULL
    END AS ramo_suggerito
FROM rami_cliente rc;

-- ============================================================
-- FUNZIONI E TRIGGER
-- ============================================================

-- Funzione: aggiorna timestamp
CREATE OR REPLACE FUNCTION fn_aggiorna_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.aggiornato_il = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger aggiornamento timestamp
CREATE TRIGGER trg_clienti_timestamp BEFORE UPDATE ON clienti FOR EACH ROW EXECUTE FUNCTION fn_aggiorna_timestamp();
CREATE TRIGGER trg_polizze_timestamp BEFORE UPDATE ON polizze FOR EACH ROW EXECUTE FUNCTION fn_aggiorna_timestamp();
CREATE TRIGGER trg_collaboratori_timestamp BEFORE UPDATE ON collaboratori FOR EACH ROW EXECUTE FUNCTION fn_aggiorna_timestamp();
CREATE TRIGGER trg_compagnie_timestamp BEFORE UPDATE ON compagnie FOR EACH ROW EXECUTE FUNCTION fn_aggiorna_timestamp();

-- Funzione: calcola imponibile polizza
CREATE OR REPLACE FUNCTION fn_calcola_imponibile()
RETURNS TRIGGER AS $$
BEGIN
    NEW.imponibile = NEW.premio_lordo - COALESCE(NEW.imposte, 0) - COALESCE(NEW.ssn, 0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_polizze_imponibile BEFORE INSERT OR UPDATE OF premio_lordo, imposte, ssn ON polizze FOR EACH ROW EXECUTE FUNCTION fn_calcola_imponibile();

-- Funzione: aggiorna contatore polizze attive per cliente
CREATE OR REPLACE FUNCTION fn_aggiorna_n_polizze()
RETURNS TRIGGER AS $$
BEGIN
    -- Aggiorna il vecchio cliente (se cambiato)
    IF TG_OP = 'UPDATE' AND OLD.cliente_id IS DISTINCT FROM NEW.cliente_id THEN
        UPDATE clienti SET n_polizze_attive = (
            SELECT COUNT(*) FROM polizze WHERE cliente_id = OLD.cliente_id AND stato = 'attiva' AND eliminato_il IS NULL
        ) WHERE id = OLD.cliente_id;
    END IF;
    -- Aggiorna il nuovo/corrente cliente
    IF TG_OP IN ('INSERT','UPDATE') THEN
        UPDATE clienti SET n_polizze_attive = (
            SELECT COUNT(*) FROM polizze WHERE cliente_id = NEW.cliente_id AND stato = 'attiva' AND eliminato_il IS NULL
        ) WHERE id = NEW.cliente_id;
    END IF;
    IF TG_OP = 'DELETE' THEN
        UPDATE clienti SET n_polizze_attive = (
            SELECT COUNT(*) FROM polizze WHERE cliente_id = OLD.cliente_id AND stato = 'attiva' AND eliminato_il IS NULL
        ) WHERE id = OLD.cliente_id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_polizze_count AFTER INSERT OR UPDATE OF stato, cliente_id, eliminato_il OR DELETE ON polizze FOR EACH ROW EXECUTE FUNCTION fn_aggiorna_n_polizze();

-- ============================================================
-- FUNZIONE: Calcolo Provvigioni Automatico
-- ============================================================

CREATE OR REPLACE FUNCTION fn_calcola_provvigione_polizza(p_polizza_id INT)
RETURNS TABLE(collaboratore_id INT, percentuale DECIMAL, importo DECIMAL) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.collaboratore_id,
        COALESCE(
            tp.percentuale,
            col.perc_provv_default,
            0
        ) AS percentuale,
        ROUND(
            COALESCE(p.imponibile, p.premio_lordo) *
            COALESCE(tp.percentuale, col.perc_provv_default, 0) / 100,
            2
        ) AS importo
    FROM polizze p
    LEFT JOIN collaboratori col ON col.id = p.collaboratore_id
    LEFT JOIN tabelle_provvigioni tp ON tp.collaboratore_id = p.collaboratore_id
        AND tp.ramo_id = p.ramo_id
        AND (tp.compagnia_id = p.compagnia_id OR tp.compagnia_id IS NULL)
        AND tp.valido_dal <= CURRENT_DATE
        AND (tp.valido_al IS NULL OR tp.valido_al >= CURRENT_DATE)
    WHERE p.id = p_polizza_id
    ORDER BY tp.compagnia_id NULLS LAST  -- priorita': specifico compagnia > generico
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- DATI INIZIALI
-- ============================================================

-- Compagnie FIM
INSERT INTO compagnie (codice, nome, nome_normalizzato, tipo) VALUES
('ALLIANZ',     'Allianz S.p.A.',               'Allianz',              'compagnia'),
('ALZ_DIRECT',  'Allianz Direct',               'Allianz',              'compagnia'),
('PRIMA',       'Prima Assicurazioni S.p.A.',   'Great Lakes (Prima)',  'compagnia'),
('GLI',         'Great Lakes Insurance SE',      'Great Lakes (Prima)',  'compagnia'),
('BENE',        'Bene Assicurazioni S.p.A.',    'Bene Assicurazioni',   'compagnia'),
('DUAL',        'DUAL/Arch Insurance',           'DUAL/Arch',            'mga'),
('WAKAM',       'WAKAM S.A.',                    'WAKAM',                'compagnia'),
('DALLBOGG',    'Dallbogg Life and Health',      'Dallbogg',             'compagnia');

-- Rami assicurativi
INSERT INTO rami_assicurativi (codice, nome, categoria) VALUES
('RCA',         'RCA',                          'auto'),
('RCA_FI',      'RCA + Furto/Incendio',         'auto'),
('KASKO',       'Kasko',                        'auto'),
('RC_PROF',     'RC Professionale',             'responsabilita'),
('RC_AZIENDA',  'RC Azienda',                   'responsabilita'),
('DO',          'D&O (Directors & Officers)',    'responsabilita'),
('CYBER',       'Cyber Risk',                   'responsabilita'),
('VITA',        'Vita',                         'vita'),
('LTC',         'Long Term Care',               'vita'),
('PREV',        'Previdenza Integrativa',       'vita'),
('INFORTUNI',   'Infortuni',                    'danni'),
('CASA',        'Casa e Patrimonio',            'danni'),
('CATASTROFALI','Catastrofali',                 'danni'),
('MULTIRISCHIO','Multirischio Impresa',         'danni'),
('TRASPORTI',   'Trasporti e Merci',            'danni'),
('CONSULENZA',  'Oneri Gestione/Consulenza',    'altro');

-- Workflow scadenze predefiniti
INSERT INTO workflow_scadenze (nome, giorni_prima_scadenza, invia_email_cliente, notifica_collaboratore, genera_preventivo, template_email, template_sms) VALUES
('Alert 60 giorni', 60, FALSE, TRUE, FALSE,
 NULL,
 NULL),
('Alert 30 giorni', 30, TRUE, TRUE, TRUE,
 'Gentile {cliente_nome},\n\nLe ricordiamo che la Sua polizza {ramo} n. {numero_polizza} presso {compagnia} e'' in scadenza il {data_scadenza}.\n\nIl Suo consulente FIM si occupera'' di verificare le migliori condizioni di rinnovo.\n\nPer qualsiasi informazione:\nTel: {collaboratore_tel}\nEmail: {collaboratore_email}\n\nCordiali saluti,\nFIM Insurance Broker S.A.S.\nRUI Sez. B - N. B000405449',
 'FIM Broker: la polizza {ramo} n.{numero_polizza} scade il {data_scadenza}. Il suo consulente la contattera'' per il rinnovo. Info: 06-XXXXXXX'),
('Alert 7 giorni URGENTE', 7, TRUE, TRUE, FALSE,
 'Gentile {cliente_nome},\n\nATTENZIONE: la Sua polizza {ramo} n. {numero_polizza} scadra'' tra 7 giorni ({data_scadenza}).\n\nLa preghiamo di contattarci al piu'' presto per confermare il rinnovo ed evitare interruzioni di copertura.\n\nTel: {collaboratore_tel}\nEmail: {collaboratore_email}\n\nCordiali saluti,\nFIM Insurance Broker S.A.S.',
 'URGENTE FIM: polizza {ramo} scade il {data_scadenza}! Contattaci subito per il rinnovo: 06-XXXXXXX'),
('Post-scadenza', -7, TRUE, TRUE, FALSE,
 'Gentile {cliente_nome},\n\nLa informiamo che la Sua polizza {ramo} n. {numero_polizza} risulta scaduta dal {data_scadenza}.\n\nE'' fondamentale rinnovare la copertura per evitare di restare senza protezione assicurativa.\n\nLa preghiamo di contattarci con urgenza.\n\nCordiali saluti,\nFIM Insurance Broker S.A.S.',
 NULL);

-- ============================================================
-- ROW LEVEL SECURITY (Supabase)
-- ============================================================

-- Abilita RLS su tutte le tabelle principali
ALTER TABLE clienti ENABLE ROW LEVEL SECURITY;
ALTER TABLE polizze ENABLE ROW LEVEL SECURITY;
ALTER TABLE sinistri ENABLE ROW LEVEL SECURITY;
ALTER TABLE provvigioni_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE comunicazioni ENABLE ROW LEVEL SECURITY;
ALTER TABLE adeguatezza_idd ENABLE ROW LEVEL SECURITY;
ALTER TABLE documenti ENABLE ROW LEVEL SECURITY;

-- Policy: utenti autenticati possono leggere tutto (team FIM interno)
CREATE POLICY "Team FIM lettura" ON clienti FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON polizze FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON sinistri FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON provvigioni_log FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON comunicazioni FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON adeguatezza_idd FOR SELECT TO authenticated USING (true);
CREATE POLICY "Team FIM lettura" ON documenti FOR SELECT TO authenticated USING (true);

-- Policy: solo titolare e servizio possono scrivere
CREATE POLICY "Team FIM scrittura" ON clienti FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Team FIM scrittura" ON polizze FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Team FIM scrittura" ON sinistri FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Team FIM scrittura" ON comunicazioni FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Team FIM scrittura" ON adeguatezza_idd FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "Team FIM scrittura" ON documenti FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Provvigioni: solo INSERT (registro immutabile)
CREATE POLICY "Provvigioni insert only" ON provvigioni_log FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Provvigioni no update" ON provvigioni_log FOR UPDATE TO authenticated USING (false);

-- ============================================================
-- COMMENTO FINALE
-- ============================================================
COMMENT ON DATABASE current_database() IS 'FIM Insurance Broker - Gestionale v2.0 - Schema PostgreSQL per Supabase';
