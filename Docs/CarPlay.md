# CarPlay audio

Funston uses the CarPlay audio templates on iOS 18 and later. The CarPlay scene shares the app's `AppEnvironment` and `PlaybackController`, including its queue, remembered listening positions, playback speed, sleep timer, artwork, and remote controls. It can launch without an iPhone scene. Disconnecting CarPlay leaves audio playing.

The four tabs are:

- **Listen:** the current recording and the existing Continue Listening shelf.
- **Library:** public saved audio items, with a recording list for each.
- **Downloads:** completed, present, supported audio files; selecting one uses the local file and offline queue.
- **Explore:** popular audio from Old Time Radio and Live Music Archive.

Selecting a recording opens the shared system Now Playing template. Its Recordings button opens the current queue. Books, video, incomplete downloads, and missing local files are excluded. Starting audio while the phone owns video playback reports an error. List and tab counts respect CarPlay's template limits.

## Signing

`Funston/Funston.entitlements` declares `com.apple.developer.carplay-audio`; both the XcodeGen specification and generated Xcode project reference it. The scene manifest registers the phone and CarPlay delegates separately.

For a device or App Store build, request the audio entitlement from [Apple](https://developer.apple.com/contact/carplay), enable the granted managed capability on the app's identifier, and use a provisioning profile containing it. See [Requesting CarPlay Entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements). Adding the file alone does not grant the developer account this capability.

## Verification

Run `CarPlayTests` for routing, audio filtering, shared queue selection, and cancellation. In the older Simulator app, launch Funston and choose **I/O > External Displays > CarPlay**. Xcode 27 uses Device Hub and its CarPlay Simulator integration instead; that integration requires a physical iPhone connected over USB. It does not support an iOS simulator as the phone. This is tracked by Apple as issue 179494052 / FB23101450 in the [Xcode 27.2 beta 2 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes). The Mac supplies the simulated vehicle display, so this testing route does not require a car. The physical phone still needs a signed Funston build with the approved audio entitlement. The following checks are developer validation work:

1. Open Funston from the CarPlay home screen, including with the phone app closed.
2. Browse both collections, choose a recording, and check Now Playing title, artwork, play/pause, skip controls, and Recordings.
3. Save or remove audio on the phone and check Library in CarPlay.
4. Download audio, go offline, and play it through Downloads; deleted files and video must not appear.
5. Switch playback on the phone and check that CarPlay follows the same queue. Disconnect and reconnect while playing; playback and its position should persist.
6. Verify rotary/touch navigation and announcements with a real head unit, and playback through interruptions and route changes.

Simulator unit tests and compilation do not establish real head-unit behavior or entitlement approval.

### Simulator attempt — October 8, 2026

Actual CarPlay UI verification remains blocked on the installed Xcode 27.0 (27A266a). Two dedicated iPhone 17 Pro simulators were used, on iOS 26.5 and iOS 27.0. Existing simulators and their app data were left alone. The later diagnosis below explains why this setup could not produce a CarPlay session.

Device Hub attachment through the computer-use tool failed with an AppleEvent timeout (`-1712`). As a diagnostic fallback, CoreSimulator's CarPlay service was enabled, the virtual CarPlay screen was powered on, and its CarPlay display properties were configured. The system CarPlay process started and the display accepted an 800 × 480 geometry. On iOS 26.5, the guest exposed that screen as AirPlay: inspecting Funston's connected scenes showed `UIWindowSceneSessionRoleExternalDisplayNonInteractive`, not `CPTemplateApplicationSceneSessionRoleApplication`. Screenshots were blank before launching the phone app, then showed its ordinary phone interface. On iOS 27, scene inspection showed only the phone application scene, with no CarPlay scene. Neither attempt reached the CarPlay home screen. These screenshots are connection diagnostics, not verified CarPlay screenshots.

The previously passing 25 automated checks establish build, routing, filtering, selection, cancellation, and playback/resume behavior only. They do not establish that the CarPlay home screen, tabs, Now Playing, or navigation work in a real simulator session. No generic phone VoiceOver regression pass was repeated. VoiceOver was briefly enabled on the new iOS 26.5 simulator while diagnosing the display, then disabled; it did not establish CarPlay focus or speech.

Apple documents [CarPlay Voice Control and visual accessibility settings](https://support.apple.com/en-gb/guide/iphone/iph53475523f/ios), but that documentation does not establish VoiceOver support on the CarPlay display. No claim of CarPlay VoiceOver support or verification is made here.

Connection logs, scene inspection, diagnostic screenshots, and the temporary connection probe source are in `output/carplay-verification/`. The two dedicated simulators were shut down after the attempt. A working CarPlay Simulator connection is still needed to execute the UI checks above; this is not a requirement for the user to own or drive a car.

### Diagnosis — October 8, 2026

The failure occurs before Funston's CarPlay scene delegate is called. Apple's current release notes explicitly exclude iOS Simulator phones from Device Hub CarPlay support. An exposed framebuffer labeled CarPlay, a running `CarPlay` process, and successful private-API completion callbacks do not establish a supported vehicle connection. The previous probe started those components but did not create a CarPlay session.

Funston's built scene manifest contains the correct CarPlay role, scene class, and delegate, and the simulator executable embeds the audio entitlement. No application-side cause for the missing session was found. This is a diagnosis of the failed test setup, not a claim that every app-side UI behavior is correct. The installed Xcode 27.0 notes also mention a resolved Device Hub CarPlay connection issue (179523697), but that is a different issue and does not imply support for simulated phones.

No older Simulator.app installation or USB-attached iPhone was found on this Mac during diagnosis. The available supported route is a physical iPhone over USB with Device Hub acting as the car display. A legacy Simulator.app would be a separate workaround to investigate, not a verified fix for this installation. No app code was changed to work around the unsupported connection.
