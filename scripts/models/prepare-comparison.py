#!/usr/bin/env python3
"""Prepare public model assets and synthetic speech; never inspect user recordings."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess

REPO = "argmaxinc/whisperkit-coreml"
MODELS = [
    ("distil-v3-compressed", "distil-whisper_distil-large-v3_594MB", ["en"]),
    ("distil-v3-full", "distil-whisper_distil-large-v3", ["en"]),
    ("turbo-compressed", "openai_whisper-large-v3-v20240930_626MB", ["en", "es"]),
    ("turbo-full", "openai_whisper-large-v3-v20240930", ["en", "es"]),
]
SCRIPTS = {
    "en": [
        ("short", "Please send me the notes after the meeting."),
        ("faithful", "These is the files I need. The new version work on my Mac."),
        ("negation", "The build is not ready. Do not deploy it. This is very very useful."),
        ("technical", "Please update the Quasar Ledger. Check the cache, the queue, and the schema. The final word is telescope."),
    ],
    "es": [
        ("short", "Por favor, mandame las notas después de la reunión."),
        ("voseo", "¿Podés revisar este cambio? Si encontrás un problema, avisame antes de publicarlo."),
        ("negation", "La versión no está lista. No la publiques todavía. Esto es muy muy importante."),
        ("technical", "Revisá la caché, la cola y el esquema de la base de datos. La última palabra es telescopio."),
    ],
}
VOICES = {"en": ["Samantha", "Daniel"], "es": ["Paulina", "Mónica"]}


def fetch(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".partial")
    subprocess.run(["curl", "-fLsS", "--retry", "5", "--retry-all-errors", url, "-o", str(partial)], check=True)
    partial.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=".build/whisper-comparison")
    parser.add_argument("--download", action="store_true", help="Download about 4.4 GB of public model packages in total")
    parser.add_argument("--distil-v35", type=Path, help="Include an already converted and tested Distil-v3.5 folder")
    parser.add_argument("--distil-v35-revision", help="Source weights commit used for the local conversion")
    args = parser.parse_args()
    if bool(args.distil_v35) != bool(args.distil_v35_revision):
        parser.error("--distil-v35 and --distil-v35-revision must be provided together")
    listed = subprocess.check_output(["say", "-v", "?"], text=True)
    installed = {line.split("  ", 1)[0].strip() for line in listed.splitlines()}
    missing = {voice for voices in VOICES.values() for voice in voices} - installed
    if missing:
        parser.error(f"Required exact system voice names are missing: {sorted(missing)}")
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=True)
    index_path = root / "argmax-index.json"
    if not index_path.exists():
        fetch(f"https://huggingface.co/api/models/{REPO}/revision/main", index_path)
    index = json.loads(index_path.read_text())
    revision = index["sha"]
    candidates = []
    for model_id, variant, languages in MODELS:
        folder = root / "models" / variant
        # Use a private copy/cache for every model, including the baseline.
        files = [entry["rfilename"] for entry in index["siblings"] if entry["rfilename"].startswith(variant + "/")]
        if not files:
            raise RuntimeError(f"No files for {variant} at {revision}")
        if args.download:
            print(f"Preparing {model_id}: {len(files)} files at {revision}", flush=True)
            def download(relative):
                destination = root / "models" / relative
                if not destination.exists():
                    fetch(f"https://huggingface.co/{REPO}/resolve/{revision}/{relative}", destination)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(download, files))
        candidates.append(dict(id=model_id, variant=variant, folder=str(folder), languages=languages, revision=revision))
    if args.distil_v35:
        folder = args.distil_v35.resolve()
        for component in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json", "generation_config.json"]:
            if not (folder / component).exists():
                raise RuntimeError(f"Missing converted component: {folder / component}")
        candidates.append(dict(id="distil-v3.5-full", variant="distil-whisper_distil-large-v3.5",
                               folder=str(folder), languages=["en"], revision=args.distil_v35_revision))
    fixtures = []
    for language, scripts in SCRIPTS.items():
        for voice in VOICES[language]:
            for name, reference in scripts:
                fixture_id = f"{language}-{voice}-{name}"
                path = root / "audio" / f"{fixture_id}.aiff"
                path.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(["say", "-v", voice, "-r", "165", "-o", str(path), reference], check=True)
                if path.stat().st_size <= 4096:
                    raise RuntimeError(f"Speech synthesis produced an empty fixture: {path}")
                fixtures.append(dict(id=fixture_id, language=language, voice=voice, path=str(path), reference=reference))
    (root / "manifest.json").write_text(json.dumps(dict(models=candidates, fixtures=fixtures), indent=2, ensure_ascii=False) + "\n")
    print(root / "manifest.json")


if __name__ == "__main__":
    main()
