# Vocabulary Package Format

VoxKey imports separately distributed recognition hints without embedding company terminology in the application or transcription model.

## Import and activation

Select an imported package and choose **View Contents…** to browse its terms, categories, priorities, and spoken forms. Search matches terms, categories, and spoken forms. The viewer is read only and works for both active and inactive packages; viewing does not change activation or saved vocabulary.

Open **Vocabulary…** from the menu bar. Personal terms are entered one per line and saved explicitly. **Import Package…** accepts a ZIP archive, a folder, or its `manifest.json` file. VoxKey validates the package, presents its name, version, classification, language, and term count, and imports it inactive. **Use this package** activates it for new dictations. Replacing the same identifier requires review and deactivates the replacement until explicitly enabled. Removing a package leaves the original source files untouched.

ZIPs must contain exactly one pair of `manifest.json` and `terms.json`, together at the archive root or inside one top-level folder. Finder metadata and unrelated files are ignored. Entries are decompressed into bounded memory without writing extracted files to disk; a private temporary copy of the compressed ZIP is removed after preview, including on failure. Archives must be unencrypted and cannot contain symlinks, unsafe paths, or duplicate paths. ZIP64 and multi-volume archives are not supported. ZIPs are limited to 8 MiB compressed, 8 MiB expanded, and 128 entries; the manifest and term-file limits below still apply.

Personal vocabulary and imported packages are stored locally in `~/Library/Application Support/com.rodrigouroz.VoxKey/vocabulary.json`. Writes are atomic, and a malformed saved file is reported rather than overwritten. Imported paths, recognition prompts, audio, and transcripts are not stored in this file. The application support directory is created with owner-only access.

## Schema version 1

A package is a directory with exactly these required filenames; unrelated files are ignored. The manifest references only the sibling `terms.json`. Symlinked input files and path traversal are rejected. The SHA-256 digest detects changed contents; it is not a publisher signature or proof of authorship.

`manifest.json`:

```json
{
  "schemaVersion": 1,
  "identifier": "org.example.vocabulary",
  "displayName": "Example Vocabulary",
  "version": "1.0",
  "classification": "personal",
  "locales": ["en"],
  "content": {
    "path": "terms.json",
    "sha256": "<64 hexadecimal characters: SHA-256 of the exact terms.json bytes>"
  }
}
```

`terms.json`:

```json
{
  "schemaVersion": 1,
  "locale": "en",
  "terms": [
    {
      "canonical": "Quasar Ledger",
      "category": "product",
      "priority": 100,
      "spokenForms": ["Quasar ledger"]
    }
  ]
}
```

`canonical` and `priority` are required; `category` and `spokenForms` are optional. Priority is an integer from 0 through 100. Terms are nonempty, trimmed, at most 80 characters, and cannot contain control characters, line breaks, or model-token delimiters. Each entry allows at most five spoken forms. Canonical duplicates are rejected using Unicode normalization and case-insensitive comparison. Personal duplicates are combined, preserving the first spelling.

Limits: 200 personal terms, 500 terms per package, 20 installed packages, 64 KiB per manifest, and 512 KiB per term file. Only the English locale (`en`) is accepted by the current English transcription model. Package identifiers contain only ASCII letters, digits, periods, hyphens, and underscores, with a maximum of 160 characters. Names, versions, classifications, and categories use the same text restrictions as terms.

## Recognition

Each trigger captures a value snapshot of the current vocabulary. Personal terms precede active package terms; package terms use descending priority, with import order and source order breaking ties. Canonical duplicates are removed across the combined list. Terms supply recognition hints, never post-transcription replacement rules, and VoxKey never learns from dictated text.

The selected model's actual tokenizer encodes complete hints, including spoken forms where supplied. Hints are added in order until the next complete hint would exceed the prompt budget. WhisperKit 1.1.0's budget is `Constants.maxTokenContext / 2 - 1`, currently 111 tokens. VoxKey bounds the prompt before calling the decoder so the library cannot discard high-priority terms through suffix truncation. The prompt stays in memory and is not logged.

WhisperKit 1.1.0 fixes premature end-token and confidence checks during forced prompt prefill. VoxKey now uses the standard decoder rather than its former `VocabularyTextDecoder` adapter. Installed-model regressions cover synthetic speech with personal and package hints, an exhausted prompt budget, short utterances, and silence. Ordinary speech sampling, confidence handling, and finalization remain owned by WhisperKit.

The public repository contains the format, loader, and synthetic test fixtures only. Company vocabulary, employee or customer data, internal download locations, and private package artifacts must not be committed or bundled with the application.

## Validation

The standard suite checks parsing, bounds, digest verification, archive rejection,
persistence, activation, and prompt selection using synthetic fixtures. Installed-model
checks are opt-in and do not establish accuracy across accents or microphones.

Optional integration tests accept `VOXKEY_VOCABULARY_TEST_PACKAGE` (a local package folder) and `VOXKEY_VOCABULARY_TEST_AUDIO` (a synthetic audio file saying “Please add Quasar Ledger to the project.”). Neither private packages nor generated audio are bundled with tests. Run `swift test --force-resolved-versions --no-parallel --filter 'suppliedLocalVocabularyPackageImportsWithoutBundlingItsContents|installedLocalModelTranscribesWithBoundedVocabularyHints'` with those variables set and the default model already installed.
