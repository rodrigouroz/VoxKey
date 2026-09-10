import pathlib
root = pathlib.Path(__file__).resolve().parent
from load_gector import model, torch
import coremltools as ct
import numpy as np

class TagPredictor(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        bias = torch.zeros(model.config.num_labels - 1)
        bias[model.config.label2id['$KEEP']] = 0.3
        self.register_buffer('keep_bias', bias)
        self.keep = model.config.label2id['$KEEP']
        self.incorrect = model.config.d_label2id['$INCORRECT']

    def forward(self, input_ids, attention_mask, word_masks):
        logits = self.model(input_ids, attention_mask)
        labels = torch.softmax(logits.logits_labels, dim=-1) + self.keep_bias
        error = (torch.softmax(logits.logits_d, dim=-1)[:, :, self.incorrect] * word_masks).max(dim=-1)[0]
        confidence, tags = labels.max(dim=-1)
        return torch.where(torch.logical_or(error[:, None] < 0.6, confidence < 0.6), self.keep, tags).to(torch.int32)

wrapper = TagPredictor(model).eval()
inputs = (torch.ones((1, 80), dtype=torch.int32), torch.ones((1, 80), dtype=torch.int32), torch.ones((1, 80), dtype=torch.int32))
with torch.inference_mode():
    traced = torch.jit.trace(wrapper, inputs)
converted = ct.convert(traced, inputs=[ct.TensorType(name=name, shape=(1, 80), dtype=np.int32)
                                      for name in ['input_ids', 'attention_mask', 'word_masks']],
                       outputs=[ct.TensorType(name='tags')],
                       convert_to='mlprogram', compute_precision=ct.precision.FLOAT16,
                       minimum_deployment_target=ct.target.macOS13)
converted.save(str(root / 'Gector.mlpackage'))
print('Converted Core ML package bytes:', sum(p.stat().st_size for p in (root / 'Gector.mlpackage').rglob('*') if p.is_file()), flush=True)
