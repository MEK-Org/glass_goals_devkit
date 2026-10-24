/// A collection of clipboard representations received in one native event.
///
/// The transport intentionally knows neither application MIME names nor any
/// document format. Consumers choose their own representations and preference
/// order with [read].
class NativeClipboardData {
  const NativeClipboardData({
    this.representations = const {},
    this.preferPlainText = false,
  });

  final Map<String, String> representations;
  final bool preferPlainText;

  String read(String mimeType) => representations[mimeType] ?? '';
}

/// Whether trusted browser clipboard events are available for this target.
const nativeClipboardEventsAvailable = false;

/// No-op on non-browser targets. Flutter's platform clipboard remains intact.
class NativeClipboardBridge {
  NativeClipboardBridge({
    required bool Function() isActive,
    required NativeClipboardData? Function() onCopy,
    required void Function() onCut,
    required void Function(NativeClipboardData) onPaste,
  });

  void dispose() {}
}
