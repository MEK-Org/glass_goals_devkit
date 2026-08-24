import 'dart:io';

import 'package:flutter/foundation.dart';

bool isMacOS() {
  if (kIsWeb) {
    return defaultTargetPlatform == TargetPlatform.macOS;
  }
  return Platform.isMacOS;
}

String getEnvironment() {
  switch (Uri.base.host) {
    case 'localhost':
      return 'local';
    case 'glassgoals.com':
      return 'prod';
    case 'staging-glassgoals.web.app':
      return 'staging';
    default:
      return 'unknown';
  }
}
