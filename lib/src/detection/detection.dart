import '../models/face_liveness_data.dart';
import 'package:flutter/material.dart';

import '../expression/expression.dart';
import 'face_liveness_processing.dart';

/// Base class responsible for handling the common
/// facial liveness detection initialization flow.
abstract class Detection {
  /// Initializes the detection process.
  ///
  /// Validates the provided [expressions], and then navigates to
  /// the [FaceLivenessProcessing] screen which performs the
  /// actual liveness detection.
  ///
  /// Returns:
  /// - A list of [XFile]s containing the captured selfies if detection succeeds.
  /// - `null` if user cancels or detection fails.
  Future<FaceLivenessData?> initializeDetection({
    required BuildContext context,
    required List<ChallengeExpression> expressions,
  }) async {
    // Validate required expressions list
    if (expressions.isEmpty) {
      const errorMessage =
          "Invalid expression list: At least 1 expression is required.";

      debugPrint("❗ $errorMessage");
      throw Exception(errorMessage);
    }

    debugPrint(
      "🔍 Starting liveness detection with "
      "${expressions.length} expression(s)...",
    );

    return await Navigator.of(context).push<FaceLivenessData?>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => FaceLivenessProcessing(expression: expressions),
      ),
    );

    // Navigate to detection flow
    // return await Navigator.push(
    //   context,
    //   MaterialPageRoute(
    //     builder: (_) => FaceLivenessProcessing(expression: expressions),
    //   ),
    // );
  }
}
