import SwiftUI

/// Identificador da Window Scene de transcrição de arquivo — mantido em
/// constante para não divergir entre App.swift (declaração) e MenuBarView
/// (openWindow(id:)).
enum AudioFileWindowID {
    static let value: String = "audio-file"
}

/// Conteúdo da janela flutuante de transcrição de arquivo.
///
/// Lê dependências via `@Environment` (AppState, TranscriptionStore) e encaminha
/// para `AudioFileView`, que já existe e é reutilizada sem modificações.
struct AudioFileWindowContent: View {
    @Environment(AppState.self) private var appState
    @Environment(TranscriptionStore.self) private var store

    var body: some View {
        AudioFileView(appState: appState, store: store)
            .frame(minWidth: 640, minHeight: 520)
            .navigationTitle("Transcrever arquivo")
    }
}
