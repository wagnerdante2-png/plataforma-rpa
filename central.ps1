$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebRoot = Join-Path $Root "web"
$RobotsFile = Join-Path $Root "robots.json"
$LogDirectory = Join-Path $Root "logs"
$RobotDirectory = Join-Path $Root "robots"
$RuntimeDirectory = Join-Path $Root "runtime"
$DownloadDirectory = Join-Path $Root "downloads"
$ArchiveDirectory = Join-Path $Root "archive"
$ProcessArchiveDirectory = Join-Path $ArchiveDirectory "processos"
$ProjectArchiveDirectory = Join-Path $ArchiveDirectory "projetos"
$AppDirectory = Join-Path $Root "apps"
$AdherenceAppId = "aderencia-escala"
$AdherenceAppDirectory = Join-Path $AppDirectory $AdherenceAppId
$AdherenceIndexPath = Join-Path $AdherenceAppDirectory "index.html"
$AdherenceRepositoryZip = "https://github.com/wagnerdante2-png/aderencia-escala/archive/refs/heads/main.zip"
$WorkforceAppDirectory = Join-Path $AppDirectory "workforce-operacional"
$WorkforceIndexPath = Join-Path $WorkforceAppDirectory "index.html"
$IdentificationStandardUrl = "file://fs1maravilhas.file.core.windows.net/publico/SharepointTI/CGOCRYPT/cgo861.html"
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
Ensure-Directory $ArchiveDirectory
Ensure-Directory $ProcessArchiveDirectory
Ensure-Directory $ProjectArchiveDirectory
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

function Get-CentralGitHubToken {
    foreach ($name in @("GH_TOKEN", "GITHUB_TOKEN")) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    try {
        $gh = Get-Command "gh.exe" -ErrorAction SilentlyContinue
        if (-not $gh) { $gh = Get-Command "gh" -ErrorAction SilentlyContinue }
        if ($gh) {
            $token = (& $gh.Source auth token 2>$null | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace([string]$token)) { return ([string]$token).Trim() }
        }
    } catch {}

    try {
        $git = Get-Command "git.exe" -ErrorAction SilentlyContinue
        if (-not $git) { $git = Get-Command "git" -ErrorAction SilentlyContinue }
        if ($git) {
            $oldInteractive = $env:GCM_INTERACTIVE
            try {
                $env:GCM_INTERACTIVE = "Never"
                $credentialInput = "protocol=https`nhost=github.com`n`n"
                $result = @($credentialInput | & $git.Source -c credential.interactive=never credential fill 2>$null)
                foreach ($line in $result) {
                    if ([string]$line -match '^password=(.+)$') {
                        $token = [string]$Matches[1]
                        if (-not [string]::IsNullOrWhiteSpace($token)) { return $token.Trim() }
                    }
                }
            } finally { $env:GCM_INTERACTIVE = $oldInteractive }
        }
    } catch {}

    return ""
}

function Invoke-CentralPrivateBrowserDownload {
    param(
        $Robot,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $browserUri = ""
    if ($Robot.PSObject.Properties.Name -contains "repositoryBrowserZip") {
        $browserUri = ([string]$Robot.repositoryBrowserZip).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($browserUri)) {
        throw ("O robo '{0}' e privado e nao possui URL de fallback pelo navegador." -f [string]$Robot.id)
    }

    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path -LiteralPath $downloads)) {
        throw "Pasta Downloads nao encontrada para o fallback de repositorio privado."
    }

    $pattern = "robo-horas*.zip"
    if ($Robot.PSObject.Properties.Name -contains "browserDownloadPattern") {
        $candidatePattern = ([string]$Robot.browserDownloadPattern).Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidatePattern)) {
            $pattern = $candidatePattern
        }
    }

    $startedAt = (Get-Date).ToUniversalTime()

    Write-Host "[..] Repositorio privado: usando sessao GitHub do navegador..." -ForegroundColor Yellow
    Write-Host "     O navegador abrira o download autenticado. Nao feche a aba." -ForegroundColor DarkGray

    Start-Process $browserUri

    $deadline = (Get-Date).AddSeconds(120)
    $downloaded = $null

    while ((Get-Date) -lt $deadline) {
        $partial = Get-ChildItem -LiteralPath $downloads -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like ($pattern + ".crdownload") -or
                $_.Name -like ($pattern + ".tmp")
            }

        $candidate = Get-ChildItem -LiteralPath $downloads -Filter $pattern -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTimeUtc -ge $startedAt.AddSeconds(-3) -and
                $_.Length -gt 0
            } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($candidate -and -not $partial) {
            $downloaded = $candidate
            break
        }

        Start-Sleep -Milliseconds 750
    }

    if (-not $downloaded) {
        throw ("A Matrix abriu o download privado do robo '{0}', mas nao encontrou o ZIP concluido em Downloads. " +
               "Confirme que o navegador esta logado no GitHub e tente novamente.") -f [string]$Robot.id
    }

    Copy-Item -LiteralPath $downloaded.FullName -Destination $OutFile -Force
    Write-Host ("[OK] Pacote privado recebido via navegador: {0}" -f $downloaded.Name) -ForegroundColor Green
}

function Invoke-CentralRobotPackageDownload {
    param($Robot, [Parameter(Mandatory = $true)][string]$OutFile)

    $uri = [string]$Robot.repositoryZip
    $isPrivate = $false
    if ($Robot.PSObject.Properties.Name -contains "privateRepository") {
        $isPrivate = [bool]$Robot.privateRepository
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not $isPrivate) {
        Invoke-WebRequest -Uri $uri -OutFile $OutFile -UseBasicParsing
        return
    }

    $githubToken = Get-CentralGitHubToken

    if (-not [string]::IsNullOrWhiteSpace($githubToken)) {
        $headers = @{
            Authorization = ("Bearer " + $githubToken)
            Accept = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
            "User-Agent" = "Matrix-RPA"
        }

        Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $OutFile -UseBasicParsing
        return
    }

    Invoke-CentralPrivateBrowserDownload -Robot $Robot -OutFile $OutFile
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
        Invoke-CentralRobotPackageDownload -Robot $Robot -OutFile $zipPath
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

function Get-WorkforceSearchRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in @(
        $Root,
        (Split-Path -Parent $Root),
        $(if (Split-Path -Parent $Root) { Split-Path -Parent (Split-Path -Parent $Root) } else { $null }),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "Downloads" } else { $null }),
        $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE "Desktop" } else { $null })
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if ((Test-Path -LiteralPath $full -PathType Container) -and -not $roots.Contains($full)) {
                $roots.Add($full)
            }
        }
        catch {}
    }

    return @($roots)
}

function Find-WorkforceOfflineDemo {
    foreach ($base in @(Get-WorkforceSearchRoots)) {
        try {
            $packagedIndex = Get-ChildItem -LiteralPath $base -File -Filter "index.html" -Recurse -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Directory.Name -ieq "workforce-operacional" -and
                    $_.Directory.Parent -and
                    $_.Directory.Parent.Name -ieq "apps" -and
                    ([IO.Path]::GetFullPath($_.Directory.FullName) -ne [IO.Path]::GetFullPath($WorkforceAppDirectory))
                } |
                Select-Object -First 1

            if ($packagedIndex) {
                return [PSCustomObject]@{
                    kind = "dist"
                    path = $packagedIndex.Directory.FullName
                    source = "packaged-app"
                }
            }
        }
        catch {}


        try {
            $zip = Get-ChildItem -LiteralPath $base -File -Filter "workforce-demo-offline.zip" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($zip) {
                return [PSCustomObject]@{
                    kind = "zip"
                    path = $zip.FullName
                }
            }
        }
        catch {}

        try {
            $index = Get-ChildItem -LiteralPath $base -File -Filter "index.html" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.Name -ieq "dist-offline" } |
                Select-Object -First 1
            if ($index) {
                return [PSCustomObject]@{
                    kind = "dist"
                    path = $index.Directory.FullName
                }
            }
        }
        catch {}

        try {
            $launcher = Get-ChildItem -LiteralPath $base -File -Filter "ABRIR-WORKFORCE-DEMO.cmd" -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($launcher) {
                $nearbyDist = Join-Path $launcher.Directory.FullName "dist-offline"
                if (Test-Path -LiteralPath (Join-Path $nearbyDist "index.html") -PathType Leaf) {
                    return [PSCustomObject]@{
                        kind = "dist"
                        path = $nearbyDist
                    }
                }
            }
        }
        catch {}
    }

    return $null
}

function Copy-WorkforceDist {
    param([string]$SourceDirectory)

    $sourceIndex = Join-Path $SourceDirectory "index.html"
    if (-not (Test-Path -LiteralPath $sourceIndex -PathType Leaf)) {
        throw "dist-offline do Workforce nao possui index.html."
    }

    if (Test-Path -LiteralPath $WorkforceAppDirectory) {
        Remove-Item -LiteralPath $WorkforceAppDirectory -Recurse -Force
    }

    Ensure-Directory $WorkforceAppDirectory
    Get-ChildItem -LiteralPath $SourceDirectory -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $WorkforceAppDirectory -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $WorkforceIndexPath -PathType Leaf)) {
        throw "Falha ao incorporar snapshot local do Workforce."
    }

    Write-CentralLog ("Snapshot local do Workforce incorporado a partir de: " + $SourceDirectory)
}

function Ensure-WorkforceSnapshotInstalled {
    if (Test-Path -LiteralPath $WorkforceIndexPath -PathType Leaf) {
        return $true
    }

    $artifact = Find-WorkforceOfflineDemo
    if (-not $artifact) {
        Write-CentralLog "Demo offline do Workforce nao localizada. Procurado por apps\workforce-operacional / workforce-demo-offline.zip / dist-offline / ABRIR-WORKFORCE-DEMO.cmd." "AVISO"
        return $false
    }

    if ([string]$artifact.kind -eq "dist") {
        Copy-WorkforceDist -SourceDirectory ([string]$artifact.path)
        return $true
    }

    if ([string]$artifact.kind -eq "zip") {
        $token = [Guid]::NewGuid().ToString("N")
        $tempDir = Join-Path $RuntimeDirectory ("workforce_import_" + $token)
        Ensure-Directory $tempDir

        try {
            Write-CentralLog ("Importando demo offline do Workforce: " + [string]$artifact.path)
            Expand-Archive -LiteralPath ([string]$artifact.path) -DestinationPath $tempDir -Force

            $index = Get-ChildItem -LiteralPath $tempDir -File -Filter "index.html" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Directory.Name -ieq "dist-offline" } |
                Select-Object -First 1

            if (-not $index) {
                throw "O ZIP workforce-demo-offline.zip nao contem dist-offline\index.html."
            }

            Copy-WorkforceDist -SourceDirectory $index.Directory.FullName
            return $true
        }
        finally {
            if (Test-Path -LiteralPath $tempDir) {
                try { Remove-Item -LiteralPath $tempDir -Recurse -Force } catch {}
            }
        }
    }

    return $false
}

function Send-WorkforceStaticFile {
    param(
        [System.IO.Stream]$Stream,
        [string]$RequestPath
    )

    if (-not (Test-Path -LiteralPath $WorkforceIndexPath -PathType Leaf)) {
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Snapshot local do Workforce ainda nao foi empacotado." }
        return
    }

    $prefix = "/apps/workforce-operacional"
    $relative = $RequestPath.Substring($prefix.Length).TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = "index.html" }
    $relative = [Uri]::UnescapeDataString($relative)

    $appFull = [IO.Path]::GetFullPath($WorkforceAppDirectory)
    $filePath = [IO.Path]::GetFullPath((Join-Path $WorkforceAppDirectory $relative))

    if (-not $filePath.StartsWith($appFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{ ok = $false; message = "Arquivo do Workforce nao encontrado." }
        return
    }

    Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -Body ([IO.File]::ReadAllBytes($filePath)) -ContentType (Get-ContentType $filePath)
}

function Get-WorkforcePayload {
    $installed = Test-Path -LiteralPath $WorkforceIndexPath -PathType Leaf
    $message = ""

    if (-not $installed) {
        try {
            $installed = [bool](Ensure-WorkforceSnapshotInstalled)
        }
        catch {
            $message = $_.Exception.Message
            Write-CentralLog ("Falha ao importar demo offline do Workforce: " + $message) "ERRO"
            $installed = $false
        }
    }

    if (-not $installed -and [string]::IsNullOrWhiteSpace($message)) {
        $message = "Demo offline do Workforce nao encontrada no pacote local nem no PC."
    }

    return [PSCustomObject]@{
        id = "workforce-operacional"
        installed = $installed
        localUrl = "/apps/workforce-operacional/"
        message = $message
        sourceArtifact = "workforce-demo-offline.zip"
        sourceLauncher = "ABRIR-WORKFORCE-DEMO.cmd"
        sourceBranch = "feature/historical-competence-navigation-20260813"
    }
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
        ".svg"   { return "image/svg+xml" }
        ".png"   { return "image/png" }
        ".jpg"   { return "image/jpeg" }
        ".jpeg"  { return "image/jpeg" }
        ".webp"  { return "image/webp" }
        ".ico"   { return "image/x-icon" }
        ".woff"  { return "font/woff" }
        ".woff2" { return "font/woff2" }
        ".ttf"   { return "font/ttf" }
        ".pdf"   { return "application/pdf" }
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
        Headers = $headers
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

function Resolve-ProcessArchiveFile {
    param([string]$RelativePath)

    $primary = [IO.Path]::GetFullPath((Join-Path $ProcessArchiveDirectory $RelativePath))
    if (Test-Path -LiteralPath $primary -PathType Leaf) {
        return $primary
    }

    $rootParent = Split-Path -Parent $Root
    $rootGrandParent = if ($rootParent) { Split-Path -Parent $rootParent } else { $null }
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($base in @($Root, $rootParent, $rootGrandParent)) {
        if ([string]::IsNullOrWhiteSpace($base) -or -not (Test-Path -LiteralPath $base -PathType Container)) { continue }

        $direct = Join-Path (Join-Path $base "archive\processos") $RelativePath
        $candidates.Add($direct)

        foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            $candidateA = Join-Path (Join-Path $dir.FullName "archive\processos") $RelativePath
            $candidates.Add($candidateA)

            $candidateB = Join-Path (Join-Path (Join-Path $dir.FullName "plataforma-rpa-main") "archive\processos") $RelativePath
            $candidates.Add($candidateB)
        }
    }

    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                Write-CentralLog ("Acervo documental localizado fora da pasta atual da plataforma: " + $full) "AVISO"
                return $full
            }
        }
        catch {}
    }

    return $null
}

function Send-ArchiveFile {
    param(
        [System.IO.Stream]$Stream,
        [string]$RequestPath
    )

    $prefix = "/archive/processos/"
    $relative = $RequestPath.Substring($prefix.Length)
    $relative = [Uri]::UnescapeDataString($relative)

    $filePath = Resolve-ProcessArchiveFile -RelativePath $relative

    if ([string]::IsNullOrWhiteSpace($filePath) -or
        -not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
        ([IO.Path]::GetExtension($filePath).ToLowerInvariant() -ne ".pdf")) {
        $expected = [IO.Path]::GetFullPath((Join-Path $ProcessArchiveDirectory $relative))
        Write-CentralLog ("Documento do acervo nao encontrado. Esperado em: " + $expected) "ERRO"
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{
            ok = $false
            message = "Documento nao encontrado no acervo local."
            expected = $expected
        }
        return
    }

    try {
        $pdfBytes = [IO.File]::ReadAllBytes($filePath)
        Write-CentralLog ("Documento servido ao visualizador: " + $filePath)
        Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -Body $pdfBytes -ContentType "application/pdf"
    }
    catch {
        Write-CentralLog ("Falha ao ler documento do acervo: " + $filePath + " | " + $_.Exception.Message) "ERRO"
        Write-JsonResponse -Stream $Stream -StatusCode 500 -Object @{
            ok = $false
            message = "Falha ao ler documento local."
        }
    }
}

function Resolve-ProjectArchiveFile {
    param([string]$RelativePath)

    $primary = [IO.Path]::GetFullPath((Join-Path $ProjectArchiveDirectory $RelativePath))
    if (Test-Path -LiteralPath $primary -PathType Leaf) {
        return $primary
    }

    $rootParent = Split-Path -Parent $Root
    $rootGrandParent = if ($rootParent) { Split-Path -Parent $rootParent } else { $null }
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($base in @($Root, $rootParent, $rootGrandParent)) {
        if ([string]::IsNullOrWhiteSpace($base) -or -not (Test-Path -LiteralPath $base -PathType Container)) { continue }

        $direct = Join-Path (Join-Path $base "archive\projetos") $RelativePath
        $candidates.Add($direct)

        foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            $candidateA = Join-Path (Join-Path $dir.FullName "archive\projetos") $RelativePath
            $candidates.Add($candidateA)

            $candidateB = Join-Path (Join-Path (Join-Path $dir.FullName "plataforma-rpa-main") "archive\projetos") $RelativePath
            $candidates.Add($candidateB)
        }
    }

    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                Write-CentralLog ("Documento de projeto localizado fora da pasta atual: " + $full) "AVISO"
                return $full
            }
        }
        catch {}
    }

    return $null
}

function Send-ProjectArchiveFile {
    param(
        [System.IO.Stream]$Stream,
        [string]$RequestPath
    )

    $prefix = "/archive/projetos/"
    $relative = $RequestPath.Substring($prefix.Length)
    $relative = [Uri]::UnescapeDataString($relative)

    $filePath = Resolve-ProjectArchiveFile -RelativePath $relative

    if ([string]::IsNullOrWhiteSpace($filePath) -or
        -not (Test-Path -LiteralPath $filePath -PathType Leaf) -or
        ([IO.Path]::GetExtension($filePath).ToLowerInvariant() -ne ".pdf")) {
        $expected = [IO.Path]::GetFullPath((Join-Path $ProjectArchiveDirectory $relative))
        Write-CentralLog ("Documento de projeto nao encontrado. Esperado em: " + $expected) "ERRO"
        Write-JsonResponse -Stream $Stream -StatusCode 404 -Object @{
            ok = $false
            message = "Documento de projeto nao encontrado no acervo local."
            expected = $expected
        }
        return
    }

    try {
        $pdfBytes = [IO.File]::ReadAllBytes($filePath)
        Write-CentralLog ("Documento de projeto servido ao visualizador: " + $filePath)
        Write-HttpResponse -Stream $Stream -StatusCode 200 -Reason "OK" -Body $pdfBytes -ContentType "application/pdf"
    }
    catch {
        Write-CentralLog ("Falha ao ler documento de projeto: " + $filePath + " | " + $_.Exception.Message) "ERRO"
        Write-JsonResponse -Stream $Stream -StatusCode 500 -Object @{
            ok = $false
            message = "Falha ao ler documento local do projeto."
        }
    }
}

function Open-ProjectArchiveFile {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Arquivo de projeto nao informado."
    }

    $relative = [Uri]::UnescapeDataString($RelativePath).TrimStart("/")
    if ($relative.StartsWith("archive/projetos/", [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $relative.Substring("archive/projetos/".Length)
    }

    if ($relative.Contains("..")) {
        throw "Caminho de arquivo invalido."
    }

    $filePath = Resolve-ProjectArchiveFile -RelativePath $relative
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Arquivo de projeto nao encontrado no acervo local."
    }

    $allowed = @(".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".xls", ".html", ".htm")
    $ext = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
    if ($allowed -notcontains $ext) {
        throw ("Tipo de arquivo nao autorizado para abertura local: " + $ext)
    }

    Write-CentralLog ("Abrindo arquivo historico de projeto: " + $filePath)
    Start-Process -FilePath $filePath | Out-Null

    return [PSCustomObject]@{
        ok = $true
        file = $filePath
    }
}

function Open-IdentificationStandard {
    try {
        Write-CentralLog ("Abrindo Identificacao Padrao: " + $IdentificationStandardUrl)
        Start-Process -FilePath $IdentificationStandardUrl | Out-Null
        return [PSCustomObject]@{
            ok = $true
            url = $IdentificationStandardUrl
        }
    }
    catch {
        throw ("Nao foi possivel abrir Identificacao Padrao: " + $_.Exception.Message)
    }
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

    if ($Request.Method -eq "GET" -and $pathOnly -eq "/api/workforce") {
        Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Get-WorkforcePayload)
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

    if ($Request.Method -eq "POST" -and $pathOnly -eq "/api/projects/open-file") {
        try {
            $payload = $Request.Body | ConvertFrom-Json
            $relativePath = [string]$payload.path
            Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Open-ProjectArchiveFile -RelativePath $relativePath)
        }
        catch {
            Write-CentralLog $_.Exception.Message "ERRO"
            Write-JsonResponse -Stream $Stream -StatusCode 400 -Object @{ ok = $false; message = $_.Exception.Message }
        }
        return
    }

    if ($Request.Method -eq "POST" -and $pathOnly -eq "/api/projects/identificacao-padrao/open") {
        try {
            Write-JsonResponse -Stream $Stream -StatusCode 200 -Object (Open-IdentificationStandard)
        }
        catch {
            Write-CentralLog $_.Exception.Message "ERRO"
            Write-JsonResponse -Stream $Stream -StatusCode 400 -Object @{ ok = $false; message = $_.Exception.Message }
        }
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

    if ($Request.Method -eq "GET" -and $pathOnly.StartsWith("/archive/processos/", [StringComparison]::OrdinalIgnoreCase)) {
        Send-ArchiveFile -Stream $Stream -RequestPath $pathOnly
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly.StartsWith("/archive/projetos/", [StringComparison]::OrdinalIgnoreCase)) {
        Send-ProjectArchiveFile -Stream $Stream -RequestPath $pathOnly
        return
    }

    if ($Request.Method -eq "GET" -and $pathOnly.StartsWith("/apps/workforce-operacional", [StringComparison]::OrdinalIgnoreCase)) {
        Send-WorkforceStaticFile -Stream $Stream -RequestPath $pathOnly
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
