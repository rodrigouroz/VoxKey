#!/usr/bin/env python3
"""Run release-mode comparisons sequentially, one model per process."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".build/whisper-comparison")
    parser.add_argument("--models", nargs="+")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    manifest = json.loads((root / "manifest.json").read_text())
    available = [model["id"] for model in manifest["models"]]
    requested = args.models or available
    if not set(requested).issubset(available):
        parser.error("Every requested model must be in manifest.json")
    environment = dict(os.environ)
    environment.pop("VOXKEY_MODEL_COMPARISON", None)
    with (root / "release-build.log").open("w") as log:
        subprocess.run(["swift", "test", "-c", "release", "--force-resolved-versions", "--no-parallel",
                        "--filter", "compareWhisperCandidate"], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    for model in requested:
        print(f"Benchmarking {model}", flush=True)
        environment["VOXKEY_MODEL_COMPARISON"] = str(root)
        environment["VOXKEY_COMPARISON_MODEL"] = model
        with (root / f"{model}.run.log").open("w") as log:
            subprocess.run(["swift", "test", "-c", "release", "--skip-build", "--no-parallel",
                            "--filter", "compareWhisperCandidate"], env=environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        print(f"Finished {model}", flush=True)
    subprocess.run(["python3", "scripts/models/summarize-comparison.py", str(root)], check=True)


if __name__ == "__main__":
    main()
