import XCTest
@testable import WezCryptSecureStudio

final class APIModelTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testDecodesMediaItemFromServerJSON() throws {
        let json = """
        {"id":"0123456789abcdef0123456789abcdef","filename":"IMG_0001.HEIC","mime_type":"image/heic","media_type":"photo",
         "size_bytes":2400000,"sha256":"ab","width":4032,"height":3024,"duration_ms":null,"taken_at":1700000000,
         "added_at":1700000500,"is_favorite":true,"is_screenshot":false,"has_thumbnail":true,"storage_kind":"wzc2","album_ids":["a1"]}
        """
        let item = try decoder.decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.mediaType, .photo)
        XCTAssertEqual(item.sizeBytes, 2_400_000)
        XCTAssertEqual(item.takenAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(item.isFavorite)
        XCTAssertEqual(item.albumIds, ["a1"])
        XCTAssertNil(item.duration)
    }

    func testDecodesDuplicateUpload() throws {
        let json = """
        {"status":"duplicate","media":{"id":"m","filename":"a.mov","mime_type":"video/quicktime","media_type":"video","size_bytes":10,
        "sha256":"s","width":null,"height":null,"duration_ms":5500,"taken_at":1,"added_at":2,"is_favorite":false,"is_screenshot":false,
        "has_thumbnail":false,"storage_kind":"wzc2"}}
        """
        let response = try decoder.decode(CreateUploadResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "duplicate")
        XCTAssertEqual(response.media?.duration, 5.5)
        XCTAssertNil(response.uploadId)
    }

    func testDecodesSessionTokens() throws {
        let json = """
        {"device_id":"d","access_token":"wza_x","access_expires_at":1700000900,"refresh_token":"wzr_y","refresh_expires_at":1702592000}
        """
        let session = try decoder.decode(SessionCredentials.self, from: Data(json.utf8))
        XCTAssertEqual(session.deviceId, "d")
        XCTAssertEqual(session.accessExpiresAt, Date(timeIntervalSince1970: 1_700_000_900))
    }

    func testEncodesSnakeCase() throws {
        let body = CreateUploadRequest(filename: "a", mimeType: "image/jpeg", mediaType: .photo, sizeBytes: 1, sha256: "x", takenAt: 5,
                                       width: nil, height: nil, durationMs: nil, isFavorite: true, isScreenshot: false, localIdentifier: nil)
        let object = try JSONSerialization.jsonObject(with: APIClient.makeEncoder().encode(body)) as? [String: Any]
        XCTAssertEqual(object?["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(object?["size_bytes"] as? Int, 1)
        XCTAssertEqual(object?["is_favorite"] as? Bool, true)
        XCTAssertEqual(object?["taken_at"] as? Int, 5)
    }

    func testErrorEnvelopeParsing() {
        let error = APIError.from(status: 409, data: Data(#"{"error":{"code":"offset_mismatch","message":"m","offset":1048576}}"#.utf8))
        XCTAssertEqual(error, .server(status: 409, code: "offset_mismatch", message: "m", offset: 1_048_576))
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(APIError.from(status: 503, data: Data()).isRetryable, true)
        XCTAssertEqual(APIError.from(status: 422, data: Data(#"{"detail":[{"loc":["body"]}]}"#.utf8)).code, "validation_error")
        XCTAssertFalse(APIError.transport(URLError(.serverCertificateUntrusted)).isRetryable)
        XCTAssertTrue(APIError.transport(URLError(.networkConnectionLost)).isRetryable)
    }

    func testRangeHeaderURLIsHTTPSOnly() throws {
        let keychain = KeychainStore(service: "tests.\(UUID().uuidString)")
        let client = APIClient(baseURL: URL(string: "https://studio.rextv.sbs")!, credentials: SessionCredentialStore(keychain: keychain), deviceKeys: DeviceKeyManager(keychain: keychain))
        let url = try client.url(for: "/api/mobile/library", query: [URLQueryItem(name: "q", value: "a b")])
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.absoluteString, "https://studio.rextv.sbs/api/mobile/library?q=a%20b")
    }
}
