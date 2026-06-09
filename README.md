# aliveness

A Flutter package for **face liveness detection** — verifies that a user is a real, live person by guiding them through a sequence of randomized facial expression challenges captured via the front camera.

Built on top of [Google ML Kit Face Detection](https://pub.dev/packages/google_mlkit_face_detection).

---

## Features

- **11 built-in challenge expressions** — blink, smile, head turns, nods, tilts, open mouth, and per-eye winks
- **Randomized challenge order** — shuffled on every session to prevent replay attacks
- **Wrong gesture detection** — real-time feedback when the user performs the incorrect expression
- **Low-light detection** — pauses detection and prompts the user when ambient light is insufficient
- **Per-challenge photo capture** — returns one cropped face image per completed challenge
- **Haptic feedback** — vibration on success and wrong gesture
- **Cross-platform** — supports iOS (BGRA8888) and Android (YUV420) camera formats

---

## Platform Setup

### Android

Add the camera permission to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

Set the minimum SDK version in `android/app/build.gradle`:

```gradle
minSdkVersion 21
```

### iOS

Add the camera usage description to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera is required for face liveness detection.</string>
```

---

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  aliveness: ^1.0.1
```

Then run:

```bash
flutter pub get
```

---

## Usage

### Basic

```dart
import 'package:aliveness/aliveness.dart';

final FaceLivenessData? result = await Aliveness().start(
  context: context,
  expressions: [
    ChallengeExpression.smile,
    ChallengeExpression.eyeblink,
    ChallengeExpression.leftPose,
    ChallengeExpression.rightPose,
    ChallengeExpression.nodUp,
    ChallengeExpression.nodDown,
    ChallengeExpression.tiltLeft,
    ChallengeExpression.tiltRight,
    ChallengeExpression.openMouth,
    ChallengeExpression.winkLeft,
    ChallengeExpression.winkRight,
  ],
);

if (result != null) {
  final List<img.Image> photos = result.photos;
  // photos[0] → cropped face from challenge 1
  // photos[1] → cropped face from challenge 2
  // ...
}
```

The challenge order is **automatically shuffled** on every call — you do not need to shuffle the list yourself.

### Handling Cancellation

`start()` returns `null` if the user exits the screen before completing all challenges:

```dart
final result = await Aliveness().start(
  context: context,
  expressions: [ChallengeExpression.smile, ChallengeExpression.eyeblink],
);

if (result == null) {
  // User cancelled or exited early
  return;
}

// Proceed with result.photos
```

### Converting Photos to Bytes

The returned images are `img.Image` objects from the [`image`](https://pub.dev/packages/image) package. To convert to raw bytes (e.g. for upload):

```dart
import 'package:image/image.dart' as img;

for (final photo in result.photos) {
  final Uint8List bytes = Uint8List.fromList(img.encodeJpg(photo));
  // Upload or display bytes
}
```

---

## Available Expressions

| Expression | Description | Detection Basis |
|---|---|---|
| `ChallengeExpression.smile` | Smile for the camera | `smilingProbability > 0.5` |
| `ChallengeExpression.eyeblink` | Blink both eyes | Either eye `openProbability < 0.3` |
| `ChallengeExpression.leftPose` | Turn head to the left | `headEulerAngleY > 10°` ¹ |
| `ChallengeExpression.rightPose` | Turn head to the right | `headEulerAngleY < -10°` ¹ |
| `ChallengeExpression.nodUp` | Look up | `headEulerAngleX > 15°` |
| `ChallengeExpression.nodDown` | Look down | `headEulerAngleX < -15°` |
| `ChallengeExpression.tiltLeft` | Tilt head to the left | `headEulerAngleZ < -20°` ¹ |
| `ChallengeExpression.tiltRight` | Tilt head to the right | `headEulerAngleZ > 20°` ¹ |
| `ChallengeExpression.openMouth` | Open mouth wide | Lip contour gap / face height > 5% |
| `ChallengeExpression.winkLeft` | Wink left eye only | Subject's left eye closed, right open ² |
| `ChallengeExpression.winkRight` | Wink right eye only | Subject's right eye closed, left open ² |

> ¹ **iOS mirror correction** — ML Kit reports raw (unmirrored) euler angles. The package negates Y and Z on iOS so the detected direction matches the mirrored camera preview the user sees.
>
> ² **Android eye coordinate correction** — Android ML Kit uses image-space coordinates for eye landmarks (`leftEye` = camera-left = subject's right). The package swaps the probabilities on Android so `winkLeft`/`winkRight` consistently refer to the subject's own eye.

You can pass any subset or combination. At least one expression is required — passing an empty list throws an exception.

---

## Return Value

`start()` returns a `FaceLivenessData?` object:

```dart
class FaceLivenessData {
  final List<img.Image> photos; // one cropped face image per completed challenge
}
```

The list length equals the number of expressions passed. Each image is a square-cropped face photo captured at the moment the challenge was completed.

---

## Assets

This package requires icon assets to display challenge instructions. Add the following files to your app's asset bundle under `assets/icons/`:

| File | Used for |
|---|---|
| `icon_face_liveness_smile.png` | Smile challenge |
| `icon_face_liveness_blink.png` | Eyeblink challenge |
| `icon_face_liveness_look_left.png` | Left pose challenge |
| `icon_face_liveness_look_right.png` | Right pose challenge |
| `icon_face_liveness_nod_up.png` | Nod up challenge |
| `icon_face_liveness_nod_down.png` | Nod down challenge |
| `icon_face_liveness_tilt_left.png` | Tilt left challenge |
| `icon_face_liveness_tilt_right.png` | Tilt right challenge |
| `icon_face_liveness_open_mouth.png` | Open mouth challenge |
| `icon_face_liveness_wink_left.png` | Wink left challenge |
| `icon_face_liveness_wink_right.png` | Wink right challenge |

Declare them in your `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/icons/
```

---

## Dependencies

| Package | Version | Purpose |
|---|---|---|
| `camera` | `^0.12.0+1` | Camera stream access |
| `google_mlkit_face_detection` | `^0.13.2` | Face metrics and contour detection |
| `image` | `^4.9.1` | Image conversion and cropping |

---

## License

MIT
