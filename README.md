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

## Seguranca

A Central escuta apenas em `127.0.0.1` e aceita somente IDs existentes em `robots.json`. O navegador nao envia caminhos ou comandos arbitrarios para execucao.

## GitHub Actions

Este projeto nao utiliza GitHub Actions.
