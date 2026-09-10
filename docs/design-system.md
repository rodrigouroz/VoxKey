# VoxKey design system

VoxKey uses the visual language established by Settings: warm neutral surfaces,
forest-green actions, a restrained lime brand accent, and native macOS controls.
Settings, Vocabulary, Last Dictation, and the status overlay share the palette in
`Sources/VoxKeyApp/VoxKeyDesign.swift`. New windows should use its components.
The public page in `docs/styles.css` declares the same values as CSS custom
properties; change a color in both places or not at all.

## Palette

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| Canvas | `#F4F5F0` | `#171C1B` | Window background |
| Surface | `#FFFFFF` | `#222927` | Section cards |
| Inset surface | `#F2F5F1` | `#1A211F` | Text fields and transcript |
| Ink | `#202D28` | `#F0F5EF` | Main text |
| Secondary ink | `#5D6C64` | `#ACBCB2` | Supporting text and metadata |
| Brand green (`brandGreen`) | `#356040` | `#416B4D` | Primary button fill with white text; the app's global accent color |
| Lime highlight (`accent`) | `#C1EF92` | `#C1EF92` | Brand mark; waveform; small highlights on dark surfaces |
| Accent ink | `#356040` | `#C1EF92` | Ready states and active icons |
| Accent wash | `#EAF4E1` | `#2B3B2B` | Subtle active-state background |
| Attention ink | `#A35830` | `#F2B68F` | Actionable warnings |
| Attention wash | `#FBEEE4` | `#3B2F28` | Warning background |
| Border | `#DCE3DA` | `#3D4942` | Card and field boundaries |

The recording overlay uses one fixed dark forest palette in either appearance,
exposed as `VoxKeyDesign.Overlay`. The public page's capture pill and privacy
panel use the same values.

| Overlay role | Value | Use |
| --- | --- | --- |
| Surface | `#20382B` | Pill and keycap fill |
| Border | `#43523F` | Pill outline |
| Key border | `#677C5D` | Keycap outline; idle waveform bars |
| Ink | `#F0F5E8` | Status text |
| Secondary ink | `#C1CEB7` | Keycap label |
| Attention | `#F2B68F` | Warning icon |

Follow system appearance. Increased Contrast strengthens borders to `#6C7B70`
in light appearance and `#A2B1A6` in dark appearance. Text and primary-button
color pairs meet a 4.5:1 contrast ratio; lime is not a text color on light surfaces,
and it barely reads as a fill there, so light mode leans on brand green.
Native controls retain their focus, keyboard, selection, and disabled behavior.

## Typography and geometry

- Use the system font, always through a `VoxKeyDesign.TextStyle`; do not set
  point sizes at call sites. Window titles are 26 pt bold; section titles are 17 pt
  semibold; item titles are 14 pt semibold; body text is 13 pt, with a medium
  `emphasis` variant; captions are 12 pt; footnotes are 11 pt, with a medium
  variant for state labels; `micro` is 10 pt medium for keycap-sized labels.
  Text editors use 14 pt.
- On the public page, body copy and demo captions never drop below 11 px.
  Compact metadata and decorative chrome may go smaller.
- The brand name is 17 pt bold. The 33 pt onboarding hero is reserved for the
  introductory “Press. Speak. Release.” message, not ordinary settings pages.
- Eyebrows use 11 pt system monospaced type, sparingly, for orientation. The
  `indicator` style is the semibold monospaced variant for check marks and glyphs.
- Window content has 28 pt horizontal and 20 pt vertical margins. Sections are
  separated by 20 pt; card content uses 18 pt padding and 12 pt gaps.
- Section cards have a 16 pt radius and a 1 pt border. Inset fields have a 10 pt
  radius, 1 pt border, and 12 pt text padding.
- Native button geometry stays native. The floating status overlay uses a dark
  forest-green pill in both appearances, matching the public page's dictation demo.
  During capture, a lime input waveform sits beside the status and a keycap for the
  configured trigger. The pill stays compact for ordinary capture and grows to keep
  toggle instructions and warnings readable. Warning icons remain amber.

## Components and behavior

Use `brandRow`, semantic `label` styles, `section`, `textField`, and `install`
from `VoxKeyDesign` for new windows. Use the shared layout constants when a
specialized layout, such as the prerequisite rows, needs its own composition.

Group controls with the content they affect. Use one green primary action per
section, with neutral secondary actions. Successful saves use quiet inline
feedback. A completed dictation without an input is normal completion:
“Your dictation is ready.” Show its text and make Copy prominent. Hide Deliver
until a destination is available. Never use a warning icon or amber surface
merely because no destination was selected.

Reserve amber for actionable problems and uncertain delivery. The uncertainty
explanation and explicit checked-input confirmation remain visible before a
retry. Preserve the established interaction and focus behavior when styling
these states. Do not add decorative animation or sound to settings actions.

## Validation

Run the existing AppKit layout and action tests when shared components change.
Inspect native windows in light and dark appearance, including empty and loaded
Vocabulary, normal Last Dictation, and uncertain delivery. Check long content,
native focus rings, scrolling, and Increased Contrast. Browser mockups communicate
direction; native AppKit rendering determines the shipped result.
