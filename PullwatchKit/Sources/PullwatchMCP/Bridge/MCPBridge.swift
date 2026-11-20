import Darwin
public import Foundation
import MCP
public import PullwatchCore

/// De logica van de helper `pullwatch-mcp`: een agent start hem met stdio, hij geeft elk bericht
/// door aan de socket van de app en elk antwoord terug, zoals `xcrun mcpbridge` voor Xcode. Wat
/// hij doet hangt af van `AgentAccess` in config.json:
/// - **Nooit**: elk verzoek krijgt een fout die zegt waar het aan kan; de socket blijft dicht.
/// - **Zolang Pullwatch open is**: zonder socket krijgt elk verzoek "Open Pullwatch".
/// - **Altijd**: zonder socket start hij Pullwatch op de achtergrond en wacht op de socket.
///
/// Sluit de app de verbinding (een update van Sparkle start hem opnieuw), dan verbindt de helper
/// één keer opnieuw en doet de handshake van de agent nog eens, zodat de agent er niets van
/// merkt. Hij stopt als stdin sluit.
public struct MCPBridge: Sendable {
    /// Hoe lang de helper wacht.
    public struct Timing: Sendable {
        /// Op de socket na het starten van Pullwatch.
        public var launchWait: Duration
        /// Op de socket nadat de app de verbinding sloot.
        public var reconnectWait: Duration
        /// Tussen twee pogingen om te verbinden.
        public var pollInterval: Duration

        public init(launchWait: Duration, reconnectWait: Duration, pollInterval: Duration) {
            self.launchWait = launchWait
            self.reconnectWait = reconnectWait
            self.pollInterval = pollInterval
        }

        public static let standard = Timing(launchWait: .seconds(25), reconnectWait: .seconds(10), pollInterval: .milliseconds(100))
    }

    /// De foutmeldingen van de helper. Ze zijn voor het model van de agent, dus Engels en niet
    /// vertaald, net als de beschrijvingen van de tools.
    public enum Message {
        public static let turnedOff = "Agents are turned off in Pullwatch: Settings, Agents"
        public static let openPullwatch = "Open Pullwatch to use it from an agent."
        public static let didNotStart = "Pullwatch did not start in time. Open Pullwatch to use it from an agent."
        public static let restarted = "Pullwatch closed the connection while answering. Try again."
        public static let disconnected = "Pullwatch disconnected this agent. Reconnect the agent to Pullwatch (restart its MCP server) to use it again."
    }

    /// De JSON-RPC-foutcode van die meldingen: een serverfout, geen fout in het verzoek.
    public static let unavailableCode = -32000

    /// Het id waaronder de helper na het opnieuw verbinden de `initialize` van de agent herhaalt;
    /// het antwoord daarop gaat niet naar de agent.
    static let replayID: Value = "pullwatch-mcp-reconnect"

    /// Het grootste antwoord van de app dat de helper doorgeeft.
    static let maxResponseBytes = 64 << 20

    private let socketURL: URL
    private let readAccess: @Sendable () -> AgentAccess
    private let launcher: any PullwatchLaunching
    private let timing: Timing
    private let limits: MCPLimits

    /// `readAccess` leest de stand bij de start en opnieuw bij het opnieuw verbinden, zodat een
    /// wijziging in Instellingen meteen telt.
    public init(
        socketURL: URL,
        readAccess: @escaping @Sendable () -> AgentAccess,
        launcher: any PullwatchLaunching,
        timing: Timing = .standard,
        limits: MCPLimits = .standard
    ) {
        self.socketURL = socketURL
        self.readAccess = readAccess
        self.launcher = launcher
        self.timing = timing
        self.limits = limits
    }

    /// De helper zoals hij draait: de socket en config.json in de datamap (ook met
    /// `-PullwatchDataDirectory`).
    public static func standard(launcher: any PullwatchLaunching, defaults: UserDefaults = .standard) -> MCPBridge {
        let configURL = AppPaths.file("config.json", defaults: defaults)
        return MCPBridge(socketURL: UnixSocket.url(defaults: defaults), readAccess: { configuredAccess(at: configURL) }, launcher: launcher)
    }

    /// De stand in config.json. Geen of een onleesbaar bestand is `never`.
    public static func configuredAccess(at configURL: URL) -> AgentAccess {
        ((try? JSONFileStore<AppConfig>(url: configURL).load()) ?? nil)?.agentAccess ?? .never
    }

    // MARK: - Draaien

    /// Leest stdin en schrijft stdout tot stdin sluit.
    public func runOnStandardIO() async {
        do {
            let input = try NonBlockingDescriptor(adopting: STDIN_FILENO)
            let output = try NonBlockingDescriptor(adopting: STDOUT_FILENO)
            await run(input: input.chunks()) { message in
                var line = message
                line.append(UInt8(ascii: "\n"))
                try? await output.write(line)
            }
        } catch {
            FileHandle.standardError.write(Data("pullwatch-mcp: \(error)\n".utf8))
        }
    }

    /// De ruwe bytes van de agent in, elk bericht voor de agent uit (zonder `\n`). Keert terug
    /// als `input` eindigt.
    public func run(input: AsyncStream<Data>, output: @escaping @Sendable (Data) async -> Void) async {
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        await withDiscardingTaskGroup { group in
            group.addTask { [limits] in
                var framer = LineFramer(maxLineBytes: limits.maxMessageBytes)
                for await chunk in input {
                    for line in framer.append(chunk) { sink.yield(.agent(line)) }
                }
                for line in framer.finish() { sink.yield(.agent(line)) }
                sink.yield(.agentClosed)
            }

            var state = State()
            let access = readAccess()
            if access == .never {
                state.refusal = Message.turnedOff
            } else if let connection = await firstConnection(access) {
                state.attach(connection, in: &group, sink: sink)
            } else {
                state.refusal = access == .always ? Message.didNotStart : Message.openPullwatch
            }

            loop: for await event in events {
                switch event {
                case .agentClosed:
                    break loop
                case .agent(.oversized):
                    if let response = try? MCPBoundedTransport.invalidRequest("Message is larger than \(limits.maxMessageBytes) bytes") {
                        await output(response)
                    }
                case .agent(.message(let message)):
                    await state.fromAgent(message, output: output)
                case .app(let generation, let message) where generation == state.generation:
                    await state.fromApp(message, output: output)
                case .appClosed(let generation) where generation == state.generation:
                    await state.answerPending(with: state.refusal ?? Message.restarted, output: output)
                    state.detach()
                    if state.reconnectsLeft > 0 {
                        state.reconnectsLeft -= 1
                        if let connection = await reconnect(&state) {
                            state.attach(connection, in: &group, sink: sink)
                            await state.replayHandshake()
                        }
                    }
                    if state.connection == nil, state.refusal == nil { state.refusal = Message.openPullwatch }
                case .app, .appClosed:
                    // Van een verbinding die al weg is.
                    break
                }
            }
            state.detach()
            group.cancelAll()
        }
    }

    // MARK: - Verbinden

    /// De eerste verbinding: de socket als die er is; bij **Altijd** anders Pullwatch starten en
    /// erop wachten.
    private func firstConnection(_ access: AgentAccess) async -> NonBlockingDescriptor? {
        if let connection = try? UnixSocket.connect(to: socketURL) { return connection }
        guard access == .always else { return nil }
        return await launchAndWait()
    }

    /// Na een gesloten verbinding: wachten tot de app terug is (een update start hem zelf
    /// opnieuw), en bij **Altijd** daarna zelf starten.
    private func reconnect(_ state: inout State) async -> NonBlockingDescriptor? {
        let access = readAccess()
        guard access != .never else {
            state.refusal = Message.turnedOff
            return nil
        }
        if let connection = await waitForSocket(within: timing.reconnectWait) { return connection }
        guard access == .always else { return nil }
        guard let connection = await launchAndWait() else {
            state.refusal = Message.didNotStart
            return nil
        }
        return connection
    }

    private func launchAndWait() async -> NonBlockingDescriptor? {
        do {
            try await launcher.launchPullwatch()
        } catch {
            return nil
        }
        return await waitForSocket(within: timing.launchWait)
    }

    private func waitForSocket(within limit: Duration) async -> NonBlockingDescriptor? {
        let deadline = ContinuousClock.now + limit
        while !Task.isCancelled {
            if let connection = try? UnixSocket.connect(to: socketURL) { return connection }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: timing.pollInterval)
        }
        return nil
    }

    // MARK: - Toestand

    enum Event: Sendable {
        case agent(LineFramer.Line)
        case agentClosed
        case app(generation: Int, Data)
        case appClosed(generation: Int)
    }

    /// Wat de helper bijhoudt: de verbinding, de handshake van de agent om te herhalen, en de
    /// verzoeken die nog op antwoord wachten.
    struct State {
        var connection: NonBlockingDescriptor?
        /// Telt elke verbinding, zodat berichten van een oude verbinding niet meetellen.
        var generation = 0
        var reconnectsLeft = 1
        /// Zonder verbinding: de fout op elk verzoek.
        var refusal: String?
        /// De `initialize` en `notifications/initialized` van de agent, zoals verstuurd.
        var initialize: Data?
        var initialized: Data?
        /// De id's van verzoeken die de app nog moet beantwoorden.
        var pending: Set<Value> = []
        /// Na het opnieuw verbinden: wat de agent stuurde terwijl de herhaalde handshake liep.
        var held: [Data]?

        mutating func attach(
            _ connection: NonBlockingDescriptor, in group: inout DiscardingTaskGroup,
            sink: AsyncStream<Event>.Continuation
        ) {
            generation += 1
            self.connection = connection
            refusal = nil
            let generation = generation
            let chunks = connection.chunks()
            group.addTask {
                var framer = LineFramer(maxLineBytes: MCPBridge.maxResponseBytes)
                for await chunk in chunks {
                    for case .message(let message) in framer.append(chunk) { sink.yield(.app(generation: generation, message)) }
                }
                for case .message(let message) in framer.finish() { sink.yield(.app(generation: generation, message)) }
                sink.yield(.appClosed(generation: generation))
            }
        }

        mutating func detach() {
            connection?.close()
            connection = nil
            held = nil
        }

        mutating func fromAgent(_ message: Data, output: @Sendable (Data) async -> Void) async {
            let parsed = BridgeMessage(message)
            guard let connection else {
                if let id = parsed.requestID {
                    await output(BridgeMessage.error(id: id, message: refusal ?? Message.openPullwatch))
                }
                return
            }
            switch parsed.method {
            case "initialize": initialize = message
            case "notifications/initialized": initialized = message
            default: break
            }
            if let id = parsed.requestID { pending.insert(id) }
            if held != nil {
                held?.append(message)
                return
            }
            await send(message, to: connection)
        }

        mutating func fromApp(_ message: Data, output: @Sendable (Data) async -> Void) async {
            let parsed = BridgeMessage(message)
            if parsed.method == PullwatchDisconnectNotification.name {
                // De persoon koppelde deze agent los: niet opnieuw verbinden, en elk verzoek
                // hoort waarom. De agent zelf krijgt de notificatie niet.
                reconnectsLeft = 0
                refusal = Message.disconnected
                return
            }
            if let id = parsed.responseID {
                if id == MCPBridge.replayID, held != nil {
                    // Het antwoord op de herhaalde handshake: de agent kreeg het zijne al.
                    await finishReplay()
                    return
                }
                pending.remove(id)
            }
            await output(message)
        }

        /// Elk verzoek dat de app niet meer beantwoordt krijgt `message` als fout.
        mutating func answerPending(with message: String, output: @Sendable (Data) async -> Void) async {
            for id in pending.sorted(by: { "\($0)" < "\($1)" }) {
                await output(BridgeMessage.error(id: id, message: message))
            }
            pending.removeAll()
        }

        /// Stuurt de `initialize` van de agent opnieuw, onder een eigen id; wat de agent intussen
        /// stuurt wacht tot het antwoord er is.
        mutating func replayHandshake() async {
            guard let initialize, let connection, let replay = BridgeMessage.replacingID(of: initialize, with: MCPBridge.replayID) else { return }
            held = []
            await send(replay, to: connection)
        }

        private mutating func finishReplay() async {
            let waiting = held ?? []
            held = nil
            guard let connection else { return }
            if let initialized { await send(initialized, to: connection) }
            for message in waiting { await send(message, to: connection) }
        }

        /// Een fout bij schrijven betekent dat de app weg is; dat meldt de lezer van de socket.
        private func send(_ message: Data, to connection: NonBlockingDescriptor) async {
            var line = message
            line.append(UInt8(ascii: "\n"))
            try? await connection.write(line)
        }
    }
}
