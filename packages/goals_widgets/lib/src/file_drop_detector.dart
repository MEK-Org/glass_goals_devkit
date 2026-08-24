import 'package:flutter/material.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:goals_ui_core/core.dart' show DragEventType, dragEventProvider;

/// A widget that wraps its child with file drop detection.
///
/// When a file is dragged over this widget, it will:
/// - Call onFileHover() when the file enters
/// - Call onFileLeave() when the file leaves
/// - Call onFileDrop() when the file is dropped with controller and event
///
/// This is designed to be wrapped around individual goal items or separators
/// to provide per-item file drop detection and highlighting.
class FileDropDetector extends StatefulWidget {
  final Widget child;
  final VoidCallback? onFileHover;
  final VoidCallback? onFileLeave;
  final Function(DropzoneViewController controller, dynamic event)? onFileDrop;

  const FileDropDetector({
    super.key,
    required this.child,
    this.onFileHover,
    this.onFileLeave,
    this.onFileDrop,
  });

  @override
  State<FileDropDetector> createState() => _FileDropDetectorState();
}

class _FileDropDetectorState extends State<FileDropDetector> {
  late DropzoneViewController _dropzoneController;
  bool _isHoveringWithFile = false;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) {
      return widget.child;
    }

    return IntrinsicHeight(
      child: Stack(
        children: [
          DropzoneView(
            onCreated: (controller) {
              _dropzoneController = controller;
            },
            onDropFiles: (List<DropzoneFileInterface>? files) async {
              if (_isHoveringWithFile) {
                setState(() {
                  _isHoveringWithFile = false;
                });
              }
              // Reset drag event on drop
              if (dragEventProvider.value == DragEventType.start) {
                dragEventProvider.add(DragEventType.end);
              }
              if (files != null && files.isNotEmpty) {
                widget.onFileDrop?.call(_dropzoneController, files);
              }
            },
            onHover: () {
              if (!_isHoveringWithFile) {
                setState(() {
                  _isHoveringWithFile = true;
                });
                // Set drag event to indicate file drag is in progress
                if (dragEventProvider.value != DragEventType.start) {
                  dragEventProvider.add(DragEventType.start);
                }
                widget.onFileHover?.call();
              }
            },
            onLeave: () {
              if (_isHoveringWithFile) {
                setState(() {
                  _isHoveringWithFile = false;
                });
                // Reset drag event when file leaves
                if (dragEventProvider.value == DragEventType.start) {
                  dragEventProvider.add(DragEventType.none);
                }
                widget.onFileLeave?.call();
              }
            },
          ),
          widget.child,
        ],
      ),
    );
  }
}
