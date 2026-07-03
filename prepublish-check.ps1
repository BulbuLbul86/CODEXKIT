param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSCommandPath)
)

$ErrorActionPreference = "Stop"
$script:IsDotSourced = $MyInvocation.InvocationName -eq "."

function ConvertTo-RepoPath {
    param([string]$Path)
    return (([string]$Path) -replace '\\', '/').TrimStart('/')
}

function Test-CodexKitDangerousTrackedPath {
    param([string]$Path)

    $repoPath = ConvertTo-RepoPath -Path $Path

    $blockedPrefixes = @(
        "state/",
        "repo-snapshots/",
        "docs/",
        "installers/",
        "codexkit-transfer-parts/",
        "CODEXKIT/",
        "CODEXKIT-unpacked/",
        ".serena/",
        ".pytest_cache/",
        "__pycache__/",
        "TestResults/",
        "test-results/",
        "coverage/",
        "logs/",
        "cache/",
        "exports/",
        ".venv/",
        "venv/"
    )

    foreach ($prefix in $blockedPrefixes) {
        if ($repoPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $blockedFiles = @(
        "archive-hashes.txt",
        "environment-inventory.json",
        "machine-info.json",
        "repo-manifest.json",
        "state-manifest.json",
        "tool-versions.json",
        "vscode-extensions.txt",
        "winget-packages.json",
        "winget-export.log",
        "codexkit-run-statistics.latest.json",
        "codexkit-run-statistics.latest.log",
        ".env",
        ".coverage",
        "Pester.TestResults.xml"
    )

    foreach ($file in $blockedFiles) {
        if ($repoPath.Equals($file, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $blockedPatterns = @(
        '^\.env\..+$',
        '^codexkit-state.*\.zip$',
        '^codexkit-state-secure.*\.rar$',
        '^codexkit-transfer.*\.zip$',
        '^codexkit-transfer-secure.*\.rar$',
        '^.*\.sha256$',
        '^.*\.log$',
        '^.*\.trx$',
        '^.*\.key$',
        '^.*\.pem$',
        '^.*\.p12$',
        '^.*\.pfx$',
        '^.*\.sqlite$',
        '^.*\.sqlite-shm$',
        '^.*\.sqlite-wal$',
        '^.*\.db$',
        '^.*\.pyc$'
    )

    foreach ($pattern in $blockedPatterns) {
        if ($repoPath -match $pattern) {
            return $true
        }
    }

    return $false
}

function Test-EmptyCustomPathsTemplate {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $false
    }

    foreach ($propertyName in @("files", "directories", "repo_roots")) {
        if (-not ($config.PSObject.Properties.Name -contains $propertyName)) {
            return $false
        }

        if (@($config.$propertyName).Count -ne 0) {
            return $false
        }
    }

    return $true
}

function Invoke-CodexKitPrepublishCheck {
    param([string]$Root)

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $failures = New-Object System.Collections.Generic.List[string]

    Push-Location -LiteralPath $rootPath
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) {
            $failures.Add("Git не найден в PATH.") | Out-Null
        } else {
            $trackedFiles = @(& git ls-files)
            if ($LASTEXITCODE -ne 0) {
                $failures.Add("Не удалось получить список tracked-файлов через git ls-files.") | Out-Null
            } else {
                foreach ($file in $trackedFiles) {
                    if (Test-CodexKitDangerousTrackedPath -Path $file) {
                        $failures.Add("В Git отслеживается приватный, локальный или generated-файл: $file") | Out-Null
                    }
                }
            }
        }

        $requiredFiles = @(
            "README.md",
            "LICENSE",
            ".gitignore",
            "1-BEFORE-MOVE.bat",
            "2-RESTORE-HERE.bat",
            "refresh-codexkit.ps1",
            "restore-codexkit.ps1",
            "verify-codexkit.ps1",
            "bootstrap-packages.json",
            "custom-paths.json",
            "SECURITY.md",
            "PRIVACY.md",
            "CHANGELOG.md",
            "CONTRIBUTING.md",
            "RELEASE_NOTES_v0.1-alpha.md"
        )

        foreach ($file in $requiredFiles) {
            if (-not (Test-Path -LiteralPath (Join-Path $rootPath $file))) {
                $failures.Add("Не найден обязательный файл: $file") | Out-Null
            }
        }

        if (-not (Test-EmptyCustomPathsTemplate -Path (Join-Path $rootPath "custom-paths.json"))) {
            $failures.Add("custom-paths.json должен быть пустым шаблоном: files/directories/repo_roots = [].") | Out-Null
        }
    } finally {
        Pop-Location
    }

    if ($failures.Count -gt 0) {
        Write-Host "Проверка перед публикацией не пройдена." -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host " - $failure" -ForegroundColor Red
        }
        return 1
    }

    Write-Host "Проверка перед публикацией пройдена. Опасные tracked-файлы не найдены." -ForegroundColor Green
    return 0
}

if (-not $script:IsDotSourced) {
    exit (Invoke-CodexKitPrepublishCheck -Root $RepositoryRoot)
}
