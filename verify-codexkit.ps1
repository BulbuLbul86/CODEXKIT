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

$codexHistoryChecks = @(
    @{ Name = "сессии Codex"; Path = (Join-Path $HOME ".codex\sessions") },
    @{ Name = "архив Codex"; Path = (Join-Path $HOME ".codex\archived_sessions") },
    @{ Name = "история Codex"; Path = (Join-Path $HOME ".codex\history.jsonl") },
    @{ Name = "память Codex"; Path = (Join-Path $HOME ".codex\memories_1.sqlite") },
    @{ Name = "состояние Codex"; Path = (Join-Path $HOME ".codex\state_5.sqlite") },
    @{ Name = "индекс сессий Codex"; Path = (Join-Path $HOME ".codex\session_index.jsonl") }
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
        return @{}
    }

    return $repoMap
}

$results = New-Object System.Collections.Generic.List[object]
$repoLocationStatePath = Join-Path (Join-Path $HOME ".codexkit") "repo-locations.json"
$repoLocationState = Get-RepoLocationState -Path $repoLocationStatePath

foreach ($commandName in @("git", "code", "codex", "python", "java", "javac", "adb", "node", "npm", "pnpm")) {
    $results.Add((Test-CommandPresence -Name $commandName)) | Out-Null
}

$fileChecks = @(
    @{ Name = ".gitconfig"; Path = (Join-Path $HOME ".gitconfig") },
    @{ Name = ".ssh"; Path = (Join-Path $HOME ".ssh\mikrotik_shutdown_ed25519") },
    @{ Name = "ключ adb"; Path = (Join-Path $HOME ".android\adbkey") },
    @{ Name = "авторизация Codex"; Path = (Join-Path $HOME ".codex\auth.json") },
    @{ Name = "настройки VS Code"; Path = (Join-Path $env:APPDATA "Code\User\settings.json") },
    @{ Name = "личные VPN-файлы"; Path = (Join-Path $PrivateRestoreRoot "vpn") },
    @{ Name = "ключи подписи Android"; Path = (Join-Path $PrivateRestoreRoot "android-signing") }
)

foreach ($check in $fileChecks) {
    $ok = Test-Path -LiteralPath $check.Path
    $results.Add((Get-CheckResult -Name $check.Name -Ok $ok -Details $check.Path)) | Out-Null
}

foreach ($check in $codexHistoryChecks) {
    $ok = Test-Path -LiteralPath $check.Path
    $results.Add((Get-CheckResult -Name $check.Name -Ok $ok -Details $check.Path)) | Out-Null
}

$repoManifestPath = Join-Path (Split-Path -Parent $PSCommandPath) "repo-manifest.json"
if (Test-Path -LiteralPath $repoManifestPath) {
    $repos = Get-Content -LiteralPath $repoManifestPath -Raw | ConvertFrom-Json
    foreach ($repo in $repos) {
        if ($repoLocationState.ContainsKey($repo.name)) {
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
