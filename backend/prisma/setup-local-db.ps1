# Makes a locally installed PostgreSQL match DATABASE_URL in backend/.env:
# creates (or resets the password of) the database user, creates the
# database, then runs the migrations and adds the demo salons.
#
# Run from the backend folder:  npm run db:setup-local
# It asks once for the password of the "postgres" admin account (the one
# chosen when PostgreSQL was installed). Nothing is saved.

$ErrorActionPreference = 'Stop'
$backend = Split-Path -Parent $PSScriptRoot
Set-Location $backend

$line = Get-Content (Join-Path $backend '.env') | Where-Object { $_ -match '^\s*DATABASE_URL\s*=' } | Select-Object -First 1
if (-not $line) { throw 'DATABASE_URL is missing from backend/.env.' }
$url = ($line -replace '^\s*DATABASE_URL\s*=\s*', '').Trim().Trim('"').Trim("'")
$uri = [Uri]($url -replace '^postgres(ql)?://', 'http://')

$user, $pass = $uri.UserInfo.Split(':', 2)
$user = [Uri]::UnescapeDataString($user)
$pass = [Uri]::UnescapeDataString($pass)
$db = [Uri]::UnescapeDataString($uri.AbsolutePath.TrimStart('/'))
$pgHost = $uri.Host
$port = if ($uri.Port -gt 0) { $uri.Port } else { 5432 }
if (-not $user -or -not $pass -or -not $db) {
  throw 'DATABASE_URL must look like postgresql://USER:PASSWORD@localhost:5432/DATABASE'
}

$psql = Get-Command psql -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $psql) {
  $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
    Sort-Object { [int]$_.Directory.Parent.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $psql) { throw 'Could not find psql.exe. Is PostgreSQL installed?' }

Write-Host "Setting up database '$db' for user '$user' on ${pgHost}:$port"
$secure = Read-Host 'Password of the PostgreSQL "postgres" admin account' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

$sql = @'
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_pass') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app_db') \gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'app_db', :'app_user') \gexec
'@

try {
  $sql | & $psql -h $pgHost -p $port -U postgres -d postgres -w -q -v ON_ERROR_STOP=1 `
    -v "app_user=$user" -v "app_pass=$pass" -v "app_db=$db" -f -
  if ($LASTEXITCODE -ne 0) { throw 'psql failed (is the admin password right?).' }
} finally {
  Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
Write-Host "User '$user' and database '$db' are ready."

npx prisma migrate deploy
if ($LASTEXITCODE -ne 0) { throw 'Creating the tables failed.' }
npx prisma db seed
if ($LASTEXITCODE -ne 0) { throw 'Adding the demo salons failed.' }
Write-Host 'Done. Restart "npm run dev" if it is running, then reload the app.'
