# Floating Dictionary (KOReader plugin)

A compact, floating dictionary preview for [KOReader](https://github.com/koreader/koreader). Instead of jumping straight into the full-screen dictionary popup every time you look up a word, Floating Dictionary shows a small, unobtrusive card near your selection with the definition — and lets you dig deeper only if you want to.

## Why

KOReader's built-in dictionary lookup opens a large popup that takes over most of the screen. That's great when you actually want to read a long definition, but it's overkill for the common case: you just want a quick reminder of what a word means without losing your place or breaking your reading flow.

Floating Dictionary adds a lightweight preview step in between: tap a word, get a small card with the definition right there, and only open the full dictionary popup if you need it.

## Features

* **Compact floating preview** — shows the looked-up word, the source dictionary, and the definition in a small card instead of the full-screen popup.
* **Matches your book's typography** — the preview automatically uses the same font family as the book you're currently reading (falls back to your global CRE font setting, or a sane default if neither is available).
* **Adjustable preview font size** — dedicated **A-** / **A+** buttons let you shrink or grow the preview's text (word, dictionary name, and definition) independently of the book's font size. The setting is remembered across lookups and app restarts. Footer buttons keep a fixed size so the toolbar stays consistent.
* **Multiple dictionary results** — swipe or use the previous/next buttons to cycle through all dictionaries that matched your word, with a `x/y` counter.
* **Quick actions from the preview**, configurable from the plugin's menu:

  * Highlight the looked-up word
  * Full-text search in the book
  * Look it up on Wikipedia
  * Add it to Vocabulary Builder (only shown if that plugin is installed)
* **External dictionary button passthrough** — if other plugins register their own buttons on the native dictionary popup, Floating Dictionary discovers and surfaces them in its own footer too, so you don't lose functionality by using the compact preview.
* **Per-action visibility settings** — turn any of the quick actions on/off from the plugin submenu, and toggle whether external buttons are shown at all.

## Installation

1. Download or clone this repository.
2. Copy the `floatingdictionary.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.

## Usage

1. Select or tap a word in a book like you normally would to trigger a dictionary lookup.
2. Instead of the full popup, a small card appears near your selection with the word, its source dictionary, and the definition.
3. From the footer of that card you can:

   * Move between multiple dictionary results (if more than one dictionary matched)
   * Trigger any enabled quick action (highlight, search, Wikipedia, vocabulary)
   * Shrink/grow the preview text with **A-** / **A+**
4. Tap outside the card, or swipe, to dismiss it.



## Compatibility

* Requires KOReader (tested against recent stable builds; no external dependencies beyond what ships with KOReader).
* Designed to work alongside other dictionary-related plugins — it reads from the same dictionary results KOReader already produces and doesn't replace your installed dictionaries.
* Vocabulary Builder integration is optional and only activates if that plugin is present.

