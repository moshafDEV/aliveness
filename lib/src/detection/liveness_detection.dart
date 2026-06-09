import 'package:flutter/material.dart';

import '../../aliveness.dart';
import 'detection.dart';

/// Provides a clean public interface to trigger the
/// liveness detection process from UI layers.
///
/// This class acts as an intermediate handler between UI
/// and the core [Detection] logic.
class LivenessDetection extends Detection {
  /// Starts the liveness detection workflow.
  ///
  /// Calls the base class's [initializeDetection] and returns
  /// the detection result.
  Future<FaceLivenessData?> processing({
    required BuildContext context,
    required List<ChallengeExpression> expressions,
  }) {
    return initializeDetection(context: context, expressions: expressions);
  }
}
