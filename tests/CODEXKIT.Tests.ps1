$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $repoRoot "prepublish-check.ps1")
. (Join-Path $repoRoot "refresh-codexkit.ps1")
. (Join-Path $repoRoot "restore-codexkit.ps1")

Describe "CODEXKIT prepublish" {
    It "видит опасные generated/private пути" {
        Test-CodexKitDangerousTrackedPath -Path "state/auth.json" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "repo-snapshots/app/file.txt" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "codexkit-transfer.zip" | Should Be $true
        Test-CodexKitDangerousTrackedPath -Path "archive-hashes.txt" | Should Be $true
    }

    It "не блокирует обычные файлы шаблона" {
        Test-CodexKitDangerousTrackedPath -Path "README.md" | Should Be $false
        Test-CodexKitDangerousTrackedPath -Path "refresh-codexkit.ps1" | Should Be $false
        Test-CodexKitDangerousTrackedPath -Path "bootstrap-packages.json" | Should Be $false
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
}

Describe "CODEXKIT verify script" {
    It "не содержит личный hardcoded SSH-ключ автора" {
        $content = Get-Content -LiteralPath (Join-Path $repoRoot "verify-codexkit.ps1") -Raw
        $content | Should Not Match "mikrotik_shutdown_ed25519"
    }
}
