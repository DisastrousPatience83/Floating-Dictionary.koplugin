# Floating Dictionary EN/ES

A lightweight, fully customizable floating dictionary for KOReader.

Floating Dictionary replaces the traditional dictionary workflow with a faster reading experience. Instead of opening KOReader's full dictionary window every time, it displays a compact floating preview directly beside your text selection while keeping the book visible.

Designed for language learners, heavy readers and dictionary users.

---

# Features

## Floating Dictionary

- Compact floating popup
- Doesn't interrupt reading
- Fast dictionary preview
- Tap outside to dismiss
- Scrollable definitions
- Automatic word detection
- Multiple dictionaries supported
- Instant popup refresh

---

# Popup Styles

Choose the interface you prefer.

| Style | Description |
|-------|-------------|
| Classic | Original Floating Dictionary interface |
| Kobo | Kobo-inspired layout |

Each style includes its own:

- Typography
- Spacing
- Borders
- Header layout
- Footer layout
- Dictionary formatting

---

# Display Modes

Floating Dictionary supports multiple interface profiles.

| Mode | Description |
|------|-------------|
| Personal | Uses your own configuration |
| Minimal | Hides footer actions |
| Full | Displays every available action |
| Language Learner | Translation-first interface |

Switching modes never overwrites your Personal configuration.

---

# Popup Customization

Completely personalize the popup.

## Appearance

- Font family
- Automatic book font detection
- Custom CRE font
- Popup font size
- Popup height
- Popup border thickness
- Popup border darkness
- Rounded borders

## Position

Choose how the popup appears.

- Near selected word
- Screen edge

Automatic positioning:

- Above selection
- Below selection

---

# Dictionary Experience

## Cascading Lookups

Navigate definitions naturally.

Example

```text
Book
 ↓
Dog
 ↓
Fur
 ↓
DNA
 ↓
Cell
```

Features:

- Unlimited lookup chain
- Breadcrumb navigation
- Automatic history trimming
- Animated back navigation
- Previous definitions remain accessible

---

## Breadcrumb Navigation

Displays every lookup in the current session.

Features

- Current word indicator
- Previous lookup history
- Automatic ellipsis for long chains
- One-tap back navigation

---

## Multiple Dictionaries

Works with every installed KOReader dictionary.

Supports:

- Definition dictionaries
- Translation dictionaries
- Bilingual dictionaries
- Thesaurus
- Synonyms
- Antonyms
- Pronunciation dictionaries
- Conjugation dictionaries
- Etymology dictionaries
- Any StarDict compatible dictionary

---

## Automatic Dictionary Ordering

Floating Dictionary automatically improves lookup quality.

Features

- Language detection
- Translation dictionary detection
- Automatic prioritization
- Offline operation
- Works without configuration

---

## Manual Dictionary Order

If preferred, dictionaries can be reordered manually.

Features

- Move up
- Move down
- Persistent order
- Works with every installed dictionary

---

## Dictionary Navigation

When multiple dictionaries return results.

Features

- Previous dictionary
- Next dictionary
- Swipe navigation
- Dictionary counter
- Disabled buttons at limits

---

# Phrase & Word Selection

Supports both single words and complete phrases.

Single word:

- Floating Dictionary
- Highlight
- Add note
- Translation

Multiple words:

- Floating Dictionary
- Highlight
- Add note

Both interfaces appear simultaneously.

---

# Smart Highlight

Automatically highlights long selections.

When enabled:

Single word

→ Floating Dictionary

Hyphenated word

→ Floating Dictionary

Multiple words

→ Highlight immediately

No popup appears.

No confirmation required.

---

# Footer Toolbar

Fully configurable toolbar.

Every button supports:

- Show / Hide
- Reorder
- Rename
- Custom SVG icon
- Live preview

---

# Built-in Actions

Included buttons:

- Highlight
- Translate
- Wikipedia
- Full Text Search
- Save for Review
- Vocabulary Builder

---

# External Plugin Integration

Automatically detects buttons registered by other dictionary plugins.

Compatible with:

- X-Ray
- Future dictionary plugins
- Custom plugin actions

No configuration required.

---

# Custom SVG Icons

Replace button letters with your own icons.

Icons are loaded from:

```text
floatingdictionary-images/
```

Supported:

- SVG
- Live reload
- Per-button icons

---

# Highlight Integration

Fully integrated with KOReader.

Supports:

- Highlight style
- Highlight color
- Highlight opacity
- Line height
- Note markers
- PDF write-in
- Instant refresh

No page reload required.

---

# Highlight Styles

Includes many built-in styles.

## Fill

- Solid Medium
- Solid Light
- Grid
- Dotted
- Diagonal
- Crosshatch
- Outline Thick
- Wavy Fill

## Underline

- Plain
- Fine
- Thick
- Dash
- Dotted
- Double
- Wavy

Every line-based style supports:

- Thickness
- Darkness

---

# Popup Animations

Optional page-turn inspired animations.

Features

- Opening animation
- Closing animation
- Swipe direction
- Hardware fallback
- Software fallback

Can be disabled completely.

---

# FastDict

Optional in-process dictionary engine.

Benefits

- Near-instant lookups
- No external sdcv process
- Lower latency
- Automatic fallback
- Compatible with normal dictionaries

---

# Word Review

Vocabulary review system inspired by Kindle Vocabulary Builder.

Features

- Automatic review popup
- Per-book history
- Cross-book history
- Lookup frequency tracking
- Context sentence
- Automatic word selection

Can appear:

- When opening a book
- After waking the device

---

# Save for Review

Save only important words.

Manage:

- Saved words
- Random words
- Mastered words

Features

- Multi-select
- Bulk delete
- Context sentence
- Cross-book storage
- Mark mastered

---

# Flashcards

Study saved vocabulary.

Each card contains:

- Word
- Context sentence
- Dictionary definition
- Previous dictionary
- Next dictionary

Actions

- See Definition
- Mark Mastered
- Delete
- Random Word

Target word appears italicized inside its original sentence.

---

# Vocabulary Management

Built-in management interface.

Features

- Kindle-inspired UI
- Tabs
- Search history
- Mastered words
- Saved words
- Random words
- Flashcards

---

# Language Detection

Automatically detects the language of the selected word.

Used for:

- Dictionary ordering
- Translation priority
- Better lookup accuracy

Works fully offline.

---

# Reader Integration

Deep integration with KOReader.

Supports:

- Built-in dictionary
- Built-in translator
- Built-in highlights
- Notes
- Full-text search
- Vocabulary Builder
- Page animations

---

# Performance

Optimized for eInk devices.

Features

- Low memory usage
- Instant popup refresh
- Fast redraw
- Scrollable definitions
- Cached rendering
- Minimal CPU usage

---

# Installation

1. Download this repository.

2. Copy

```text
floatingdictionary.koplugin
```

into

```text
plugins/
```

3. Restart KOReader.

---

# Usage

1. Select a word.
2. Read the floating definition.
3. Tap another word inside the definition.
4. Continue navigating.
5. Swipe between dictionaries.
6. Use toolbar actions.
7. Tap outside to close.

---

# Compatibility

Supports

- Recent KOReader releases
- Every CRE font
- EPUB
- FB2
- TXT
- HTML
- PDF
- Built-in Translator
- Vocabulary Builder
- External dictionary plugins
- FastDict
- Offline dictionaries

No external patches required.
