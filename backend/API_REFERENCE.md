# API de Backend — Guia Rápido para o Frontend

Base local: `http://127.0.0.1:3001`
TTL sessão: `20 minutos` (login) com janela deslizante e auto-refresh quando faltam <5 min.
CORS dev: `http://localhost:5173,http://127.0.0.1:5173` (fallback automático). Em produção, defina `CORS_ORIGINS`.

## Autenticação

- POST `/auth/signup`
  - Body: `{ email, password, name? }`
  - 201: `{ user_id }`
  - 400: `{ error: 'missing_email_or_password' | <mensagem_supabase> }`

- POST `/auth/login`
  - Body: `{ email, password }`
  - 200: `{ access_token, refresh_token, expires_at, user }`
  - 401: `{ error: <mensagem_supabase> }`
  - Observações:
    - `expires_in` fixado em 1200s (20 min).
    - Armazene `access_token` e `refresh_token` com segurança (secure storage).

- POST `/auth/refresh`
  - Body: `{ refresh_token }`
  - 200: `{ access_token, expires_at, user }`
  - 401: `{ error: <mensagem_supabase> }`

- POST `/auth/logout`
  - Headers: `Authorization: Bearer <access_token>`
  - 200: `{ ok: true }`

### Auto-refresh (sliding window)
- Para qualquer rota (exceto `/auth`, `/health`, `/debug`, `/webhook`):
  - Se o `access_token` expira em <5 min e o request incluir `x-refresh-token: <refresh_token>`,
    o servidor tenta renovar e retorna `x-new-access-token: <token>` no header da resposta.
  - O frontend deve capturar `x-new-access-token` e atualizar o token em memória/armazenamento.

## RBAC e API Key

- RBAC: `ensureRole([...])` consulta a role do usuário em `users`.
  - Sem bearer ou role inadequada: `401/403`.
- Bypass com `x-api-key`: se `x-api-key` for igual a `API_KEY` do ambiente, o RBAC é dispensado.
  - Em dev, `API_KEY=dev-key` (não usar em produção).

## WhatsApp (stub) e Outbox

- POST `/test/send-whatsapp`
  - Protegido por RBAC (roles `Admin, Gerente, Financeiro`) ou `x-api-key`.
  - Body: `{ phone, message }`
  - 200: `{ status: 'Sent', provider: 'stub', id: <opcional> }`

- POST `/test/seed-outbox`
  - Protegido por RBAC (mesmas roles) ou `x-api-key`.
  - Body: `{ phone, message }`
  - 200: `{ id, status: 'Queued' }`
  - Requer Supabase configurado (`SUPABASE_URL` e `SERVICE_ROLE_KEY`).

## Webhooks (Meta / WhatsApp)

- GET `/webhook/whatsapp`
  - Handshake: aceita `hub.mode=subscribe` com `hub.verify_token` igual ao `WHATSAPP_VERIFY_TOKEN`.

- POST `/webhook/whatsapp`
  - Header opcional: `x-hub-signature-256`.
  - Se `STRICT_WEBHOOK_SIGNATURE=true` e `META_APP_SECRET` presentes:
    - Se assinatura diferente do esperado: `403 { error: 'invalid_signature' }`.

## Utilitários

- GET `/health` → `{ ok: true }`
- GET `/debug/env` → `{ haveAnonKey, haveUrl, haveServiceRole }`

## Exemplo de cliente Axios (frontend)

```ts
import axios from 'axios';

const api = axios.create({ baseURL: import.meta.env.VITE_API_BASE_URL });

// Store simples de exemplo
const authStore = {
  accessToken: '',
  refreshToken: '',
  setTokens(at: string, rt: string) { this.accessToken = at; this.refreshToken = rt; },
  setAccessToken(at: string) { this.accessToken = at; }
};

api.interceptors.request.use((config) => {
  const at = authStore.accessToken;
  const rt = authStore.refreshToken;
  if (at) config.headers.Authorization = `Bearer ${at}`;
  if (rt) config.headers['x-refresh-token'] = rt; // habilita auto-refresh do backend
  return config;
});

api.interceptors.response.use((res) => {
  const newToken = res.headers['x-new-access-token'] as string | undefined;
  if (newToken) authStore.setAccessToken(newToken);
  return res;
}, (err) => {
  if (err.response?.status === 401) {
    // Opcional: redirecionar para login ou tentar refresh manual
  }
  return Promise.reject(err);
});

// Fluxo de login
export async function login(email: string, password: string) {
  const { data } = await api.post('/auth/login', { email, password });
  authStore.setTokens(data.access_token, data.refresh_token);
  return data.user;
}

// Refresh manual (se necessário)
export async function refresh() {
  const { data } = await api.post('/auth/refresh', { refresh_token: authStore.refreshToken });
  authStore.setAccessToken(data.access_token);
}

// Logout
export async function logout() {
  await api.post('/auth/logout', {}, { headers: { Authorization: `Bearer ${authStore.accessToken}` } });
  authStore.setTokens('', '');
}
```

## Notas de Ambiente

- Dev: `API_KEY=dev-key`, `WHATSAPP_PROVIDER=stub` (env no `backend/.env`).
- Produção: defina `CORS_ORIGINS` com domínios reais do frontend, `API_KEY` forte e `STRICT_WEBHOOK_SIGNATURE=true` com `META_APP_SECRET`.