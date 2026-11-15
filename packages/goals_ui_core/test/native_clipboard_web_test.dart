// ignore_for_file: deprecated_member_use, uri_does_not_exist

@TestOn('browser')
library;

import 'dart:html' as html;
import 'dart:js_util' as js_util;

import 'package:flutter_test/flutter_test.dart';
import 'package:goals_ui_core/core.dart';

html.KeyboardEvent _specialPasteKeyDown() =>
    js_util.callConstructor<html.KeyboardEvent>(
      js_util.getProperty(html.window, 'KeyboardEvent'),
      [
        'keydown',
        js_util.jsify({
          'key': 'v',
          'code': 'KeyV',
          'ctrlKey': true,
          'shiftKey': true,
          'bubbles': true,
        }),
      ],
    );

const _appCopy = NativeClipboardData(representations: {
  'application/x-example-private': 'source-record',
  'text/plain': 'source',
});

void _dispatchCopy(html.EventTarget target) {
  target.dispatchEvent(html.ClipboardEvent('copy', {
    'clipboardData': html.DataTransfer(),
    'bubbles': true,
    'cancelable': true,
  }));
}

void _dispatchSpecialPaste(String plainText) {
  html.document.dispatchEvent(_specialPasteKeyDown());
  html.document.dispatchEvent(html.ClipboardEvent('paste', {
    'clipboardData': html.DataTransfer()..setData('text/plain', plainText),
    'bubbles': true,
    'cancelable': true,
  }));
}

void main() {
  test('restores app copy representations for stripped special paste only',
      () {
    NativeClipboardData? received;
    final bridge = NativeClipboardBridge(
      isActive: () => true,
      onCopy: () => const NativeClipboardData(representations: {
        'application/x-example-private': 'source-record',
        'text/html': '<strong>source</strong>',
        'text/plain': 'source',
      }),
      onCut: () {},
      onPaste: (data) => received = data,
    );
    addTearDown(bridge.dispose);

    final copyData = html.DataTransfer();
    html.document.dispatchEvent(html.ClipboardEvent('copy', {
      'clipboardData': copyData,
      'bubbles': true,
      'cancelable': true,
    }));

    html.document.dispatchEvent(_specialPasteKeyDown());
    final stripped = html.DataTransfer()..setData('text/plain', 'source');
    html.document.dispatchEvent(html.ClipboardEvent('paste', {
      'clipboardData': stripped,
      'bubbles': true,
      'cancelable': true,
    }));
    expect(received?.preferPlainText, isTrue);
    expect(received?.read('application/x-example-private'), 'source-record');
    expect(received?.read('text/plain'), 'source');

    html.document.dispatchEvent(_specialPasteKeyDown());
    final external = html.DataTransfer()..setData('text/plain', 'external');
    html.document.dispatchEvent(html.ClipboardEvent('paste', {
      'clipboardData': external,
      'bubbles': true,
      'cancelable': true,
    }));
    expect(received?.read('application/x-example-private'), isEmpty);
    expect(received?.read('text/plain'), 'external');

    final ordinary = html.DataTransfer()
      ..setData('application/x-example-private', 'ordinary-private')
      ..setData('text/plain', 'source');
    html.document.dispatchEvent(html.ClipboardEvent('paste', {
      'clipboardData': ordinary,
      'bubbles': true,
      'cancelable': true,
    }));
    expect(received?.preferPlainText, isFalse);
    expect(received?.read('application/x-example-private'), 'ordinary-private');
  });

  test('a disposed bridge stops handling clipboard events', () {
    var consulted = 0;
    NativeClipboardBridge(
      isActive: () {
        consulted++;
        return true;
      },
      onCopy: () => _appCopy,
      onCut: () {},
      onPaste: (_) => fail('disposed bridge must not receive paste'),
    ).dispose();

    _dispatchCopy(html.document);
    _dispatchSpecialPaste('source');

    expect(consulted, 0);
  });

  test('a copy handled outside the active bridge invalidates provenance '
      'even when its text is identical', () {
    var active = true;
    NativeClipboardData? received;
    final bridge = NativeClipboardBridge(
      isActive: () => active,
      onCopy: () => _appCopy,
      onCut: () {},
      onPaste: (data) => received = data,
    );
    addTearDown(bridge.dispose);
    final external = html.TextAreaElement()..value = 'source';
    html.document.body!.append(external);
    addTearDown(external.remove);

    _dispatchCopy(html.document);
    active = false;
    _dispatchCopy(external);
    active = true;
    _dispatchSpecialPaste('source');

    expect(received?.preferPlainText, isTrue);
    expect(received?.read('application/x-example-private'), isEmpty);
    expect(received?.read('text/plain'), 'source');
  });

  test('an inactive bridge instance does not erase the active app copy', () {
    NativeClipboardData? received;
    final source = NativeClipboardBridge(
      isActive: () => true,
      onCopy: () => _appCopy,
      onCut: () {},
      onPaste: (data) => received = data,
    );
    addTearDown(source.dispose);
    final inactive = NativeClipboardBridge(
      isActive: () => false,
      onCopy: () => null,
      onCut: () {},
      onPaste: (_) => fail('inactive bridge must not receive paste'),
    );
    addTearDown(inactive.dispose);

    _dispatchCopy(html.document);
    _dispatchSpecialPaste('source');

    expect(received?.read('application/x-example-private'), 'source-record');
  });

  for (final transition in ['blur', 'visibilitychange']) {
    test('a $transition transition invalidates provenance', () {
      NativeClipboardData? received;
      final bridge = NativeClipboardBridge(
        isActive: () => true,
        onCopy: () => _appCopy,
        onCut: () {},
        onPaste: (data) => received = data,
      );
      addTearDown(bridge.dispose);

      _dispatchCopy(html.document);
      final target =
          transition == 'blur' ? html.window as html.EventTarget : html.document;
      target.dispatchEvent(html.Event(transition));
      _dispatchSpecialPaste('source');

      expect(received?.read('application/x-example-private'), isEmpty);
      expect(received?.read('text/plain'), 'source');
    });
  }
}
