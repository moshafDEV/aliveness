import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import '../../../image/image_processing.dart';
import '../../aliveness.dart';

// Duration to display the success state before proceeding to the next challenge.
const _kSuccessDuration = Duration(milliseconds: 1200);

// Duration for animated transitions in the UI (border color, alert fade, etc.).
const _kAnimationDuration = Duration(milliseconds: 200);

class FaceLivenessProcessing extends StatefulWidget {
  final List<ChallengeExpression> expression;
  const FaceLivenessProcessing({super.key, required this.expression});

  @override
  State<FaceLivenessProcessing> createState() => _FaceLivenessProcessingState();
}

class _FaceLivenessProcessingState extends State<FaceLivenessProcessing>
    with TickerProviderStateMixin {
  // Face detector configured for classification (smile, eye open) and contours.
  final FaceDetector faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      minFaceSize: 0.3,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  late CameraController cameraController;

  // Tracks whether the camera has finished initializing.
  final ValueNotifier<bool> isCameraInitialized = ValueNotifier(false);

  // Index of the currently active challenge in the expression list.
  final ValueNotifier<int> currentActionIndex = ValueNotifier(0);

  // Indicates whether at least one face is present in the current frame.
  final ValueNotifier<bool> isFaceDetected = ValueNotifier(false);

  // Indicates that the current challenge was just completed successfully.
  // When true, the UI shows a success overlay before advancing to the next step.
  final ValueNotifier<bool> isChallengeSuccess = ValueNotifier(false);

  // Indicates that the user performed the wrong expression for the current challenge.
  // When true, a red flash animation is triggered along with an explanatory message.
  final ValueNotifier<bool> isWrongGesture = ValueNotifier(false);

  // Message displayed alongside the wrong gesture alert to guide the user.
  final ValueNotifier<String> wrongGestureMessage = ValueNotifier('');

  // Indicates that the current environment brightness is below the acceptable threshold.
  // When true, face detection and challenge evaluation are suspended until light improves.
  final ValueNotifier<bool> isLowLight = ValueNotifier(false);

  // Indicates that takePicture() is currently in progress.
  // When true, a circular progress indicator is overlaid on the face ring
  // to communicate that the capture is being processed.
  final ValueNotifier<bool> isCapturing = ValueNotifier(false);

  // Controls the red background blink animation on wrong gesture.
  late final AnimationController _wrongGestureAnimController;
  late final Animation<double> _wrongGestureOpacity;

  // Minimum average luminance (Y channel, 0–255) required to proceed with detection.
  // Frames below this threshold are considered too dark for reliable analysis.
  static const double _kMinLuminanceThreshold = 50.0;

  // Raw face metric values stored locally for challenge evaluation logic only.
  // These do not drive any UI rebuild directly.
  double? smilingProbability;
  double? leftEyeOpenProbability;
  double? rightEyeOpenProbability;
  double? headEulerAngleY;

  // Guards against concurrent face detection calls on overlapping stream frames.
  bool isDetecting = false;

  // When true, the detector waits for the user to return to a neutral expression
  // before evaluating the next challenge. This prevents a single gesture from
  // satisfying multiple consecutive challenges.
  bool waitingForNeutral = true;

  // Prevents checkChallenge from running while the success overlay is displayed.
  bool isShowingSuccess = false;

  // Prevents the wrong gesture alert from firing repeatedly in quick succession.
  bool _wrongGestureCooldown = false;

  // Accumulates one captured photo per completed challenge.
  // The full list is returned to the caller once all challenges are done.
  final List<img.Image> capturedPhotos = [];

  // Accumulates the face bounding box for each completed challenge.
  // Passed to FaceEmbeddingService so it can crop without re-running ML Kit.
  final List<Rect> capturedFaceBoxes = [];

  @override
  void initState() {
    super.initState();
    initializeCamera();
    // Randomize challenge order to prevent predictable liveness attacks.
    widget.expression.shuffle();

    // Two-blink red flash: fade in then fade out, played twice in sequence.
    _wrongGestureAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _wrongGestureOpacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0.0, end: 0.55), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: 0.55, end: 0.0), weight: 1),
    ]).animate(_wrongGestureAnimController);
  }

  // Initializes the front-facing camera and begins the image stream.
  Future<void> initializeCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
    );
    cameraController = CameraController(
      frontCamera,
      ResolutionPreset.high,
      // FIX: Android does not support jpeg for image streams — it silently
      // falls back to YUV420 but with wrong metadata, corrupting ML Kit input
      // and _yuv420ToImage output. Use the correct native format per platform.
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
      enableAudio: false,
    );
    await cameraController.initialize();
    // Disable flash explicitly to prevent the torch from firing on takePicture(),
    // which is the default behavior on iOS when FlashMode is not set.
    await cameraController.setFlashMode(FlashMode.off);
    if (mounted) {
      isCameraInitialized.value = true;
      startFaceDetection();
    }
  }

  DateTime? lastDetectionTime;

  // Starts the camera image stream and throttles frame processing to
  // approximately one detection cycle every 300 milliseconds.
  void startFaceDetection() {
    if (!isCameraInitialized.value) return;

    cameraController.startImageStream((CameraImage image) {
      final now = DateTime.now();
      final shouldProcess =
          lastDetectionTime == null ||
          now.difference(lastDetectionTime!) >
              const Duration(milliseconds: 300);

      if (shouldProcess && !isDetecting) {
        lastDetectionTime = now;
        isDetecting = true;
        detectFaces(image).then((_) => isDetecting = false);
      }
    });
  }

  // Converts a raw CameraImage frame into an InputImage and runs face detection.
  // Handles platform differences: iOS uses BGRA8888 (single plane),
  // Android uses NV21 (multi-plane). Returns early if conversion yields nil.
  Future<void> detectFaces(CameraImage image) async {
    try {
      // Evaluate ambient brightness using the Y (luminance) plane.
      // This runs before the ML detector to avoid wasting resources on dark frames.
      final double luminance = ImageProcessing().computeAverageLuminance(image);
      isLowLight.value = luminance < _kMinLuminanceThreshold;
      if (isLowLight.value) return;

      final rotation = ImageProcessing().getRotation(cameraController);
      final InputImage inputImage = ImageProcessing().buildInputImage(
        image,
        rotation,
      );

      final faces = await faceDetector.processImage(inputImage);

      if (!mounted) return;

      isFaceDetected.value = faces.isNotEmpty;

      if (faces.isNotEmpty) {
        final face = faces.first;

        // Cache the latest face metrics for use in challenge and neutral checks.
        smilingProbability = face.smilingProbability;
        leftEyeOpenProbability = face.leftEyeOpenProbability;
        rightEyeOpenProbability = face.rightEyeOpenProbability;
        headEulerAngleY = face.headEulerAngleY;

        await checkChallenge(
          face,
          image: image,
          rotation: rotation,
          faceDetector: faceDetector,
        );
      }
    } catch (e) {
      debugPrint('Face detection error: $e');
    }
  }

  // Evaluates whether the user has satisfied the current challenge expression.
  // Skips evaluation while a success overlay is displayed or while waiting
  // for the user to return to a neutral pose between challenges.
  Future<void> checkChallenge(
    Face face, {
    required CameraImage image,
    required InputImageRotation rotation,
    required FaceDetector faceDetector,
  }) async {
    if (isShowingSuccess) return;

    // Wait until the user returns to a neutral position before proceeding.
    if (waitingForNeutral) {
      if (isNeutralPosition(face)) {
        waitingForNeutral = false;
      } else {
        return;
      }
    }

    final ChallengeExpression currentAction =
        widget.expression[currentActionIndex.value];
    bool actionCompleted = false;

    // On iOS the front camera preview is mirrored, but MLKit reports the raw
    // (unmirrored) euler angle. Negating aligns the detected direction with
    // what the user sees on screen. Applies to both Y (yaw) and Z (roll).
    final double? eulerY = (defaultTargetPlatform == TargetPlatform.iOS)
        ? (face.headEulerAngleY != null ? -face.headEulerAngleY! : null)
        : face.headEulerAngleY;
    final double? eulerZ = (defaultTargetPlatform == TargetPlatform.iOS)
        ? (face.headEulerAngleZ != null ? -face.headEulerAngleZ! : null)
        : face.headEulerAngleZ;

    // iOS Vision uses subject-relative eye coordinates (leftEye = subject's left).
    // Android ML Kit uses image coordinates (leftEye = camera-left = subject's right).
    // Swapping on Android aligns wink detection with what the user is asked to do.
    final double? subjectLeftEye = (defaultTargetPlatform == TargetPlatform.android)
        ? face.rightEyeOpenProbability
        : face.leftEyeOpenProbability;
    final double? subjectRightEye = (defaultTargetPlatform == TargetPlatform.android)
        ? face.leftEyeOpenProbability
        : face.rightEyeOpenProbability;

    switch (currentAction) {
      case ChallengeExpression.smile:
        actionCompleted =
            face.smilingProbability != null && face.smilingProbability! > 0.5;
        break;
      case ChallengeExpression.eyeblink:
        actionCompleted =
            (face.leftEyeOpenProbability != null &&
                face.leftEyeOpenProbability! < 0.3) ||
            (face.rightEyeOpenProbability != null &&
                face.rightEyeOpenProbability! < 0.3);
        break;
      case ChallengeExpression.leftPose:
        actionCompleted = eulerY != null && eulerY > 10;
        break;
      case ChallengeExpression.rightPose:
        actionCompleted = eulerY != null && eulerY < -10;
        break;
      case ChallengeExpression.nodUp:
        actionCompleted =
            face.headEulerAngleX != null && face.headEulerAngleX! > 15;
        break;
      case ChallengeExpression.nodDown:
        actionCompleted =
            face.headEulerAngleX != null && face.headEulerAngleX! < -15;
        break;
      case ChallengeExpression.tiltLeft:
        actionCompleted = eulerZ != null && eulerZ < -20;
        break;
      case ChallengeExpression.tiltRight:
        actionCompleted = eulerZ != null && eulerZ > 20;
        break;
      case ChallengeExpression.openMouth:
        actionCompleted = _isMouthOpen(face);
        break;
      case ChallengeExpression.winkLeft:
        actionCompleted =
            (subjectLeftEye != null && subjectLeftEye < 0.3) &&
            (subjectRightEye != null && subjectRightEye > 0.6);
        break;
      case ChallengeExpression.winkRight:
        actionCompleted =
            (subjectRightEye != null && subjectRightEye < 0.3) &&
            (subjectLeftEye != null && subjectLeftEye > 0.6);
        break;
    }

    if (actionCompleted) {
      await _handleChallengeCompleted(
        image: image,
        rotation: rotation,
        faceDetector: faceDetector,
      );
    } else {
      await _detectWrongGesture(face, currentAction);
    }
  }

  // Checks whether the user is performing a recognizable expression that does
  // not match the current challenge. Triggers a red flash alert with a
  // descriptive message when a wrong gesture is confidently detected.
  Future<void> _detectWrongGesture(Face face, ChallengeExpression expected) async {
    if (_wrongGestureCooldown || isShowingSuccess) return;

    final bool isSmiling =
        face.smilingProbability != null && face.smilingProbability! > 0.5;
    final bool isBlinking =
        (face.leftEyeOpenProbability != null &&
            face.leftEyeOpenProbability! < 0.3) ||
        (face.rightEyeOpenProbability != null &&
            face.rightEyeOpenProbability! < 0.3);
    final bool isTurningLeft =
        face.headEulerAngleY != null && face.headEulerAngleY! > 10;
    final bool isTurningRight =
        face.headEulerAngleY != null && face.headEulerAngleY! < -10;
    final double? localEulerZ = (defaultTargetPlatform == TargetPlatform.iOS)
        ? (face.headEulerAngleZ != null ? -face.headEulerAngleZ! : null)
        : face.headEulerAngleZ;

    String? message;

    switch (expected) {
      case ChallengeExpression.smile:
        if (isBlinking) message = "Don't blink — smile for the camera.";
        if (isTurningLeft || isTurningRight) {
          message = "Face forward and smile.";
        }
        break;
      case ChallengeExpression.eyeblink:
        if (isSmiling) message = "Stop smiling — blink your eyes slowly.";
        if (isTurningLeft || isTurningRight) {
          message = "Face forward and blink your eyes.";
        }
        break;
      case ChallengeExpression.leftPose:
        if (isTurningRight) {
          message = "Wrong direction — turn your head to the left.";
        }
        if (isSmiling || isBlinking) message = "Turn your head to the left.";
        break;
      case ChallengeExpression.rightPose:
        if (isTurningLeft) {
          message = "Wrong direction — turn your head to the right.";
        }
        if (isSmiling || isBlinking) message = "Turn your head to the right.";
        break;
      case ChallengeExpression.nodUp:
        if (face.headEulerAngleX != null && face.headEulerAngleX! < -15) {
          message = "Wrong direction — look up, not down.";
        }
        if (isTurningLeft || isTurningRight) {
          message = "Face forward and look up.";
        }
        break;
      case ChallengeExpression.nodDown:
        if (face.headEulerAngleX != null && face.headEulerAngleX! > 15) {
          message = "Wrong direction — look down, not up.";
        }
        if (isTurningLeft || isTurningRight) {
          message = "Face forward and look down.";
        }
        break;
      case ChallengeExpression.tiltLeft:
        if (localEulerZ != null && localEulerZ > 20) {
          message = "Wrong direction — tilt your head to the left.";
        }
        break;
      case ChallengeExpression.tiltRight:
        if (localEulerZ != null && localEulerZ < -20) {
          message = "Wrong direction — tilt your head to the right.";
        }
        break;
      case ChallengeExpression.openMouth:
        if (isSmiling && !_isMouthOpen(face)) {
          message = "Open your mouth wide, don't just smile.";
        }
        break;
      case ChallengeExpression.winkLeft:
        if (isBlinking) {
          message = "Wink only your left eye, not both.";
        }
        break;
      case ChallengeExpression.winkRight:
        if (isBlinking) {
          message = "Wink only your right eye, not both.";
        }
        break;
    }

    if (message != null) {
      await _triggerWrongGestureAlert(message);
    }
  }

  // Triggers the red background blink animation twice and displays [message]
  // as an explanatory alert. A cooldown period prevents repeated firing.
  Future<void> _triggerWrongGestureAlert(String message) async {
    _wrongGestureCooldown = true;
    wrongGestureMessage.value = message;
    isWrongGesture.value = true;

    // Vibrate twice to signal wrong gesture — first buzz, short pause, second buzz.
    Future.microtask(() => HapticFeedback.heavyImpact());
    await Future.delayed(const Duration(milliseconds: 150));
    Future.microtask(() => HapticFeedback.heavyImpact());

    // Play two blink cycles: forward then reset, twice.
    await _wrongGestureAnimController.forward();
    _wrongGestureAnimController.reset();
    await _wrongGestureAnimController.forward();
    _wrongGestureAnimController.reset();

    if (!mounted) return;

    // Hold the alert message briefly so the user has time to read it.
    await Future.delayed(const Duration(milliseconds: 1200));

    if (!mounted) return;
    isWrongGesture.value = false;

    // Cooldown window before the next wrong gesture check can fire.
    await Future.delayed(const Duration(milliseconds: 1500));
    _wrongGestureCooldown = false;
  }

  // Handles the transition after a challenge is successfully completed.
  // Captures a photo immediately, shows the success overlay for [_kSuccessDuration],
  // then either proceeds to the next challenge or exits with the full photo list.
  Future<void> _handleChallengeCompleted({
    required CameraImage image,
    required InputImageRotation rotation,
    required FaceDetector faceDetector,
  }) async {
    isCapturing.value = true;

    // Capture a photo for the current challenge before showing the success overlay.
    // FIX #5: Correct camera rotation used for crop in iOS.
    final img.Image? croppedFace = await ImageProcessing().detectAndCrop(
      image,
      rotation,
      faceDetector,
      cameraController: cameraController,
    );

    // If no face was found in the capture frame, abort silently and let the
    // next frame try again. This prevents an empty slot in capturedPhotos.
    if (croppedFace == null) {
      isCapturing.value = false;
      return;
    }

    await _capturePhoto(croppedFace);

    isCapturing.value = false;
    isShowingSuccess = true;
    isChallengeSuccess.value = true;

    // Single vibration to confirm the challenge was accepted.
    Future.microtask(() => HapticFeedback.mediumImpact());

    // Hold the success state so the user receives clear visual feedback.
    await Future.delayed(_kSuccessDuration);

    if (!mounted) return;

    isChallengeSuccess.value = false;

    final int nextIndex = currentActionIndex.value + 1;

    if (nextIndex >= widget.expression.length) {
      // Stop stream before popping to prevent orphaned buffer writes.
      await cameraController.stopImageStream();
      // All challenges completed. Return the full list of captured photos to the caller.
      if (!mounted) return;
      Navigator.pop(context, FaceLivenessData(photos: capturedPhotos));
    } else {
      // Advance to the next challenge and require a neutral reset first.
      currentActionIndex.value = nextIndex;
      waitingForNeutral = true;
      isShowingSuccess = false;
    }
  }

  // Takes a picture and appends it to [capturedPhotos].
  // Also snapshots the current face bounding box into [capturedFaceBoxes]
  // so FaceEmbeddingService can crop without re-running ML Kit.
  Future<void> _capturePhoto(img.Image? croppedFace) async {
    if (croppedFace == null) {
      // detectAndCrop returned null — no face was found in the frame at the
      // moment of capture. Log and skip rather than crashing with a null bang.
      debugPrint('Failed to capture photo: croppedFace is null');
      return;
    }
    capturedPhotos.add(croppedFace);
  }

  // Returns true if the detected face shows no significant expression or head
  // rotation, indicating the user has reset to a resting position between challenges.
  bool isNeutralPosition(Face face) {
    return (face.smilingProbability == null ||
            face.smilingProbability! < 0.1) &&
        (face.leftEyeOpenProbability == null ||
            face.leftEyeOpenProbability! > 0.7) &&
        (face.rightEyeOpenProbability == null ||
            face.rightEyeOpenProbability! > 0.7) &&
        (face.headEulerAngleY == null ||
            (face.headEulerAngleY! > -10 && face.headEulerAngleY! < 10)) &&
        (face.headEulerAngleX == null ||
            (face.headEulerAngleX! > -10 && face.headEulerAngleX! < 10)) &&
        (face.headEulerAngleZ == null ||
            (face.headEulerAngleZ! > -15 && face.headEulerAngleZ! < 15)) &&
        !_isMouthOpen(face);
  }

  // Returns true if the mouth is detectably open, based on the vertical gap
  // between the inner lip contour points relative to the face bounding box height.
  bool _isMouthOpen(Face face) {
    final upperLip = face.contours[FaceContourType.upperLipBottom];
    final lowerLip = face.contours[FaceContourType.lowerLipTop];

    if (upperLip == null ||
        lowerLip == null ||
        upperLip.points.isEmpty ||
        lowerLip.points.isEmpty) {
      return false;
    }

    final upperMidY = upperLip.points[upperLip.points.length ~/ 2].y;
    final lowerMidY = lowerLip.points[lowerLip.points.length ~/ 2].y;
    final gap = (lowerMidY - upperMidY).abs();
    final faceHeight = face.boundingBox.height;

    return faceHeight > 0 && (gap / faceHeight) > 0.05;
  }

  @override
  void dispose() {
    faceDetector.close();
    cameraController.dispose();
    isCameraInitialized.dispose();
    currentActionIndex.dispose();
    isFaceDetected.dispose();
    isChallengeSuccess.dispose();
    isWrongGesture.dispose();
    wrongGestureMessage.dispose();
    isLowLight.dispose();
    _wrongGestureAnimController.dispose();
    isCapturing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: isCameraInitialized,
        builder: (context, isInitialized, _) {
          if (!isInitialized) {
            return const Center(child: CircularProgressIndicator());
          }

          return SizedBox(
            width: double.infinity,
            height: MediaQuery.of(context).size.height,
            child: Stack(
              children: [
                // Full-screen camera preview layer.
                Container(
                  color: Colors.transparent,
                  width: double.infinity,
                  height: MediaQuery.of(context).size.height,
                  padding: const EdgeInsets.only(bottom: 180),
                  child: Center(child: CameraPreview(cameraController)),
                ),

                // Black vignette mask that frames the circular face cutout.
                Center(
                  child: Opacity(
                    opacity: 1,
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          height: MediaQuery.of(context).size.height - 180,
                          decoration: BoxDecoration(
                            border: Border.symmetric(
                              vertical: BorderSide(
                                color: const Color(0xFF1D242D),
                                width:
                                    (MediaQuery.of(context).size.width - 350) /
                                    2,
                              ),
                              horizontal: BorderSide(
                                color: const Color(0xFF1D242D),
                                width:
                                    ((MediaQuery.of(context).size.height -
                                            350) /
                                        2) -
                                    90,
                              ),
                            ),
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF1D242D),
                                width: 80,
                                strokeAlign: BorderSide.strokeAlignOutside,
                              ),
                            ),
                          ),
                        ),
                        Container(height: 180, color: const Color(0xFF1D242D)),
                      ],
                    ),
                  ),
                ),

                // Success overlay: a blurred circle with a green checkmark,
                // displayed briefly when the user completes a challenge.
                ValueListenableBuilder<bool>(
                  valueListenable: isChallengeSuccess,
                  builder: (context, isSuccess, _) {
                    return AnimatedOpacity(
                      opacity: isSuccess ? 1.0 : 0.0,
                      duration: _kAnimationDuration,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 180),
                          child: ClipOval(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                width: 350,
                                height: 350,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Container(
                                    width: 60,
                                    height: 60,
                                    decoration: const BoxDecoration(
                                      color: Colors.greenAccent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.check_rounded,
                                      color: Colors.white,
                                      size: 40,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // Wrong gesture red background blink: a full-screen red overlay that
                // flashes twice when the user performs the incorrect expression.
                // Driven directly by the AnimationController for smooth opacity.
                AnimatedBuilder(
                  animation: _wrongGestureOpacity,
                  builder: (context, _) {
                    return IgnorePointer(
                      child: Container(
                        width: double.infinity,
                        height: MediaQuery.of(context).size.height,
                        color: Colors.red.withAlpha(
                          (_wrongGestureOpacity.value * 255).toInt(),
                        ),
                      ),
                    );
                  },
                ),

                // Wrong gesture message banner: shown while the red flash is active,
                // explaining what expression the user should perform instead.
                ValueListenableBuilder<bool>(
                  valueListenable: isWrongGesture,
                  builder: (context, showAlert, _) {
                    return ValueListenableBuilder<String>(
                      valueListenable: wrongGestureMessage,
                      builder: (context, message, _) {
                        return AnimatedOpacity(
                          opacity: showAlert ? 1.0 : 0.0,
                          duration: _kAnimationDuration,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom:
                                    MediaQuery.of(context).padding.bottom + 30,
                              ),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 32,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withAlpha(
                                    (0.9 * 255).toInt(),
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  message,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),

                // Face detection border ring. Color transitions between:
                //   - green  : challenge just completed successfully
                //   - orange : ambient light is too low for reliable detection
                //   - red    : no face detected in the current frame
                //   - white  : face present, awaiting the required gesture
                // While takePicture() is in progress, a circular progress
                // indicator is overlaid on the ring to signal the capture.
                ValueListenableBuilder<bool>(
                  valueListenable: isChallengeSuccess,
                  builder: (context, isSuccess, _) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: isLowLight,
                      builder: (context, lowLight, _) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: isFaceDetected,
                          builder: (context, faceFound, _) {
                            return ValueListenableBuilder<bool>(
                              valueListenable: isCapturing,
                              builder: (context, capturing, _) {
                                final Color borderColor;
                                if (isSuccess) {
                                  borderColor = Colors.greenAccent;
                                } else if (lowLight) {
                                  borderColor = Colors.orange;
                                } else if (!faceFound) {
                                  borderColor = Colors.red;
                                } else {
                                  borderColor = Colors.white.withAlpha(100);
                                }

                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 180),
                                    child: SizedBox(
                                      width: 350,
                                      height: 350,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          // Border ring.
                                          if (!capturing)
                                            AnimatedContainer(
                                              duration: _kAnimationDuration,
                                              width: 350,
                                              height: 350,
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: borderColor,
                                                  width: 6,
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                            ),

                                          // Circular progress indicator overlaid on
                                          // the ring while takePicture() is running.
                                          // Sized slightly larger than the ring border
                                          // so it sits cleanly on top of it.
                                          if (capturing)
                                            const SizedBox(
                                              width: 350,
                                              height: 350,
                                              child: CircularProgressIndicator(
                                                color: Colors.blueAccent,
                                                strokeWidth: 6,
                                                strokeCap: StrokeCap.round,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),

                // No-face alert banner: fades in when no face is present in frame.
                // Hidden when low-light alert is active to avoid overlapping banners.
                ValueListenableBuilder<bool>(
                  valueListenable: isLowLight,
                  builder: (context, lowLight, _) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: isFaceDetected,
                      builder: (context, faceFound, _) {
                        return AnimatedOpacity(
                          opacity: (!faceFound && !lowLight) ? 1.0 : 0.0,
                          duration: _kAnimationDuration,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Padding(
                              padding: EdgeInsets.only(
                                bottom:
                                    MediaQuery.of(context).padding.bottom + 36,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red.withAlpha(
                                    (0.85 * 255).toInt(),
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.warning_amber_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'No face detected',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),

                // Low-light alert banner: fades in when ambient brightness drops
                // below the minimum luminance threshold. Suspends all detection
                // until the user moves to a better-lit environment.
                ValueListenableBuilder<bool>(
                  valueListenable: isLowLight,
                  builder: (context, lowLight, _) {
                    return AnimatedOpacity(
                      opacity: lowLight ? 1.0 : 0.0,
                      duration: _kAnimationDuration,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: EdgeInsets.only(
                            bottom: MediaQuery.of(context).padding.bottom + 36,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withAlpha(
                                (0.9 * 255).toInt(),
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.light_mode_outlined,
                                  color: Colors.white,
                                  size: 16,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'Move to a brighter area',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // Challenge instruction panel and step counter.
                // Rebuilds only when the active challenge index changes.
                ValueListenableBuilder<int>(
                  valueListenable: currentActionIndex,
                  builder: (context, index, _) {
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.all(30),
                            child: Column(
                              mainAxisSize: MainAxisSize.max,
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Image.asset(
                                  getInstructionIcon(widget.expression[index]),
                                  width: 60,
                                  height: 60,
                                  errorBuilder: (_, e, s) =>
                                      const SizedBox.shrink(),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  getActionDescription(
                                    widget.expression[index],
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Keep holding that pose for a few seconds.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 130),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          top:
                              MediaQuery.of(context).padding.top +
                              kToolbarHeight,
                          left: 16,
                          right: 16,
                          child: Center(
                            child: Text(
                              'Step ${index + 1} of ${widget.expression.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String getActionDescription(ChallengeExpression action) {
    switch (action) {
      case ChallengeExpression.smile:
        return 'Smile for the camera';
      case ChallengeExpression.eyeblink:
        return 'Blink your eyes slowly';
      case ChallengeExpression.leftPose:
        return 'Turn your head to the left';
      case ChallengeExpression.rightPose:
        return 'Turn your head to the right';
      case ChallengeExpression.nodUp:
        return 'Look up';
      case ChallengeExpression.nodDown:
        return 'Look down';
      case ChallengeExpression.tiltLeft:
        return 'Tilt your head to the left';
      case ChallengeExpression.tiltRight:
        return 'Tilt your head to the right';
      case ChallengeExpression.openMouth:
        return 'Open your mouth wide';
      case ChallengeExpression.winkLeft:
        return 'Wink your left eye';
      case ChallengeExpression.winkRight:
        return 'Wink your right eye';
    }
  }

  String getInstructionIcon(ChallengeExpression action) {
    switch (action) {
      case ChallengeExpression.smile:
        return 'assets/icons/icon_face_liveness_smile.png';
      case ChallengeExpression.eyeblink:
        return 'assets/icons/icon_face_liveness_blink.png';
      case ChallengeExpression.leftPose:
        return 'assets/icons/icon_face_liveness_look_left.png';
      case ChallengeExpression.rightPose:
        return 'assets/icons/icon_face_liveness_look_right.png';
      case ChallengeExpression.nodUp:
        return 'assets/icons/icon_face_liveness_nod_up.png';
      case ChallengeExpression.nodDown:
        return 'assets/icons/icon_face_liveness_nod_down.png';
      case ChallengeExpression.tiltLeft:
        return 'assets/icons/icon_face_liveness_tilt_left.png';
      case ChallengeExpression.tiltRight:
        return 'assets/icons/icon_face_liveness_tilt_right.png';
      case ChallengeExpression.openMouth:
        return 'assets/icons/icon_face_liveness_open_mouth.png';
      case ChallengeExpression.winkLeft:
        return 'assets/icons/icon_face_liveness_wink_left.png';
      case ChallengeExpression.winkRight:
        return 'assets/icons/icon_face_liveness_wink_right.png';
    }
  }
}
