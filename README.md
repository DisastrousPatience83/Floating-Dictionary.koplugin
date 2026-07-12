# Floating Dictionary EN/ES

A lightweight, highly customizable floating dictionary for KOReader.

Instead of opening KOReader's full dictionary popup every time, Floating Dictionary displays a compact preview beside your selection, allowing you to continue reading without breaking your flow.

---

# Why?

KOReader's built-in dictionary is excellent for reading long entries, but most lookups only need a quick reminder.

Floating Dictionary adds an intermediate step:

> **Tap a word → Read the definition → Continue reading**

Open KOReader's full dictionary only when you actually need it.

---

# Features

## Floating Preview

- Compact popup
- Shows the word, dictionary and definition
- Doesn't interrupt reading
- Tap outside to dismiss

### Popup Styles

Choose the appearance you prefer.

| Style | Description |
|-------|-------------|
| **Classic** | Original Floating Dictionary interface |
| **Kobo** | Kobo-inspired layout with compact toolbar and cleaner typography |

### Display Modes

Switch the interface instantly.

| Mode | Purpose |
|------|---------|
| **Personal** | Uses your saved configuration |
| **Minimal** | Hides the footer |
| **Full** | Shows every available feature |
| **Language Learner** | Translation-first layout |

> Changing modes never overwrites your **Personal** configuration.

### Popup Customization

Personalize the popup to match your device.

| Appearance | Appearance |
|------------|------------|
| Font | Popup height |
| Font size | Border thickness |
| Border darkness | Popup style |
| Automatic book font | Custom CRE font |

---

# Dictionary Experience

## Cascading Lookups

Explore definitions naturally without losing context.

### Example

```text
Book
 ↓
Dog
 ↓
Fur
 ↓
DNA
```

- Breadcrumb navigation
- Automatic stack limit
- Animated back navigation
- Continue reading without closing popups

---

## Phrase & Word Selection

Select a single word or a whole phrase and get the right tools either way.

| Dictionary Popup | Highlight / Add Note |
|------------------|----------------------|
| Shown side by side | Works for single words too |
| Kobo-style selection card | No need to choose between looking up or annotating |

Selecting a multi-word phrase no longer replaces the dictionary lookup with the Highlight/Add Note prompt. Both appear together, anchored to opposite edges of the screen, so you can read the definition and highlight or annotate the same selection without reopening the menu.

---

## Smart Highlight

Automatically highlight longer text selections without opening any popup.

Enable it from:

```text
KOReader Menu → Floating Dictionary → Context Menu → Smart Highlight
```

When enabled, Floating Dictionary analyzes the selection before opening any interface:

- **Single word** → Opens Floating Dictionary normally.
- **Hyphenated word** (`-`, `–`, `—`) → Opens Floating Dictionary normally.  
  Examples: `mother-in-law`, `well-known`, `Spanish–English`.
- **Two or more words** → Immediately creates a highlight.

When Smart Highlight activates:

- No dictionary popup appears.
- No Floating Dictionary context menu appears.
- No additional confirmation is required.
- The highlight is created instantly using your current highlight settings, including custom highlight styles configured through Floating Dictionary.

---

## Smarter Dictionary Ordering

Floating Dictionary automatically improves dictionary results.

| Automatic | Manual |
|-----------|--------|
| Detects word language | Reorder every installed dictionary |
| Detects translation dictionaries | Works with every dictionary type |
| Definition dictionaries first | Unconfigured dictionaries keep KOReader's order |
| Fully offline | Future dictionary types supported |

---

## Dictionary Navigation

When multiple dictionaries contain a result:

- Previous / Next buttons
- Swipe gestures
- Live dictionary counter
- Navigation buttons automatically disable when unavailable

---

# Toolbar & Actions

## Footer Customization

Every button can be configured independently.

| Feature | Feature |
|---------|---------|
| Show / Hide | Reorder |
| Rename | Custom SVG icon |
| Live preview | Per-button settings |

Custom SVG icons are loaded from:

```text
floatingdictionary-images/
```

---

## Built-in Actions

- ✓ Highlight
- ✓ Translate
- ✓ Wikipedia
- ✓ Full-text Search
- ✓ Vocabulary Builder
- ✓ Save for Review
- ✓ External Plugin Buttons

Buttons added by other dictionary plugins are detected automatically.

---

# Highlight Integration

Floating Dictionary fully integrates KOReader's highlight settings.

| Option | Option |
|--------|--------|
| Style | Color |
| Opacity | Line height |
| Note marker | Apply to all highlights |
| PDF write-in | Instant refresh |

No page reload is required.

## Built-in Highlight Styles

### Fill Styles

- Solid Medium
- Solid Light
- Grid Thin
- Grid Thick
- Dotted
- Outline Thick
- Diagonal Thin
- Diagonal Thick
- Crosshatch
- Wavy Fill

### Underline Styles

- Plain
- Fine
- Thick
- Dash
- Dotted
- Wavy

> Every style supports configurable line thickness.

---

# Word Review

A lightweight vocabulary-building system inspired by Kindle's Vocabulary Builder.

## Automatic Reviews

Previously searched words can automatically appear:

- When opening a book
- When waking the device
- Per-book history
- Easy history management

Floating Dictionary automatically remembers the resolved dictionary entry whenever possible, improving future reviews.

---

## Save for Review

Instead of saving every lookup automatically, you can now explicitly bookmark words using the **Save for Review** button.

### Manage Saved Words

| Feature | Feature |
|---------|---------|
| Cross-book word list | Words / Random / Mastered tabs |
| Multi-select | Bulk delete |
| Saved context sentence | Mark words as mastered |

Choose whether automatic reviews use:

- Saved words only
- Random dictionary headwords only
- A mix of both

---

## Flashcards

Study saved words one card at a time.

- Word and context sentence
- **See Definition** (inline dictionary lookup)
- Mark as Mastered
- Delete from the card
- Target word shown *italicized* inside its original sentence
- Jump to a random word from any book

---

# FastDict

Optional in-process dictionary engine.

| Feature | Feature |
|---------|---------|
| Near-instant lookups | No external `sdcv` process |
| Lower latency | Built-in index manager |
| Automatic fallback | Never breaks searches |

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
2. Read the floating definition.
3. Tap another word inside the definition to continue exploring.
4. Navigate previous lookups with the breadcrumb.
5. Switch dictionaries using swipe gestures or navigation buttons.
6. Use the footer to highlight, translate, search, save words, open Wikipedia or launch external plugin actions.
7. Tap outside the popup to dismiss it.

---

# Compatibility

| ✓ Supported | ✓ Supported |
|-------------|-------------|
| Recent KOReader releases | Built-in Translator |
| Vocabulary Builder | Every CRE font |
| External dictionary plugins | Offline translation detection |
| Built-in page-turn animations | Built-in highlight styles |
| FastDict fallback | No external patches required |
