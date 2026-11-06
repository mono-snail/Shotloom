import AppKit

/// The editable project and its delivered bitmap must describe the same moment.
/// Retain immutable image data and value fields before scheduling asynchronous work.
struct CaptureProjectSnapshot: @unchecked Sendable {
    let original: CGImage
    let marks: [AnnotationArchive]
    let preset: TutorialPreset?
    let backingScale: CGFloat

    @MainActor func matches(_ document: AnnotationDocument) -> Bool {
        backingScale == document.backingScale && preset == document.tutorialPreset
            && marks == document.marks.map(AnnotationArchive.init)
    }

    @MainActor init(_ document: AnnotationDocument) {
        original = document.original
        marks = document.marks.map(AnnotationArchive.init)
        preset = document.tutorialPreset
        backingScale = document.backingScale
    }
}
