param(
  [string]$Base = "http://127.0.0.1:3001",
  [string]$Email,
  [string]$Password
)
$ErrorActionPreference = "Stop"

try {
  $login = Invoke-RestMethod -Uri ($Base + "/auth/login") -Method POST -ContentType "application/json" -Body (ConvertTo-Json @{ email=$Email; password=$Password })
  $token = $login.access_token
  if (-not $token) { throw "Login falhou sem token" }

  $res = Invoke-RestMethod -Uri ($Base + "/test/send-whatsapp") -Method POST -ContentType "application/json" -Headers @{ Authorization = ("Bearer " + $token) } -Body (ConvertTo-Json @{ phone = "+5500000000000"; message = "RBAC OK" })
  $res | ConvertTo-Json -Compress
}
catch {
  Write-Error $_
  exit 1
}