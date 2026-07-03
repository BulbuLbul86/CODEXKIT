param(
    [string]$WorkspaceRoot = "",
    [string]$PrivateRestoreRoot = (Join-Path $HOME "Documents\TravelRestore")
)

$ErrorActionPreference = "Stop"

function Get-CheckResult {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Details
    )

    [pscustomobject]@{
        Проверка = $Name
        Статус   = if ($Ok) { "ОК" } else { "НЕТ" }
        Детали   = $Details
    }
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

function Expand-PortablePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $expanded = [string]$Path
    $expanded = $expanded.Replace("%USERPROFILE%", $HOME)
    $expanded = $expanded.Replace("%APPDATA%", [Environment]::GetFolderPath("ApplicationData"))
    $expanded = $expanded.Replace("%LOCALAPPDATA%", [Environment]::GetFolderPath("LocalApplicationData"))
    $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
    return $expanded
}

function Test-CommandPresence {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return Get-CheckResult -Name $Name -Ok $true -Details $command.Source
    }

    return Get-CheckResult -Name $Name -Ok $false -Details "Не найдено в PATH"
}

function Get-DefaultWorkspaceRoot {
    return (Join-Path $HOME "Documents\Codex\restored-workspace")
}

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
        return @{}
    }

    return $repoMap
}

function Get-RepoStateKey {
    param([pscustomobject]$Repo)

    if (($Repo.PSObject.Properties.Name -contains "snapshot_id") -and -not [string]::IsNullOrWhiteSpace([string]$Repo.snapshot_id)) {
        return [string]$Repo.snapshot_id
    }

    return [string]$Repo.name
}

function Get-ManifestRestoreDestination {
    param([pscustomobject]$Entry)

    if (($Entry.PSObject.Properties.Name -contains "restore_destination") -and -not [string]::IsNullOrWhiteSpace([string]$Entry.restore_destination)) {
        return Expand-PortablePath -Path ([string]$Entry.restore_destination)
    }

    return $null
}

$results = New-Object System.Collections.Generic.List[object]
$kitRoot = Split-Path -Parent $PSCommandPath
$stateManifestPath = Join-Path $kitRoot "state-manifest.json"
$repoManifestPath = Join-Path $kitRoot "repo-manifest.json"
$repoLocationStatePath = Join-Path (Join-Path $HOME ".codexkit") "repo-locations.json"
$repoLocationState = Get-RepoLocationState -Path $repoLocationStatePath

foreach ($commandName in @("git", "code", "codex", "python", "java", "javac", "adb", "node", "npm", "pnpm")) {
    $results.Add((Test-CommandPresence -Name $commandName)) | Out-Null
}

if (Test-Path -LiteralPath $stateManifestPath) {
    $entries = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $stateManifestPath -Raw | ConvertFrom-Json) |
        Where-Object {
            $_.status -eq "copied" -and
            ($_.category -notin @("repo-snapshot")) -and
            -not ([string]$_.category).StartsWith("custom-")
        })

    foreach ($entry in $entries) {
        $destination = Get-ManifestRestoreDestination -Entry $entry
        if ([string]::IsNullOrWhiteSpace($destination)) {
            continue
        }

        $ok = Test-Path -LiteralPath $destination
        $results.Add((Get-CheckResult -Name $entry.category -Ok $ok -Details $destination)) | Out-Null
    }
} else {
    $fallbackChecks = @(
        @{ Name = ".gitconfig"; Path = (Join-Path $HOME ".gitconfig") },
        @{ Name = ".ssh"; Path = (Join-Path $HOME ".ssh") },
        @{ Name = "настройки VS Code"; Path = (Join-Path $env:APPDATA "Code\User\settings.json") },
        @{ Name = "личные VPN-файлы"; Path = (Join-Path $PrivateRestoreRoot "vpn") },
        @{ Name = "ключи подписи Android"; Path = (Join-Path $PrivateRestoreRoot "android-signing") }
    )

    foreach ($check in $fallbackChecks) {
        $ok = Test-Path -LiteralPath $check.Path
        $results.Add((Get-CheckResult -Name $check.Name -Ok $ok -Details $check.Path)) | Out-Null
    }
}

if (Test-Path -LiteralPath $repoManifestPath) {
    $repos = @(ConvertTo-FlatObjectArray -Value (Get-Content -LiteralPath $repoManifestPath -Raw | ConvertFrom-Json))
    foreach ($repo in $repos) {
        $repoKey = Get-RepoStateKey -Repo $repo
        if ($repoLocationState.ContainsKey($repoKey)) {
            $repoPath = $repoLocationState[$repoKey]
        } elseif ($repoLocationState.ContainsKey($repo.name)) {
            $repoPath = $repoLocationState[$repo.name]
        } elseif (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
            $repoPath = Join-Path $WorkspaceRoot $repo.name
        } else {
            $repoPath = Join-Path (Get-DefaultWorkspaceRoot) $repo.name
        }

        $ok = Test-Path -LiteralPath (Join-Path $repoPath ".git")
        $results.Add((Get-CheckResult -Name "repo:$($repo.name)" -Ok $ok -Details $repoPath)) | Out-Null
    }
}

$results | Format-Table -AutoSize

if ($results.Статус -contains "НЕТ") {
    exit 1
}
