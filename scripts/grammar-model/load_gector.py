import os, pathlib, sys, urllib.request
root = pathlib.Path(__file__).resolve().parent
os.environ['HF_HOME'] = str(root / 'hf-cache')
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
sys.path.insert(0, str(root / 'gector/src'))
from huggingface_hub import snapshot_download
from safetensors.torch import load_file
import torch
from gector import GECToR, GECToRConfig

torch.set_num_threads(4)
name = 'gotutiyan/gector-roberta-base-5k'
revision = 'adaac6fb919431fb5a038b1e449055ae638613a4'
folder = root / 'models' / name.replace('/', '--')
snapshot_download(name, revision=revision, local_dir=folder,
                  allow_patterns=['*.json', '*.txt', 'README.md', 'model.safetensors'])
base = root / 'models/FacebookAI--roberta-base'
snapshot_download('FacebookAI/roberta-base', revision='e2da8e2f811d1448a5b465c236feacd80ffbac7b',
                  local_dir=base, allow_patterns=['*.json', 'merges.txt', 'vocab.json'])
vocab = root / 'verb-form-vocab.txt'
if not vocab.exists():
    urllib.request.urlretrieve('https://raw.githubusercontent.com/grammarly/gector/3d41d2841512d2690cffce1b5ac6795fe9a0a5dd/data/verb-form-vocab.txt', vocab)
config = GECToRConfig.from_pretrained(folder, local_files_only=True)
config.model_id = str(base)
model = GECToR(config)
# The conversion constructor initializes the encoder from its config to avoid
# fetching redundant base weights. The complete fine-tuned checkpoint must match.
state = load_file(folder / 'model.safetensors')
# Older Transformers persisted the deterministic position-id buffer. The current
# encoder registers the same values as a nonpersistent buffer. Verify before removing.
position_ids = state.pop('bert.embeddings.position_ids')
assert torch.equal(position_ids, model.bert.embeddings.position_ids)
incompatible = model.load_state_dict(state, strict=True)
print('Strict checkpoint load:', incompatible, flush=True)
model.eval()
