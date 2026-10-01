import Foundation
import Testing

@testable import LitmusCore

@Suite("Network jitter")
struct NetworkJitterTests {
    @Test("holds back an awaited URLSession call")
    func wrapsAwaitedCall() {
        let source = """
        func load(_ session: URLSession, _ request: URLRequest) async throws -> Data {
            let (data, _) = try await session.data(for: request)
            return data
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 300)

        #expect(calls == 1)
        #expect(rewritten.contains("try await __litmus_jitter(300, session, { try await session.data(for: request) })"))
        #expect(rewritten.components(separatedBy: "private func __litmus_jitter").count == 2)
    }

    @Test("holds back each kind of call, and the helper is declared once")
    func wrapsEveryKind() {
        let source = """
        func f(_ s: URLSession, _ r: URLRequest, _ u: URL, _ d: Data) async throws {
            _ = try await s.data(from: u)
            _ = try await s.upload(for: r, from: d)
            _ = try await s.download(for: r)
            _ = try await s.bytes(from: u)
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 50)

        #expect(calls == 4)
        #expect(rewritten.components(separatedBy: "private func __litmus_jitter").count == 2)
    }

    /// The session is named again for the helper to look at, so only when
    /// naming it again cannot make another one.
    @Test("passes the session when naming it again is free, and nil when it is a call")
    func passesSession() {
        let source = """
        func f(_ r: URLRequest) async throws {
            _ = try await URLSession.shared.data(for: r)
            _ = try await self.client.session.data(for: r)
            _ = try await makeSession().data(for: r)
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 0)

        #expect(calls == 3)
        #expect(rewritten.contains("__litmus_jitter(0, URLSession.shared, {"))
        #expect(rewritten.contains("__litmus_jitter(0, self.client.session, {"))
        #expect(rewritten.contains("__litmus_jitter(0, nil, { try await makeSession().data(for: r) })"))
    }

    /// What follows the call goes in the closure with it, so it still applies.
    @Test("holds back a call followed by a tuple element, an unwrap or a member")
    func wrapsWhatFollows() {
        let source = """
        func f(_ s: URLSession, _ u: URL) async {
            let data = try? await s.data(from: u).0
            let size = try! await s.data(from: u).0.count
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 0)

        #expect(calls == 2)
        #expect(rewritten.contains("try? await __litmus_jitter(0, s, { try await s.data(from: u).0 })"))
        #expect(rewritten.contains("try! await __litmus_jitter(0, s, { try await s.data(from: u).0.count })"))
    }

    @Test("holds back the value of an async let")
    func wrapsAsyncLet() {
        let source = """
        func f(_ s: URLSession, _ u: URL) async throws {
            async let first = s.data(from: u)
            async let other = compute()
            _ = try await (first, other)
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 200)

        #expect(calls == 1)
        #expect(rewritten.contains("async let first = __litmus_jitter(200, s, { try await s.data(from: u) })"))
        #expect(rewritten.contains("async let other = compute()"))
    }

    @Test("calls a completion handler late, trailing or labelled")
    func wrapsHandlers() {
        let source = """
        func f(_ s: URLSession, _ r: URLRequest) {
            s.dataTask(with: r) { data, _, _ in print(data as Any) }.resume()
            s.downloadTask(with: r, completionHandler: { url, _, _ in print(url as Any) }).resume()
            s.dataTask(with: r).resume()
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 200)

        #expect(calls == 2)
        #expect(rewritten.contains("s.dataTask(with: r, completionHandler: __litmus_jitter_handler(200, s, { data, _, _ in print(data as Any) })).resume()"))
        #expect(rewritten.contains("s.downloadTask(with: r, completionHandler: __litmus_jitter_handler(200, s, { url, _, _ in print(url as Any) })).resume()"))
        #expect(rewritten.contains("s.dataTask(with: r).resume()"))
    }

    @Test("delays what a data task publisher sends")
    func wrapsPublisher() {
        let source = """
        func f(_ s: URLSession, _ u: URL) -> AnyPublisher<Data, URLError> {
            s.dataTaskPublisher(for: u)
                .map(\\.data)
                .eraseToAnyPublisher()
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 200)

        #expect(calls == 1)
        #expect(rewritten.contains("__litmus_jitter_publisher(200, s, s.dataTaskPublisher(for: u))"))
        #expect(rewritten.hasPrefix("import Combine\n"))
    }

    @Test("leaves a task with no handler, an unawaited call and another label alone")
    func leavesOthers() {
        let source = """
        func f(_ s: URLSession, _ r: URLRequest, _ cache: Cache) async {
            s.dataTask(with: r).resume()
            let task = s.data(for: r)
            _ = await cache.data(named: "x")
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 300)

        #expect(calls == 0)
        #expect(rewritten == source)
    }

    /// The point of `#isolation`: a call on the main actor has to stay
    /// there, and Swift 6 refuses to send a closure that captures `self`
    /// anywhere else.
    @Test("what it writes type-checks on the main actor in Swift 6")
    func typeChecks() throws {
        let source = """
        import Combine
        import Foundation

        @MainActor
        final class Feed {
            let session: URLSession
            var items: [String] = []

            init(session: URLSession) { self.session = session }

            func refresh(_ url: URL) async throws {
                let (data, _) = try await session.data(from: url)
                items = [String(decoding: data, as: UTF8.self)]
            }

            func both(_ a: URL, _ b: URL) async throws {
                async let first = session.data(from: a)
                async let second = session.data(from: b)
                let (x, y) = try await (first, second)
                items = [String(decoding: x.0 + y.0, as: UTF8.self)]
            }

            func old(_ url: URL) {
                session.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data else { return }
                    Task { @MainActor in self?.items = [String(decoding: data, as: UTF8.self)] }
                }.resume()
                session.downloadTask(with: url, completionHandler: { location, _, _ in
                    print(location as Any)
                }).resume()
            }

            func later(_ url: URL) -> AnyPublisher<String, URLError> {
                session.dataTaskPublisher(for: url)
                    .map { String(decoding: $0.data, as: UTF8.self) }
                    .eraseToAnyPublisher()
            }

            // In a condition, where a trailing closure would read as the
            // statement's body.
            func search(_ url: URL) async {
                guard let (data, _) = try? await session.data(from: url) else { return }
                if let (more, _) = try? await session.data(from: url), more.count > data.count {
                    items.append("more")
                }
            }
        }
        """

        let (rewritten, calls) = NetworkJitter.apply(to: source, upTo: 300)
        #expect(calls == 8)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-jitter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Feed.swift")
        try rewritten.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-typecheck", "-swift-version", "6", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "\(output)")
    }
}
