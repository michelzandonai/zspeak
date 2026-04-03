import Testing
@testable import zspeak

@Suite("SynchronizedBuffer — thread-safe audio buffer")
struct SynchronizedBufferTests {

    // MARK: - Estado inicial

    @Test("Buffer novo deve estar vazio")
    func testInitialState() {
        let buffer = SynchronizedBuffer()
        #expect(buffer.count == 0)
        #expect(buffer.drain().isEmpty)
    }

    // MARK: - Append e drain

    @Test("append adiciona samples e drain retorna todos")
    func testAppendAndDrain() {
        let buffer = SynchronizedBuffer()

        buffer.append([1.0, 2.0, 3.0])
        buffer.append([4.0, 5.0])

        #expect(buffer.count == 5)

        let result = buffer.drain()
        #expect(result == [1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(buffer.count == 0)
    }

    @Test("drain retorna vazio se nada foi appendado")
    func testDrainEmpty() {
        let buffer = SynchronizedBuffer()
        let result = buffer.drain()
        #expect(result.isEmpty)
    }

    @Test("drain esvazia o buffer — segundo drain retorna vazio")
    func testDrainClearsBuffer() {
        let buffer = SynchronizedBuffer()
        buffer.append([1.0, 2.0])

        let first = buffer.drain()
        let second = buffer.drain()

        #expect(first == [1.0, 2.0])
        #expect(second.isEmpty)
    }

    // MARK: - Clear

    @Test("clear esvazia o buffer")
    func testClear() {
        let buffer = SynchronizedBuffer()
        buffer.append([1.0, 2.0, 3.0])
        #expect(buffer.count == 3)

        buffer.clear()
        #expect(buffer.count == 0)
        #expect(buffer.drain().isEmpty)
    }

    // MARK: - Concorrência

    @Test("append de múltiplas threads não perde dados")
    func testConcurrentAppend() async {
        let buffer = SynchronizedBuffer()
        let iterations = 1000
        let threadCount = 4

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<threadCount {
                group.addTask {
                    for _ in 0..<iterations {
                        buffer.append([1.0])
                    }
                }
            }
        }

        let result = buffer.drain()
        #expect(result.count == threadCount * iterations)
    }

    @Test("append e drain concorrentes não crasham")
    func testConcurrentAppendAndDrain() async {
        let buffer = SynchronizedBuffer()
        var totalDrained = 0

        await withTaskGroup(of: Int.self) { group in
            // Writer: appenda continuamente
            group.addTask {
                for _ in 0..<500 {
                    buffer.append([1.0, 2.0])
                }
                return 0
            }

            // Reader: drena periodicamente
            group.addTask {
                var count = 0
                for _ in 0..<50 {
                    count += buffer.drain().count
                    try? await Task.sleep(for: .microseconds(100))
                }
                // Drena restante
                count += buffer.drain().count
                return count
            }

            for await count in group {
                totalDrained += count
            }
        }

        // Total deve ser 1000 (500 appends * 2 samples cada)
        #expect(totalDrained == 1000)
    }
}
