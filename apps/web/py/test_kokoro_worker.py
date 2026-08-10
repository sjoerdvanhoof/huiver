import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import soundfile as sf

import kokoro_worker as worker


class FakePipeline:
    def __call__(self, text, **_kwargs):
        # Multiple results verify that a chunk is appended rather than overwritten.
        yield text, "", np.full(4, 0.25, dtype=np.float32)
        yield text, "", np.full(3, -0.25, dtype=np.float32)


class KokoroWorkerAudioTests(unittest.TestCase):
    def setUp(self):
        self.messages = []
        self.pipeline = FakePipeline()
        self.patches = [
            patch.object(worker, "get_pipeline", return_value=self.pipeline),
            patch.object(worker, "emit", side_effect=self.messages.append),
            patch.object(worker, "_device", "cpu"),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()

    def test_track_streams_segments_and_gaps_to_one_wav(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "track.wav"
            worker.handle_track(
                {"id": "t1", "chunks": ["one", "two"], "out": str(out)}
            )

            audio, rate = sf.read(out, dtype="float32")
            expected_frames = 2 * (7 + int(worker.SAMPLE_RATE * worker.GAP_SECONDS))
            self.assertEqual(rate, worker.SAMPLE_RATE)
            self.assertEqual(len(audio), expected_frames)
            self.assertAlmostEqual(
                self.messages[-1]["duration"], expected_frames / worker.SAMPLE_RATE
            )
            np.testing.assert_allclose(audio[:4], 0.25, atol=1e-4)
            np.testing.assert_allclose(audio[4:7], -0.25, atol=1e-4)
            np.testing.assert_allclose(audio[7:17], 0, atol=1e-4)

    def test_empty_track_remains_a_valid_one_frame_wav(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "empty.wav"
            worker.handle_track({"id": "t2", "chunks": [], "out": str(out)})
            info = sf.info(out)
            self.assertEqual(info.samplerate, worker.SAMPLE_RATE)
            self.assertEqual(info.frames, 1)

    def test_track_batch_can_append_to_an_existing_wav(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "track.wav"
            worker.handle_track({"id": "a", "chunks": ["one"], "out": str(out)})
            worker.handle_track(
                {"id": "b", "chunks": ["two"], "out": str(out), "append": True}
            )
            info = sf.info(out)
            self.assertEqual(
                info.frames, 2 * (7 + int(worker.SAMPLE_RATE * worker.GAP_SECONDS))
            )

    def test_stream_writes_ordered_individual_wavs(self):
        with tempfile.TemporaryDirectory() as directory:
            worker.handle_stream(
                {"id": "s1", "chunks": ["one", "two"], "dir": directory}
            )
            audio_messages = [m for m in self.messages if m["type"] == "audio"]
            self.assertEqual([m["index"] for m in audio_messages], [0, 1])
            for message in audio_messages:
                info = sf.info(message["path"])
                self.assertEqual(info.samplerate, worker.SAMPLE_RATE)
                self.assertEqual(
                    info.frames, 7 + int(worker.SAMPLE_RATE * worker.GAP_SECONDS)
                )
            self.assertEqual(self.messages[-1], {"type": "done", "id": "s1"})

    def test_cancelled_track_closes_partial_wav_and_accepts_next_request(self):
        checks = iter([False, True])
        with tempfile.TemporaryDirectory() as directory, patch.object(
            worker, "is_cancelled", side_effect=lambda _rid: next(checks)
        ):
            partial = Path(directory) / "partial.wav"
            worker.handle_track(
                {"id": "cancel", "chunks": ["one", "two"], "out": str(partial)}
            )
            # Reopening for append proves the cancellation path closed the handle.
            with sf.SoundFile(partial, mode="r+"):
                pass

            with patch.object(worker, "is_cancelled", return_value=False):
                following = Path(directory) / "following.wav"
                worker.handle_track(
                    {"id": "next", "chunks": ["three"], "out": str(following)}
                )
                self.assertTrue(following.exists())


if __name__ == "__main__":
    unittest.main()
