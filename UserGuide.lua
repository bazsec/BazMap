-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazMap User Guide
---------------------------------------------------------------------------

if not BazCore or not BazCore.RegisterUserGuide then return end

BazCore:RegisterUserGuide("BazMap", {
    title = "BazMap",
    intro = "Detaches the World Map from Blizzard's panel system and turns it into a freely resizable, repositionable window — with independent layouts for the map, the quest log, and the quest detail view.",
    pages = {
        {
            title = "Welcome",
            blocks = {
                { type = "lead", text = "BazMap takes the World Map out of Blizzard's centred panel and gives it its own resizable, draggable window. The rest of your UI doesn't get shoved around when you open it, and you can size it however you want without losing the layout the next time you open it." },
                { type = "h2", text = "Three layouts in one" },
                { type = "paragraph", text = "Map mode (default key |cffffd700M|r), quest log mode (default key |cffffd700L|r), and quest detail view (clicking a tracked quest in the objective tracker) each remember their own size and position. You can have a large map for exploring zones, a compact quest log for tracking, and a comfortable layout for reading quest details — switching between them no longer resets the others." },
            },
        },
        {
            title = "Resizing & Moving",
            blocks = {
                { type = "h3", text = "Resize" },
                { type = "paragraph", text = "Drag any edge or corner of the window. The map content scales to fit. Width is computed automatically from height to keep the map's aspect ratio — you can't accidentally squish it." },
                { type = "h3", text = "Move" },
                { type = "paragraph", text = "Drag the title area to reposition. The new position saves automatically when you release." },
                { type = "h3", text = "Reset" },
                { type = "paragraph", text = "If you've dragged the map off-screen or sized it down to nothing, |cffffd700/bazmap reset|r restores the default size and position for all three views." },
            },
        },
        {
            title = "Why Three Layouts?",
            blocks = {
                { type = "paragraph", text = "The world map shows up in three different shapes depending on what you're doing, and each shape has a different ideal size:" },
                { type = "list", items = {
                    "|cffffd700Map|r is best big and centred — you want to read zone names, see icons, plan routes",
                    "|cffffd700Quest log|r is best compact and to one side — a reference panel that doesn't dominate the screen",
                    "|cffffd700Quest detail|r needs the map for context plus the details panel for reading — its own ideal size sits between the other two",
                }},
                { type = "note", style = "info", text = "With one combined layout you'd be constantly resizing as you switched. BazMap saves all three so you set them up once and never touch them again." },
            },
        },
        {
            title = "Profiles",
            blocks = {
                { type = "paragraph", text = "BazMap uses BazCore's per-character profile system. One character can have a giant fullscreen map while another runs a compact corner panel. Switch profiles in |cffffd700Settings → BazMap → Profiles|r." },
            },
        },
        {
            title = "Slash Commands",
            blocks = {
                { type = "table",
                  columns = { "Command", "Effect" },
                  rows = {
                      { "/bazmap",       "Open the BazMap settings page" },
                      { "/bazmap reset", "Reset map and quest-log window positions to defaults" },
                      { "/bmap",         "Alias for /bazmap — every subcommand works on either form" },
                  },
                },
            },
        },
    },
})
