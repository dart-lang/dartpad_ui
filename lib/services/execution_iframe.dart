// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library execution_iframe;

import 'dart:async';
import 'dart:html';
import 'dart:js';

import 'execution.dart';

export 'execution.dart';

class ExecutionServiceIFrame implements ExecutionService {
  static const testKey = '__TESTRESULT__ ';

  final StreamController<String> _stdoutController =
      StreamController<String>.broadcast();
  final StreamController<String> _stderrController =
      StreamController<String>.broadcast();
  final StreamController<TestResult> _testResultsController =
      StreamController<TestResult>.broadcast();

  IFrameElement _frame;
  String _frameSrc;
  Completer _readyCompleter = Completer();

  ExecutionServiceIFrame(this._frame) {
    _frameSrc = _frame.src;

    _initListener();
  }

  IFrameElement get frame => _frame;

  @override
  Future execute(
    String html,
    String css,
    String javaScript, {
    String modulesBaseUrl,
  }) {
    return _send('execute', {
      'html': html,
      'css': css,
      'js': _decorateJavaScript(javaScript, modulesBaseUrl: modulesBaseUrl),
    });
  }

  @override
  Future tearDown() => _reset();

  @override
  void replaceHtml(String html) {
    _send('setHtml', {'html': html});
  }

  @override
  void replaceCss(String css) {
    _send('setCss', {'css': css});
  }

  set frameSrc(String src) {
    frame.src = src;
    _frameSrc = src;
  }

  /// TODO(redbrogdon): Format message so internal double quotes are escaped.
  @override
  String get testResultDecoration => '''
void _result(bool success, [List<String> messages]) {
  // Join messages into a comma-separated list for inclusion in the JSON array.
  final joinedMessages = messages?.map((m) => '"\$m"')?.join(',') ?? '';

  print('$testKey{"success": \$success, "messages": [\$joinedMessages]}');
}

// Ensure we have at least one use of `_result`.
var resultFunction = _result;
''';

  String _decorateJavaScript(String javaScript, {String modulesBaseUrl}) {
    final postMessagePrint = '''
var testKey = '$testKey';

function dartPrint(message) {
  if (message.startsWith(testKey)) {
    var resultMsg = JSON.parse(message.substring(testKey.length));
    resultMsg.sender = 'frame';
    resultMsg.type = 'testResult';
    parent.postMessage(resultMsg, '*');
  } else {
    parent.postMessage(
      {'sender': 'frame', 'type': 'stdout', 'message': message.toString()}, '*');
  }
}
// Unload previous version.
require.undef('dartpad_main');
''';

    /// The javascript exception handling for Dartpad catches both errors
    /// directly raised by main() (in which case we might have useful Dart
    /// exception information we don't want to discard), as well as errors
    /// generated by other means, like assertion errors when starting up
    /// asynchronous functions.
    ///
    /// To avoid duplicating error messages on the DartPad console, we signal to
    /// window.onerror that we've already sent a dartMainRunner message by
    /// flipping _thrownDartMainRunner to true.  Some platforms don't populate
    /// error so avoid using it if it is null.
    ///
    /// This seems to produce both the stack traces we expect in inspector
    /// and the right error messages on the console.
    final exceptionHandler = '''
var _thrownDartMainRunner = false;

window.onerror = function(message, url, lineNumber, colno, error) {
  if (!_thrownDartMainRunner) {
    var errorMessage = '';
    if (error != null) {
      errorMessage = 'Error: ' + error;
    } 
    parent.postMessage(
      {'sender': 'frame', 'type': 'stderr', 'message': message + errorMessage}, '*');
  }
  _thrownDartMainRunner = false;
};
''';

    var requireConfig = '';
    if (modulesBaseUrl != null) {
      requireConfig = '''
require.config({
  "baseUrl": "$modulesBaseUrl",
  "waitSeconds": 60
});
''';
    }

    final usesRequireJs = modulesBaseUrl != null;

    var postfix = '';
    if (usesRequireJs) {
      postfix = '''
require(['dart_sdk'],
  function(sdk) {
    'use strict';
    sdk.developer._extensions.clear();
    sdk.dart.hotRestart();
});

require(["dartpad_main", "dart_sdk"], function(dartpad_main, dart_sdk) {
    // SDK initialization.
    dart_sdk.dart.setStartAsyncSynchronously(true);
    dart_sdk._isolate_helper.startRootIsolate(() => {}, []);

    // Loads the `dartpad_main` module and runs its bootstrapped main method.
    //
    // DDK provides the user's code in a RequireJS module, which exports an
    // object that looks something like this:
    //
    // {
    //       [random_tokens]__bootstrap: bootstrap,
    //       [random_tokens]__main: main
    // }
    //
    // The first of those properties holds the compiled code for the bootstrap
    // Dart file, which the server uses to wrap the user's code and wait on a
    // call to dart:ui's `webOnlyInitializePlatform` before executing any of it.
    //
    // The loop below iterates over the properties of the exported object,
    // looking for one that ends in "__bootstrap". Once found, it executes the
    // bootstrapped main method, which calls the user's main method, which
    // (presumably) calls runApp and starts Flutter's rendering.

    // TODO: simplify this once we are firmly in a post Flutter 1.24 world.
    for (var prop in dartpad_main) {
          if (prop.endsWith("bootstrap")) {
            dartpad_main[prop].main();
          }
    }});
''';
    }

    return '$postMessagePrint\n$exceptionHandler\n$requireConfig\n'
            '$javaScript\n$postfix'
        .trim();
  }

  @override
  Stream<String> get onStdout => _stdoutController.stream;

  @override
  Stream<String> get onStderr => _stderrController.stream;

  @override
  Stream<TestResult> get testResults => _testResultsController.stream;

  Future _send(String command, Map<String, String> params) {
    var m = {'command': command};
    m.addAll(params);
    frame.contentWindow.postMessage(m, '*');
    return Future.value();
  }

  /// Destroy and re-load the iframe.
  Future _reset() {
    if (frame.parent != null) {
      _readyCompleter = Completer();

      var clone = _frame.clone(false) as IFrameElement;
      clone.src = _frameSrc;

      var children = frame.parent.children;
      var index = children.indexOf(_frame);
      children.insert(index, clone);
      frame.parent.children.remove(_frame);
      _frame = clone;
    }

    return _readyCompleter.future.timeout(Duration(seconds: 1), onTimeout: () {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    });
  }

  void _initListener() {
    context['dartMessageListener'] = JsFunction.withThis((_this, data) {
      var type = data['type'] as String;

      if (type == 'testResult') {
        final result = TestResult(data['success'] as bool,
            List<String>.from(data['messages'] as Iterable ?? []));
        _testResultsController.add(result);
      } else if (type == 'stderr') {
        // Ignore any exceptions before the iframe has completed initialization.
        if (_readyCompleter.isCompleted) {
          _stderrController.add(data['message'] as String);
        }
      } else if (type == 'ready' && !_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      } else {
        _stdoutController.add(data['message'] as String);
      }
    });
  }
}
