import pathlib,json,hashlib,struct,base64
root=pathlib.Path(__file__).resolve().parent
repo=root.parent.parent
out=repo/'Sources/VoxKeyApp/Resources/GrammarPreparation'
out.mkdir(parents=True,exist_ok=True)
checkpoint=root/'models/gotutiyan--gector-roberta-base-5k'
source=(checkpoint/'model.safetensors').read_bytes()
header_size=struct.unpack('<Q',source[:8])[0]
header=json.loads(source[8:8+header_size])
raw=(root/'Gector.mlpackage/Data/com.apple.CoreML/weights/weight.bin').read_bytes()
rows=json.loads((root/'weight-mapping.json').read_text())
conversions=[]; occupied=[]
for row in rows:
    match=row['match']; repeat=1
    if row['op']=='keep_bias_to_fp16':continue
    if match is None:
        assert row['op']=='token_type_embeddings_1_to_fp16'
        match=['bert.embeddings.token_type_embeddings.weight',False,1536];repeat=80
    name,transpose,size=match
    assert not transpose
    tensor=header[name];assert tensor['dtype']=='F32'
    start,end=tensor['data_offsets']
    destination=struct.unpack('<Q',raw[row['offset']+16:row['offset']+24])[0]
    assert (end-start)//2*repeat==row['bytes']
    conversions.append(dict(sourceOffset=8+header_size+start,count=(end-start)//4,destinationOffset=destination,repetitions=repeat))
    occupied.append((destination,destination+row['bytes']))
constants=[];cursor=0
for start,end in sorted(occupied):
    if start>cursor:constants.append(dict(offset=cursor,data=base64.b64encode(raw[cursor:start]).decode()))
    cursor=end
if cursor<len(raw):constants.append(dict(offset=cursor,data=base64.b64encode(raw[cursor:]).decode()))
revision='adaac6fb919431fb5a038b1e449055ae638613a4'
base=f'https://huggingface.co/gotutiyan/gector-roberta-base-5k/resolve/{revision}'
files=[]
for name,path,url in [('model.safetensors',checkpoint/'model.safetensors',base+'/model.safetensors'),('tokenizer.json',checkpoint/'tokenizer.json',base+'/tokenizer.json'),('config.json',checkpoint/'config.json',base+'/config.json'),('verb-form-vocab.txt',root/'verb-form-vocab.txt','https://raw.githubusercontent.com/grammarly/gector/3d41d2841512d2690cffce1b5ac6795fe9a0a5dd/data/verb-form-vocab.txt')]:
    data=path.read_bytes();files.append(dict(name=name,url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
recipe=dict(identifier='gector-roberta-fp16-adaac6fb-v1',files=files,outputBytes=len(raw),outputSHA256=hashlib.sha256(raw).hexdigest(),constants=constants,conversions=conversions,modelBytes=len((root/'Gector.mlpackage/Data/com.apple.CoreML/model.mlmodel').read_bytes()),modelSHA256=hashlib.sha256((root/'Gector.mlpackage/Data/com.apple.CoreML/model.mlmodel').read_bytes()).hexdigest())
(out/'recipe.json').write_text(json.dumps(recipe,indent=2)+'\n')
(out/'model.mlmodel').write_bytes((root/'Gector.mlpackage/Data/com.apple.CoreML/model.mlmodel').read_bytes())
(out/'Manifest.json').write_bytes((root/'Gector.mlpackage/Manifest.json').read_bytes())
print('download bytes',sum(f['bytes'] for f in files),'app recipe bytes',sum(p.stat().st_size for p in out.iterdir()))
print('constant bytes',sum(len(base64.b64decode(c['data'])) for c in constants),'tensor conversions',len(conversions))
print(files)
