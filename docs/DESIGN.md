# Native parity design

Document windows with a black composition canvas, standard toolbar, and a scrollable right inspector. Inspector tabs: Video, Layers, Scenes, Setup. All screens use system controls, text sizes, and light/dark appearance. Content stays local.

Menus mirror toolbar/context actions. Command-N/O/S/Shift-S for documents, Command-Z/Shift-Z for history, Space for global playback, P/Escape for clean view, G/Shift-G for grid/shuffle, 1–9/Shift-1–9 for scenes, H/V for screenshot/output recording. Editing shortcuts ignore text entry. Empty canvas offers Add Videos and Choose Folder. Progress and errors remain visible near the canvas. Feel: direct, predictable editing.

## Design plan

The document editor keeps a content-first canvas with a flat right inspector. Video groups Playback, Appearance, Placement and Source; Layers lists front to back; Scenes keeps nine numbered slots; Setup groups source, shuffle, canvas and output. Standard native toolbar chrome provides readable document identity in both appearances. Clean view fits the composition without changing its layout. Empty canvas invites importing; empty selection points to canvas or Layers. Frequent canvas actions retain their documented shortcuts while inspector controls receive normal keyboard input. The intended feeling is direct, predictable editing.


Settings is one app-wide native Settings window, opened from Vollage > Settings… (Command-comma) or the toolbar gear. Its single grouped form offers System, Light, and Dark as radio choices. System is the default. Changes apply immediately to all windows and persist across launches; they do not edit a project. No empty state is needed. Keep the pane compact, with system styling and no initial control focus.
