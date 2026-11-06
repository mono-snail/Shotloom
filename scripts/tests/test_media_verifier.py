import hashlib
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
import AVFoundation
import CoreVideo
@main struct Fixture {
 static func main() async throws {
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
  writer.add(input)
  guard writer.startWriting() else { throw writer.error! }
  writer.startSession(atSourceTime: .zero)
  for index in 0..<10 {
   let deadline = Date().addingTimeInterval(10)
   while !input.isReadyForMoreMediaData {
    guard Date() < deadline else { fatalError("writer readiness timeout") }
    try await Task.sleep(for: .milliseconds(1))
   }
   var image: CVPixelBuffer?
   guard CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &image) == kCVReturnSuccess, let image else { fatalError("allocation") }
   CVPixelBufferLockBaseAddress(image, [])
   let pointer = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
   for y in 0..<48 { for x in 0..<64 {
    let offset = y * CVPixelBufferGetBytesPerRow(image) + x * 4
    pointer[offset] = UInt8(index * 20); pointer[offset+1] = 80
    pointer[offset+2] = 160; pointer[offset+3] = 255
   } }
   CVPixelBufferUnlockBaseAddress(image, [])
   guard adaptor.append(image, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else { throw writer.error! }
  }
  writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
  input.markAsFinished(); await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error! }
 }
}
'''


class MediaVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="deskcapture-media-verifier-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = pathlib.Path(cls.temporary.name)
        cls.binary = cls.directory / "verify"
        fixture_source = cls.directory / "fixture.swift"
        fixture_source.write_text(FIXTURE)
        for source, target in [(ROOT / "scripts/verify-recording-media.swift", cls.binary),
                               (fixture_source, cls.directory / "fixture")]:
            subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(target)],
                           check=True, capture_output=True, text=True, timeout=60)
        cls.movie = cls.directory / "generated.mov"
        subprocess.run([str(cls.directory / "fixture"), str(cls.movie)], check=True, timeout=30,
                       capture_output=True, text=True)

    def run_verifier(self, source, destination):
        return subprocess.run([str(self.binary), str(source), str(destination)],
                              capture_output=True, text=True, timeout=30)

    def test_decodes_all_ten_generated_frames_and_preserves_source(self):
        before = hashlib.sha256(self.movie.read_bytes()).hexdigest()
        report = self.directory / "valid-report.json"
        result = self.run_verifier(self.movie, report)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(report.read_text())
        self.assertTrue(data["success"])
        self.assertEqual(data["inputSHA256"], before)
        self.assertEqual(data["tracks"][0]["buffers"], 10)
        self.assertEqual(data["tracks"][0]["samples"], 10)
        self.assertEqual(data["tracks"][0]["nonmonotonicBuffers"], 0)
        self.assertEqual(hashlib.sha256(self.movie.read_bytes()).hexdigest(), before)

    def test_truncated_media_is_a_failure_report(self):
        broken = self.directory / "truncated.mov"
        broken.write_bytes(self.movie.read_bytes()[:96])
        report = self.directory / "invalid-report.json"
        result = self.run_verifier(broken, report)
        self.assertEqual(result.returncode, 1)
        data = json.loads(report.read_text())
        self.assertFalse(data["success"])
        self.assertTrue(data["error"])

    def test_report_cannot_replace_media(self):
        before = self.movie.read_bytes()
        result = self.run_verifier(self.movie, self.movie)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.movie.read_bytes(), before)

    def test_report_cannot_replace_media_through_directory_alias(self):
        alias = self.directory / "alias"
        alias.symlink_to(self.directory, target_is_directory=True)
        before = self.movie.read_bytes()
        result = self.run_verifier(self.movie, alias / self.movie.name)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.movie.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
