## 1.0.1

- Improved README: added Dependencies table, Assets setup guide, and expression detection basis details
- Clarified package description in `pubspec.yaml`
- Added homepage, repository, and issue tracker metadata to `pubspec.yaml`
- Added MIT License

## 1.0.0

Initial release of the `aliveness` Flutter package for face liveness detection.

- 11 built-in facial challenge expressions: smile, blink, left/right pose, nod up/down, tilt left/right, open mouth, wink left/right
- Randomized challenge order per session to prevent replay attacks
- Wrong gesture detection with real-time feedback
- Low-light detection — pauses and prompts user when ambient light is insufficient
- Per-challenge cropped face photo capture via `FaceLivenessData.photos`
- Haptic feedback on challenge success and wrong gesture
- Cross-platform support: iOS (BGRA8888) and Android (YUV420) camera formats
- iOS euler angle mirror correction for accurate left/right/tilt detection
- Android eye coordinate correction for consistent `winkLeft`/`winkRight` behavior
- Built on `google_mlkit_face_detection`, `camera`, and `image` packages
