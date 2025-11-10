async function formatPhoneE164BR(phone) {
  const cleaned = String(phone || '').replace(/\D/g, '');
  // Assume BR if starts with '55' or local without country code
  if (cleaned.startsWith('55')) {
    return `+${cleaned}`;
  }
  // If already has leading + and digits only
  if (/^\+?[0-9]{10,15}$/.test(phone)) {
    return phone.startsWith('+') ? phone : `+${phone}`;
  }
  // Fallback: prefix Brazil country code
  return `+55${cleaned}`;
}

async function sendWhatsApp({ phone, message }) {
  const provider = process.env.WHATSAPP_PROVIDER || 'stub';

  const e164 = await formatPhoneE164BR(phone);
  if (!/^\+?[0-9]{10,15}$/.test(e164)) {
    return { ok: false, error: 'invalid_phone' };
  }
  if (!message || String(message).trim().length === 0) {
    return { ok: false, error: 'empty_message' };
  }

  if (provider === 'stub') {
    return { ok: true, provider };
  }

  if (provider === 'meta') {
    const token = process.env.WHATSAPP_TOKEN;
    const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;
    if (!token || !phoneNumberId) {
      return { ok: false, error: 'provider_not_configured' };
    }
    try {
      const url = `https://graph.facebook.com/v20.0/${phoneNumberId}/messages`;
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          messaging_product: 'whatsapp',
          to: e164.replace('+', ''),
          type: 'text',
          text: { body: String(message).slice(0, 4096) },
        }),
      });
      const json = await res.json().catch(() => ({}));
      if (!res.ok) {
        const err = json?.error?.message || `http_${res.status}`;
        return { ok: false, error: err };
      }
      const msgId = Array.isArray(json?.messages) && json.messages[0]?.id ? json.messages[0].id : null;
      return { ok: true, provider, id: msgId };
    } catch (e) {
      return { ok: false, error: e?.message || 'network_error' };
    }
  }

  // TODO: implementar 'twilio' ou '360dialog' quando necessário
  return { ok: false, error: 'provider_not_supported' };
}

module.exports = { sendWhatsApp };