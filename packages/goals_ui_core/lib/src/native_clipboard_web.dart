import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

import 'native_clipboard_stub.dart' hide nativeClipboardEventsAvailable;

export 'native_clipboard_stub.dart' show NativeClipboardData;

/// Browser clipboard events carry rich data while the event is trusted.
const nativeClipboardEventsAvailable = true;

@JS('navigator.clipboard')
external _AsyncClipboard? get _asyncClipboard;

extension type _AsyncClipboard(JSObject _) implements JSObject {
  external JSPromise<JSArray<_ClipboardItem>> read();
}

extension type _ClipboardItem(JSObject _) implements JSObject {
  external JSArray<JSString> get types;
  external JSPromise<_ClipboardBlob> getType(String type);
}

extension type _ClipboardBlob(JSObject _) implements JSObject {
  external JSPromise<JSString> text();
}

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
    _installOwnershipGuards();
    for (final MapEntry(key: type, value: listener) in _listeners.entries) {
      html.document.addEventListener(type, listener, true);
    }
  }

  // Each tear-off is a distinct closure, and dart:html wraps every distinct
  // closure in a new JavaScript function, so removeEventListener only
  // detaches the exact objects that were added. Hold them for dispose.
  late final Map<String, html.EventListener> _listeners = {
    'copy': _copy,
    'cut': _cut,
    'paste': _paste,
    'keydown': _keyDown,
  };

  final bool Function() isActive;
  final NativeClipboardData? Function() onCopy;
  final void Function() onCut;
  final void Function(NativeClipboardData) onPaste;
  bool _preferPlainText = false;
  bool _disposed = false;
  int _pasteSequence = 0;

  static const _envelopeAttribute = 'data-goals-clipboard-v1';

  // Standard HTML travels through the OS clipboard between independent pages.
  // Carry private representations in an inert attribute too: browsers do not
  // expose application/* formats through the asynchronous Clipboard API.
  static Map<String, String> _forNativeCopy(NativeClipboardData payload) {
    final representations = payload.representations;
    if (!representations.keys.any((type) => type.startsWith('application/'))) {
      return representations;
    }
    final envelope = base64Encode(utf8.encode(jsonEncode(representations)));
    final visibleHtml = representations['text/html'] ??
        const HtmlEscape().convert(representations['text/plain'] ?? '');
    return {
      ...representations,
      'text/html': '<span $_envelopeAttribute="$envelope"></span>$visibleHtml',
    };
  }

  static Map<String, String>? _fromNativeHtml(String? markup) {
    if (markup == null || !markup.contains(_envelopeAttribute)) return null;
    try {
      final document = html.DomParser().parseFromString(markup, 'text/html');
      final encoded = document
          .querySelector('[$_envelopeAttribute]')
          ?.getAttribute(_envelopeAttribute);
      if (encoded == null) return null;
      final decoded = jsonDecode(utf8.decode(base64Decode(encoded)));
      if (decoded is! Map ||
          decoded.entries
              .any((entry) => entry.key is! String || entry.value is! String)) {
        return null;
      }
      return Map<String, String>.from(decoded);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  // Chrome's trusted Cmd/Ctrl+Shift+V event intentionally exposes only
  // text/plain, even when the immediately preceding app copy published
  // private representations. Keep that app-owned copy in this page only and
  // restore it only for the matching plain-text special-paste event. The
  // native event values take precedence, so ordinary paste and external text
  // keep their browser-provided representations.
  //
  // Matching text alone does not prove the clipboard still holds the app
  // copy, so the retained copy is dropped whenever ownership may have
  // changed: on every copy/cut before any bridge handles it (an active bridge
  // then records its own payload), and on window blur or visibility changes,
  // where another tab or application may have written the clipboard.
  static NativeClipboardData? _lastAppCopy;
  static bool _ownershipGuardsInstalled = false;

  // Window capture listeners run before the document capture listeners each
  // bridge registers, so a copy that no active bridge handles leaves nothing
  // retained, and an inactive bridge never erases another bridge's copy.
  // They are page-wide and stay installed for the page's lifetime.
  static void _installOwnershipGuards() {
    if (_ownershipGuardsInstalled) return;
    _ownershipGuardsInstalled = true;
    void forget(html.Event _) => _lastAppCopy = null;
    html.window.addEventListener('copy', forget, true);
    html.window.addEventListener('cut', forget, true);
    html.window.addEventListener('blur', forget);
    html.document.addEventListener('visibilitychange', forget);
  }

  /// Cmd/Ctrl+Shift+V is the explicit plain-paste route. ClipboardEvent does
  /// not expose modifiers, so remember it only until the matching paste.
  void _keyDown(html.Event rawEvent) {
    if (!isActive()) {
      _preferPlainText = false;
      return;
    }
    final event = rawEvent as html.KeyboardEvent;
    _preferPlainText = event.shiftKey &&
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
    for (final entry in _forNativeCopy(payload).entries) {
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
    for (final entry in _forNativeCopy(payload).entries) {
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
    final restored = _specialPasteRepresentations(
      representations,
      preferPlainText: preferPlainText,
    );
    final sequence = ++_pasteSequence;
    if (preferPlainText &&
        event.isTrusted == true &&
        !restored.keys.any((type) => type.startsWith('application/'))) {
      _readSpecialPaste(representations, sequence);
      return;
    }
    onPaste(NativeClipboardData(
      representations: restored,
      preferPlainText: preferPlainText,
    ));
  }

  Future<void> _readSpecialPaste(
      Map<String, String> native, int sequence) async {
    var restored = native;
    try {
      // Read only in response to the user's trusted paste. This uses the
      // browser's normal clipboard permission/activation policy; denial keeps
      // the event's plain text. Never substitute a cross-window text cache.
      final clipboard = _asyncClipboard;
      if (clipboard != null) {
        final items = await clipboard.read().toDart;
        for (final item in items.toDart) {
          final types = item.types.toDart.map((type) => type.toDart);
          if (!types.contains('text/html') || !types.contains('text/plain')) {
            continue;
          }
          Future<String> read(String type) async {
            final blob = await item.getType(type).toDart;
            return (await blob.text().toDart).toDart;
          }

          final plain = await read('text/plain');
          if (plain != native['text/plain']) continue;
          final envelope = _fromNativeHtml(await read('text/html'));
          if (envelope == null || envelope['text/plain'] != plain) continue;
          restored = {...envelope, ...native};
          break;
        }
      }
    } catch (_) {
      // Unsupported/denied clipboard access is ordinary plain paste.
    }
    if (_disposed || sequence != _pasteSequence || !isActive()) return;
    onPaste(NativeClipboardData(
      representations: restored,
      preferPlainText: true,
    ));
  }

  static Map<String, String> _specialPasteRepresentations(
    Map<String, String> native, {
    required bool preferPlainText,
  }) {
    final envelope = _fromNativeHtml(native['text/html']);
    if (envelope != null && envelope['text/plain'] == native['text/plain']) {
      return {
        ...envelope,
        ...native,
        if (envelope.containsKey('text/html'))
          'text/html': envelope['text/html']!,
      };
    }
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
    _disposed = true;
    _pasteSequence++;
    for (final MapEntry(key: type, value: listener) in _listeners.entries) {
      html.document.removeEventListener(type, listener, true);
    }
  }
}
