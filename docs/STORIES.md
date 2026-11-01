# Native parity milestone — everything except motion

Reference: desktop/README.md and desktop/renderer. Motion recording/playback is deliberately excluded; imported motion is ignored, with a visible notice.

- done: Editing: multi-selection, group drag/resize, individual playback/timeline, volume, speed, mirror, five blend modes, layers, duplicate/delete/clear, undo/redo.
  UX: Canvas with selection outlines and corner handles; scrollable inspector and layers tab. Shift-click extends selection. Controls apply to all selected clips; timeline and rating apply to one. Gestures form one undo step. Clean view disables editing.
- done: Media/folders: codec conversion, independent keep/position locks, aspect-aware free-region grid, count changes, automatic shuffle, ratings, external player/Finder.
  UX: Setup inspector tab for folder/count/timer/canvas size; progress and cancellation during imports; errors preserve the current composition. Context menu for source actions and ratings.
- done: Projects/scenes: portable browser/desktop project compatibility, nine named slots with previews, save/save-as, window titles/dirty state, close prompt and recovery.
  UX: Scenes inspector tab with Capture, Recall, Rename; native file dialogs; Save/Discard/Cancel on close; recovery reopens interrupted documents. No motion controls.
- done: Output: shared blend-aware compositor for live canvas, PNG, real-time MP4 with mixed audio; window/fixed canvas and fullscreen.
  UX: Output toolbar menu, native save dialog, recording badge and Stop. Export excludes editing controls. Closing requires finishing recording.
- done: Verify: synthetic video/audio fixtures, portable round trip through Electron storage, editing/undo/scenes, locks/grid/shuffle/ratings, PNG/MP4 media inspection, real window interactions, light/dark snapshots; install final release.
