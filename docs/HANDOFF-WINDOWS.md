# Handoff — zspeak para Windows

> **Estado em 16/07/2026:** o P0 descrito neste handoff foi implementado na
> `main`. A solution, o aplicativo WPF, o spike sherpa-onnx, o instalador, os
> testes e os benchmarks estão em [`windows/`](../windows/). Este documento
> permanece como registro das decisões e critérios usados no port.

## Objetivo

Criar uma versão nativa do zspeak para Windows, no mesmo repositório, mantendo o app macOS intacto. O primeiro marco deve entregar o fluxo 100% local:

`Microfone -> PCM mono 16 kHz float32 -> Parakeet TDT 0.6B V3 -> Clipboard -> Ctrl+V`

Este documento é o ponto de partida para o Codex executado no computador Windows.

## Estado do código macOS na avaliação inicial

O projeto macOS não pode ser apenas compilado no Windows. Ele foi construído em Swift/SwiftUI e depende de tecnologias Apple:

- `AppKit` e `SwiftUI` para tray, janelas e overlay;
- `AVFoundation`, `CoreAudio` e `Accelerate` para captura e processamento de áudio;
- `CoreML` e Apple Neural Engine via FluidAudio para ASR, VAD e diarização;
- `MLX` e `Metal` para o LLM local;
- `CGEvent`, Accessibility API e `NSPasteboard` para hotkeys, seleção e inserção;
- `KeyboardShortcuts` e `LaunchAtLogin`, também específicos do macOS.

O trabalho é um port por comportamento, não uma adaptação condicional do mesmo executável Swift.

## Decisão inicial recomendada

Criar uma solução independente em `windows/`, sem modificar o target Swift nem o `Package.swift`:

```text
windows/
├── ZSpeak.Windows.sln
├── src/
│   ├── ZSpeak.App/          # WPF, tray, overlay e composição
│   ├── ZSpeak.Core/         # regras sem dependência de UI/SO
│   └── ZSpeak.Platform/     # áudio, hotkey, clipboard e Win32
├── tests/
│   ├── ZSpeak.Core.Tests/
│   └── ZSpeak.IntegrationTests/
├── scripts/
└── README.md
```

Stack inicial:

- Windows 11 x64 como alvo inicial;
- C# e .NET 8;
- WPF para reduzir risco no tray/overlay e permitir interop Win32 maduro;
- `NotifyIcon` para tray;
- NAudio estável 2.x/WASAPI para captura, dispositivos e resampling;
- `RegisterHotKey` para atalhos simples e hook de baixo nível somente quando `Hold` ou `Double Tap` exigirem key-up;
- Clipboard do Windows e `SendInput` para `Ctrl+V`;
- Startup Task empacotado ou chave `HKCU`, conforme a distribuição escolhida;
- sherpa-onnx C# como primeira prova do backend ASR.

Não usar Swift for Windows para a interface: SwiftUI, AppKit, FluidAudio/CoreML e MLX continuariam ausentes.

## Spike obrigatório do ASR

Antes de construir toda a interface, criar um console app que:

1. baixa ou localiza o Parakeet TDT 0.6B V3 em formato compatível;
2. valida o download e mantém cache em `%LOCALAPPDATA%\zspeak\Models`;
3. transcreve `Tests/Fixtures/pt-short.wav` e `Tests/Fixtures/pt-long.wav` offline;
4. mede carregamento, pico de memória e real-time factor em CPU;
5. confirma português e termos técnicos em inglês;
6. executa pela segunda vez com a rede desativada.

Candidato principal: sherpa-onnx com `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8`. O projeto oferece Windows x64/arm64 e binding C#, mas o V3 é não-streaming. Preview parcial fica fora do primeiro marco ou usa pseudo-streaming somente após benchmark.

Alternativa de spike: modelo OpenVINO `FluidInference/parakeet-tdt-0.6b-v3-ov`. Não adotar como definitivo antes de provar integração C#, distribuição e desempenho na máquina-alvo.

Se nenhum caminho atingir qualidade e latência aceitáveis, registrar os números e comparar outro backend local. Não trocar silenciosamente o Parakeet V3 nem introduzir cloud.

## Mapeamento macOS -> Windows

| Comportamento | Código atual | Implementação Windows |
|---|---|---|
| Captura do microfone | `AudioCapture.swift`, `MicrophoneManager.swift` | NAudio/WASAPI, seleção por ID persistente |
| Resampling | `StreamingResampler.swift` | NAudio/WDL ou Media Foundation, mono 16 kHz float32 |
| ASR local | `Transcriber.swift`, FluidAudio/CoreML | sherpa-onnx C# + Parakeet V3 ONNX |
| Hotkey global | `HotkeyManager.swift` | `RegisterHotKey`; hook Win32 só quando necessário |
| Colar no app ativo | `TextInserter.swift` | Clipboard + `SendInput(Ctrl+V)` e restauração segura |
| App em tray | `AppLifecycle.swift`, `MenuBarView.swift` | WPF + `NotifyIcon`, processo em background |
| Overlay | `OverlayPanel.swift`, `OverlayView.swift` | janela WPF transparente, topmost e sem ativar foco |
| Histórico/configurações | stores Swift + `UserDefaults` | JSON versionado em `%LOCALAPPDATA%\zspeak` |
| Iniciar com sistema | `LaunchAtLogin` | Startup Task ou `HKCU` por usuário |
| Leitura da seleção | `SelectedTextReader.swift` | UI Automation; fallback por `Ctrl+C` com restauração |
| LLM local | `LLMCorrectionManager.swift`, MLX | fora do P0; backend local após spike separado |
| Diarização | FluidAudio/CoreML | fora do P0; avaliar sherpa-onnx sem bloquear o MVP |

## Regras e fixtures reutilizáveis

O Swift não deve ser copiado mecanicamente, mas estas regras podem ser portadas:

- normalização PT-BR de `PTBRTextNormalizer.swift`;
- vocabulário e aliases de `VocabularyStore.swift`;
- VAD/trimming de `VADSpeechTrimmer.swift`, `SpeechSampleTrimmer.swift` e `SpeechSignalConditioner.swift`;
- pre-roll e buffers de `AudioCapture.swift`;
- estados e cancelamento de `RecordingController.swift`;
- persistência/migração de `TranscriptionStore.swift`;
- proteção de clipboard de `ClipboardSnapshot.swift` e `TextInserter.swift`;
- métricas e WAVs em `Tests/Fixtures`.

Para cada regra portada, criar teste equivalente em C# antes ou junto da implementação.

## Ordem de execução

### P0 — MVP utilizável

1. Criar solution e CI Windows sem tocar no build macOS.
2. Provar o ASR V3 offline no console e registrar benchmark.
3. Capturar microfone escolhido e converter para mono 16 kHz float32.
4. Implementar hotkey global `Toggle` com detecção de conflito.
5. Transcrever, copiar e enviar `Ctrl+V` ao app anteriormente focado.
6. Criar tray com estados `carregando`, `pronto`, `gravando`, `transcrevendo` e `erro`.
7. Persistir configurações e histórico local.
8. Empacotar x64 e validar em usuário Windows sem ferramentas de desenvolvimento.

### P1 — paridade prática

- modos `Hold` e `Double Tap`;
- seleção e prioridade de microfones;
- pre-roll, VAD e tratamento de silêncio/clipping;
- overlay sem roubar foco;
- vocabulário personalizado e normalização PT-BR;
- transcrição de arquivo de áudio/vídeo com FFmpeg empacotado/licenciado;
- restauração segura do clipboard;
- iniciar com o Windows.

### P2 — recursos avançados

- preview ao vivo, somente se o benchmark não degradar o fluxo;
- leitura/tradução do texto selecionado via UI Automation;
- LLM local para correção e Prompt Mode;
- diarização e nomes de speakers;
- benchmark visual e demais telas avançadas.

## Critérios de aceite do P0

- Funciona em Windows 11 x64 sem Xcode, Python ou Visual Studio instalados.
- Primeira execução baixa o modelo com progresso, cancelamento e erro recuperável.
- Execuções posteriores funcionam completamente sem internet.
- Nenhum áudio, texto, métrica ou telemetria sai da máquina.
- Hotkey inicia e encerra a gravação com outro aplicativo em foco.
- O texto PT-BR é colocado no aplicativo que estava em foco.
- Falha de `SendInput` não perde o texto: ele permanece no clipboard.
- Microfone removido durante a captura não derruba o processo.
- Uma segunda instância não registra hotkey nem corrompe configurações.
- Modelo, DLLs nativas, licença e arquitetura são validados no empacotamento.

## Testes e gates obrigatórios

```powershell
dotnet restore windows/ZSpeak.Windows.sln
dotnet build windows/ZSpeak.Windows.sln -c Release --no-restore
dotnet test windows/ZSpeak.Windows.sln -c Release --no-build
```

Cobertura mínima:

- unitários: normalização, vocabulário, estados, buffers, VAD, settings e histórico;
- integração: WAV fixture para texto não vazio e expectativa PT-BR;
- integração offline: cache pré-carregado com rede bloqueada;
- integração Win32: registro/desregistro da hotkey e conflito conhecido;
- integração de clipboard: preservar conteúdo e não apagar resultado em falha;
- smoke test empacotado em Windows Sandbox ou VM limpa;
- CI Windows separada, mantendo a CI/testes macOS.

Não declarar paridade apenas com build verde. Gravação real, foco, paste e execução offline precisam de cobertura automatizada e smoke test no Windows.

## Restrições

- Manter 100% local, sem API keys, sidecar obrigatório ou envio de dados.
- Não remover nem reescrever o app macOS durante o port.
- Não commitar modelos, DLLs sem licença, caches, áudio do usuário ou builds.
- Confirmar licença e redistribuição de cada dependência.
- Fixar versões após o spike e registrar hashes dos downloads.
- Preservar comentários e comunicação em português.
- Incrementar a versão patch a cada alteração entregue.
- Fazer commits pequenos e não publicar implementação incompleta como pronta.

## Referências verificadas em 15/07/2026

- [FluidAudio — Apple Platforms e alternativa Windows em desenvolvimento](https://github.com/FluidInference/FluidAudio)
- [sherpa-onnx — Windows x64/arm64 e binding C#](https://github.com/k2-fsa/sherpa-onnx)
- [Parakeet TDT V3 — 25 idiomas e CC BY 4.0](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [Parakeet V3 convertido para OpenVINO](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-ov)
- [NAudio — WASAPI e áudio para .NET](https://github.com/naudio/NAudio)
- [Windows App SDK](https://learn.microsoft.com/windows/apps/windows-app-sdk/)
- [Win32 `RegisterHotKey`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-registerhotkey)
- [Win32 `SendInput`](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-sendinput)

## Prompt pronto para o Codex no Windows

```text
Você está no Windows, dentro do repositório zspeak. Leia primeiro AGENTS.md, docs/HANDOFF-WINDOWS.md, README.md, Package.swift e docs/versioning.md.

Objetivo: executar o port nativo do zspeak para Windows sem alterar nem quebrar o app macOS. Trabalhe em C#/.NET 8 dentro de windows/, seguindo as fases, restrições, testes e critérios de aceite do handoff.

Comece verificando git status, branch, remote, arquitetura/versão do Windows, SDK .NET e Visual Studio Build Tools. Depois faça somente o spike obrigatório do ASR: crie a estrutura mínima da solution, integre um candidato Windows para Parakeet TDT 0.6B V3, transcreva as fixtures PT-BR, prove a segunda execução offline e registre carregamento, memória e real-time factor. Não construa toda a UI antes de aprovar esse gate.

Se o V3 não funcionar, documente a causa com comandos e números. Compare a alternativa OpenVINO indicada no handoff, mas não troque o modelo, não use cloud e não afirme sucesso sem teste real.

Ao concluir cada marco: rode build/testes, revise o diff, atualize a versão patch, preserve alterações preexistentes e apresente resultado, riscos e próximo gate. Não faça push, PR, merge ou release sem autorização explícita nessa conversa.
```
