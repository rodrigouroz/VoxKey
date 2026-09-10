# Grammar correction: third-party model terms

VoxKey's source code is MIT licensed. That license does **not** apply to the
third-party grammar model, its converted model definition, its tokenizer, or
its vocabulary data.

VoxKey offers an opt-in download and native Core ML
FP16 preparation of
`gotutiyan/gector-roberta-base-5k`, revision
`adaac6fb919431fb5a038b1e449055ae638613a4`:
https://huggingface.co/gotutiyan/gector-roberta-base-5k

The author's complete published restriction is: “Only non-commercial purposes.”
The original model card is included as `MODEL_CARD.md`. It does not specify a
standard license or an explicit redistribution/modification grant. The optional grammar feature
is offered for noncommercial use. VoxKey does not grant additional rights to
the model or relicense it under MIT.
The app downloads the checkpoint directly from the author's pinned revision;
VoxKey does not host or bundle the large model files. Neither downloading nor
local conversion removes the original noncommercial restriction.

The reference implementation is `gotutiyan/gector`, revision
`a4a342ed7c4733a34263443b605b7edffbef7099`, MIT, copyright 2022 gotutiyan.
VoxKey's Swift edit decoder follows that implementation. Its original license is
included as `gotutiyan-gector-LICENSE.txt`.

The verb-form vocabulary originates from `grammarly/gector`, revision
`3d41d2841512d2690cffce1b5ac6795fe9a0a5dd`, file `data/verb-form-vocab.txt`.
Its Apache 2.0 license is included as `grammarly-gector-LICENSE.txt`.
GECToR: Grammatical Error Correction: Tag, Not Rewrite, Omelianchuk et al. (2020):
https://aclanthology.org/2020.bea-1.16/

The tokenizer is the tokenizer supplied with the checkpoint, derived from
RoBERTa. Its files are not relicensed by VoxKey. Conversion provenance and
checksums are included in `GrammarPreparation/recipe.json` in the app's resource
bundle. That signed recipe pins all four downloads and the final FP16 weight
blob; conversion must reproduce the qualified blob's SHA-256 before activation.
