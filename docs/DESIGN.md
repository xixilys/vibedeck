# macOS panel design

VibeDeck uses a 380 pt menu panel with native menu material, a segmented tab picker, standard settings menu and quiet footer commands. Text follows three sizes (11/13/24 pt) and the existing 0.85–1.3 scale presets. Content uses separators and compact rows; it avoids a stack of large provider cards.

Overview starts with readable device quota windows, followed by today's collected input/output for each CLI, scoped historical token totals and API-equivalent cost. Existing platform, usage and recent-interaction details remain in disclosures. Today's input includes accumulated cache reads; it is not a single request's context length. This branch adds no pending-approval, session-context or live-capture feature.

Quota rings show **used** percentages: 0 is empty and 100 is full. Values under 60% are normal, 60–85% warn, and values above 85% or forecast depletion are critical. Icons and words accompany warning colors. Missing, reset, undated and invalid quota values are omitted; old/offline/retained readings remain gray and qualified. Windows remain separated by device and provider, never summed. Reset labels stay on one line and expose the full value on hover. Device filters and all detail routes remain available.

Today's usage and API-equivalent cost retain visible coverage cues; nearby information popovers explain collected-log coverage, excluded Codex Cloud / Dot usage, cache semantics, and reference-rate estimates. Estimates do not describe subscription bills. Longer technical explanations belong in popovers or existing detail disclosures.

## References

- macOS Control Center: compact grouped controls, standard material and restrained hierarchy.
- [Stats](https://github.com/exelban/stats) and [iStat Menus](https://bjango.com/mac/istatmenus/): dense, readable status rows and clear metric units.
- [CodexBar](https://github.com/steipete/CodexBar): explicit usage windows and reset information.
- [cc-bar](https://github.com/nanvon/cc-bar): flat provider sections, separators, native header controls. The locally cached `MenuBar/PopoverRootView.swift` and `Main/DesignSystem.swift` were inspected for presentation patterns.

References guide visual hierarchy only. VibeDeck preserves its own collection, credentials, devices, accounting, navigation and lifecycle. The cc-bar README and the Stats/CodexBar repository references were checked during this pass; presentation details were also compared with the local cc-bar source snapshot.
