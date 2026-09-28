Set-StrictMode -Version 2.0

$script:MatrixVaultVersion = 1

function Get-MatrixVaultRoot {
    param([string]$PlatformRoot)
    if ([string]::IsNullOrWhiteSpace($PlatformRoot)) {
        $PlatformRoot = Split-Path -Parent $PSScriptRoot
    }
    return [IO.Path]::GetFullPath($PlatformRoot)
}

function Get-MatrixVaultPaths {
    param([string]$PlatformRoot)
    $root = Get-MatrixVaultRoot -PlatformRoot $PlatformRoot
    $directory = Join-Path $root "private\vault"
    return [PSCustomObject]@{
        PlatformRoot = $root
        Directory = $directory
        File = (Join-Path $directory "vault.json")
    }
}

function Protect-MatrixVaultAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Ambiente corporativo pode bloquear alteracoes de ACL sem privilegio elevado.
    # A protecao do segredo e feita pelo proprio Windows via ConvertFrom-SecureString
    # no contexto do usuario atual. Esta funcao fica propositalmente silenciosa.
    return
}

function Initialize-MatrixVault {
    param([string]$PlatformRoot)
    $paths = Get-MatrixVaultPaths -PlatformRoot $PlatformRoot

    if (-not (Test-Path -LiteralPath $paths.Directory)) {
        New-Item -ItemType Directory -Path $paths.Directory -Force | Out-Null
    }
    [void](Protect-MatrixVaultAcl -Path $paths.Directory)

    if (-not (Test-Path -LiteralPath $paths.File)) {
        $now = (Get-Date).ToString("o")
        $vault = [ordered]@{
            version = $script:MatrixVaultVersion
            createdAt = $now
            updatedAt = $now
            ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            secrets = @()
        }
        $vault | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $paths.File -Encoding UTF8
        [void](Protect-MatrixVaultAcl -Path $paths.File)
    }

    return $paths
}

function Read-MatrixVault {
    param([string]$PlatformRoot)
    $paths = Initialize-MatrixVault -PlatformRoot $PlatformRoot
    try {
        $vault = Get-Content -LiteralPath $paths.File -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw ("Cofre Matrix corrompido ou ilegivel: " + $_.Exception.Message)
    }

    if (-not $vault -or [int]$vault.version -ne $script:MatrixVaultVersion) {
        throw "Versao do Cofre Matrix nao suportada."
    }

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($vault.PSObject.Properties.Name -contains "ownerSid") {
        if ([string]$vault.ownerSid -ne $currentSid) {
            throw "Este cofre pertence a outro usuario Windows."
        }
    }

    return [PSCustomObject]@{ Paths = $paths; Data = $vault }
}

function Write-MatrixVault {
    param(
        [Parameter(Mandatory = $true)]$VaultData,
        [Parameter(Mandatory = $true)]$Paths
    )

    $VaultData.updatedAt = (Get-Date).ToString("o")
    $temp = $Paths.File + ".tmp"

    try {
        $VaultData | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
        [void](Protect-MatrixVaultAcl -Path $temp)
        Move-Item -LiteralPath $temp -Destination $Paths.File -Force
        [void](Protect-MatrixVaultAcl -Path $Paths.File)
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Normalize-MatrixSecretId {
    param([Parameter(Mandatory = $true)][string]$Id)
    $value = $Id.Trim().ToUpperInvariant()
    $value = $value -replace '[^A-Z0-9_\-\.]', '_'
    if ([string]::IsNullOrWhiteSpace($value)) { throw "ID do segredo invalido." }
    return $value
}

function Get-MatrixSecretMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$PlatformRoot
    )

    $normalized = Normalize-MatrixSecretId -Id $Id
    $state = Read-MatrixVault -PlatformRoot $PlatformRoot
    $record = @($state.Data.secrets | Where-Object { ([string]$_.id) -eq $normalized } | Select-Object -First 1)
    if (-not $record -or $record.Count -eq 0) { return $null }

    $item = $record[0]
    return [PSCustomObject]@{
        Id = [string]$item.id
        Account = if ($item.PSObject.Properties.Name -contains "account") { [string]$item.account } else { "" }
        Kind = if ($item.PSObject.Properties.Name -contains "kind") { [string]$item.kind } else { "SECRET" }
        Provider = if ($item.PSObject.Properties.Name -contains "provider") { [string]$item.provider } else { "" }
        CreatedAt = [string]$item.createdAt
        UpdatedAt = [string]$item.updatedAt
    }
}

function Get-MatrixSecretList {
    param([string]$PlatformRoot)
    $state = Read-MatrixVault -PlatformRoot $PlatformRoot
    $result = @()

    foreach ($item in @($state.Data.secrets)) {
        $result += [PSCustomObject]@{
            Id = [string]$item.id
            Account = if ($item.PSObject.Properties.Name -contains "account") { [string]$item.account } else { "" }
            Kind = if ($item.PSObject.Properties.Name -contains "kind") { [string]$item.kind } else { "SECRET" }
            Provider = if ($item.PSObject.Properties.Name -contains "provider") { [string]$item.provider } else { "" }
            UpdatedAt = [string]$item.updatedAt
        }
    }

    return @($result | Sort-Object Id)
}

function Set-MatrixSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][Security.SecureString]$Secret,
        [string]$Account = "",
        [string]$Kind = "SECRET",
        [string]$Provider = "",
        [string]$PlatformRoot
    )

    $normalized = Normalize-MatrixSecretId -Id $Id
    $state = Read-MatrixVault -PlatformRoot $PlatformRoot

    $cipher = ($Secret | ConvertFrom-SecureString)
    if ([string]::IsNullOrWhiteSpace([string]$cipher)) {
        throw "O segredo nao pode ser vazio."
    }

    $now = (Get-Date).ToString("o")
    $existing = @($state.Data.secrets | Where-Object { ([string]$_.id) -eq $normalized } | Select-Object -First 1)

    if ($existing -and $existing.Count -gt 0) {
        $item = $existing[0]
        $item.cipher = $cipher
        $item.account = $Account
        $item.kind = $Kind.ToUpperInvariant()
        $item.provider = $Provider
        $item.updatedAt = $now
    }
    else {
        $newItem = [PSCustomObject]@{
            id = $normalized
            account = $Account
            kind = $Kind.ToUpperInvariant()
            provider = $Provider
            cipher = $cipher
            createdAt = $now
            updatedAt = $now
        }
        $state.Data.secrets = @($state.Data.secrets) + @($newItem)
    }

    Write-MatrixVault -VaultData $state.Data -Paths $state.Paths
    return (Get-MatrixSecretMetadata -Id $normalized -PlatformRoot $PlatformRoot)
}

function Get-MatrixSecretSecure {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$PlatformRoot
    )

    $normalized = Normalize-MatrixSecretId -Id $Id
    $state = Read-MatrixVault -PlatformRoot $PlatformRoot
    $record = @($state.Data.secrets | Where-Object { ([string]$_.id) -eq $normalized } | Select-Object -First 1)

    if (-not $record -or $record.Count -eq 0) {
        throw ("Segredo nao encontrado no Cofre Matrix: " + $normalized)
    }

    try {
        return (ConvertTo-SecureString ([string]$record[0].cipher))
    }
    catch {
        throw "Nao foi possivel descriptografar o segredo. Use o mesmo usuario Windows que cadastrou a credencial."
    }
}

function Get-MatrixSecretValue {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$PlatformRoot
    )

    $secure = Get-MatrixSecretSecure -Id $Id -PlatformRoot $PlatformRoot
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Remove-MatrixSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$PlatformRoot
    )

    $normalized = Normalize-MatrixSecretId -Id $Id
    $state = Read-MatrixVault -PlatformRoot $PlatformRoot
    $before = @($state.Data.secrets).Count
    $state.Data.secrets = @($state.Data.secrets | Where-Object { ([string]$_.id) -ne $normalized })

    if (@($state.Data.secrets).Count -eq $before) { return $false }

    Write-MatrixVault -VaultData $state.Data -Paths $state.Paths
    return $true
}

function Test-MatrixSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$PlatformRoot
    )

    try {
        $value = Get-MatrixSecretValue -Id $Id -PlatformRoot $PlatformRoot
        $ok = -not [string]::IsNullOrEmpty($value)
        $value = $null
        return $ok
    }
    catch {
        return $false
    }
}
