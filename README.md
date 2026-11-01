# Controle de Qualidade

Projeto criado para modernizar a forma de realizar o controle de qualidade dos computadores da **Pichau**, reunindo informações de hardware, discos e drivers em um painel visual para apoiar a conferência das máquinas.

A proposta é tornar a identificação de pendências mais rápida e facilitar o trabalho de quem realiza a qualidade antes da liberação do computador.

## Funcionalidades

- Exibição das principais informações do computador, como processador, memória RAM, placa-mãe e BIOS.
- Consulta das GPUs e dos discos detectados.
- Organização dos dispositivos por categoria, com indicação de drivers faltantes ou com problemas.
- Filtro de dispositivos e consulta de detalhes dos drivers.
- Exportação de Hardware IDs para auxiliar na identificação de drivers.
- Acionamento do atualizador de drivers a partir do painel.
- Atalhos para reiniciar o computador e acessar a BIOS/UEFI, conforme os utilitários disponíveis no ambiente.

## Como executar

1. Baixe ou clone o projeto em um computador com Windows.
2. Mantenha o executável, o `launcher.ps1` e as pastas do projeto juntos.
3. Abra **Controle de Qualidade.exe**.
4. Aguarde a coleta das informações e utilize o painel para conferir a máquina.

O executável inicia um servidor local em PowerShell e abre a interface no navegador. O projeto utiliza Windows PowerShell e comandos de diagnóstico do Windows. A atualização de drivers solicita permissão de administrador quando necessário.

## Obrigatório para atualizar drivers: DriversRepo

> **A opção “Atualizar Drivers” depende de uma pasta chamada `DriversRepo` com os pacotes de drivers. O usuário precisa criar e preencher essa pasta: apenas baixar este projeto ou criar uma pasta vazia não é suficiente.**

A organização recomendada é manter o repositório de drivers dentro de `AtualizarDrivers`:

```text
Controle de Qualidade/
├── Controle de Qualidade.exe
├── launcher.ps1
├── Launcher_Portatil.cs
├── scripts/
├── web/
└── AtualizarDrivers/
    ├── Atualizar Drivers.cmd
    ├── Atualizar Drivers.ps1
    └── DriversRepo/
        ├── AMD/
        ├── INTEL/
        └── NVIDIA/
```

Coloque nas pastas dos fabricantes os pacotes de drivers extraídos, incluindo os arquivos `.inf` e os demais arquivos necessários à instalação. Preserve a estrutura interna de cada pacote. Crie as pastas conforme os fabricantes e os equipamentos que serão atendidos.

O script também procura `DriversRepo` nas pastas superiores e na raiz dos discos locais ou removíveis, como `C:\DriversRepo` e `D:\DriversRepo`.

**Sem um DriversRepo válido, o painel de diagnóstico pode ser utilizado, mas a atualização de drivers será encerrada sem instalar os pacotes.** Nesse caso, o atualizador informa que o repositório não foi encontrado e tenta salvar o diagnóstico em `AtualizarDrivers/AtualizarDrivers_erro.log`.

Os logs de execução do atualizador ficam em `DriversRepo/_Logs` quando o repositório é encontrado. Após a atualização, atualize os dados no painel para conferir o resultado; alguns drivers podem exigir a reinicialização do Windows.

## Estrutura do projeto

| Arquivo ou pasta | Finalidade |
| --- | --- |
| `Controle de Qualidade.exe` | Entrada do aplicativo. |
| `Launcher_Portatil.cs` | Código-fonte do inicializador do aplicativo. |
| `launcher.ps1` | Servidor local e integração entre o painel e os recursos do Windows. |
| `scripts/` | Coleta das informações de diagnóstico. |
| `web/` | Interface do painel. |
| `AtualizarDrivers/` | Scripts responsáveis pela atualização de drivers. |

## Observações de uso

O painel apoia a conferência técnica dos computadores. O resultado exibido deve ser avaliado junto às demais etapas do processo de qualidade, incluindo testes físicos e funcionais.

O atualizador configura o plano de energia para impedir o desligamento automático da tela, a suspensão e a hibernação por tempo de inatividade durante o processo. Revise essas configurações depois, conforme a necessidade do ambiente.
