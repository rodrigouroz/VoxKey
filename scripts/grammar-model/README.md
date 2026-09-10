# Reproduce the grammar model recipe

These developer tools derive the small Core ML preparation resources shipped in
VoxKey. The app downloads and prepares its model natively; users do not need Python.
Model terms are separate from the MIT application license; read
[the grammar model terms](../../licenses/grammar/TERMS.md) before downloading.

Use Apple Silicon, Python 3.12, and the pinned dependencies below. Run from the
repository root. Downloads and generated files stay in the ignored `.build`
directory. Conversion needs several GB of disk space and memory.

```sh
mkdir -p .build/grammar-model
cp scripts/grammar-model/*.py .build/grammar-model/
UV_CACHE_DIR=.build/grammar-model/uv-cache uv venv --python 3.12 .build/grammar-model/venv
UV_CACHE_DIR=.build/grammar-model/uv-cache uv pip install --python .build/grammar-model/venv/bin/python -r scripts/grammar-model/requirements-reference.txt
git clone https://github.com/gotutiyan/gector.git .build/grammar-model/gector
git -C .build/grammar-model/gector checkout a4a342ed7c4733a34263443b605b7edffbef7099
git -C .build/grammar-model/gector apply ../../../scripts/grammar-model/gector-loader.patch
.build/grammar-model/venv/bin/python .build/grammar-model/convert_gector_coreml.py
.build/grammar-model/venv/bin/python .build/grammar-model/map_gector_weights.py
.build/grammar-model/venv/bin/python .build/grammar-model/make_native_recipe.py
```

The loader pins the checkpoint and base tokenizer revisions, verifies the
position-ID buffer, and loads all trained weights strictly. The converter uses
80-token inputs, FP16, a 0.3 keep bias, and a 0.6 confidence threshold. The mapper
and recipe generator write `Sources/VoxKeyApp/Resources/GrammarPreparation`.
Review the resulting diff; do not update the pinned model or hashes incidentally.

The shipped recipe's weight hash is
`3b39288c1b69d4011b4d398314a075f8e8f5f1518a097899f874e4e058b89690`.
Core ML records a fresh conversion date and generates new manifest UUIDs, so
those metadata bytes and the model-definition hash can differ on a repeat run.
The weight hash and tensor mapping must still match. Verify a regenerated
recipe with the native installer and the 64-case regression corpus as described
in [the model guide](../../docs/research/grammar-candidate.md#build-and-verify).
Never substitute a different model's output for the expected regression results.
