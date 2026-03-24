-- ============================================================
-- FIM - WORKFLOW AUTOMATICO SCADENZE
-- ============================================================
-- Funzione PostgreSQL da richiamare via Supabase Cron (pg_cron)
-- o via Edge Function schedulata ogni giorno alle 7:00
-- ============================================================

-- ============================================================
-- FUNZIONE PRINCIPALE: Processa Scadenze Giornaliere
-- ============================================================
CREATE OR REPLACE FUNCTION fn_processa_scadenze_giornaliere()
RETURNS TABLE(
    azioni_eseguite INT,
    email_programmate INT,
    sms_programmati INT,
    notifiche_collaboratori INT,
    preventivi_generati INT
) AS $$
DECLARE
    v_workflow RECORD;
    v_polizza RECORD;
    v_azioni INT := 0;
    v_email INT := 0;
    v_sms INT := 0;
    v_notifiche INT := 0;
    v_preventivi INT := 0;
    v_data_target DATE;
    v_template TEXT;
    v_corpo_email TEXT;
    v_corpo_sms TEXT;
    v_cliente_nome TEXT;
    v_collab_nome TEXT;
    v_collab_email TEXT;
    v_collab_tel TEXT;
    v_gia_inviato BOOLEAN;
BEGIN
    -- Per ogni workflow attivo
    FOR v_workflow IN
        SELECT * FROM workflow_scadenze WHERE attivo = TRUE ORDER BY giorni_prima_scadenza DESC
    LOOP
        -- Calcola la data target
        v_data_target := CURRENT_DATE + v_workflow.giorni_prima_scadenza;

        -- Trova le polizze che scadono in quella data
        FOR v_polizza IN
            SELECT
                p.id AS polizza_id,
                p.numero_polizza,
                p.data_scadenza,
                p.premio_lordo,
                r.nome AS ramo,
                comp.nome AS compagnia,
                c.id AS cliente_id,
                COALESCE(CONCAT(c.cognome, ' ', c.nome), c.ragione_sociale) AS cliente_nome,
                c.email AS cliente_email,
                c.cellulare AS cliente_cellulare,
                col.id AS collaboratore_id,
                COALESCE(CONCAT(col.cognome, ' ', col.nome), 'FIM Broker') AS collab_nome,
                COALESCE(col.email, 'info@fimbroker.it') AS collab_email,
                COALESCE(col.telefono, '') AS collab_tel
            FROM polizze p
            JOIN clienti c ON c.id = p.cliente_id AND c.eliminato_il IS NULL
            JOIN compagnie comp ON comp.id = p.compagnia_id
            JOIN rami_assicurativi r ON r.id = p.ramo_id
            LEFT JOIN collaboratori col ON col.id = p.collaboratore_id
            WHERE p.stato = 'attiva'
              AND p.eliminato_il IS NULL
              AND p.data_scadenza = v_data_target
              AND NOT (p.stato = ANY(v_workflow.escludi_stati))
              AND (v_workflow.solo_rami IS NULL OR p.ramo_id = ANY(v_workflow.solo_rami))
              AND (v_workflow.solo_compagnie IS NULL OR p.compagnia_id = ANY(v_workflow.solo_compagnie))
        LOOP
            -- Verifica se non abbiamo gia' inviato questa comunicazione
            SELECT EXISTS(
                SELECT 1 FROM comunicazioni
                WHERE polizza_id = v_polizza.polizza_id
                  AND tipo = 'scadenza_' || ABS(v_workflow.giorni_prima_scadenza) || 'gg'
                  AND data_invio > CURRENT_DATE - INTERVAL '3 days'
            ) INTO v_gia_inviato;

            IF v_gia_inviato THEN
                CONTINUE;
            END IF;

            -- Prepara variabili template
            v_cliente_nome := v_polizza.cliente_nome;
            v_collab_nome := v_polizza.collab_nome;
            v_collab_email := v_polizza.collab_email;
            v_collab_tel := v_polizza.collab_tel;

            -- === EMAIL AL CLIENTE ===
            IF v_workflow.invia_email_cliente AND v_polizza.cliente_email IS NOT NULL THEN
                v_corpo_email := REPLACE(
                    REPLACE(
                    REPLACE(
                    REPLACE(
                    REPLACE(
                    REPLACE(
                        COALESCE(v_workflow.template_email, ''),
                        '{cliente_nome}', v_cliente_nome),
                        '{numero_polizza}', v_polizza.numero_polizza),
                        '{ramo}', v_polizza.ramo),
                        '{compagnia}', v_polizza.compagnia),
                        '{data_scadenza}', TO_CHAR(v_polizza.data_scadenza, 'DD/MM/YYYY')),
                        '{collaboratore_email}', v_collab_email);
                v_corpo_email := REPLACE(v_corpo_email, '{collaboratore_tel}', v_collab_tel);

                INSERT INTO comunicazioni (
                    cliente_id, polizza_id, collaboratore_id,
                    canale, tipo, direzione,
                    oggetto, corpo, destinatario,
                    stato, data_programmata, generato_da, workflow_id
                ) VALUES (
                    v_polizza.cliente_id, v_polizza.polizza_id, v_polizza.collaboratore_id,
                    'email',
                    'scadenza_' || ABS(v_workflow.giorni_prima_scadenza) || 'gg',
                    'uscita',
                    'FIM Broker - Scadenza polizza ' || v_polizza.ramo || ' n. ' || v_polizza.numero_polizza,
                    v_corpo_email,
                    v_polizza.cliente_email,
                    'programmato',
                    NOW(),
                    'workflow_scadenze',
                    v_workflow.id::TEXT
                );
                v_email := v_email + 1;
            END IF;

            -- === SMS AL CLIENTE ===
            IF v_workflow.invia_sms_cliente AND v_polizza.cliente_cellulare IS NOT NULL AND v_workflow.template_sms IS NOT NULL THEN
                v_corpo_sms := REPLACE(
                    REPLACE(
                    REPLACE(
                    REPLACE(
                        v_workflow.template_sms,
                        '{numero_polizza}', v_polizza.numero_polizza),
                        '{ramo}', v_polizza.ramo),
                        '{data_scadenza}', TO_CHAR(v_polizza.data_scadenza, 'DD/MM/YYYY')),
                        '{compagnia}', v_polizza.compagnia);

                INSERT INTO comunicazioni (
                    cliente_id, polizza_id, collaboratore_id,
                    canale, tipo, direzione,
                    corpo, destinatario,
                    stato, data_programmata, generato_da, workflow_id
                ) VALUES (
                    v_polizza.cliente_id, v_polizza.polizza_id, v_polizza.collaboratore_id,
                    'sms',
                    'scadenza_' || ABS(v_workflow.giorni_prima_scadenza) || 'gg',
                    'uscita',
                    v_corpo_sms,
                    v_polizza.cliente_cellulare,
                    'programmato',
                    NOW(),
                    'workflow_scadenze',
                    v_workflow.id::TEXT
                );
                v_sms := v_sms + 1;
            END IF;

            -- === NOTIFICA AL COLLABORATORE ===
            IF v_workflow.notifica_collaboratore AND v_polizza.collaboratore_id IS NOT NULL THEN
                INSERT INTO comunicazioni (
                    cliente_id, polizza_id, collaboratore_id,
                    canale, tipo, direzione,
                    oggetto, corpo, destinatario,
                    stato, data_programmata, generato_da, workflow_id
                ) VALUES (
                    v_polizza.cliente_id, v_polizza.polizza_id, v_polizza.collaboratore_id,
                    'email',
                    'notifica_scadenza_collaboratore',
                    'uscita',
                    '[FIM] Scadenza ' || v_polizza.ramo || ' - ' || v_cliente_nome || ' (' || ABS(v_workflow.giorni_prima_scadenza) || 'gg)',
                    'Polizza: ' || v_polizza.numero_polizza || E'\n' ||
                    'Cliente: ' || v_cliente_nome || E'\n' ||
                    'Compagnia: ' || v_polizza.compagnia || E'\n' ||
                    'Ramo: ' || v_polizza.ramo || E'\n' ||
                    'Scadenza: ' || TO_CHAR(v_polizza.data_scadenza, 'DD/MM/YYYY') || E'\n' ||
                    'Premio: ' || TO_CHAR(v_polizza.premio_lordo, 'FM999G999D00') || ' EUR',
                    v_collab_email,
                    'programmato',
                    NOW(),
                    'workflow_scadenze',
                    v_workflow.id::TEXT
                );
                v_notifiche := v_notifiche + 1;
            END IF;

            v_azioni := v_azioni + 1;
        END LOOP;
    END LOOP;

    RETURN QUERY SELECT v_azioni, v_email, v_sms, v_notifiche, v_preventivi;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- CRON JOB: Esegui ogni giorno alle 7:00 (richiede pg_cron)
-- ============================================================
-- Su Supabase, abilitare pg_cron dal Dashboard > Database > Extensions
-- Poi eseguire:

-- SELECT cron.schedule(
--     'fim-scadenze-giornaliere',
--     '0 7 * * *',   -- Ogni giorno alle 7:00
--     $$SELECT fn_processa_scadenze_giornaliere()$$
-- );

-- Per verificare i cron job attivi:
-- SELECT * FROM cron.job;

-- Per vedere i risultati delle esecuzioni:
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- ============================================================
-- FUNZIONE: Calcolo Provvigioni Mensili Batch
-- ============================================================
CREATE OR REPLACE FUNCTION fn_calcola_provvigioni_mensili(p_periodo VARCHAR(7) DEFAULT NULL)
RETURNS TABLE(
    polizze_processate INT,
    provvigioni_calcolate INT,
    totale_provvigioni DECIMAL
) AS $$
DECLARE
    v_periodo VARCHAR(7);
    v_count INT := 0;
    v_prov_count INT := 0;
    v_totale DECIMAL := 0;
    v_polizza RECORD;
    v_perc DECIMAL;
    v_importo DECIMAL;
    v_imponibile DECIMAL;
BEGIN
    v_periodo := COALESCE(p_periodo, TO_CHAR(CURRENT_DATE, 'YYYY-MM'));

    -- Per ogni polizza attiva
    FOR v_polizza IN
        SELECT
            p.id, p.collaboratore_id, p.ramo_id, p.compagnia_id,
            p.imponibile, p.premio_lordo, p.perc_provvigione,
            p.frazionamento, p.numero_polizza
        FROM polizze p
        WHERE p.stato = 'attiva'
          AND p.eliminato_il IS NULL
          AND p.collaboratore_id IS NOT NULL
          -- Solo polizze che hanno una rata nel periodo
          AND (
              -- Annuale: mese di effetto = mese corrente
              (p.frazionamento = 'annuale' AND TO_CHAR(p.data_effetto, 'MM') = SUBSTRING(v_periodo, 6, 2))
              -- Semestrale: ogni 6 mesi
              OR (p.frazionamento = 'semestrale' AND MOD(
                  EXTRACT(MONTH FROM CURRENT_DATE)::INT - EXTRACT(MONTH FROM p.data_effetto)::INT + 12, 12
              ) IN (0, 6))
              -- Trimestrale: ogni 3 mesi
              OR (p.frazionamento = 'trimestrale' AND MOD(
                  EXTRACT(MONTH FROM CURRENT_DATE)::INT - EXTRACT(MONTH FROM p.data_effetto)::INT + 12, 12
              ) IN (0, 3, 6, 9))
              -- Mensile: sempre
              OR p.frazionamento = 'mensile'
          )
          -- Non gia' calcolata per questo periodo
          AND NOT EXISTS (
              SELECT 1 FROM provvigioni_log pl
              WHERE pl.polizza_id = p.id
                AND pl.periodo = v_periodo
                AND pl.tipo = 'maturata'
          )
    LOOP
        v_count := v_count + 1;

        -- Calcola imponibile
        v_imponibile := COALESCE(v_polizza.imponibile, v_polizza.premio_lordo);

        -- Adegua per frazionamento
        CASE v_polizza.frazionamento
            WHEN 'semestrale' THEN v_imponibile := v_imponibile / 2;
            WHEN 'trimestrale' THEN v_imponibile := v_imponibile / 4;
            WHEN 'mensile' THEN v_imponibile := v_imponibile / 12;
            ELSE NULL; -- annuale: importo pieno
        END CASE;

        -- Cerca percentuale provvigione (priorita': tabella specifica > polizza > default collaboratore)
        SELECT tp.percentuale INTO v_perc
        FROM tabelle_provvigioni tp
        WHERE tp.collaboratore_id = v_polizza.collaboratore_id
          AND tp.ramo_id = v_polizza.ramo_id
          AND (tp.compagnia_id = v_polizza.compagnia_id OR tp.compagnia_id IS NULL)
          AND tp.valido_dal <= CURRENT_DATE
          AND (tp.valido_al IS NULL OR tp.valido_al >= CURRENT_DATE)
        ORDER BY tp.compagnia_id NULLS LAST
        LIMIT 1;

        IF v_perc IS NULL THEN
            v_perc := COALESCE(
                v_polizza.perc_provvigione,
                (SELECT perc_provv_default FROM collaboratori WHERE id = v_polizza.collaboratore_id)
            );
        END IF;

        IF v_perc IS NULL OR v_perc = 0 THEN
            CONTINUE;
        END IF;

        v_importo := ROUND(v_imponibile * v_perc / 100, 2);

        -- Registra nel log provvigioni (immutabile)
        INSERT INTO provvigioni_log (
            polizza_id, collaboratore_id, periodo, tipo,
            imponibile, percentuale, importo,
            fonte_dati, creato_da
        ) VALUES (
            v_polizza.id, v_polizza.collaboratore_id, v_periodo, 'maturata',
            v_imponibile, v_perc, v_importo,
            'calcolo_automatico', 'fn_calcola_provvigioni_mensili'
        );

        v_prov_count := v_prov_count + 1;
        v_totale := v_totale + v_importo;
    END LOOP;

    RETURN QUERY SELECT v_count, v_prov_count, v_totale;
END;
$$ LANGUAGE plpgsql;

-- CRON: Calcolo provvigioni il 1° di ogni mese alle 8:00
-- SELECT cron.schedule(
--     'fim-provvigioni-mensili',
--     '0 8 1 * *',
--     $$SELECT fn_calcola_provvigioni_mensili()$$
-- );

-- ============================================================
-- FUNZIONE: Verifica Compliance IDD
-- Restituisce polizze senza checklist adeguatezza compilata
-- ============================================================
CREATE OR REPLACE FUNCTION fn_verifica_compliance_idd()
RETURNS TABLE(
    polizza_id INT,
    numero_polizza VARCHAR,
    cliente TEXT,
    ramo TEXT,
    data_emissione DATE,
    ha_idd BOOLEAN,
    idd_firmata BOOLEAN,
    dip_consegnato BOOLEAN,
    giorni_senza_idd INT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.id,
        p.numero_polizza,
        COALESCE(CONCAT(c.cognome, ' ', c.nome), c.ragione_sociale)::TEXT,
        r.nome::TEXT,
        p.data_emissione,
        (a.id IS NOT NULL),
        COALESCE(a.firma_cliente, FALSE),
        COALESCE(a.dip_consegnato, FALSE),
        (CURRENT_DATE - p.data_emissione)::INT
    FROM polizze p
    JOIN clienti c ON c.id = p.cliente_id
    JOIN rami_assicurativi r ON r.id = p.ramo_id
    LEFT JOIN adeguatezza_idd a ON a.polizza_id = p.id
    WHERE p.stato = 'attiva'
      AND p.eliminato_il IS NULL
      AND p.tipo_emissione IN ('nuova', 'sostituzione')
      AND (a.id IS NULL OR a.firma_cliente = FALSE)
    ORDER BY p.data_emissione ASC;
END;
$$ LANGUAGE plpgsql;
