# Backend Deploy Checklist (Render)

Este checklist consolida os passos e segredos para concluir a implantação do backend e validações pós-deploy.

## 1) Pré-requisitos
- `PORT=3001` padronizado (Dockerfile/compose/render.yaml).
- Testes locais passando (29/29): `BASE_URL=http://127.0.0.1:3001 API_KEY=dev-key npm test`.
- Smoke tests locais OK: `scripts/smoke-tests.ps1 -Base "http://127.0.0.1:3001" -ApiKey "dev-key"`.
- Supabase CLI configurada e projeto linkado: `supabase login` + `supabase link --project-ref <REF>`.
- Tipos gerados e CI artifact: `npm run gen:types` ou baixar artefato do job `supabase-types`.

## 2) Segredos e variáveis no Render (Service: backend-api)
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `API_KEY` (para endpoints internos e smoke tests)
- `WHATSAPP_VERIFY_TOKEN` (webhook)
- `META_APP_SECRET` (verificação de assinatura do webhook)
- `CORS_ORIGINS` (CSV de domínios do frontend; ex.: `https://app.seu-dominio.com`)
- Já definidos no `render.yaml`:
  - `PORT=3001`
  - `STRICT_WEBHOOK_SIGNATURE="true"`

## 3) Deploy
- Build e start: `render.yaml` usa `npm install` e `npm run start` no diretório `backend`.
- Health check: `/health` (já configurado em `render.yaml`).
- Após subir, validar rapidamente:
  - `Invoke-RestMethod -Uri 'https://<render-app>/health' -Method GET`

## 4) Smoke tests pós-deploy
- Executar localmente apontando para o Render:
  - `scripts/smoke-tests.ps1 -Base "https://<render-app>" -ApiKey "<API_KEY>"`
- Opcional: executar via CI (workflow manual) com `BASE_URL` e `API_KEY` como segredos.

## 5) RLS e RBAC
- Garantir políticas RLS compatíveis com roles (`Admin/Gerente/Financeiro/Equipe/Aluno`).
- Validar RBAC com testes existentes e smoke tests:
  - Sem bearer: rotas sensíveis retornam 403.
  - Com `x-api-key`: endpoints de teste funcionam conforme esperado.

## 6) Backups e Monitoramento
- Backups:
  - Dump diário do banco (Supabase ou job externo) e retenção de 30 dias de transaction log.
- Alertas/Observabilidade:
  - Configurar Sentry (ou equivalente) e alertas de latência/erros.
  - Documentar `SENTRY_DSN` (se adotado) e pontos de observação.

## 7) Documentação e Operação
- `openapi.json`: gerar/entregar especificação dos endpoints (planejado; opcional nesta fase).
- Runbook (`RUNBOOK.md`): procedimentos de restore, incident response, rollback.
- Atualizar `check_list.yaml` conforme avanços (segredos e backups).

## 8) Notas de CORS
- Desenvolvimento suportado: `http://localhost:5173,http://127.0.0.1:5173`.
- Produção: configure `CORS_ORIGINS` com o(s) domínio(s) reais do frontend (evite wildcard).
- Validar com chamadas simples ao backend a partir do domínio do frontend.

## 9) Comandos úteis
- Rodar servidor local: `node src/server.js` (PORT do `.env`)
- Testes: `BASE_URL=http://127.0.0.1:3001 API_KEY=dev-key npm test`
- Smoke local: `scripts/smoke-tests.ps1 -Base "http://127.0.0.1:3001" -ApiKey "dev-key"`
- Gerar tipos: `npm run gen:types`