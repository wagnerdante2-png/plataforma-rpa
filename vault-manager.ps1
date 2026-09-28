$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root "src\vault.ps1")

function Show-Title {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " MATRIX VAULT - COFRE LOCAL CRIPTOGRAFADO" -ForegroundColor Cyan
    Write-Host " DPAPI CurrentUser | sem segredos no GitHub" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Read-NonEmpty {
    param([string]$Prompt)
    do { $value = Read-Host $Prompt } while ([string]::IsNullOrWhiteSpace($value))
    return $value.Trim()
}

function Import-ZenviaTokenCsv {
    $downloads = Join-Path $env:USERPROFILE "Downloads"
    $candidates = @()

    if (Test-Path -LiteralPath $downloads) {
        $candidates = @(Get-ChildItem -LiteralPath $downloads -Filter "*.csv" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 20)
    }

    if ($candidates.Count -eq 0) {
        throw "Nenhum CSV foi encontrado em Downloads."
    }

    $found = @()

    foreach ($file in $candidates) {
        try {
            $rows = @(Import-Csv -LiteralPath $file.FullName)
            if ($rows.Count -eq 0) { continue }

            $props = @($rows[0].PSObject.Properties.Name)
            $tokenColumn = $props | Where-Object {
                $n = ($_ -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
                $n -in @("XAPITOKEN","APITOKEN","TOKEN")
            } | Select-Object -First 1

            if ($tokenColumn) {
                $tokenValue = ([string]$rows[0].$tokenColumn).Trim()
                if (-not [string]::IsNullOrWhiteSpace($tokenValue)) {
                    $found += [PSCustomObject]@{
                        File = $file
                        TokenColumn = $tokenColumn
                        TokenValue = $tokenValue
                    }
                }
            }
        }
        catch {}
    }

    if ($found.Count -eq 0) {
        throw "Nenhum CSV recente com coluna de token Zenvia foi identificado em Downloads."
    }

    $selected = $found[0]
    Write-Host ("CSV identificado: " + $selected.File.Name) -ForegroundColor DarkGray
    Write-Host "O valor do token NAO sera exibido." -ForegroundColor DarkGray

    $secure = ConvertTo-SecureString $selected.TokenValue -AsPlainText -Force
    [void](Set-MatrixSecret -Id "ZENVIA_ROBO_HORAS" -Secret $secure -Account "5511993581874" -Kind "API_TOKEN" -Provider "ZENVIA" -PlatformRoot $Root)

    $selected.TokenValue = $null
    $secure = $null

    Write-Host ""
    Write-Host "Token Zenvia armazenado no Cofre Matrix com ID ZENVIA_ROBO_HORAS." -ForegroundColor Green

    $delete = Read-Host "Excluir agora o CSV original de Downloads? [S/n]"
    if ([string]::IsNullOrWhiteSpace($delete) -or $delete.Trim().ToUpperInvariant() -eq "S") {
        Remove-Item -LiteralPath $selected.File.FullName -Force
        Write-Host "CSV removido de Downloads." -ForegroundColor Green
    }
    else {
        Write-Host "CSV mantido. Ele continua contendo o token em texto legivel." -ForegroundColor Yellow
    }
}

function Add-GenericSecret {
    $id = Read-NonEmpty "ID logico do segredo (ex.: SISTEMA_USUARIO)"
    $account = Read-Host "Usuario/conta/remetente (opcional)"
    $provider = Read-Host "Sistema/provedor (opcional)"
    $kind = Read-Host "Tipo [PASSWORD/TOKEN/API_TOKEN/SECRET]"
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = "SECRET" }

    $secret = Read-Host "Digite o segredo" -AsSecureString
    $meta = Set-MatrixSecret -Id $id -Secret $secret -Account $account -Kind $kind -Provider $provider -PlatformRoot $Root

    Write-Host ""
    Write-Host ("Segredo salvo: " + $meta.Id) -ForegroundColor Green
}

function List-Secrets {
    $items = @(Get-MatrixSecretList -PlatformRoot $Root)
    if ($items.Count -eq 0) {
        Write-Host "Cofre vazio." -ForegroundColor DarkGray
        return
    }

    Write-Host ("{0,-28} {1,-16} {2,-18} {3}" -f "ID","TIPO","PROVEDOR","CONTA")
    Write-Host ("-" * 90)
    foreach ($item in $items) {
        Write-Host ("{0,-28} {1,-16} {2,-18} {3}" -f $item.Id,$item.Kind,$item.Provider,$item.Account)
    }
}

function Test-SecretInteractive {
    $id = Read-NonEmpty "ID do segredo a testar"
    if (Test-MatrixSecret -Id $id -PlatformRoot $Root) {
        Write-Host "Segredo encontrado e descriptografado com sucesso. Valor nao exibido." -ForegroundColor Green
    }
    else {
        Write-Host "Falha ao localizar/descriptografar o segredo." -ForegroundColor Red
    }
}

function Delete-SecretInteractive {
    $id = Read-NonEmpty "ID do segredo a remover"
    $confirm = Read-Host ("Digite REMOVER para excluir " + $id)
    if ($confirm -cne "REMOVER") {
        Write-Host "Cancelado." -ForegroundColor Yellow
        return
    }

    if (Remove-MatrixSecret -Id $id -PlatformRoot $Root) {
        Write-Host "Segredo removido." -ForegroundColor Green
    }
    else {
        Write-Host "Segredo nao encontrado." -ForegroundColor Yellow
    }
}

[void](Initialize-MatrixVault -PlatformRoot $Root)

while ($true) {
    Show-Title
    Write-Host "1 - Listar credenciais cadastradas (sem mostrar segredos)"
    Write-Host "2 - Adicionar/atualizar uma credencial"
    Write-Host "3 - Importar token Zenvia do CSV em Downloads"
    Write-Host "4 - Testar acesso a uma credencial"
    Write-Host "5 - Remover uma credencial"
    Write-Host "0 - Sair"
    Write-Host ""

    $choice = Read-Host "Opcao"

    try {
        switch ($choice) {
            "1" { List-Secrets }
            "2" { Add-GenericSecret }
            "3" { Import-ZenviaTokenCsv }
            "4" { Test-SecretInteractive }
            "5" { Delete-SecretInteractive }
            "0" { break }
            default { Write-Host "Opcao invalida." -ForegroundColor Yellow }
        }
    }
    catch {
        Write-Host ""
        Write-Host ("ERRO: " + $_.Exception.Message) -ForegroundColor Red
    }

    if ($choice -eq "0") { break }
    Write-Host ""
    Read-Host "Pressione ENTER para continuar"
}
