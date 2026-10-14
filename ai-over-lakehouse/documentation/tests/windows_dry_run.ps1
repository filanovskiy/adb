# Hosted Windows QA. No real database credentials or database access.
# Password entry uses a synthetic fixture; the package/OS keyring are real.
# Setup's remaining commands execute from the actual downloaded ZIP.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$QaRoot = Join-Path $env:RUNNER_TEMP ('peakgear-windows-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $QaRoot | Out-Null
$Report = [ordered]@{
    windows = [Environment]::OSVersion.Version.ToString()
    powershell = $PSVersionTable.PSVersion.ToString()
    real_database_access = $false
    interactive_password_prompt_tested = $false
    checks = @()
}
try {
    $Extracted = Join-Path $QaRoot 'extracted'
    Expand-Archive -LiteralPath (Join-Path $Root 'downloads\peakgear-livelab-starter-kit.zip') -DestinationPath $Extracted
    $QaStarterDir = Join-Path $Extracted 'starter-kit'
    $QaCredentialFixture = Join-Path $PSScriptRoot 'windows_credential_fixture.py'
    $QaProject = Join-Path $QaRoot 'Project with spaces'
    New-Item -ItemType Directory -Path (Join-Path $QaProject '.codex') -Force | Out-Null
    $Utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $QaProject '.codex\config.toml'), "[mcp_servers.Unrelated]`ncommand = 'echo'`n", $Utf8)

    # Isolate all fixture files, uv packages, and URL config from the runner home.
    # Windows Credential Manager still runs under the real logged-in Windows user.
    $env:USERPROFILE = Join-Path $QaRoot 'user'
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'AppData\Local'
    $env:APPDATA = Join-Path $env:USERPROFILE 'AppData\Roaming'
    foreach ($Path in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $env:UV_NO_MODIFY_PATH = '1'
    $env:PEAKGEAR_QA_SYNTHETIC_PASSWORD = [guid]::NewGuid().ToString() + '-QA-only'
    $PreinstalledUv = Get-Command uv -ErrorAction SilentlyContinue
    if ($PreinstalledUv) {
        $UvParent = Split-Path $PreinstalledUv.Source -Parent
        $env:PATH = (($env:PATH -split ';') | Where-Object { $_.TrimEnd('\') -ne $UvParent.TrimEnd('\') }) -join ';'
    }

    # CI cannot enter a secret into a GUI console. Hook only the vendor CLI's
    # getpass function, then execute the real package CLI and OS keyring APIs.
    # Record this limitation instead of claiming an interactive learner run.
    function Read-Host {
        param([string]$Prompt)
        if ($Prompt -notlike 'Lab Data Studio URL*') { throw 'Unexpected setup prompt in the fixture.' }
        return 'https://example.adb.test.oraclecloudapps.com'
    }
    function Invoke-QaConfig {
        param([string]$Program, [string[]]$Arguments)
        if (-not (Test-Path -LiteralPath $Program)) { throw 'The actual vendor config executable is missing.' }
        $QaToolRoot = (& uv tool dir).Trim()
        $QaPython = Join-Path $QaToolRoot 'oracle-data-studio\Scripts\python.exe'
        & $QaPython $QaCredentialFixture @Arguments
        if ($LASTEXITCODE -ne 0) { throw 'The real vendor CLI/keyring fixture failed.' }
    }
    $SetupText = [IO.File]::ReadAllText((Join-Path $QaStarterDir '01-setup-peakgear-mcp.ps1'))
    $Hook = 'Invoke-Checked -Program $ConfigCommand -Arguments'
    if (($SetupText.Split(@($Hook), [StringSplitOptions]::None)).Count -ne 2) { throw 'Setup fixture expects exactly one vendor credential call.' }
    $SetupText = $SetupText.Replace($Hook, 'Invoke-QaConfig -Program $ConfigCommand -Arguments').Replace('$PSScriptRoot', '$QaStarterDir')
    & ([scriptblock]::Create($SetupText)) -ProjectPath $QaProject
    if ($LASTEXITCODE -ne 0) { throw 'The setup script failed.' }
    $Report.checks += 'ZIP extraction and production setup commands'
    $Report.checks += 'Fresh user-scoped uv and Python package installation'
    $Report.checks += 'Real Windows Credential Manager password storage and verification'

    $ToolRoot = (& uv tool dir).Trim()
    $QaPython = Join-Path $ToolRoot 'oracle-data-studio\Scripts\python.exe'
    $Runtime = Join-Path $env:LOCALAPPDATA 'peakgear-livelab'
    $ProjectConfig = Join-Path $QaProject '.codex\config.toml'
    $env:PEAKGEAR_QA_PROJECT_CONFIG = $ProjectConfig
    & $QaPython -c "import os,tomllib; from pathlib import Path; c=tomllib.loads(Path(os.environ['PEAKGEAR_QA_PROJECT_CONFIG']).read_text()); assert c['mcp_servers']['Unrelated']['command']=='echo'; assert Path(c['mcp_servers']['LiveLab']['command']).is_file(); assert c['mcp_servers']['LiveLab']['args'][-1]=='admin'; print('PASS native Python config and unrelated settings')"
    if ($LASTEXITCODE -ne 0) { throw 'Generated configuration is invalid.' }
    $Report.checks += 'Native Python configuration with spaces and preservation of unrelated MCP'

    # Clear only the synthetic fixture so startup cannot contact any database.
    & $QaPython $QaCredentialFixture cleanup
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic-credential cleanup failed.' }
    & $QaPython (Join-Path $PSScriptRoot 'windows_mcp_smoke.py') --runtime $Runtime --python $QaPython --project-config $ProjectConfig
    if ($LASTEXITCODE -ne 0) { throw 'Native MCP/process-management smoke test failed.' }
    $Report.checks += 'Real MCP stdio initialize and tool listing without database access'
    $Report.checks += 'Real CIM process ownership, Stop, Restart, Status, and Refresh'
    $Report.checks += 'Unrelated Python process survives scoped cleanup'
    $Report.status = 'passed'
} catch {
    $Report.status = 'failed'
    $Report.error = $_.Exception.Message
    throw
} finally {
    $Report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $env:RUNNER_TEMP 'peakgear-windows-report.json') -Encoding UTF8
}
