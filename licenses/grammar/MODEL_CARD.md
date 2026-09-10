---
language: en
tags:
- GECToR_gotutiyan
- grammatical error correction
---

Only non-commercial purposes.

# gector sample
This is an unofficial pretrained model of GECToR ([Omelianchuk+ 2020](https://aclanthology.org/2020.bea-1.16/)).

### How to use
The code is avaliable from https://github.com/gotutiyan/gector.

CLI
```sh
python predict.py --input <raw text file>     --restore_dir gotutiyan/gector-roberta-base-5k     --out <path to output file>
```

API
```py
from transformers import AutoTokenizer
from gector.modeling import GECToR
from gector.predict import predict, load_verb_dict
import torch

model_id = 'gotutiyan/gector-roberta-base-5k'
model = GECToR.from_pretrained(model_id)
if torch.cuda.is_available():
    model.cuda()
tokenizer = AutoTokenizer.from_pretrained(model_id)
encode, decode = load_verb_dict('data/verb-form-vocab.txt')
srcs = [
    'This is a correct sentence.',
    'This are a wrong sentences'
]
corrected = predict(
    model, tokenizer, srcs,
    encode, decode,
    keep_confidence=0.0,
    min_error_prob=0.0,
    n_iteration=5,
    batch_size=2,
)
print(corrected)
```
