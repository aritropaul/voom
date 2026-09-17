import Testing
import Foundation
import CoreML
@testable import VoomCore

/// Guards the predicate that decides whether a failed transcription is worth
/// retrying with freshly loaded models. Only CoreML failures are — a missing
/// file or an unreadable track will fail again just as fast.
struct CoreMLFailureTests {

    @Test func recognizesDirectCoreMLError() {
        let error = NSError(domain: MLModelErrorDomain, code: 0)
        #expect(error.isCoreMLFailure)
    }

    @Test func recognizesWrappedCoreMLError() {
        let underlying = NSError(domain: MLModelErrorDomain, code: 0)
        let error = NSError(
            domain: "com.voom.pipeline",
            code: 7,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        #expect(error.isCoreMLFailure)
    }

    @Test func ignoresUnrelatedErrors() {
        let missingFile = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        #expect(!missingFile.isCoreMLFailure)
        #expect(!TranscriptionError.noAudioTrack.isCoreMLFailure)
    }
}
