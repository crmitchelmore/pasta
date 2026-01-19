import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

public protocol LoginItemServicing {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

#if canImport(ServiceManagement)
public struct SMAppServiceMainAppLoginItemService: LoginItemServicing {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
#else
public struct SMAppServiceMainAppLoginItemService: LoginItemServicing {
    public init() {}
    public var isEnabled: Bool { false }
    public func register() throws {}
    public func unregister() throws {}
}
#endif

public struct LaunchAtLoginManager {
    private let service: LoginItemServicing

    public init(service: LoginItemServicing = SMAppServiceMainAppLoginItemService()) {
        self.service = service
    }

    public var isEnabled: Bool {
        service.isEnabled
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> Bool {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
        return service.isEnabled
    }
}
