/*
 * Copyright (c) 2020 Ubique Innovation AG <https://www.ubique.ch>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * SPDX-License-Identifier: MPL-2.0
 */

import CrowdNotifierSDK
import DP3TSDK
import Foundation

protocol ReportingManagerProtocol: AnyObject {
    func getFakeOnsetDate(completion: @escaping (Result<CodeValidator.OnsetDateWrapper, CodeValidator.ValidationError>) -> Void)

    func getOnsetDate(covidCode: String,
                      isFakeRequest fake: Bool,
                      completion: @escaping (Result<CodeValidator.OnsetDateWrapper, CodeValidator.ValidationError>) -> Void)

    func getFakeJWTTokens(completion: @escaping (Result<CodeValidator.TokenWrapper, CodeValidator.ValidationError>) -> Void)

    var hasUserConsent: Bool { get }

    func getUserConsent(callback: @escaping (Result<Void, DP3TTracingError>) -> Void)

    func getJWTTokens(covidCode: String,
                      isFakeRequest fake: Bool,
                      completion: @escaping (Result<CodeValidator.TokenWrapper, CodeValidator.ValidationError>) -> Void)

    func sendENKeys(tokens: CodeValidator.TokenWrapper,
                    isFakeRequest fake: Bool,
                    completion: @escaping (Result<Void, DP3TTracingError>) -> Void)

    func sendCheckIns(tokens: CodeValidator.TokenWrapper,
                      selectedCheckIns: [CheckIn],
                      isFakeRequest _: Bool,
                      completion: @escaping (Result<Void, NetworkError>) -> Void)
}

class ReportingManager: ReportingManagerProtocol {
    // MARK: - Shared

    static let shared = ReportingManager()

    // MARK: - Init

    private init() {}

    // MARK: - Variables

    // in memory dictionary for codes we already have a token and date,
    // if only the second request (iWasExposed) fails
    private var tokenCache: [String: CodeValidator.TokenWrapper] = [:]

    let codeValidator = CodeValidator()

    @KeychainPersisted(key: "oldestSharedKeyDate", defaultValue: nil)
    var oldestSharedKeyDate: Date?

    @UBOptionalUserDefault(key: "endIsolationQuestionDate")
    var endIsolationQuestionDate: Date?

    private let backend = Environment.current.userUploadService
    private var task: URLSessionDataTask?

    private var fakeCode: String {
        String(Int.random(in: 100_000_000_000 ... 999_999_999_999))
    }

    private var state: IWasExposedState?

    private(set) var onsetDate: Date?

    private var onsetResponseDate: Date?
    private var userInteractionDuration: TimeInterval = 0

    // MARK: - API

    var hasUserConsent: Bool { state != nil }

    func getFakeOnsetDate(completion: @escaping (Result<CodeValidator.OnsetDateWrapper, CodeValidator.ValidationError>) -> Void) {
        getOnsetDate(covidCode: fakeCode, isFakeRequest: true, completion: completion)
    }

    func getOnsetDate(covidCode: String, isFakeRequest fake: Bool, completion: @escaping (Result<CodeValidator.OnsetDateWrapper, CodeValidator.ValidationError>) -> Void) {
        codeValidator.sendOnsetDateRequest(code: covidCode, isFakeRequest: fake) { result in
            switch result {
            case let .success(onset):
                self.onsetResponseDate = Date().addingTimeInterval(-ExponentialDistribution.sample(rate: 0.2))
                self.onsetDate = onset.onset
                completion(.success(onset))
            case let .failure(error):
                completion(.failure(error))
            }
        }
    }

    func getUserConsent(callback: @escaping (Result<Void, DP3TTracingError>) -> Void) {
        guard #available(iOS 12.5, *) else { return }
        DP3TTracing.requestTEKPermission { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(state):
                self.state = state
                callback(.success(()))
            case let .failure(error):
                callback(.failure(error))
            }
        }
    }

    func getFakeJWTTokens(completion: @escaping (Result<CodeValidator.TokenWrapper, CodeValidator.ValidationError>) -> Void) {
        getJWTTokens(covidCode: fakeCode, isFakeRequest: true, completion: completion)
    }

    func getJWTTokens(covidCode: String,
                      isFakeRequest fake: Bool = false,
                      completion: @escaping (Result<CodeValidator.TokenWrapper, CodeValidator.ValidationError>) -> Void) {
        if let tokens = tokenCache[covidCode] {
            completion(.success(tokens))
        } else {
            var delay: TimeInterval = 0
            if let start = onsetResponseDate {
                userInteractionDuration = Date().timeIntervalSince(start)
                delay = start.sendPadding
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.codeValidator.sendCodeRequest(code: covidCode, isFakeRequest: fake) { [weak self] result in
                    guard let strongSelf = self else { return }

                    switch result {
                    case let .success(tokens):
                        strongSelf.tokenCache[covidCode] = tokens
                        completion(.success(tokens))
                    case let .failure(error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func sendENKeys(tokens: CodeValidator.TokenWrapper,
                    isFakeRequest fake: Bool = false,
                    completion: @escaping (Result<Void, DP3TTracingError>) -> Void) {
        guard #available(iOS 12.5, *) else { return }

        let state: IWasExposedState
        if fake {
            state = .fake
        } else {
            guard self.state != nil else {
                completion(.failure(.permissonError))
                return
            }
            state = self.state!
        }

        DP3TTracing.sendTEKs(onset: tokens.enToken.onset,
                             iWasExposedState: state,
                             authentication: .HTTPAuthorizationHeader(header: "Authorization", value: "Bearer \(tokens.enToken.token)")) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch result {
                case let .success(wrapper):
                    self.tokenCache.removeValue(forKey: tokens.code)

                    TracingManager.shared.updateStatus(shouldSync: false) { [weak self] in
                        guard let self = self else { return }

                        if !fake {
                            self.endIsolationQuestionDate = Date().addingTimeInterval(60 * 60 * 24 * 14) // Ask if user wants to end isolation after 14 days

                            let oldestKeyDate = wrapper.oldestKeyDate ?? Date()
                            // keys older than 10 days are never persisted on the server
                            self.oldestSharedKeyDate = max(oldestKeyDate, Date(timeIntervalSinceNow: -60 * 60 * 24 * 10))
                        }

                        completion(.success(()))
                    }
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    func sendCheckIns(tokens: CodeValidator.TokenWrapper,
                      selectedCheckIns: [CheckIn],
                      isFakeRequest _: Bool = false,
                      completion: @escaping (Result<Void, NetworkError>) -> Void) {
        task?.cancel()

        var payload = UserUploadPayload()
        payload.version = 4
        payload.userInteractionDurationMs = UInt32(userInteractionDuration * 1000)

        var uploadInfos = [UploadVenueInfo]()

        for checkIn in selectedCheckIns {
            guard let checkOutTime = checkIn.checkOutTime else {
                continue
            }
            let infos = CrowdNotifier.generateUserUploadInfo(venueInfo: checkIn.venue, arrivalTime: checkIn.checkInTime, departureTime: checkOutTime)

            uploadInfos.append(contentsOf: infos.map {
                var info = UploadVenueInfo()
                info.preID = $0.preId.data
                info.timeKey = $0.timeKey.data
                info.notificationKey = $0.notificationKey.data
                info.intervalStartMs = Int64($0.intervalStartMs)
                info.intervalEndMs = Int64($0.intervalEndMs)
                info.fake = false
                return info
            })
        }

        let fakeCount = 1024 - uploadInfos.count
        let fakeCheckins: [UploadVenueInfo] = (0 ..< fakeCount).map { _ in
            var info = UploadVenueInfo()
            info.preID = .randomBytes(32)
            info.timeKey = .randomBytes(32)
            info.notificationKey = .randomBytes(32)
            info.intervalStartMs = Int64.random(in: 0 ... Int64.max)
            info.intervalEndMs = Int64.random(in: 0 ... Int64.max)
            info.fake = true
            return info
        }
        uploadInfos.append(contentsOf: fakeCheckins)

        payload.venueInfos = uploadInfos

        let payloadData = (try? payload.serializedData()) ?? Data()

        var request = backend.endpoint("userupload", method: .post, headers: ["Content-Type": "application/x-protobuf"], body: payloadData).request()

        request.addValue("Bearer \(tokens.checkInToken.token)", forHTTPHeaderField: "Authorization")

        task = URLSession.certificatePinned.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let response = response as? HTTPURLResponse,
                   response.statusCode != 200 {
                    completion(.failure(.statusError(code: response.statusCode)))
                } else if let e = error {
                    completion(.failure(.unexpected(error: e)))
                } else {
                    completion(.success(()))
                }
            }
        }

        task?.resume()
    }
}

extension Data {
    static func randomBytes(_ count: Int) -> Data {
        var keyData = Data(count: count)
        _ = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        return keyData
    }
}

private extension Date {
    var sendPadding: TimeInterval {
        let now = Date()
        guard now > self else { return 0 }

        var padding: TimeInterval = .second * 5

        while addingTimeInterval(padding) < now {
            padding += .second * 5
        }

        return addingTimeInterval(padding).timeIntervalSince(now)
    }
}
