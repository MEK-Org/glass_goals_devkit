import 'dart:html' as html;

import 'native_clipboard_stub.dart' hide nativeClipboardEventsAvailable;

export 'native_clipboard_stub.dart' show NativeClipboardData;

/// Browser clipboard events carry rich data while the event is trusted.
const nativeClipboardEventsAvailable = true;

/// Bridges trusted browser clipboard events to the focused consumer.
///
/// Representation names belong to callers, allowing one shared event bridge
/// to carry application-private, HTML, and plain-text payloads together.
class NativeClipboardBridge {
  NativeClipboardBridge({
    required this.isActive,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
  }) {
    html.document.addEventListener('copy', _copy, true);
    html.document.addEventListener('cut', _cut, true);
    html.document.addEventListener('paste', _paste, true);
    html.document.addEventListener('keydown', _keyDown, true);
  }

  final bool Function() isActive;
  final NativeClipboardData? Function() onCopy;
  final void Function() onCut;
  final void Function(NativeClipboardData) onPaste;
  bool _preferPlainText = false;

  // Chrome's trusted Cmd/Ctrl+Shift+V event intentionally exposes only
  // text/plain, even when the immediately preceding app copy published
  // private representations. Keep that app-owned copy in this page only and
  // restore it only for the matching plain-text special-paste event. The
  // native event values take precedence, so ordinary paste and external text
  // keep their browser-provided representations.
  static NativeClipboardData? _lastAppCopy;

  /// Cmd/Ctrl+Shift+V is the explicit plain-paste route. ClipboardEvent does
  /// not expose modifiers, so remember it only until the matching paste.
  void _keyDown(html.Event rawEvent) {
    if (!isActive()) {
      _preferPlainText = false;
      return;
    }
    final event = rawEvent as html.KeyboardEvent;
    _preferPlainText =
        event.shiftKey &&
        (event.ctrlKey || event.metaKey) &&
        event.key?.toLowerCase() == 'v';
  }

  void _write(html.Event rawEvent) {
    final event = rawEvent as html.ClipboardEvent;
    if (!isActive()) return;
    final payload = onCopy();
    final clipboard = event.clipboardData;
    if (payload == null || clipboard == null) {
      _lastAppCopy = null;
      return;
    }
    for (final entry in payload.representations.entries) {
      clipboard.setData(entry.key, entry.value);
    }
    _lastAppCopy = payload;
    event.preventDefault();
  }

  void _copy(html.Event event) => _write(event);

  void _cut(html.Event rawEvent) {
    final event = rawEvent as html.ClipboardEvent;
    if (!isActive()) return;
    final payload = onCopy();
    final clipboard = event.clipboardData;
    if (payload == null || clipboard == null) {
      _lastAppCopy = null;
      return;
    }
    for (final entry in payload.representations.entries) {
      clipboard.setData(entry.key, entry.value);
    }
    _lastAppCopy = payload;
    event.preventDefault();
    onCut();
  }

  void _paste(html.Event rawEvent) {
    final event = rawEvent as html.ClipboardEvent;
    if (!isActive()) return;
    final clipboard = event.clipboardData;
    if (clipboard == null) return;
    final preferPlainText = _preferPlainText;
    _preferPlainText = false;
    event.preventDefault();
    final representations = {
      for (final type in clipboard.types ?? const <String>[])
        type: clipboard.getData(type),
    };
    onPaste(NativeClipboardData(
      representations: _specialPasteRepresentations(
        representations,
        preferPlainText: preferPlainText,
      ),
      preferPlainText: preferPlainText,
    ));
  }

  static Map<String, String> _specialPasteRepresentations(
    Map<String, String> native, {
    required bool preferPlainText,
  }) {
    if (!preferPlainText) return native;
    final retained = _lastAppCopy;
    final plainText = native['text/plain'];
    if (retained == null ||
        plainText == null ||
        plainText != retained.read('text/plain')) {
      return native;
    }
    return {...retained.representations, ...native};
  }

  void dispose() {
    html.document.removeEventListener('copy', _copy, true);
    html.document.removeEventListener('cut', _cut, true);
    html.document.removeEventListener('paste', _paste, true);
    html.document.removeEventListener('keydown', _keyDown, true);
  }
}
