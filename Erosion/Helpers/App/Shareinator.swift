//
//  Shareinator.swift
//  PartyUI
//
//  Created by lunginspector on 2/12/26.
//

import Foundation
import UIKit

@MainActor
public func presentShareSheet(with url: URL) {
    Alertinator.shared.runWhenPresentationIdle {
        guard let topController = Alertinator.resolveActivePresenter() else { return }
        let activityViewController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = topController.view
            popover.sourceRect = CGRect(x: topController.view.bounds.midX, y: topController.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        topController.present(activityViewController, animated: true)
    }
}

