#!/usr/bin/env python3
"""Summarize completed local Whisper benchmark evidence without uploading it."""
import json
import math
from pathlib import Path
import re
import statistics
import sys
import unicodedata


def words(text):
    return re.findall(r"[^\W_]+", unicodedata.normalize("NFC", text).casefold())


def distance(actual, expected):
    row = list(range(len(expected) + 1))
    for index, word in enumerate(actual):
        current = [index + 1]
        for column, reference in enumerate(expected):
            current.append(min(current[-1] + 1, row[column + 1] + 1, row[column] + (word != reference)))
        row = current
    return row[-1]


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/whisper-comparison")
    manifest = json.loads((root / "manifest.json").read_text())
    lines = ["| Model | Language | Mode | Word error rate | Median decode | p95 decode |",
             "| --- | --- | --- | ---: | ---: | ---: |"]
    details = []
    summary = []
    for candidate in manifest["models"]:
        path = root / (candidate["id"] + ".jsonl")
        if not path.exists():
            lines.append(f'| {candidate["id"]} | — | Not run | — | — | — |')
            continue
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        decodes = [row for row in rows if row["type"] == "decode"]
        expected = sum(f["language"] in candidate["languages"] for f in manifest["fixtures"]) * 3 * (2 if len(candidate["languages"]) > 1 else 1)
        if len(decodes) != expected:
            raise RuntimeError(f'{candidate["id"]}: incomplete evidence ({len(decodes)}/{expected})')
        for language, mode in sorted({(row["language"], row["mode"]) for row in decodes}):
            warm = [row for row in decodes if row["round"] > 0 and row["language"] == language and row["mode"] == mode]
            edits = sum(distance(words(row["transcription"]), words(row["reference"])) for row in warm)
            count = sum(len(words(row["reference"])) for row in warm)
            times = sorted(row["milliseconds"] for row in warm)
            result = dict(model=candidate["id"], language=language, mode=mode, wordErrors=edits,
                          referenceWords=count, wer=100 * edits / count, medianMS=statistics.median(times),
                          p95MS=times[math.ceil(len(times) * .95) - 1], samples=len(times),
                          languageMatches=sum(row["detectedLanguage"] == language for row in warm))
            summary.append(result)
            lines.append(f'| {candidate["id"]} | {language} | {mode} | {result["wer"]:.2f}% | {result["medianMS"]:.0f} ms | {result["p95MS"]:.0f} ms |')
            for row in warm:
                if row["round"] == 1 and words(row["transcription"]) != words(row["reference"]):
                    details.append(dict(model=candidate["id"], fixture=row["fixture"], mode=mode,
                                        reference=row["reference"], transcription=row["transcription"]))
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (root / "differences.json").write_text(json.dumps(details, indent=2, ensure_ascii=False) + "\n")
    (root / "table.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
