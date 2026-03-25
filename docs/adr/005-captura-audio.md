# ADR 005: Captura de Audio — AVAudioEngine

## Status
Aceito

## Contexto
O app precisa capturar audio do microfone em tempo real e converter para o formato esperado pelo Parakeet TDT: 16kHz, mono, float32.

Opcoes no macOS:
- **AVAudioEngine**: Framework de alto nivel da Apple. installTap para captura continua.
- **AVCaptureSession**: Framework de camera/audio. Mais confiavel com Bluetooth.
- **CoreAudio (AudioUnit)**: Baixo nivel, maximo controle, complexo.

## Decisao
Adotamos **AVAudioEngine** com `installTap` e **AVAudioConverter** para resample.

## Justificativa

### API moderna
- `installTap(onBus:bufferSize:format:)` fornece callback continuo com `AVAudioPCMBuffer`
- Integracao direta com `AVAudioConverter` para resample
- API async/await compativel

### Resample
- Microfone entrega 44.1kHz ou 48kHz (depende do hardware)
- Parakeet TDT espera 16kHz mono float32
- `AVAudioConverter` faz a conversao eficientemente (ratio 44100/16000 = 2.75625)

### Permissoes
- `NSMicrophoneUsageDescription` no Info.plist
- macOS pede permissao na primeira captura
- Suporte a troca de microfone em runtime

### Consideracoes importantes
- `installTap` sempre entrega 32-bit float a 44.1kHz independente do format passado
- E necessario reter o AVAudioEngine fortemente (ARC pode desalocar)
- Buffer size de 4096 samples e bom default

## Consequencias

### Positivas
- API simples e bem documentada
- Resample nativo sem dependencias
- Funciona com todos microfones suportados pelo macOS
- Overhead minimo

### Negativas
- Pode falhar com alguns dispositivos Bluetooth (AVCaptureSession seria mais confiavel)
- Nao captura audio do sistema (so microfone) — nao e necessario para nosso caso

## Alternativas rejeitadas
- **CoreAudio direto**: Muito complexo para o beneficio. AVAudioEngine e wrapper suficiente.
- **AVCaptureSession**: Mais confiavel com Bluetooth, mas API mais complexa e focada em video. Pode ser adotada no futuro se houver problemas com Bluetooth.
