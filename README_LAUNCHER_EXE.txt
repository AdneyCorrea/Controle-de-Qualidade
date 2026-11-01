COMO GERAR O LAUNCHER EXE PORTATIL
=================================

1) Execute o arquivo: Criar_Launcher_EXE.cmd
2) O script tentara compilar com o csc.exe do .NET Framework.
3) Se nao encontrar o csc.exe, ele tenta usar o dotnet SDK instalado no Windows.
4) O resultado final sera: Controle de Qualidade.exe

Esse EXE:
- usa a logo do pombo como icone embutido
- funciona com letra de pendrive variavel
- abre o launcher.ps1 usando caminho relativo a propria pasta

Se a compilacao ainda falhar:
- instale o .NET Framework 4.x Developer Pack
ou
- instale o .NET SDK (recomendado)
