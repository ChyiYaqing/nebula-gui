import AppKit
import Network

@MainActor final class ConnectionEnvironment {
    enum Event { case sleep, wake, network(Bool) }
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private let receive: @MainActor (Event) -> Void
    init(receive: @escaping @MainActor (Event) -> Void) {
        self.receive = receive
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.receive(.sleep) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.receive(.wake) }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.receive(.network(path.status == .satisfied)) }
        }
        monitor.start(queue: DispatchQueue(label: "net.nebula.gui.network-path"))
    }
    func stop() {
        monitor.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
