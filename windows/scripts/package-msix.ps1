# Le paquet MSIX du Microsoft Store, à partir de l'exécutable de `tauri build`.
#
# Le Store signe lui-même le paquet après certification : on l'envoie non signé.
# L'identité (Name, Publisher) vient de Partner Center › Identité du produit ;
# tant que le compte n'existe pas, des valeurs provisoires permettent de
# construire et d'essayer le paquet (installation « déroulée », voir plus bas).
#
#   pwsh windows/scripts/package-msix.ps1 [-IdentityName …] [-Publisher "CN=…"] [-PublisherDisplayName …]
#
# Sortie : windows/src-tauri/target/release/bundle/msix/Polymestre_<version>_x64.msix
# et, à côté, le dossier `layout/` (essai sans signature : Mode développeur, puis
# `Add-AppxPackage -Register layout\AppxManifest.xml`).

param(
  [string]$IdentityName = $(if ($env:MSSTORE_IDENTITY_NAME) { $env:MSSTORE_IDENTITY_NAME } else { "StudyTrack.Preview" }),
  [string]$Publisher = $(if ($env:MSSTORE_PUBLISHER) { $env:MSSTORE_PUBLISHER } else { "CN=StudyTrackPreview" }),
  [string]$PublisherDisplayName = $(if ($env:MSSTORE_PUBLISHER_DISPLAY_NAME) { $env:MSSTORE_PUBLISHER_DISPLAY_NAME } else { "Hugo Chazarain" })
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot            # windows/
$tauri = Join-Path $root "src-tauri"
$release = Join-Path $tauri "target/release"
$out = Join-Path $release "bundle/msix"
$layout = Join-Path $out "layout"

# La version du Store a quatre nombres, le dernier à zéro (réservé au Store).
$config = Get-Content (Join-Path $tauri "tauri.conf.json") -Raw | ConvertFrom-Json
if ($config.version -notmatch '^\d+\.\d+\.\d+$') { throw "Version Tauri inattendue : $($config.version)" }
$version = "$($config.version).0"

# L'exécutable : le binaire Cargo (`studytrack.exe`) ; le nom du produit en secours.
$exe = @("Polymestre.exe", "polymestre.exe", "studytrack.exe", "StudyTrack.exe") | ForEach-Object { Join-Path $release $_ } |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw "Pas d'exécutable dans $release : lancer d'abord « npm run tauri build »." }

# MakeAppx du SDK Windows le plus récent installé.
$kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
$makeappx = Get-ChildItem $kits -Directory -Filter "10.*" | Sort-Object { [version]$_.Name } -Descending |
  ForEach-Object { Join-Path $_.FullName "x64\makeappx.exe" } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makeappx) { throw "makeappx.exe introuvable sous $kits (SDK Windows 10/11 requis)." }

Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $layout "Assets") | Out-Null
Copy-Item $exe (Join-Path $layout "Polymestre.exe")

# Les tuiles : celles que `tauri icon` a tirées de l'icône de l'app (la même que le Mac).
foreach ($name in "Square44x44Logo.png", "Square71x71Logo.png", "Square150x150Logo.png", "StoreLogo.png") {
  Copy-Item (Join-Path $tauri "icons/$name") (Join-Path $layout "Assets/$name")
}

# Échappe une valeur pour un attribut XML (un éditeur « Chazarain & co » ne casse rien).
function Esc([string]$value) { [System.Security.SecurityElement]::Escape($value) }

@"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap rescap">
  <Identity Name="$(Esc $IdentityName)" Publisher="$(Esc $Publisher)" Version="$version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>Polymestre</DisplayName>
    <PublisherDisplayName>$(Esc $PublisherDisplayName)</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <!-- Windows 10 1809 et après : WebView2 y est (ou s'y installe) ; Windows 11 l'a toujours. -->
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="fr-CH" />
  </Resources>
  <Applications>
    <!-- Une app Win32 « entière » (Tauri) : FullTrustApplication + runFullTrust. -->
    <Application Id="StudyTrack" Executable="Polymestre.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements
        DisplayName="Polymestre"
        Description="Ton semestre, tes séries et ton temps d'étude."
        BackgroundColor="transparent"
        Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png">
        <uap:DefaultTile Square71x71Logo="Assets\Square71x71Logo.png" />
      </uap:VisualElements>
    </Application>
  </Applications>
  <Capabilities>
    <Capability Name="internetClient" />
    <rescap:Capability Name="runFullTrust" />
  </Capabilities>
</Package>
"@ | Set-Content -Path (Join-Path $layout "AppxManifest.xml") -Encoding utf8

$msix = Join-Path $out "Polymestre_$($config.version)_x64.msix"
& $makeappx pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "makeappx a échoué ($LASTEXITCODE)." }
Write-Host "MSIX : $msix (identité $IdentityName, éditeur $Publisher, version $version)"
