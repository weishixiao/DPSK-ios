import Foundation

/// The app half of the privileged service.
///
/// The app never runs a privileged syscall itself: it sends JSON over the Mach
/// service the launchd job registers, and reads the answer back. Everything
/// that decides what is allowed lives on the far side of that connection.
final class IOSAgentClient {
  static let serviceName = "io.github.ccch1mneyyy.dshgo.agentd"

  private var connection: NSXPCConnection?

  /// Whether the daemon is installed and answering.
  var isAvailable: Bool {
    connection != nil
  }

  private func connected() -> NSXPCConnection? {
    if let existing = connection { return existing }
    // `NSXPCConnection(machServiceName:options:)` is unavailable in the iOS
    // SDK, but the selector ships in the Foundation runtime. Reach it through
    // the ObjC runtime - the same pattern IOSPhoneControl uses to resolve
    // PhoneRunnerSupport - so a host with the daemon installed connects, and
    // a build without the daemon degrades to "unavailable".
    let selector = NSSelectorFromString("initWithMachServiceName:options:")
    guard let type = NSClassFromString("NSXPCConnection") as? NSObject.Type,
          let method = class_getInstanceMethod(type, selector) else {
      return nil
    }
    typealias MachServiceInit = @convention(c) (AnyObject, Selector, NSString, UInt) -> Unmanaged<NSXPCConnection>?
    let initialize = unsafeBitCast(method_getImplementation(method), to: MachServiceInit.self)
    let allocated = type.alloc() as AnyObject
    guard let unmanaged = initialize(allocated, selector, Self.serviceName as NSString, 0) else {
      return nil
    }
    let fresh = unmanaged.takeRetainedValue()
    fresh.remoteObjectInterface = NSXPCInterface(with: AgentXPCProtocol.self)
    fresh.invalidationHandler = { [weak self] in self?.connection = nil }
    fresh.interruptionHandler = { [weak self] in self?.connection = nil }
    fresh.resume()
    connection = fresh
    return fresh
  }

  /// One call. `method` and `params` travel as JSON; the reply is the daemon's
  /// own JSON object, which carries `ok` and either `result` or `error`.
  func call(_ method: String,
            params: [String: Any] = [:],
            confirmed: Bool = false,
            timeout: TimeInterval = 30) async -> [String: Any] {
    let request: [String: Any] = [
      "id": UUID().uuidString,
      "method": method,
      "params": params,
      "confirmed": confirmed,
    ]
    guard let payload = try? JSONSerialization.data(withJSONObject: request) else {
      return ["ok": false, "error": ["code": "ERR_BAD_PARAMS", "message": "request is not JSON"]]
    }
    let box: [String: Any] = await withCheckedContinuation { continuation in
      var finished = false
      let finish: ([String: Any]) -> Void = { answer in
        guard !finished else { return }
        finished = true
        continuation.resume(returning: answer)
      }
      guard let active = connected() else {
        finish(["ok": false, "error": ["code": "ERR_AGENT_UNAVAILABLE", "message": "the service is not installed on this host"]])
        return
      }
      let proxy = active.remoteObjectProxyWithErrorHandler { error in
        finish(["ok": false, "error": ["code": "ERR_INTERNAL", "message": error.localizedDescription]])
      } as? AgentXPCProtocol
      guard let proxy else {
        finish(["ok": false, "error": ["code": "ERR_INTERNAL", "message": "no proxy"]])
        return
      }
      proxy.call(payload) { data in
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          finish(["ok": false, "error": ["code": "ERR_INTERNAL", "message": "reply was not JSON"]])
          return
        }
        finish(decoded)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        finish(["ok": false, "error": ["code": "ERR_TIMEOUT", "message": "the service did not answer"]])
      }
    }
    return box
  }
}

/// Mirrors the daemon's exported interface; the reply is one JSON blob so a
/// private-selector change never reshapes the connection.
@objc protocol AgentXPCProtocol {
  func call(_ payload: Data, reply: @escaping (Data) -> Void)
}