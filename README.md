# Floating Dictionary (KOReader plugin)

A compact, floating dictionary preview for [KOReader](https://github.com/koreader/koreader). Instead of jumping straight into the full-screen dictionary popup every time you look up a word, Floating Dictionary shows a small, unobtrusive card near your selection with the definition — and lets you dig deeper only if you want to.

## Why

KOReader's built-in dictionary lookup opens a large popup that takes over most of the screen. That's great when you actually want to read a long definition, but it's overkill for the common case: you just want a quick reminder of what a word means without losing your place or breaking your reading flow.

Floating Dictionary adds a lightweight preview step in between: tap a word, get a small card with the definition right there, and only open the full dictionary popup if you need it.

## Features

* **Compact floating preview** — shows the looked-up word, the source dictionary, and the definition in a small card instead of the full-screen popup.
* **Matches your book's typography** — the preview automatically uses the same font family as the book you're currently reading (falls back to your global CRE font setting, or a sane default if neither is available), unless you've picked an explicit preview font override (see below), which always wins.
* **Custom preview font** — a **Font** tab in the settings popup lets you pick any font face CRE knows about and use it for the preview instead of the book's font, or leave it on "Use book font" for the old automatic behaviour. Selecting a font applies live — the word, dictionary name, and definition all update instantly, no need to close the menu first. Since the list can get long depending on how many fonts you have installed, it's paginated instead of one giant scroll: `<<` / `<` / page indicator / `>` / `>>` chips to jump a page at a time or straight to the first/last page, plus swipe left/right on the popup as a shortcut for flipping one page.
* **Adjustable preview font size** — dedicated **A-** / **A+** buttons let you shrink or grow the preview's text (word, dictionary name, and definition) independently of the book's font size. The setting is remembered across lookups and app restarts. **The footer buttons now scale right along with it** (icon size, row height, and fallback labels), so the whole preview grows and shrinks together instead of the toolbar staying a fixed size.
* **Multiple dictionary results** — swipe or use the previous/next buttons to cycle through all dictionaries that matched your word, with a `x/y` counter. When there's only one result, the arrows simply gray out instead of disappearing.
* **Translate button** — send the looked-up word or phrase straight to KOReader's own built-in translator, using whichever source/target languages you already have configured. No extra plugin or dependency required.
* **Quick actions from the preview**, configurable from the plugin's menu:
  * Highlight the looked-up word
  * Full-text search in the book
  * Look it up on Wikipedia
  * Translate it
  * Add it to Vocabulary Builder (only shown if that plugin is installed)
* **External dictionary button passthrough** — if other plugins register their own buttons on the native dictionary popup, Floating Dictionary discovers and surfaces them in its own footer too, so you don't lose functionality by using the compact preview.
* **Fully customizable, reorderable footer** — a gear icon on the preview opens a settings popup with two tabs, **Buttons** and **Font**:
  * The **Buttons** tab lists every footer button (including the navigation arrows and the external-plugins group). From there you can:
    * Show or hide any action with a tap (arrows stay reorderable but can't be hidden, since they're always functionally needed)
    * Move any button up or down with dedicated ↑ / ↓ chips — only the arrows that would actually do something are shown, so the first button only gets ↓ and the last only gets ↑
    * See changes reflected instantly, with no need to close and reopen the popup
  * The **Font** tab is the custom preview font picker described above.
* **Per-action visibility settings** — the same show/hide state is also available from the plugin submenu, and you can toggle whether external buttons are shown at all. Settings persist across restarts and automatically stay in sync with future plugin updates — if an action is removed or a new one is added, your saved order adapts without breaking.
* **Cleaner compact labels** — on devices or themes without the icon set, footer buttons now fall back to a single capital letter instead of a shortened word, so labels never get clipped regardless of translation length.
* **E-ink friendly settings popup** — opening the settings menu, switching tabs, flipping font pages, or picking a font now only refreshes the small popup card itself instead of the whole screen, so navigating it doesn't flash/flicker like a full-screen refresh on e-ink devices.

## Installation

1. Download or clone this repository.
2. Copy the `floatingdictionary.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.

## Usage

1. Select or tap a word in a book like you normally would to trigger a dictionary lookup.
2. Instead of the full popup, a small card appears near your selection with the word, its source dictionary, and the definition.
3. From the footer of that card you can:
   * Move between multiple dictionary results (if more than one dictionary matched)
   * Trigger any enabled quick action (highlight, search, Wikipedia, translate, vocabulary)
   * Shrink/grow the preview text with **A-** / **A+** (the footer buttons scale along with it)
   * Tap the gear icon to open settings: show/hide or reorder footer buttons in the **Buttons** tab, or pick a custom preview font in the **Font** tab
4. Tap outside the card, or swipe, to dismiss it.

## Compatibility

* Requires KOReader (tested against recent stable builds; no external dependencies beyond what ships with KOReader).
* Designed to work alongside other dictionary-related plugins — it reads from the same dictionary results KOReader already produces and doesn't replace your installed dictionaries.
* Vocabulary Builder integration is optional and only activates if that plugin is present.
* Translate action uses KOReader's core translator module (`ui/translator`), which ships with every install — no extra setup needed beyond your existing translation language settings.
* Custom preview fonts are limited to font faces CRE already knows about on your device (the same list KOReader's own font menus use).
