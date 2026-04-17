import Foundation

/// Traduz erros técnicos (OSStatus, domínios opacos) para mensagens que o
/// usuário final consegue agir. Centralizar aqui evita espalhar `switch`s de
/// códigos de erro nas Views.
enum ErrorMapper {
    static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        // OSStatus conhecidos
        if ns.domain == NSOSStatusErrorDomain {
            switch ns.code {
            case -10868: return "Formato de áudio incompatível com o microfone selecionado. Tente trocar de dispositivo."
            case -10851: return "Propriedade de áudio inválida."
            case -10877: return "Dispositivo de áudio indisponível."
            case -10875: return "Dispositivo de áudio ocupado por outro app."
            case -10863: return "Hardware não suportado."
            case -50: return "Parâmetro inválido."
            case -66681: return "Falha ao iniciar o motor de áudio."
            default: break
            }
        }
        if let localized = error as? LocalizedError, let desc = localized.errorDescription { return desc }
        return "Erro inesperado (código \(ns.code))"
    }
}
