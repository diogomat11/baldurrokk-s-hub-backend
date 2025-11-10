# Coelho FC Backend (mínimo)

[![Backend CI](https://img.shields.io/badge/CI-backend--ci-blue)](../.github/workflows/backend-ci.yml) [![DLQ CI](https://img.shields.io/badge/CI-backend--ci--dlq-blue)](../.github/workflows/backend-ci-dlq.yml)

Backend mínimo com Fastify para envio de WhatsApp de cobranças.

## Requisitos
- Node.js 18+
- Variáveis de ambiente:
  - `SUPABASE_URL`
  - `SUPABASE_SERVICE_ROLE_KEY`
  - `PORT` (opcional, padrão 3001)
  - `API_KEY` (protege o endpoint; envia no header `x-api-key`)
  - `WHATSAPP_PROVIDER` ("stub" por padrão; "meta" para WhatsApp Cloud)
  - `WHATSAPP_PHONE_NUMBER_ID` (provider Meta)
  - `WHATSAPP_TOKEN` (provider Meta)
  - `WHATSAPP_VERIFY_TOKEN` (verificação do webhook GET)
  - `META_APP_SECRET` (opcional, para assinatura HMAC do webhook)
  - `STRICT_WEBHOOK_SIGNATURE` (true/false; exige assinatura válida no webhook)
  - `WORKER_BATCH_SIZE` (padrão 10)
  - `WORKER_INTERVAL_MS` (padrão 10000)
  - `DRY_RUN` (true/false; não envia, apenas logs)

## Instalação

```bash
cd backend
npm install
cp .env.example .env
# edite .env com SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY
npm run dev
```

## Endpoints
- `GET /health` — verificação básica
- `POST /invoices/:id/send-whatsapp` — enfileira e envia mensagem do WhatsApp para a fatura
  - Header: `x-api-key: <API_KEY>` (se `API_KEY` estiver configurado)
  - Body opcional: `{ "phone": "+55DDDNUMERO" }` para sobrescrever telefone
  - Retornos:
    - `200 { outboxId, status: "Sent" }`
    - `502 { outboxId, status: "Failed", error }`
- `POST /test/send-whatsapp` — envio direto via provider (sem Supabase)
  - Header: `x-api-key: <API_KEY>`
  - Body: `{ "phone": "+55DDDNUMERO", "message": "texto" }`
  - Usado para validar configuração do provider.
- `GET /webhook/whatsapp` — verificação do webhook (Meta)
  - Query: `hub.mode=subscribe&hub.verify_token=<token>&hub.challenge=<str>`
  - Responde `200 <challenge>` se `WHATSAPP_VERIFY_TOKEN` bater; senão `403`.
- `POST /webhook/whatsapp` — recebimento de eventos (Meta)
  - Opcional: valida a assinatura `x-hub-signature-256` se `META_APP_SECRET` definido
  - Habilite `STRICT_WEBHOOK_SIGNATURE=true` para exigir assinatura válida (ambiente prod)

## Fluxo (endpoint)
1. Chama `queue_invoice_whatsapp(invoice_id, phone_override)` (função SQL 0018)
2. Busca a mensagem/telefone na `whatsapp_outbox`
3. Envia via provider (`stub` ou `meta`)
4. Marca como enviado/erro com `mark_whatsapp_sent`/`mark_whatsapp_failed`

## Provider WhatsApp Cloud (Meta)
- Configure no `.env`:
  - `WHATSAPP_PROVIDER=meta`
  - `WHATSAPP_PHONE_NUMBER_ID=<id>` (Settings do WhatsApp Cloud)
  - `WHATSAPP_TOKEN=<token>` (User Access Token ou App Token com permissão)
- Envio realiza `POST https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/messages` com `text.body`.
- Telefone é normalizado para E.164 (Brasil) quando possível.

## Webhook Meta (Cloud)
- Assinatura: cabeçalho `x-hub-signature-256` = `sha256=<HMAC_SHA256(app_secret, body)>`
- Dev: se `META_APP_SECRET` estiver vazio ou `STRICT_WEBHOOK_SIGNATURE=false`, a assinatura não é exigida.
- Produção: defina `META_APP_SECRET` e `STRICT_WEBHOOK_SIGNATURE=true` para validar a assinatura.
- Verificação (GET): use `WHATSAPP_VERIFY_TOKEN` para responder ao challenge.

## Worker de envio
Processa automaticamente mensagens pendentes da view `public.v_whatsapp_outbox_pending`.

- Rodar:
```bash
npm run worker
```
- Configuração via `.env`:
  - `WORKER_BATCH_SIZE=10` — quantidade por ciclo
  - `WORKER_INTERVAL_MS=10000` — intervalo entre ciclos (ms)
  - `DRY_RUN=false` — quando `true`, não envia (apenas logs)
- Comportamento:
  - Busca pendências (`status = 'Pending'`)
  - Tenta enviar via provider
  - Marca como `Sent` ou `Failed` conforme o resultado

## Deploy no Render

- Conectar o repositório no Render e adicionar o arquivo `render.yaml` (já presente na raiz do projeto).
- Serviços:
  - Web `backend-api`:
    - `rootDir: backend`
    - `buildCommand: npm install`
    - `startCommand: npm run start`
    - `healthCheckPath: /health`
    - Variáveis:
      - `PORT=3001`
      - `SUPABASE_URL` (Secret)
      - `SUPABASE_SERVICE_ROLE_KEY` (Secret)
      - `SUPABASE_ANON_KEY` (Secret)
      - `API_KEY` (Secret, recomenda-se valor forte)
      - `WHATSAPP_PROVIDER=stub` (alterar para `meta` em produção)
      - `WHATSAPP_VERIFY_TOKEN` (Secret, opcional para webhook GET)
      - `META_APP_SECRET` (Secret, opcional para assinatura HMAC)
      - `STRICT_WEBHOOK_SIGNATURE=false` (usar `true` em produção com segredo habilitado)
  - Worker `whatsapp-worker`:
    - `rootDir: backend`
    - `buildCommand: npm install`
    - `startCommand: npm run worker`
    - Variáveis:
      - `SUPABASE_URL` (Secret)
      - `SUPABASE_SERVICE_ROLE_KEY` (Secret)
      - `WHATSAPP_PROVIDER=stub`
      - `WORKER_BATCH_SIZE=10`
      - `WORKER_INTERVAL_MS=10000`
      - `DRY_RUN=false`

- Pós-deploy (smoke test):
  - `GET https://<host-render>/health` deve retornar `{ "ok": true }`.
  - `POST https://<host-render>/invoices/:id/send-whatsapp` com header `x-api-key: <API_KEY>`.

- Segurança:
  - Mantenha `API_KEY` forte e rotacione-o quando necessário.
  - Habilite `STRICT_WEBHOOK_SIGNATURE=true` e defina `META_APP_SECRET` ao integrar WhatsApp Cloud em produção.

## Próximos passos
- Integrar webhooks do WhatsApp Cloud para atualizar status
- Adicionar retries e dead-letter (reprocessar erros)
- Autenticação adicional (JWT/RBAC) se exposto publicamente

## API de Autenticação

- Variáveis de ambiente necessárias:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`

- Endpoints:
  - `POST /auth/signup` — cria usuário
    - Body: `{ "email": "user@example.com", "password": "SenhaForte123" }`
  - `POST /auth/login` — autentica usuário
    - Body: `{ "email": "user@example.com", "password": "SenhaForte123" }`
  - `POST /auth/refresh` — renova `access_token`
    - Body: `{ "refresh_token": "<token>" }`
  - `POST /auth/logout` — invalida sessão atual
    - Header: `Authorization: Bearer <access_token>`
    - Content-Type: use `application/json` e envie `{}` no body (ou envie `{}` com `application/json`)

- Exemplos (PowerShell local):
  - Signup:
    ```powershell
    $body = @{ email = 'aluno.teste@example.com'; password = 'SenhaForte123' } | ConvertTo-Json
    Invoke-RestMethod -Uri 'http://localhost:3001/auth/signup' -Method Post -ContentType 'application/json' -Body $body
    ```
  - Login:
    ```powershell
    $body = @{ email = 'aluno.teste@example.com'; password = 'SenhaForte123' } | ConvertTo-Json
    $login = Invoke-RestMethod -Uri 'http://localhost:3001/auth/login' -Method Post -ContentType 'application/json' -Body $body
    $accessToken = $login.access_token
    $refreshToken = $login.refresh_token
    ```
  - Refresh:
    ```powershell
    $refreshBody = @{ refresh_token = $refreshToken } | ConvertTo-Json
    Invoke-RestMethod -Uri 'http://localhost:3001/auth/refresh' -Method Post -ContentType 'application/json' -Body $refreshBody
    ```
  - Logout:
    ```powershell
    $headers = @{ Authorization = "Bearer $accessToken" }
    Invoke-RestMethod -Uri 'http://localhost:3001/auth/logout' -Method Post -Headers $headers -ContentType 'application/json' -Body '{}'
    ```

- Observações:
  - Access token expira em 20 minutos (expiresIn=1200). Durante o uso, o backend faz auto-refresh se o TTL estiver <5min, desde que você envie o header `x-refresh-token: <refresh_token>`. O novo token vem no header `x-new-access-token`.
  - Caso esteja inativo, nenhum refresh ocorre e o login expira naturalmente.
  - Erro `auth_not_configured` indica ausência de `SUPABASE_URL` ou `SUPABASE_ANON_KEY` no ambiente.
  - Em dev existe `GET /debug/env` para inspeção rápida das variáveis (não incluir em produção).
  - Em produção (Render), use `https://<host-render>/...` nas URLs e configure os Secrets em `render.yaml`.


# Backend API

## Saúde
- `GET /health` retorna `{ ok: true }`

## Autenticação
- `POST /auth/signup` cria usuário (role inicial `Aluno`).
- `POST /auth/login` retorna `access_token`, `refresh_token`, `expires_at` (policy: `expiresIn=1200`, ~20min).
- `POST /auth/refresh` aceita `refresh_token` e retorna novo `access_token` e `expires_at`.
- `POST /auth/logout` invalida a sessão atual.

### Janela deslizante por atividade (auto-refresh)
- Todos os endpoints autenticados verificam o TTL do token no `preHandler`.
- Se o token estiver com menos de 5 minutos restantes e você enviar `x-refresh-token` no header, o backend tentará renovar a sessão via Supabase.
- Em caso de sucesso, o novo access token vem no header de resposta `x-new-access-token`.
- Se você não enviar `x-refresh-token` ou houver inatividade, a sessão expira naturalmente após ~20 min.

## RBAC (Role-Based Access Control)
- Middleware `ensureRole([...])` exige que o usuário tenha uma das roles permitidas.
- Roles esperadas na tabela `users.role`: `Admin`, `Gerente`, `Financeiro` (exemplos; ajuste conforme seu domínio).
- Bypass técnico: se o header `x-api-key` corresponder à `API_KEY` do ambiente, o RBAC é dispensado.
- O middleware decodifica o JWT (`sub`) e busca o `role` na tabela `users`.
- Retornos:
  - Token ausente/inválido: `401 { error: 'unauthorized' }`
  - Role insuficiente: `403 { error: 'forbidden' }`
  - Erro interno: `500 { error: 'internal_error' }`

### Rotas protegidas por RBAC
- `POST /test/send-whatsapp` (roles: `Admin`, `Gerente`, `Financeiro`).
- `POST /invoices/:id/send-whatsapp` (roles: `Admin`, `Gerente`, `Financeiro`).
- `POST /test/seed-outbox` (roles: `Admin`, `Gerente`, `Financeiro`).

### Headers de autenticação
- `Authorization: Bearer <access_token>` em todas as requisições autenticadas.
- `x-refresh-token: <refresh_token>` para permitir auto-refresh quando TTL < 5min.
- `x-api-key: <API_KEY>` permite bypass técnico do RBAC (não recomendado para uso amplo).

## Debug
- `GET /debug/env` retorna flags indicando presença de `SUPABASE_ANON_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.

## Webhooks WhatsApp
- `GET /webhook/whatsapp` valida o token de verificação (`WHATSAPP_VERIFY_TOKEN`).
- `POST /webhook/whatsapp` opcionalmente valida assinatura (`META_APP_SECRET`, `STRICT_WEBHOOK_SIGNATURE`).

## Notas
- Configure `SUPABASE_ANON_KEY`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` e `API_KEY` em produção.
- As roles devem existir e estar atribuídas na tabela `users`.
- Para clientes: sempre leia `x-new-access-token` e atualize o token local quando presente.