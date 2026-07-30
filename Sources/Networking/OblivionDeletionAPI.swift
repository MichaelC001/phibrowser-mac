// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Domain result of the first deletion step. Success is discriminated by the
/// body's `status` field alone: `pending_verification` means a verification
/// code went out to the account email; `running` means a previously accepted
/// deletion is already executing server-side and no new code is sent.
enum AccountDeletionRequestOutcome: Equatable {
    case verificationCodeSent(requestID: String)
    case deletionAlreadyRunning
}

/// Oblivion's error statuses, each carrying a distinct user-facing meaning.
/// Raw HTTP is mapped here once so the flow logic never touches status codes.
enum AccountDeletionServiceError: Error, Equatable {
    /// 400 — invalid request, e.g. a wrong verification code.
    case invalidRequest
    /// 401 — the access token was rejected.
    case unauthorized
    /// 404 — deliberately generic; must not reveal whether an account exists.
    case notFound
    /// 410 — the verification code or the deletion request has expired.
    case expired
    /// 429 — send quota or minimum-interval limit hit.
    case rateLimited
    /// 5xx — retryable with the same idempotency key.
    case serverError(statusCode: Int)
    /// Anything outside the documented contract, including accepted
    /// responses whose body does not parse.
    case unexpectedResponse(statusCode: Int)
}

/// Pure mapping from Oblivion's HTTP responses to domain results. No I/O:
/// `APIClient` performs the calls and feeds the raw status and body in.
enum OblivionDeletionAPI {
    /// Maps a `POST /v1/deletion-requests` response. Any 2xx routes by the
    /// body's `status` field: the API document only pins 202 for a fresh
    /// request, and the already-running shape's status code is unspecified
    /// (and never exercised against staging), so the code must not decide
    /// between the two success shapes.
    static func requestOutcome(statusCode: Int, body: Data) throws -> AccountDeletionRequestOutcome {
        guard (200...299).contains(statusCode) else {
            throw serviceError(statusCode: statusCode)
        }

        guard let payload = try? JSONDecoder().decode(RequestPayload.self, from: body) else {
            throw AccountDeletionServiceError.unexpectedResponse(statusCode: statusCode)
        }

        switch payload.status {
        case "pending_verification":
            guard let requestID = payload.requestID, !requestID.isEmpty else {
                throw AccountDeletionServiceError.unexpectedResponse(statusCode: statusCode)
            }
            return .verificationCodeSent(requestID: requestID)
        case "running":
            return .deletionAlreadyRunning
        default:
            throw AccountDeletionServiceError.unexpectedResponse(statusCode: statusCode)
        }
    }

    /// Maps a `POST /v1/deletion-requests/{request_id}/verify` response.
    /// Any 2xx counts as accepted: the documented 202 was never exercised
    /// against staging (a real verify deletes a real account), and judging a
    /// queued deletion as failed would send the user into retries that hit
    /// 404/410 on an already-consumed request. The body carries nothing the
    /// client acts on.
    static func verifyOutcome(statusCode: Int) throws {
        guard (200...299).contains(statusCode) else {
            throw serviceError(statusCode: statusCode)
        }
    }

    private static func serviceError(statusCode: Int) -> AccountDeletionServiceError {
        switch statusCode {
        case 400:
            return .invalidRequest
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 410:
            return .expired
        case 429:
            return .rateLimited
        case 500...599:
            return .serverError(statusCode: statusCode)
        default:
            return .unexpectedResponse(statusCode: statusCode)
        }
    }

    private struct RequestPayload: Decodable {
        let status: String
        let requestID: String?

        enum CodingKeys: String, CodingKey {
            case status
            case requestID = "request_id"
        }
    }
}
