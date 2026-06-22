# Local dev server for DTSC frontend
$port = 5173
$root = $PSScriptRoot
Write-Host "DTSC Frontend: http://localhost:$port"
python -m http.server $port --directory $root