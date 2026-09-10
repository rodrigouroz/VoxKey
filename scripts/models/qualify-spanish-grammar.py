#!/usr/bin/env python3
"""Local, opt-in qualification of a public Spanish grammar candidate; never used by the app."""
import argparse
import json
from pathlib import Path
import statistics
import time
import unicodedata

MODEL = "dreuxx26/Multilingual-grammar-Corrector-using-mT5-small"
REVISION = "1e7f08320a74dd0307101d31e8620acffffa51a9"
# Curated before inference. Exact matches are a strict screen, not a general GEC score.
FIXTURES = [
    ("agreement-singular", "La niña están cansada.", "La niña está cansada."),
    ("agreement-plural", "Los archivo está listo.", "Los archivos están listos."),
    ("agreement-verb", "Los modelos funciona en mi computadora.", "Los modelos funcionan en mi computadora."),
    ("agreement-gender", "La reunión está programado para mañana.", "La reunión está programada para mañana."),
    ("accent", "El cafe está caliente.", "El café está caliente."),
    ("preserve-past", "Yo fui a la tienda ayer.", "Yo fui a la tienda ayer."),
    ("preserve-negation", "No debemos borrar los datos.", "No debemos borrar los datos."),
    ("preserve-authorization", "El despliegue no está autorizado.", "El despliegue no está autorizado."),
    ("preserve-voseo-question", "¿Podés revisar el cambio y avisarme cuando esté listo?", "¿Podés revisar el cambio y avisarme cuando esté listo?"),
    ("preserve-voseo", "Vos tenés razón.", "Vos tenés razón."),
    ("preserve-numbers", "El importe es 125,50 pesos y la versión es 2.1.0.", "El importe es 125,50 pesos y la versión es 2.1.0."),
    ("preserve-technical", "Actualizá PostgreSQL y revisá la caché.", "Actualizá PostgreSQL y revisá la caché."),
    ("preserve-repetition", "Esto es muy, muy importante.", "Esto es muy, muy importante."),
    ("preserve-identifier", "El campo user_id no puede ser null.", "El campo user_id no puede ser null."),
]


def normalized(text):
    return " ".join(unicodedata.normalize("NFC", text).split())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".build/whisper-comparison")
    parser.add_argument("--download-only", action="store_true")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    from huggingface_hub import snapshot_download
    folder = snapshot_download(MODEL, revision=REVISION, cache_dir=root / "hf-cache/hub",
                               allow_patterns=["*.json", "*.safetensors", "spiece.model"],
                               local_files_only=not args.download_only)
    if args.download_only:
        print(folder)
        return
    import torch
    from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
    torch.set_num_threads(4)
    start = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(folder, trust_remote_code=False, local_files_only=True, use_fast=False)
    model = AutoModelForSeq2SeqLM.from_pretrained(folder, use_safetensors=True,
                                               trust_remote_code=False, local_files_only=True).eval()
    metadata = dict(model=MODEL, revision=REVISION, device="cpu", threads=4,
                    loadMS=(time.perf_counter() - start) * 1000,
                    note="Exploratory Python CPU inference, not production Core ML latency.")
    rows = []
    with (root / "spanish-grammar.jsonl").open("w") as log, torch.inference_mode():
        log.write(json.dumps(dict(type="metadata", **metadata)) + "\n")
        for round_index in range(3):
            for fixture, text, expected in FIXTURES:
                inputs = tokenizer(text, return_tensors="pt")
                start = time.perf_counter()
                output = model.generate(**inputs, max_new_tokens=64, do_sample=False)
                elapsed = (time.perf_counter() - start) * 1000
                corrected = tokenizer.decode(output[0], skip_special_tokens=True)
                row = dict(type="decode", round=round_index, fixture=fixture, text=text, expected=expected,
                           corrected=corrected, milliseconds=elapsed,
                           exactMatch=normalized(corrected) == normalized(expected))
                rows.append(row)
                log.write(json.dumps(row, ensure_ascii=False) + "\n")
                log.flush()
                print(json.dumps(row, ensure_ascii=False), flush=True)
    warm = [r for r in rows if r["round"] > 0]
    summary = dict(**metadata, uniqueFixtures=len(FIXTURES),
                   correctionMatches=sum(r["exactMatch"] for r in warm if not r["fixture"].startswith("preserve")),
                   correctionSamples=sum(not r["fixture"].startswith("preserve") for r in warm),
                   preservationMatches=sum(r["exactMatch"] for r in warm if r["fixture"].startswith("preserve")),
                   preservationSamples=sum(r["fixture"].startswith("preserve") for r in warm),
                   medianMS=statistics.median(r["milliseconds"] for r in warm))
    (root / "spanish-grammar-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
