# Floating Dictionary

A lightweight, highly customizable floating dictionary for KOReader.

Instead of opening KOReader's full dictionary popup every time, **Floating Dictionary** displays a compact preview beside your selection, allowing you to continue reading without breaking your flow.

---

# Why?

KOReader's built-in dictionary is excellent for reading long entries, but most lookups only need a quick reminder.

Floating Dictionary adds an intermediate step:

> **Tap a word → Read the definition → Continue reading**

Open KOReader's full dictionary only when you actually need it.

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

| Style | Description |
|-------|-------------|
| **Classic** | Original Floating Dictionary interface |
| **Kobo** | Kobo-inspired layout with compact toolbar and cleaner typography |

---

## Cascading lookups

Explore definitions naturally without losing context.

Example

```text
Book
 ↓
Dog
 ↓
Fur
 ↓
DNA
```

| | |
|---|---|
| Breadcrumb navigation | Automatic stack limit |
| Animated back navigation | Continue reading without closing popups |

---

## Smarter dictionary ordering

Floating Dictionary automatically improves dictionary results.

| Automatic | Manual |
|-----------|--------|
| Detects word language | Reorder every installed dictionary |
| Detects translation dictionaries | Works with every dictionary type |
| Definition dictionaries first | Unconfigured dictionaries keep KOReader's order |
| Fully offline | Future dictionary types supported |

---

## Display modes

Switch the interface instantly.

| Mode | Purpose |
|------|---------|
| **Personal** | Uses your saved configuration |
| **Minimal** | Hides the footer |
| **Full** | Shows every available feature |
| **Language Learner** | Translation-first layout |

Changing modes never overwrites your Personal configuration.

---

## Popup customization

Personalize the popup to match your device.

| | |
|---|---|
| Font | Popup height |
| Font size | Border thickness |
| Border darkness | Popup style |
| Automatic book font | Custom CRE font |

---

## Footer customization

Every button can be configured independently.

| | |
|---|---|
| Show / Hide | Reorder |
| Rename | Custom SVG icon |
| Live preview | Per-button settings |

Custom SVG icons are loaded from:

```text
floatingdictionary-images/
```

---

## Dictionary navigation

When multiple dictionaries contain a result:

| | |
|---|---|
| Previous / Next buttons | Swipe gestures |
| Disabled navigation when unavailable | Live dictionary counter |

---

## Quick actions

| | |
|---|---|
| ✓ Highlight | ✓ Translate |
| ✓ Wikipedia | ✓ Full-text search |
| ✓ Vocabulary Builder | ✓ External plugin buttons |

Buttons added by other dictionary plugins are detected automatically.

---

## Highlight integration

Floating Dictionary completely integrates KOReader's highlight settings.

| | |
|---|---|
| Style | Color |
| Opacity | Line height |
| Note marker | Apply to all |
| PDF write-in | Instant refresh |

No page reload is required.

---

## Built-in highlight styles

### Fill styles

| | |
|---|---|
| Solid Medium | Grid Thin |
| Solid Light | Grid Thick |
| Dotted | Outline Thick |
| Diagonal Thin | Crosshatch |
| Diagonal Thick | Wavy Fill |

### Underline styles

| | |
|---|---|
| Plain | Thick |
| Fine | Dash |
| Dotted | Wavy |

Every style supports configurable line thickness.

---

## Word Review

A lightweight spaced-review system.

Automatically displays previously searched words:

| | |
|---|---|
| When opening a book | When waking the device |
| Per-book history | Easy history management |

Floating Dictionary automatically remembers the resolved dictionary entry whenever possible, improving future reviews.

---

## FastDict

Optional in-process dictionary engine.

| | |
|---|---|
| Near-instant lookups | No external `sdcv` process |
| Automatic fallback | Never breaks searches |
| Lower latency | Built-in index manager |

The index manager shows which dictionaries use FastDict and which continue using KOReader's standard engine.

---

# Installation

1. Download or clone this repository.
2. Copy:

```text
floatingdictionary.koplugin
```

into:

```text
plugins/
```

3. Restart KOReader.

---

# Usage

1. Tap or select a word.
2. Floating Dictionary displays a compact preview.
3. Tap another word inside the definition to continue exploring.
4. Navigate previous lookups using the breadcrumb.
5. Browse dictionaries with swipe gestures or navigation buttons.
6. Use the footer to highlight, translate, search, open Wikipedia or access external plugin actions.
7. Tap outside the popup to close the lookup session.

---

# Compatibility

| | |
|---|---|
| ✓ Recent KOReader releases | ✓ Built-in Translator |
| ✓ Vocabulary Builder | ✓ Every CRE font |
| ✓ External dictionary plugins | ✓ Offline translation detection |
| ✓ Built-in page-turn animations | ✓ Built-in highlight styles |
| ✓ FastDict fallback | ✓ No external patches required |

---

# License

Distributed under the same license as this repository.

Contributions, bug reports and feature requests are always welcome.
