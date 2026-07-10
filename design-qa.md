# Design QA — design system global do zspeak

- Source visual truth: `/Users/michelzandonai/.codex/generated_images/019f4943-ad2f-7113-be06-e27a55e04c24/exec-7e0a161d-9ef0-45c4-87ce-a59828193626.png`
- Full-view implementation: `/Users/michelzandonai/desenv/zspeak/Tests/__Snapshots__/VisualSnapshotTests/settings-overview.png`
- Installed-app implementation: `/tmp/zspeak-installed-1.0.46.png`
- Sidebar implementation: `/Users/michelzandonai/desenv/zspeak/Tests/__Snapshots__/VisualSnapshotTests/settings-sidebar-overview.png`
- Auxiliary-window implementation: `/Users/michelzandonai/desenv/zspeak/Tests/__Snapshots__/VisualSnapshotTests/audio-file-processing.png`
- Tray regression implementation: `/Users/michelzandonai/desenv/zspeak/Tests/__Snapshots__/TrayInfoOverlaySnapshotTests/tray-info-overlay-recording.png`
- Combined comparison evidence: `/tmp/zspeak-app-design-system-comparison.png`
- Viewports: Settings `980 × 720 pt`; sidebar `240 × 720 pt`; audio file `720 × 520 pt`; tray `520 × 96 pt`.
- State: dark appearance, Overview with one pending item, audio processing at 40%, tray recording at 0:12.
- Comparison scope: transfer of the approved tray design system to different app layouts; component hierarchy is preserved rather than pixel-cloned from the tray HUD.

**Findings**

- No P0, P1, or P2 issue remains.
- Fonts and typography: the system SF family is preserved. Primary content uses high-contrast white, supporting copy uses the tray secondary/tertiary hierarchy, status labels keep semantic emphasis, and no inspected text is clipped.
- Spacing and layout rhythm: 14 pt primary radius, 9 pt compact radius, 22 pt page padding, thin cold borders, restrained elevation, and consistent grouped spacing are applied to Settings, cards, model rows, auxiliary windows, overlays, and sidebar selection.
- Colors and visual tokens: the approved blue-graphite surface (`0.052 / 0.086 / 0.130`), cold outline, blue processing accent, red live accent, amber warning, and mint success now come from one global token source. The app remains deliberately dark in light macOS appearance.
- Image quality and asset fidelity: there are no missing raster assets in the reference. Native SF Symbols remain sharp at every scale; no emoji, placeholder, handcrafted SVG, or approximate asset replaces a source element. The live waveform remains data-driven.
- Copy and content: existing product language and workflows are unchanged. Sidebar labels, page titles, form help, statuses, actions, and tray copy remain complete and readable.
- Accessibility: the custom sidebar exposes selected state and labels, status meaning never depends only on color, the approved tray retains VoiceOver and Reduce Motion behavior, and contrast is preserved across the dark surfaces.

**Comparison History**

1. First pass: P1 — the native `NavigationSplitView` sidebar rendered as a blank light material in isolated visual capture, breaking the global dark system. Fix: replaced the native sidebar list chrome with a zspeak-owned sidebar surface, explicit navigation buttons, selected-state border/fill, and accessibility traits. Post-fix evidence: `settings-sidebar-overview.png`.
2. Second pass: P2 — shared text and outline tokens had drifted slightly from the approved tray values. Fix: restored the exact tray secondary/tertiary opacity and cold-outline opacity, then reused those values globally. Post-fix evidence: `/tmp/zspeak-app-design-system-comparison.png` and the updated tray regression snapshot.
3. Final pass: no actionable P0/P1/P2 mismatch. Settings pages, dense Correção LLM content, Transcrever Arquivo, overlay states, sidebar, and tray all share the same visual grammar without changing their interaction model.

**Focused Region Comparison**

- Sidebar: inspected independently at `240 × 720 pt` because navigation density and selected-state contrast are too small in a full window capture.
- Overview cards: inspected at `980 × 720 pt` for radius, cold borders, semantic icons, typography, and vertical rhythm.
- Auxiliary window: inspected at `720 × 520 pt` to confirm the same surface, segmented control, progress, status chip, and action hierarchy outside Settings.
- Tray: compared separately at its approved `520 × 96 pt` state to ensure the global token consolidation did not regress the original design.

**Manual Validation Record**

- Input/precondition: approved tray reference plus deterministic Overview, sidebar, audio-processing, and tray-recording fixtures.
- Action: opened each rendered snapshot and the combined comparison board, then inspected the installed 1.0.46 window and its accessibility tree for sidebar selection, navigation labels, typography, spacing, colors, image/icon fidelity, copy, and overflow.
- Expected result: all app surfaces use the approved blue-graphite design language, preserve their content, and remain legible without clipping or light-theme drift.
- Rule protected: the tray design system is the single visual source of truth for the whole application.

**Automated Coverage**

- `VisualSnapshotTests`: 21 deterministic visual states covering overlays, Settings pages, sidebar, sheets, and Transcrever Arquivo.
- `TrayInfoOverlaySnapshotTests`: preserves the originally approved tray state after token consolidation.
- The final focused run is executed without recording mode so comparisons fail on future visual regressions.

**Follow-up Polish**

- P3: native macOS controls keep their platform-specific toggle, picker, and search-field rendering. This is intentional so keyboard navigation and accessibility behavior stay native while surrounding surfaces follow zspeak tokens.

final result: passed
