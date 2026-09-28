# Plataforma RPA

Hub local para centralizar automacoes pontuais em Windows.

## Premissas

- execucao 100% local;
- interface no navegador em `127.0.0.1`;
- PowerShell nativo do Windows;
- sem Python;
- sem instalacao de bibliotecas;
- sem banco externo;
- sem GitHub Actions;
- cada robo continua independente e e acionado pelo seu proprio `.cmd`.

## Como iniciar

1. Baixe/extrai o repositorio.
2. Execute `Iniciar Central.cmd`.
3. A interface abre automaticamente em `http://127.0.0.1:8765`.
4. Fechar a janela da Central encerra o servidor local.

## Catalogo de robos

Os robos sao cadastrados em `robots.json`.

Nesta primeira versao o catalogo esta vazio. Os robos existentes serao conectados na proxima etapa sem incorporá-los ao nucleo da plataforma.

## Estrutura

- `Iniciar Central.cmd` - inicializador local.
- `central.ps1` - servidor HTTP local e executor seguro.
- `robots.json` - catalogo declarativo.
- `web/` - interface Matrix/hacker.
- `downloads/` - arquivos operacionais locais entregues pela Central (ignorado pelo Git).
- `apps/` - aplicações web locais acopladas pela Central (ignorado pelo Git).

## Seguranca

A Central escuta apenas em `127.0.0.1` e aceita somente IDs existentes em `robots.json`. O navegador nao envia caminhos ou comandos arbitrarios para execucao.

## GitHub Actions

Este projeto nao utiliza GitHub Actions.

## Recursos operacionais locais

A Central cria automaticamente a pasta `downloads/`.

Para habilitar o card **Escala de Folgas**, coloque a versão corporativa aprovada com o nome exato:

`downloads/Escala de Folgas.xlsm`

O arquivo não faz parte do repositório Git. No empacotamento corporativo definitivo, ele poderá compor o pacote operacional ao lado da Central.

### Aderência de Escala

O terceiro card de recursos acopla a aplicação `aderencia-escala` no primeiro acesso.
A cópia operacional fica em `apps/aderencia-escala/` e é servida pela própria Central em `/apps/aderencia-escala/`.
A pasta `.github` e a pasta `tests` do repositório de origem não são copiadas para o pacote operacional.


## Robos em repositorios privados

A Central suporta fontes privadas no catalogo `robots.json` usando `"privateRepository": true`.

Para instalar um robo privado, a maquina precisa possuir uma credencial GitHub local valida. A Central procura, nesta ordem:

1. variavel de ambiente `GH_TOKEN`;
2. variavel de ambiente `GITHUB_TOKEN`;
3. sessao existente do GitHub CLI (`gh auth token`);
4. credencial ja armazenada no Git Credential Manager.

O token nao e gravado em `robots.json`, no repositorio ou nos logs.

O Robo Horas v1.2 e instalado em `robots\robo-horas-v1.2` a partir do repositorio privado `wagnerdante2-png/robo-horas`. A base real de contatos acompanha esse pacote privado; nenhum telefone e armazenado no repositorio publico da Matrix.


## Cofre Matrix

A plataforma inclui um cofre local criptografado para senhas, tokens e outras credenciais usadas pelos robos.

Arquivos:
- `src\vault.ps1` — motor do cofre;
- `vault-manager.ps1` — gerenciamento interativo;
- `Cofre Matrix.cmd` — launcher para cadastro/manutencao.

Os dados reais sao criados somente em:

`private\vault\vault.json`

A pasta `private\` e ignorada pelo Git e nao deve ser enviada para repositorios, e-mails ou compartilhamentos.

### Protecao

- segredos criptografados com Windows DPAPI;
- escopo `CurrentUser`: somente o mesmo usuario Windows que cadastrou o segredo consegue descriptografa-lo;
- ACL privada aplicada ao diretorio e ao arquivo;
- valores nunca sao exibidos pela listagem do cofre;
- o JSON guarda apenas metadados e o texto cifrado.

### Token Zenvia do Robo Horas

Abra `Cofre Matrix.cmd` e use:

`3 - Importar token Zenvia do CSV em Downloads`

O gerenciador identifica um CSV recente que contenha coluna de token, importa o valor sem exibi-lo e salva com o ID:

`ZENVIA_ROBO_HORAS`

Conta/remetente associada:

`5511993581874`

Apos a importacao, o gerenciador oferece remover o CSV original de Downloads para evitar manter o token em texto legivel.

### Consulta por um robo

Um robo instalado dentro da Matrix pode carregar o modulo e consultar um segredo pelo ID logico:

```powershell
$matrixRoot = Split-Path -Parent (Split-Path -Parent $Root)
. (Join-Path $matrixRoot "src\vault.ps1")

$token = Get-MatrixSecretValue -Id "ZENVIA_ROBO_HORAS" -PlatformRoot $matrixRoot
try {
    # usar $token apenas na chamada da API; nunca registrar em log
}
finally {
    $token = $null
}
```

Para verificacoes sem revelar o valor, use `Test-MatrixSecret` ou `Get-MatrixSecretMetadata`.
