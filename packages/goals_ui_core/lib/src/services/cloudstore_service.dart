import 'dart:typed_data' show ByteData, Uint8List;

import 'package:goals_core/model.dart' show GoalPath;

/// Optional cloud storage capabilities used by drop/upload interactions.
abstract class CloudstoreService {
  Future<void> saveData(
    String filename,
    ByteData data, {
    String? type,
    GoalPath? path,
    String? originalFilename,
  });

  Future<void> saveDataBytes(
    String filename,
    Uint8List data, {
    String? type,
    GoalPath? path,
    String? originalFilename,
  });

  Future<String> getDownloadUrl(String filename);
}
