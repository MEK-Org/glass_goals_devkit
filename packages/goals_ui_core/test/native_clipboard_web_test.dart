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
}
