//
//  Alertinator.swift
//  PartyUI
//
//  Created by lunginspector on 2/12/26.
//

import Foundation
import UIKit

@MainActor
public class Alertinator {
    public static let shared = Alertinator()
    
    var alertController: UIAlertController?
    private var pendingAlerts: [UIAlertController] = []
    private var isDraining = false
    
    public func alert(title: String, body: String, showCancel: Bool = true) {
        Task { @MainActor in
            let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
            if showCancel {
                alert.addAction(.init(title: "确定", style: .cancel) { _ in
                    self.scheduleNextDrain()
                })
            }
            alert.view.tintColor = UIColor(named: "AccentColor")
            self.enqueue(alert)
        }
    }
    
    public func alert(title: String, body: String, showCancel: Bool = true, actionLabel: String = "确定", action: @escaping () -> Void) {
        Task { @MainActor in
            let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
            alert.addAction(.init(title: actionLabel, style: .default) { _ in
                action()
                self.scheduleNextDrain()
            })
            if showCancel {
                alert.addAction(.init(title: "取消", style: .cancel) { _ in
                    self.scheduleNextDrain()
                })
            }
            alert.view.tintColor = UIColor(named: "AccentColor")
            self.enqueue(alert)
        }
    }
    
    public func prompt(title: String, placeholder: String = "", text: String = "", showCancel: Bool = true, completion: @escaping (String?) async -> Void) {
        Task { @MainActor in
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                if !placeholder.isEmpty {
                    field.placeholder = placeholder
                }
                if !text.isEmpty {
                    field.text = text
                }
            }
            if showCancel {
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                    self.scheduleNextDrain()
                    Task {
                        await completion(nil)
                    }
                })
            }
            alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
                let value = alert?.textFields?.first?.text
                self.scheduleNextDrain()
                Task {
                    await completion(value)
                }
            })
            alert.view.tintColor = UIColor(named: "AccentColor")
            self.enqueue(alert)
        }
    }

    @MainActor
    public func runWhenPresentationIdle(_ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            for _ in 0..<30 {
                if let host = Self.resolveActivePresenter(),
                   !Self.isControllerBusy(host) {
                    block()
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            block()
        }
    }

    @MainActor
    private func enqueue(_ alert: UIAlertController) {
        pendingAlerts.append(alert)
        drainQueue()
    }

    @MainActor
    private func scheduleNextDrain() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.drainQueue()
        }
    }

    @MainActor
    private func drainQueue() {
        guard !isDraining, !pendingAlerts.isEmpty else { return }
        isDraining = true
        Task { @MainActor in
            defer { isDraining = false }
            while let nextAlert = pendingAlerts.first {
                var presented = false
                for _ in 0..<35 {
                    if let topController = Self.resolveActivePresenter(),
                       !Self.isControllerBusy(topController),
                       !(topController is UIAlertController) {
                        self.alertController = nextAlert
                        topController.present(nextAlert, animated: true)
                        pendingAlerts.removeFirst()
                        presented = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                if !presented {
                    // A modal alert or sheet is still held open by the user; pause draining until dismissed
                    break
                }
                if !pendingAlerts.isEmpty {
                    // Wait until this newly presented alert is dismissed before presenting the next
                    break
                }
            }
        }
    }

    @MainActor
    static func resolveActivePresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first,
              var topController = window.rootViewController else {
            return nil
        }
        while let presented = topController.presentedViewController, !presented.isBeingDismissed {
            topController = presented
        }
        return topController
    }

    @MainActor
    static func isControllerBusy(_ vc: UIViewController) -> Bool {
        if vc.isBeingDismissed || vc.isBeingPresented || vc.transitionCoordinator != nil {
            return true
        }
        if vc.presentedViewController != nil {
            // A child modal/sheet/alert is currently in the middle of dismissing
            return true
        }
        return false
    }
}
