param(
    [string]$KitRoot = (Split-Path -Parent $PSCommandPath),
    [string]$ArchivePassword,
    [ValidateSet("Auto", "Full", "Incremental")]
    [string]$RefreshMode = "Auto"
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

    robocopy $emptyDir $Path /MIR /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy mirror cleanup failed for $Path with exit code $LASTEXITCODE"
    }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-FileIfExists {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$Incremental
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }

    if ($Incremental -and -not (Test-FileCopyRequired -Source $Source -Destination $Destination)) {
        return $true
    }

    Ensure-Dir -Path (Split-Path -Parent $Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

function Get-FileSha256 {
    param([string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Test-FileCopyRequired {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        return $true
    }

    $sourceItem = Get-Item -LiteralPath $Source -Force
    $destinationItem = Get-Item -LiteralPath $Destination -Force

    if ([int64]$sourceItem.Length -ne [int64]$destinationItem.Length) {
        return $true
    }

    $timeDeltaSeconds = [Math]::Abs(($sourceItem.LastWriteTimeUtc - $destinationItem.LastWriteTimeUtc).TotalSeconds)
    return ($timeDeltaSeconds -gt 2)
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
    robocopy $Source $Destination /E /XJ /FFT /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
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
        "/XJ",
        "/FFT",
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
        category            = $Category
        source              = $Source
        destination         = $Destination
        restore_destination = Get-PortableRestorePath -Path $Source
        status              = $Status
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

function Get-ArchiveRelativePath {
    param(
        [string]$BaseRoot,
        [string]$Path
    )

    $relative = Convert-ToRelativePath -Root $BaseRoot -Path $Path
    if ($null -eq $relative) {
        $relative = Split-Path -Leaf $Path
    }

    return ($relative -replace '\\', '/')
}

function Get-TransferFileEntries {
    param(
        [string[]]$Items,
        [string]$BaseRoot
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        if (-not (Test-Path -LiteralPath $item)) {
            continue
        }

        $resolvedItem = (Resolve-Path -LiteralPath $item).Path
        $fileItem = Get-Item -LiteralPath $resolvedItem -Force
        if (-not $fileItem.PSIsContainer) {
            $entries.Add([pscustomobject]@{
                file_path    = $fileItem.FullName
                archive_path = Get-ArchiveRelativePath -BaseRoot $BaseRoot -Path $fileItem.FullName
                length       = [int64]$fileItem.Length
            }) | Out-Null
            continue
        }

        Get-ChildItem -LiteralPath $fileItem.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $entries.Add([pscustomobject]@{
                file_path    = $_.FullName
                archive_path = Get-ArchiveRelativePath -BaseRoot $BaseRoot -Path $_.FullName
                length       = [int64]$_.Length
            }) | Out-Null
        }
    }

    return @($entries | Sort-Object archive_path)
}

function Add-FileChunkToZip {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [System.IO.Stream]$SourceStream,
        [string]$EntryName,
        [int64]$BytesToCopy
    )

    $entry = $Zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::NoCompression)
    $targetStream = $entry.Open()
    try {
        $buffer = New-Object byte[] (1024 * 1024)
        $remaining = [int64]$BytesToCopy
        while ($remaining -gt 0) {
            $readSize = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $read = $SourceStream.Read($buffer, 0, $readSize)
            if ($read -le 0) {
                break
            }
            $targetStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
    } finally {
        $targetStream.Dispose()
    }
}

function New-SplitTransferArchives {
    param(
        [string[]]$Items,
        [string]$BaseRoot,
        [string]$PartsRoot,
        [int64]$PartTargetBytes
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Clear-Dir -Path $PartsRoot

    $partPaths = New-Object System.Collections.Generic.List[string]
    $largeFileRecords = New-Object System.Collections.Generic.List[object]
    $entries = @(Get-TransferFileEntries -Items $Items -BaseRoot $BaseRoot)

    $currentPart = $null
    $currentBytes = [int64]0
    $partIndex = 0

    foreach ($entry in $entries) {
        if ($entry.length -gt $PartTargetBytes) {
            $sourceStream = [System.IO.File]::OpenRead([string]$entry.file_path)
            try {
                $remaining = [int64]$entry.length
                $chunkIndex = 0
                $chunkId = [guid]::NewGuid().ToString("N")
                $chunks = New-Object System.Collections.Generic.List[string]

                while ($remaining -gt 0) {
                    if ($null -eq $currentPart -or $currentBytes -gt 0) {
                        if ($currentPart) {
                            $currentPart.Zip.Dispose()
                        }
                        $partIndex++
                        $partPath = Join-Path $PartsRoot ("codexkit-transfer-part-{0:D3}.zip" -f $partIndex)
                        $currentPart = [pscustomobject]@{
                            Path = $partPath
                            Zip  = [System.IO.Compression.ZipFile]::Open($partPath, [System.IO.Compression.ZipArchiveMode]::Create)
                        }
                        $partPaths.Add($partPath) | Out-Null
                        $currentBytes = [int64]0
                    }

                    $chunkIndex++
                    $chunkBytes = [Math]::Min($PartTargetBytes, $remaining)
                    $chunkName = "{0:D5}" -f $chunkIndex
                    $chunkEntryName = "codexkit-large-files/$chunkId/chunk-$chunkName.bin"
                    Add-FileChunkToZip -Zip $currentPart.Zip -SourceStream $sourceStream -EntryName $chunkEntryName -BytesToCopy $chunkBytes
                    $chunks.Add($chunkEntryName) | Out-Null
                    $currentBytes += [int64]$chunkBytes
                    $remaining -= [int64]$chunkBytes
                }

                $largeFileRecords.Add([pscustomobject]@{
                    path   = [string]$entry.archive_path
                    length = [int64]$entry.length
                    chunks = @($chunks.ToArray())
                }) | Out-Null
            } finally {
                $sourceStream.Dispose()
            }
            continue
        }

        if ($null -eq $currentPart -or ($currentBytes -gt 0 -and ($currentBytes + [int64]$entry.length) -gt $PartTargetBytes)) {
            if ($currentPart) {
                $currentPart.Zip.Dispose()
            }
            $partIndex++
            $partPath = Join-Path $PartsRoot ("codexkit-transfer-part-{0:D3}.zip" -f $partIndex)
            $currentPart = [pscustomobject]@{
                Path = $partPath
                Zip  = [System.IO.Compression.ZipFile]::Open($partPath, [System.IO.Compression.ZipArchiveMode]::Create)
            }
            $partPaths.Add($partPath) | Out-Null
            $currentBytes = [int64]0
        }

        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $currentPart.Zip,
            [string]$entry.file_path,
            [string]$entry.archive_path,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
        $currentBytes += [Math]::Max([int64]$entry.length, [int64]1)
    }

    if ($largeFileRecords.Count -gt 0) {
        $manifestJson = ([pscustomobject]@{
            version = 1
            files   = @($largeFileRecords.ToArray())
        } | ConvertTo-Json -Depth 8)
        $manifestBytes = [System.Text.Encoding]::UTF8.GetBytes($manifestJson)

        if ($null -eq $currentPart -or ($currentBytes + $manifestBytes.Length) -gt $PartTargetBytes) {
            if ($currentPart) {
                $currentPart.Zip.Dispose()
            }
            $partIndex++
            $partPath = Join-Path $PartsRoot ("codexkit-transfer-part-{0:D3}.zip" -f $partIndex)
            $currentPart = [pscustomobject]@{
                Path = $partPath
                Zip  = [System.IO.Compression.ZipFile]::Open($partPath, [System.IO.Compression.ZipArchiveMode]::Create)
            }
            $partPaths.Add($partPath) | Out-Null
            $currentBytes = [int64]0
        }

        $manifestEntry = $currentPart.Zip.CreateEntry("codexkit-large-files/manifest.json", [System.IO.Compression.CompressionLevel]::Optimal)
        $manifestStream = $manifestEntry.Open()
        try {
            $manifestStream.Write($manifestBytes, 0, $manifestBytes.Length)
        } finally {
            $manifestStream.Dispose()
        }
    }

    if ($currentPart) {
        $currentPart.Zip.Dispose()
    }

    return @($partPaths)
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

function Test-SkippedDriveRepoFolderName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    $excludedNames = @(
        '$RECYCLE.BIN',
        'System Volume Information',
        'Recovery',
        'Windows',
        'Program Files',
        'Program Files (x86)',
        'ProgramData',
        'Users',
        'PerfLogs',
        'Games',
        'Steam',
        'SteamLibrary',
        'XboxGames',
        'WindowsApps',
        'WpSystem',
        'MSOCache',
        'OneDriveTemp',
        'msdownld.tmp',
        'Downloads',
        'Foto',
        'node_modules',
        '.gradle',
        '.venv',
        'venv',
        'dist',
        'build',
        '.next',
        'CODEXKIT',
        'travel-kit',
        'repo-snapshots',
        'codexkit-transfer-parts',
        'codexkit-large-files'
    )

    if ($excludedNames -contains $Name) {
        return $true
    }

    return ($Name -match '^[0-9a-f]{12,}$')
}

function Test-SkippedRepoPath {
    param(
        [string]$Path,
        [string[]]$ExcludedPathPrefixes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    foreach ($excludedPrefix in $ExcludedPathPrefixes) {
        if (-not [string]::IsNullOrWhiteSpace($excludedPrefix) -and $Path.StartsWith($excludedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $pathParts = @($Path -split '[\\/]') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $skippedParts = @(
        'CODEXKIT',
        'travel-kit',
        'repo-snapshots',
        'codexkit-transfer-parts',
        'codexkit-large-files',
        'node_modules',
        '.gradle',
        '.venv',
        'venv',
        'dist',
        'build',
        '.next'
    )

    foreach ($part in $pathParts) {
        if ($skippedParts -contains $part) {
            return $true
        }
    }

    return $false
}

function Find-GitRepoPathsBounded {
    param(
        [string]$Root,
        [int]$MaxDepth = 3
    )

    $repos = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $repos
    }

    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{
        Path  = $Root
        Depth = 0
    })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $currentPath = [string]$current.Path
        $gitPath = Join-Path $currentPath ".git"
        if (Test-Path -LiteralPath $gitPath) {
            $repos.Add($currentPath) | Out-Null
            continue
        }

        if ([int]$current.Depth -ge $MaxDepth) {
            continue
        }

        try {
            Get-ChildItem -LiteralPath $currentPath -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-SkippedDriveRepoFolderName -Name $_.Name) } |
                ForEach-Object {
                    $queue.Enqueue([pscustomobject]@{
                        Path  = $_.FullName
                        Depth = ([int]$current.Depth + 1)
                    })
                }
        } catch {
            continue
        }
    }

    return $repos
}

function Get-LooseDriveRepoRoots {
    param([int]$MaxDepth = 3)

    $repos = New-Object System.Collections.Generic.List[string]
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($drive.Root) -or -not (Test-Path -LiteralPath $drive.Root)) {
            continue
        }

        try {
            Get-ChildItem -LiteralPath $drive.Root -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-SkippedDriveRepoFolderName -Name $_.Name) } |
                ForEach-Object {
                    foreach ($repoPath in (Find-GitRepoPathsBounded -Root $_.FullName -MaxDepth $MaxDepth)) {
                        $repos.Add($repoPath) | Out-Null
                    }
                }
        } catch {
            continue
        }
    }

    return $repos
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
        (Join-Path $HomeDir "OneDrive\Documents"),
        (Join-Path $HomeDir "Desktop"),
        (Join-Path $HomeDir "source"),
        (Join-Path $HomeDir "src"),
        (Join-Path $HomeDir "projects"),
        (Join-Path $HomeDir "Projects"),
        (Join-Path $HomeDir "dev"),
        (Join-Path $HomeDir "repos"),
        (Join-Path $HomeDir "GitHub"),
        (Join-Path $WorkspaceRoot "work")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidates.Add($candidate) | Out-Null
        }
    }

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($folderName in @("Projects", "projects", "Code", "code", "dev", "source", "src", "repos", "GitHub")) {
            $candidate = Join-Path $drive.Root $folderName
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $candidates.Add($candidate) | Out-Null
            }
        }
    }

    foreach ($candidate in (Get-LooseDriveRepoRoots -MaxDepth 3)) {
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

function Convert-ToRelativePath {
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

function Get-PortableRestorePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $portableRoots = @(
        @{ Root = $homeDir; Token = "%USERPROFILE%" },
        @{ Root = $appDataDir; Token = "%APPDATA%" },
        @{ Root = $localAppDataDir; Token = "%LOCALAPPDATA%" }
    )

    foreach ($item in $portableRoots) {
        $root = [string]$item.Root
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        $relative = Convert-ToRelativePath -Root $root -Path $Path
        if ($null -ne $relative) {
            if ([string]::IsNullOrWhiteSpace($relative)) {
                return [string]$item.Token
            }
            return (Join-Path ([string]$item.Token) $relative)
        }
    }

    return $Path
}

function Add-DetectedFileEntry {
    param(
        [System.Collections.Generic.List[hashtable]]$Files,
        [string]$Category,
        [string]$Source,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        return
    }

    $Files.Add(@{
        Category    = $Category
        Source      = $Source
        Destination = $Destination
    }) | Out-Null
}

function Add-DetectedDirectoryEntry {
    param(
        [System.Collections.Generic.List[hashtable]]$Directories,
        [string]$Category,
        [string]$Source,
        [string]$Destination
    )

    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source -PathType Container)) {
        return
    }

    $Directories.Add(@{
        Category    = $Category
        Source      = $Source
        Destination = $Destination
    }) | Out-Null
}

function Get-DetectedEnvironmentEntries {
    param(
        [string]$HomeDir,
        [string]$AppDataDir,
        [string]$LocalAppDataDir,
        [string]$StateRoot
    )

    $files = New-Object System.Collections.Generic.List[hashtable]
    $directories = New-Object System.Collections.Generic.List[hashtable]

    Add-DetectedFileEntry -Files $files -Category "auto-git" -Source (Join-Path $HomeDir ".gitconfig") -Destination (Join-Path $StateRoot "auto\home\.gitconfig")
    Add-DetectedFileEntry -Files $files -Category "auto-git" -Source (Join-Path $HomeDir ".gitignore_global") -Destination (Join-Path $StateRoot "auto\home\.gitignore_global")
    Add-DetectedFileEntry -Files $files -Category "auto-git" -Source (Join-Path $HomeDir ".git-credentials") -Destination (Join-Path $StateRoot "auto\home\.git-credentials")

    Add-DetectedFileEntry -Files $files -Category "auto-node" -Source (Join-Path $HomeDir ".npmrc") -Destination (Join-Path $StateRoot "auto\home\.npmrc")
    Add-DetectedFileEntry -Files $files -Category "auto-node" -Source (Join-Path $HomeDir ".yarnrc") -Destination (Join-Path $StateRoot "auto\home\.yarnrc")
    Add-DetectedFileEntry -Files $files -Category "auto-node" -Source (Join-Path $HomeDir ".yarnrc.yml") -Destination (Join-Path $StateRoot "auto\home\.yarnrc.yml")
    Add-DetectedFileEntry -Files $files -Category "auto-node" -Source (Join-Path $HomeDir ".pnpmrc") -Destination (Join-Path $StateRoot "auto\home\.pnpmrc")

    Add-DetectedFileEntry -Files $files -Category "auto-python" -Source (Join-Path $HomeDir "pip\pip.ini") -Destination (Join-Path $StateRoot "auto\home\pip\pip.ini")
    Add-DetectedFileEntry -Files $files -Category "auto-python" -Source (Join-Path $HomeDir ".pypirc") -Destination (Join-Path $StateRoot "auto\home\.pypirc")

    Add-DetectedFileEntry -Files $files -Category "auto-java" -Source (Join-Path $HomeDir ".m2\settings.xml") -Destination (Join-Path $StateRoot "auto\home\.m2\settings.xml")
    Add-DetectedFileEntry -Files $files -Category "auto-java" -Source (Join-Path $HomeDir ".gradle\gradle.properties") -Destination (Join-Path $StateRoot "auto\home\.gradle\gradle.properties")
    Add-DetectedFileEntry -Files $files -Category "auto-java" -Source (Join-Path $HomeDir ".gradle\init.gradle") -Destination (Join-Path $StateRoot "auto\home\.gradle\init.gradle")

    Add-DetectedFileEntry -Files $files -Category "auto-terminal" -Source (Join-Path $LocalAppDataDir "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json") -Destination (Join-Path $StateRoot "auto\localappdata\WindowsTerminal\settings.json")
    Add-DetectedFileEntry -Files $files -Category "auto-nuget" -Source (Join-Path $AppDataDir "NuGet\NuGet.Config") -Destination (Join-Path $StateRoot "auto\appdata\NuGet\NuGet.Config")

    foreach ($editorName in @("Code", "Code - Insiders", "Cursor", "VSCodium")) {
        $editorUserRoot = Join-Path $AppDataDir "$editorName\User"
        $safeEditorName = $editorName -replace '[^A-Za-z0-9._-]', '-'
        Add-DetectedFileEntry -Files $files -Category "auto-editor" -Source (Join-Path $editorUserRoot "settings.json") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\settings.json")
        Add-DetectedFileEntry -Files $files -Category "auto-editor" -Source (Join-Path $editorUserRoot "keybindings.json") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\keybindings.json")
        Add-DetectedDirectoryEntry -Directories $directories -Category "auto-editor" -Source (Join-Path $editorUserRoot "snippets") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\snippets")
        Add-DetectedDirectoryEntry -Directories $directories -Category "auto-editor" -Source (Join-Path $editorUserRoot "profiles") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\profiles")
        Add-DetectedDirectoryEntry -Directories $directories -Category "auto-editor" -Source (Join-Path $editorUserRoot "globalStorage") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\globalStorage")
        Add-DetectedDirectoryEntry -Directories $directories -Category "auto-editor" -Source (Join-Path $editorUserRoot "workspaceStorage") -Destination (Join-Path $StateRoot "auto\appdata\editors\$safeEditorName\User\workspaceStorage")
    }

    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-shell" -Source (Join-Path $HomeDir "Documents\PowerShell") -Destination (Join-Path $StateRoot "auto\home\Documents\PowerShell")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-shell" -Source (Join-Path $HomeDir "Documents\WindowsPowerShell") -Destination (Join-Path $StateRoot "auto\home\Documents\WindowsPowerShell")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-github" -Source (Join-Path $AppDataDir "GitHub CLI") -Destination (Join-Path $StateRoot "auto\appdata\GitHub CLI")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-docker" -Source (Join-Path $HomeDir ".docker") -Destination (Join-Path $StateRoot "auto\home\.docker")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-kubernetes" -Source (Join-Path $HomeDir ".kube") -Destination (Join-Path $StateRoot "auto\home\.kube")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-cloud" -Source (Join-Path $HomeDir ".aws") -Destination (Join-Path $StateRoot "auto\home\.aws")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-cloud" -Source (Join-Path $HomeDir ".azure") -Destination (Join-Path $StateRoot "auto\home\.azure")
    Add-DetectedDirectoryEntry -Directories $directories -Category "auto-cloud" -Source (Join-Path $HomeDir ".config\gcloud") -Destination (Join-Path $StateRoot "auto\home\.config\gcloud")

    return [pscustomobject]@{
        files       = $files
        directories = $directories
    }
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
            if ([string]::IsNullOrWhiteSpace($repoPath) -or (Test-SkippedRepoPath -Path $repoPath -ExcludedPathPrefixes $ExcludedPathPrefixes)) {
                continue
            }

            if (-not $seenRepoPaths.Add($repoPath)) {
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

function Get-RepoSourceKey {
    param([object]$Repo)

    $sourcePath = [string]$Repo.source_path
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        return $null
    }

    return (($sourcePath -replace '[\\/]+$', '').ToLowerInvariant())
}

function Merge-RepoManifestEntries {
    param(
        [object[]]$ExistingRepos,
        [object[]]$DiscoveredRepos
    )

    $merged = New-Object System.Collections.Generic.List[object]
    $seenSourcePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($repo in @($ExistingRepos)) {
        if ($null -eq $repo) {
            continue
        }

        $sourceKey = Get-RepoSourceKey -Repo $repo
        if ($sourceKey) {
            $seenSourcePaths.Add($sourceKey) | Out-Null
        }

        $name = [string]$repo.name
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $seenNames.Add($name) | Out-Null
        }

        $merged.Add($repo) | Out-Null
    }

    foreach ($repo in @($DiscoveredRepos)) {
        if ($null -eq $repo) {
            continue
        }

        $sourceKey = Get-RepoSourceKey -Repo $repo
        $name = [string]$repo.name
        if (($sourceKey -and $seenSourcePaths.Contains($sourceKey)) -or (-not [string]::IsNullOrWhiteSpace($name) -and $seenNames.Contains($name))) {
            continue
        }

        if ($sourceKey) {
            $seenSourcePaths.Add($sourceKey) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $seenNames.Add($name) | Out-Null
        }

        $merged.Add($repo) | Out-Null
    }

    return @($merged.ToArray())
}

function Get-RepoManifestEntries {
    param(
        [string]$RepoManifestPath,
        [System.Collections.Generic.List[string]]$Roots,
        [string[]]$ExcludedPathPrefixes
    )

    $existingRepos = @()
    if (Test-Path -LiteralPath $RepoManifestPath) {
        try {
            $existingRepos = @(Get-Content -LiteralPath $RepoManifestPath -Raw | ConvertFrom-Json)
        } catch {
            Write-Warning "Could not read repo-manifest.json: $($_.Exception.Message)"
        }
    }

    Write-Step "Discovering work repository snapshots"
    $discoveredRepos = @(Discover-RepoManifestEntries -Roots $Roots -ExcludedPathPrefixes $ExcludedPathPrefixes)
    $mergedRepos = @(Merge-RepoManifestEntries -ExistingRepos $existingRepos -DiscoveredRepos $discoveredRepos)
    $mergedRepos | ConvertTo-Json -Depth 4 | Set-Content -Path $RepoManifestPath -Encoding UTF8
    return $mergedRepos
}

function ConvertTo-IndexText {
    param(
        [string]$Text,
        [int]$MaxLength = 180
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = $Text -replace '[\r\n\t]+', ' '
    $clean = $clean -replace '\s{2,}', ' '
    $clean = $clean.Trim()
    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return ($clean.Substring(0, [Math]::Max(0, $MaxLength - 3)) + "...")
}

function ConvertTo-MarkdownCell {
    param([string]$Text)

    $clean = ConvertTo-IndexText -Text $Text -MaxLength 140
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return "-"
    }

    return ($clean -replace '\|', '\|')
}

function Read-JsonlObjects {
    param(
        [string]$Path,
        [int]$MaxLines = 0
    )

    $objects = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $objects
    }

    $lineCount = 0
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $lineCount++
        if ($MaxLines -gt 0 -and $lineCount -gt $MaxLines) {
            break
        }

        try {
            $objects.Add(($line | ConvertFrom-Json)) | Out-Null
        } catch {
            continue
        }
    }

    return $objects
}

function Get-CodexSessionIndexEntries {
    param([string]$CodexHome)

    $entries = New-Object System.Collections.Generic.List[object]
    $sessionIndexPath = Join-Path $CodexHome "session_index.jsonl"
    foreach ($entry in (Read-JsonlObjects -Path $sessionIndexPath)) {
        $entries.Add([pscustomobject]@{
            id          = [string]$entry.id
            thread_name = ConvertTo-IndexText -Text ([string]$entry.thread_name) -MaxLength 180
            updated_at  = [string]$entry.updated_at
        }) | Out-Null
    }

    return $entries
}

function Get-CodexSessionFileEntries {
    param(
        [string]$CodexHome,
        [hashtable]$ThreadNamesById
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $sessionRoots = @(
        @{ Path = (Join-Path $CodexHome "sessions"); Kind = "active" },
        @{ Path = (Join-Path $CodexHome "archived_sessions"); Kind = "archived" }
    )

    foreach ($root in $sessionRoots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $root.Path -Recurse -Force -File -Filter "*.jsonl" -ErrorAction SilentlyContinue)) {
            $metadata = $null
            foreach ($lineObject in (Read-JsonlObjects -Path $file.FullName -MaxLines 80)) {
                if ([string]$lineObject.type -eq "session_meta") {
                    $metadata = $lineObject.payload
                    break
                }
            }

            $threadId = if ($metadata -and $metadata.id) { [string]$metadata.id } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
            $threadName = ""
            if ($ThreadNamesById.ContainsKey($threadId)) {
                $threadName = [string]$ThreadNamesById[$threadId]
            }

            $cwd = if ($metadata -and $metadata.cwd) { [string]$metadata.cwd } else { "" }
            $entries.Add([pscustomobject]@{
                id               = $threadId
                parent_thread_id = if ($metadata -and $metadata.parent_thread_id) { [string]$metadata.parent_thread_id } else { "" }
                thread_name      = $threadName
                kind             = [string]$root.Kind
                thread_source    = if ($metadata -and $metadata.thread_source) { [string]$metadata.thread_source } else { "" }
                agent_nickname   = if ($metadata -and $metadata.agent_nickname) { [string]$metadata.agent_nickname } else { "" }
                agent_role       = if ($metadata -and $metadata.agent_role) { [string]$metadata.agent_role } else { "" }
                cwd              = $cwd
                cwd_portable     = Get-PortableRestorePath -Path $cwd
                file_path        = $file.FullName
                file_portable    = Get-PortableRestorePath -Path $file.FullName
                size_bytes       = [int64]$file.Length
                created_at       = if ($metadata -and $metadata.timestamp) { [string]$metadata.timestamp } else { $file.CreationTimeUtc.ToString("o") }
                updated_at       = $file.LastWriteTimeUtc.ToString("o")
            }) | Out-Null
        }
    }

    return @($entries | Sort-Object updated_at -Descending)
}

function Get-CodexOutputIndex {
    param(
        [string]$CodexDocumentsRoot,
        [int]$MaxFiles = 2000
    )

    $directories = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $CodexDocumentsRoot -PathType Container)) {
        return [pscustomobject]@{
            directories = @()
            files       = @()
        }
    }

    $outputDirs = @(Get-ChildItem -LiteralPath $CodexDocumentsRoot -Recurse -Force -Directory -Filter "outputs" -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($dir in $outputDirs) {
        $dirFiles = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)
        $totalBytes = [int64]0
        foreach ($dirFile in $dirFiles) {
            $totalBytes += [int64]$dirFile.Length
        }

        $directories.Add([pscustomobject]@{
            path        = $dir.FullName
            portable    = Get-PortableRestorePath -Path $dir.FullName
            file_count  = $dirFiles.Count
            total_bytes = $totalBytes
            updated_at  = $dir.LastWriteTimeUtc.ToString("o")
        }) | Out-Null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $CodexDocumentsRoot -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\outputs\\' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $MaxFiles)) {
        $files.Add([pscustomobject]@{
            name       = $file.Name
            extension  = $file.Extension
            path       = $file.FullName
            portable   = Get-PortableRestorePath -Path $file.FullName
            size_bytes = [int64]$file.Length
            updated_at = $file.LastWriteTimeUtc.ToString("o")
        }) | Out-Null
    }

    return [pscustomobject]@{
        directories = @($directories.ToArray())
        files       = @($files.ToArray())
    }
}

function Get-RepoWorkIndexEntries {
    param([object[]]$Repos)

    $entries = New-Object System.Collections.Generic.List[object]
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue

    foreach ($repo in @($Repos)) {
        $sourcePath = [string]$repo.source_path
        $exists = -not [string]::IsNullOrWhiteSpace($sourcePath) -and (Test-Path -LiteralPath $sourcePath -PathType Container)
        $statusLines = @()
        $dirtyCount = 0
        $branchLine = ""

        if ($exists -and $gitCommand -and (Test-Path -LiteralPath (Join-Path $sourcePath ".git"))) {
            try {
                $statusLines = @(& $gitCommand.Source -C $sourcePath status --short --branch 2>$null)
                if ($statusLines.Count -gt 0) {
                    $branchLine = [string]$statusLines[0]
                    $dirtyCount = @($statusLines | Select-Object -Skip 1).Count
                }
            } catch {
                $statusLines = @()
            }
        }

        $entries.Add([pscustomobject]@{
            name          = [string]$repo.name
            branch        = [string]$repo.branch
            remote_url    = [string]$repo.url
            source_path   = $sourcePath
            portable      = Get-PortableRestorePath -Path $sourcePath
            exists        = [bool]$exists
            git_status    = ConvertTo-IndexText -Text $branchLine -MaxLength 220
            dirty_count   = [int]$dirtyCount
            status_sample = @($statusLines | Select-Object -Skip 1 -First 40 | ForEach-Object { ConvertTo-IndexText -Text ([string]$_) -MaxLength 220 })
        }) | Out-Null
    }

    return @($entries | Sort-Object name)
}

function New-CodexWorkIndex {
    param(
        [string]$CodexHome,
        [string]$CodexDocumentsRoot,
        [object[]]$RepoManifestEntries
    )

    $sessionIndexEntries = @(Get-CodexSessionIndexEntries -CodexHome $CodexHome)
    $threadNamesById = @{}
    foreach ($entry in $sessionIndexEntries) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.id)) {
            $threadNamesById[[string]$entry.id] = [string]$entry.thread_name
        }
    }

    $sessionFiles = @(Get-CodexSessionFileEntries -CodexHome $CodexHome -ThreadNamesById $threadNamesById)
    $outputs = Get-CodexOutputIndex -CodexDocumentsRoot $CodexDocumentsRoot
    $repoEntries = @(Get-RepoWorkIndexEntries -Repos $RepoManifestEntries)

    return [pscustomobject]@{
        version       = 1
        generated_at  = (Get-Date).ToString("o")
        source_machine = $env:COMPUTERNAME
        source_user    = $env:USERNAME
        notes          = @(
            "This is an index only. Full Codex state, sessions and repository snapshots are stored elsewhere in the CODEXKIT package.",
            "Chat bodies are not copied into this index to reduce accidental secret exposure."
        )
        counts         = [pscustomobject]@{
            session_titles      = $sessionIndexEntries.Count
            session_files       = $sessionFiles.Count
            output_directories  = @($outputs.directories).Count
            output_files_indexed = @($outputs.files).Count
            repositories        = $repoEntries.Count
            dirty_repositories  = @($repoEntries | Where-Object { $_.dirty_count -gt 0 }).Count
        }
        session_titles = $sessionIndexEntries
        session_files  = $sessionFiles
        outputs        = $outputs
        repositories   = $repoEntries
    }
}

function Write-CodexWorkIndexMarkdown {
    param(
        [object]$Index,
        [string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# CODEXKIT Work Index") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Generated: $($Index.generated_at)") | Out-Null
    $lines.Add("Machine: $($Index.source_machine)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("This file is a searchable map of local Codex work. It indexes chat titles, session files, output artifacts and repository state without copying full chat bodies into the report.") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Area | Count |") | Out-Null
    $lines.Add("|---|---:|") | Out-Null
    $lines.Add("| Chat titles | $($Index.counts.session_titles) |") | Out-Null
    $lines.Add("| Session files | $($Index.counts.session_files) |") | Out-Null
    $lines.Add("| Output folders | $($Index.counts.output_directories) |") | Out-Null
    $lines.Add("| Output files indexed | $($Index.counts.output_files_indexed) |") | Out-Null
    $lines.Add("| Repositories | $($Index.counts.repositories) |") | Out-Null
    $lines.Add("| Repositories with local changes | $($Index.counts.dirty_repositories) |") | Out-Null
    $lines.Add("") | Out-Null

    $lines.Add("## Recent Chats") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Updated | Title | Thread | Workspace |") | Out-Null
    $lines.Add("|---|---|---|---|") | Out-Null
    foreach ($session in @($Index.session_files | Sort-Object updated_at -Descending | Select-Object -First 60)) {
        $title = if ([string]::IsNullOrWhiteSpace([string]$session.thread_name)) { [string]$session.id } else { [string]$session.thread_name }
        $lines.Add("| $(ConvertTo-MarkdownCell $session.updated_at) | $(ConvertTo-MarkdownCell $title) | $(ConvertTo-MarkdownCell $session.id) | $(ConvertTo-MarkdownCell $session.cwd_portable) |") | Out-Null
    }
    $lines.Add("") | Out-Null

    $lines.Add("## Repositories") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Name | Branch | Local changes | Status | Path |") | Out-Null
    $lines.Add("|---|---|---:|---|---|") | Out-Null
    foreach ($repo in @($Index.repositories | Sort-Object @{ Expression = "dirty_count"; Descending = $true }, name | Select-Object -First 120)) {
        $lines.Add("| $(ConvertTo-MarkdownCell $repo.name) | $(ConvertTo-MarkdownCell $repo.branch) | $($repo.dirty_count) | $(ConvertTo-MarkdownCell $repo.git_status) | $(ConvertTo-MarkdownCell $repo.portable) |") | Out-Null
    }
    $lines.Add("") | Out-Null

    $lines.Add("## Recent Output Files") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Updated | File | Size | Path |") | Out-Null
    $lines.Add("|---|---|---:|---|") | Out-Null
    foreach ($file in @($Index.outputs.files | Sort-Object updated_at -Descending | Select-Object -First 120)) {
        $lines.Add("| $(ConvertTo-MarkdownCell $file.updated_at) | $(ConvertTo-MarkdownCell $file.name) | $($file.size_bytes) | $(ConvertTo-MarkdownCell $file.portable) |") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("Full machine-readable index: `codex-work-index.json`.") | Out-Null

    Ensure-Dir -Path (Split-Path -Parent $Path)
    $lines | Set-Content -Path $Path -Encoding UTF8
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
$localAppDataDir = [Environment]::GetFolderPath("LocalApplicationData")
$workspaceRoot = Split-Path -Parent $KitRoot
$stateRoot = Join-Path $KitRoot "state"
$repoSnapshotsRoot = Join-Path $KitRoot "repo-snapshots"
$docsRoot = Join-Path $KitRoot "docs"
$zipPath = Join-Path $KitRoot "codexkit-state.zip"
$transferZipPath = Join-Path $KitRoot "codexkit-transfer.zip"
$secureTransferPath = Join-Path $KitRoot "codexkit-transfer-secure.rar"
$transferPartsRoot = Join-Path $KitRoot "codexkit-transfer-parts"
$manifestPath = Join-Path $KitRoot "state-manifest.json"
$hashesPath = Join-Path $KitRoot "archive-hashes.txt"
$toolVersionsPath = Join-Path $KitRoot "tool-versions.json"
$extensionsPath = Join-Path $KitRoot "vscode-extensions.txt"
$wingetExportPath = Join-Path $KitRoot "winget-packages.json"
$machineInfoPath = Join-Path $KitRoot "machine-info.json"
$environmentInventoryPath = Join-Path $KitRoot "environment-inventory.json"
$workIndexJsonPath = Join-Path $docsRoot "codex-work-index.json"
$workIndexMarkdownPath = Join-Path $docsRoot "codex-work-index.md"
$bootstrapPackagesPath = Join-Path $KitRoot "bootstrap-packages.json"
$repoManifestPath = Join-Path $KitRoot "repo-manifest.json"
$customPathsConfigPath = Join-Path $KitRoot "custom-paths.json"

$manifest = [System.Collections.Generic.List[object]]::new()
$customPathsConfig = Get-OptionalJsonConfig -Path $customPathsConfigPath
$configuredCopyEntries = Get-ConfiguredCopyEntries -Config $customPathsConfig -StateRoot $stateRoot -DocsRoot $docsRoot
$detectedEnvironmentEntries = Get-DetectedEnvironmentEntries -HomeDir $homeDir -AppDataDir $appDataDir -LocalAppDataDir $localAppDataDir -StateRoot $stateRoot
$repoRoots = Get-ConfiguredRepoRoots -Config $customPathsConfig -HomeDir $homeDir -WorkspaceRoot $workspaceRoot

$hasExistingSnapshot = (Test-Path -LiteralPath $stateRoot) -or (Test-Path -LiteralPath $repoSnapshotsRoot)
$effectiveRefreshMode = if ($RefreshMode -eq "Auto") {
    if ($hasExistingSnapshot) { "Incremental" } else { "Full" }
} else {
    $RefreshMode
}
$incrementalRefresh = ($effectiveRefreshMode -eq "Incremental")

Write-Step "Refreshing state folder ($effectiveRefreshMode mode)"
if ($incrementalRefresh) {
    Ensure-Dir -Path $stateRoot
    Ensure-Dir -Path $repoSnapshotsRoot
} else {
    Clear-Dir -Path $stateRoot
    Clear-Dir -Path $repoSnapshotsRoot
}
Ensure-Dir -Path $docsRoot

Write-Step "Writing machine info"
$machineInfo = [pscustomobject]@{
    generated_at   = (Get-Date).ToString("o")
    source_machine = $env:COMPUTERNAME
    source_user    = $env:USERNAME
    source_home    = $homeDir
    refresh_mode   = $effectiveRefreshMode
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

foreach ($entry in $detectedEnvironmentEntries.files) {
    $copyFiles += $entry
}

foreach ($entry in $configuredCopyEntries.files) {
    $copyFiles += $entry
}

foreach ($entry in $copyFiles) {
    $status = if (Copy-FileIfExists -Source $entry.Source -Destination $entry.Destination -Incremental:$incrementalRefresh) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category $entry.Category -Source $entry.Source -Destination $entry.Destination -Status $status
}

foreach ($fileName in $codexPersistentFiles) {
    $source = Join-Path $homeDir ".codex\$fileName"
    $destination = Join-Path $stateRoot "codex\$fileName"
    $status = if (Copy-FileIfExists -Source $source -Destination $destination -Incremental:$incrementalRefresh) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category "codex-history" -Source $source -Destination $destination -Status $status
}

$copyDirs = @(
    @{ Category = "ssh"; Source = (Join-Path $homeDir ".ssh"); Destination = (Join-Path $stateRoot "ssh") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\snippets"); Destination = (Join-Path $stateRoot "vscode\User\snippets") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\profiles"); Destination = (Join-Path $stateRoot "vscode\User\profiles") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\globalStorage"); Destination = (Join-Path $stateRoot "vscode\User\globalStorage") },
    @{ Category = "vscode"; Source = (Join-Path $appDataDir "Code\User\workspaceStorage"); Destination = (Join-Path $stateRoot "vscode\User\workspaceStorage") }
)

foreach ($entry in $detectedEnvironmentEntries.directories) {
    $copyDirs += $entry
}

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
    "output",
    "outputs",
    "target",
    "models",
    "checkpoints",
    "weights",
    "datasets",
    "data",
    "cache",
    ".cache",
    "tmp",
    "temp",
    "input",
    "downloads",
    ".cxx",
    ".externalNativeBuild",
    "__pycache__",
    ".pytest_cache"
)
$repoExcludeFiles = @(
    "local.properties",
    "Thumbs.db",
    "*.img",
    "*.iso",
    "*.apk",
    "*.aab",
    "*.apks",
    "*.obb",
    "*.bin",
    "*.zip",
    "*.7z",
    "*.rar",
    "*.tar",
    "*.gz",
    "*.xz",
    "*.safetensors",
    "*.ckpt",
    "*.pt",
    "*.pth",
    "*.onnx",
    "*.gguf",
    "*.pb",
    "*.tflite",
    "*.h5",
    "*.weights"
)
$repoManifestEntries = @(Get-RepoManifestEntries -RepoManifestPath $repoManifestPath -Roots $repoRoots -ExcludedPathPrefixes @($stateRoot, $repoSnapshotsRoot, $KitRoot))
foreach ($repo in $repoManifestEntries) {
    $sourcePath = $repo.source_path
    $snapshotPath = Join-Path $repoSnapshotsRoot $repo.name
    $status = if (Copy-DirWithExclusions -Source $sourcePath -Destination $snapshotPath -ExcludeDirs $repoExcludeDirs -ExcludeFiles $repoExcludeFiles) { "copied" } else { "missing" }
    Add-ManifestEntry -Manifest $manifest -Category "repo-snapshot" -Source $sourcePath -Destination $snapshotPath -Status $status
}

Write-Step "Writing Codex work index"
$codexWorkIndex = New-CodexWorkIndex -CodexHome (Join-Path $homeDir ".codex") -CodexDocumentsRoot (Join-Path $homeDir "Documents\Codex") -RepoManifestEntries $repoManifestEntries
$codexWorkIndex | ConvertTo-Json -Depth 10 | Set-Content -Path $workIndexJsonPath -Encoding UTF8
Write-CodexWorkIndexMarkdown -Index $codexWorkIndex -Path $workIndexMarkdownPath

Write-Step "Writing environment inventory"
$environmentInventory = [pscustomobject]@{
    generated_at          = (Get-Date).ToString("o")
    source_machine        = $env:COMPUTERNAME
    source_user           = $env:USERNAME
    requested_refresh_mode = $RefreshMode
    refresh_mode          = $effectiveRefreshMode
    repo_search_roots     = @($repoRoots)
    repos_detected        = @($repoManifestEntries).Count
    auto_files_detected   = @($detectedEnvironmentEntries.files).Count
    auto_dirs_detected    = @($detectedEnvironmentEntries.directories).Count
    work_index            = [pscustomobject]@{
        markdown = $workIndexMarkdownPath
        json     = $workIndexJsonPath
        counts   = $codexWorkIndex.counts
    }
    copied_items          = @($manifest | Where-Object { $_.status -eq "copied" } | Select-Object category, source, destination, restore_destination)
    missing_items         = @($manifest | Where-Object { $_.status -eq "missing" } | Select-Object category, source, destination, restore_destination)
}
$environmentInventory | ConvertTo-Json -Depth 6 | Set-Content -Path $environmentInventoryPath -Encoding UTF8

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

Write-Step "Capturing winget package snapshot"
$wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetCommand) {
    & $wingetCommand.Source export --output $wingetExportPath --accept-source-agreements --disable-interactivity 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "winget export reported a non-zero exit code: $LASTEXITCODE"
        if (-not (Test-Path -LiteralPath $wingetExportPath)) {
            Set-Content -Path $wingetExportPath -Value "[]" -Encoding UTF8
        }
    }
} else {
    Set-Content -Path $wingetExportPath -Value "[]" -Encoding UTF8
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
$splitPartTargetBytes = [int64]1879048192
$stateRootEstimatedBytes = Get-PathTotalBytes -Path $stateRoot
$stateZipSkippedForSplit = $false
if ($stateRootEstimatedBytes -gt $splitPartTargetBytes) {
    $stateZipSkippedForSplit = $true
    $effectiveStateZipPath = $null
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    Write-Warning "Skipping codexkit-state.zip because the state folder is large. Split transfer parts will include the state folder directly."
} else {
    Compress-Archive -Path $stateRoot -DestinationPath $zipBuildPath -Force
}

Write-Step "Creating transfer archive"
if (-not $stateZipSkippedForSplit -and (Test-Path -LiteralPath $zipPath)) {
    try {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $zipBuildPath -Destination $zipPath -Force
    } catch {
        $effectiveStateZipPath = $zipBuildPath
        Write-Warning "Could not replace existing codexkit-state.zip because it is locked. Using $effectiveStateZipPath for this run."
    }
} elseif (-not $stateZipSkippedForSplit) {
    Move-Item -LiteralPath $zipBuildPath -Destination $zipPath -Force
}

$effectiveTransferZipPath = $transferZipPath
$transferPartPaths = @()
$transferArchiveSplit = $false
$transferZipBuildPath = Join-Path $KitRoot "codexkit-transfer.__new.zip"
if (Test-Path -LiteralPath $transferZipBuildPath) {
    Remove-Item -LiteralPath $transferZipBuildPath -Force -ErrorAction SilentlyContinue
}
$transferItems = @(
    (Join-Path $KitRoot "1-BEFORE-MOVE.bat"),
    (Join-Path $KitRoot "2-RESTORE-HERE.bat"),
    (Join-Path $KitRoot "README.md"),
    (Join-Path $KitRoot "refresh-codexkit.ps1"),
    (Join-Path $KitRoot "restore-codexkit.ps1"),
    (Join-Path $KitRoot "verify-codexkit.ps1"),
    $bootstrapPackagesPath,
    $customPathsConfigPath,
    $repoManifestPath,
    $wingetExportPath,
    $toolVersionsPath,
    $extensionsPath,
    $hashesPath,
    $manifestPath,
    $machineInfoPath,
    $environmentInventoryPath,
    $docsRoot,
    $repoSnapshotsRoot,
    $(if ($effectiveStateZipPath) { $effectiveStateZipPath } else { $stateRoot })
) | Where-Object { Test-Path -LiteralPath $_ }
$transferItemsEstimatedBytes = [int64]0
foreach ($item in $transferItems) {
    $transferItemsEstimatedBytes += Get-PathTotalBytes -Path $item
}

if ($transferItemsEstimatedBytes -gt $splitPartTargetBytes) {
    $transferArchiveSplit = $true
    $effectiveTransferZipPath = $null
    if (Test-Path -LiteralPath $transferZipPath) {
        Remove-Item -LiteralPath $transferZipPath -Force -ErrorAction SilentlyContinue
    }
    Write-Step "Creating split transfer archives"
    $transferPartPaths = @(New-SplitTransferArchives -Items $transferItems -BaseRoot $KitRoot -PartsRoot $transferPartsRoot -PartTargetBytes $splitPartTargetBytes)
} else {
    if (Test-Path -LiteralPath $transferPartsRoot) {
        Remove-Item -LiteralPath $transferPartsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    if (Test-Path -LiteralPath $winRarPath) {
        Write-Step "Creating password-protected transfer archive"
        Get-ChildItem -LiteralPath $KitRoot -Filter "codexkit-transfer-secure*.rar" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $rarArgs = @("a", "-r", "-v3800m", "-hp$ArchivePassword", $secureTransferPath) + @($transferItems)
        & $winRarPath @rarArgs | Out-Null
    } else {
        if ($transferArchiveSplit) {
            Write-Warning "Archive password was provided, but WinRAR was not found. Split ZIP parts were created without password protection."
        } else {
            Write-Warning "Archive password was provided, but WinRAR was not found. Skipping secure archive."
        }
    }
}

Write-Step "Writing archive hashes"
$hashLines = New-Object System.Collections.Generic.List[string]
if ($effectiveStateZipPath -and (Test-Path -LiteralPath $effectiveStateZipPath)) {
    $zipHash = Get-FileSha256 -Path $effectiveStateZipPath
    $hashLines.Add("$([System.IO.Path]::GetFileName($effectiveStateZipPath)) SHA256 $zipHash") | Out-Null
}
if ($effectiveTransferZipPath -and (Test-Path -LiteralPath $effectiveTransferZipPath)) {
    $transferZipHash = Get-FileSha256 -Path $effectiveTransferZipPath
    $hashLines.Add("$([System.IO.Path]::GetFileName($effectiveTransferZipPath)) SHA256 $transferZipHash") | Out-Null
} elseif ($transferArchiveSplit) {
    $hashLines.Add("codexkit-transfer.zip SPLIT_INTO_PARTS") | Out-Null
    foreach ($partPath in $transferPartPaths) {
        if (Test-Path -LiteralPath $partPath) {
            $partHash = Get-FileSha256 -Path $partPath
            $hashLines.Add("codexkit-transfer-parts/$([System.IO.Path]::GetFileName($partPath)) SHA256 $partHash") | Out-Null
        }
    }
}
if ($stateZipSkippedForSplit) {
    $hashLines.Add("codexkit-state.zip SKIPPED_SPLIT_TRANSFER_INCLUDES_STATE_FOLDER") | Out-Null
}
foreach ($securePart in @(Get-ChildItem -LiteralPath $KitRoot -Filter "codexkit-transfer-secure*.rar" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $rarHash = Get-FileSha256 -Path $securePart.FullName
    $hashLines.Add("$($securePart.Name) SHA256 $rarHash") | Out-Null
}
$hashLines | Set-Content -Path $hashesPath -Encoding UTF8

Write-Step "CODEXKIT refresh complete"
