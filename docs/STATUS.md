# Project Status & Verification Log

This file separates **written**, **tested in CI** and **not tested**. Nothing here is marked as working without a test run or log behind it.

## Progress by phase

| # | Phase | State |
|---|---|---|
| 1 | Requirements & architecture | Done — [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](../SECURITY.md) |
| 2 | iOS project from scratch (SwiftUI, iOS 17, Swift 6) | Done — compiles for device in CI (`xcodebuild archive`) |
| 3 | Client-side encryption & recovery | Done — WZCE v1, VaultKeys, RecoveryKit, KeyVault (Secure Enclave) |
| 4 | Secure backend | Done — FastAPI `/api/v2`, scrypt auth, quotas, rate limit, audit, systemd sandbox |
| 5 | Connection, sync, chunked resumable upload | Done — SQLite queue, background URLSession, adaptive concurrency |
| 6 | UI | Done — Welcome, Connect Server, Test Connection, Encryption Setup, Permissions, Dashboard, Library (Photos / Videos / Files), Transfers (Sync Center), Restore, Settings (Sync, Security, About) |
| 7 | Tests | Backend: pytest. iOS: unit + integration (real backend on the runner) + UI |
| 8 | GitHub Actions build | Done — tests, unsigned IPA, verification, SHA256SUMS, release job |
| 9 | Fix build/test failures | See CI history below |
| 10 | Delivery | IPA as a GitHub Actions artifact; GitHub Release on tag / manual dispatch |

## CI history (this branch)

| Run | Result | Notes |
|---|---|---|
| iOS #3 (previous session) | ❌ | Swift 6 errors: tuple labels lost in `importFiles`, captured `var` in a `@Sendable` closure in `ResourceExporter` |
| iOS #4 | IPA ✅ · tests ⏹ | Compile errors fixed; the test job hung in `simctl bootstatus` (runner issue) and was cancelled |
| iOS #5 | IPA ✅ · tests: see Actions | Simulator boot now bounded (7 min) with one erase-and-retry |
| Backend #3 | ✅ | pytest on Python 3.12 and 3.13 |

## Test coverage map

| Requirement | Test(s) | Where it runs |
|---|---|---|
| Encryption / decryption, byte-exact | `CryptoTests.testRoundTripSizes`, `test_wzce.py::test_roundtrip` | simulator, Linux |
| Swift ↔ Python compatibility | `testEncryptionMatchesPythonByteForByte`, `testKeyDerivationMatchesPython`, `test_cross_language_vector` | both |
| Unique nonces / keys | `testUniqueNoncesAndKeysPerEncryption` | simulator |
| Invalid authentication tag / corruption | `testCorruptedSegmentDetected`, `testCorruptedChunkRejectedAndTamperedDownloadDetected`, `test_corrupted_chunk_detected` | both |
| Reordering / truncation / wrong key / wrong object | `testReorderedSegmentsDetected`, `testTruncationTrailingDataWrongKeyAndWrongObject`, `test_wrong_key_and_object_binding` | both |
| Key recovery on a new device | `testRecoveryKeyRestoreOnNewDeviceAndWrongKey`, `testKeyVaultPersistsAndRecoversWithRecoveryKey` | simulator + backend |
| Image / video backup + restore original bytes (SHA-256) | `testPhotoAndVideoOriginalsBackUpAndRestore` | simulator Photos library + backend |
| Large file streaming, bounded memory | `testLargeFileBackupAndByteExactRestore`, `testEncryptionMemoryStaysBounded`, `test_large_streaming_roundtrip` | both |
| Duplicate detection | `testDuplicatePrevention`, `test_duplicate_prevention` | both |
| Interrupted upload / resume / app restart | `testInterruptedUploadResumesAfterRelaunch`, `testQueueSurvivesRelaunch`, `test_interrupted_upload_resumes` | both |
| Network failure / switching | `testNetworkSwitchingPausesAndResumes`, `testNetworkSwitching` | simulator |
| Server unavailable / invalid credentials | `testIncorrectPasswordIsRejected`, `testUnauthorizedAccessIsRejected`, `test_incorrect_password_and_unknown_user` | both |
| Invalid TLS certificate | `testExpiredCertificateRejected`, `testSelfSignedCertificateRejected`, `testUntrustedRootRejected`, `testWrongHostRejected` (badssl.com; skipped if the runner has no internet) | simulator |
| Storage full | `testLowStorageDefersWithoutWritingFiles`, `testLowStorageGuard`, `test_quota_and_low_disk` | both |
| Background transfer | `testBackgroundURLSessionTransfer` (background session object in the simulator) | simulator |
| Desktop recovery tool | `test_desktop_restore_tool_end_to_end` | Linux |
| Performance | `testUploadConcurrencyAndChunkSizeBenchmark`, `testEncryptionThroughputBenchmark` (numbers in the CI job summary) | simulator, loopback |
| Onboarding UI against a real server | `OnboardingUITests` | simulator |

## Not tested (cannot be tested in this environment)

These need a physical iPhone and/or the production server. They are **untested**, not "passed":

- Installation of the signed IPA on a real iPhone (signing happens outside CI with KravaSigner).
- Secure Enclave key sealing (simulators have no Secure Enclave; the Keychain fallback path is what CI runs).
- Face ID unlock.
- Real background behaviour: BGProcessingTask scheduling, uploads continuing while suspended on a device, relaunch by `handleEventsForBackgroundURLSession`, behaviour after force-quit.
- Real Wi-Fi / cellular throughput, thermal and battery impact; iCloud-only originals download; ProRAW / ProRes / 4K HDR files from a real camera.
- Deployment on `studio.rextv.sbs` (no server access was used; no production files were touched).
- SFTP transport: not implemented (see [ARCHITECTURE.md](ARCHITECTURE.md#sftp)).

## Known limitations

- Photos edits: the original resource is backed up; edited renderings are not.
- Recovery-key rotation is designed but not implemented.
- iOS cannot sync continuously in the background (see ARCHITECTURE.md).
- Traffic analysis: the server sees ciphertext sizes and upload times.
