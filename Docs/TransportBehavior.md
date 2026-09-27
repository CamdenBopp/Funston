# Track transport behavior — build 5

- Next and Previous preserve explicit playback intent, including while an item loads or audio-session activation is pending. A temporary zero player rate is not treated as a user pause.
- Paused track navigation stays paused. Explicit queue selection remains a Play action.
- The full and compact players show Pause while preparing to play; their button labels and actions share the same state rule. Preparing a paused selection shows Play.
- Previous retains the existing restart-current-recording behavior after five seconds. Next at the queue boundary does nothing; natural completion of the final recording ends playback.
- Remote Next/Previous commands use the same controller methods. No polling, extra progress observers, or playback library was added.

## Verification

The pre-change two-test baseline reproduced unwanted autoplay when navigating while paused. Continuing playback during ordinary local track changes already passed; the misleading Play appearance during preparation was established by source inspection rather than claimed as a reproduced audio failure.

The final full iOS 27 simulator suite passed **60/60 tests**, with zero skips or runtime warnings (`/tmp/FunstonTransportTests2.xcresult`). New checks cover playing/paused navigation, rapid replacement, delayed activation, restart-current behavior, automatic advancement, the queue boundary, and transport button semantics. The live-stream UI journey verifies Play → Next → Previous reaches Playing without another Play tap, then verifies Pause.

Signed Release 0.2.0 (5) was installed on the iPhone 14 Pro Max without deleting app data. After the user unlocked the device, the app launched and remained running through the post-launch check, with no new app crash reports. This establishes launch survival, not physical-device playback verification. Manual Lock Screen, interruption, and route-change testing remains separate. This change does not claim gapless streaming.

Apple's [transport behavior documentation](https://developer.apple.com/documentation/avfoundation/controlling-the-transport-behavior-of-a-player) distinguishes readiness, requested playback, waiting, and actual playback—the UI must not conflate them.
