$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebRoot = Join-Path $Root "web"
$RobotsFile = Join-Path $Root "robots.json"
$LogDirectory = Join-Path $Root "logs"
$RobotDirectory = Join-Path $Root "robots"
$RuntimeDirectory = Join-Path $Root "runtime"
$DownloadDirectory = Join-Path $Root "downloads"
$AppDirectory = Join-Path $Root "apps"
$AdherenceAppId = "aderencia-escala"
$AdherenceAppDirectory = Join-Path $AppDirectory $AdherenceAppId
$AdherenceIndexPath = Join-Path $AdherenceAppDirectory "index.html"
$AdherenceRepositoryZip = "https://github.com/wagnerdante2-png/aderencia-escala/archive/refs/heads/main.zip"
$ScaleFileName = "Escala de Folgas.xlsm"
$ScaleFilePath = Join-Path $DownloadDirectory $ScaleFileName
$Port = 8765
$BaseUrl = "http://127.0.0.1:$Port/"
$CRLF = ([char]13).ToString() + ([char]10).ToString()

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Ensure-Directory $LogDirectory
Ensure-Directory $RobotDirectory
Ensure-Directory $RuntimeDirectory
Ensure-Directory $DownloadDirectory
Ensure-Directory $AppDirectory
$LogFile = Join-Path $LogDirectory ("central_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-CentralLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} | {1} | {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-RobotsConfig {
    if (-not (Test-Path -LiteralPath $RobotsFile)) {
        throw "robots.json nao encontrado: $RobotsFile"
    }
    return (Get-Content -LiteralPath $RobotsFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Resolve-RobotCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return "" }
    if ([IO.Path]::IsPathRooted($Command)) { return [IO.Path]::GetFullPath($Command) }
    return [IO.Path]::GetFullPath((Join-Path $Root $Command))
}

function Get-RobotsPayload {
    $config = Get-RobotsConfig
    $result = @()

    foreach ($robot in @($config.robots)) {
        $path = Resolve-RobotCommand ([string]$robot.command)
        $enabled = $true
        if ($robot.PSObject.Properties.Name -contains "enabled") {
            $enabled = [bool]$robot.enabled
        }

        $installed = (-not [string]::IsNullOrWhiteSpace($path)) -and (Test-Path -LiteralPath $path)
        $installable = $robot.PSObject.Properties.Name -contains "repositoryZip" -and -not [string]::IsNullOrWhiteSpace([string]$robot.repositoryZip)

        $result += [PSCustomObject]@{
            id = [string]$robot.id
            name = [string]$robot.name
            description = [string]$robot.description
            category = if ($robot.PSObject.Properties.Name -contains "category") { [string]$robot.category } else { "AUTOMACAO" }
            symbol = if ($robot.PSObject.Properties.Name -contains "symbol") { [string]$robot.symbol } else { ">_" }
            enabled = $enabled
            installed = $installed
            installable = $installable
            available = $enabled -and ($installed -or $installable)
        }
    }

    return [PSCustomObject]@{
        title = [string]$config.title
        subtitle = [string]$config.subtitle
        robots = $result
    }
}

function Ensure-RobotInstalled {
    param($Robot)

    $commandPath = Resolve-RobotCommand ([string]$Robot.command)
    if (Test-Path -LiteralPath $commandPath) {
        return $commandPath
    }

    $hasSource = $Robot.PSObject.Properties.Name -contains "repositoryZip"
    if (-not $hasSource -or [string]::IsNullOrWhiteSpace([string]$Robot.repositoryZip)) {
        throw "Robo nao esta instalado e nao possui fonte de instalacao configurada: $([string]$Robot.id)"
    }

    $installDir = Split-Path -Parent $commandPath
    $installParent = Split-Path -Parent $installDir
    Ensure-Directory $installParent

    if (Test-Path -LiteralPath $installDir) {
        $recoveryDir = Join-Path $RobotDirectory "_recovery"
        Ensure-Directory $recoveryDir
        $recoveryPath = Join-Path $recoveryDir ("{0}_{1}" -f [string]$Robot.id, (Get-Date -Format "yyyyMMdd_HHmmss"))
        Write-CentralLog ("Instalacao incompleta encontrada para {0}. Movendo para {1}" -f [string]$Robot.id, $recoveryPath) "AVISO"
        Move-Item -LiteralPath $installDir -Destination $recoveryPath -Force
    }

    $token = [Guid]::NewGuid().ToString("N")
    $tempDir = Join-Path $RuntimeDirectory ("install_" + $token)
    $zipPath = Join-Path $tempDir "robot.zip"
    $extractDir = Join-Path $tempDir "extract"

    Ensure-Directory $tempDir
    Ensure-Directory $extractDir

    try {
        Write-CentralLog ("Acoplando robo {0} a partir de {1}" -f [string]$Robot.id, [string]$Robot.repositoryZip)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri ([string]$Robot.repositoryZip) -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $sourceRoot = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $sourceRoot) {
            throw "Pacote do robo nao possui uma pasta raiz reconhecivel."
        }

        Ensure-Directory $installDir
        Get-ChildItem -LiteralPath $sourceRoot.FullName -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $installDir -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath $commandPath)) {
            throw "Pacote baixado, mas o launcher esperado nao foi encontrado: $commandPath"
        }

        Write-CentralLog ("Robo {0} acoplado com sucesso em {1}" -f [string]$Robot.id, $installDir)
        return $commandPath
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            try { Remove-Item -LiteralPath $tempDir -Recurse -Force } catch {}
        }
    }
}

function Start-Robot {
    param([Parameter(Mandatory = $true)][string]$Id)

    $config = Get-RobotsConfig
    $robot = @($config.robots | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if (-not $robot) { throw "Robo nao encontrado: $Id" }

    $enabled = $true
    if ($robot.PSObject.Properties.Name -contains "enabled") { $enabled = [bool]$robot.enabled }
    if (-not $enabled) { throw "Robo desabilitado: $Id" }

    $commandPath = Ensure-RobotInstalled -Robot $robot
    if ([string]::IsNullOrWhiteSpace($commandPath) -or -not (Test-Path -LiteralPath $commandPath)) {
        throw "Executavel do robo nao encontrado apos acoplamento: $commandPath"
    }

    $workingDirectory = Split-Path -Parent $commandPath
    $extension = [IO.Path]::GetExtension($commandPath).ToLowerInvariant()

    Write-CentralLog ("Executando robo {0}: {1}" -f $Id, $commandPath)

    if ($extension -eq ".cmd" -or $extension -eq ".bat") {
        Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", ('"' + $commandPath + '"')) -WorkingDirectory $workingDirectory | Out-Null
    }
    elseif ($extension -eq ".ps1") {
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $commandPath + '"')) -WorkingDirectory $workingDirectory | Out-Null
    }
    else {
        Start-Process -FilePath $commandPath -WorkingDirectory $workingDirectory | Out-Null
    }

    return [PSCustomObject]@{
        ok = $true
        id = $Id
        name = [string]$robot.name
        startedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        installed = $true
    }
}

function Ensure-AdherenceAppInstalled {
    if (Test-Path -LiteralPath $AdherenceIndexPath -PathType Leaf) {
        return $AdherenceAppDirectory
    }

    if (Test-Path -LiteralPath $AdherenceAppDirectory) {
        $recoveryDir = Join-Path $AppDirectory "_recovery"
        Ensure-Directory $recoveryDir
        $recoveryPath = Join-Path $recoveryDir ("aderencia-escala_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        Write-CentralLog ("Instalacao incompleta da Aderencia encontrada. Movendo para " + $recoveryPath) "AVISO"
        Move-Item -LiteralPath $AdherenceAppDirectory -Destination $recoveryPath -Force
    }

    $token = [Guid]::NewGuid().ToString("N")
    $tempDir = Join-Path $RuntimeDirectory ("app_" + $token)
    $zipPath = Join-Path $tempDir "aderencia.zip"
    $extractDir = Join-Path $tempDir "extract"

    Ensure-Directory $tempDir
    Ensure-Directory $extractDir

    try {
        Write-CentralLog ("Acoplando app aderencia-escala a partir de " + $AdherenceRepositoryZip)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $AdherenceRepositoryZip -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

        $sourceRoot = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
        if (-not $sourceRoot) {
            throw "Pacote da Aderencia nao possui uma pasta raiz reconhecivel."
        }

        Ensure-Directory $AdherenceAppDirectory
        Get-ChildItem -LiteralPath $sourceRoot.FullName -Force | Where-Object {
            $_.Name -notin @(".github", "tests")
        } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $AdherenceAppDirectory -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath $AdherenceIndexPath -PathType Leaf)) {
            throw "Pacote baixado, mas index.html da Aderencia nao foi encontrado."
        }

        Write-CentralLog ("App aderencia-escala acoplado com sucesso em " + $AdherenceAppDirectory)
        return $AdherenceAppDirectory
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            try { Remove-Item -LiteralPath $tempDir -Recurse -Force } catch {}
        }
    }
}

function Send-AppStaticFile {
    param(
        [System.IO.Stream]$Stream,
        [string]$RequestPath
    )

    [void](Ensure-AdherenceAppInstalled)

    $prefix = "/apps/aderencia-escala"
    $relative = $RequestPath.Substring($prefix.Length).TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = "index.html" }
    $relative = [Uri]::UnescapeDataString($relative)

    $appFull = [IO.Path]::GetFullPath($AdherenceAppDirectory)
    $filePath = [IO.Path]::GetFullPath((Join-Path $AdherenceAppDirectory $relative))

    if (-not $filePath.StartsWith($appFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Arquivo da Aderencia nao encontrado." }
        return
    }

    Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -Body ([IO.File]::ReadAllBytes($filePath)) -ContentType (Get-ContentType $filePath)
}

function Get-ResourcesPayload {
    $scaleAvailable = Test-Path -LiteralPath $ScaleFilePath -PathType Leaf
    $scaleSize = 0

    if ($scaleAvailable) {
        $scaleSize = (Get-Item -LiteralPath $ScaleFilePath).Length
    }

    $adherenceInstalled = Test-Path -LiteralPath $AdherenceIndexPath -PathType Leaf

    return [PSCustomObject]@{
        scale = [PSCustomObject]@{
            id = "escala-folgas"
            name = "Escala de Folgas"
            fileName = $ScaleFileName
            available = $scaleAvailable
            sizeBytes = $scaleSize
            downloadUrl = "/download/escala-folgas"
        }
        adherence = [PSCustomObject]@{
            id = "aderencia-escala"
            name = "Aderencia de Escala"
            installed = $adherenceInstalled
            installable = $true
            available = $true
            openUrl = "/apps/aderencia-escala/"
        }
    }
}

function Write-FileDownloadResponse {
    param(
        [System.IO.Stream]$Stream,
        [string]$FilePath,
        [string]$DownloadName
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Arquivo local indisponivel." }
        return
    }

    $fileInfo = Get-Item -LiteralPath $FilePath
    $safeName = $DownloadName.Replace([char]34, "")
    $header = "HTTP/1.1 200 OK" + $CRLF +
              "Content-Type: application/vnd.ms-excel.sheet.macroEnabled.12" + $CRLF +
              "Content-Length: $($fileInfo.Length)" + $CRLF +
              "Content-Disposition: attachment; filename=" + [char]34 + $safeName + [char]34 + $CRLF +
              "Cache-Control: no-store" + $CRLF +
              "X-Content-Type-Options: nosniff" + $CRLF +
              "Connection: close" + $CRLF + $CRLF

    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)

    $fileStream = [IO.File]::OpenRead($FilePath)
    try {
        $buffer = New-Object byte[] 65536
        while (($read = $fileStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $Stream.Write($buffer, 0, $read)
        }
        $Stream.Flush()
    }
    finally {
        $fileStream.Dispose()
    }
}

function Get-ContentType {
    param([string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".html" { return "text/html; charset=utf-8" }
        ".css"  { return "text/css; charset=utf-8" }
        ".js"   { return "application/javascript; charset=utf-8" }
        ".json" { return "application/json; charset=utf-8" }
        ".svg"  { return "image/svg+xml" }
        ".png"  { return "image/png" }
        default { return "application/octet-stream" }
    }
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [string]$Reason,
        [byte[]]$Body,
        [string]$ContentType
    )

    if ($null -eq $Body) { $Body = New-Object byte[] 0 }

    $header = "HTTP/1.1 $StatusCode $Reason" + $CRLF +
              "Content-Type: $ContentType" + $CRLF +
              "Content-Length: $($Body.Length)" + $CRLF +
              "Cache-Control: no-store" + $CRLF +
              "X-Content-Type-Options: nosniff" + $CRLF +
              "Connection: close" + $CRLF + $CRLF

    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Write-JsonResponse {
    param([System.IO.Stream]$Stream, [int]$StatusCode, $Object)
    $reason = if ($StatusCode -eq 200) { "OK" } elseif ($StatusCode -eq 400) { "Bad Request" } elseif ($StatusCode -eq 404) { "Not Found" } else { "Internal Server Error" }
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    Write-HttpResponse -Stream $Stream -StatusCode $StatusCode -Reason $reason -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType "application/json; charset=utf-8"
}

function Read-HttpRequest {
    param([System.IO.Stream]$Stream)

    $reader = New-Object System.IO.StreamReader($Stream, [Text.Encoding]::UTF8, $false, 4096, $true)
    $requestLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($requestLine)) { return $null }

    $parts = $requestLine.Split(" ")
    if ($parts.Count -lt 2) { throw "Requisicao HTTP invalida." }

    $headers = @{}
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line -or $line -eq "") { break }
        $separator = $line.IndexOf(":")
        if ($separator -gt 0) {
            $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] = $line.Substring($separator + 1).Trim()
        }
    }

    $bodyText = ""
    $contentLength = 0
    if ($headers.ContainsKey("content-length")) {
        [void][int]::TryParse([string]$headers["content-length"], [ref]$contentLength)
    }

    if ($contentLength -gt 0) {
        $buffer = New-Object char[] $contentLength
        $readTotal = 0
        while ($readTotal -lt $contentLength) {
            $readNow = $reader.Read($buffer, $readTotal, $contentLength - $readTotal)
            if ($readNow -le 0) { break }
            $readTotal += $readNow
        }
        $bodyText = New-Object string($buffer, 0, $readTotal)
    }

    return [PSCustomObject]@{
        Method = $parts[0].ToUpperInvariant()
        Path = $parts[1]
        Body = $bodyText
    }
}

function Send-StaticFile {
    param([System.IO.Stream]$Stream, [string]$RequestPath)

    $relative = if ($RequestPath -eq "/") { "index.html" } else { $RequestPath.TrimStart("/") }
    $relative = [Uri]::UnescapeDataString($relative)
    $webFull = [IO.Path]::GetFullPath($WebRoot)
    $filePath = [IO.Path]::GetFullPath((Join-Path $WebRoot $relative))

    if (-not $filePath.StartsWith($webFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Arquivo nao encontrado." }
        return
    }

    Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -Body ([IO.File]::ReadAllBytes($filePath)) -ContentType (Get-ContentType $filePath)
}

function Handle-Request {
    param([System.IO.Stream]$Stream, $Request)

    $pathOnly = ([string]$Request.Path).Split("?")[0]

    if ($Request.Method -eq "GET" -and $pathOnly -eq "/api/robots") {
        Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Get-RobotsPayload)
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly -eq "/api/health") {
        Write-JsonResponse -Stream $Stream -StatusCode 200 -Object @{ ok = $true; node = "CENTRAL-RPA"; time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly -eq "/api/resources") {
        Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Get-ResourcesPayload)
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly -eq "/download/escala-folgas") {
        Write-CentralLog ("Download solicitado: " + $ScaleFilePath)
        Write-FileDownloadResponse -Stream $Stream -FilePath $ScaleFilePath -DownloadName "Escala_de_Folgas.xlsm"
        return
    }

    if ($Request.Method -eq "POST" -and $pathOnly -eq "/api/run") {
        try {
            $payload = $Request.Body | ConvertFrom-Json
            $id = [string]$payload.id
            if ([string]::IsNullOrWhiteSpace($id)) { throw "ID do robo nao informado." }
            Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Start-Robot -Id $id)
        }
        catch {
            Write-CentralLog $_.Exception.Message "ERRO"
            Write-JsonResponse -Stream $Stream -StatusCode 400 -Object @{ ok = $false; message = $_.Exception.Message }
        }
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly.StartsWith("/apps/aderencia-escala", [StringComparison]::OrdinalIgnoreCase)) {
        try {
            Send-AppStaticFile -Stream $Stream -RequestPath $pathOnly
        }
        catch {
            Write-CentralLog $_.Exception.Message "ERRO"
            Write-JsonResponse -Stream $Stream -StatusCode 400 -Object @{ ok = $false; message = $_.Exception.Message }
        }
        return
    }

    if ($Request.Method -eq "GET") {
        Send-StaticFile -Stream $Stream -RequestPath $pathOnly
        return
    }

    Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Rota nao encontrada." }
}

$listener = $null
$stream = $null

try {
    if (-not (Test-Path -LiteralPath $WebRoot)) { throw "Pasta web nao encontrada: $WebRoot" }

    $listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([Net.IPAddress]::Loopback), $Port
    $listener.Start()

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " CENTRAL RPA // LOCAL AUTOMATION NODE" -ForegroundColor Green
    Write-Host " MATRIX INTERFACE ONLINE" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-CentralLog ("Servidor local iniciado em " + $BaseUrl)
    Write-Host "Feche esta janela para encerrar a Central." -ForegroundColor DarkGray
    Write-Host ""

    Start-Process $BaseUrl | Out-Null

    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null

        try {
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream
            if ($request) { Handle-Request -Stream $stream -Request $request }
        }
        catch {
            Write-CentralLog $_.Exception.Message "ERRO"
            try {
                if ($stream) { Write-JsonResponse -Stream $stream -StatusCode 500 -Object @{ ok = $false; message = "Erro interno da Central." } }
            }
            catch {}
        }
        finally {
            try { if ($stream) { $stream.Dispose() } } catch {}
            try { $client.Close() } catch {}
        }
    }
}
catch {
    Write-CentralLog $_.Exception.Message "ERRO"
    Write-Host ""
    Write-Host ("[ERRO] " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ""
    Read-Host "Pressione ENTER para fechar"
    exit 1
}
finally {
    if ($listener) {
        try { $listener.Stop() } catch {}
    }
}
