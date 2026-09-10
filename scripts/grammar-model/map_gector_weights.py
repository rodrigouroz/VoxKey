import coremltools as ct, pathlib, numpy as np, hashlib, json
from safetensors.numpy import load_file
from coremltools.libmilstoragepython import _BlobStorageReader
root=pathlib.Path(__file__).resolve().parent
source=root/'models/gotutiyan--gector-roberta-base-5k/model.safetensors'
weights=load_file(source)
lookup={}
for name,a in weights.items():
    for transpose,v in [(False,a),(True,a.T)] if a.ndim==2 else [(False,a)]:
        b=v.astype(np.float16).tobytes()
        lookup[hashlib.sha256(b).hexdigest()]=(name,transpose,len(b))
spec=ct.utils.load_spec(root/'Gector.mlpackage/Data/com.apple.CoreML/model.mlmodel')
reader=_BlobStorageReader(str(root/'Gector.mlpackage/Data/com.apple.CoreML/weights/weight.bin'))
rows=[]
for f in spec.mlProgram.functions.values():
 for block in f.block_specializations.values():
  for op in block.operations:
   for key,value in op.attributes.items():
    if value.WhichOneof('value')=='blobFileValue':
     offset=value.blobFileValue.offset
     data=reader.read_fp16_data(offset).tobytes()
     match=lookup.get(hashlib.sha256(data).hexdigest())
     rows.append(dict(offset=offset,bytes=len(data),match=match,op=op.outputs[0].name))
(root/'weight-mapping.json').write_text(json.dumps(rows,indent=2))
print('blobs',len(rows),'matched',sum(bool(r['match']) for r in rows))
print('unmatched', [r for r in rows if not r['match']])
