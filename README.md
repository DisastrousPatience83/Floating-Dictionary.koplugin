# Floating Dictionary

**Floating Dictionary** is a KOReader plugin that replaces the standard dictionary window with a compact floating card.

Select a word and a floating card appears with its definition, dictionary source, navigation controls, and configurable action buttons such as **Wikipedia**, **Translate**, **Highlight**, and **Save for review**.

The plugin also includes a configurable selection menu, per-book word review, dictionary result navigation, cascade lookups, and **FastDict**, an in-process StarDict lookup engine.

**Current version: 6.2.0**

---

## Table of Contents

1. [Features](#features)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [First Steps](#first-steps)
5. [Settings Reference](#settings-reference)
6. [Popup Styles](#popup-styles)
7. [Footer Buttons and Other Plugins](#footer-buttons-and-other-plugins)
8. [Small Selection Menu](#small-selection-menu)
9. [Word Review](#word-review)
10. [Fast Lookups (FastDict)](#fast-lookups-fastdict)
11. [Updating](#updating)
12. [What's New in 6.2.0](#whats-new-in-620)

---

## Features

- **Floating dictionary card** instead of the standard full-screen dictionary window.
- **Three popup styles:** Classic, Kobo, and Kindle.
- **Cascade lookups:** tap a word inside a definition to open a new dictionary card. A breadcrumb trail lets you navigate back through the lookup chain.
- **Multiple dictionary results:** browse several results for the same word with a result counter such as `1/3` and previous/next arrows.
- **Dictionary order:** choose which installed dictionary is searched first.
- **Configurable footer buttons:** Highlight, Wikipedia, Translate, Fulltext search, and Save for review.
  - Show or hide buttons.
  - Reorder buttons.
  - Rename button labels.
  - Assign custom icons.
- **Other plugin buttons:** integrate buttons provided by other dictionary plugins, such as X-Ray or AI assistant plugins.
- **Small selection menu:** display up to five configurable actions when selecting text.
- **Smart Highlight:** optionally turn any selection of two or more words into an instant highlight without opening the dictionary popup.
- **Word Review:** save words while reading and review them later on a per-book basis.
- **Vocabulary Builder integration:** optionally send saved words to KOReader's Vocabulary Builder plugin.
- **FastDict:** an in-process StarDict engine for faster exact-word lookups.
- **Appearance controls:** customize interface language, font, font size, card height, border appearance, popup position, highlight styles, and transition animations.
- **Built-in updater:** check GitHub Releases for new versions directly from KOReader.

---

## Requirements

- A device running **KOReader**, including Kobo, Kindle, Android, Linux, and other supported platforms.
- At least one **StarDict dictionary** installed in KOReader.
- An internet connection for **Wikipedia** and **Translate**.
- **Vocabulary Builder** is optional and only required if you want saved words mirrored there.

---

## Installation

1. Download the latest release from the repository's **Releases** page.
2. Unzip the downloaded archive.
3. You should get a folder whose name ends in `.koplugin`.
4. Copy the `.koplugin` folder into the `plugins` directory of your KOReader installation.

Typical locations include:

- **Kobo:** `.adds/koreader/plugins/`
- **Kindle:** `koreader/plugins/`
- **Android:** the `plugins` folder inside your KOReader data directory

5. Restart KOReader.
6. Open a book.
7. Open the main menu and go to the settings section.
8. You should see **Floating Dictionary** in the KOReader menu.

---

## First Steps

After installation:

1. Open a book and long-press a word.
2. The Floating Dictionary card should appear.
3. Open the KOReader menu and select **Floating Dictionary**.
4. Make sure **Enable Floating Dictionary** is turned on.
5. Go to **Appearance > Popup style** and choose between:
   - Classic
   - Kobo
   - Kindle
6. Go to **Context menu > Buttons shown in preview** to choose which text buttons appear in the dictionary card.
7. If you want buttons provided by other plugins, configure them under **Context menu > Other plugins**.

---

## Settings Reference

The plugin adds a **Floating Dictionary** entry to the KOReader menu.

### Enable Floating Dictionary

Turns the floating dictionary card on or off.

### Check for Updates

Checks GitHub Releases for a newer version of Floating Dictionary and installs it when available.

---

### Appearance

#### Language

Sets the interface language used by the plugin.

#### Preview Font

Overrides the font family used inside the floating dictionary card.

#### Popup Style

Choose between:

- **Classic**
- **Kobo**
- **Kindle**

#### Popup Position

Controls where the dictionary card appears.

- **Near word:** the card is positioned close to the selected word.
- **Screen edge:** the card is docked to the top or bottom edge of the screen.

The **Kindle** style always uses **Screen edge** positioning.

#### Card Height

Sets the maximum height of the dictionary card as a percentage of the screen.

#### Popup Font Size

Controls the font size used inside the dictionary card.

#### Popup Border

Adjusts the border thickness and darkness.

#### Highlight Styles

Controls the appearance of highlights created through the plugin.

#### Card Transition Animations

Enables or disables popup transition animations.

---

### Dictionary

#### Dictionary Order

Controls the order in which installed dictionaries are searched.

Tap a dictionary to select it, then use:

- **Move up**
- **Move down**

The dictionary at the top of the list is given priority.

#### Fast Lookups (FastDict)

Turns the FastDict lookup engine on or off.

See [Fast Lookups (FastDict)](#fast-lookups-fastdict) for more information.

---

### Context Menu

#### Buttons Shown in Preview

Controls the text buttons displayed in the dictionary card.

You can:

- Show or hide buttons.
- Reorder buttons.
- Rename button labels.
- Assign custom icons.

Only text buttons are managed here. Previous/next arrows and buttons supplied by other plugins are managed separately.

#### Enable Small Menu

Turns the small selection menu on or off.

#### Small Menu Buttons

Choose up to five buttons and configure their order.

#### Other Plugins

Manages buttons supplied by other dictionary plugins.

You can control their visibility, position, text, and icons.

#### Smart Highlight

Turns any selection of two or more words into an instant highlight without opening the dictionary popup.

Smart Highlight is **off by default**.

Single-word selections are not affected.

---

### Word Review

Contains the settings for the Word Review feature, including where words saved with **Save for review** are stored.

---

## Popup Styles

Floating Dictionary provides three popup styles. All styles use the same dictionary data and provide the same core functionality. Only the presentation changes.

### Classic

The default style.

A floating card with rounded corners and a footer row of buttons stretched across the available width.

### Kobo

A layout inspired by Kobo's dictionary presentation.

The card displays:

1. The selected word.
2. The definition.
3. The dictionary name.

Footer buttons are compact and grouped toward the left.

When multiple dictionary results are available, the result counter is displayed next to the word.

### Kindle

A full-width dictionary panel docked to the screen edge.

It uses square corners and a single line along its top edge.

The Kindle style has the following layout:

- The **headword** is displayed in bold.
- The **phonetic pronunciation** appears on the same line when provided by the dictionary.
- The **definition body** is displayed in italics.
- The **dictionary source** appears at the bottom of the card, below a thin separator line.
- Configured buttons appear as a row of tabs next to **Dictionary**, following the order configured by the user.
- Hidden buttons are not displayed.
- Tab labels are not truncated. If the labels do not fit, spacing is reduced first, followed by font-size reduction if necessary.
- Only the previous/next navigation arrows remain in the footer.

The Kindle style always uses **Screen edge** positioning regardless of the saved **Popup position** setting.

When switching back to Classic or Kobo, the previously configured popup position is restored.

---

## Footer Buttons and Other Plugins

### Text Buttons

Open:

**Floating Dictionary > Context menu > Buttons shown in preview**

From there you can:

- Show or hide individual buttons.
- Move buttons up or down.
- Set a custom **Button Text**.
- Leave Button Text empty to restore the default single-letter label.
- Choose a custom icon from the icons available on your device.

This menu only manages text buttons.

Previous/next navigation arrows and buttons supplied by other plugins are managed elsewhere.

### Buttons from Other Plugins

Open:

**Floating Dictionary > Context menu > Other plugins**

Use **Show buttons from other plugins** as the master switch.

All detected buttons supplied by other plugins are listed with their current position and visibility state.

Select a plugin button and configure:

- **Move up**
- **Move down**
- **Hide**
- **Show**
- **Button text**
- **Button icon**

When you activate one of these buttons:

1. The Floating Dictionary card closes.
2. The selected plugin performs its own action.
3. The highlight of the original word is cleared when the other plugin's window closes.

### Wikipedia and Translate

Wikipedia and Translate require an internet connection.

If Wi-Fi is disabled, KOReader asks whether you want to connect.

If you decline the connection request, the dictionary card remains open.

---

## Small Selection Menu

The Small Selection Menu appears when you select text.

By default, it provides actions such as:

- Highlight
- Note
- Save

### Enabling the Menu

Go to:

**Floating Dictionary > Context menu > Enable small menu**

### Choosing Buttons

Go to:

**Floating Dictionary > Context menu > Small menu buttons**

You can select up to **five buttons**.

Available buttons include:

- Text buttons configured under **Buttons shown in preview**
- Add Note
- Buttons supplied by other plugins

Buttons supplied by other plugins can have their own **Button Text** for the Small Selection Menu. This text is configured separately from the button text used in the dictionary card.

The menu never displays more than five buttons.

If five buttons are already enabled, you must remove one before adding another.

---

## Word Review

Word Review allows you to save words while reading and review them later.

### Saving a Word

Use **Save for review** from:

- The Floating Dictionary card.
- The Small Selection Menu.

### Storage

The destination can be configured as:

- **Word Review**
- **Vocabulary Builder**
- **Both**

The default is **Both**.

### Per-Book Review

Saved words are associated with the book in which they were saved.

The review card can also appear when you open a book.

Word Review is additionally available from the KOReader file browser, where you can manage your saved words.

---

## Fast Lookups (FastDict)

**FastDict** is an in-process StarDict lookup engine designed to make exact-word dictionary lookups faster.

Instead of starting KOReader's external dictionary process for every lookup, FastDict performs supported lookups directly inside KOReader.

Enable or disable it under:

**Floating Dictionary > Dictionary > Fast lookups (FastDict)**

If FastDict cannot handle a particular lookup, KOReader automatically falls back to its normal dictionary lookup method.

Fallbacks can occur with:

- Fuzzy searches.
- Special query syntax.
- Unsupported dictionaries.
- Engine errors.
- Other lookup types not supported by FastDict.

Enabling FastDict should therefore only affect lookup speed. Unsupported lookups continue to use KOReader's normal method.

---

## Updating

### Automatic Update

Open:

**Floating Dictionary > Check for updates**

The plugin checks GitHub Releases for a newer version and installs it.

### Manual Update

You can also update manually:

1. Download the new release.
2. Unzip it.
3. Replace the existing `.koplugin` folder with the new version.
4. Restart KOReader.

---

### My Custom Button Text Is Cut Off

Update to **Floating Dictionary 6.2.0**.

Earlier versions imposed an approximately 80-pixel limit on custom button labels.

Version 6.2.0 removes this limitation and allows the interface to adjust the available space more appropriately.

---

### Wikipedia or Translate Does Nothing

Check that your device is connected to the internet.

For Translate, also check KOReader's own translator settings.

---

### The Small Selection Menu Does Not Appear

Make sure:

**Context menu > Enable small menu**

is enabled.

If you are using an older version, update to **6.2.0**. Version 6.2.0 fixes an issue with how the Small Selection Menu resolved its own buttons.

---

### Display Mode, Select Mode, or Extend Last Highlight Are Missing

These options were removed in version **6.2.0**.

See [What's New in 6.2.0](#whats-new-in-620).

---

## What's New in 6.2.0

### Added

- **Kindle popup style.**
- **Other Plugins** submenu for managing buttons supplied by other plugins.
- Small Selection Menu now supports up to **five buttons**.
- Small Selection Menu now supports buttons from other plugins.
- Other-plugin buttons have their own configurable **Button Text** for the Small Selection Menu.
- Connection check before launching Wikipedia or Translate.

### Improved and Fixed

- Custom **Button Text** is no longer truncated.
- Small Selection Menu cards are no longer limited to 62% of the screen width.
- **Buttons shown in preview** now lists only text buttons.
- Cleaner behavior when launching buttons supplied by other plugins.
- Cascade lookups preserve the configured popup position.
- Small Selection Menu button resolution has been fixed.

### Removed

The following options were removed in version 6.2.0:

- Display Mode:
  - Personal
  - Minimal
  - Full
  - Language learner
- Select Mode
- Extend Last Highlight

---
