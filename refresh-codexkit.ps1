param(
    [string]$KitRoot = (Split-Path -Parent $PSCommandPath),
    [string]$ArchivePassword
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

function Clear-Dir {
    param([string]$Path)

    Ensure-Dir -Path $Path

    $emptyDir = Join-Path $env:TEMP "codexkit-empty-dir"
    if (-not (Test-Path -LiteralPath $emptyDir)) {
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    } else {
        Get-ChildItem -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    robocopy $emptyDir $Path /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy mirror cleanup failed for $Path with exit code $LASTEXITCODE"
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
    robocopy $Source $Destination /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed for $Source -> $Destination with exit code $LASTEXITCODE"
    }

    return $true
}

function Copy-DirWithExclusions {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @()
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }

    Ensure-Dir -Path $Destination

    $args = @(
        $Source,
        $Destination,
        "/E",
        "/R:1",
        "/W:1",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS",
        "/NC",
        "/NS"
    )

    if ($ExcludeDirs.Count -gt 0) {
        $args += "/XD"
        $args += $ExcludeDirs
    }

    if ($ExcludeFiles.Count -gt 0) {
        $args += "/XF"
        $args += $ExcludeFiles
    }

    robocopy @args | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed for $Source -> $Destination with exit code $LASTEXITCODE"
    }

    return $true
}

function Add-ManifestEntry {
    param(
        [System.Collections.Generic.List[object]]$Manifest,
        [string]$Category,
        [string]$Source,
        [string]$Destination,
        [string]$Status
    )

    $Manifest.Add([pscustomobject]@{
        category    = $Category
        source      = $Source
        destination = $Destination
        status      = $Status
    }) | Out-Null
}

function Normalize-ZipTimestamps {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    $minDate = [datetime]::new(1980, 1, 1, 0, 0, 0, [datetimekind]::Local)
    $maxDate = [datetime]::new(2107, 12, 31, 23, 59, 58, [datetimekind]::Local)
    $safeDate = [datetime]::new(1980, 1, 2, 0, 0, 0, [datetimekind]::Local)

    Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.LastWriteTime -lt $minDate -or $_.LastWriteTime -gt $maxDate) {
            $_.LastWriteTime = $safeDate
        }
    }
}

function Get-DriveFileSystem {
    param([string]$Path)

    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
        $targetPath = if ($resolved) { $resolved.Path } else { $Path }
        $root = [System.IO.Path]::GetPathRoot($targetPath)
        if ([string]::IsNullOrWhiteSpace($root)) {
            return $null
        }

        $driveLetter = $root.TrimEnd('\').TrimEnd(':')
        if ([string]::IsNullOrWhiteSpace($driveLetter)) {
            return $null
        }

        $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($volume) {
            return $volume.FileSystem
        }
    } catch {
        return $null
    }

    return $null
}

function Get-PathTotalBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [int64]0
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        return [int64]$item.Length
    }

    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) {
        return [int64]0
    }

    return [int64]$sum
}

function Expand-ConfiguredPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-OptionalJsonConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    } catch {
        Write-Warning "Could not read JSON config ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Get-CommandVersionInfo {
    param(
        [string]$CommandName,
        [string[]]$VersionArgs = @("--version")
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $command) {
        return [pscustomobject]@{
            command = $CommandName
            found   = $false
            path    = $null
            version = $null
        }
    }

    $versionText = $null
    try {
        $versionText = (& $command.Source @VersionArgs 2>&1 | Select-Object -First 1).ToString().Trim()
    } catch {
        $versionText = $null
    }

    return [pscustomobject]@{
        command = $CommandName
        found   = $true
        path    = $command.Source
        version = $versionText
    }
}

function Find-CodeCommand {
    $command = Get-Command code -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $fallback = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    return $null
}

function Get-ConfiguredCopyEntries {
    param(
        [object]$Config,
        [string]$StateRoot,
        [string]$DocsRoot
    )

    $files = New-Object System.Collections.Generic.List[hashtable]
    $directories = New-Object System.Collections.Generic.List[hashtable]

    if (-not $Config) {
        return [pscustomobject]@{
            files       = $files
            directories = $directories
        }
    }

    foreach ($entry in @($Config.files)) {
        $source = Expand-ConfiguredPath -Path ([string]$entry.source)
        $destinationRelative = [string]$entry.destination
        $target = if ([string]::IsNullOrWhiteSpace([string]$entry.target)) { "state" } else { ([string]$entry.target).ToLowerInvariant() }
        $category = if ([string]::IsNullOrWhiteSpace([string]$entry.category)) { "custom" } else { [string]$entry.category }

        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destinationRelative)) {
            Write-Warning "Skipping invalid custom file entry in custom-paths.json because source or destination is empty."
            continue
        }

        $baseRoot = if ($target -eq "docs") { $DocsRoot } else { $StateRoot }
        $files.Add(@{
            Category    = $category
            Source      = $source
            Destination = (Join-Path $baseRoot $destinationRelative)
        }) | Out-Null
    }

    foreach ($entry in @($Config.directories)) {
        $source = Expand-ConfiguredPath -Path ([string]$entry.source)
        $destinationRelative = [string]$entry.destination
        $target = if ([string]::IsNullOrWhiteSpace([string]$entry.target)) { "state" } else { ([string]$entry.target).ToLowerInvariant() }
        $category = if ([string]::IsNullOrWhiteSpace([string]$entry.category)) { "custom" } else { [string]$entry.category }

        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destinationRelative)) {
            Write-Warning "Skipping invalid custom directory entry in custom-paths.json because source or destination is empty."
            continue
        }

        $baseRoot = if ($target -eq "docs") { $DocsRoot } else { $StateRoot }
        $directories.Add(@{
            Category    = $category
            Source      = $source
            Destination = (Join-Path $baseRoot $destinationRelative)
        }) | Out-Null
    }

    return [pscustomobject]@{
        files       = $files
        directories = $directories
    }
}

function Get-ConfiguredRepoRoots {
    param(
        [object]$Config,
        [string]$HomeDir,
        [string]$WorkspaceRoot
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        (Join-Path $HomeDir "Documents\Codex"),
        (Join-Path $HomeDir "Documents"),
        (Join-Path $HomeDir "source"),
        (Join-Path $HomeDir "projects"),
        (Join-Path $HomeDir "dev"),
        (Join-Path $HomeDir "Desktop"),
        (Join-Path $WorkspaceRoot "work")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidates.Add($candidate) | Out-Null
        }
    }

    if ($Config) {
        foreach ($root in @($Config.repo_roots)) {
            $expanded = Expand-ConfiguredPath -Path ([string]$root)
            if (-not [string]::IsNullOrWhiteSpace($expanded)) {
                $candidates.Add($expanded) | Out-Null
            }
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

function Get-GitRepoMetadata {
    param([string]$RepoPath)

    $branch = $null
    $remoteUrl = $null

    try {
        $branch = (& git -C $RepoPath branch --show-current 2>$null | Select-Object -First 1).ToString().Trim()
    } catch {
        $branch = $null
    }

    try {
        $remoteUrl = (& git -C $RepoPath remote get-url origin 2>$null | Select-Object -First 1).ToString().Trim()
    } catch {
        $remoteUrl = $null
    }

    return [pscustomobject]@{
        branch = $branch
        url    = $remoteUrl
    }
}

function Discover-RepoManifestEntries {
    param(
        [System.Collections.Generic.List[string]]$Roots,
        [string[]]$ExcludedPathPrefixes
    )

    $repos = New-Object System.Collections.Generic.List[object]
    $seenRepoPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $Roots) {
        Write-Host "Scanning repos under $root" -ForegroundColor DarkCyan

        $gitDirs = Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -Filter ".git" -ErrorAction SilentlyContinue
        foreach ($gitDir in $gitDirs) {
            $repoPath = Split-Path -Parent $gitDir.FullName
            if ([string]::IsNullOrWhiteSpace($repoPath)) {
                continue
            }

            $skip = $false
            foreach ($excludedPrefix in $ExcludedPathPrefixes) {
                if (-not [string]::IsNullOrWhiteSpace($excludedPrefix) -and $repoPath.StartsWith($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $skip = $true
                    break
                }
            }

            if ($skip -or -not $seenRepoPaths.Add($repoPath)) {
                continue
            }

            $metadata = Get-GitRepoMetadata -RepoPath $repoPath
            $repos.Add([pscustomobject]@{
                name        = (Split-Path -Leaf $repoPath)
                url         = $metadata.url
                branch      = $metadata.branch
                source_path = $repoPath
                notes       = "Auto-discovered git repository."
            }) | Out-Null
        }
    }

    return $repos
}

function Get-RepoManifestEntries {
    param(
        [string]$RepoManifestPath,
        [System.Collections.Generic.List[string]]$Roots,
        [string[]]$ExcludedPathPrefixes
    )

    if (Test-Path -LiteralPath $RepoManifestPath) {
        try {
            $existingRepos = @(Get-Content -LiteralPath $RepoManifestPath -Raw | ConvertFrom-Json)
            if ($existingRepos.Count -gt 0) {
                return $existingRepos
            }
        } catch {
            Write-Warning "Could not read repo-manifest.json: $($_.Exception.Message)"
        }
    }

    Write-Step "Discovering work repository snapshots"
    $discoveredRepos = @(Discover-RepoManifestEntries -Roots $Roots -ExcludedPathPrefixes $ExcludedPathPrefixes)
    $discoveredRepos | ConvertTo-Json -Depth 4 | Set-Content -Path $RepoManifestPath -Encoding UTF8
    return $discoveredRepos
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

$homeDir = [Environment]::GetFolderPath("UserProfile")
$appDataDir = [Environment]::GetFolderPath("ApplicationData")
$workspaceRoot = Split-Path -Parent $KitRoot
$stateRoot = Join-Path $KitRoot "state"
$repoSnapshotsRoot = Join-Path $KitRoot "repo-snapshots"
$docsRoot = Join-Path $KitRoot "docs"
$zipPath = Join-Path $KitRoot "codexkit-state.zip"
$transferZipPath = Join-Path $KitRoot "codexkit-transfer.zip"
$secureTransferPath = Join-Path $KitRoot "codexkit-transfer-secure.rar"
$manifestPath = Join-Path $KitRoot "state-manifest.json"
$hashesPath = Join-Path $KitRoot "archive-hashes.txt"
$toolVersionsPath = Join-Path $KitRoot "tool-versions.json"
$extensionsPath = Join-Path $KitRoot "vscode-extensions.txt"
$machineInfoPath = Join-Path $KitRoot "machine-info.json"
$bootstrapPackagesPath = Join-Path $KitRoot "bootstrap-packages.json"
$repoManifestPath = Join-Path $KitRoot "repo-manifest.json"
$customPathsConfigPath = Join-Path $KitRoot "custom-paths.json"

$manifest = [System.Collections.Generic.List[object]]::new()
$customPathsConfig = Get-OptionalJsonConfig -Path $customPathsConfigPath
$configuredCopyEntries = Get-ConfiguredCopyEntries -Config $customPathsConfig -StateRoot $stateRoot -DocsRoot $docsRoot
$repoRoots = Get-ConfiguredRepoRoots -Config $customPathsConfig -HomeDir $homeDir -WorkspaceRoot $workspaceRoot

Write-Step "Refreshing state folder"
Clear-Dir -Path $stateRoot
Clear-Dir -Path $repoSnapshotsRoot
Ensure-Dir -Path $docsRoot

Write-Step "Writing machine info"
$machineInfo = [pscustomobject]@{
    generated_at   = (Get-Date).ToString("o")
    source_machine = $env:COMPUTERNAME
    source_user    = $env:USERNAME
    source_home    = $homeDir
}
$machineInfo | ConvertTo-Json -Depth 4 | Set-Content -Path $machineInfoPath -Encoding UTF8

$copyFiles = @(
    @{ Category = "git"; Source = (Join-Path $homeDir ".gitconfig"); Destination = (Join-Path $stateRoot "git\.gitconfig") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\settings.json"); Destination = (Join-Path $stateRoot "vscode\User\settings.json") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\chatLanguageModels.json"); Destination = (Join-Path $stateRoot "vscode\User\chatLanguageModels.json") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\agent-sessions.code-workspace"); Destination = (Join-Path $stateRoot "vscode\User\agent-sessions.code-workspace") },
    @{ Category = "android"; Source = (Join-Path $homeDir ".android\adbkey"); Destination = (Join-Path $stateRoot "android\adbkey") },
    @{ Category = "android"; Source = (Join-Path $homeDir ".android\adbkey.pub"); Destination = (Join-Path $stateRoot "android\adbkey.pub") },
    @{ Category = "android"; Source = (Join-Path $homeDir ".android\debug.keystore"); Destination = (Join-Path $stateRoot "android\debug.keystore") }
)

foreach ($entry in $configuredCopyEntries.files) {
    $copyFiles += $entry
}

foreach ($entry in $copyFiles) {
    $status = if (Copy-FileIfExists -Source $entry.Source -Destination $entry.Destination) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category $entry.Category -Source $entry.Source -Destination $entry.Destination -Status $status
}

foreach ($fileName in $codexPersistentFiles) {
    $source = Join-Path $homeDir ".codex\$fileName"
    $destination = Join-Path $stateRoot "codex\$fileName"
    $status = if (Copy-FileIfExists -Source $source -Destination $destination) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category "codex-history" -Source $source -Destination $destination -Status $status
}

$copyDirs = @(
    @{ Category = "ssh"; Source = (Join-Path $homeDir ".ssh"); Destination = (Join-Path $stateRoot "ssh") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\snippets"); Destination = (Join-Path $stateRoot "vscode\User\snippets") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\profiles"); Destination = (Join-Path $stateRoot "vscode\User\profiles") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\globalStorage"); Destination = (Join-Path $stateRoot "vscode\User\globalStorage") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\workspaceStorage"); Destination = (Join-Path $stateRoot "vscode\User\workspaceStorage") }
)

foreach ($entry in $configuredCopyEntries.directories) {
    $copyDirs += $entry
}

foreach ($entry in $copyDirs) {
    $status = if (Copy-DirIfExists -Source $entry.Source -Destination $entry.Destination) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category $entry.Category -Source $entry.Source -Destination $entry.Destination -Status $status
}

foreach ($dirName in $codexPersistentDirs) {
    $source = Join-Path $homeDir ".codex\$dirName"
    $destination = Join-Path $stateRoot "codex\$dirName"
    $status = if (Copy-DirIfExists -Source $source -Destination $destination) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category "codex-history" -Source $source -Destination $destination -Status $status
}

Write-Step "Capturing work repository snapshots"
$repoExcludeDirs = @(
    ".gradle",
    ".idea",
    ".kotlin",
    "build",
    "artifacts",
    "work",
    "node_modules",
    "dist",
    "out",
    ".cxx",
    ".externalNativeBuild"
)
$repoExcludeFiles = @(
    "local.properties",
    "Thumbs.db"
)
$repoManifestEntries = @(Get-RepoManifestEntries -RepoManifestPath $repoManifestPath -Roots $repoRoots -ExcludedPathPrefixes @($stateRoot, $repoSnapshotsRoot, $KitRoot))
foreach ($repo in $repoManifestEntries) {
    $sourcePath = $repo.source_path
    $snapshotPath = Join-Path $repoSnapshotsRoot $repo.name
    $status = if (Copy-DirWithExclusions -Source $sourcePath -Destination $snapshotPath -ExcludeDirs $repoExcludeDirs -ExcludeFiles $repoExcludeFiles) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category "repo-snapshot" -Source $sourcePath -Destination $snapshotPath -Status $status
}

Write-Step "Capturing tool versions"
$toolVersions = @(
    Get-CommandVersionInfo -CommandName "git"
    Get-CommandVersionInfo -CommandName "gh"
    Get-CommandVersionInfo -CommandName "code"
    Get-CommandVersionInfo -CommandName "codex"
    Get-CommandVersionInfo -CommandName "python"
    Get-CommandVersionInfo -CommandName "py" -VersionArgs @("--version")
    Get-CommandVersionInfo -CommandName "java"
    Get-CommandVersionInfo -CommandName "javac"
    Get-CommandVersionInfo -CommandName "adb"
    Get-CommandVersionInfo -CommandName "node"
    Get-CommandVersionInfo -CommandName "npm"
    Get-CommandVersionInfo -CommandName "pnpm"
)
$toolVersions | ConvertTo-Json -Depth 4 | Set-Content -Path $toolVersionsPath -Encoding UTF8

Write-Step "Capturing VS Code extensions"
$codeCommand = Find-CodeCommand
if ($codeCommand) {
    & $codeCommand --list-extensions --show-versions | Set-Content -Path $extensionsPath -Encoding UTF8
} else {
    Set-Content -Path $extensionsPath -Value "# code command not found on source machine" -Encoding UTF8
}

Write-Step "Writing state manifest"
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Step "Normalizing archive timestamps"
Normalize-ZipTimestamps -Root $stateRoot
Normalize-ZipTimestamps -Root $repoSnapshotsRoot
Normalize-ZipTimestamps -Root $docsRoot

Write-Step "Creating zip archive"
$effectiveStateZipPath = $zipPath
$zipBuildPath = Join-Path $KitRoot "codexkit-state.__new.zip"
if (Test-Path -LiteralPath $zipBuildPath) {
    Remove-Item -LiteralPath $zipBuildPath -Force -ErrorAction SilentlyContinue
}
Compress-Archive -Path $stateRoot -DestinationPath $zipBuildPath -Force

Write-Step "Creating transfer archive"
if (Test-Path -LiteralPath $zipPath) {
    try {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $zipBuildPath -Destination $zipPath -Force
    } catch {
        $effectiveStateZipPath = $zipBuildPath
        Write-Warning "Could not replace existing codexkit-state.zip because it is locked. Using $effectiveStateZipPath for this run."
    }
} else {
    Move-Item -LiteralPath $zipBuildPath -Destination $zipPath -Force
}

$effectiveTransferZipPath = $transferZipPath
$transferZipBuildPath = Join-Path $KitRoot "codexkit-transfer.__new.zip"
if (Test-Path -LiteralPath $transferZipBuildPath) {
    Remove-Item -LiteralPath $transferZipBuildPath -Force -ErrorAction SilentlyContinue
}
$transferItems = @(
    (Join-Path $KitRoot "1-BEFORE-MOVE.bat"),
    (Join-Path $KitRoot "2-RESTORE-HERE.bat"),
    (Join-Path $KitRoot "README-RU.md"),
    (Join-Path $KitRoot "refresh-codexkit.ps1"),
    (Join-Path $KitRoot "restore-codexkit.ps1"),
    (Join-Path $KitRoot "verify-codexkit.ps1"),
    $bootstrapPackagesPath,
    $customPathsConfigPath,
    $repoManifestPath,
    (Join-Path $KitRoot "winget-packages.json"),
    $toolVersionsPath,
    $extensionsPath,
    $hashesPath,
    $manifestPath,
    $machineInfoPath,
    $docsRoot,
    $repoSnapshotsRoot,
    $effectiveStateZipPath
) | Where-Object { Test-Path -LiteralPath $_ }
$targetFileSystem = Get-DriveFileSystem -Path $KitRoot
$fat32LimitBytes = [int64]4294967295
$transferItemsEstimatedBytes = [int64]0
foreach ($item in $transferItems) {
    $transferItemsEstimatedBytes += Get-PathTotalBytes -Path $item
}

$transferArchiveSkipped = $false
if ($targetFileSystem -eq "FAT32" -and $transferItemsEstimatedBytes -gt $fat32LimitBytes) {
    $transferArchiveSkipped = $true
    $effectiveTransferZipPath = $null
    if (Test-Path -LiteralPath $transferZipPath) {
        Remove-Item -LiteralPath $transferZipPath -Force -ErrorAction SilentlyContinue
    }
    Write-Warning "Skipping codexkit-transfer.zip: estimated content size is larger than the 4 GB FAT32 file limit. Use the CODEXKIT folder directly."
} else {
    Compress-Archive -Path $transferItems -DestinationPath $transferZipBuildPath -Force
    if (Test-Path -LiteralPath $transferZipPath) {
        try {
            Remove-Item -LiteralPath $transferZipPath -Force -ErrorAction Stop
            Move-Item -LiteralPath $transferZipBuildPath -Destination $transferZipPath -Force
        } catch {
            $effectiveTransferZipPath = $transferZipBuildPath
            Write-Warning "Could not replace existing codexkit-transfer.zip because it is locked. Using $effectiveTransferZipPath for this run."
        }
    } else {
        Move-Item -LiteralPath $transferZipBuildPath -Destination $transferZipPath -Force
    }
}

$legacySecureArchivePath = Join-Path $KitRoot "codexkit-state-secure.rar"
if (Test-Path -LiteralPath $legacySecureArchivePath) {
    Remove-Item -LiteralPath $legacySecureArchivePath -Force
}

if ($ArchivePassword) {
    $winRarPath = "C:\Program Files\WinRAR\WinRAR.exe"
    if ($transferArchiveSkipped) {
        Write-Warning "Skipping password-protected transfer archive for the same FAT32 size limit reason. Use the CODEXKIT folder directly."
    } elseif (Test-Path -LiteralPath $winRarPath) {
        Write-Step "Creating password-protected transfer archive"
        if (Test-Path -LiteralPath $secureTransferPath) {
            Remove-Item -LiteralPath $secureTransferPath -Force
        }
        & $winRarPath a -r "-hp$ArchivePassword" $secureTransferPath @transferItems | Out-Null
    } else {
        Write-Warning "Archive password was provided, but WinRAR was not found. Skipping secure archive."
    }
}

Write-Step "Writing archive hashes"
$hashLines = New-Object System.Collections.Generic.List[string]
if ($effectiveStateZipPath -and (Test-Path -LiteralPath $effectiveStateZipPath)) {
    $zipHash = (Get-FileHash -LiteralPath $effectiveStateZipPath -Algorithm SHA256).Hash
    $hashLines.Add("$([System.IO.Path]::GetFileName($effectiveStateZipPath)) SHA256 $zipHash") | Out-Null
}
if (Test-Path -LiteralPath $effectiveTransferZipPath) {
    $transferZipHash = (Get-FileHash -LiteralPath $effectiveTransferZipPath -Algorithm SHA256).Hash
    $hashLines.Add("$([System.IO.Path]::GetFileName($effectiveTransferZipPath)) SHA256 $transferZipHash") | Out-Null
} elseif ($transferArchiveSkipped) {
    $hashLines.Add("codexkit-transfer.zip SKIPPED FAT32_4GB_LIMIT") | Out-Null
}
if (Test-Path -LiteralPath $secureTransferPath) {
    $rarHash = (Get-FileHash -LiteralPath $secureTransferPath -Algorithm SHA256).Hash
    $hashLines.Add("codexkit-transfer-secure.rar SHA256 $rarHash") | Out-Null
} elseif ($transferArchiveSkipped -and $ArchivePassword) {
    $hashLines.Add("codexkit-transfer-secure.rar SKIPPED FAT32_4GB_LIMIT") | Out-Null
}
$hashLines | Set-Content -Path $hashesPath -Encoding UTF8

Write-Step "CODEXKIT refresh complete"
