import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class ImageProcessing {
  /// Converts the raw camera image into a platform-appropriate image format.
  ///
  /// On Android, the YUV420 format is converted into a standard image format.
  /// On iOS, the BGRA8888 format is handled with padding removal if needed.
  /// Throws an exception if the camera format is unsupported.
  img.Image toImgImage(CameraImage cameraImage) {
    if (Platform.isAndroid) {
      return _yuv420ToImage(cameraImage);
    }

    if (Platform.isIOS) {
      final plane = cameraImage.planes[0];
      final int width = cameraImage.width;
      final int height = cameraImage.height;
      final int bytesPerRow = plane.bytesPerRow;
      final Uint8List bytes = plane.bytes;

      // Check if row padding exists on iOS and remove if necessary
      final bool hasPadding = bytesPerRow != width * 4;

      if (!hasPadding) {
        final Uint8List cleanBytes = Uint8List.fromList(bytes);
        return img.Image.fromBytes(
          width: width,
          height: height,
          bytes: cleanBytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      }

      // Handle row padding by stripping it out
      final Uint8List cleanBytes = Uint8List(width * height * 4);
      int dstIdx = 0;
      for (int y = 0; y < height; y++) {
        final int rowStart = y * bytesPerRow;
        final int rowBytes = width * 4;
        cleanBytes.setRange(dstIdx, dstIdx + rowBytes, bytes, rowStart);
        dstIdx += rowBytes;
      }

      return img.Image.fromBytes(
        width: width,
        height: height,
        bytes: cleanBytes.buffer,
        order: img.ChannelOrder.bgra,
      );
    }

    throw Exception('Camera format not supported: ${cameraImage.format.group}');
  }

  /// Converts the YUV420 format from Android's camera image into an RGB image.
  ///
  /// For NV21 (single plane YUV format), this method extracts the Y, U, and V
  /// components and converts them into RGB pixels to create the final image.
  img.Image _yuv420ToImage(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;
    final image = img.Image(width: width, height: height);

    // Process Android NV21 format (single plane: Y + VU interleaved)
    if (cameraImage.planes.length == 1) {
      final bytes = cameraImage.planes[0].bytes;
      final int uvOffset = width * height;

      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int yVal = bytes[y * width + x];
          final int uvIdx = uvOffset + (y ~/ 2) * width + (x & ~1);
          final int vVal = bytes[uvIdx] - 128;
          final int uVal = bytes[uvIdx + 1] - 128;

          final int r = (yVal + 1.402 * vVal).clamp(0, 255).toInt();
          final int g = (yVal - 0.344136 * uVal - 0.714136 * vVal)
              .clamp(0, 255)
              .toInt();
          final int b = (yVal + 1.772 * uVal).clamp(0, 255).toInt();

          image.setPixelRgb(x, y, r, g, b);
        }
      }
      return image;
    }

    // Process YUV420 format with separate Y, U, and V planes
    final yPlane = cameraImage.planes[0];
    final uPlane = cameraImage.planes[1];
    final vPlane = cameraImage.planes[2];

    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uvRowStride = uPlane.bytesPerRow;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIdx = y * yPlane.bytesPerRow + x;
        final int uvRow = y ~/ 2;
        final int uvCol = x ~/ 2;
        final int uvIdx = uvRow * uvRowStride + uvCol * uvPixelStride;

        final int yVal = yPlane.bytes[yIdx];
        final int uVal = uPlane.bytes[uvIdx] - 128;
        final int vVal = vPlane.bytes[uvIdx] - 128;

        final int r = (yVal + 1.402 * vVal).clamp(0, 255).toInt();
        final int g = (yVal - 0.344136 * uVal - 0.714136 * vVal)
            .clamp(0, 255)
            .toInt();
        final int b = (yVal + 1.772 * uVal).clamp(0, 255).toInt();

        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return image;
  }

  /// Returns the rotation of the camera for iOS and Android devices.
  ///
  /// On iOS, the rotation is always 0 degrees (portrait). For Android, the
  /// sensor orientation is used to determine the correct rotation (90, 180, or 270 degrees).
  InputImageRotation getRotation(CameraController cameraController) {
    if (Platform.isIOS) return InputImageRotation.rotation0deg;

    final sensorOrientation = cameraController.description.sensorOrientation;
    switch (sensorOrientation) {
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  /// Returns the image rotation for cropping, which may differ from the ML Kit rotation.
  ///
  /// This is necessary because the front camera sensor on iOS is oriented at 270 degrees
  /// but the image itself is already in portrait. The rotation is adjusted accordingly.
  InputImageRotation getImageRotationForCrop(
    CameraController cameraController,
  ) {
    if (Platform.isIOS) return InputImageRotation.rotation0deg;

    return getRotation(cameraController);
  }

  /// Detects faces in the camera image, applies rotation, and crops the face region.
  ///
  /// This method takes into account platform-specific rotations, especially for iOS,
  /// where the front camera needs additional rotation adjustments. It selects the largest
  /// face in the frame and returns the cropped face image.
  Future<img.Image?> detectAndCrop(
    CameraImage cameraImage,
    InputImageRotation rotation,
    FaceDetector detector, {
    CameraController? cameraController,
  }) async {
    final inputImage = buildInputImage(cameraImage, rotation);
    final faces = await detector.processImage(inputImage);
    if (faces.isEmpty) return null;

    img.Image fullImage = toImgImage(cameraImage);

    final cropRotation = cameraController != null
        ? getImageRotationForCrop(cameraController)
        : rotation;

    if (Platform.isIOS) {
      fullImage = img.flipHorizontal(fullImage);
    } else {
      fullImage = _applyRotation(fullImage, cropRotation);
    }

    final Face bestFace = faces.reduce(
      (a, b) => a.boundingBox.width > b.boundingBox.width ? a : b,
    );
    final box = bestFace.boundingBox;

    double left;
    final double top = box.top;
    final double faceWidth = box.width;
    final double faceHeight = box.height;

    if (Platform.isIOS) {
      left = fullImage.width - box.right;
    } else {
      left = box.left;
    }

    const double paddingFactor = 0.0;
    final double padX = faceWidth * paddingFactor;
    final double padY = faceHeight * paddingFactor;

    final x = (left - padX).clamp(0, fullImage.width - 1).toInt();
    final y = (top - padY).clamp(0, fullImage.height - 1).toInt();
    final w = (faceWidth + padX * 2).clamp(1, fullImage.width - x).toInt();
    final h = (faceHeight + padY * 2).clamp(1, fullImage.height - y).toInt();

    img.Image cropped = img.copyCrop(
      fullImage,
      x: x,
      y: y,
      width: w,
      height: h,
    );

    final int size = cropped.width < cropped.height
        ? cropped.width
        : cropped.height;
    final int offsetX = (cropped.width - size) ~/ 2;
    final int offsetY = (cropped.height - size) ~/ 2;
    cropped = img.copyCrop(
      cropped,
      x: offsetX,
      y: offsetY,
      width: size,
      height: size,
    );

    if (Platform.isIOS) {
      return _applyRotation(cropped, cropRotation);
    }

    return cropped;
  }

  /// Builds a platform-specific InputImage from a raw CameraImage.
  ///
  /// For Android, the YUV420 format is converted to NV21 format. For iOS, the BGRA8888 format
  /// is used. This method constructs an InputImage to be processed by ML Kit.
  InputImage buildInputImage(
    CameraImage cameraImage,
    InputImageRotation rotation,
  ) {
    try {
      if (Platform.isAndroid) {
        final nv21Bytes = _convertToNV21(cameraImage);
        final metadata = InputImageMetadata(
          size: Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: cameraImage.width,
        );
        return InputImage.fromBytes(bytes: nv21Bytes, metadata: metadata);
      }

      final metadata = InputImageMetadata(
        size: Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.bgra8888,
        bytesPerRow: cameraImage.planes[0].bytesPerRow,
      );
      return InputImage.fromBytes(
        bytes: cameraImage.planes[0].bytes,
        metadata: metadata,
      );
    } catch (e) {
      throw Exception('Failed to build InputImage: $e');
    }
  }

  /// Converts the camera image from NV21 format to a raw byte array in NV21 format.
  ///
  /// This method handles both single-plane and multi-plane YUV formats used by Android devices.
  Uint8List _convertToNV21(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    if (cameraImage.planes.length == 1) {
      return cameraImage.planes[0].bytes;
    }

    final yPlane = cameraImage.planes[0];
    final uPlane = cameraImage.planes[1];
    final vPlane = cameraImage.planes[2];

    final nv21 = Uint8List(width * height + (width * height ~/ 2));
    int nv21Idx = 0;

    for (int row = 0; row < height; row++) {
      final int rowStart = row * yPlane.bytesPerRow;
      nv21.setRange(nv21Idx, nv21Idx + width, yPlane.bytes, rowStart);
      nv21Idx += width;
    }

    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final int uvHeight = height ~/ 2;
    final int uvWidth = width ~/ 2;
    for (int row = 0; row < uvHeight; row++) {
      for (int col = 0; col < uvWidth; col++) {
        final int uvIdx = row * uPlane.bytesPerRow + col * uvPixelStride;
        nv21[nv21Idx++] = vPlane.bytes[uvIdx];
        nv21[nv21Idx++] = uPlane.bytes[uvIdx];
      }
    }

    return nv21;
  }

  /// Computes the average luminance of a camera frame.
  ///
  /// For iOS, it samples the green channel of the BGRA8888 format.
  /// For Android, it samples the Y plane of the NV21 format.
  double computeAverageLuminance(CameraImage image) {
    if (image.planes.isEmpty) return 255.0;

    final bool isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final Uint8List bytes = image.planes[0].bytes;
    int total = 0;
    int count = 0;

    if (isIOS) {
      for (int i = 1; i < bytes.length; i += 40) {
        total += bytes[i];
        count++;
      }
    } else {
      for (int i = 0; i < bytes.length; i += 10) {
        total += bytes[i];
        count++;
      }
    }

    return count > 0 ? total / count : 255.0;
  }

  /// Applies the appropriate rotation to the image based on the given rotation value.
  ///
  /// This ensures the image is correctly oriented for further processing.
  img.Image _applyRotation(img.Image image, InputImageRotation rotation) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return img.copyRotate(image, angle: 90);
      case InputImageRotation.rotation180deg:
        return img.copyRotate(image, angle: 180);
      case InputImageRotation.rotation270deg:
        return img.copyRotate(image, angle: 270);
      case InputImageRotation.rotation0deg:
        return image;
    }
  }
}
