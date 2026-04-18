import Foundation
import Testing
@testable import zspeak

@Suite("PreRollBuffer - ring circular thread-safe")
struct PreRollBufferTests {

    @Test("Snapshot de buffer recém-criado é vazio")
    func snapshotVazioInicial() {
        let buffer = PreRollBuffer(capacity: 100)
        #expect(buffer.snapshot().isEmpty)
    }

    @Test("Append abaixo da capacidade preserva ordem cronológica")
    func appendAbaixoDaCapacidade() {
        let buffer = PreRollBuffer(capacity: 10)
        buffer.append([1.0, 2.0, 3.0])

        let snapshot = buffer.snapshot()
        #expect(snapshot == [1.0, 2.0, 3.0])
    }

    @Test("Append exatamente na capacidade devolve tudo em ordem")
    func appendExatamenteNaCapacidade() {
        let buffer = PreRollBuffer(capacity: 4)
        buffer.append([1.0, 2.0, 3.0, 4.0])

        let snapshot = buffer.snapshot()
        #expect(snapshot == [1.0, 2.0, 3.0, 4.0])
    }

    @Test("Append acima da capacidade mantém os N últimos em ordem cronológica")
    func appendAcimaDaCapacidade() {
        let buffer = PreRollBuffer(capacity: 4)
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0, 6.0])

        let snapshot = buffer.snapshot()
        #expect(snapshot == [3.0, 4.0, 5.0, 6.0])
    }

    @Test("Appends sucessivos mantêm janela móvel correta")
    func appendsSucessivos() {
        let buffer = PreRollBuffer(capacity: 3)
        buffer.append([1.0, 2.0])
        buffer.append([3.0, 4.0])
        buffer.append([5.0])

        let snapshot = buffer.snapshot()
        #expect(snapshot == [3.0, 4.0, 5.0])
    }

    @Test("Clear zera o conteúdo")
    func clearZeraConteudo() {
        let buffer = PreRollBuffer(capacity: 10)
        buffer.append([1.0, 2.0, 3.0])
        buffer.clear()

        #expect(buffer.snapshot().isEmpty)
    }

    @Test("Clear + append após overflow entrega apenas o novo conteúdo")
    func clearAposOverflow() {
        let buffer = PreRollBuffer(capacity: 3)
        buffer.append([1.0, 2.0, 3.0, 4.0, 5.0])
        buffer.clear()
        buffer.append([9.0, 8.0])

        #expect(buffer.snapshot() == [9.0, 8.0])
    }

    @Test("Append vazio é no-op")
    func appendVazio() {
        let buffer = PreRollBuffer(capacity: 5)
        buffer.append([1.0, 2.0])
        buffer.append([])

        #expect(buffer.snapshot() == [1.0, 2.0])
    }

    @Test("Capacidade zero retorna sempre vazio")
    func capacidadeZero() {
        let buffer = PreRollBuffer(capacity: 0)
        buffer.append([1.0, 2.0, 3.0])

        #expect(buffer.snapshot().isEmpty)
    }

    @Test("Capacidade típica do app (500 ms a 16 kHz = 8000 samples)")
    func capacidadeDoApp() {
        let buffer = PreRollBuffer(capacity: 8_000)

        // Alimenta 1 segundo de áudio sintético — deve sobrescrever o primeiro meio segundo
        var samples = [Float](repeating: 0, count: 16_000)
        for i in 0..<samples.count { samples[i] = Float(i) }
        buffer.append(samples)

        let snapshot = buffer.snapshot()
        #expect(snapshot.count == 8_000)
        // Primeiros samples do snapshot devem ser os segundos 8000 do input
        #expect(snapshot.first == 8_000)
        #expect(snapshot.last == 15_999)
    }

    @Test("Escritas concorrentes não corrompem o buffer")
    func escritasConcorrentes() async {
        let buffer = PreRollBuffer(capacity: 1_000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let chunk = [Float](repeating: 1.0, count: 200)
                    for _ in 0..<20 {
                        buffer.append(chunk)
                    }
                }
            }
        }

        let snapshot = buffer.snapshot()
        // Sobrescreveu muito conteúdo — apenas valida que o tamanho é consistente
        // e que nenhum sample é NaN/valor lixo.
        #expect(snapshot.count == 1_000)
        #expect(snapshot.allSatisfy { $0 == 1.0 })
    }
}

@Suite("AtomicBool - flag thread-safe")
struct AtomicBoolTests {

    @Test("Valor inicial é false")
    func valorInicialFalse() {
        let flag = AtomicBool()
        #expect(flag.current == false)
    }

    @Test("Set true é refletido na leitura")
    func setTrue() {
        let flag = AtomicBool()
        flag.set(true)
        #expect(flag.current == true)
    }

    @Test("Set false após set true volta para false")
    func setFalseAposTrue() {
        let flag = AtomicBool()
        flag.set(true)
        flag.set(false)
        #expect(flag.current == false)
    }

    @Test("Leituras e escritas concorrentes não crasheiam e retornam booleano válido")
    func concorrenciaSemCrash() async {
        let flag = AtomicBool()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { flag.set(i.isMultiple(of: 2)) }
                group.addTask { _ = flag.current }
            }
        }

        // Apenas verifica que não quebrou — valor final é indefinido mas deve ser Bool.
        let finalValue = flag.current
        #expect(finalValue == true || finalValue == false)
    }
}
