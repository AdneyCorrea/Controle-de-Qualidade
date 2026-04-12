CONTROLE DE QUALIDADE - VERSAO FOTO / ALTA VISIBILIDADE
======================================================

O que foi ajustado:
- visual com foco em legibilidade para fotos
- textos principais maiores
- contraste mais forte em vermelho/preto
- cards e detalhes com leitura mais limpa na tela


Arquivos principais:
- Controle de Qualide.exe
- Executar_App.cmd
- launcher.ps1
- scripts\coletar_dados.ps1
- AtualizarDrivers\Instalar_Drivers_Offline.cmd
- AtualizarDrivers\Instalar_Drivers_Offline.ps1
- web\index.html
- web\assets\styles.css
- web\assets\app.js
- web\assets\logo.png / logo.ico / logo.svg

Observacoes:
- O app continua mantendo o fluxo de leitura de hardware, drivers, discos e wallpaper.
- A parte visual foi reforcada para ficar melhor em fotos de controle de qualidade.


Correcao aplicada:
- O launcher agora usa pasta temporaria em %TEMP% para runtime e perfil do navegador.
- Ao fechar o app, a pasta principal nao fica mais presa pelo navegador nem pelo PowerShell.
