param(
    [int]$TopN = 20,
    [ValidateSet('main12', 'energy', 'fiber')]
    [string]$Preset = 'main12',
    [string]$OutFile = ''
)

$ErrorActionPreference = "SilentlyContinue"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

$pyCandidates = @(
    'C:\Users\hongyangwan\AppData\Local\Programs\Python\Python313\python.exe',
    'python'
)

$pythonCmd = $null
foreach ($candidate in $pyCandidates) {
    try {
        if ($candidate -eq 'python') {
            $cmd = Get-Command python -ErrorAction SilentlyContinue
            if ($cmd) { $pythonCmd = $cmd.Source; break }
        }
        elseif (Test-Path $candidate) {
            $pythonCmd = $candidate
            break
        }
    }
    catch {}
}

if (-not $pythonCmd) {
    throw 'Python not found. Please install Python 3.11 or use workspace .venv.'
}

$scriptPath = Join-Path $PSScriptRoot 'python\Get-HotLowCandidates.py'
if (-not (Test-Path $scriptPath)) {
    throw "Script not found: $scriptPath"
}

$args = @($scriptPath, '--topn', $TopN, '--preset', $Preset)
if ($OutFile) {
    $args += @('--out', $OutFile)
}

& $pythonCmd @args
