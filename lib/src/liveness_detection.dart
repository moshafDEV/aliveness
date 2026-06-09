import './models/face_liveness_data.dart';
import 'package:flutter/material.dart';

import 'detection/liveness_detection.dart';
import 'expression/expression.dart';

/// Highest-level facade class used by external modules or UI screens.
///
/// This class exposes a simple `start()` method for developers to
/// initiate liveness detection without needing to understand
/// internal processing layers.
class Aliveness extends LivenessDetection {
  /// Start the liveness detection sequence.
  ///
  /// Internally calls the [processing] method provided by
  /// [LivenessDetection].
  Future<FaceLivenessData?> start({
    required BuildContext context,
    required List<ChallengeExpression> expressions,
  }) {
    return processing(context: context, expressions: expressions);
  }
}
