# Verified fixes

- Bound the window delegate when the AppKit view enters its window, enabling document close prompts and titles reliably.
- Suspended unmodified canvas shortcuts while editing text, and decoded shifted number keys for scene capture.
- Kept output recording active during media preparation and prepared replacement audio before swapping clips.
- Padded short source audio to video duration, preventing early audio loops.
- Applied video track orientation to compositor frames; tested an actual 90-degree rotated fixture.
- Replaced the executable atomically during builds so an already-running app is not overwritten in place.
- Captured the specific tested document window, allowing additional empty windows without invalid visual evidence.
