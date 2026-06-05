<#
.SYNOPSIS
    Publishes the JW Swarm Node tray app and builds the MSI installer.

.DESCRIPTION
    Must run on Windows with the .NET 8 SDK and WiX Toolset v5
    (dotnet tool install --global wix) available. Produces:
      packaging/bin/JwSwarmNode.msi

.EXAMPLE
    pwsh ./build-msi.ps1
#>
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$publishDir = Join-Path $PSScriptRoot "publish"
$appProject = Join-Path $root "src/JwSwarmNode.App/JwSwarmNode.App.csproj"

Write-Host "==> Publishing tray app ($Configuration / $Runtime)"
if (Test-Path $publishDir) { Remove-Item -Recurse -Force $publishDir }
dotnet publish $appProject `
    -c $Configuration `
    -r $Runtime `
    --self-contained false `
    -p:PublishSingleFile=false `
    -o $publishDir

Write-Host "==> Building MSI with WiX"
$wixproj = Join-Path $PSScriptRoot "JwSwarmNode.Installer.wixproj"
dotnet build $wixproj `
    -c $Configuration `
    -p:PublishDir=$publishDir `
    -p:BindPath=$publishDir

Write-Host "==> Done. MSI under packaging/bin/$Configuration"
