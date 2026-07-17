# 📖 Floating Dictionary — KOReader Plugin

**Floating Dictionary** is a plugin for [KOReader](https://github.com/koreader/koreader) that replaces the stock dictionary popup with a **compact, fully customizable floating card**: configurable action buttons, an in-process fast lookup engine (FastDict), a per-book "Word Review" spaced-repetition companion, smart highlighting, page-turn-style animations, and deep visual customization.

* **Internal name:** `floatingdictionary`
* **Package folder:** `floatingdictionary.koplugin`
* **Platform:** KOReader only (Kindle, Kobo, PocketBook, Android, Linux/desktop builds of KOReader — anywhere KOReader itself runs)

---

## 📑 Table of Contents

1. [Overview](#-overview)
2. [Requirements](#-requirements)
3. [Installation](#-installation)
4. [Feature Summary](#-feature-summary)
5. [The Floating Card](#-the-floating-card)
6. [Display Modes](#️-display-modes)
7. [Popup Styles](#-popup-styles)
8. [Footer Action Buttons](#-footer-action-buttons)
9. [Small Selection Menu](#-small-selection-menu)
10. [Smart Highlight](#️-smart-highlight)
11. [Dictionary Order](#-dictionary-order)
12. [Buttons From Other Plugins](#-buttons-from-other-plugins)
13. [FastDict — Instant Lookups](#-fastdict--instant-lookups)
14. [Word Review](#-word-review)
15. [Card Transition Animation](#-card-transition-animation)
16. [Appearance & Customization](#️-appearance--customization)
17. [Full Settings Reference](#-full-settings-reference)
18. [Menu Map](#️-menu-map)
19. [How to Enable / Disable Each Feature](#-how-to-enable--disable-each-feature)
20. [Known Limitations](#️-known-limitations)
21. [Troubleshooting](#-troubleshooting)
22. [FAQ](#-faq)
23. [Plugin Files](#️-plugin-files)
24. [Contributing](#-contributing)
25. [License](#-license)

---

## 🔎 Overview

By default, KOReader shows a plain, non-configurable popup whenever you look up a word. **Floating Dictionary** intercepts that lookup and renders its own card instead, giving you:

- A smaller, faster, more readable popup.
- A configurable row of action buttons (highlight, search, Wikipedia, translate, save for review, navigate between results, third-party plugin buttons).
- An independent "small menu" that appears right next to any text selection.
- An internal dictionary engine (**FastDict**) that can answer lookups without spawning the external `sdcv` process.
- A **Word Review** companion that resurfaces words from a book's own lookup history (or a random dictionary entry) every time you open that book or wake the device.
- Full control over fonts, sizes, borders, icons, button labels, popup position, and visual style.

Every feature below can be toggled independently — nothing here is all-or-nothing.

---

## ✅ Requirements

- A working installation of **KOReader** (any recent version that supports the modern `ReaderDictionary:addToDictButtons` API is recommended for full third-party button integration).
- At least one installed **StarDict-format dictionary** for definitions/translations to have something to look up (KOReader's own dictionary manager can download these).
- Optional: other dictionary-related plugins (e.g. X-Ray) if you want their buttons surfaced inside the Floating Dictionary card.

---

## 💾 Installation

1. Download or clone this repository.
2. Copy the plugin folder — it must contain `main.lua`, `wordreview.lua`, `_meta.lua`, and `engine.lua` (the FastDict/StarDict engine) — into your KOReader plugins directory:

   ```
   koreader/plugins/floatingdictionary.koplugin/
   ├── _meta.lua
   ├── main.lua
   ├── wordreview.lua
   ├── engine.lua
   └── floatingdictionary-images/   <-- optional, for custom SVG icons
   ```
3. Restart KOReader.
4. Open the menu: **☰ → Floating Dictionary**. If the entry doesn't appear, confirm the folder is named exactly `floatingdictionary.koplugin` and that `_meta.lua` is present and unmodified.

---

## 🧩 Feature Summary

| Feature | Description |
|---|---|
| 🃏 Floating card | Compact popup shown on word/selection lookup, replacing the native one. |
| 🎛️ Display modes | Preset profiles (`Personal`, `Minimal`, `Full`, `Language learner`) that instantly change what's shown. |
| 🎨 Popup styles | Two visual presentations: `Classic` and `Kobo`. |
| 🔘 Configurable buttons | Highlight, search in book, Wikipedia, save for review, translate, prev/next result, third-party plugin buttons. |
| 📋 Small menu | Independent mini-menu next to any selection, up to 3 user-chosen buttons. |
| ✍️ Smart Highlight | 2+ word selections become an instant highlight instead of opening the dictionary. |
| 📚 Dictionary order | User-defined priority order for installed dictionaries. |
| 🔌 Third-party buttons | Surfaces buttons registered by other dictionary plugins inside the same card. |
| ⚡ FastDict | In-process StarDict engine that answers exact lookups without launching `sdcv`. |
| 🧠 Word Review | Per-book "remembered word" companion with saved-word management and flashcards. |
| 🎬 Animations | Page-turn-style wipe animation when the card opens/closes. |
| 🖌️ Deep customization | Font size/family, card height, border thickness/darkness, popup position, per-button custom icon/label. |

---

## 🃏 The Floating Card

When you select or long-press a word in a book, instead of KOReader's default dialog you get a **floating card**:

- Anchors either close to the selected word or to the top/bottom screen edge (your choice), automatically picking top vs. bottom based on where the selection sits on screen.
- Shows the definition text plus a row of action buttons along the bottom.
- Tapping a cross-reference link inside a definition opens another card **stacked on top** of the previous one (cascade behavior), with a breadcrumb trail so you can navigate back through the chain of lookups. This cascading behavior is not user-configurable — it always works this way.
- Can be disabled entirely, restoring KOReader's native dictionary popup.

---

## 🎛️ Display Modes

A single, exclusive (radio-style) choice that layers a complete preset on top of (or in place of) your individual settings. Switching modes takes effect immediately, since every render path re-reads it live.

| Mode | Behavior |
|---|---|
| **Personal** | No override — the plugin behaves exactly as configured by your individual settings. This is the *only* editable/custom profile; every appearance/behavior change you make is always saved into this profile. |
| **Minimal** | Hides the entire footer action bar; only the definition is shown. Fixed preset, not editable. |
| **Full** | Forces every dictionary/button/tool to be visible, in your configured dictionary order. Fixed preset, not editable. |
| **Language learner** | Prioritizes translation dictionaries over definition ones, then monolingual definition dictionaries; hides Wikipedia and full-text search. Fixed preset, not editable. |

📍 **Location:** `Floating Dictionary → Appearance → Display mode`

---

## 🎨 Popup Styles

| Style | Description |
|---|---|
| **Classic** *(default)* | The plugin's original look: rounded card corners, generous padding, buttons stretched to fill the row width, hairline gray separators between buttons. |
| **Kobo** | A tighter, flatter alternative inspired by Kobo's native reader UI: fully square corners (no radius), an italic headword, smaller/compact left-aligned icon buttons with even spacing instead of full-width separators, and lighter-gray rule lines. |

Style only ever changes **how** the same data is drawn — never what data is shown or how it behaves. Every other feature (custom icons, button reorder, font size, display modes, card height, border settings, breadcrumb cascade, font override, etc.) works identically and automatically under either style.

📍 **Location:** `Floating Dictionary → Appearance → Popup style`

---

## 🔘 Footer Action Buttons

The buttons available on the **large card's** bottom bar. You can choose which ones are visible, their order, and give each a custom label or icon.

| Button | Function |
|---|---|
| **Highlight** | Highlights the current word/selection using your active highlight style. |
| **Fulltext search** | Full-text search inside the currently open document. |
| **Wikipedia** | Looks up the word/selection on Wikipedia. |
| **Save for review** | Adds the word to that book's Word Review history. |
| **Translate** | Automatically detects the looked-up word's language and translates it using installed translation dictionaries. |
| **◀ Previous result / Next result ▶** | Navigates between multiple dictionary results for the same lookup. |
| **Buttons from other plugins** | Placeholder slot for buttons contributed by other installed dictionary plugins (e.g. X-Ray). |

📍 **Location:** `Floating Dictionary → Appearance → Visible buttons`
From there you can: check/uncheck each button, move it up/down, and assign it a custom text label or a custom `.svg` icon (placed inside the `floatingdictionary-images/` folder next to the plugin). If a custom icon file goes missing later, the button silently falls back to its custom label, then to its default initial letter — nothing breaks.

---

## 📋 Small Selection Menu

A **separate, independent mini-menu** (not the large card) that appears right next to any text selection. It can be turned on/off independently of the big floating card — you can have either one, both, or neither.

Available buttons (choose up to 3, with your own order):

- Highlight
- Add Note
- Save for review
- Wikipedia
- Translate
- Fulltext search

📍 **Location:** `Floating Dictionary → Context menu → Small menu buttons`

> 💡 Example: keep only the small menu active (for quick highlighting/saving) while turning the big definition card off entirely — or the reverse.

---

## ✍️ Smart Highlight

When **enabled**: selecting 2 or more words instantly highlights them — no popup, no menu of any kind — using your current highlight settings, exactly as if you'd used KOReader's native highlighting directly.

- Single-word selections (including hyphenated ones like *well-known*) are **never** affected — they still open the dictionary normally.
- When **disabled** *(default)*, multi-word selections follow KOReader's own native "long-press on text" setting instead, exactly as if this plugin weren't installed.

📍 **Location:** `Floating Dictionary → Context menu → Smart Highlight`

---

## 📚 Dictionary Order

Lets you rank installed dictionaries — definitions, translations, synonyms, antonyms, etymology, conjugations, pronunciation, usage examples, thesauri, or any other kind KOReader can query — in whatever priority order you prefer.

1. Open the dictionary order submenu.
2. Tap a dictionary to select it.
3. Use **"Move up" / "Move down"** to change its priority.

Dictionaries higher on the list appear first whenever you look up a word.

📍 **Location:** `Floating Dictionary → Dictionary → Dictionary order`

---

## 🔌 Buttons From Other Plugins

If you have other dictionary-related plugins installed (e.g. **X-Ray**) that add their own buttons to KOReader's native popup, Floating Dictionary can **auto-detect** them and surface them inside its own card's button row.

- Toggle independently at any time.
- Uses the modern `ReaderDictionary:addToDictButtons` API; if a third-party button can't be read correctly, it's simply skipped — it never breaks the card.

📍 **Location:** `Floating Dictionary → Dictionary → Show buttons from other plugins`

---

## ⚡ FastDict — Instant Lookups

FastDict is a **built-in StarDict engine**, written in pure LuaJIT, that answers exact-word lookups **without spawning the external `sdcv` process**, making lookups noticeably faster.

- Fuzzy searches, special query syntax, unsupported dictionaries, or any internal engine error automatically **fall through** to the original `sdcv` code path — enabling FastDict can only ever speed lookups up, it can never break them.
- The first time each dictionary is used, FastDict builds an **offset/index cache** on disk (a one-time, potentially slow scan); this cache is what makes subsequent lookups fast.
- Cache building runs on a UI tick so a "building…" progress message actually gets painted before the (blocking) scan starts.

| Option | Function |
|---|---|
| **Enable instant lookups** | Turns the FastDict engine on/off. |
| **Build index caches now** | Builds indexes only for dictionaries that don't have one yet. |
| **Rebuild index caches** | Forces a full rebuild of every dictionary's index, even existing ones. |
| **Status** | Live readout: `idle` (not loaded yet), `error — using sdcv` (engine failed and is disabled for this session, see log), or a count of how many dictionaries are served via FastDict vs. via `sdcv`. |

📍 **Location:** `Floating Dictionary → Dictionary → FastDict`

---

## 🧠 Word Review

A per-book, spaced-repetition-style **"word of the day"** companion, built as an independent module (`wordreview.lua`) so it can evolve on its own.

### How it works

- Every time you open a book, WordReview shows **one word from that book's own lookup history** (favoring, but not restricting itself to, words looked up more often), using the exact same floating card the plugin already uses for normal lookups.
- If the book has **no lookup history yet** (first-ever open, or no searches performed so far), it falls back to a **random entry** from your installed dictionaries, so there's always something useful to see.
- History is stored **per book**, inside that book's own `.sdr` sidecar directory — the same place KOReader stores every other piece of per-book state — using the same save format KOReader's own `DocSettings` uses (no extra dependency introduced).

### Word Sources

| Mode | Description |
|---|---|
| **Only saved words** | Only words you explicitly saved via "Save for review" (large card or small menu). |
| **Only random words** | Only random headwords pulled from your installed dictionaries. |
| **Both** *(default)* | Tries your saved words first, falling back to a random headword when nothing has been saved yet for that specific book. |

### Triggers

- ☑️ **Show review word when opening a book**
- ☑️ **Show review word when waking from sleep**

Both checkboxes are fully independent — enable either, both, or neither.

### Managing Saved Words

The **"Manage saved words"** screen is a Kindle Vocabulary-Builder-style UI with three tabs:

| Tab | Contents |
|---|---|
| **Words** | All words saved so far, across your library. |
| **Random** | Randomly sampled dictionary headwords. |
| **Mastered** | Words you've explicitly marked as mastered. |

From this screen you can:

- Browse words in a compact grid (short, fixed-size boxes — long words are truncated with `...` rather than resizing the grid).
- Mark/unmark a word as **"Mastered"** (shown with a small discreet checkmark).
- Multi-select words for bulk actions.
- Enter **Flashcards mode**: a full-screen card shows the headword (auto-shrunk to fit on one line if long), the original sentence/context it was found in (with the target word italicized), and a **"See Definition"** view you can reach with a swipe gesture — the same gesture KOReader's dictionary popup uses to switch between installed dictionaries.
- Mark a card as mastered directly from the flashcard view ("Exit Flashcards" / "Mark as Mastered" controls).

📍 **Location:** `Floating Dictionary → Word Review`

---

## 🎬 Card Transition Animation

The plugin includes a self-contained "wipe" page-turn-style animation (adapted from the standalone page-turn-animation approach) used when the floating card opens or closes.

- Only ever fires when **this plugin's own card** is shown or closed — it never affects ordinary page turns or any other widget in KOReader.
- Does not require any external animation patch to be installed separately; everything needed is embedded in the plugin.
- On **MTK-based devices**, the software animation is automatically skipped (a hardware limitation, not a bug) — everything else keeps working normally.

📍 **Location:** `Floating Dictionary → Appearance → Enable card transition animations`

---

## 🖌️ Appearance & Customization

| Setting | Controls |
|---|---|
| **Popup font size** | Text size for word/definition text in every dictionary popup. Fixed list of point sizes: `12, 16, 20, 22, 24, 26, 28, 30, 34, 38, 44`. |
| **Font family** | Uses the book's own detected font by default, or force-overrides the popup's font with a specific installed face. |
| **Card height** | The floating card's height as a fraction of the screen height — useful for tuning small (6") vs. large (10"+) screens. |
| **Popup border thickness** | Border thickness of every dictionary popup. |
| **Popup border darkness** | From `0` (white/invisible) to `1` (solid black). |
| **Popup position mode** | `Near word` (hugs the selection, default) or `Screen edge` (always anchors flush to top/bottom regardless of where the selection is). Both modes still auto-pick top vs. bottom based on which half of the screen the selection is in. |
| **Highlight styles** | Per-style thickness/darkness for the lines/dots used when highlighting text. |
| **Custom button icons** | Replace a button's default initial-letter fallback with your own `.svg`, placed in `floatingdictionary-images/`. |
| **Custom button labels** | Change the text/initial shown on any footer or small-menu button, independent of any icon. |

📍 **Location:** `Floating Dictionary → Appearance`

---

## ⚙️ Full Settings Reference

For advanced users / contributors, every persisted setting key used by the plugin (stored via KOReader's `G_reader_settings`):

| Setting key | Purpose |
|---|---|
| `floatingdictionary_enabled` | Master on/off switch for the floating card. |
| `floatingdictionary_animations_enabled` | Card transition animation on/off. |
| `floatingdictionary_visible_actions` | Which footer buttons are shown. |
| `floatingdictionary_actions_order` | Order of footer buttons. |
| `floatingdictionary_smallmenu_buttons` | Which small-menu buttons are shown, and their order. |
| `floatingdictionary_small_menu_enabled` | Small menu on/off. |
| `floatingdictionary_action_custom_labels` | Per-button custom text labels. |
| `floatingdictionary_action_custom_icons` | Per-button custom `.svg` icon file. |
| `floatingdictionary_dictionary_order` | User-ranked dictionary priority list. |
| `floatingdictionary_show_external_buttons` | Show/hide buttons from other plugins. |
| `floatingdictionary_smart_highlight_enabled` | Smart Highlight on/off. |
| `floatingdictionary_popup_font_size` | Popup text size. |
| `floatingdictionary_card_height_ratio` | Card height as a fraction of screen height. |
| `floatingdictionary_popup_position_mode` | `near_word` or `screen_edge`. |
| `floatingdictionary_popup_border_thickness` | Popup border thickness. |
| `floatingdictionary_popup_border_darkness` | Popup border darkness (0–1). |
| `floatingdictionary_font_family` | Font family override (unset = use book's font). |
| `floatingdictionary_display_mode` | `personal`, `minimal`, `full`, or `language`. |
| `floatingdictionary_popup_style` | `classic` or `kobo`. |
| `floatingdictionary_fancy_highlight_thickness` | Per-style highlight line thickness. |
| `floatingdictionary_underline_darkness` | Per-style highlight line darkness. |
| `floatingdictionary_fastdict_enabled` | FastDict on/off. |
| `floatingdictionary_save_destination` | Where "Save for review" words are mirrored to (Word Review and/or a compatible Vocabulary Builder plugin, if installed). |

> These keys are documented here for transparency/debugging; you should not need to edit them by hand — everything is reachable from the in-app menu.

---

## 🗺️ Menu Map

```
Floating Dictionary
├── Enable Floating Dictionary            (master switch)
├── Appearance
│   ├── Display mode                      (Personal / Minimal / Full / Language learner)
│   ├── Popup style                       (Classic / Kobo)
│   ├── Visible buttons                   (choose, reorder, customize)
│   ├── Popup font size
│   ├── Font family
│   ├── Card height
│   ├── Popup border thickness / darkness
│   ├── Popup position mode
│   ├── Highlight styles
│   └── Enable card transition animations
├── Dictionary
│   ├── Dictionary order
│   ├── Show buttons from other plugins
│   └── FastDict
│       ├── Enable instant lookups
│       ├── Build index caches now
│       ├── Rebuild index caches
│       └── Status (read-only)
├── Context menu
│   ├── Buttons shown in preview
│   ├── Enable small menu
│   ├── Small menu buttons
│   └── Smart Highlight
└── Word Review
    ├── Manage saved words (Words / Random / Mastered tabs, Flashcards mode)
    ├── Word source (Only saved / Only random / Both)
    ├── Show review word when opening a book
    └── Show review word when waking from sleep
```

---

## 🚀 How to Enable / Disable Each Feature

| I want to... | Go to... |
|---|---|
| Turn the whole plugin off and go back to KOReader's native dictionary | `Floating Dictionary → Enable Floating Dictionary` |
| Change which buttons show on the big card | `Appearance → Visible buttons` |
| Use only the small menu, without the big card | Disable `Enable Floating Dictionary`, keep `Enable small menu` on |
| Make 2+ word selections auto-highlight | `Context menu → Smart Highlight` |
| Speed up lookups | `Dictionary → FastDict → Enable instant lookups` |
| See a review word every time I open a book | `Word Review → Show review word when opening a book` |
| Save words to review later | Select text → tap **"Save for review"** (big card or small menu) |
| Review saved words as flashcards | `Word Review → Manage saved words → (pick a word) → Flashcards` |
| Change the whole visual look | `Appearance → Popup style` |
| Use my own icons on the buttons | Drop `.svg` files into `floatingdictionary-images/` → `Appearance → Visible buttons → (button) → Icon` |
| Anchor the popup to a fixed screen edge instead of near the word | `Appearance → Popup position mode → Screen edge` |
| Show every available tool/dictionary regardless of my personal settings | `Appearance → Display mode → Full` |
| Get a distraction-free popup with just the definition | `Appearance → Display mode → Minimal` |

---

## ⚠️ Known Limitations

- 🖥️ **KOReader-only** — this is not a standalone app or browser extension.
- ⚡ **FastDict** only accelerates **exact** lookups; fuzzy searches or special query syntax always fall back to `sdcv`.
- 🌐 **Translate** and **Wikipedia** buttons depend on having the relevant translation dictionaries installed and/or an internet connection, depending on your KOReader/network setup.
- 🈳 **Automatic language detection** for translation is heuristic (based on the looked-up word's spelling); it can misfire on very short or ambiguous words.
- 🖼️ **Custom icons** must be `.svg` files you place manually into `floatingdictionary-images/` — the plugin does not fetch, generate, or bundle icon packs.
- 📱 On **MTK devices**, the card transition animation is automatically disabled — this is an intentional hardware limitation, not a bug.
- 🧩 **Third-party plugin buttons** only appear if that plugin uses KOReader's modern `addToDictButtons` API; older plugins may not integrate.
- 💾 **Word Review** history is stored per book inside its `.sdr` sidecar folder; deleting that folder deletes that book's review history.
- 🔤 The **"Language learner"** display mode is a fixed, non-editable preset — to customize its behavior you must use the **Personal** mode instead.
- 🔀 **Cascading (chained) lookups** — tapping a cross-reference link inside a definition — always stack with a breadcrumb trail; this behavior is not currently user-configurable.

---

## 🩺 Troubleshooting

| Problem | Likely cause / fix |
|---|---|
| Plugin menu doesn't appear | Confirm the folder is named exactly `floatingdictionary.koplugin` and contains `_meta.lua`. |
| Lookups feel slow | Enable **FastDict** and build the index caches from `Dictionary → FastDict → Build index caches now`. |
| Another dictionary plugin's buttons don't show up | Check `Dictionary → Show buttons from other plugins`, and confirm that plugin uses the modern button-registration API. |
| A custom icon doesn't show on a button | Make sure the `.svg` file is inside `floatingdictionary-images/` next to the plugin, then re-select it from the button's settings menu. |
| FastDict shows "Status: error — using sdcv" | Check the KOReader log — the engine may have hit an error and disabled itself for the current session only; it will retry on next app start. |
| Word Review shows nothing useful | Make sure at least one dictionary is installed (for the random fallback) and/or that you've looked up or saved words in that specific book. |
| Animations don't play | Confirm they're enabled in `Appearance`, and note that MTK-based devices intentionally skip the software animation. |

---

## ❓ FAQ

**Does this replace my installed dictionaries?**
No. It reuses whatever StarDict dictionaries you already have installed in KOReader — it only changes how lookup results are presented and interacted with.

**Can I use the small menu and the big card at the same time?**
Yes, they're independent. You can also disable either one and keep only the other.

**Will FastDict ever give me wrong definitions?**
No — if FastDict can't answer a lookup (unsupported dictionary, fuzzy search, engine error) it transparently defers to KOReader's normal `sdcv` lookup path, so results are always at least as correct as without the plugin.

**Does Word Review sync between devices?**
No — history is stored locally per book, inside that book's own sidecar folder on the device.

**Can I have different button sets for the big card vs. the small menu?**
Yes — `Appearance → Visible buttons` controls the big card, while `Context menu → Small menu buttons` controls the small menu, completely independently.

---

## 🗃️ Plugin Files

| File | Contents |
|---|---|
| `_meta.lua` | Plugin metadata (name, full name, description) used by KOReader to list the plugin. |
| `main.lua` | Core logic: floating card, footer buttons, popup styles, FastDict integration, animations, all settings menus, Smart Highlight, cascading lookups. |
| `wordreview.lua` | Self-contained Word Review module: per-book history storage, "Manage saved words" screen (Words / Random / Mastered tabs), and the Flashcards review mode. |
| `engine.lua` *(referenced, not shown here)* | The pure-LuaJIT StarDict engine used by FastDict for instant, in-process lookups. |
| `floatingdictionary-images/` | Optional folder you create yourself to hold custom `.svg` icons for buttons. |

---

## 🤝 Contributing

Found a bug or have an idea? Open an **issue** or a **pull request** in this repository. Documentation fixes, translations, and new features are all welcome.

---

<p align="center">Made with 📖 for KOReader readers.</p>
