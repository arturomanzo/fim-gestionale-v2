// ============================================================
// FIM - Edge Function: Invia Comunicazioni Programmate
// ============================================================
// Deploy: supabase functions deploy invia-comunicazioni
// Trigger: Supabase Cron ogni 15 minuti, oppure Webhook
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Configurazione Resend (servizio email)
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// FIM Settings
const FIM_EMAIL_FROM = 'FIM Insurance Broker <noreply@fimbroker.it>'
const FIM_EMAIL_REPLY_TO = 'info@fimbroker.it'

interface Comunicazione {
  id: number
  canale: string
  tipo: string
  oggetto: string | null
  corpo: string | null
  destinatario: string
  cliente_id: number | null
  polizza_id: number | null
}

Deno.serve(async (req: Request) => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    // 1. Recupera comunicazioni programmate da inviare
    const { data: comunicazioni, error } = await supabase
      .from('comunicazioni')
      .select('*')
      .eq('stato', 'programmato')
      .lte('data_programmata', new Date().toISOString())
      .order('data_programmata', { ascending: true })
      .limit(50)  // batch di 50 per esecuzione

    if (error) throw error
    if (!comunicazioni || comunicazioni.length === 0) {
      return new Response(JSON.stringify({ message: 'Nessuna comunicazione da inviare', count: 0 }))
    }

    let inviate = 0
    let errori = 0

    for (const com of comunicazioni as Comunicazione[]) {
      try {
        if (com.canale === 'email') {
          // Invia email tramite Resend
          const emailResponse = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${RESEND_API_KEY}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              from: FIM_EMAIL_FROM,
              reply_to: FIM_EMAIL_REPLY_TO,
              to: [com.destinatario],
              subject: com.oggetto || 'Comunicazione FIM Insurance Broker',
              html: convertiCorpoInHtml(com.corpo || '', com.tipo),
            }),
          })

          if (!emailResponse.ok) {
            const errDetail = await emailResponse.text()
            throw new Error(`Resend error: ${errDetail}`)
          }

          // Aggiorna stato comunicazione
          await supabase
            .from('comunicazioni')
            .update({
              stato: 'inviato',
              data_invio: new Date().toISOString(),
            })
            .eq('id', com.id)

          inviate++

        } else if (com.canale === 'sms') {
          // SMS tramite Twilio (o altro provider)
          // Per ora: segna come inviato e logga
          // TODO: integrare Twilio quando attivato
          await supabase
            .from('comunicazioni')
            .update({
              stato: 'inviato',
              data_invio: new Date().toISOString(),
              errore_dettaglio: 'SMS provider non ancora configurato - simulato',
            })
            .eq('id', com.id)

          inviate++
        }
      } catch (sendError: unknown) {
        // Segna errore sulla singola comunicazione
        const errorMessage = sendError instanceof Error ? sendError.message : 'Errore sconosciuto'
        await supabase
          .from('comunicazioni')
          .update({
            stato: 'errore',
            errore_dettaglio: errorMessage,
          })
          .eq('id', com.id)

        errori++
      }
    }

    // Log risultato nel audit trail AI
    await supabase.from('attivita_agenti_ai').insert({
      agente: 'fima_scadenze',
      azione: 'invio_comunicazioni_batch',
      output_dati: { inviate, errori, totale: comunicazioni.length },
      stato: errori === 0 ? 'completato' : 'completato',
      modello_ai: 'n/a',
    })

    return new Response(
      JSON.stringify({
        message: `Comunicazioni processate: ${inviate} inviate, ${errori} errori su ${comunicazioni.length} totali`,
        inviate,
        errori,
        totale: comunicazioni.length,
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (err: unknown) {
    const errorMessage = err instanceof Error ? err.message : 'Errore sconosciuto'
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
})

// ============================================================
// Helper: Converti corpo testo in HTML con template FIM
// ============================================================
function convertiCorpoInHtml(corpo: string, tipo: string): string {
  const corpoHtml = corpo.replace(/\n/g, '<br>')

  // Colore header in base al tipo
  let headerColor = '#1A3A5C' // navy default
  let headerText = 'Comunicazione'
  if (tipo.includes('scadenza')) {
    if (tipo.includes('7')) { headerColor = '#DC2626'; headerText = 'Scadenza Urgente' }
    else if (tipo.includes('30')) { headerColor = '#D97706'; headerText = 'Promemoria Scadenza' }
    else if (tipo.includes('60')) { headerColor = '#1A3A5C'; headerText = 'Avviso Scadenza' }
    else { headerColor = '#DC2626'; headerText = 'Polizza Scaduta' }
  }

  return `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; color: #333;">
  <!-- Header FIM -->
  <div style="background: ${headerColor}; padding: 20px; border-radius: 8px 8px 0 0;">
    <h2 style="color: #fff; margin: 0; font-size: 18px;">FIM Insurance Broker</h2>
    <p style="color: rgba(255,255,255,0.8); margin: 5px 0 0; font-size: 13px;">${headerText}</p>
  </div>

  <!-- Corpo -->
  <div style="background: #f9fafb; padding: 24px; border: 1px solid #e5e7eb; border-top: none;">
    <div style="font-size: 14px; line-height: 1.7;">
      ${corpoHtml}
    </div>
  </div>

  <!-- Footer IVASS -->
  <div style="background: #1A3A5C; padding: 16px 20px; border-radius: 0 0 8px 8px;">
    <p style="color: rgba(255,255,255,0.7); margin: 0; font-size: 11px; line-height: 1.5;">
      FIM Insurance Broker S.A.S. | Via Roma 41, 04012 Cisterna di Latina (LT)<br>
      RUI Sez. B - N. B000405449 |
      <a href="https://www.fimbroker.it" style="color: #00C4B4;">www.fimbroker.it</a> |
      <a href="mailto:info@fimbroker.it" style="color: #00C4B4;">info@fimbroker.it</a><br>
      Soggetto alla vigilanza IVASS -
      <a href="https://servizi.ivass.it/RuirPubblica/" style="color: #00C4B4;">Verifica iscrizione</a>
    </p>
  </div>

  <!-- Unsubscribe -->
  <p style="text-align: center; font-size: 11px; color: #9ca3af; margin-top: 16px;">
    Ricevi questa email perche' sei cliente di FIM Insurance Broker.<br>
    Per non ricevere piu' comunicazioni:
    <a href="mailto:info@fimbroker.it?subject=Disiscrizione" style="color: #6b7280;">clicca qui</a>
  </p>
</body>
</html>`
}
