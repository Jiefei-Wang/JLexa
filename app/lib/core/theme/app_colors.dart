import 'package:flutter/material.dart';

class AppColors {
  // Primary brand
  static const Color primary = Color(0xFF2563EB); // Vibrant Blue
  static const Color primaryDark = Color(0xFF1D4ED8);
  static const Color primaryLight = Color(0xFFEFF6FF);
  static const Color primaryGradientStart = Color(0xFF2563EB);
  static const Color primaryGradientEnd = Color(0xFF3B82F6);

  // Secondary brand / Accent
  static const Color secondary = Color(0xFF0D9488); // Teal
  static const Color secondaryLight = Color(0xFFF0FDFA);
  static const Color accentPurple = Color(0xFF8B5CF6);
  static const Color accentPurpleLight = Color(0xFFF5F3FF);

  // Status & Confidence
  static const Color success = Color(0xFF10B981); // High confidence / ready
  static const Color successLight = Color(0xFFECFDF5);
  static const Color warning = Color(
    0xFFF59E0B,
  ); // Medium confidence / attention
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color error = Color(0xFFEF4444); // Low confidence / error
  static const Color errorLight = Color(0xFFFEF2F2);

  // Background & Surfaces
  static const Color background = Color(0xFFF8FAFC);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceElevated = Color(0xFFFFFFFF);
  static const Color card = Color(0xFFFFFFFF);

  // Text
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color textTertiary = Color(0xFF94A3B8);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Borders & Dividers
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderLight = Color(0xFFF1F5F9);
  static const Color divider = Color(0xFFE2E8F0);

  // Audio & Waveform
  static const Color waveformSpeech = Color(0xFF3B82F6);
  static const Color waveformSilence = Color(0xFFCBD5E1);
  static const Color playhead = Color(0xFFEF4444);
  static const Color segmentHighlight = Color(0x333B82F6);
  static const Color segmentBorder = Color(0xFF2563EB);
  static const Color scrubberTrack = Color(0xFFE2E8F0);
  static const Color scrubberProgress = Color(0xFF2563EB);
}
