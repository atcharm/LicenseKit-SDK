import Foundation
import LicenseKit

/// Translates between LicenseKit's domain and the demo service's HTTP API.
///
/// This is the file you would write to integrate a real licensing service, and
/// it is deliberately the *only* place in the demo that knows what that service's
/// JSON looks like. Note what is absent: no `URLSession`, no `async`, no retry
/// loop, no backoff, no cancellation. `RemoteLicenseProvider` owns all of that
/// once, for every adapter, which is why this file is pure translation and can be
/// read top-to-bottom in a minute.
///
/// The service it speaks to answers three endpoints and has the habits real ones
/// do — a body-level `ok` flag that contradicts a 200 status, an error code that
/// carries more meaning than the status line, and an optional signature. Each of
/// those is handled below, with a note on why.
public struct DemoStoreAdapter: RemoteProviderAdapter {
    /// Recorded on every license this adapter produces, and how the runtime
    /// finds its way back here when refreshing or releasing a seat.
    public let providerID: ProviderID = "demo-store"

    public let baseURL: URL
    private let codec: JSONLicenseCodec

    /// Everything this service can do.
    ///
    /// Advertising capabilities is not decoration: `LicenseManager` reads them to
    /// pick a provider for activation, and to decide whether releasing a seat is
    /// even worth attempting. A licensing UI should read them too, so it never
    /// offers a button the backend cannot honour — compare `GumroadAdapter`,
    /// which omits `.deactivation` because Gumroad has no seat-release endpoint.
    ///
    /// `.signedLicenses` is a claim about the service, and the demo's Service
    /// screen can make it a lie on purpose. That is the point of the toggle: it
    /// shows what `SignatureRule.Policy` does when a provider stops signing.
    public var capabilities: ProviderCapabilities {
        [.activation, .deactivation, .refresh, .remoteValidation, .seatAccounting, .signedLicenses]
    }

    public init(
        baseURL: URL = DemoStoreBackend.baseURL,
        codec: JSONLicenseCodec = JSONLicenseCodec()
    ) {
        self.baseURL = baseURL
        self.codec = codec
    }

    // MARK: - Requests

    public func activationRequest(for request: ActivationRequest) throws -> HTTPRequest {
        try post("activate", [
            "key": request.key.rawValue,
            "product": request.product.rawValue,
            // Absent when the host configured no machine identity. The service
            // then has nothing to count seats against, which is a legitimate
            // configuration rather than an error.
            "fingerprint": request.fingerprint?.rawValue,
            "device": request.deviceName,
        ])
    }

    public func validationRequest(for record: LicenseRecord) throws -> HTTPRequest {
        try post("validate", [
            "key": record.license.key.rawValue,
            "fingerprint": record.activation?.fingerprint.rawValue,
        ])
    }

    public func deactivationRequest(for record: LicenseRecord) throws -> HTTPRequest {
        try post("deactivate", [
            "key": record.license.key.rawValue,
            "fingerprint": record.activation?.fingerprint.rawValue,
        ])
    }

    /// Builds a JSON POST, dropping any field the caller had no value for.
    ///
    /// Sending `"fingerprint": null` and omitting the key entirely mean the same
    /// thing to most services, but omitting it keeps the request minimal and
    /// avoids depending on how the server treats an explicit null.
    private func post(_ path: String, _ fields: [String: String?]) throws -> HTTPRequest {
        let payload = fields.compactMapValues { $0 }
        do {
            return .jsonPost(
                url: baseURL.appendingPathComponent(path),
                body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            )
        } catch {
            throw LicenseProviderError.malformedResponse(
                reason: "could not encode the \(path) request"
            )
        }
    }

    // MARK: - Responses

    public func decodeActivation(
        _ response: HTTPResponse,
        for request: ActivationRequest,
        at now: Date
    ) throws -> LicenseRecord {
        let payload = try JSONValue(parsing: response.body)
        try requireAcknowledged(payload)

        let (license, signature) = try licensePair(in: payload)

        var activation: ActivationInfo?
        if let fingerprint = request.fingerprint {
            activation = ActivationInfo(
                // Prefer the service's own handle for the seat; fall back to the
                // fingerprint so the record always has something to identify
                // this activation by when it later asks to release it.
                id: ActivationID(rawValue: payload["activation_id"].string ?? fingerprint.rawValue),
                fingerprint: fingerprint,
                activatedAt: now,
                deviceName: request.deviceName
            )
        }

        return LicenseRecord(
            license: license,
            signature: signature,
            origin: LicenseOrigin(provider: providerID, medium: .remote, retrievedAt: now),
            activation: activation,
            providerState: providerState(from: payload, at: now),
            lastValidatedAt: now
        )
    }

    public func decodeValidation(
        _ response: HTTPResponse,
        for record: LicenseRecord,
        at now: Date
    ) throws -> RemoteValidationResult {
        let payload = try JSONValue(parsing: response.body)
        try requireAcknowledged(payload)

        let (license, signature) = try licensePair(in: payload)
        return RemoteValidationResult(
            state: providerState(from: payload, at: now),
            updatedLicense: license,
            updatedSignature: signature
        )
    }

    public func decodeDeactivation(_ response: HTTPResponse, for record: LicenseRecord) throws {
        try requireAcknowledged(try JSONValue(parsing: response.body))
    }

    /// Maps a failure the service reported onto the domain's error space.
    ///
    /// The status code alone is not enough, and that is not this service being
    /// awkward — Gumroad, Polar, and most others do the same. The error *code* in
    /// the body distinguishes "no seats left" from "no such key", and those want
    /// different UI: one offers seat management, the other says check the key.
    ///
    /// Getting the transient/definitive split right matters more than the
    /// message. `.rateLimited` and `.server` are retried and never revoke a
    /// license; `.seatLimitReached` and `.licenseNotFound` are settled answers
    /// and retrying them would only waste the customer's battery.
    public func mapFailure(
        _ response: HTTPResponse,
        for operation: ProviderOperation
    ) -> LicenseProviderError {
        let payload = try? JSONValue(parsing: response.body)
        let message = payload?["message"].string

        switch payload?["error"].string {
        case "seat_limit": return .seatLimitReached
        case "unknown_key": return .licenseNotFound
        case "revoked": return .rejected(reason: message ?? "the purchase was withdrawn")
        default: break
        }

        switch response.status {
        case 401, 403:
            return .unauthorized
        case 404:
            return .licenseNotFound
        case 409, 422:
            return .rejected(reason: message ?? "the request was rejected")
        case 429:
            // The service knows when it will be ready better than any local
            // backoff calculation does, so hand `Retry-After` through and let
            // `RemoteLicenseProvider` honour it.
            return .rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        default:
            return .server(status: response.status, message: message)
        }
    }

    // MARK: - Mapping

    /// Rejects a body that says the request failed while the status line says it
    /// succeeded.
    ///
    /// A 200 carrying `{"ok": false}` is how this service reports a refunded
    /// purchase, so without this check a withdrawn license would activate
    /// cleanly. `.rejected` is deliberately *not* transient: a refund is a
    /// settled answer and must not be retried into looking like an outage.
    private func requireAcknowledged(_ payload: JSONValue) throws {
        guard payload["ok"].bool == true else {
            throw LicenseProviderError.rejected(
                reason: payload["message"].string
                    ?? payload["error"].string
                    ?? "the licensing service refused the request"
            )
        }
    }

    /// Reads the license the service returned, and its signature when it signed.
    ///
    /// A service that returns unsigned licenses is relying on TLS for
    /// authenticity. That can be a sound design, but it is the *host's* call
    /// whether to accept it, expressed through `SignatureRule.Policy` — so this
    /// adapter reports what it found and refuses to decide.
    private func licensePair(in payload: JSONValue) throws -> (License, LicenseSignature?) {
        guard let encoded = payload["license"].string,
              let data = Data(base64Encoded: encoded)
        else {
            throw LicenseProviderError.malformedResponse(
                reason: "the response carried no license payload"
            )
        }

        do {
            if payload["signed"].bool == true {
                let signed = try codec.decodeSignedLicense(data)
                return (signed.license, signed.signature)
            }
            return (try codec.decodeLicense(data), nil)
        } catch let error as LicenseFormatError {
            throw LicenseProviderError.malformedResponse(
                reason: error.errorDescription ?? "the license could not be decoded"
            )
        }
    }

    /// Folds the service's answer into the unsigned, local half of a record.
    ///
    /// Everything here is mutable state the provider owns — status, renewals,
    /// seat usage — and it lives outside the signed `License` on purpose. That is
    /// why a renewal can move the expiry forward without the vendor reissuing or
    /// resigning anything, and why `LicenseRecord.effectiveExpiry` prefers this
    /// over the signed policy's own window.
    private func providerState(from payload: JSONValue, at now: Date) -> ProviderStateSnapshot {
        var opaque = LicenseMetadata()
        // `seats.total` arrives as null for an unlimited license, which `.int`
        // correctly reads as absent rather than zero.
        if let total = payload.at("seats", "total").int {
            opaque["seats.total"] = .integer(Int64(total))
        }
        if let signed = payload["signed"].bool {
            opaque["service.signsLicenses"] = .boolean(signed)
        }

        return ProviderStateSnapshot(
            // An unrecognised status decodes to itself rather than failing, so a
            // service that invents a new lifecycle state does not break the app.
            // `RevocationRule` treats anything it does not know as `.unknown`.
            status: ProviderStateSnapshot.Status(rawValue: payload["status"].string ?? "unknown"),
            expiresAt: payload["expires_at"].date,
            activationCount: payload.at("seats", "used").int,
            opaqueState: opaque,
            observedAt: now
        )
    }
}
