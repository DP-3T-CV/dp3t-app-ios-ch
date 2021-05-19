//
/*
 * Copyright (c) 2020 Ubique Innovation AG <https://www.ubique.ch>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SPDX-License-Identifier: MPL-2.0
 */

import UIKit

class NSCheckInOverviewViewController: NSViewController {
    // MARK: - Subviews

    private let stackScrollView = NSStackScrollView(axis: .vertical, spacing: 0)

    private let currentStateView = NSCheckInCurrentStateModuleView()
    private let diaryView = NSCheckInDiaryModuleView()

    // MARK: - View setup & lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "module_checkins_title".ub_localized

        setupView()
        setupButtonCallbacks()
    }

    private func setupView() {
        view.backgroundColor = .ns_background

        stackScrollView.stackView.isLayoutMarginsRelativeArrangement = true
        stackScrollView.stackView.layoutMargins = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)

        view.addSubview(stackScrollView)
        stackScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        stackScrollView.addSpacerView(NSPadding.large)
        stackScrollView.addArrangedView(currentStateView)
        stackScrollView.addSpacerView(NSPadding.large)
        stackScrollView.addArrangedView(diaryView)
        stackScrollView.addSpacerView(NSPadding.large)
    }

    private func setupButtonCallbacks() {
        currentStateView.scanQrCodeCallback = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.navigationController?.pushViewController(NSCheckInViewController(), animated: true)
        }

        currentStateView.checkoutCallback = { [weak self] in
            guard let strongSelf = self else { return }

            if let _ = CheckInManager.shared.currentCheckIn {
                let vc = NSCheckInEditViewController()
                vc.presentInNavigationController(from: strongSelf, useLine: false)
            }
        }

        diaryView.touchUpCallback = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.navigationController?.pushViewController(NSDiaryViewController(), animated: true)
        }
    }
}
