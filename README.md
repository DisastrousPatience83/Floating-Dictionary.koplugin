# Floating Dictionary

A lightweight, highly customizable floating dictionary for KOReader.

Instead of opening KOReader's full dictionary popup every time, Floating Dictionary displays a compact preview beside your selection, allowing you to continue reading without breaking your flow.

---

## Why?

KOReader's built-in dictionary is excellent for reading long entries, but most lookups only need a quick glance.

Floating Dictionary adds an intermediate step:

- Tap a word.
- Read a compact definition.
- Continue reading.
- Open the full dictionary only when needed.

---

# Features

## Floating preview

- Compact popup
- Word, dictionary and definition
- Doesn't interrupt reading
- Tap outside to dismiss

---

## Multiple popup styles

Choose the appearance you prefer.

### Classic

The original Floating Dictionary design.

### Kobo

- Kobo-inspired layout
- Compact toolbar
- Cleaner typography
- Rectangular popup

---

## Cascading lookups

Follow links inside definitions without losing context.

- Infinite lookup chain
- Breadcrumb navigation
- Automatic stack management
- Back navigation with animations

Example

```
Book
 ↓
Dog
 ↓
Fur
 ↓
DNA
```

---

## Smarter dictionary ordering

Floating Dictionary automatically improves dictionary results.

- Detects the language
- Detects translation dictionaries
- Prioritizes definition dictionaries
- Fully offline

You can also manually reorder every installed dictionary.

---

## Display modes

Switch the interface instantly.

| Mode | Description |
|------|-------------|
| Personal | Uses your saved configuration |
| Minimal | Footer hidden |
| Full | Everything enabled |
| Language Learner | Translation-first layout |

---

## Popup customization

Personalize the entire popup.

- Font
- Font size
- Height
- Border thickness
- Border darkness
- Classic or Kobo style

---

## Footer customization

Every button is individually configurable.

- Show / hide
- Reorder
- Rename
- Custom SVG icon
- Live preview

Custom icons are loaded from

```
floatingdictionary-images/
```

---

## Dictionary navigation

When multiple dictionaries match:

- Swipe
- Previous / Next buttons
- Disabled navigation when unavailable

---

## Quick actions

Available actions include:

- Highlight
- Translate
- Wikipedia
- Full-text search
- Vocabulary Builder

Buttons added by other dictionary plugins are detected automatically.

---

## Highlight integration

Floating Dictionary completely replaces KOReader's highlight menu.

Configure:

- Style
- Color
- Opacity
- Line height
- Note marker
- PDF write-in

Changes apply immediately.

---

## Built-in highlight styles

16 styles included.

**Fill**

- Solid Medium
- Solid Light
- Dotted
- Diagonal Thin
- Diagonal Thick
- Grid Thin
- Grid Thick
- Outline Thick
- Crosshatch
- Wavy Fill

**Underline**

- Plain
- Fine
- Thick
- Dash
- Dotted
- Wavy

Each style has configurable line thickness.

---

## Word Review

Review previously searched words automatically.

Appears when:

- Opening a book
- Waking the device

History is stored separately for every book.

---

## FastDict

Optional in-process dictionary engine.

- Near-instant lookups
- No external `sdcv`
- Automatic fallback
- Built-in index manager

---

# Installation

1. Download or clone this repository.
2. Copy `floatingdictionary.koplugin` into:

```
plugins/
```

3. Restart KOReader.

---

# Compatibility

- Recent KOReader releases
- Built-in Translator
- Vocabulary Builder
- Every CRE font
- External dictionary plugins
- Offline translation detection
- No external patches required

---

# License

Distributed under the same license as the repository.

Contributions, bug reports and feature requests are always welcome.
