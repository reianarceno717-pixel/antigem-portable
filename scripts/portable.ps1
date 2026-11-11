# AntiGem Portable - Windows entry point (PowerShell)
# Same technique as scripts/portable.sh: bootstrap -> verify -> isolate -> menu
$ErrorActionPreference = "Stop"

$AppName = "AntiGem Portable"
$Version = "0.1.0"
$Root    = Split-Path -Parent $PSScriptRoot
$Data    = Join-Path $Root "data"
$Runtimes= Join-Path $Root "runtimes"
$Packages= Join-Path $Root "packages"
$NodePin = "v22.14.0"
$NodeMin = 20

switch ($env:PROCESSOR_ARCHITECTURE) {
  "AMD64" { $Target = "windows-x64";   $NodePlat = "win-x64" }
  "ARM64" { $Target = "windows-arm64"; $NodePlat = "win-arm64" }
  default { Write-Host "Unsupported CPU: $env:PROCESSOR_ARCHITECTURE" -ForegroundColor Red; exit 1 }
}

function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Info ($m) { Write-Host $m -ForegroundColor Cyan }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }

$HostHome   = $env:USERPROFILE
$HostNode   = (Get-Command node -ErrorAction SilentlyContinue)
$Engines    = @{}
foreach ($e in @("claude","codex","agy","opencode")) {
  $c = Get-Command $e -ErrorAction SilentlyContinue
  if ($c) { $Engines[$e] = $c.Source }
}

New-Item -ItemType Directory -Force -Path $Data,$Runtimes,$Packages | Out-Null

function Get-PortableNode {
  $cand = Join-Path $Runtimes "$Target\node\node.exe"
  if (Test-Path $cand) { return $cand }
  if ($HostNode) { return $HostNode.Source }
  return $null
}

function Install-PortableNode {
  $file = "node-$NodePin-$NodePlat.zip"
  $url  = "https://nodejs.org/dist/$NodePin/$file"
  $dst  = Join-Path $Packages $file
  Write-Info "Downloading portable Node $NodePin for $Target..."
  Invoke-WebRequest -Uri $url -OutFile $dst
  Write-Info "Verifying checksum..."
  $sums = Join-Path $Packages "SHASUMS256.txt"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/$NodePin/SHASUMS256.txt" -OutFile $sums
  $want = (Select-String -Path $sums -Pattern ([regex]::Escape($file)) | Select-Object -First 1).Line.Split(" ")[0]
  $got  = (Get-FileHash -Algorithm SHA256 $dst).Hash.ToLower()
  if (-not $want) { throw "checksum for $file not found" }
  if ($want -ne $got) { throw "checksum mismatch for $file" }
  $tmp = Join-Path $Runtimes ".tmp"
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Expand-Archive -Path $dst -DestinationPath $tmp -Force
  $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
  $dest  = Join-Path $Runtimes "$Target\node"
  Remove-Item -Recurse -Force $dest -ErrorAction SilentlyContinue
  Move-Item $inner.FullName $dest
  Remove-Item -Recurse -Force $tmp, $dst, $sums -ErrorAction SilentlyContinue
  Write-Ok "Portable Node ready."
  return (Join-Path $dest "node.exe")
}

$Node = Get-PortableNode
if (-not $Node) { $Node = Install-PortableNode }

# --- isolate HOME -----------------------------------------------------------
$PortableHome = Join-Path $Data "home"
$PortableTmp  = Join-Path $Data "tmp"
New-Item -ItemType Directory -Force -Path $PortableHome,$PortableTmp | Out-Null
$env:USERPROFILE = $PortableHome
$env:HOME        = $PortableHome
$env:XDG_CONFIG_HOME = Join-Path $PortableHome ".config"
$env:XDG_DATA_HOME   = Join-Path $PortableHome ".local\share"
$env:TMP = $PortableTmp
$env:TEMP = $PortableTmp
$env:PATH = (Split-Path $Node) + ";" + $env:PATH
$env:ANTIGEM_PORTABLE = "1"

# --- config -----------------------------------------------------------------
$Cfg = Join-Path $Data "config.env"
if (-not (Test-Path $Cfg)) {
  @(
    "# AntiGem Portable - edit freely"
    "ANTIGEM_AGENT=claude"
    "ANTIGEM_MODEL="
  ) | Set-Content -Encoding ASCII $Cfg
}

$Workspace = Join-Path $Data "workspace"
New-Item -ItemType Directory -Force -Path $Workspace | Out-Null

function Show-Doctor {
  Write-Host ""
  Write-Host "$AppName $Version" -ForegroundColor White
  Write-Host "root      $Root"
  Write-Host "platform  $Target ($env:PROCESSOR_ARCHITECTURE)"
  Write-Host "node      $Node ($(& $Node -v 2>$null))"
  Write-Host "home      $env:USERPROFILE"
  Write-Host "workspace $Workspace"
  Write-Host ""
  Write-Host "engines" -ForegroundColor White
  foreach ($e in @("claude","codex","agy","opencode")) {
    $p = $Engines[$e]
    if ($p) { Write-Host ("  {0,-9} ready     {1}" -f $e, $p) }
    else    { Write-Host ("  {0,-9} missing" -f $e) -ForegroundColor DarkGray }
  }
  $free = (Get-PSDrive -Name ([IO.Path]::GetPathRoot($Root).TrimEnd(':'))).Free / 1GB
  Write-Host ""
  Write-Host ("free      {0:N1} GB" -f $free)
  Write-Host ("creds     {0} file(s) in data\home" -f (Get-ChildItem $PortableHome -Recurse -File -ErrorAction SilentlyContinue).Count)
  Write-Host ""
}

function Start-Agent ($name) {
  $bin = $Engines[$name]
  if (-not $bin) { Write-Warn "engine '$name' not found. Install it or run --doctor"; return }
  Write-Info "Starting $name  -  workspace: $Workspace"
  Push-Location $Workspace
  try { & $bin } finally { Pop-Location }
}

function Import-Creds {
  $map = @(
    @(".claude.json", ".claude.json"),
    @(".claude\settings.json", ".claude\settings.json"),
    @(".codex\config.toml", ".codex\config.toml"),
    @(".codex\auth.json", ".codex\auth.json"),
    @(".gemini\oauth_creds.json", ".gemini\oauth_creds.json"),
    @(".config\opencode\opencode.json", ".config\opencode\opencode.json")
  )
  $n = 0
  foreach ($pair in $map) {
    $src = Join-Path $HostHome $pair[0]
    $dst = Join-Path $PortableHome $pair[1]
    if (Test-Path $src) {
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      Copy-Item $src $dst -Force
      Write-Host "  copied $($pair[0])"
      $n++
    }
  }
  Write-Ok "Imported $n file(s). Credentials are copied, not moved."
}

function Show-Menu {
  Write-Host ""
  Write-Host "$AppName $Version" -ForegroundColor White
  while ($true) {
    Write-Host "1) Workspace - start an agent      4) Import host credentials"
    Write-Host "2) Doctor    - environment report  5) Update portable Node"
    Write-Host "3) Terminal  - portable shell      6) Quit"
    $c = Read-Host "choice"
    switch ($c) {
      "1" { $a = Read-Host "agent [claude/codex/agy/opencode] (claude)"; if (-not $a) { $a = "claude" }; Start-Agent $a }
      "2" { Show-Doctor }
      "3" { Push-Location $Workspace; try { & $env:COMSPEC } finally { Pop-Location } }
      "4" { Import-Creds }
      "5" { $Node = Install-PortableNode }
      "6" { return }
      default { Write-Warn "unknown choice: $c" }
    }
    Write-Host ""
  }
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { "--menu" }
switch ($cmd) {
  "--doctor" { Show-Doctor }
  "--list"   { foreach ($e in $Engines.Keys) { Write-Host "$e`t$($Engines[$e])" } }
  "--agent"  { Start-Agent $(if ($args.Count -gt 1) { $args[1] } else { "claude" }) }
  "--exec"   { Push-Location $Workspace; try { & $env:COMSPEC /c $args[1] } finally { Pop-Location } }
  "--import" { Import-Creds }
  "--update" { $Node = Install-PortableNode }
  "--help"   { Write-Host "usage: windows.bat [--menu|--doctor|--list|--agent NAME|--exec CMD|--import|--update]" }
  default    { Show-Menu }
}
