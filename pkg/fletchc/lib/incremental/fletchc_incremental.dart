// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fletchc_incremental;

import 'dart:async' show
    EventSink,
    Future;

import 'dart:developer' show
    UserTag;

import 'package:compiler/src/apiimpl.dart' show
    CompilerImpl;

import 'package:compiler/compiler_new.dart' show
    CompilerDiagnostics,
    CompilerInput,
    CompilerOutput,
    Diagnostic;

import 'package:compiler/src/elements/elements.dart' show
    ClassElement,
    ConstructorElement,
    Element,
    FunctionElement,
    LibraryElement;

import 'library_updater.dart' show
    IncrementalCompilerContext,
    LibraryUpdater,
    Logger;

import '../fletch_compiler.dart' show
    FletchCompiler;

import '../src/debug_info.dart' show
    DebugInfo;

import '../src/class_debug_info.dart' show
    ClassDebugInfo;

import '../src/fletch_selector.dart' show
    FletchSelector;

import '../src/fletch_compiler_implementation.dart' show
    FletchCompilerImplementation,
    OutputProvider;

import '../fletch_system.dart';

import '../src/fletch_backend.dart' show
    FletchBackend;

import 'package:sdk_library_metadata/libraries.dart' show
    Category;

import '../src/driver/exit_codes.dart' as exit_codes;

part 'caching_compiler.dart';

const List<String> INCREMENTAL_OPTIONS = const <String>[
    '--disable-type-inference',
    '--incremental-support',
    '--generate-code-with-compile-time-errors',
    '--no-source-maps', // TODO(ahe): Remove this.
];

enum IncrementalMode {
  /// Incremental compilation is turned off
  none,

  /// Incremental compilation is turned on for a limited set of features that
  /// are known to be fully implemented. Initially, this limited set of
  /// features will be instance methods without signature changes. As other
  /// features mature, they will be enabled in this mode.
  production,

  /// All incremental features are turned on even if we know that we don't
  /// always generate correct code. Initially, this covers features such as
  /// schema changes.
  experimental,
}

class IncrementalCompiler {
  final Uri libraryRoot;
  final Uri patchRoot;
  final Uri nativesJson;
  final Uri packageConfig;
  final Uri fletchVm;
  final CompilerInput inputProvider;
  final List<String> options;
  final CompilerOutput outputProvider;
  final Map<String, dynamic> environment;
  final IncrementalCompilerContext _context;
  final List<Category> categories;
  final IncrementalMode support;

  FletchCompilerImplementation _compiler;

  IncrementalCompiler(
      {this.libraryRoot,
       this.patchRoot,
       this.nativesJson,
       this.packageConfig,
       this.fletchVm,
       this.inputProvider,
       CompilerDiagnostics diagnosticHandler,
       this.options,
       this.outputProvider,
       this.environment,
       this.categories,
       this.support: IncrementalMode.none})
      : _context = new IncrementalCompilerContext(diagnosticHandler) {
    // if (libraryRoot == null) {
    //   throw new ArgumentError('libraryRoot is null.');
    // }
    if (inputProvider == null) {
      throw new ArgumentError('inputProvider is null.');
    }
    if (outputProvider == null) {
      throw new ArgumentError('outputProvider is null.');
    }
    if (diagnosticHandler == null) {
      throw new ArgumentError('diagnosticHandler is null.');
    }
    _context.incrementalCompiler = this;
  }

  bool get isProductionModeEnabled {
    return support == IncrementalMode.production ||
        support == IncrementalMode.experimental;
  }

  bool get isExperimentalModeEnabled {
    return support == IncrementalMode.experimental;
  }

  LibraryElement get mainApp => _compiler.mainApp;

  FletchCompilerImplementation get compiler => _compiler;

  /// Perform a full compile of [script]. This will reset the incremental
  /// compiler.
  ///
  /// Notice: a full compile means not incremental. The part of the program
  /// that is compiled is determined by tree shaking.
  Future<bool> compile(Uri script) {
    _compiler = null;
    return _reuseCompiler(null).then((CompilerImpl compiler) {
      _compiler = compiler;
      return compiler.run(script);
    });
  }

  /// Perform a full analysis of [script]. This will reset the incremental
  /// compiler.
  ///
  /// Notice: a full analysis is analogous to a full compile, that is, full
  /// analysis not incremental. The part of the program that is analyzed is
  /// determined by tree shaking.
  Future<int> analyze(Uri script) {
    _compiler = null;
    int initialErrorCount = _context.errorCount;
    int initialProblemCount = _context.problemCount;
    return _reuseCompiler(null, analyzeOnly: true).then(
        (CompilerImpl compiler) {
      // Don't try to reuse the compiler object.
      return compiler.run(script).then((_) {
        return _context.problemCount == initialProblemCount
            ? 0
            : _context.errorCount == initialErrorCount
                ? exit_codes.ANALYSIS_HAD_NON_ERROR_PROBLEMS
                : exit_codes.ANALYSIS_HAD_ERRORS;
      });
    });
  }

  Future<CompilerImpl> _reuseCompiler(
      Future<bool> reuseLibrary(LibraryElement library),
      {bool analyzeOnly: false}) {
    List<String> options = this.options == null
        ? <String> [] : new List<String>.from(this.options);
    options.addAll(INCREMENTAL_OPTIONS);
    if (analyzeOnly) {
      options.add("--analyze-only");
    }
    return reuseCompiler(
        cachedCompiler: _compiler,
        libraryRoot: libraryRoot,
        patchRoot: patchRoot,
        packageConfig: packageConfig,
        nativesJson: nativesJson,
        fletchVm: fletchVm,
        inputProvider: inputProvider,
        diagnosticHandler: _context,
        options: options,
        outputProvider: outputProvider,
        environment: environment,
        reuseLibrary: reuseLibrary,
        categories: categories);
  }

  void _checkCompilationFailed() {
    if (!isExperimentalModeEnabled && _compiler.compilationFailed) {
      throw new IncrementalCompilationFailed(
          "Unable to reuse compiler due to compile-time errors");
    }
  }

  /// Perform an incremental compilation of [updatedFiles]. [compile] must have
  /// been called once before calling this method.
  Future<FletchDelta> compileUpdates(
      FletchSystem currentSystem,
      Map<Uri, Uri> updatedFiles,
      {Logger logTime,
       Logger logVerbose}) {
    _checkCompilationFailed();
    if (logTime == null) {
      logTime = (_) {};
    }
    if (logVerbose == null) {
      logVerbose = (_) {};
    }
    Future mappingInputProvider(Uri uri) {
      Uri updatedFile = updatedFiles[uri];
      return inputProvider.readFromUri(updatedFile == null ? uri : updatedFile);
    }
    LibraryUpdater updater = new LibraryUpdater(
        _compiler,
        mappingInputProvider,
        logTime,
        logVerbose,
        _context);
    _context.registerUriWithUpdates(updatedFiles.keys);
    return _reuseCompiler(updater.reuseLibrary).then(
        (CompilerImpl compiler) async {
      _compiler = compiler;
      FletchDelta delta = await updater.computeUpdateFletch(currentSystem);
      _checkCompilationFailed();
      return delta;
    });
  }

  FletchDelta computeInitialDelta() {
    FletchBackend backend = _compiler.backend;
    return backend.computeDelta();
  }

  String lookupFunctionName(FletchFunction function) {
    if (function.isParameterStub) return "<parameter stub>";
    Element element = function.element;
    if (element == null) return function.name;
    if (element.isConstructor) {
      ConstructorElement constructor = element;
      ClassElement enclosing = constructor.enclosingClass;
      String name = (constructor.name == null || constructor.name.length == 0)
          ? ''
          : '.${constructor.name}';
      String postfix = function.isInitializerList ? ' initializer' : '';
      return '${enclosing.name}$name$postfix';
    }

    ClassElement enclosing = element.enclosingClass;
    if (enclosing == null) return function.name;
    return '${enclosing.name}.${function.name}';
  }

  ClassDebugInfo createClassDebugInfo(FletchClass klass) {
    return _compiler.context.backend.createClassDebugInfo(klass);
  }

  String lookupFunctionNameBySelector(int selector) {
    int id = FletchSelector.decodeId(selector);
    return _compiler.context.symbols[id];
  }

  DebugInfo createDebugInfo(
      FletchFunction function,
      FletchSystem currentSystem) {
    return _compiler.context.backend.createDebugInfo(function, currentSystem);
  }

  DebugInfo debugInfoForPosition(
      Uri file,
      int position,
      FletchSystem currentSystem) {
    return _compiler.debugInfoForPosition(file, position, currentSystem);
  }

  int positionInFileFromPattern(Uri file, int line, String pattern) {
    return _compiler.positionInFileFromPattern(file, line, pattern);
  }

  int positionInFile(Uri file, int line, int column) {
    return _compiler.positionInFile(file, line, column);
  }

  Iterable<Uri> findSourceFiles(Pattern pattern) {
    return _compiler.findSourceFiles(pattern);
  }
}

class IncrementalCompilationFailed {
  final String reason;

  const IncrementalCompilationFailed(this.reason);

  String toString() => "Can't incrementally compile program.\n\n$reason";
}

String unparseIncrementalMode(IncrementalMode mode) {
  switch (mode) {
    case IncrementalMode.none:
      return "none";

    case IncrementalMode.production:
      return "production";

    case IncrementalMode.experimental:
      return "experimental";
  }
  throw "Unhandled $mode";
}

IncrementalMode parseIncrementalMode(String text) {
  switch (text) {
    case "none":
      return IncrementalMode.none;

    case "production":
        return IncrementalMode.production;

    case "experimental":
      return IncrementalMode.experimental;

  }
  return null;
}
