# BazMap Changelog

## 014 - Fix POI Tooltip Taint Error
- Fixed "attempt to perform arithmetic on local 'textHeight' (a secret number value tainted by 'BazMap')" error when hovering Area POIs on the world map
  - Root cause: BazMap's `SetAttribute` calls on WorldMapFrame (required to detach from Blizzard's panel layout system) taint the frame's attribute table; taint then propagates through GameTooltip → UIWidgets → `UIWidgetTemplateTextWithStateMixin:Setup` where `GetStringHeight()` returns a tainted number and `Clamp()` fails on arithmetic
  - Fix: wrapped `UIWidgetTemplateTextWithStateMixin.Setup` in a pcall at file scope so the taint error is caught silently; the widget text may not render in that specific tooltip but the tooltip itself still shows and the map is fully functional
  - Investigated alternative approaches (modifying `UIPanelWindows` table instead of `SetAttribute`) but these break `MaximizeUIPanel` because the `panel-maximize` secure handler reads attributes directly off the frame, not the Lua table — `SetAttribute` is the only viable way to detach from the panel system

## 013 - Icon Update
- Changed addon panel icon to inv_misc_map_01

## 012 - Unified Profiles
- Profiles now managed centrally in BazCore settings
- Removed per-addon Profiles subcategory

## 009
- Category changed to "Baz Suite"

## 008
- Version bump to re-trigger CurseForge upload

## 007
- Resize handle now uses BazCore:MakeResizable() shared utility

## 006
- License changed to GPL v2 (consistent with Baz Suite)

## 005 - BazCore Migration
- Migrated to BazCore framework (profiles, settings panel, minimap button)
- Fixed mode detection: M now correctly opens map mode, L opens quest log mode
- Deferred mode detection to next frame for reliable QuestMapFrame state
- Replaced deprecated UIDropDownMenu and InterfaceOptionsCheckButtonTemplate
- BazCore is now a required dependency

## Version 4
- **License Update:** Project is now licensed under GNU GPL v3.
- **Codebase:** Added license headers and LICENSE file.

## Version 3
- **Container Architecture:** Restored container-based architecture to properly wrap the World Map.
- **Scaling & Resizing:** Implemented synchronous scaling fixes to ensure the map fits perfectly within the container when resized.
- **Window Management:**
  - Added persistence for Map and Quest Log positions independently.
  - Added resize grip to the bottom right.
  - Enforced "Always on Top" constraints for the resize handle.
- **Compatibility:**
  - Added conflict resolution for "BlizzMove" (disables BlizzMove's WorldMap handling to prevent conflicts).
  - Implemented aggressive parenting logic ("Nuclear Enforcer") to keep the World Map inside the BazMap container.
- **Options Panel:** Added a configuration panel with buttons to reset Map and Quest profiles.
- **UX Improvements:**
  - Removed "Blackout" background for a cleaner look.
  - Solved visibility flicker during map mode transitions.
