-- SPDX-License-Identifier: GPL-2.0-or-later
---------------------------------------------------------------------------
-- BazMap User Guide
---------------------------------------------------------------------------

if not BazCore or not BazCore.RegisterUserGuide then return end

BazCore:RegisterUserGuide("BazMap", {
    title = "BazMap",
    intro = "Detaches the World Map from Blizzard's panel system and turns it into a freely resizable, repositionable window - with independent layouts for map mode and quest log mode.",
    pages = {
        {
            title = "Welcome",
            blocks = {
                { type = "lead", text = "BazMap reparents the World Map (M) into its own container so it behaves like a normal addon window: drag the edges to resize, drag the title to move, and the rest of your UI doesn't get shoved around when you open it." },
                { type = "h2", text = "Two layouts in one" },
                { type = "paragraph", text = "Map mode and quest log mode each remember their own size and position. You can have a large map for exploring zones and a compact quest log for tracking - switching between them no longer resets the other." },
            },
        },
        {
            title = "How It Works",
            blocks = {
                { type = "paragraph", text = "BazMap creates a container frame, reparents WorldMapFrame inside it, and re-steals the map every frame in case anything else tries to reparent it." },
                { type = "note", style = "info", text = "The polling protects against UI taint and panel-system interference." },
                { type = "h3", text = "Storage" },
                { type = "paragraph", text = "Your saved layouts live in two profiles inside |cffffd700BazMapDB|r: one for map mode, one for quest log mode. Each profile stores height + position. Width is always derived from height using the map's aspect ratio." },
            },
        },
        {
            title = "Resizing & Moving",
            blocks = {
                { type = "h3", text = "Resize" },
                { type = "paragraph", text = "Drag any edge or corner of the window. The map content scales to fit." },
                { type = "h3", text = "Move" },
                { type = "paragraph", text = "Drag the title area to reposition. The new position is saved automatically." },
                { type = "h3", text = "Modes" },
                { type = "table",
                  columns = { "Key", "Mode" },
                  rows = {
                      { "M",  "World Map" },
                      { "L",  "Quest Log" },
                  },
                },
                { type = "note", style = "tip", text = "Each mode loads its own saved size and position. Switching modes saves the current layout and loads the other." },
            },
        },
        {
            title = "Why Two Layouts?",
            blocks = {
                { type = "paragraph", text = "The world map and quest log have very different ideal sizes:" },
                { type = "list", items = {
                    "|cffffd700Map|r is best big and centered - you want to read zone names, see icons, plan routes",
                    "|cffffd700Quest log|r is best compact and to one side - a reference panel that doesn't dominate the screen",
                }},
                { type = "note", style = "info", text = "With one combined layout, you'd be constantly resizing as you switched. BazMap saves both." },
            },
        },
        {
            title = "Profile Support",
            blocks = {
                { type = "paragraph", text = "Per-character profiles via BazCore - one character can have a giant fullscreen map while another runs a compact corner panel. Switch profiles in the Profiles sub-category." },
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
                      { "/bmap",         "Alias for /bazmap - every subcommand works on either form" },
                  },
                },
            },
        },
    },
})
