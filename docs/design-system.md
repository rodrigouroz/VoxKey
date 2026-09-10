# VoxKey design system

VoxKey windows are macOS windows first: system neutrals, native controls, and
grouped-form cards. VoxKey owns three brand colors, forest green for actions,
lime for the mark and highlights, and amber for attention, plus a serif voice
for titles that it shares with the public page. Setup, Settings, Vocabulary,
Last Dictation, and the status overlay share `Sources/VoxKeyApp/VoxKeyDesign.swift`.
New windows should use its components. The public page in `docs/styles.css`
declares the brand values as CSS custom properties; change a color in both
places or not at all.

## Palette

Neutrals are system colors. They adapt to appearance, Increased Contrast, and
future macOS changes without VoxKey maintaining hex values.

| Role | Token | System color |
| --- | --- | --- |
| Canvas | `canvas` | `windowBackgroundColor` |
| Surface | `surface` | White on the light window; white at 6.5% on the dark one |
| Inset surface | `insetSurface` | `textBackgroundColor` |
| Ink | `ink` | `labelColor` |
| Secondary ink | `secondaryInk` | `secondaryLabelColor` |
| Border | `border` | `separatorColor` |

Brand colors are VoxKey's own and carry light and dark variants.

| Role | Light | Dark | Use |
| --- | --- | --- | --- |
| Brand green (`brandGreen`) | `#356040` | `#416B4D` | Primary button fill with white text; the app's accent color asset |
| Lime highlight (`accent`) | `#A9DC78` | `#C1EF92` | Brand mark; waveform; highlights. Deeper in light so it reads as a fill |
| Accent ink (`accentInk`) | `#356040` | `#C1EF92` | Ready states and active icons |
| Accent wash (`accentWash`) | `#EAF4E1` | `#2B3B2B` | Subtle active-state background |
| Attention ink (`warm`) | `#A35830` | `#F2B68F` | Actionable warnings |
| Attention wash (`warmWash`) | `#FBEEE4` | `#3B2F28` | Warning background |

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

Text and primary-button color pairs meet a 4.5:1 contrast ratio. Lime is never a
text color on light surfaces. Native controls retain their focus, keyboard,
selection, and disabled behavior.

## Brand mark and icons

The mark is a lime keycap holding a five-bar waveform (`VoxKeyBrandMarkView`).
The app icon is the same drawing on a forest tile; its source is
`docs/assets/voxkey-icon.svg`, which also renders the site favicon. Regenerate
the asset catalog PNGs from that file rather than editing them by hand. The
menu bar uses a monochrome template version of the keycap (`menuBarMark`) in the
ready state and SF Symbols for capturing, busy, attention, and not-ready states.

## Typography and geometry

- Titles use the system serif, New York, through `TextStyle.windowTitle` (26 pt
  bold) and `TextStyle.onboardingHero` (33 pt bold, reserved for “Press. Speak.
  Release.”). Everything else is the system sans: section titles 17 pt semibold,
  item titles 14 pt semibold, body 13 pt with a medium `emphasis` variant,
  captions 12 pt, footnotes 11 pt with a medium variant for state labels,
  `micro` 10 pt medium for keycap-sized labels, and `indicator` for monospaced
  check marks. Always pick a `TextStyle`; do not set point sizes at call sites.
- No eyebrows in the app. Monospaced all-caps labels are a landing-page pattern
  and stay on the public page. Window titles and section titles carry orientation.
- On the public page, body copy and demo captions never drop below 11 px, and
  decorative chrome never below 10 px.
- Window content has 28 pt horizontal and 20 pt vertical margins. Sections are
  separated by 20 pt; card content uses 18 pt padding and 12 pt gaps.
- Cards have a 12 pt radius and a 1 pt separator border. Inset fields have an
  8 pt radius, 1 pt border, and 12 pt text padding.
- Native button geometry stays native. The floating status overlay uses a dark
  forest-green pill in both appearances, matching the public page's dictation demo.
  During capture, a lime input waveform sits beside the status and a keycap for the
  configured trigger. The pill stays compact for ordinary capture and grows to keep
  toggle instructions and warnings readable. Warning icons remain amber.

## Windows

- **Set Up VoxKey** (`OnboardingWindowController`) is the first-run flow:
  hero, three checks, optional grammar, readiness check, Finish Setup. It
  reopens from the menu while any check is unmet and shows the app in the Dock
  so permission dialogs cannot strand the user.
- **Settings** (`SettingsWindowController`, ⌘,) holds everyday preferences:
  trigger, Toggle Dictation, microphone, grammar, Launch at Login, feedback. It
  is an ordinary window that returns focus to the previous app when closed.
- Both windows show a `GrammarCorrectionCard`; AppController mirrors a change in
  one to the other.

## Components and behavior

Use semantic `label` styles, `section`, `separator`, `textField`, and `install`
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
Inspect native windows in light and dark appearance, including Set Up VoxKey,
Settings, empty and loaded Vocabulary, normal Last Dictation, and uncertain
delivery. Check long content, native focus rings, scrolling, and Increased
Contrast. Browser mockups communicate direction; native AppKit rendering
determines the shipped result.
