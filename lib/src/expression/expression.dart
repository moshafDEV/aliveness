/// Represents different facial expressions or detected face actions.
enum ChallengeExpression {
  /// Represents a quick eye blink (either eye).
  eyeblink,

  /// Represents a smiling expression.
  smile,

  /// Represents the face turned to the left (yaw).
  leftPose,

  /// Represents the face turned to the right (yaw).
  rightPose,

  /// Represents the head tilted upward (pitch up).
  nodUp,

  /// Represents the head tilted downward (pitch down).
  nodDown,

  /// Represents the head rolled to the left (roll).
  tiltLeft,

  /// Represents the head rolled to the right (roll).
  tiltRight,

  /// Represents an open mouth.
  openMouth,

  /// Represents a wink with the left eye only.
  winkLeft,

  /// Represents a wink with the right eye only.
  winkRight,
}
