import Foundation
import Flutter

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
    // Both `alloc` and `NSXPCConnection(machServiceName:options:)` are hidden
    // from Swift and the iOS SDK, but the selectors ship in the Foundation
    // runtime. Reach them through the ObjC runtime - the same pattern
    // IOSPhoneControl uses to resolve PhoneRunnerSupport - so a host with the
    // daemon installed connects, and a build without it degrades to
    // "unavailable" instead of failing to compile.
    guard let type = NSClassFromString("NSXPCConnection") as? NSObject.Type else { return nil }
    let initSelector = NSSelectorFromString("initWithMachServiceName:options:")
    let allocSelector = NSSelectorFromString("alloc")
    guard let initMethod = class_getInstanceMethod(type, initSelector),
          let allocMethod = class_getClassMethod(type, allocSelector) else {
      return nil
    }
    typealias Alloc = @convention(c) (AnyObject, Selector) -> Unmanaged<NSObject>
    typealias MachServiceInit = @convention(c) (AnyObject, Selector, NSString, UInt) -> Unmanaged<NSXPCConnection>?
    let alloc = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)
    let initialize = unsafeBitCast(method_getImplementation(initMethod), to: MachServiceInit.self)
    // `alloc` hands back a +1 reference that the initializer consumes; the
    // initializer returns a new +1 reference, released with the connection.
    let allocated = alloc(type, allocSelector).takeUnretainedValue()
    guard let unmanaged = initialize(allocated, initSelector, Self.serviceName as NSString, 0) else {
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

/// The Flutter edge of the client: `dsh/agent`.
///
/// One method, `call`, because the daemon already speaks a request envelope and a
/// second, Flutter-shaped schema would be a second thing to keep in step with it.
/// The reply travels back verbatim - `ok` with a `result`, or `ok:false` with an
/// `error` - so the app can tell "the daemon refused this" from "the daemon is not
/// there", and it never holds a task port: only what the daemon chose to report.
final class AgentChannel {
  private let channel: FlutterMethodChannel
  private let client = IOSAgentClient()

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/agent", binaryMessenger: messenger)
    channel.setMethodCallHandler { [client] call, result in
      switch call.method {
      case "call":
        Self.dispatch(call, client: client, result: result)
      case "available":
        result(client.isAvailable)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// `{method, params, confirmed?, timeout?}` in, the daemon's own reply out.
  ///
  /// `confirmed` is the human's answer travelling with the request, not a default
  /// the app may set for itself: a method that needs it answers
  /// `ERR_CONFIRMATION_REQUIRED` when it is missing, which is what the UI turns
  /// into a prompt.
  private static func dispatch(_ call: FlutterMethodCall, client: IOSAgentClient, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let method = arguments["method"] as? String,
          !method.isEmpty
    else {
      result(FlutterError(code: "bad-arguments", message: "`method` is required", details: nil))
      return
    }
    let params = arguments["params"] as? [String: Any] ?? [:]
    let confirmed = arguments["confirmed"] as? Bool == true
    let timeout = arguments["timeout"] as? Double ?? 30
    Task {
      let reply = await client.call(method, params: params, confirmed: confirmed, timeout: timeout)
      DispatchQueue.main.async { result(reply) }
    }
  }
}
