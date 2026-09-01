[CmdletBinding()]
param(
    [int[]] $Years = @(2019, 2020, 2021, 2022, 2023),
    [string] $OutputDirectory = 'Override',
    [string] $MsBuildPath,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-MSBuild {
    param([string] $ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "MSBuild was not found at '$ExplicitPath'."
        }

        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }

    $msbuildCommand = Get-Command 'MSBuild.exe' -ErrorAction SilentlyContinue
    if ($msbuildCommand) {
        return $msbuildCommand.Source
    }

    $vswherePaths = @()
    $vswhereCommand = Get-Command 'vswhere.exe' -ErrorAction SilentlyContinue
    if ($vswhereCommand) {
        $vswherePaths += $vswhereCommand.Source
    }

    if (${env:ProgramFiles(x86)}) {
        $vswherePaths += Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    }

    foreach ($vswherePath in $vswherePaths | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) {
            continue
        }

        $foundPaths = @(
            & $vswherePath `
                -latest `
                -products '*' `
                -requires Microsoft.Component.MSBuild `
                -find 'MSBuild\**\Bin\MSBuild.exe'
        )

        foreach ($foundPath in $foundPaths) {
            if ($foundPath -and (Test-Path -LiteralPath $foundPath -PathType Leaf)) {
                return (Resolve-Path -LiteralPath $foundPath).Path
            }
        }
    }

    throw 'MSBuild was not found. Install Visual Studio Build Tools or pass -MsBuildPath.'
}

function Invoke-Git {
    param([string[]] $Arguments)

    & git -C $script:RepoRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}

function Test-GitRef {
    param([string] $Ref)

    & git -C $script:RepoRoot show-ref --verify --quiet $Ref
    return $LASTEXITCODE -eq 0
}

function Resolve-BuildRef {
    param([string] $Branch)

    $ref = "refs/remotes/origin/$Branch"
    if (Test-GitRef -Ref $ref) {
        return "origin/$Branch"
    }

    throw "Branch '$Branch' was not found at origin."
}

try {
if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
    throw 'Git was not found in PATH.'
}

$script:RepoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or -not $script:RepoRoot) {
    throw "'$PSScriptRoot' is not inside a Git repository."
}

$trackedChanges = @(& git -C $script:RepoRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the Git working tree status.'
}

if ($trackedChanges.Count -gt 0) {
    throw 'The Git working tree has tracked changes. Commit or stash them before running this script.'
}

$originalBranch = [string] (& git -C $script:RepoRoot branch --show-current)
$originalBranch = $originalBranch.Trim()
$originalCommit = (& git -C $script:RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $originalCommit) {
    throw 'Could not determine the current Git revision.'
}

Write-Host 'Fetching the latest branches from origin...'
Invoke-Git -Arguments @('fetch', '--prune', 'origin')

$resolvedMsBuildPath = Find-MSBuild -ExplicitPath $MsBuildPath
$projectRelativePath = 'Source\Revit.IFC.Export\Revit.IFC.Export.csproj'
$assemblyName = 'Revit.IFC.Export.dll'

if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    $outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    $outputRoot = [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $OutputDirectory))
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("revit-ifc-build-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
$restoreError = $null

try {
    foreach ($year in $Years) {
        $branch = 'fix/release-{0:D2}.x.x' -f ($year % 100)
        $platform = if ($year -ge 2023) { 'x64' } else { 'AnyCPU' }
        $actualRef = $branch

        Write-Host "[$year] Resolving branch '$branch'..."

        try {
            if ($year -lt 2000 -or $year -gt 2099) {
                throw "Unsupported year '$year'. Expected a value from 2000 through 2099."
            }

            $actualRef = Resolve-BuildRef -Branch $branch
            Invoke-Git -Arguments @('switch', '--quiet', '--detach', $actualRef)

            $projectPath = Join-Path $script:RepoRoot $projectRelativePath
            if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
                throw "Project '$projectRelativePath' does not exist on '$actualRef'."
            }

            $buildOutput = Join-Path $temporaryRoot $year
            New-Item -ItemType Directory -Path $buildOutput | Out-Null
            $buildOutputProperty = [System.IO.Path]::GetFullPath($buildOutput) + [System.IO.Path]::DirectorySeparatorChar

            Write-Host "[$year] Building Revit.IFC.Export (Release|$platform)..."

            $msbuildArguments = @(
                $projectPath,
                '/restore',
                '/t:Rebuild',
                '/m',
                '/nologo',
                '/verbosity:minimal',
                '/p:Configuration=Release',
                "/p:Platform=$platform",
                "/p:OutputPath=$buildOutputProperty",
                '/p:PostBuildEvent='
            )

            & $resolvedMsBuildPath @msbuildArguments
            if ($LASTEXITCODE -ne 0) {
                throw "MSBuild failed with exit code $LASTEXITCODE."
            }

            $builtAssembly = Join-Path $buildOutput $assemblyName
            if (-not (Test-Path -LiteralPath $builtAssembly -PathType Leaf)) {
                throw "Build completed, but '$assemblyName' was not found in '$buildOutput'."
            }

            $yearOutput = Join-Path $outputRoot $year
            New-Item -ItemType Directory -Path $yearOutput -Force | Out-Null
            $destination = Join-Path $yearOutput $assemblyName
            Copy-Item -LiteralPath $builtAssembly -Destination $destination -Force

            $results.Add([pscustomobject]@{
                Year = $year
                Branch = $actualRef
                Platform = $platform
                Status = 'Succeeded'
                Output = $destination
            })

            Write-Host "[$year] Copied to '$destination'."
        }
        catch {
            $results.Add([pscustomobject]@{
                Year = $year
                Branch = $actualRef
                Platform = $platform
                Status = 'Failed'
                Output = $_.Exception.Message
            })

            Write-Warning "[$year] $($_.Exception.Message)"
        }
    }
}
finally {
    try {
        if ($originalBranch) {
            Invoke-Git -Arguments @('switch', '--quiet', $originalBranch)
        }
        else {
            Invoke-Git -Arguments @('switch', '--quiet', '--detach', $originalCommit)
        }
    }
    catch {
        $restoreError = $_.Exception.Message
    }

    $expectedTempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    if ($resolvedTempRoot.StartsWith($expectedTempParent + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot).StartsWith('revit-ifc-build-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$results | Format-Table -AutoSize -Wrap

if ($restoreError) {
    throw "Builds finished, but the original Git revision could not be restored: $restoreError"
}

$failedBuilds = @($results | Where-Object Status -eq 'Failed')
if ($failedBuilds.Count -gt 0) {
    throw "$($failedBuilds.Count) build(s) failed. See the summary above."
}

Write-Host "All requested assemblies are available in '$outputRoot'."
}
finally {
    if (-not $NoPause) {
        try {
            [void](Read-Host 'Press Enter to close')
        }
        catch {
            Write-Warning "Could not pause before exit: $($_.Exception.Message)"
        }
    }
}
