-- FIM Gestionale v2 - Tabella Fatture
-- Eseguire nel SQL Editor di Supabase Dashboard

CREATE TABLE IF NOT EXISTS public.fatture (
    id SERIAL PRIMARY KEY,
    numero_fattura VARCHAR(50) NOT NULL,
    data_fattura DATE NOT NULL DEFAULT CURRENT_DATE,
    data_scadenza DATE,
    cliente_id INTEGER REFERENCES public.clienti(id),
    tipo VARCHAR(20) NOT NULL DEFAULT 'attiva' CHECK (tipo IN ('attiva', 'passiva')),
    descrizione TEXT,
    imponibile NUMERIC(12,2) DEFAULT 0,
    iva_perc NUMERIC(5,2) DEFAULT 22,
    iva_importo NUMERIC(12,2) DEFAULT 0,
    totale NUMERIC(12,2) DEFAULT 0,
    stato VARCHAR(20) DEFAULT 'emessa' CHECK (stato IN ('bozza', 'emessa', 'inviata', 'pagata', 'scaduta', 'annullata')),
    metodo_pagamento VARCHAR(50),
    data_pagamento DATE,
    note TEXT,
    polizza_id INTEGER REFERENCES public.polizze(id),
    creato_il TIMESTAMPTZ DEFAULT NOW(),
    aggiornato_il TIMESTAMPTZ DEFAULT NOW(),
    eliminato_il TIMESTAMPTZ
);

-- RLS
ALTER TABLE public.fatture ENABLE ROW LEVEL SECURITY;

CREATE POLICY "fatture_select" ON public.fatture FOR SELECT USING (true);
CREATE POLICY "fatture_insert" ON public.fatture FOR INSERT WITH CHECK (true);
CREATE POLICY "fatture_update" ON public.fatture FOR UPDATE USING (true);
CREATE POLICY "fatture_delete" ON public.fatture FOR DELETE USING (true);

-- Grants
GRANT ALL ON public.fatture TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE fatture_id_seq TO anon, authenticated;
