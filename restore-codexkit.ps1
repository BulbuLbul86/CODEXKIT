param(
    [string]$WorkspaceRoot = "",
    [string]$PrivateRestoreRoot = (Join-Path $HOME "Documents\TravelRestore"),
    [string]$ProgramsRoot = (Join-Path $env:SystemDrive "TravelApps"),
    [switch]$FullDesktop,
    [switch]$SkipWinget,
    [switch]$SkipState,
    [switch]$SkipRepos,
    [switch]$UseGitHubFallback
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Restore-LargeTransferFilesIfNeeded {
    param([string]$Root)

    $largeFilesManifestPath = Join-Path $Root "codexkit-large-files\manifest.json"
    if (-not (Test-Path -LiteralPath $largeFilesManifestPath)) {
        return
    }

    Write-Step "Восстановление больших файлов переноса"
    $manifest = Get-Content -LiteralPath $largeFilesManifestPath -Raw | ConvertFrom-Json
    foreach ($file in @($manifest.files)) {
        $destination = Join-Path $Root (([string]$file.path) -replace '/', '\')
        Ensure-Dir -Path (Split-Path -Parent $destination)

        $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            foreach ($chunk in @($file.chunks)) {
                $chunkPath = Join-Path $Root (([string]$chunk) -replace '/', '\')
                $inputStream = [System.IO.File]::OpenRead($chunkPath)
                try {
                    $inputStream.CopyTo($outputStream)
                } finally {
                    $inputStream.Dispose()
                }
            }
        } finally {
            $outputStream.Dispose()
        }
    }

    Remove-Item -LiteralPath (Join-Path $Root "codexkit-large-files") -Recurse -Force
}

function Expand-TransferPayloadIfNeeded {
    param(
        [string]$KitRoot,
        [string]$StateRoot,
        [string]$StateZipPath
    )

    if ((Test-Path -LiteralPath $StateRoot) -or (Test-Path -LiteralPath $StateZipPath)) {
        return
    }

    $singleArchive = Join-Path $KitRoot "codexkit-transfer.zip"
    if (Test-Path -LiteralPath $singleArchive) {
        Write-Step "Распаковка переносимого архива"
        Expand-Archive -LiteralPath $singleArchive -DestinationPath $KitRoot -Force
        Restore-LargeTransferFilesIfNeeded -Root $KitRoot
        return
    }

    $partsRoot = Join-Path $KitRoot "codexkit-transfer-parts"
    $parts = @()
    if (Test-Path -LiteralPath $partsRoot) {
        $parts = @(Get-ChildItem -LiteralPath $partsRoot -Filter "codexkit-transfer-part-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    } else {
        $parts = @(Get-ChildItem -LiteralPath $KitRoot -Filter "codexkit-transfer-part-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    }

    if ($parts.Count -eq 0) {
        return
    }

    Write-Step "Распаковка разделённых частей переноса"
    foreach ($part in $parts) {
        Write-Host "Распаковываю $($part.Name)"
        Expand-Archive -LiteralPath $part.FullName -DestinationPath $KitRoot -Force
    }
    Restore-LargeTransferFilesIfNeeded -Root $KitRoot
}

function Copy-FileIfExists {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }

    Ensure-Dir -Path (Split-Path -Parent $Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

function Copy-DirIfExists {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }

    Ensure-Dir -Path $Destination
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Не удалось скопировать папку через robocopy: $Source -> $Destination. Код выхода: $LASTEXITCODE"
    }

    return $true
}

function Mirror-Dir {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }

    Ensure-Dir -Path $Destination
    robocopy $Source $Destination /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Не удалось синхронизировать папку через robocopy: $Source -> $Destination. Код выхода: $LASTEXITCODE"
    }

    return $true
}

function Backup-DirIfExists {
    param(
        [string]$Source,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $null
    }

    Ensure-Dir -Path $BackupRoot
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Join-Path $BackupRoot ("{0}-{1}" -f (Split-Path -Leaf $Source), $timestamp)
    robocopy $Source $backupPath /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Не удалось создать резервную копию через robocopy: $Source -> $backupPath. Код выхода: $LASTEXITCODE"
    }

    return $backupPath
}

function Resolve-PortableRestorePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-SafeBackupName {
    param([string]$Path)

    $name = $Path -replace '[:\\/]+', '_'
    $name = $name -replace '[^A-Za-z0-9._-]', '_'
    return $name.Trim('_')
}

function ConvertTo-FlatObjectArray {
    param([object]$Value)

    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            foreach ($flatItem in (ConvertTo-FlatObjectArray -Value $item)) {
                $items.Add($flatItem) | Out-Null
            }
        }
    } else {
        $items.Add($Value) | Out-Null
    }

    return @($items.ToArray())
}

function Backup-StateItemIfExists {
    param(
        [string]$Path,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    Ensure-Dir -Path $BackupRoot
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupName = "{0}-{1}" -f (Get-SafeBackupName -Path $Path), $timestamp
    $backupPath = Join-Path $BackupRoot $backupName
    $item = Get-Item -LiteralPath $Path -Force

    if ($item.PSIsContainer) {
        robocopy $Path $backupPath /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "Не удалось создать резервную копию через robocopy: $Path -> $backupPath. Код выхода: $LASTEXITCODE"
        }
        return $backupPath
    }

    Ensure-Dir -Path (Split-Path -Parent $backupPath)
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function Restore-AutoManifestEntries {
    param(
        [string]$ManifestPath,
        [string]$BackupRoot
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return
    }

    try {
        $entries = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json))
    } catch {
        Write-Warning "Не удалось прочитать манифест состояния для автоматического восстановления: $($_.Exception.Message)"
        return
    }

    $autoEntries = @($entries | Where-Object { $_.status -eq "copied" -and ([string]$_.category).StartsWith("auto-") })
    if ($autoEntries.Count -eq 0) {
        return
    }

    Write-Step "Восстановление автоматически найденных настроек окружения"
    foreach ($entry in $autoEntries) {
        $source = [string]$entry.destination
        $destinationTemplate = [string]$entry.restore_destination
        $destination = Resolve-PortableRestorePath -Path $destinationTemplate

        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $source)) {
            Write-Warning "В комплекте отсутствует автоматически найденный элемент: $source"
            continue
        }

        $sourceItem = Get-Item -LiteralPath $source -Force
        if (Test-Path -LiteralPath $destination) {
            $backupPath = Backup-StateItemIfExists -Path $destination -BackupRoot $BackupRoot
            if ($backupPath) {
                Write-Host "Существующая настройка сохранена в резервную копию: $backupPath"
            }
        }

        Write-Host "Восстанавливаю $($entry.category): $destination"
        if ($sourceItem.PSIsContainer) {
            Mirror-Dir -Source $source -Destination $destination | Out-Null
        } else {
            Copy-FileIfExists -Source $source -Destination $destination | Out-Null
        }
    }
}

function Get-RelativePathIfUnder {
    param(
        [string]$Root,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalizedRoot = $Root.TrimEnd('\')
    if (-not $Path.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return $Path.Substring($normalizedRoot.Length).TrimStart('\')
}

function Restore-CustomManifestEntries {
    param(
        [string]$ManifestPath,
        [string]$StateRoot,
        [string]$PrivateRestoreRoot
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return
    }

    try {
        $entries = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json))
    } catch {
        Write-Warning "Не удалось прочитать манифест состояния для восстановления личных путей: $($_.Exception.Message)"
        return
    }

    $customEntries = @($entries | Where-Object { $_.status -eq "copied" -and ([string]$_.category).StartsWith("custom-") })
    if ($customEntries.Count -eq 0) {
        return
    }

    Write-Step "Восстановление личных файлов из custom-paths.json"
    Ensure-Dir -Path $PrivateRestoreRoot
    foreach ($entry in $customEntries) {
        $source = [string]$entry.destination
        if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path -LiteralPath $source)) {
            continue
        }

        $relative = Get-RelativePathIfUnder -Root $StateRoot -Path $source
        if ([string]::IsNullOrWhiteSpace($relative)) {
            $relative = Split-Path -Leaf $source
        }

        $destination = Join-Path $PrivateRestoreRoot $relative
        $sourceItem = Get-Item -LiteralPath $source -Force
        Write-Host "Восстанавливаю $($entry.category): $destination"
        if ($sourceItem.PSIsContainer) {
            Copy-DirIfExists -Source $source -Destination $destination | Out-Null
        } else {
            Copy-FileIfExists -Source $source -Destination $destination | Out-Null
        }
    }
}

function Get-DefaultWorkspaceRoot {
    return (Join-Path $HOME "Documents\Codex\restored-workspace")
}

$codexPersistentFiles = @(
    "config.toml",
    "auth.json",
    "AGENTS.md",
    "installation_id",
    ".codex-global-state.json",
    ".codex-global-state.json.bak",
    "cap_sid",
    "chrome-native-hosts-v2.json",
    "models_cache.json",
    "history.jsonl",
    "session_index.jsonl",
    "goals_1.sqlite",
    "goals_1.sqlite-shm",
    "goals_1.sqlite-wal",
    "logs_2.sqlite",
    "logs_2.sqlite-shm",
    "logs_2.sqlite-wal",
    "memories_1.sqlite",
    "state_5.sqlite",
    "state_5.sqlite-shm",
    "state_5.sqlite-wal"
)

$codexPersistentDirs = @(
    "sessions",
    "archived_sessions",
    "attachments",
    "codex-remote-attachments",
    "generated_images",
    "memories",
    "state",
    "sqlite",
    "browser",
    "rules",
    "skills",
    "plugins",
    "vendor_imports"
)

function Get-RepoLocationState {
    param([string]$Path)

    $repoMap = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $repoMap
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($state.repos) {
            foreach ($property in $state.repos.PSObject.Properties) {
                if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    $repoMap[$property.Name] = [string]$property.Value
                }
            }
        }
    } catch {
        Write-Warning "Не удалось прочитать сохранённые расположения репозиториев: $($_.Exception.Message)"
    }

    return $repoMap
}

function Save-RepoLocationState {
    param(
        [hashtable]$RepoMap,
        [string]$Path
    )

    Ensure-Dir -Path (Split-Path -Parent $Path)

    $repos = [ordered]@{}
    foreach ($key in ($RepoMap.Keys | Sort-Object)) {
        $repos[$key] = $RepoMap[$key]
    }

    $state = [ordered]@{
        updated_at = (Get-Date).ToString("o")
        machine    = $env:COMPUTERNAME
        repos      = $repos
    }

    $state | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8
}

function Get-CommonRepoSearchRoots {
    param(
        [string]$PreferredRoot,
        [hashtable]$RepoPathMap
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    $homeCandidates = @(
        (Join-Path $HOME "Documents"),
        (Join-Path $HOME "Documents\Codex"),
        (Join-Path $HOME "Desktop"),
        (Join-Path $HOME "source"),
        (Join-Path $HOME "projects"),
        (Join-Path $HOME "dev")
    )

    foreach ($candidate in $homeCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidates.Add($candidate) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredRoot)) {
        $candidates.Add($PreferredRoot) | Out-Null
    }

    foreach ($repoPath in $RepoPathMap.Values) {
        $parent = Split-Path -Parent $repoPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            $candidates.Add($parent) | Out-Null
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        if ($seen.Add($candidate)) {
            $roots.Add($candidate) | Out-Null
        }
    }

    return $roots
}

function Find-ExistingRepoPath {
    param(
        [pscustomobject]$Repo,
        [System.Collections.Generic.List[string]]$SearchRoots
    )

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($root in $SearchRoots) {
        try {
            $matches = Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $Repo.name }

            foreach ($match in $matches) {
                $candidates.Add([pscustomobject]@{
                    path       = $match.FullName
                    has_git    = (Test-Path -LiteralPath (Join-Path $match.FullName ".git"))
                    last_write = $match.LastWriteTimeUtc
                }) | Out-Null
            }
        } catch {
            continue
        }
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates |
        Sort-Object @{ Expression = "has_git"; Descending = $true }, @{ Expression = "last_write"; Descending = $true } |
        Select-Object -First 1

    if ($candidates.Count -gt 1) {
        Write-Host "Найдено несколько старых расположений для $($Repo.name). Использую $($best.path)"
    } else {
        Write-Host "Найдено старое расположение для $($Repo.name): $($best.path)"
    }

    return $best.path
}

function Resolve-RepoTargetPath {
    param(
        [pscustomobject]$Repo,
        [hashtable]$RepoPathMap,
        [string]$PreferredRoot
    )

    if ($RepoPathMap.ContainsKey($Repo.name)) {
        $rememberedPath = [string]$RepoPathMap[$Repo.name]
        if (Test-Path -LiteralPath $rememberedPath) {
            Write-Host "Использую запомненный путь для $($Repo.name): $rememberedPath"
            return $rememberedPath
        }
    }

    if ($Repo.PSObject.Properties.Name -contains "source_path") {
        $sourcePath = [string]$Repo.source_path
        if (-not [string]::IsNullOrWhiteSpace($sourcePath) -and (Test-Path -LiteralPath $sourcePath)) {
            Write-Host "Использую исходный путь для $($Repo.name): $sourcePath"
            return $sourcePath
        }
    }

    $searchRoots = Get-CommonRepoSearchRoots -PreferredRoot $PreferredRoot -RepoPathMap $RepoPathMap
    $foundPath = Find-ExistingRepoPath -Repo $Repo -SearchRoots $searchRoots
    if ($foundPath) {
        return $foundPath
    }

    if (-not $script:ResolvedNewRepoRoot) {
        $defaultRoot = if (-not [string]::IsNullOrWhiteSpace($PreferredRoot)) { $PreferredRoot } else { Get-DefaultWorkspaceRoot }
        $prompt = "Старые папки проектов не найдены. Куда сохранить новые проекты? [Enter = $defaultRoot]"
        $selectedRoot = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($selectedRoot)) {
            $script:ResolvedNewRepoRoot = $defaultRoot
        } else {
            $script:ResolvedNewRepoRoot = $selectedRoot.Trim()
        }
    }

    return (Join-Path $script:ResolvedNewRepoRoot $Repo.name)
}

function Find-CommandPath {
    param(
        [string]$Name,
        [string]$Fallback
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($Fallback -and (Test-Path -LiteralPath $Fallback)) {
        return $Fallback
    }

    return $null
}

function ConvertTo-SafePackageId {
    param([string]$PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return "unknown-package"
    }

    return (($PackageId -replace '[^A-Za-z0-9._-]', '_').Trim('_'))
}

function Install-WingetPackage {
    param(
        [pscustomobject]$Package,
        [string]$ProgramsRoot
    )

    $args = @(
        "install",
        "--id", $Package.id,
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if ($Package.source) {
        $args += @("--source", $Package.source)
    }

    Write-Host "Устанавливаю $(Get-PackageDisplayName -Package $Package)"
    try {
        $installed = $false

        if ($ProgramsRoot) {
            Ensure-Dir -Path $ProgramsRoot
            $packageFolder = ($Package.id -replace '[^A-Za-z0-9._-]', '-')
            $packageInstallRoot = Join-Path $ProgramsRoot $packageFolder
            $argsWithLocation = @($args + @("--location", $packageInstallRoot))
            & winget @argsWithLocation
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            } else {
                Write-Warning "winget не смог установить $($Package.id) в $packageInstallRoot. Повторяю установку в стандартное расположение."
            }
        }

        if (-not $installed) {
            & winget @args
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
            }
        }

        if (-not $installed) {
            Write-Warning "winget вернул ненулевой код для $($Package.id): $LASTEXITCODE"
        }
    } catch {
        Write-Warning "Установка через winget не удалась для $($Package.id): $($_.Exception.Message)"
    }
}

function Get-OfflinePackageDir {
    param(
        [pscustomobject]$Package,
        [string]$InstallersRoot
    )

    if ([string]::IsNullOrWhiteSpace($InstallersRoot) -or [string]::IsNullOrWhiteSpace([string]$Package.id)) {
        return $null
    }

    return (Join-Path $InstallersRoot (ConvertTo-SafePackageId -PackageId ([string]$Package.id)))
}

function Get-OfflineInstallerCandidate {
    param([string]$PackageDir)

    if (-not (Test-Path -LiteralPath $PackageDir)) {
        return $null
    }

    $extensionPriority = @{
        ".msi"        = 1
        ".exe"        = 2
        ".msixbundle" = 3
        ".appxbundle" = 4
        ".msix"       = 5
        ".appx"       = 6
        ".zip"        = 7
    }

    $packageRoot = (Resolve-Path -LiteralPath $PackageDir).Path
    if (-not $packageRoot.EndsWith("\")) {
        $packageRoot += "\"
    }

    $candidates = @(Get-ChildItem -LiteralPath $PackageDir -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $extensionPriority.ContainsKey($_.Extension.ToLowerInvariant()) } |
        ForEach-Object {
            $relativePath = if ($_.FullName.StartsWith($packageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $_.FullName.Substring($packageRoot.Length)
            } else {
                $_.Name
            }

            [pscustomobject]@{
                File           = $_
                DependencyRank = if ($relativePath -match '(^|[\\/])Dependencies[\\/]') { 1 } else { 0 }
                ExtensionRank  = $extensionPriority[$_.Extension.ToLowerInvariant()]
                Length         = [int64]$_.Length
            }
        } |
        Sort-Object DependencyRank, ExtensionRank, @{ Expression = "Length"; Descending = $true })

    if ($candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].File
}

function Get-WingetYamlSilentArgs {
    param(
        [string]$PackageDir,
        [string]$InstallerPath
    )

    if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
        $installerDir = Split-Path -Parent $InstallerPath
        $installerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InstallerPath)
        $matchingYaml = @(Get-ChildItem -LiteralPath $installerDir -Force -File -Filter "*.yaml" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $installerBaseName } |
            Select-Object -First 1)

        if ($matchingYaml.Count -gt 0) {
            foreach ($line in (Get-Content -LiteralPath $matchingYaml[0].FullName -ErrorAction SilentlyContinue)) {
                if ($line -match '^\s*Silent:\s*(?<args>.+)$') {
                    return $Matches.args.Trim()
                }
            }
        }
    }

    $yaml = @(Get-ChildItem -LiteralPath $PackageDir -Recurse -Force -File -Filter "*.yaml" -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($yaml.Count -eq 0) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $yaml[0].FullName -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*Silent:\s*(?<args>.+)$') {
            return $Matches.args.Trim()
        }
    }

    return $null
}

function Add-UserPathEntry {
    param([string]$PathToAdd)

    if ([string]::IsNullOrWhiteSpace($PathToAdd) -or -not (Test-Path -LiteralPath $PathToAdd)) {
        return
    }

    $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @($currentUserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts -notcontains $PathToAdd) {
        $newPath = (@($parts + $PathToAdd) -join ';')
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }

    $processParts = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($processParts -notcontains $PathToAdd) {
        $env:Path = (@($processParts + $PathToAdd) -join ';')
    }
}

function Invoke-OfflineInstallerFile {
    param(
        [string]$InstallerPath,
        [string]$SilentArgs,
        [string]$PackageId,
        [string]$ProgramsRoot,
        [string]$PackageDir
    )

    $extension = [System.IO.Path]::GetExtension($InstallerPath).ToLowerInvariant()
    if ($extension -eq ".msi") {
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", $InstallerPath, "/qn", "/norestart") -Wait -PassThru
        return (@(0, 3010) -contains [int]$process.ExitCode)
    }

    if (@(".msix", ".msixbundle", ".appx", ".appxbundle") -contains $extension) {
        $dependencyPaths = @()
        if (-not [string]::IsNullOrWhiteSpace($PackageDir)) {
            $dependencyRoot = Join-Path $PackageDir "Dependencies"
            if (Test-Path -LiteralPath $dependencyRoot) {
                $dependencyPaths = @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { @(".msix", ".msixbundle", ".appx", ".appxbundle") -contains $_.Extension.ToLowerInvariant() } |
                    Sort-Object FullName |
                    ForEach-Object { $_.FullName })
            }
        }

        if ($dependencyPaths.Count -gt 0) {
            Add-AppxPackage -Path $InstallerPath -DependencyPath $dependencyPaths -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $InstallerPath -ErrorAction Stop
        }

        return $true
    }

    if ($extension -eq ".exe") {
        if ([string]::IsNullOrWhiteSpace($SilentArgs)) {
            Write-Warning "Для $InstallerPath не найдены тихие параметры установки. Может открыться обычное окно установщика."
            $process = Start-Process -FilePath $InstallerPath -Wait -PassThru
        } else {
            $process = Start-Process -FilePath $InstallerPath -ArgumentList $SilentArgs -Wait -PassThru
        }

        return (@(0, 3010) -contains [int]$process.ExitCode)
    }

    if ($extension -eq ".zip") {
        if ([string]::IsNullOrWhiteSpace($ProgramsRoot)) {
            $ProgramsRoot = Join-Path $env:SystemDrive "TravelApps"
        }

        Ensure-Dir -Path $ProgramsRoot
        $destination = Join-Path $ProgramsRoot (ConvertTo-SafePackageId -PackageId $PackageId)
        Ensure-Dir -Path $destination
        Expand-Archive -LiteralPath $InstallerPath -DestinationPath $destination -Force

        if ($PackageId -eq "Google.PlatformTools") {
            $adb = Get-ChildItem -LiteralPath $destination -Recurse -Force -File -Filter "adb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($adb) {
                Add-UserPathEntry -PathToAdd (Split-Path -Parent $adb.FullName)
            }
        }

        Write-Host "Распаковано в $destination"
        return $true
    }

    return $false
}

function Install-OfflinePackage {
    param(
        [pscustomobject]$Package,
        [string]$InstallersRoot
    )

    $packageDir = Get-OfflinePackageDir -Package $Package -InstallersRoot $InstallersRoot
    if ([string]::IsNullOrWhiteSpace($packageDir)) {
        return $false
    }

    $installer = Get-OfflineInstallerCandidate -PackageDir $packageDir
    if (-not $installer) {
        return $false
    }

    $displayName = Get-PackageDisplayName -Package $Package
    $silentArgs = Get-WingetYamlSilentArgs -PackageDir $packageDir -InstallerPath $installer.FullName
    Write-Host "Устанавливаю $displayName из офлайн-установщика: $($installer.Name)"

    try {
        if (Invoke-OfflineInstallerFile -InstallerPath $installer.FullName -SilentArgs $silentArgs -PackageId ([string]$Package.id) -ProgramsRoot $ProgramsRoot -PackageDir $packageDir) {
            return $true
        }

        Write-Warning "Офлайн-установщик вернул ненулевой код для $displayName."
        return $false
    } catch {
        Write-Warning "Офлайн-установка не удалась для ${displayName}: $($_.Exception.Message)"
        return $false
    }
}

function Install-WorkspacePackage {
    param(
        [pscustomobject]$Package,
        [string]$ProgramsRoot,
        [string]$InstallersRoot,
        [bool]$WingetAvailable
    )

    if (Install-OfflinePackage -Package $Package -InstallersRoot $InstallersRoot) {
        return
    }

    if ($WingetAvailable) {
        Write-Warning "Офлайн-установщик не найден для $(Get-PackageDisplayName -Package $Package). Пробую онлайн-установку через winget."
        Install-WingetPackage -Package $Package -ProgramsRoot $ProgramsRoot
        return
    }

    Write-Warning "Офлайн-установщик не найден для $(Get-PackageDisplayName -Package $Package), а winget недоступен."
}

function Get-PackageInstallDefault {
    param([pscustomobject]$Package)

    if ($Package.PSObject.Properties.Name -contains "install_by_default") {
        return [bool]$Package.install_by_default
    }

    return $false
}

function Get-PackageDisplayName {
    param([pscustomobject]$Package)

    if (($Package.PSObject.Properties.Name -contains "display_name") -and -not [string]::IsNullOrWhiteSpace([string]$Package.display_name)) {
        return [string]$Package.display_name
    }

    return [string]$Package.id
}

function Confirm-PackageInstall {
    param([pscustomobject]$Package)

    $displayName = Get-PackageDisplayName -Package $Package
    $recommended = Get-PackageInstallDefault -Package $Package
    $defaultLabel = if ($recommended) { "Д/н" } else { "д/Н" }

    Write-Host ""
    Write-Host $displayName -ForegroundColor Yellow
    Write-Host "  Пакет: $($Package.id)"

    if (($Package.PSObject.Properties.Name -contains "notes") -and -not [string]::IsNullOrWhiteSpace([string]$Package.notes)) {
        Write-Host "  Что делает: $($Package.notes)"
    }

    if (($Package.PSObject.Properties.Name -contains "project_hint") -and -not [string]::IsNullOrWhiteSpace([string]$Package.project_hint)) {
        Write-Host "  Где пригодится: $($Package.project_hint)"
    }

    while ($true) {
        $answer = Read-Host "  Установить это приложение? [$defaultLabel]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $recommended
        }

        switch -Regex ($answer.Trim()) {
            '^(y|yes|д|да)$' { return $true }
            '^(n|no|н|нет)$' { return $false }
            default { Write-Host "  Введите Д или Н." -ForegroundColor DarkYellow }
        }
    }
}

$kitRoot = Split-Path -Parent $PSCommandPath
$stateRoot = Join-Path $kitRoot "state"
$zipPath = Join-Path $kitRoot "codexkit-state.zip"
$stateManifestPath = Join-Path $kitRoot "state-manifest.json"
$bootstrapPackagesPath = Join-Path $kitRoot "bootstrap-packages.json"
$installersRoot = Join-Path $kitRoot "installers"
$repoManifestPath = Join-Path $kitRoot "repo-manifest.json"
$repoSnapshotsRoot = Join-Path $kitRoot "repo-snapshots"
$extensionsPath = Join-Path $kitRoot "vscode-extensions.txt"
$wingetExportPath = Join-Path $kitRoot "winget-packages.json"
$docsRoot = Join-Path $kitRoot "docs"
$machineInfoPath = Join-Path $kitRoot "machine-info.json"
$appDataDir = [Environment]::GetFolderPath("ApplicationData")
$travelKitStateDir = Join-Path $HOME ".codexkit"
$repoLocationStatePath = Join-Path $travelKitStateDir "repo-locations.json"
$repoLocationState = Get-RepoLocationState -Path $repoLocationStatePath
$resolvedRepoPaths = @{}
$codexBackupRoot = Join-Path $travelKitStateDir "backups\codex-home"

Expand-TransferPayloadIfNeeded -KitRoot $kitRoot -StateRoot $stateRoot -StateZipPath $zipPath

if ($FullDesktop) {
    Write-Warning "Режим FullDesktop устарел. CODEXKIT восстанавливает только выбранные рабочие инструменты; полный список программ остаётся в winget-packages.json как справка."
}

if (Test-Path -LiteralPath $machineInfoPath) {
    try {
        $machineInfo = Get-Content -LiteralPath $machineInfoPath -Raw | ConvertFrom-Json
        Write-Step "Загружен CODEXKIT с компьютера $($machineInfo.source_machine) ($($machineInfo.generated_at))"
    } catch {
        Write-Warning "Не удалось прочитать machine-info.json: $($_.Exception.Message)"
    }
}

if (-not (Test-Path -LiteralPath $stateRoot) -and (Test-Path -LiteralPath $zipPath)) {
    Write-Step "Распаковка архива состояния"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $kitRoot -Force
}

if (-not $SkipWinget) {
    $wingetPath = Find-CommandPath -Name "winget" -Fallback $null
    if (-not $wingetPath) {
        Write-Warning "winget не найден. CODEXKIT будет использовать офлайн-установщики с флешки, где они есть."
    }

    if (Test-Path -LiteralPath $bootstrapPackagesPath) {
        Write-Step "Выбор рабочих приложений"
        $packages = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $bootstrapPackagesPath -Raw | ConvertFrom-Json))
        $selectedPackages = 0
        $skippedPackages = 0
        foreach ($package in $packages) {
            if (-not (Confirm-PackageInstall -Package $package)) {
                $skippedPackages += 1
                continue
            }

            $selectedPackages += 1
            Install-WorkspacePackage -Package $package -ProgramsRoot $ProgramsRoot -InstallersRoot $installersRoot -WingetAvailable:([bool]$wingetPath)
        }

        Write-Host ""
        Write-Host "Выбрано приложений: $selectedPackages. Пропущено: $skippedPackages." -ForegroundColor DarkGray
        Write-Host "Полный справочный список программ старого ПК сохранён в winget-packages.json." -ForegroundColor DarkGray
    }
}

if (-not $SkipState) {
    Write-Step "Восстановление Git, SSH, Android, Codex, VS Code и личных файлов"

    Copy-FileIfExists -Source (Join-Path $stateRoot "git\.gitconfig") -Destination (Join-Path $HOME ".gitconfig") | Out-Null

    Copy-DirIfExists -Source (Join-Path $stateRoot "ssh") -Destination (Join-Path $HOME ".ssh") | Out-Null
    Copy-DirIfExists -Source (Join-Path $stateRoot "android") -Destination (Join-Path $HOME ".android") | Out-Null
    Copy-DirIfExists -Source (Join-Path $stateRoot "vscode\User") -Destination (Join-Path $appDataDir "Code\User") | Out-Null

    $codexStateSource = Join-Path $stateRoot "codex"
    $codexStateDestination = Join-Path $HOME ".codex"
    $codexBackupSessionRoot = Join-Path $codexBackupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
    $didCodexBackup = $false

    foreach ($dirName in $codexPersistentDirs) {
        $sourceDir = Join-Path $codexStateSource $dirName
        $destinationDir = Join-Path $codexStateDestination $dirName
        if (Test-Path -LiteralPath $sourceDir) {
            if ((Test-Path -LiteralPath $destinationDir) -and -not $didCodexBackup) {
                Ensure-Dir -Path $codexBackupSessionRoot
                $didCodexBackup = $true
            }
            if (Test-Path -LiteralPath $destinationDir) {
                $backupDir = Join-Path $codexBackupSessionRoot $dirName
                robocopy $destinationDir $backupDir /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
                if ($LASTEXITCODE -ge 8) {
                    throw "Не удалось создать резервную копию через robocopy: $destinationDir -> $backupDir. Код выхода: $LASTEXITCODE"
                }
            }
            Mirror-Dir -Source $sourceDir -Destination $destinationDir | Out-Null
        }
    }

    foreach ($fileName in $codexPersistentFiles) {
        $sourceFile = Join-Path $codexStateSource $fileName
        $destinationFile = Join-Path $codexStateDestination $fileName
        if (Test-Path -LiteralPath $sourceFile) {
            if ((Test-Path -LiteralPath $destinationFile) -and -not $didCodexBackup) {
                Ensure-Dir -Path $codexBackupSessionRoot
                $didCodexBackup = $true
            }
            if (Test-Path -LiteralPath $destinationFile) {
                $backupFile = Join-Path $codexBackupSessionRoot $fileName
                Ensure-Dir -Path (Split-Path -Parent $backupFile)
                Copy-Item -LiteralPath $destinationFile -Destination $backupFile -Force
            }
            Copy-FileIfExists -Source $sourceFile -Destination $destinationFile | Out-Null
        }
    }

    Ensure-Dir -Path $PrivateRestoreRoot
    Copy-DirIfExists -Source (Join-Path $stateRoot "vpn") -Destination (Join-Path $PrivateRestoreRoot "vpn") | Out-Null
    Copy-DirIfExists -Source (Join-Path $stateRoot "android-signing") -Destination (Join-Path $PrivateRestoreRoot "android-signing") | Out-Null
    Copy-DirIfExists -Source (Join-Path $stateRoot "artifacts") -Destination (Join-Path $PrivateRestoreRoot "artifacts") | Out-Null
    Copy-DirIfExists -Source $docsRoot -Destination (Join-Path $PrivateRestoreRoot "docs") | Out-Null

    Restore-AutoManifestEntries -ManifestPath $stateManifestPath -BackupRoot (Join-Path $travelKitStateDir "backups\auto-state")
    Restore-CustomManifestEntries -ManifestPath $stateManifestPath -StateRoot $stateRoot -PrivateRestoreRoot $PrivateRestoreRoot
}

$gitPath = Find-CommandPath -Name "git" -Fallback (Join-Path ${env:ProgramFiles} "Git\cmd\git.exe")
if ($gitPath) {
    try {
        & $gitPath lfs install | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git lfs install вернул ненулевой код: $LASTEXITCODE"
        }
    } catch {
        Write-Warning "git lfs install не удался: $($_.Exception.Message)"
    }
}

if (-not $SkipRepos) {
    $gitPath = Find-CommandPath -Name "git" -Fallback (Join-Path ${env:ProgramFiles} "Git\cmd\git.exe")
    if ($gitPath -and (Test-Path -LiteralPath $repoManifestPath)) {
        Write-Step "Восстановление рабочих репозиториев"
        $effectiveWorkspaceRoot = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot } else { Get-DefaultWorkspaceRoot }
        $repoBackupRoot = Join-Path $effectiveWorkspaceRoot "_codexkit-backups"
        $repos = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $repoManifestPath -Raw | ConvertFrom-Json))
        foreach ($repo in $repos) {
            $targetPath = Resolve-RepoTargetPath -Repo $repo -RepoPathMap $repoLocationState -PreferredRoot $WorkspaceRoot
            $resolvedRepoPaths[$repo.name] = $targetPath
            $snapshotPath = Join-Path $repoSnapshotsRoot $repo.name

            if (Test-Path -LiteralPath $snapshotPath) {
                if (Test-Path -LiteralPath $targetPath) {
                    $backupPath = Backup-DirIfExists -Source $targetPath -BackupRoot $repoBackupRoot
                    if ($backupPath) {
                        Write-Host "Существующий $($repo.name) сохранён в резервную копию: $backupPath"
                    }
                }

                Write-Host "Восстанавливаю снимок $($repo.name)"
                Mirror-Dir -Source $snapshotPath -Destination $targetPath | Out-Null
                continue
            }

            if ($UseGitHubFallback -and -not [string]::IsNullOrWhiteSpace([string]$repo.url)) {
                if (Test-Path -LiteralPath (Join-Path $targetPath ".git")) {
                    Write-Host "Снимок отсутствует. Обновляю $($repo.name) из удалённого репозитория"
                    & $gitPath -C $targetPath pull --ff-only
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "git pull не удался для $($repo.name). Код выхода: $LASTEXITCODE"
                    }
                    continue
                }

                if (Test-Path -LiteralPath $targetPath) {
                    Write-Warning "Пропускаю $($repo.name): целевой путь уже существует и не является git-репозиторием."
                    continue
                }

                Write-Host "Снимок отсутствует. Клонирую $($repo.name) из удалённого репозитория"
                & $gitPath clone --branch $repo.branch $repo.url $targetPath
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "git clone не удался для $($repo.name). Код выхода: $LASTEXITCODE"
                }
                continue
            }

            Write-Warning "Снимок $($repo.name) отсутствует. CODEXKIT работает в локальном режиме, поэтому репозиторий пропущен."
        }

        if ($resolvedRepoPaths.Count -gt 0) {
            Save-RepoLocationState -RepoMap $resolvedRepoPaths -Path $repoLocationStatePath
        }
    }
}

$codePath = Find-CommandPath -Name "code" -Fallback (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd")
if ($codePath -and (Test-Path -LiteralPath $extensionsPath)) {
    Write-Step "Установка расширений VS Code"
    $extensions = Get-Content -LiteralPath $extensionsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") }
    foreach ($extension in $extensions) {
        $extensionId = ($extension -split "@", 2)[0].Trim()
        if ($extensionId) {
            & $codePath --install-extension $extensionId --force
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Установка расширения VS Code не удалась для $extensionId. Код выхода: $LASTEXITCODE"
            }
        }
    }
}

$npmPath = Find-CommandPath -Name "npm" -Fallback $null
$pnpmPath = Find-CommandPath -Name "pnpm" -Fallback $null
if ($npmPath -and -not $pnpmPath) {
    Write-Step "Установка pnpm"
    try {
        & $npmPath install -g pnpm
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "npm install -g pnpm вернул ненулевой код: $LASTEXITCODE"
        }
    } catch {
        Write-Warning "Установка pnpm не удалась: $($_.Exception.Message)"
    }
}

Write-Step "Восстановление завершено"
Write-Host "Папка программ:        $ProgramsRoot"
Write-Host "Личные файлы:          $PrivateRestoreRoot"
if ($resolvedRepoPaths.Count -gt 0) {
    Write-Host "Карта репозиториев:    $repoLocationStatePath"
}
if ($script:ResolvedNewRepoRoot) {
    Write-Host "Папка новых репо:      $script:ResolvedNewRepoRoot"
}
if (Test-Path -LiteralPath $codexBackupRoot) {
    Write-Host "Резервные копии Codex: $codexBackupRoot"
}
$backupWorkspaceRoot = if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) { $WorkspaceRoot } else { Get-DefaultWorkspaceRoot }
Write-Host "Папка резервных копий: $(Join-Path $backupWorkspaceRoot '_codexkit-backups')"
Write-Host "Следующая проверка:    запусти .\\verify-codexkit.ps1"
