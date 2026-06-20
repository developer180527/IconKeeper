//
//  LoginItemManager.swift
//  IconKeeper
//
//  Wraps ServiceManagement for "launch at login" so the menu bar companion
//  can run quietly after a reboot.
//

import ServiceManagement

@MainActor
enum LoginItemManager {
    /// Whether IconKeeper is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
