"""Embed the artwork in the executable shipped through launcher-only updates."""
import base64
from pathlib import Path

ARTWORK = Path(__file__).resolve().parents[1] / "resources/launcher-artwork.jpg"


def embedded_artwork_source(folder):
    encoded = base64.b64encode(ARTWORK.read_bytes()).decode("ascii")
    source = folder / "EmbeddedLauncherArtwork.swift"
    literal = "\n".join(encoded[start:start + 120] for start in range(0, len(encoded), 120))
    source.write_text('let embeddedLauncherArtwork = """\n' + literal + '\n"""\n')
    return source
