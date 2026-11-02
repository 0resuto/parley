import 'package:flutter/material.dart';

import 'package:parley/data/models/unit.dart';

/// English chip label for a dictionary status.
String statusLabel(UnitStatus status) {
  return switch (status) {
    UnitStatus.newUnit => 'New',
    UnitStatus.learning => 'Learning',
    UnitStatus.young => 'Young',
    UnitStatus.mature => 'Mature',
    UnitStatus.known => 'Known',
  };
}

/// Accent color for a dictionary status.
Color statusColor(ColorScheme colors, UnitStatus status) {
  return switch (status) {
    UnitStatus.newUnit => colors.primary,
    UnitStatus.learning => colors.tertiary,
    UnitStatus.young => colors.secondary,
    UnitStatus.mature => colors.onSurfaceVariant,
    UnitStatus.known => colors.outline,
  };
}
