# ADR 009: Overlay Visual com Waveform Reativa

## Status

Aceito

## Contexto

O zspeak precisa de feedback visual durante a gravação para que o usuário saiba que o app está captando áudio e respondendo ao volume da voz. O indicador no menu bar (ícone colorido) é insuficiente — é pequeno, fora do campo de visão e não transmite a sensação de que o app está "ouvindo".

A referência de mercado é o Spokenly, que exibe um overlay flutuante com barras de áudio rolando durante a gravação.

## Decisão

Implementar overlay flutuante durante gravação usando **NSPanel non-activating** com **waveform reativa estilo Spokenly**: barras verticais que rolam da direita para a esquerda, reagindo ao volume da voz em tempo real.

## Alternativas consideradas

### 1. Overlay simples com texto ("Gravando...")

- Feedback mínimo, sem indicação de que o mic está captando
- Não transmite confiança ao usuário
- **Descartado**: UX fraca

### 2. Overlay com círculo pulsante

- Animação genérica, sem relação com o áudio real
- Não diferencia silêncio de fala
- **Descartado**: não reage ao volume, feedback impreciso

### 3. Waveform reativa estilo Spokenly (escolhido)

- Barras rolam da direita para a esquerda simulando áudio sendo gravado
- Amplitude das barras proporcional ao volume da voz (scaling 12x, sensibilidade alta)
- Referência visual conhecida do mercado
- **Escolhido**: melhor UX, feedback de volume em tempo real

## Detalhes técnicos

### NSPanel non-activating

- `NSPanel` com `styleMask: [.nonactivatingPanel]` — não rouba foco do app ativo
- `panel.level = .floating` — sempre visível acima das janelas
- `panel.isMovableByWindowBackground = false` — posição fixa
- Posicionado na parte superior da tela, centralizado

### OverlayModel @Observable

- Model compartilhado entre `AudioCapture` e a view do overlay
- Usa `@Observable` (Observation framework) em vez de `@Published`/`ObservableObject`
- **Motivo**: `@Observable` faz tracking granular por propriedade, evitando re-renders desnecessários e flickering na animação

### Timer de animação

- `Timer` com interval de 22ms (~45 FPS)
- A cada tick: novas barras adicionadas à direita, barras antigas removidas à esquerda
- Amplitude de cada barra calculada a partir do nível de áudio atual do `AudioCapture`

### Informações no overlay

- Ícone e nome do app em foco (capturado pelo `TextInserter` antes de ativar o overlay)
- Branding "zspeak" no canto direito
- Waveform ocupando a área central

## Consequências

### Positivas

- Feedback visual rico e em tempo real durante gravação
- Usuário sabe imediatamente se o mic está captando sua voz
- UX alinhada com referência de mercado (Spokenly)
- Não rouba foco do app ativo (NSPanel non-activating)
- Sem flickering graças ao @Observable com tracking granular

### Negativas

- Timer a 45 FPS consome mais CPU que overlay estático (~1-2% durante gravação)
- Complexidade adicional no pipeline de áudio (expor nível de áudio do AudioCapture)
- NSPanel requer gerenciamento manual de ciclo de vida (show/hide)
