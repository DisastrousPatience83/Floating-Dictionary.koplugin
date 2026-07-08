# Floating Dictionary (KOReader Plugin)

A compact, floating dictionary preview for KOReader. Instead of jumping straight into the full-screen dictionary popup every time you look up a word, **Floating Dictionary** shows a small, unobtrusive card near your selection with the definition—and lets you dig deeper only if you want to.

---

# Why?

KOReader's built-in dictionary lookup opens a large popup that takes over most of the screen. That's great when you actually want to read a long definition, but it's overkill for the common case: you just want a quick reminder of what a word means without losing your place or breaking your reading flow.

Floating Dictionary adds a lightweight preview step in between:

- Tap a word.
- Instantly get a compact floating definition.
- Open the full dictionary only if you need more information.

---

# Features

## Compact floating preview

Instead of opening the native dictionary window immediately, the plugin displays a small floating card containing:

- Looked-up word
- Dictionary name
- Definition

This keeps your reading uninterrupted.

---

## Cascading lookups with breadcrumb trail

Looking up another word inside a definition opens another floating card on top of the current one.

Example:

```
Book
 ↓
Dog
 ↓
Fur
 ↓
DNA
```

A breadcrumb at the top lets you jump back instantly to any previous lookup.

The stack has a configurable depth limit to prevent unlimited growth.

This behavior is always enabled because it's considered a core feature of the plugin.

---

## Automatic translation dictionary detection

The plugin automatically:

- Detects the language of the selected word.
- Identifies bilingual dictionaries from their names.
- Pushes translation dictionaries to the end of the results.

Definition dictionaries therefore appear first without changing KOReader's own dictionary configuration.

---

## Manual dictionary ordering

Every installed dictionary can be manually reordered.

The system works for every dictionary type:

- Definitions
- Translation
- Synonyms
- Antonyms
- Pronunciation
- Conjugations
- Etymology
- Examples
- Thesaurus
- Any future dictionary supported by KOReader

Unconfigured dictionaries automatically fall back to the default ordering.

---

## Display modes

Quick one-tap profile switching.

### Personal

Uses your saved configuration.

(Default.)

### Minimal

Removes the footer entirely for the cleanest interface.

### Full

Shows every available dictionary, tool and action.

### Language Learner

- Translation dictionaries first
- Definition dictionaries second
- Wikipedia hidden
- Full-text search hidden

Changing modes never overwrites your Personal configuration.

---

## Page-turn style animations

Floating cards animate like page turns.

Opening:

- Left → Right

Closing:

- Right → Left

Returning through breadcrumbs also animates backwards.

Animations can be disabled.

---

## Uses the book's typography

By default, Floating Dictionary automatically uses:

1. Current book font
2. Global CRE font
3. Built-in fallback font

A manually selected font always overrides this behavior.

---

## Custom preview font

The Font tab lets you choose any installed CRE font.

Features:

- Live preview
- Pagination
- Swipe navigation
- Previous / Next buttons

---

## Adjustable font size

Dedicated buttons:

- A−
- A+

The size is remembered between sessions.

Footer icons scale together with the text.

---

## Adjustable popup size

Choose the popup height as a percentage of the screen.

Ideal for:

- Phones
- Tablets
- Large eReaders

---

## Custom popup border

Configure:

- Border thickness
- Border darkness

---

## Multiple dictionary results

Navigate through every matching dictionary using:

- Previous button
- Next button
- Swipe gestures

If only one dictionary exists, navigation buttons become disabled instead of disappearing.

---

## Translate button

Immediately sends the selected word or phrase to KOReader's built-in translator.

---

## Quick actions

Any footer action can be enabled or disabled.

Available actions include:

- Highlight
- Full-text search
- Wikipedia
- Translate
- Vocabulary Builder

---

## External plugin buttons

If another plugin adds buttons to KOReader's native dictionary popup, Floating Dictionary automatically detects and displays them.

---

## Fully customizable footer

Settings are divided into two tabs.

### Buttons

- Show / hide actions
- Reorder buttons
- Live updates

### Font

- Choose preview font
- Live preview

---

## Custom footer icons

Every button can use:

1. Custom SVG icon
2. Custom text
3. Single-letter fallback

Place custom SVG files inside:

```
floatingdictionary-images/
```

---

## Per-button visibility

Every footer button can be shown or hidden independently.

Settings are remembered permanently.

---

## Embedded highlight styles

Includes nine built-in highlight styles:

- Solid Medium
- Solid Light
- Dotted
- Diagonal Thin
- Diagonal Thick
- Grid Thin
- Grid Thick
- Outline Thick
- Crosshatch

Line thickness is configurable.

No external patch required.

---

## Integrated highlight settings

Floating Dictionary absorbs KOReader's own Highlight menu.

Includes:

- Style
- Color
- Opacity
- Line height
- Note marker
- Apply to all
- PDF write-in

Applying a style now refreshes highlights immediately without requiring a page reload.

---

## Word Review

A lightweight spaced-review system.

The plugin remembers words looked up for each book.

A random previous word appears automatically:

- When opening a book
- When waking the device

History can be managed or cleared from the settings menu.

---

## Fast Lookups (FastDict)

Optional in-process dictionary engine.

Advantages:

- Near-instant lookups
- No external `sdcv` process
- Automatic fallback to KOReader's normal lookup if necessary
- Never breaks searches

FastDict includes an index manager showing which dictionaries use FastDict and which continue using KOReader's standard engine.

---

# Installation

1. Download or clone this repository.
2. Copy the `floatingdictionary.koplugin` folder into:

```
plugins/
```

3. Restart KOReader.

---

# Usage

1. Tap or select a word.
2. Floating Dictionary displays a compact preview.
3. Select another word inside the definition to create another floating card.
4. Use the breadcrumb to navigate previous lookups.
5. Use footer buttons to:
   - Switch dictionaries
   - Highlight
   - Search
   - Translate
   - Open Wikipedia
   - Add to Vocabulary Builder
6. Tap outside the popup to dismiss the entire lookup session.

---

# Compatibility

- Compatible with recent KOReader releases.
- Uses KOReader's existing dictionary engine.
- Works alongside other dictionary plugins.
- Vocabulary Builder integration is optional.
- Uses KOReader's built-in Translator.
- Supports every CRE font installed on the device.
- Built-in animations require no external patches.
- Translation dictionary detection works completely offline.
- Highlight styles are built into the plugin.
- FastDict automatically falls back to KOReader's standard lookup whenever necessary.

---

# License

This project is distributed under the same license as the repository.

Contributions, bug reports, and feature requests are welcome.
