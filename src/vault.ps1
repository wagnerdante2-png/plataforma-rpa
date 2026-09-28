Set-StrictMode -Version 2.0

$script:MatrixVaultVersion = 1
$script:MatrixVaultEntropyText = "MATRIX_RPA_VAULT_V1"

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

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $userSid = $identity.User
        $systemSid = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList "S-1-5-18"
        $rights = [Security.AccessControl.FileSystemRights]::FullControl
        $allow = [Security.AccessControl.AccessControlType]::Allow

        if (Test-Path -LiteralPath $Path -PathType Container) {
            $security = Get-Acl -LiteralPath $Path
            $security.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($security.Access)) {
                [void]$security.RemoveAccessRuleSpecific($rule)
            }

            $inherit = [Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
            $prop = [Security.AccessControl.PropagationFlags]::None
            $userRule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($userSid, $rights, $inherit, $prop, $allow)
            $systemRule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($systemSid, $rights, $inherit, $prop, $allow)
            $security.AddAccessRule($userRule)
            $security.AddAccessRule($systemRule)
            Set-Acl -LiteralPath $Path -AclObject $security
            return
        }

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $security = Get-Acl -LiteralPath $Path
            $security.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($security.Access)) {
                [void]$security.RemoveAccessRuleSpecific($rule)
            }

            $userRule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($userSid, $rights, $allow)
            $systemRule = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($systemSid, $rights, $allow)
            $security.AddAccessRule($userRule)
            $security.AddAccessRule($systemRule)
            Set-Acl -LiteralPath $Path -AclObject $security
            return
        }
    }
    catch {
        Write-Warning ("ACL adicional do Cofre Matrix nao pode ser aplicada neste Windows. DPAPI CurrentUser continua protegendo os segredos. Motivo: " + $_.Exception.Message)
        return
    }

    return
}

function Get-MatrixVaultEntropy {
    return [Text.Encoding]::UTF8.GetBytes($script:MatrixVaultEntropyText)
}

function Protect-MatrixSecretText {
    param([Parameter(Mandatory = $true)][string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { throw "O segredo nao pode ser vazio." }

    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes,
            (Get-MatrixVaultEntropy),
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Convert]::ToBase64String($protected)
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Unprotect-MatrixSecretText {
    param([Parameter(Mandatory = $true)][string]$CipherText)
    $protected = [Convert]::FromBase64String($CipherText)
    $plainBytes = $null
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            (Get-MatrixVaultEntropy),
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plainBytes)
    }
    catch {
        throw "Nao foi possivel descriptografar o segredo. Use o mesmo usuario Windows que cadastrou a credencial."
    }
    finally {
        if ($plainBytes) { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
        if ($protected) { [Array]::Clear($protected, 0, $protected.Length) }
    }
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

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plain)) { throw "O segredo nao pode ser vazio." }
        $cipher = Protect-MatrixSecretText -PlainText $plain
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        $plain = $null
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

    $plain = Unprotect-MatrixSecretText -CipherText ([string]$record[0].cipher)
    try {
        return (ConvertTo-SecureString $plain -AsPlainText -Force)
    }
    finally {
        $plain = $null
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
