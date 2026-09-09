# Pasta artwork

`AppIcon-master.png` is the unmasked, opaque source artwork. Generated with the built-in image tool on 9 September 2026: a porcelain clipboard with an offset page, golden clip and three broad blue-grey marks on a cobalt field. No text or small ornamental symbols. Native resolution is 1254 × 1254; none of the exports upscale it.

Run from the repository root:

```sh
swift scripts/generate-brand-assets.swift
bash Resources/DMG/create-icns.sh
swift test --filter BrandAssetTests
```

The exporter reads both asset catalogues to produce exact pixel sizes. iOS icons are opaque and unmasked; macOS exports include transparent margins and rounded corners. The installed ICNS, SwiftPM fallback, onboarding/About artwork and web icons derive from the same source. Menu-bar controls use Apple's adaptive monochrome SF Symbol, rather than shrinking the full-colour icon.

Web filenames are versioned because `/images/*` is cached immutably for one year. Change the filename and its references on future updates.

The website's `screenshot-quicksearch-v2.jpg` and `screenshot-snippets-v2.jpg` are unaltered native-window captures from the development app on 9 September 2026, after the 1.6.2 release. They use curated sample entries/templates in the isolated `Pasta Development` database; they are not HTML recreations or generated app screens. CUA captures are 680 pixels wide and the site keeps them below that display width. Personal development history and preferences were backed up for restoration after capture; the installed app's data was not replaced.
