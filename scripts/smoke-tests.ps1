param(
  [string]$Base = "http://localhost:3001",
  [string]$ApiKey = "dev-key"
)

function To-Base64Url([byte[]]$bytes) {
  $s = [Convert]::ToBase64String($bytes)
  $s = $s.TrimEnd('=').Replace('+','-').Replace('/','_')
  return $s
}
function New-FakeJwt([string]$sub) {
  $h = @{ alg = 'none'; typ = 'JWT' } | ConvertTo-Json -Compress
  $now = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  $p = @{ sub = $sub; exp = $now + 3600 } | ConvertTo-Json -Compress
  $hb = [System.Text.Encoding]::UTF8.GetBytes($h)
  $pb = [System.Text.Encoding]::UTF8.GetBytes($p)
  return (To-Base64Url $hb) + "." + (To-Base64Url $pb) + "."
}

$haveSupabase = ($env:SUPABASE_URL) -and (($env:SUPABASE_ANON_KEY) -or ($env:VITE_SUPABASE_ANON_KEY)) -and ($env:SUPABASE_SERVICE_ROLE_KEY)

Write-Host "[1] GET /health"; Invoke-RestMethod -Uri "$Base/health" -Method GET | ConvertTo-Json -Depth 3;
Write-Host "[2] GET /debug/env"; Invoke-RestMethod -Uri "$Base/debug/env" -Method GET | ConvertTo-Json -Depth 3;

$accessToken = $null; $refreshToken = $null;
if ($haveSupabase) {
  $email = "smoke_" + (Get-Random) + "@test.local"; $password = "12345678"; $name = "Smoke Tests";
  Write-Host "[3] POST /auth/signup $email"; Invoke-RestMethod -Uri "$Base/auth/signup" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ email=$email; password=$password; name=$name });
  Write-Host "[4] POST /auth/login"; $login = Invoke-RestMethod -Uri "$Base/auth/login" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ email=$email; password=$password }); $login | ConvertTo-Json -Depth 3;
  $accessToken = $login.access_token; $refreshToken = $login.refresh_token;
} else {
  Write-Host "[3/4] Supabase não configurado; pulando signup/login.";
}

Write-Host "[5] RBAC negativo: POST /test/seed-outbox (espera 403)";
try {
  $token = $accessToken
  if (-not $token) { $token = New-FakeJwt "rbac-ci-user" }
  Invoke-WebRequest -Uri "$Base/test/seed-outbox" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ phone="+5511999999999"; message="RBAC test" }) -Headers @{ Authorization = "Bearer $token" }
} catch {
  $status = $_.Exception.Response.StatusCode.Value__;
  Write-Host "Status:" $status;
  if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "Erro RBAC negativo" }
}

Write-Host "[6] Bypass RBAC via x-api-key: POST /test/seed-outbox"; Invoke-RestMethod -Uri "$Base/test/seed-outbox" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ phone="+5511999988888"; message="Stub queue" }) -Headers @{ "x-api-key" = $ApiKey } | ConvertTo-Json -Depth 3;
Write-Host "[7] Bypass RBAC via x-api-key: POST /test/send-whatsapp"; Invoke-RestMethod -Uri "$Base/test/send-whatsapp" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ phone="+5511999990000"; message="Stub send" }) -Headers @{ "x-api-key" = $ApiKey } | ConvertTo-Json -Depth 3;

if ($haveSupabase) {
  Write-Host "[8] POST /auth/refresh"; Invoke-RestMethod -Uri "$Base/auth/refresh" -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ refresh_token=$refreshToken }) | ConvertTo-Json -Depth 3;
  Write-Host "[9] POST /auth/logout"; Invoke-RestMethod -Uri "$Base/auth/logout" -Method POST -ContentType "application/json" -Body "{}" -Headers @{ Authorization = "Bearer $accessToken" } | ConvertTo-Json -Depth 3;
} else {
  Write-Host "[8/9] Supabase não configurado; pulando refresh/logout.";
}