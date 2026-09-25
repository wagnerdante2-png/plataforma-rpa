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
