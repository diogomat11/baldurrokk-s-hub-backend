require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const fastify = require('fastify')({ logger: true });
const { supabase, createUserClient } = require('./supabase');
const { sendWhatsApp } = require('./providers/whatsapp');
const crypto = require('crypto')

// Rotina: marcar faturas vencidas automaticamente
async function markOverdueInvoices() {
  try {
    const today = new Date().toISOString().slice(0, 10);
    // Atualiza faturas 'Aberta' com due_date anterior a hoje para 'Vencida'
    const { data, error } = await supabase
      .from('invoices')
      .update({ status: 'Vencida', updated_at: new Date().toISOString() })
      .lt('due_date', today)
      .eq('status', 'Aberta')
      .select('id', { count: 'exact' });
    if (error) {
      fastify.log.error({ error }, 'overdue job: update failed');
      return;
    }
    const count = Array.isArray(data) ? data.length : 0;
    if (count > 0) {
      fastify.log.info({ updated: count }, 'overdue job: invoices marked as Vencida');
    } else {
      fastify.log.info('overdue job: no invoices to update');
    }
  } catch (e) {
    fastify.log.error(e, 'overdue job: unexpected error');
  }
}

// Agendar execução periódica (default: a cada 24h) e executar na inicialização
function scheduleOverdueJob() {
  const hours = Number(process.env.OVERDUE_JOB_INTERVAL_HOURS || 24);
  const intervalMs = Math.max(1, hours) * 60 * 60 * 1000;
  // Executa na inicialização
  markOverdueInvoices();
  // Executa periodicamente
  setInterval(() => {
    markOverdueInvoices();
  }, intervalMs);
}

// Inicializa rotina ao carregar o servidor
scheduleOverdueJob();

 const corsOriginsRaw = String(process.env.CORS_ORIGINS || '')
   .split(',')
   .map(s => s.trim())
   .filter(Boolean);
 const corsOrigins = corsOriginsRaw.map(o => o.replace(/\/$/, '')); // remover barra final
 const defaultDevOrigins = ['http://localhost:5173', 'http://127.0.0.1:5173'];

 // helper: verifica se origem é permitida, suportando wildcard do tipo "*.dominio.com"
 function isAllowedOrigin(origin) {
   if (!origin) return false;
   // match exato
   if (corsOrigins.includes(origin)) return true;
   // wildcard simples: *.vercel.app, *.onrender.com
   for (const entry of corsOrigins) {
     if (entry.startsWith('*.')) {
       const suffix = entry.slice(1); // ".vercel.app"
       if (origin.endsWith(suffix)) return true;
     }
   }
   return false;
 }

 fastify.register(require('@fastify/cors'), {
   origin: (origin, cb) => {
     const o = origin || '';
     const allowAllDev = !corsOrigins.length && process.env.NODE_ENV !== 'production';
     if (allowAllDev) {
       if (!o || defaultDevOrigins.includes(o)) return cb(null, true);
       return cb(null, false);
     }
     if (!o) return cb(null, false);
     if (isAllowedOrigin(o)) return cb(null, true);
     return cb(null, false);
   },
   credentials: true,
   // permitir headers e métodos usados nos endpoints
   allowedHeaders: ['authorization', 'content-type', 'x-refresh-token'],
   exposedHeaders: ['x-new-access-token'],
   methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
   maxAge: 600,
 });
 fastify.get('/health', async () => ({ ok: true }));
// RBAC helpers
const decodeJwt = (token) => {
  try {
    const parts = String(token || '').split('.');
    if (parts.length !== 3) return null;
    const toB64 = (s) => {
      let b64 = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
      const pad = b64.length % 4;
      if (pad) b64 += '='.repeat(4 - pad);
      return b64;
    };
    const payloadJson = Buffer.from(toB64(parts[1]), 'base64').toString('utf8');
    return JSON.parse(payloadJson || '{}');
  } catch (e) {
    return null;
  }
};
const ensureRole = (roles) => async (req, reply) => {
  // API key bypass: se header x-api-key bate, não exige RBAC
  const apiKey = process.env.API_KEY;
  if (apiKey && String(req.headers['x-api-key'] || '') === apiKey) {
    return;
  }
  const auth = String(req.headers['authorization'] || '');
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const payload = decodeJwt(token);
  const userId = payload && payload.sub ? String(payload.sub) : '';
  if (!userId) {
    return reply.code(401).send({ error: 'unauthorized' });
  }

  // Fallback de desenvolvimento: se Supabase não estiver configurado, confia no claim "role" do token
  const supDev = !process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY || /your-project-ref/.test(String(process.env.SUPABASE_URL || ''));
  if (supDev) {
    const role = String((payload && payload.role) || '');
    if (!role || !roles.includes(role)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    req.user = { id: userId, role };
    return;
  }

  try {
    const { data: userRow, error } = await supabase
      .from('users')
      .select('role')
      .eq('id', userId)
      .limit(1)
      .maybeSingle();
    if (error || !userRow || !roles.includes(String(userRow.role || ''))) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    req.user = { id: userId, role: String(userRow.role) };
  } catch (e) {
    req.log.error(e, 'rbac check failed');
    return reply.code(500).send({ error: 'internal_error' });
  }
};
// Auto-refresh on activity: sliding session window (refresh if <5min TTL)
fastify.addHook('preHandler', async (req, reply) => {
  try {
    const path = req.url || '';
    // Skip auth/util routes and webhooks
    if (path.startsWith('/auth') || path.startsWith('/health') || path.startsWith('/debug') || path.startsWith('/webhook')) {
      return;
    }
    const auth = String(req.headers['authorization'] || '');
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!token) return;

    const parts = token.split('.');
    if (parts.length !== 3) return;
    const payloadJson = Buffer.from(parts[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
    const payload = JSON.parse(payloadJson || '{}');
    const exp = Number(payload.exp || 0);
    const now = Math.floor(Date.now() / 1000);
    const secondsLeft = exp - now;
    const threshold = 300; // 5 minutes
    if (secondsLeft > threshold) return;

    const refreshToken = String(req.headers['x-refresh-token'] || '');
    if (!refreshToken) return;

    const anonKey = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || '';
    const supabaseUrl = process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL || '';
    if (!anonKey || !supabaseUrl) return;
 
    const { createClient } = require('@supabase/supabase-js');
    const client = createClient(supabaseUrl, anonKey, { auth: { persistSession: false } });
    const { data, error } = await client.auth.refreshSession({ refresh_token: refreshToken });
    if (!error && data && data.session && data.session.access_token) {
      reply.header('x-new-access-token', data.session.access_token);
    } else if (error) {
      req.log.warn(error, 'auto-refresh failed');
    }
  } catch (e) {
    req.log.warn(e, 'preHandler refresh error');
  }
});
// Debug: check env presence (temporary)
fastify.get('/debug/env', async () => ({
  haveAnonKey: Boolean(process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY),
  haveUrl: Boolean(process.env.SUPABASE_URL || process.env.VITE_SUPABASE_URL),
  haveServiceRole: Boolean(process.env.SUPABASE_SERVICE_ROLE_KEY),
}));
fastify.post('/auth/signup', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
  try {
    const { email, password, name, role, status } = req.body || {};
    if (!email) {
      return reply.code(400).send({ error: 'missing_email' });
    }
    const pwd = password && String(password).length >= 6
      ? String(password)
      : crypto.randomBytes(12).toString('hex');

    const { data, error } = await supabase.auth.admin.createUser({
      email,
      password: pwd,
      email_confirm: true,
      user_metadata: name ? { name } : undefined,
    });
    if (error) return reply.code(400).send({ error: error.message });
    if (data && data.user && data.user.id) {
      try {
        const finalRole = ['Admin','Gerente','Financeiro','Equipe','Aluno'].includes(String(role)) ? String(role) : 'Aluno';
        const finalStatus = ['Ativo','Inativo'].includes(String(status)) ? String(status) : 'Ativo';
        const { error: upErr } = await supabase
          .from('users')
          .upsert({ id: data.user.id, email, name: name || '', role: finalRole, status: finalStatus });
        if (upErr) {
          req.log.warn(upErr, 'users upsert failed');
        }
      } catch (e) {
        req.log.warn(e, 'users insert failed');
      }
    }
    return reply.code(201).send({
      id: data?.user?.id || null,
      email,
      name: name || '',
      role: role && ['Admin','Gerente','Financeiro','Equipe','Aluno'].includes(String(role)) ? String(role) : 'Aluno',
      status: status && ['Ativo','Inativo'].includes(String(status)) ? String(status) : 'Ativo',
      temporary_password: (!password || String(password).length < 6) ? pwd : undefined,
    });
  } catch (e) {
    req.log.error(e, 'auth/signup error');
    return reply.code(500).send({ error: 'internal_error' });
  }
});

// Novo endpoint: convite por email sem expor senha no frontend
fastify.post('/auth/invite', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
  try {
    const { email, name, role, status } = req.body || {};
    if (!email) {
      return reply.code(400).send({ error: 'missing_email' });
    }

    // Tenta usar inviteUserByEmail (envia e-mail de convite com link para definir senha)
    let userId = null;
    let inviteErr = null;
    try {
      if (supabase?.auth?.admin?.inviteUserByEmail) {
        const { data, error } = await supabase.auth.admin.inviteUserByEmail(email, {
          data: name ? { name } : undefined,
        });
        inviteErr = error || null;
        userId = data?.user?.id || null;
      } else {
        inviteErr = new Error('inviteUserByEmail_not_supported');
      }
    } catch (e) {
      inviteErr = e;
    }

    // Fallback: cria usuário com senha aleatória e envia confirmação por e-mail
    if (!userId) {
      const tmpPwd = crypto.randomBytes(12).toString('hex');
      const { data, error } = await supabase.auth.admin.createUser({
        email,
        password: tmpPwd,
        email_confirm: false,
        user_metadata: name ? { name } : undefined,
      });
      if (error) {
        req.log.error({ error, inviteErr }, 'invite/create user failed');
        return reply.code(400).send({ error: error.message || 'invite_failed' });
      }
      userId = data?.user?.id || null;
      // Opcional: poderia gerar link de recuperação aqui se necessário
    }

    // Upsert no perfil de users com role/status
    try {
      const finalRole = ['Admin','Gerente','Financeiro','Equipe','Aluno'].includes(String(role)) ? String(role) : 'Aluno';
      const finalStatus = ['Ativo','Inativo'].includes(String(status)) ? String(status) : 'Ativo';
      const { error: upErr } = await supabase
        .from('users')
        .upsert({ id: userId, email, name: name || '', role: finalRole, status: finalStatus });
      if (upErr) {
        req.log.warn(upErr, 'users upsert failed (invite)');
      }
    } catch (e) {
      req.log.warn(e, 'users upsert error (invite)');
    }

    return reply.code(201).send({
      id: userId,
      email,
      name: name || '',
      role: role && ['Admin','Gerente','Financeiro','Equipe','Aluno'].includes(String(role)) ? String(role) : 'Aluno',
      status: status && ['Ativo','Inativo'].includes(String(status)) ? String(status) : 'Ativo',
      invited: true,
    });
  } catch (e) {
    req.log.error(e, 'auth/invite error');
    return reply.code(500).send({ error: 'internal_error' });
  }
});
fastify.post('/auth/login', async (req, reply) => {
  try {
    const { email, password } = req.body || {};
    if (!email || !password) {
      return reply.code(400).send({ error: 'missing_email_or_password' });
    }

    // Fallback de desenvolvimento: permite login com credenciais de teste sem Supabase
    const hasAnonKey = Boolean(process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY);
    const devFake = String(process.env.DEV_FAKE_LOGIN || 'false') === 'true'
      || !process.env.SUPABASE_URL
      || !hasAnonKey
      || /your-project-ref/.test(String(process.env.SUPABASE_URL || ''));
    if (devFake) {
      const devEmail = process.env.DEV_TEST_EMAIL || 'diogomat11@gmail.com';
      const devPass = process.env.DEV_TEST_PASSWORD || 'Juart2025@';
      if (email === devEmail && password === devPass) {
        const now = Math.floor(Date.now() / 1000);
        const exp = now + 3600; // 1h
        const header = { alg: 'none', typ: 'JWT' };
        const payload = { sub: 'dev-user-1', email, role: 'Admin', exp };
        const toB64Url = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
        const access_token = `${toB64Url(header)}.${toB64Url(payload)}.dev`;
        const refresh_token = `dev-${crypto.randomBytes(16).toString('hex')}`;
        const user = { id: 'dev-user-1', email, name: 'Dev User', role: 'Admin', status: 'Ativo' };
        return reply.code(200).send({ access_token, refresh_token, expires_at: exp, user });
      }
    }

    const anonKey = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || '';
    if (!anonKey) {
      return reply.code(500).send({ error: 'auth_not_configured' });
    }
    const { createClient } = require('@supabase/supabase-js');
    const url = process.env.SUPABASE_URL;
    const client = createClient(url, anonKey, { auth: { persistSession: false } });
    const { data, error } = await client.auth.signInWithPassword({ email, password, options: { expiresIn: 1200 } });
    if (error) return reply.code(401).send({ error: error.message });
    return reply.code(200).send({
      access_token: data.session?.access_token || null,
      refresh_token: data.session?.refresh_token || null,
      expires_at: data.session?.expires_at || null,
      user: data.user || null,
    });
  } catch (e) {
    req.log.error(e, 'auth/login error');
    return reply.code(500).send({ error: 'internal_error' });
  }
});
fastify.post('/auth/refresh', async (req, reply) => {
  try {
    const { refresh_token } = req.body || {};
    if (!refresh_token) return reply.code(400).send({ error: 'missing_refresh_token' });
    const anonKey = process.env.SUPABASE_ANON_KEY || process.env.VITE_SUPABASE_ANON_KEY || '';
    if (!anonKey) return reply.code(500).send({ error: 'auth_not_configured' });
    const { createClient } = require('@supabase/supabase-js');
    const url = process.env.SUPABASE_URL;
    const client = createClient(url, anonKey, { auth: { persistSession: false } });
    const { data, error } = await client.auth.refreshSession({ refresh_token });
    if (error) return reply.code(401).send({ error: error.message });
    return reply.code(200).send({
      access_token: data.session?.access_token || null,
      expires_at: data.session?.expires_at || null,
      user: data.user || null,
    });
  } catch (e) {
    req.log.error(e, 'auth/refresh error');
    return reply.code(500).send({ error: 'internal_error' });
  }
});
fastify.post('/auth/logout', async (req, reply) => {
  try {
    const auth = String(req.headers['authorization'] || '')
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
    if (!token) return reply.code(400).send({ error: 'missing_bearer_token' })
    const userClient = createUserClient(token)
    if (!userClient) return reply.code(500).send({ error: 'auth_not_configured' })
    const { error } = await userClient.auth.signOut()
    if (error) return reply.code(400).send({ error: error.message })
    return reply.code(200).send({ ok: true })
  } catch (e) {
    req.log.error(e, 'auth/logout error')
    return reply.code(500).send({ error: 'internal_error' })
  }
})

// Novo endpoint: usuário atual
fastify.get('/users/me', async (req, reply) => {
  try {
    const auth = String(req.headers['authorization'] || '')
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : ''
    if (!token) return reply.code(401).send({ error: 'unauthorized' })

    const payload = decodeJwt(token)
    const userId = payload && payload.sub ? String(payload.sub) : ''
    if (!userId) return reply.code(401).send({ error: 'unauthorized' })

    // Fallback de desenvolvimento: se Supabase não estiver configurado ou em placeholder, devolve usuário do token
    const supDev = !process.env.SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY || /your-project-ref/.test(String(process.env.SUPABASE_URL || ''))
    if (supDev) {
      const role = String((payload && payload.role) || 'Admin')
      const emailClaim = String((payload && payload.email) || '')
      const user = { id: userId, email: emailClaim || 'dev@example.com', name: 'Dev User', role, status: 'Ativo' }
      return reply.code(200).send(user)
    }

    const { data, error } = await supabase
      .from('users')
      .select('id,email,name,role,status')
      .eq('id', userId)
      .limit(1)
      .maybeSingle()

    if (error) return reply.code(500).send({ error: error.message || 'internal_error' })
    if (!data) return reply.code(404).send({ error: 'not_found' })

    return reply.code(200).send(data)
  } catch (e) {
    req.log.error(e, 'users/me error')
    return reply.code(500).send({ error: 'internal_error' })
  }
})
 
 // Endpoint de teste direto (sem Supabase), protegido por API_KEY
 fastify.post('/test/send-whatsapp', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
   const apiKey = process.env.API_KEY;
   if (apiKey && String(req.headers['x-api-key'] || '') !== apiKey) {
     // Se API key não bater, já passou pelo RBAC no preHandler
   }
   try {
     const { phone, message } = req.body || {};
     const sendRes = await sendWhatsApp({ phone, message });
     if (sendRes.ok) {
       return reply.code(200).send({ status: 'Sent', provider: sendRes.provider, id: sendRes.id || null });
     }
     return reply.code(502).send({ status: 'Failed', error: sendRes.error || 'unknown_error' });
   } catch (e) {
     req.log.error(e, 'test/send-whatsapp error');
     return reply.code(500).send({ error: 'internal_error' });
   }
 });
 fastify.post('/invoices/:id/send-whatsapp', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
   const apiKey = process.env.API_KEY;
   if (apiKey && String(req.headers['x-api-key'] || '') !== apiKey) {
     // Se API key não bater, já passou pelo RBAC no preHandler
   }
   try {
     const invoiceId = String(req.params.id);
     const phoneOverride = req.body && req.body.phone ? String(req.body.phone) : null;

     // Cria entrada na outbox usando função 0018
     const { data: queuedId, error: queueErr } = await supabase.rpc('queue_invoice_whatsapp', {
       p_invoice_id: invoiceId,
       p_phone_override: phoneOverride,
     });
     if (queueErr) {
       req.log.error(queueErr, 'queue_invoice_whatsapp error');
       return reply.code(400).send({ error: queueErr.message });
     }

     // Busca mensagem e telefone para enviar
     const { data: outboxRow, error: fetchErr } = await supabase
       .from('whatsapp_outbox')
       .select('phone,message')
       .eq('id', queuedId)
       .maybeSingle();

     if (fetchErr) {
       req.log.error(fetchErr, 'fetch outbox error');
       return reply.code(500).send({ error: fetchErr.message, outboxId: queuedId });
     }
     if (!outboxRow) {
       return reply.code(404).send({ error: 'outbox_not_found', outboxId: queuedId });
     }

     const sendRes = await sendWhatsApp({ phone: outboxRow.phone, message: outboxRow.message });
     if (sendRes.ok) {
       // Marca como enviado
       const { error: markErr } = await supabase.rpc('mark_whatsapp_sent', { p_outbox_id: queuedId });
       if (markErr) {
         req.log.error(markErr, 'mark_whatsapp_sent error');
         // Retorna 200, mas sinaliza problema no pós-processamento
         return reply.code(200).send({ outboxId: queuedId, status: 'Sent', warn: 'mark_update_failed' });
       }
       return reply.code(200).send({ outboxId: queuedId, status: 'Sent' });
     } else {
       const errorText = sendRes.error || 'unknown_error';
       const { error: failErr } = await supabase.rpc('mark_whatsapp_failed', {
         p_outbox_id: queuedId,
         p_error: errorText,
       });
       if (failErr) {
         req.log.error(failErr, 'mark_whatsapp_failed error');
       }
       return reply.code(502).send({ outboxId: queuedId, status: 'Failed', error: errorText });
     }
   } catch (e) {
     req.log.error(e, 'unexpected error');
     return reply.code(500).send({ error: 'internal_error' });
  }
 });

 // Marcar fatura como paga
 fastify.put('/invoices/:id/mark-paid', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
   try {
     const invoiceId = String(req.params.id);
     const {
       payment_method = 'PIX',
       paid_at = new Date().toISOString(),
       receipt_url = null,
       professional_id = null,
     } = req.body || {};

     const { error } = await supabase.rpc('mark_invoice_paid', {
       p_invoice_id: invoiceId,
       p_payment_method: payment_method,
       p_paid_at: paid_at,
       p_receipt_url: receipt_url,
       p_professional_id: professional_id,
     });
     if (error) {
       req.log.error(error, 'mark_invoice_paid error');
       return reply.code(400).send({ error: error.message });
     }
     return reply.code(200).send({ ok: true });
   } catch (e) {
     req.log.error(e, 'invoices mark-paid unexpected error');
     return reply.code(500).send({ error: 'internal_error' });
   }
 });

 // Marcar despesa como paga
 fastify.put('/expenses/:id/mark-paid', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
   try {
     const expenseId = String(req.params.id);
     const { error } = await supabase
       .from('expenses')
       .update({ status: 'Paga' })
       .eq('id', expenseId);
     if (error) {
       req.log.error(error, 'expenses update mark-paid error');
       return reply.code(400).send({ error: error.message });
     }
     return reply.code(200).send({ ok: true });
   } catch (e) {
     req.log.error(e, 'expenses mark-paid unexpected error');
     return reply.code(500).send({ error: 'internal_error' });
   }
 });

 // Marcar repasse como pago
 fastify.put('/repasses/:id/mark-paid', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
   try {
     const repassId = String(req.params.id);
     const {
       paid_at = new Date().toISOString(),
       receipt_url = null,
     } = req.body || {};

     const { error } = await supabase.rpc('mark_repass_paid', {
       p_repass_id: repassId,
       p_paid_at: paid_at,
       p_receipt_url: receipt_url,
     });
     if (error) {
       req.log.error(error, 'mark_repass_paid error');
       return reply.code(400).send({ error: error.message });
     }
     return reply.code(200).send({ ok: true });
   } catch (e) {
     req.log.error(e, 'repasses mark-paid unexpected error');
     return reply.code(500).send({ error: 'internal_error' });
   }
 });

 fastify.get('/webhook/whatsapp', async (req, reply) => {
   const mode = req.query['hub.mode'];
   const token = req.query['hub.verify_token'];
   const challenge = req.query['hub.challenge'];
   const expected = process.env.WHATSAPP_VERIFY_TOKEN;
   if (mode === 'subscribe' && expected && token === expected) {
     return reply.code(200).send(challenge || '');
   }
   return reply.code(403).send('');
 })
 fastify.post('/webhook/whatsapp', async (req, reply) => {
   const secret = process.env.META_APP_SECRET;
   const strict = String(process.env.STRICT_WEBHOOK_SIGNATURE || 'false') === 'true';
   const signature = String(req.headers['x-hub-signature-256'] || '');
   if (secret && signature) {
     try {
       const hmac = crypto.createHmac('sha256', secret)
         .update(JSON.stringify(req.body || {}))
         .digest('hex');
       const expected = `sha256=${hmac}`;
       if (strict && signature !== expected) {
         req.log.warn({ got: signature, expected }, 'invalid webhook signature');
         return reply.code(403).send({ error: 'invalid_signature' });
       }
     } catch (e) {
       req.log.error(e, 'signature calc error');
       if (strict) return reply.code(500).send({ error: 'signature_error' });
     }
   }
   req.log.info({ body: req.body }, 'whatsapp webhook received');
   return reply.code(200).send({ ok: true });
 })
 fastify.post('/test/seed-outbox', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (request, reply) => {
   // Proteção mínima por API key
   const apiKey = request.headers['x-api-key'];
   if (!apiKey || apiKey !== process.env.API_KEY) {
     // Se API key não bater, já passou pelo RBAC no preHandler
   }
   const { phone, message } = request.body || {};
   if (!phone || !message) {
     reply.code(400);
     return { error: 'Body must include phone and message' };
   }

   try {
     const { data, error } = await supabase
       .from('whatsapp_outbox')
       .insert([{ phone, message, status: 'Pending' }])
       .select('id')
       .limit(1)
       .maybeSingle();

     if (error) {
       fastify.log.error({ error }, 'Failed to insert outbox');
       reply.code(500);
       return { error: 'Failed to insert outbox' };
     }

     return { id: data?.id ?? null, status: 'Queued' };
   } catch (err) {
     fastify.log.error({ err }, 'Unexpected error inserting outbox');
     reply.code(500);
     return { error: 'Unexpected error' };
   }
 });
 // Admin: atualizar role do usuário
 fastify.patch('/users/:id/role', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
   try {
     const userId = String(req.params.id || '')
     const role = String((req.body || {}).role || '')
     const allowed = ['Admin','Gerente','Financeiro','Equipe','Aluno']
     if (!userId) return reply.code(400).send({ error: 'missing_user_id' })
     if (!allowed.includes(role)) return reply.code(400).send({ error: 'invalid_role' })

     const { data, error } = await supabase
       .from('users')
       .update({ role })
       .eq('id', userId)
       .select('id,email,name,role,status')
       .limit(1)
       .maybeSingle()

     if (error) return reply.code(500).send({ error: error.message || 'internal_error' })
     if (!data) return reply.code(404).send({ error: 'not_found' })
     return reply.code(200).send(data)
   } catch (e) {
     req.log.error(e, 'users/role patch error')
     return reply.code(500).send({ error: 'internal_error' })
   }
 })
 // Admin: buscar usuários por email ou id
 fastify.get('/users', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
   try {
     const email = String((req.query || {}).email || '')
     const id = String((req.query || {}).id || '')
     if (!email && !id) return reply.code(400).send({ error: 'missing_email_or_id' })

     let q = supabase
       .from('users')
       .select('id,email,name,role,status')
       .limit(10)

     if (email) q = q.eq('email', email)
     if (id) q = q.eq('id', id)

     const { data, error } = await q
     if (error) return reply.code(500).send({ error: error.message || 'internal_error' })
     if (!data || data.length === 0) return reply.code(404).send({ error: 'not_found' })
     return reply.code(200).send(Array.isArray(data) ? data : [data])
   } catch (e) {
     req.log.error(e, 'users search error')
     return reply.code(500).send({ error: 'internal_error' })
   }
 })
 // Rotas de Unidades
  fastify.get('/units', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    const { q } = req.query || {};
    let query = supabase.from('units').select('*').order('name', { ascending: true });
    if (q && typeof q === 'string' && q.trim() !== '') {
      query = query.ilike('name', `%${q.trim()}%`);
    }
    const { data, error } = await query;
    if (error) {
      req.log.error({ error }, 'Failed to fetch units');
      return reply.code(500).send({ error: 'internal_error' });
    }
    return reply.code(200).send(Array.isArray(data) ? data : []);
  });

 fastify.post('/units', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    const payload = req.body || {};
    const { data, error } = await supabase.from('units').insert(payload).select().single();
    if (error) {
      req.log.error({ error }, 'Failed to create unit');
      return reply.code(500).send({ error: 'internal_error' });
    }
    return reply.code(201).send(data || null);
  });

  fastify.put('/units/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    const { id } = req.params;
    const payload = req.body || {};
    const { data, error } = await supabase.from('units').update(payload).eq('id', id).select().single();
    if (error) {
      req.log.error({ error }, 'Failed to update unit');
      return reply.code(500).send({ error: 'internal_error' });
    }
    return reply.code(200).send(data || null);
  });

  // Rotas de Alunos
  fastify.get('/students', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const { q } = req.query || {};
      let query = supabase
        .from('students')
        .select('id,name,cpf,birthdate,start_date,leaving_date,payment_method,address,guardian_name,guardian_phone,guardian_email,guardian_cpf,status,unit_id,class_id,plan_id,recurrence_id,created_at,updated_at')
        .order('name', { ascending: true });
      if (q && typeof q === 'string' && q.trim() !== '') {
        const term = `%${q.trim()}%`;
        // Busca por nome ou CPF
        query = query.ilike('name', term);
      }
      const { data, error } = await query;
      if (error) {
        req.log.error({ error }, 'Failed to fetch students');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(Array.isArray(data) ? data : []);
    } catch (e) {
      req.log.error(e, 'students list error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.post('/students', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const payload = req.body || {};
      const normalized = { ...payload };
      const st = String(normalized.status || '').trim();
      if ((st === 'Inativo' || st === 'Inactive') && !normalized.leaving_date) {
        const today = new Date();
        normalized.leaving_date = today.toISOString().slice(0, 10);
      }
      const { data, error } = await supabase
        .from('students')
        .insert(normalized)
        .select()
        .single();
      if (error) {
        req.log.error({ error }, 'Failed to create student');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(201).send(data || null);
    } catch (e) {
      req.log.error(e, 'students create error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.put('/students/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const { id } = req.params;
      const payload = req.body || {};
      const normalized = { ...payload };
      const st = String(normalized.status || '').trim();
      if ((st === 'Inativo' || st === 'Inactive') && !normalized.leaving_date) {
        const today = new Date();
        normalized.leaving_date = today.toISOString().slice(0, 10);
      }
      const { data, error } = await supabase
        .from('students')
        .update(normalized)
        .eq('id', id)
        .select()
        .single();
      if (error) {
        req.log.error({ error }, 'Failed to update student');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(data || null);
    } catch (e) {
      req.log.error(e, 'students update error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Plans (Plano)
  fastify.get('/plans', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const { unit_id, status } = req.query || {};
      let query = supabase
        .from('plans')
        .select('id,name,unit_id,frequency_per_week,value,start_date,end_date,status')
        .order('name', { ascending: true });
      if (unit_id) query = query.eq('unit_id', unit_id);
      if (status) query = query.eq('status', status);
      const { data, error } = await query;
      if (error) {
        req.log.error({ error }, 'Failed to fetch plans');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(Array.isArray(data) ? data : []);
    } catch (e) {
      req.log.error(e, 'plans list error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Classes (Turmas)
  fastify.get('/classes', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const { unit_id, status } = req.query || {};
      let query = supabase
        .from('classes')
        .select('id,unit_id,name,category,vacancies,status,schedule,teacher_ids')
        .order('name', { ascending: true });
      if (unit_id) query = query.eq('unit_id', unit_id);
      if (status) query = query.eq('status', status);
      const { data, error } = await query;
      if (error) {
        req.log.error({ error }, 'Failed to fetch classes');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(Array.isArray(data) ? data : []);
    } catch (e) {
      req.log.error(e, 'classes list error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Create class
  fastify.post('/classes', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const body = req.body || {};
      const normalized = {
        unit_id: String(body.unit_id || '').trim(),
        name: String(body.name || '').trim(),
        category: typeof body.category === 'string' ? body.category : null,
        vacancies: Number.isFinite(body.vacancies) ? Number(body.vacancies) : 0,
        status: String(body.status || 'Ativo'),
        schedule: (body.schedule && typeof body.schedule === 'object') ? body.schedule : { slots: [] },
        teacher_ids: Array.isArray(body.teacher_ids) ? body.teacher_ids : [],
      };
      if (!normalized.unit_id || !normalized.name) {
        return reply.code(400).send({ error: 'invalid_payload' });
      }
      const { data, error } = await supabase
        .from('classes')
        .insert(normalized)
        .select('id,unit_id,name,category,vacancies,status,schedule,teacher_ids')
        .maybeSingle();
      if (error) {
        req.log.error({ error }, 'Failed to create class');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(data || null);
    } catch (e) {
      req.log.error(e, 'classes create error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Update class
  fastify.put('/classes/:id', { preHandler: ensureRole(['Admin','Gerente']) }, async (req, reply) => {
    try {
      const id = String((req.params || {}).id || '').trim();
      if (!id) return reply.code(400).send({ error: 'invalid_id' });
      const body = req.body || {};
      const patch = {};
      if (body.unit_id !== undefined) patch.unit_id = String(body.unit_id);
      if (body.name !== undefined) patch.name = String(body.name || '');
      if (body.category !== undefined) patch.category = body.category ?? null;
      if (body.vacancies !== undefined) patch.vacancies = Number.isFinite(body.vacancies) ? Number(body.vacancies) : 0;
      if (body.status !== undefined) patch.status = String(body.status || 'Ativo');
      if (body.schedule !== undefined) patch.schedule = body.schedule;
      if (body.teacher_ids !== undefined) patch.teacher_ids = Array.isArray(body.teacher_ids) ? body.teacher_ids : [];

      const { data, error } = await supabase
        .from('classes')
        .update(patch)
        .eq('id', id)
        .select('id,unit_id,name,category,vacancies,status,schedule,teacher_ids')
        .maybeSingle();
      if (error) {
        req.log.error({ error }, 'Failed to update class');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(data || null);
    } catch (e) {
      req.log.error(e, 'classes update error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Delete class
  fastify.delete('/classes/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const id = String((req.params || {}).id || '').trim();
      if (!id) return reply.code(400).send({ error: 'invalid_id' });
      const { error } = await supabase
        .from('classes')
        .delete()
        .eq('id', id);
      if (error) {
        req.log.error({ error }, 'Failed to delete class');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send({ ok: true });
    } catch (e) {
      req.log.error(e, 'classes delete error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Recurrences (Recorrências)
  fastify.get('/recurrences', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const { status } = req.query || {};
      let query = supabase
        .from('recurrences')
        .select('id,type,discount_percent,start_date,end_date,units_applicable,status')
        .order('start_date', { ascending: true });
      if (status) query = query.eq('status', status);
      const { data, error } = await query;
      if (error) {
        req.log.error({ error }, 'Failed to fetch recurrences');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(Array.isArray(data) ? data : []);
    } catch (e) {
      req.log.error(e, 'recurrences list error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.delete('/students/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const { id } = req.params;
      const { error } = await supabase
        .from('students')
        .delete()
        .eq('id', id);
      if (error) {
        req.log.error({ error }, 'Failed to delete student');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(204).send();
    } catch (e) {
      req.log.error(e, 'students delete error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  // Rotas de Profissionais (Equipe)
  fastify.get('/professionals', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const { q } = req.query || {};
      let query = supabase
        .from('professionals')
        .select('id,name,cpf,role_position,salary,specialties,phone,email,unit_ids,hired_at,status,created_at,updated_at')
        .order('name', { ascending: true });
      if (q && typeof q === 'string' && q.trim() !== '') {
        const term = `%${q.trim()}%`;
        query = query.ilike('name', term);
      }
      const { data, error } = await query;
      if (error) {
        req.log.error({ error }, 'Failed to fetch professionals');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(Array.isArray(data) ? data : []);
    } catch (e) {
      req.log.error(e, 'professionals list error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.post('/professionals', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const payload = req.body || {};
      const { data, error } = await supabase
        .from('professionals')
        .insert(payload)
        .select()
        .single();
      if (error) {
        req.log.error({ error }, 'Failed to create professional');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(201).send(data || null);
    } catch (e) {
      req.log.error(e, 'professionals create error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.put('/professionals/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const { id } = req.params;
      const payload = req.body || {};
      const { data, error } = await supabase
        .from('professionals')
        .update(payload)
        .eq('id', id)
        .select()
        .single();
      if (error) {
        req.log.error({ error }, 'Failed to update professional');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(200).send(data || null);
    } catch (e) {
      req.log.error(e, 'professionals update error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

  fastify.delete('/professionals/:id', { preHandler: ensureRole(['Admin']) }, async (req, reply) => {
    try {
      const { id } = req.params;
      const { error } = await supabase
        .from('professionals')
        .delete()
        .eq('id', id);
      if (error) {
        req.log.error({ error }, 'Failed to delete professional');
        return reply.code(500).send({ error: 'internal_error' });
      }
      return reply.code(204).send();
    } catch (e) {
      req.log.error(e, 'professionals delete error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });

 const port = Number(process.env.PORT || 3001);
 fastify.listen({ port, host: '0.0.0.0' }).catch((err) => {
   fastify.log.error(err);
   process.exit(1);
 });
  // Dashboard metrics
  fastify.get('/dashboard/metrics', { preHandler: ensureRole(['Admin','Gerente','Financeiro']) }, async (req, reply) => {
    try {
      const now = new Date();
      const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
      const monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0);
      const sixMonthsAgo = new Date(now.getFullYear(), now.getMonth() - 6, now.getDate());

      const iso = (d) => new Date(d).toISOString().slice(0, 10);

      // Total unidades ativas
      const { data: units, error: unitsErr } = await supabase
        .from('units')
        .select('id,status');
      if (unitsErr) throw new Error(unitsErr.message);
      const totalUnidades = (units || []).filter(u => u.status === 'Ativa' || u.status === 'Active').length;

      // Total alunos ativos
      const { data: students, error: studentsErr } = await supabase
        .from('students')
        .select('id,status,leaving_date');
      if (studentsErr) throw new Error(studentsErr.message);
      const totalAlunos = (students || []).filter(s => s.status === 'Ativo' || s.status === 'Active').length;

      // Faturamento mensal: invoices pagas no mês
      let invQuery = supabase
        .from('invoices')
        .select('amount_net, unit_id, student_id, status, paid_at')
        .gte('paid_at', iso(monthStart))
        .lte('paid_at', iso(monthEnd))
        .eq('status', 'Paga');
      const { data: invoices, error: invErr } = await invQuery;
      if (invErr) throw new Error(invErr.message);
      const faturamentoMensal = (invoices || []).reduce((sum, i) => sum + Number(i.amount_net || 0), 0);

      // Inadimplência: considera faturas do mês (por due_date), não pagas/canceladas.
      // Conta como 'vencida' se due_date < hoje, independentemente do status persistido.
      const todayIso = now.toISOString().slice(0, 10);
      const { data: monthInv, error: monthInvErr } = await supabase
        .from('invoices')
        .select('id,status,due_date')
        .gte('due_date', iso(monthStart))
        .lte('due_date', iso(monthEnd));
      if (monthInvErr) throw new Error(monthInvErr.message);
      const relevantes = (monthInv || []).filter((i) => i.status !== 'Paga' && i.status !== 'Cancelada');
      const vencidasDerivadas = relevantes.filter((i) => String(i.due_date || '') < todayIso).length;
      const base = relevantes.length;
      const inadimplencia = base > 0 ? Number(((vencidasDerivadas / base) * 100).toFixed(2)) : 0;

      // Churn 6 meses: alunos que tiveram leaving_date nos últimos 6 meses sobre base ativa
      const { data: leavers, error: leaversErr } = await supabase
        .from('students')
        .select('id,leaving_date')
        .gte('leaving_date', iso(sixMonthsAgo))
        .lte('leaving_date', iso(now));
      if (leaversErr) throw new Error(leaversErr.message);
      const churn = totalAlunos > 0 ? Number((((leavers || []).length / totalAlunos) * 100).toFixed(2)) : 0;

      // Receita por unidade (mês atual)
      const unitMap = new Map((units || []).map(u => [u.id, u.name || u.nome || u.id]));
      const receitaPorUnidadeAgg = new Map();
      const alunosPorUnidadeAgg = new Map();
      (invoices || []).forEach((inv) => {
        const uid = inv.unit_id || '—';
        const prev = receitaPorUnidadeAgg.get(uid) || 0;
        receitaPorUnidadeAgg.set(uid, prev + Number(inv.amount_net || 0));
        const stuSet = alunosPorUnidadeAgg.get(uid) || new Set();
        if (inv.student_id) stuSet.add(inv.student_id);
        alunosPorUnidadeAgg.set(uid, stuSet);
      });
      const receitaPorUnidade = Array.from(receitaPorUnidadeAgg.entries()).map(([uid, receita]) => ({
        unidade: unitMap.get(uid) || uid,
        receita,
        alunos: (alunosPorUnidadeAgg.get(uid) || new Set()).size,
      }));

      // Evolução de faturamento (últimos 5 meses)
      const monthLabel = (d) => d.toLocaleString('pt-BR', { month: 'short' }).replace('.', '')
        .replace(/\b\w/g, (c) => c.toUpperCase());
      const evolucaoFaturamento = [];
      for (let i = 4; i >= 0; i--) {
        const start = new Date(now.getFullYear(), now.getMonth() - i, 1);
        const end = new Date(now.getFullYear(), now.getMonth() - i + 1, 0);
        const { data: invM, error: invMErr } = await supabase
          .from('invoices')
          .select('amount_net,status,paid_at')
          .gte('paid_at', iso(start))
          .lte('paid_at', iso(end))
          .eq('status', 'Paga');
        if (invMErr) throw new Error(invMErr.message);
        const receita = (invM || []).reduce((s, r) => s + Number(r.amount_net || 0), 0);
        const { data: expM, error: expMErr } = await supabase
          .from('expenses')
          .select('amount,status,expense_date')
          .gte('expense_date', iso(start))
          .lte('expense_date', iso(end))
          .eq('status', 'Paga');
        if (expMErr) throw new Error(expMErr.message);
        const despesas = (expM || []).reduce((s, r) => s + Number(r.amount || 0), 0);
        const lucro = receita - despesas;
        evolucaoFaturamento.push({ mes: monthLabel(start), receita, despesas, lucro });
      }

      return reply.code(200).send({
        totalUnidades,
        totalAlunos,
        faturamentoMensal,
        inadimplencia,
        churn,
        receitaPorUnidade,
        evolucaoFaturamento,
      });
    } catch (e) {
      req.log.error(e, 'dashboard metrics error');
      return reply.code(500).send({ error: 'internal_error' });
    }
  });