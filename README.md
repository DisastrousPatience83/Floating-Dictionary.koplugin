# Floating Dictionary (KOReader plugin)

A compact, floating dictionary preview for [KOReader](https://github.com/koreader/koreader). Instead of jumping straight into the full-screen dictionary popup every time you look up a word, Floating Dictionary shows a small, unobtrusive card near your selection with the definition — and lets you dig deeper only if you want to.

## Why

KOReader's built-in dictionary lookup opens a large popup that takes over most of the screen. That's great when you actually want to read a long definition, but it's overkill for the common case: you just want a quick reminder of what a word means without losing your place or breaking your reading flow.

Floating Dictionary adds a lightweight preview step in between: tap a word, get a small card with the definition right there, and only open the full dictionary popup if you need it.

## Features

* **Compact floating preview** — shows the looked-up word, the source dictionary, and the definition in a small card instead of the full-screen popup.
* **Cascading lookups with breadcrumb trail** — selecting a word from inside a definition stacks a new card on top of the previous one instead of replacing it, and a breadcrumb strip (e.g. "... → Patas → Pelo → ADN") shows the trail of lookups. Tap any earlier word in the breadcrumb to jump straight back to it, closing everything opened after it. A depth cap keeps the stack from growing forever. This is always on and is no longer a configurable option — it's core to how the plugin works.
* **Automatic translation-dictionary detection and ordering** — the plugin no longer requires you to manually pick which installed dictionaries are "translation dictionaries." It automatically guesses the language of the looked-up word from its own spelling, recognizes which installed dictionaries look like bilingual/translation dictionaries by their name, and pushes those to the end of the result pages — so your normal definition dictionaries always come first (e.g. 1/2 = definition, 2/2 = translation), even if a translation dictionary is enabled as a regular dictionary in KOReader's own settings. Designed to scale to more languages as you install more translation dictionaries, with no manual configuration required.
* **Page-turn style slide animation** — cards slide in left-to-right when opening (initial lookup or a new cascade step) and slide out right-to-left when closing, using a self-contained software wipe animation (no external patch needed). Going back to an earlier word via the breadcrumb animates right-to-left instead, matching the direction of "going back." Paging between results or changing font size within the same card redraws in place with no transition.
* **Matches your book's typography** — the preview automatically uses the same font family as the book you're currently reading (falls back to your global CRE font setting, or a sane default if neither is available), unless you've picked an explicit preview font override (see below), which always wins.
* **Custom preview font** — a **Font** tab in the settings popup lets you pick any font face CRE knows about and use it for the preview instead of the book's font, or leave it on "Use book font" for the old automatic behaviour. Selecting a font applies live — the word, dictionary name, and definition all update instantly, no need to close the menu first. Since the list can get long depending on how many fonts you have installed, it's paginated instead of one giant scroll: `<<` / `<` / page indicator / `>` / `>>` chips to jump a page at a time or straight to the first/last page, plus swipe left/right on the popup as a shortcut for flipping one page.
* **Adjustable preview font size** — dedicated **A-** / **A+** buttons let you shrink or grow the preview's text (word, dictionary name, and definition) independently of the book's font size. The setting is remembered across lookups and app restarts. The footer buttons scale right along with it (icon size, row height, and fallback labels), so the whole preview grows and shrinks together instead of the toolbar staying a fixed size.
* **Multiple dictionary results** — swipe or use the previous/next buttons to cycle through all dictionaries that matched your word, with definition dictionaries always ordered ahead of translation dictionaries. When there's only one result, the arrows simply gray out instead of disappearing.
* **Translate button** — send the looked-up word or phrase straight to KOReader's own built-in translator, using whichever source/target languages you already have configured. No extra plugin or dependency required.
* **Quick actions from the preview**, configurable from the plugin's menu:
  * Highlight the looked-up word
  * Full-text search in the book
  * Look it up on Wikipedia
  * Translate it
  * Add it to Vocabulary Builder (only shown if that plugin is installed)
* **External dictionary button passthrough** — if other plugins register their own buttons on the native dictionary popup, Floating Dictionary discovers and surfaces them in its own footer too, so you don't lose functionality by using the compact preview.
* **Fully customizable, reorderable footer** — a gear icon on the preview opens a settings popup with two tabs, **Buttons** and **Font**:
  * The **Buttons** tab lists every footer button, including the previous/next navigation arrows and the external-plugins group — all of them can now be shown, hidden, and reordered just like any other action, since cycling between results is always still available via swipe. From there you can:
    * Show or hide any action with a tap
    * Move any button up or down with dedicated ↑ / ↓ chips — only the arrows that would actually do something are shown, so the first button only gets ↓ and the last only gets ↑
    * See changes reflected instantly, with no need to close and reopen the popup
  * The **Font** tab is the custom preview font picker described above.
* **Per-action visibility settings** — the same show/hide state is also available from the plugin submenu, and you can toggle whether external buttons are shown at all. Settings persist across restarts and automatically stay in sync with future plugin updates — if an action is removed or a new one is added, your saved order adapts without breaking.
* **Cleaner compact labels** — on devices or themes without the icon set, footer buttons now fall back to a single capital letter instead of a shortened word, so labels never get clipped regardless of translation length.

## Installation

1. Download or clone this repository.
2. Copy the `floatingdictionary.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.

## Usage

1. Select or tap a word in a book like you normally would to trigger a dictionary lookup.
2. Instead of the full popup, a small card slides in near your selection with the word, its source dictionary, and the definition.
3. Select a word inside that definition to cascade into a new lookup, stacked on top — a breadcrumb at the top of the card shows the trail so far, and tapping any earlier word in it jumps straight back.
4. From the footer of a card you can:
   * Move between multiple dictionary results (if more than one dictionary matched) — definition dictionaries first, translation dictionaries last
   * Trigger any enabled quick action (highlight, search, Wikipedia, translate, vocabulary)
   * Shrink/grow the preview text with **A-** / **A+** (the footer buttons scale along with it)
   * Tap the gear icon to open settings: show/hide or reorder footer buttons in the **Buttons** tab, or pick a custom preview font in the **Font** tab
5. Tap outside the card, or swipe, to dismiss the whole lookup session at once.

## Compatibility

* Requires KOReader (tested against recent stable builds; no external dependencies beyond what ships with KOReader).
* Designed to work alongside other dictionary-related plugins — it reads from the same dictionary results KOReader already produces and doesn't replace your installed dictionaries.
* Vocabulary Builder integration is optional and only activates if that plugin is present.
* Translate action uses KOReader's core translator module (`ui/translator`), which ships with every install — no extra setup needed beyond your existing translation language settings.
* Custom preview fonts are limited to font faces CRE already knows about on your device (the same list KOReader's own font menus use).
* The page-turn slide animation is a self-contained software wipe built into the plugin itself — it doesn't require or conflict with any separately installed page-turn animation patch.
* Translation-dictionary detection works by recognizing language names/codes and words like "translation"/"traducción" in installed dictionaries' own names — no internet connection or external language database required.
