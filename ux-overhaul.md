# Pasta UX Overhaul (macOS)

Date: 2026-01-20

## Target tasks & user segments
- **Tasks:** open panel fast, search & filter, preview, paste, delete, manage settings, onboarding/permissions.
- **Segments:** power users/devs (keyboard-first), general macOS users, privacy‑conscious users.

## Current journey / task flow (observed)
1. Open panel (hotkey) → Search (custom field) → Filter (sidebar buttons) → Select item (scroll list) → Preview → Paste.
2. Delete flows: Delete selected (sheet) or bulk delete recent (sheet).
3. Onboarding: Welcome → Accessibility steps → Done.
4. Settings: hotkey + launch at login + storage + limits + exclusions.

## Top issues (ranked)
1. **Search/filter controls don’t follow macOS patterns + hidden labels (High impact, high frequency).**  
   - **Where:** `SearchBarView`, `FilterSidebarView`.  
   - **Before:** custom search field, hidden toggle/picker labels, result count only via tooltip.  
   - **After:** standard macOS search field (`.searchable` or `NSSearchField`), visible/announced labels, segmented exact/fuzzy, filter as Sidebar/List with selection.  
   - **A11y:** labels are hidden → screen readers lose context; add `.accessibilityLabel`, `.accessibilityHint`, keep visible labels when possible.

2. **List/selection behavior is custom (ScrollView + buttons) and weak for keyboard/a11y (High impact, high frequency).**  
   - **Where:** `ClipboardListView`, `FilterSidebarView`.  
   - **Before:** custom row selection with onTap; no native selection model, limited accessibility.  
   - **After:** macOS `List` with selection binding, built‑in focus ring, context menu (Copy/Delete/Reveal), standard keyboard navigation.  
   - **A11y:** use `List` row accessibility and `accessibilitySelected`.

3. **Primary actions are scattered; destructive actions sit beside primary actions (High impact, medium frequency).**  
   - **Where:** `footerView` in `PanelContentView`.  
   - **Before:** Refresh/Delete/Delete Recent/Quit in footer; Quit adjacent to destructive actions.  
   - **After:** move to toolbar/menu bar; separate destructive actions into menu; use `⌘W` close window, `⌘⌫` delete.  
   - **OS X pattern:** use toolbar + menu, avoid “Quit” as a primary button in a panel.

4. **Onboarding flow is manual and unclear in copy (Medium impact, high frequency).**  
   - **Where:** `OnboardingView`.  
   - **Before:** “Request Prompt” label unclear; must press “Check Again.”  
   - **After:** rename to “Show Permission Prompt” and auto‑poll trust; show current status inline with next step guidance.  
   - **A11y:** add explicit status text for VoiceOver.

5. **Preview panel doesn’t signal that selection drives content (Medium impact, high frequency).**  
   - **Where:** `PreviewPanelView`, `ClipboardListView`.  
   - **Before:** empty state generic; selection state not emphasized.  
   - **After:** add “Select an item to preview” and highlight selected row; optionally show mini preview snippet on hover.

6. **Filters are exhaustive, slow to scan, and not grouped (Medium impact, medium frequency).**  
   - **Where:** `FilterSidebarView`.  
   - **Before:** all types + all domains in one list.  
   - **After:** split into “All / Favorites / Types / Domains”; collapse domains by default.  
   - **OS X pattern:** sidebar sections with headers.

7. **Copy/paste hints aren’t discoverable (Medium impact, medium frequency).**  
   - **Where:** onboarding, footer, empty state.  
   - **Before:** only one line in onboarding; no keyboard hints in empty state.  
   - **After:** add inline hint “Press ↩︎ to paste, ⌘⌫ to delete, ⌘F to search.”  
   - **A11y:** ensure hints are not color‑only.

8. **Settings labels are terse + some actions are silent (Low impact, medium frequency).**  
   - **Where:** `SettingsView`.  
   - **Before:** “Clear all history…” summary is small; no warning about images.  
   - **After:** add inline explanation before action and show confirmation text in the dialog.

## Recommended fixes (prioritized)
1. **Adopt native macOS search + filter patterns.**  
   - Convert `SearchBarView` to `.searchable` in the panel or wrap `NSSearchField`.  
   - Replace Fuzzy toggle with segmented control labeled “Exact / Fuzzy.”  
   - Provide visible labels or `accessibilityLabel` for toggle/picker.

2. **Use `List` with selection for sidebar + clipboard list.**  
   - Sidebar: `List(selection:)` with sections (All, Types, Domains).  
   - Clipboard list: `List` rows with selection state, context menu, and default focus ring.

3. **Move actions to toolbar/menu; reduce footer density.**  
   - Replace footer buttons with toolbar items (Refresh, Delete, Delete Recent).  
   - Keep “Quit” only in menu bar; add `⌘W` to close panel.

4. **Onboarding: simplify and auto‑progress.**  
   - Copy updates + automatic trust polling; show “Permission granted” state and next step.

5. **Preview state clarity.**  
   - Stronger empty state; show selected item summary header; allow quick “Copy/Paste/Delete” in preview.

6. **Filter ergonomics.**  
   - Collapse domains; add “Pinned filters”; show count only when >0.

7. **Accessibility pass.**  
   - Ensure every control has labels; avoid `.labelsHidden()` unless `accessibilityLabel` is set.  
   - Ensure focus order: Search → Sidebar → List → Preview; use `accessibilitySortPriority`.

8. **Liquid Glass use (OS X pattern).**  
   - Apply **NSGlassEffectView** to panel chrome (header/footer) only; use **NSGlassEffectContainerView** if multiple glass cards are adjacent.  
   - Keep content areas in `.regularMaterial` to avoid legibility issues.

## Information architecture & navigation recommendations
- Add top‑level toolbar with **Search**, **Filter**, **Delete**, **Settings** (standard macOS).  
- Sidebar sections: “All”, “Types”, “Domains” with collapsible disclosure.  
- Use standard context menu actions on list items: **Paste**, **Copy**, **Delete**, **Reveal in Finder** (for file paths).

## UX writing improvements (before → after)
- “Request Prompt” → “Show Permission Prompt”  
- “Check Again” → “Refresh Permission Status”  
- “Delete…” → “Delete Selected…”  
- “Delete Recent…” → “Delete Recent Items…”  
- Empty state: “Copy something to start building your history.” → “Copy anything to build your history. Press ⌘V to paste or ⌃⌘C to reopen Pasta.”

## Acceptance criteria
- Search field uses native macOS search patterns and has VoiceOver‑readable labels.  
- Sidebar and list are `List` with keyboard selection, focus rings, and context menus.  
- Footer no longer contains Quit; destructive actions are in toolbar/menu only.  
- Onboarding completes without manual “Check Again” and communicates permission state.  
- Preview clearly indicates selection‑driven content and offers quick actions.

## Measurement ideas
- **Time‑to‑first‑paste** (panel open → paste)  
- **Search success rate** (search → paste)  
- **Keyboard‑only completion rate** for paste and delete flows  
- **Onboarding completion rate** and time to permission grant  
- **A11y audit pass rate** (labels, focus order, contrast)

## Other UX optimizations (backlog)
- Auto‑refresh history on panel open; remove manual Refresh unless troubleshooting.  
- Add per‑type quick filters in search field token bar.  
- Add undo for delete (toast + Undo).  
- Add “Open Settings” from onboarding completion screen.  
- Provide “Pin” or “Star” for frequent items.
