import SwiftUI

/// Tela de gerenciamento de vocabulário customizado para context biasing
struct VocabularyView: View {
    let appState: AppState
    @Bindable var store: VocabularyStore

    @State private var isApplying = false
    @State private var entryToDelete: VocabularyEntry?
    @State private var applyError: String?

    var body: some View {
        Form {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "Nenhum termo",
                    systemImage: "text.book.closed",
                    description: Text("Adicione termos para melhorar a precisão da transcrição.")
                )
            } else {
                ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                    Section {
                        TextField("Termo correto", text: $store.entries[index].term)

                        // Aliases
                        Section("Aliases") {
                            ForEach(Array(store.entries[index].aliases.enumerated()), id: \.offset) { aliasIndex, _ in
                                HStack {
                                    TextField("Alias", text: $store.entries[index].aliases[aliasIndex])
                                    Button {
                                        store.entries[index].aliases.remove(at: aliasIndex)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            Button("Adicionar alias") {
                                store.entries[index].aliases.append("")
                            }
                        }

                        LabeledContent("Peso") {
                            TextField("Peso", value: $store.entries[index].weight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }

                        Toggle("Ativo", isOn: $store.entries[index].isEnabled)

                        Button("Apagar", role: .destructive) {
                            entryToDelete = entry
                        }
                    }
                }
            }

            if let applyError {
                Label(applyError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulário")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.addEntry(term: "", aliases: [], weight: 10.0)
                } label: {
                    Label("Adicionar Termo", systemImage: "plus")
                }

                Button {
                    applyVocabulary()
                } label: {
                    if isApplying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Aplicar", systemImage: "checkmark.circle")
                    }
                }
                .disabled(isApplying || !appState.isModelReady)
            }
        }
        .alert("Apagar termo?", isPresented: .init(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button("Cancelar", role: .cancel) { entryToDelete = nil }
            Button("Apagar", role: .destructive) {
                if let entry = entryToDelete {
                    store.deleteEntry(entry)
                    entryToDelete = nil
                }
            }
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
    }

    private func applyVocabulary() {
        Task {
            isApplying = true
            applyError = nil
            store.save()
            do {
                try await appState.applyVocabulary()
            } catch {
                applyError = error.localizedDescription
            }
            isApplying = false
        }
    }
}
