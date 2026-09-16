//
//  ErrorAlert.swift
//  IconKeeper
//
//  Presents the store's queued errors one at a time, in the right place.
//
//  A single global error string used to be shown by the main window: a second
//  error overwrote the first, and an alert raised while a sheet was open popped
//  up over (or behind) the sheet. Now errors queue, the main window waits for
//  sheets to close, and a sheet shows errors about its own item itself.
//

import SwiftUI

private struct StoreErrorAlert: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.controlActiveState) private var activeState

    /// `true` for a top-level window: shows every error, but only while no
    /// sheet is up. `false` for a sheet: shows app-wide errors and those about
    /// `itemID`.
    let isWindow: Bool
    let itemID: UUID?

    private var current: UserError? {
        guard activeState != .inactive else { return nil }
        if isWindow {
            guard store.modalDepth == 0 else { return nil }
            return store.pendingErrors.first
        }
        return store.pendingErrors.first { $0.itemID == nil || $0.itemID == itemID }
    }

    func body(content: Content) -> some View {
        let error = current
        content.alert(
            "Something went wrong",
            isPresented: Binding(
                get: { error != nil },
                set: { if !$0, let error { store.dismissError(error.id) } }
            ),
            presenting: error,
            actions: { _ in Button("OK", role: .cancel) {} },
            message: { Text($0.message) }
        )
    }
}

/// Counts presented sheets so windows can defer alerts until they close.
private struct ModalTracker: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content
            .onAppear { store.modalDepth += 1 }
            .onDisappear { store.modalDepth = max(0, store.modalDepth - 1) }
    }
}

extension View {
    /// For a window's root view.
    func windowErrorAlert() -> some View {
        modifier(StoreErrorAlert(isWindow: true, itemID: nil))
    }

    /// For a sheet's root view: registers the sheet and shows relevant errors.
    func sheetErrorAlert(itemID: UUID? = nil) -> some View {
        modifier(StoreErrorAlert(isWindow: false, itemID: itemID))
            .modifier(ModalTracker())
    }
}
