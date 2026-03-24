-- ============================================================
-- FIM - SCRIPT MIGRAZIONE DA FIREBASE A POSTGRESQL
-- ============================================================
-- ISTRUZIONI:
-- 1. Esportare i dati da Firebase Console > Realtime Database > Export JSON
-- 2. Caricare il JSON in Supabase Storage (bucket: 'migrazione')
-- 3. Usare la Edge Function 'migra-firebase' per processare
-- 4. Oppure: convertire il JSON in CSV e importare con COPY
-- ============================================================

-- Tabella temporanea per import JSON da Firebase
CREATE TEMP TABLE firebase_raw (
    collection VARCHAR(50),
    firebase_id VARCHAR(100),
    dati JSONB
);

-- ============================================================
-- FUNZIONE: Migra clienti da Firebase JSON
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migra_clienti_firebase(p_json JSONB)
RETURNS INT AS $$
DECLARE
    v_count INT := 0;
    v_record JSONB;
    v_key TEXT;
BEGIN
    FOR v_key, v_record IN SELECT * FROM jsonb_each(p_json)
    LOOP
        INSERT INTO clienti (
            uuid_firebase, tipo, cognome, nome, codice_fiscale,
            data_nascita, ragione_sociale, partita_iva,
            telefono, cellulare, email,
            indirizzo, cap, citta, provincia,
            note, creato_il
        ) VALUES (
            v_key,
            COALESCE(v_record->>'tipo', 'privato'),
            v_record->>'cognome',
            v_record->>'nome',
            NULLIF(v_record->>'codiceFiscale', ''),
            CASE WHEN v_record->>'dataNascita' IS NOT NULL
                 THEN (v_record->>'dataNascita')::DATE ELSE NULL END,
            v_record->>'ragioneSociale',
            NULLIF(v_record->>'partitaIva', ''),
            v_record->>'telefono',
            v_record->>'cellulare',
            v_record->>'email',
            v_record->>'indirizzo',
            v_record->>'cap',
            v_record->>'citta',
            v_record->>'provincia',
            v_record->>'note',
            COALESCE(
                to_timestamp((v_record->>'createdAt')::BIGINT / 1000),
                NOW()
            )
        )
        ON CONFLICT (uuid_firebase) DO UPDATE SET
            cognome = EXCLUDED.cognome,
            nome = EXCLUDED.nome,
            email = EXCLUDED.email,
            telefono = EXCLUDED.telefono;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNZIONE: Migra collaboratori da Firebase JSON
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migra_collaboratori_firebase(p_json JSONB)
RETURNS INT AS $$
DECLARE
    v_count INT := 0;
    v_record JSONB;
    v_key TEXT;
    v_codice VARCHAR(20);
BEGIN
    FOR v_key, v_record IN SELECT * FROM jsonb_each(p_json)
    LOOP
        v_codice := COALESCE(v_record->>'codice', 'COL-' || LPAD(v_count::TEXT, 3, '0'));

        INSERT INTO collaboratori (
            uuid_firebase, codice, cognome, nome, codice_rui,
            ruolo, email, telefono, attivo, data_nomina,
            perc_provv_default, note
        ) VALUES (
            v_key,
            v_codice,
            COALESCE(v_record->>'cognome', 'N/D'),
            COALESCE(v_record->>'nome', 'N/D'),
            v_record->>'codiceRui',
            COALESCE(v_record->>'ruolo', 'subagente'),
            v_record->>'email',
            v_record->>'telefono',
            COALESCE((v_record->>'attivo')::BOOLEAN, TRUE),
            CASE WHEN v_record->>'dataNomina' IS NOT NULL
                 THEN (v_record->>'dataNomina')::DATE ELSE NULL END,
            COALESCE((v_record->>'percProvvDefault')::DECIMAL, 7.00),
            v_record->>'note'
        )
        ON CONFLICT (uuid_firebase) DO UPDATE SET
            cognome = EXCLUDED.cognome,
            nome = EXCLUDED.nome;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- FUNZIONE: Migra polizze da Firebase JSON
-- ============================================================
CREATE OR REPLACE FUNCTION fn_migra_polizze_firebase(p_json JSONB)
RETURNS INT AS $$
DECLARE
    v_count INT := 0;
    v_record JSONB;
    v_key TEXT;
    v_cliente_id INT;
    v_compagnia_id INT;
    v_ramo_id INT;
    v_collab_id INT;
    v_compagnia_nome VARCHAR(100);
BEGIN
    FOR v_key, v_record IN SELECT * FROM jsonb_each(p_json)
    LOOP
        -- Risolvi cliente
        SELECT id INTO v_cliente_id FROM clienti
        WHERE uuid_firebase = v_record->>'cliente'
           OR uuid_firebase = v_record->>'clienteId'
        LIMIT 1;

        IF v_cliente_id IS NULL THEN
            CONTINUE; -- salta polizze senza cliente valido
        END IF;

        -- Risolvi compagnia (normalizzata)
        v_compagnia_nome := LOWER(COALESCE(v_record->>'compagnia', 'non specificata'));
        SELECT id INTO v_compagnia_id FROM compagnie
        WHERE LOWER(nome) LIKE '%' || v_compagnia_nome || '%'
           OR LOWER(nome_normalizzato) LIKE '%' || v_compagnia_nome || '%'
           OR LOWER(codice) = v_compagnia_nome
        LIMIT 1;

        IF v_compagnia_id IS NULL THEN
            -- Crea compagnia se non esiste
            INSERT INTO compagnie (codice, nome, nome_normalizzato)
            VALUES (
                UPPER(REPLACE(LEFT(v_record->>'compagnia', 15), ' ', '_')),
                v_record->>'compagnia',
                v_record->>'compagnia'
            )
            RETURNING id INTO v_compagnia_id;
        END IF;

        -- Risolvi ramo
        SELECT id INTO v_ramo_id FROM rami_assicurativi
        WHERE LOWER(codice) = LOWER(COALESCE(v_record->>'ramo', v_record->>'tipoGaranzia', 'RCA'))
           OR LOWER(nome) LIKE '%' || LOWER(COALESCE(v_record->>'ramo', v_record->>'tipoGaranzia', '')) || '%'
        LIMIT 1;

        IF v_ramo_id IS NULL THEN
            SELECT id INTO v_ramo_id FROM rami_assicurativi WHERE codice = 'RCA'; -- fallback
        END IF;

        -- Risolvi collaboratore
        SELECT id INTO v_collab_id FROM collaboratori
        WHERE uuid_firebase = v_record->>'collaboratore'
        LIMIT 1;

        -- Inserisci polizza
        INSERT INTO polizze (
            uuid_firebase, numero_polizza, cliente_id, compagnia_id, ramo_id, collaboratore_id,
            data_emissione, data_effetto, data_scadenza,
            stato, tipo_emissione,
            premio_lordo, imposte, ssn,
            perc_provvigione, provvigione,
            dettagli_ramo, note
        ) VALUES (
            v_key,
            COALESCE(v_record->>'numeroPolizza', v_record->>'numero', 'MIG-' || v_key),
            v_cliente_id,
            v_compagnia_id,
            v_ramo_id,
            v_collab_id,
            COALESCE((v_record->>'dataEmissione')::DATE, CURRENT_DATE),
            COALESCE((v_record->>'dataEffetto')::DATE, (v_record->>'dataEmissione')::DATE, CURRENT_DATE),
            COALESCE((v_record->>'dataScadenza')::DATE, CURRENT_DATE + INTERVAL '1 year'),
            COALESCE(v_record->>'stato', 'attiva'),
            COALESCE(v_record->>'tipoEmissione', 'nuova'),
            COALESCE((v_record->>'premio')::DECIMAL, (v_record->>'premioLordo')::DECIMAL, 0),
            COALESCE((v_record->>'imposte')::DECIMAL, 0),
            COALESCE((v_record->>'ssn')::DECIMAL, 0),
            (v_record->>'percProvvigione')::DECIMAL,
            (v_record->>'provvigione')::DECIMAL,
            CASE
                WHEN v_record ? 'targa' THEN jsonb_build_object(
                    'targa', v_record->>'targa',
                    'marca', v_record->>'marca',
                    'modello', v_record->>'modello',
                    'classe_cu', v_record->>'classeCu'
                )
                ELSE '{}'::JSONB
            END,
            v_record->>'note'
        )
        ON CONFLICT (uuid_firebase) DO NOTHING;

        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- ESECUZIONE MIGRAZIONE
-- Decommentare e adattare con i propri dati JSON
-- ============================================================

-- Esempio:
-- SELECT fn_migra_collaboratori_firebase('{"uid1": {"cognome": "Rossi", ...}}'::JSONB);
-- SELECT fn_migra_clienti_firebase('{"uid1": {"cognome": "Bianchi", ...}}'::JSONB);
-- SELECT fn_migra_polizze_firebase('{"uid1": {"numeroPolizza": "12345", ...}}'::JSONB);

-- Dopo la migrazione: verifiche
-- SELECT 'clienti' AS tabella, COUNT(*) AS righe FROM clienti UNION ALL
-- SELECT 'collaboratori', COUNT(*) FROM collaboratori UNION ALL
-- SELECT 'polizze', COUNT(*) FROM polizze UNION ALL
-- SELECT 'compagnie', COUNT(*) FROM compagnie;
