"""Speaker identification using pyannote embedding model.

Extracts voice embeddings from audio segments and matches against known speaker profiles.
"""

import logging
import os
from pathlib import Path

import numpy as np

logger = logging.getLogger(__name__)


class SpeakerIdentifier:
    """Extracts and compares speaker embeddings using pyannote's embedding model."""

    def __init__(self, embeddings_dir: str | None = None):
        self._model = None
        self._embeddings_dir = embeddings_dir or self._default_embeddings_dir()

        try:
            from pyannote.audio import Model, Inference

            token = os.environ.get("HF_TOKEN")
            if not token:
                logger.warning("No HF_TOKEN — speaker identification disabled")
                return

            logger.info("Loading pyannote embedding model...")
            model = Model.from_pretrained(
                "pyannote/wespeaker-voxceleb-resnet34-LM",
                use_auth_token=token,
            )
            self._model = Inference(model, window="whole")
            logger.info("Speaker embedding model loaded")
        except ImportError:
            logger.warning("pyannote.audio not installed — speaker identification disabled")

    @staticmethod
    def _default_embeddings_dir() -> str:
        home = Path.home()
        d = home / "Library" / "Application Support" / "MeetNotes" / "embeddings"
        d.mkdir(parents=True, exist_ok=True)
        return str(d)

    @property
    def available(self) -> bool:
        return self._model is not None

    def extract_embedding(self, audio_path: str, start: float = 0.0, end: float | None = None) -> np.ndarray | None:
        """Extract a voice embedding from an audio segment.

        Args:
            audio_path: Path to the audio file.
            start: Start time in seconds.
            end: End time in seconds (None = entire file).

        Returns:
            Embedding numpy array, or None if extraction fails.
        """
        if not self._model:
            return None

        try:
            from pyannote.core import Segment

            if end is not None and end > start:
                excerpt = Segment(start, end)
                embedding = self._model.crop(audio_path, excerpt)
            else:
                embedding = self._model(audio_path)

            return np.array(embedding)
        except Exception as e:
            logger.error(f"Embedding extraction failed: {e}")
            return None

    def save_embedding(self, name: str, embedding: np.ndarray) -> str:
        """Save a speaker embedding to disk.

        Args:
            name: Speaker name (used as filename).
            embedding: Numpy embedding array.

        Returns:
            Path to the saved .npy file.
        """
        # Sanitize name for filesystem
        safe_name = "".join(c if c.isalnum() or c in "-_ " else "_" for c in name).strip()
        safe_name = safe_name[:100]
        if not safe_name:
            raise ValueError("Speaker name produces empty filename after sanitization")
        path = os.path.join(self._embeddings_dir, f"{safe_name}.npy")
        np.save(path, embedding)
        logger.info(f"Saved embedding for '{name}' at {path}")
        return path

    def load_embedding(self, path: str) -> np.ndarray | None:
        """Load a speaker embedding from disk."""
        try:
            return np.load(path, allow_pickle=False)
        except Exception as e:
            logger.error(f"Failed to load embedding from {path}: {e}")
            return None

    def compare(self, embedding_a: np.ndarray, embedding_b: np.ndarray) -> float:
        """Compute cosine similarity between two embeddings.

        Returns:
            Similarity score in [-1.0, 1.0]. Higher = more similar.
        """
        norm_a = np.linalg.norm(embedding_a)
        norm_b = np.linalg.norm(embedding_b)
        if norm_a == 0 or norm_b == 0:
            return 0.0
        return float(np.dot(embedding_a, embedding_b) / (norm_a * norm_b))

    def identify(
        self,
        embedding: np.ndarray,
        known_speakers: list[dict],
        threshold: float = 0.65,
    ) -> str | None:
        """Match an embedding against known speaker profiles.

        Args:
            embedding: The unknown speaker's embedding.
            known_speakers: List of dicts with "name" and "embedding_path" keys.
            threshold: Minimum cosine similarity for a match.

        Returns:
            Name of the best matching speaker, or None if no match above threshold.
        """
        best_score = -1.0
        best_name = None

        for speaker in known_speakers:
            path = speaker.get("embedding_path", "")
            if not path or not os.path.isfile(path):
                continue

            known_emb = self.load_embedding(path)
            if known_emb is None:
                continue

            score = self.compare(embedding, known_emb)
            if score > best_score:
                best_score = score
                best_name = speaker.get("name")

        if best_score >= threshold and best_name:
            logger.info(f"Identified speaker as '{best_name}' (score={best_score:.3f})")
            return best_name

        logger.info(f"No speaker match above threshold {threshold} (best={best_score:.3f})")
        return None
