"""Source integration contracts, not iOS runtime or Swift behavioral tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text(encoding="utf-8")


def body(source, declaration):
    start = source.index(declaration)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[opening + 1:end - 1]


class MediaIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.screen = read("submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift")
        cls.gallery = read("submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift")
        cls.legacy = read("submodules/Camera/CameraLegacy/Sources/LegacyCamera.swift")
        cls.neo = read("submodules/Camera/CameraNeo/Sources/CameraNeo.swift")

    def test_settings_have_runtime_consumers_and_registered_defaults(self):
        settings = read("AyuGram/SGSimpleSettings/Sources/ExteraMediaSettings.swift")
        for name, default, consumer in [("zoomSlider", "true", self.screen), ("staticZoom", "false", self.screen), ("unmuteWithVolumeButtons", "false", self.gallery)]:
            self.assertIn(f'"extera.media.{name}": {default}', settings)
            self.assertIn(f"public var {name}: Bool", settings)
            self.assertIn(f"ExteraMediaSettings.shared.{name}", consumer)

    def test_protocol_and_both_backend_completions(self):
        signature = "func updateZoom(_ update: CameraZoomUpdate, completion: @escaping (CameraZoomState?) -> Void)"
        self.assertIn(signature, read("submodules/Camera/Sources/Camera.swift"))
        self.assertIn("self.queue.async", body(self.legacy, signature))
        self.assertIn("Queue.mainQueue().async", body(self.legacy, signature))
        self.assertIn("self.sessionQueue.async", body(self.neo, signature))
        self.assertIn("DispatchQueue.main.async", body(self.neo, signature))

    def test_real_device_bounds_and_cancelled_ramps(self):
        device = read("submodules/Camera/CameraLegacy/Sources/CameraDevice.swift")
        for source in [device, body(self.neo, "func updateZoom(_ update: CameraZoomUpdate, completion:")]:
            for contract in ["device.minAvailableVideoZoomFactor", "device.maxAvailableVideoZoomFactor", "device.videoZoomFactor", "device.cancelVideoZoomRamp()"]:
                self.assertIn(contract, source)
        self.assertIn("neutral: device.neutralZoomFactor", device)

    def test_legacy_front_zoom_requires_dual_camera_for_secondary_device(self):
        for method in ["func setZoomLevel(", "func setZoomDelta(", "func rampZoom(", "func updateZoom(_ update: CameraZoomUpdate) ->"]:
            self.assertIn("self.isDualCameraEnabled == true", body(self.legacy, method))

    def test_slider_release_and_pinch_use_static_preference(self):
        self.assertIn(".valueChanged", self.screen)
        release = body(self.screen, "@objc private func zoomSliderReleased()")
        self.assertIn("staticZoom ? .read : .reset", release)
        pinch = body(self.screen, "@objc private func handlePinch(")
        self.assertIn(".delta(scale)", pinch)
        self.assertEqual(pinch.count("!ExteraMediaSettings.shared.staticZoom"), 2)
        self.assertIn("<= 0.5", pinch)  # Preserve the pre-existing quick-pinch policy.

    def test_lens_change_invalidates_old_snapshot_and_resets_on_next_main_turn(self):
        self.assertIn("if positionChanged || self.zoomState == nil", self.screen)
        self.assertIn("self.zoomRequestId += 1", self.screen)
        self.assertIn("requestId == self.zoomRequestId", self.screen)
        self.assertIn("Queue.mainQueue().async { [weak self] in self?.updateZoom(.reset) }", self.screen)

    def test_observer_is_scoped_and_queued_callbacks_are_invalidated(self):
        observer = body(self.gallery, "private func updateVolumeObservation()")
        for contract in ["volumeObservationGeneration += 1", "volumeObservation?.invalidate()", "volumeObservationInForeground", "isCentral == true", "_isVisible == true", "item?.isSecret == false", "generation == self.volumeObservationGeneration", "options: [.old, .new]"]:
            self.assertIn(contract, observer)
        for declaration in ["override func centralityUpdated(", "override func visibilityUpdated(", "func setupItem("]:
            self.assertIn("self.updateVolumeObservation()", body(self.gallery, declaration))

    def test_unmute_requires_active_owned_nonsecret_playback(self):
        unmute = body(self.gallery, "private func unmuteVideoForVolumeChange()")
        for contract in ["UIApplication.shared.applicationState == .active", "self.view.window != nil", "self.isCentral == true", "self._isVisible == true", "!self.isAnimatingOut", "self.item?.isSecret == false", "!self.isLivePhoto", "currentPictureInPictureNode !== self", "videoNode.ownsContentNode", "!content.fileReference.media.isAnimated", "case .playing, .buffering(_, true, _, _)"]:
            self.assertIn(contract, unmute)
        self.assertIn("videoNode.setSoundMuted(soundMuted: false)", unmute)
        self.assertIn("videoNode.setSoundEnabled(true)", unmute)

    def test_unmute_does_not_seek_or_change_system_audio_configuration(self):
        unmute = body(self.gallery, "private func unmuteVideoForVolumeChange()")
        for forbidden in [".seek(", ".play(", ".setActive(", ".setCategory(", "outputVolume =", "MPVolumeView", "AVSystemController"]:
            self.assertNotIn(forbidden, unmute)

    def test_existing_background_pause_and_pip_guard_remain(self):
        self.assertIn("guard !inForeground, self.isCentral == true", self.gallery)
        self.assertIn("currentPictureInPictureNode !== self", self.gallery)
        self.assertIn("isRoundVideo ? ExteraMediaSettings.shared.pauseOnMinimizeRound : ExteraMediaSettings.shared.pauseOnMinimizeVideo", self.gallery)
        self.assertIn("self.videoNode?.pause()", self.gallery)


if __name__ == "__main__":
    unittest.main(verbosity=2)
