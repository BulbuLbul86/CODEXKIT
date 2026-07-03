$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "prepublish-check.ps1")
. (Join-Path $repoRoot "refresh-codexkit.ps1")
. (Join-Path $repoRoot "restore-codexkit.ps1")

Describe "CODEXKIT prepublish" {
    It "видит опасные generated/private пути" {
        Test-CodexKitDangerousTrackedPath -Path "state/auth.json" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "repo-snapshots/app/file.txt" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "codexkit-transfer.zip" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "codexkit-transfer-part-001.zip" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "codexkit-transfer.zip.sha256" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "archive-hashes.txt" | Should Be $true
    }

    It "видит локальные тестовые, логовые и cache-артефакты" {
        Test-CodexKitDangerousTrackedPath -Path "TestResults/run.trx" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "test-results/pester.xml" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "coverage/index.html" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path ".pytest_cache/v/cache/nodeids" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "logs/local-run.log" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "cache/state.bin" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "exports/report.csv" | Should Be $true
    }

    It "видит секреты и локальные окружения" {
        Test-CodexKitDangerousTrackedPath -Path ".env" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path ".env.local" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "private.key" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "cert.pem" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "local.sqlite" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "Pester.TestResults.xml" | Should Be $true
    }

    It "не блокирует обычные файлы шаблона" {
        Test-CodexKitDangerousTrackedPath -Path "README.md" | Should Be $false
        Test-CodexKitDangerousTrackedPath -Path "refresh-codexkit.ps1" | Should Be $false
        Test-CodexKitDangerousTrackedPath -Path "bootstrap-packages.json" | Should Be $false
        Test-CodexKitDangerousTrackedPath -Path "tests/CODEXKIT.Tests.ps1" | Should Be $false
    }

    It "проверяет пустой custom-paths.json" {
        Test-EmptyCustomPathsTemplate -Path (Join-Path $repoRoot "custom-paths.json") | Should Be $true
    }
}

Describe "CODEXKIT repository snapshots" {
    It "создаёт разные snapshot_id для репозиториев с одинаковым именем" {
        $first = Get-RepoSnapshotId -Name "app" -SourcePath "C:\Work\one\app"
        $second = Get-RepoSnapshotId -Name "app" -SourcePath "D:\Work\two\app"

        $first | Should Match "^app__[a-f0-9]{12}$"
        $second | Should Match "^app__[a-f0-9]{12}$"
        $first | Should Not Be $second
    }

    It "создаёт стабильный и безопасный snapshot_id" {
        $first = Get-RepoSnapshotId -Name "my app:core" -SourcePath "C:\Work\my app"
        $second = Get-RepoSnapshotId -Name "my app:core" -SourcePath "C:\Work\my app\"

        $first | Should Be $second
        $first | Should Match "^my_app_core__[a-f0-9]{12}$"
    }
}

Describe "CODEXKIT sensitivity modes" {
    It "помечает автоматические секреты как чувствительные" {
        Test-SensitiveCopyEntry -Category "ssh" -Source "C:\Users\me\.ssh" -Destination "state\ssh" | Should Be $true
        Test-SensitiveCopyEntry -Category "auto-git" -Source "C:\Users\me\.git-credentials" -Destination "state\auto\home\.git-credentials" | Should Be $true
        Test-SensitiveCopyEntry -Category "auto-node" -Source "C:\Users\me\.npmrc" -Destination "state\auto\home\.npmrc" | Should Be $true
        Test-SensitiveCopyEntry -Category "auto-java" -Source "C:\Users\me\.gradle\init.gradle" -Destination "state\auto\home\.gradle\init.gradle" | Should Be $true
        Test-SensitiveCopyEntry -Category "auto-cloud" -Source "C:\Users\me\.aws" -Destination "state\auto\home\.aws" | Should Be $true
        Test-SensitiveCopyEntry -Category "android" -Source "C:\Users\me\.android\debug.keystore" -Destination "state\android\debug.keystore" | Should Be $true
    }

    It "помечает чувствительные файлы Codex" {
        Test-SensitiveCodexFileName -Name "config.toml" | Should Be $true
        Test-SensitiveCodexFileName -Name "auth.json" | Should Be $true
        Test-SensitiveCodexDirectoryName -Name "sessions" | Should Be $true
        Test-SensitiveCodexDirectoryName -Name "skills" | Should Be $false
    }

    It "оставляет custom-paths явным пользовательским механизмом" {
        Test-CustomCopyEntry -Entry @{ Category = "custom"; Source = "C:\Example\Config"; Destination = "state\custom"; IsCustom = $true } | Should Be $true
    }
}

Describe "CODEXKIT transfer hashes" {
    It "проверяет sha256-файл для временного файла" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("codexkit-test-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $file = Join-Path $tmp "payload.txt"
            [System.IO.File]::WriteAllText($file, "hello", [System.Text.Encoding]::UTF8)

            $hashPath = Join-Path $tmp "payload.sha256"
            $hash = Get-FileSha256 -Path $file
            Set-Content -Path $hashPath -Value "$hash  payload.txt" -Encoding UTF8

            { Test-TransferHashFile -HashFilePath $hashPath -BaseRoot $tmp -ExpectedFiles @($file) } | Should Not Throw
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "останавливается при несовпадении sha256" {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("codexkit-test-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $file = Join-Path $tmp "payload.txt"
            [System.IO.File]::WriteAllText($file, "hello", [System.Text.Encoding]::UTF8)

            $hashPath = Join-Path $tmp "payload.sha256"
            Set-Content -Path $hashPath -Value ((-join ("0" * 64)) + "  payload.txt") -Encoding UTF8

            { Test-TransferHashFile -HashFilePath $hashPath -BaseRoot $tmp -ExpectedFiles @($file) } | Should Throw
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "не падает, если sha256-файл отсутствует" {
        $missingHash = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString("N") + ".sha256")
        { Test-TransferHashFile -HashFilePath $missingHash -BaseRoot ([System.IO.Path]::GetTempPath()) -ExpectedFiles @() } | Should Not Throw
    }
}

Describe "CODEXKIT verify script" {
    It "не содержит личный hardcoded SSH-ключ автора" {
        $content = Get-Content -LiteralPath (Join-Path $repoRoot "verify-codexkit.ps1") -Raw
        $needle = "mikrotik" + "_shutdown" + "_ed25519"
        $content | Should Not Match $needle
    }
}

Describe "CODEXKIT PlanOnly" {
    It "выходит до распаковки и операций восстановления" {
        $content = Get-Content -LiteralPath (Join-Path $repoRoot "restore-codexkit.ps1") -Raw
        $planIndex = $content.IndexOf('if ($PlanOnly)')
        $expandIndex = $content.IndexOf('Expand-TransferPayloadIfNeeded -KitRoot')

        ($planIndex -ge 0) | Should Be $true
        ($expandIndex -ge 0) | Should Be $true
        ($planIndex -lt $expandIndex) | Should Be $true
    }
}
