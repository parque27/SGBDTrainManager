# Load every file in data\ into PostgreSQL/PostGIS (schema "import", one table per file).
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File data\load\load.ps1
#
# Default: starts a throwaway container "ocemt-pg" (postgis/postgis:18-3.7) with data\ mounted read-only at /data.
# Set $env:OCEMT_PG_PORT to publish it on another host port than 5432.
# To load into a server you already have, set $env:PGHOST (and PGPORT, PGUSER, PGDATABASE, PGPASSWORD as needed).
# That path runs psql and gzip on this machine (client-side \copy, load_client.sql): no superuser needed, but the
# server needs PostGIS (or the right to create it). psql must be on PATH; gzip too, or Git for Windows installed
# (its gzip.exe in "C:\Program Files\Git\usr\bin" is used).
$ErrorActionPreference = "Stop"

$Image = "postgis/postgis:18-3.7"
$Name = "ocemt-pg"
Set-Location (Join-Path $PSScriptRoot "..\..")   # repository root, so that ${PWD}\data is this data folder
if (-not (Test-Path "data\manifest.csv")) { throw "data\manifest.csv not found: run this script from the repository" }

function Invoke-Checked {
    param([string]$What, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE)" }
}

if ($env:PGHOST) {
    if (-not (Get-Command psql -ErrorAction SilentlyContinue)) { throw "psql is not on PATH (needed to load into $env:PGHOST)" }
    if (-not (Get-Command gzip -ErrorAction SilentlyContinue)) {
        $GitUsrBin = Join-Path $env:ProgramFiles "Git\usr\bin"
        if (Test-Path (Join-Path $GitUsrBin "gzip.exe")) { $env:PATH = "$GitUsrBin;$env:PATH" }
        else { throw "gzip is not on PATH: install Git for Windows (it ships gzip) or add a gzip.exe to PATH" }
    }
    Write-Host "Loading into the existing server at $env:PGHOST (files are read on this machine)"
    Invoke-Checked "psql" { psql -v ON_ERROR_STOP=1 -f data/load/create_import_tables.sql -f data/load/load_client.sql }
    exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker is not installed or not on PATH" }
$Port = if ($env:OCEMT_PG_PORT) { $env:OCEMT_PG_PORT } else { "5432" }
$Existing = docker ps -aq --filter "name=^$Name$"
if ($Existing) {
    Write-Host "Reusing the existing container $Name (remove it with: docker rm -fv $Name)"
    Invoke-Checked "docker start" { docker start $Name | Out-Null }
} else {
    Invoke-Checked "docker run" {
        docker run -d --name $Name -e POSTGRES_PASSWORD=ocemt -p "127.0.0.1:${Port}:5432" -v "${PWD}\data:/data:ro" $Image | Out-Null
    }
}

Write-Host -NoNewline "Waiting for PostgreSQL"
# The first start runs a temporary server on the socket only; wait for the real one on TCP.
$Ready = $false
for ($i = 0; $i -lt 120; $i++) {
    docker exec $Name pg_isready -U postgres -h 127.0.0.1 -q
    if ($LASTEXITCODE -eq 0) { $Ready = $true; break }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 1
}
Write-Host ""
if (-not $Ready) { throw "PostgreSQL did not start; see: docker logs $Name" }

Invoke-Checked "psql" {
    docker exec $Name psql -U postgres -v ON_ERROR_STOP=1 -f /data/load/create_import_tables.sql -f /data/load/load.sql
}
Write-Host "Done. SQL prompt: docker exec -it $Name psql -U postgres"
