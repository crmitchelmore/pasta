# Pasta artwork

`AppIcon-master.png` is the unmasked, opaque source artwork. Generated with the built-in image tool on 9 September 2026: a porcelain clipboard with an offset page, golden clip and three broad blue-grey marks on a cobalt field. No text or small ornamental symbols. Native resolution is 1254 × 1254; none of the exports upscale it.

Run from the repository root:

```sh
swift scripts/generate-brand-assets.swift
swift scripts/generate-brand-assets.swift --alpha   # also runs create-icns.sh
bash Resources/DMG/create-icns.sh
swift test --filter BrandAssetTests
```

`create-icns.sh` builds `Resources/DMG/AppIcon.icns` and `AppIconAlpha.icns` from the appiconsets, then runs `scripts/optimize-artwork.py` (needs `python3 -m pip install pillow imagequant pyoxipng`; set `PYTHON` to use another interpreter). The optimiser recompresses every PNG slot losslessly and palette-quantises slots at least 256 px wide only when they stay at or above 45 dB PSNR over black and white and save at least 25%. That makes each ICNS about 1.6 MB → 0.5 MB with no visible change; re-running it is a no-op. Releases ship the committed ICNS and DMG background as-is, so commit the regenerated files. The DMG volume icon is the app ICNS without its 1024 px slot (`scripts/ci-slim-icns.py`, applied by `ci-create-macos-dmg.sh`).

`Resources/DMG/create-background.sh` renders the 1320 × 800 px DMG backdrop (660 × 400 pt window at 2×) in sRGB, independent of the display profile, then optimises it to about 16 KB.

The iOS onboarding mark (`PastaMark.png`) is exported at 288 px, exactly 96 pt at 3x, and optimised with `--min-quantise-width 0` to about 30 KB. That cut the compiled iOS `Assets.car` from 2.34 MB to 1.62 MB.

Landing-page icons are exported at their exact display sizes: `app-icon-v3-144.png` (40 pt nav and 72 pt download at 2x) and `app-icon-v3-216.png` (72 pt at 3x). Optimise them with `python3 scripts/optimize-artwork.py --min-quantise-width 0 landing-page/images/app-icon-v3-*.png`, which takes the nav icon from 254 KB at 512 px to about 8 KB. `/images/*` is served `immutable`, so give a changed image a new filename.

The macOS PNG fallbacks (`Sources/PastaApp/Resources/AppIcon.png`, `AppIconAlpha.png`) are only used by SwiftPM development runs; release staging removes them because installed apps load the ICNS. `BrandAssetTests` keeps them byte-identical to the matching `icon_512x512@2x.png` slots; recompress all four losslessly with `oxipng -o 6 --strip none` after exporting.

The exporter reads both asset catalogues to produce exact pixel sizes. iOS icons are opaque and unmasked; macOS exports include transparent margins and rounded corners. The installed ICNS, SwiftPM fallback, onboarding/About artwork and web icons derive from the same source. Menu-bar controls use Apple's adaptive monochrome SF Symbol, rather than shrinking the full-colour icon.

Web filenames are versioned because `/images/*` is cached immutably for one year. Change the filename and its references on future updates.

The website's `screenshot-quicksearch-v2.jpg` and `screenshot-snippets-v2.jpg` are unaltered native-window captures from the development app on 9 September 2026, after the 1.6.2 release. They use curated sample entries/templates in the isolated `Pasta Development` database; they are not HTML recreations or generated app screens. CUA captures are 680 pixels wide and the site keeps them below that display width. Personal development history and preferences were backed up for restoration after capture; the installed app's data was not replaced.
