// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library fletchc.fletch_backend;

import 'dart:async' show
    Future;

import 'package:compiler/src/dart2jslib.dart' show
    Backend,
    BackendConstantEnvironment,
    CodegenRegistry,
    CodegenWorkItem,
    Compiler,
    CompilerTask,
    ConstantCompilerTask,
    Enqueuer,
    MessageKind,
    Registry,
    ResolutionEnqueuer,
    isPrivateName;

import 'package:compiler/src/tree/tree.dart' show
    DartString,
    EmptyStatement,
    Expression;

import 'package:compiler/src/elements/elements.dart' show
    AstElement,
    AbstractFieldElement,
    ClassElement,
    ConstructorElement,
    Element,
    ExecutableElement,
    FieldElement,
    FormalElement,
    FunctionElement,
    FunctionSignature,
    FunctionTypedElement,
    LibraryElement,
    MemberElement;

import 'package:compiler/src/elements/modelx.dart' show
    LibraryElementX;

import 'package:compiler/src/dart_types.dart' show
    DartType,
    InterfaceType;

import 'package:compiler/src/universe/universe.dart'
    show Selector;

import 'package:compiler/src/util/util.dart'
    show Spannable;

import 'package:compiler/src/elements/modelx.dart' show
    FunctionElementX;

import 'package:compiler/src/dart_backend/dart_backend.dart' show
    DartConstantTask;

import 'package:compiler/src/constants/constant_system.dart' show
    ConstantSystem;

import 'package:compiler/src/compile_time_constants.dart' show
    BackendConstantEnvironment;

import 'package:compiler/src/constants/values.dart' show
    ConstantValue,
    ConstructedConstantValue,
    ListConstantValue,
    MapConstantValue,
    StringConstantValue;

import 'package:compiler/src/constants/expressions.dart' show
    ConstantExpression;

import 'package:compiler/src/resolution/resolution.dart' show
    TreeElements;

import 'package:compiler/src/library_loader.dart' show
    LibraryLoader;

import 'fletch_constants.dart' show
    FletchClassConstant,
    FletchFunctionConstant,
    FletchClassInstanceConstant;

import 'compiled_function.dart' show
    CompiledFunctionKind,
    CompiledFunction,
    DebugInfo;

import 'codegen_visitor.dart';
import 'debug_info.dart';
import 'debug_info_constructor_codegen.dart';
import 'debug_info_function_codegen.dart';
import 'debug_info_lazy_field_initializer_codegen.dart';
import 'fletch_context.dart';
import 'fletch_selector.dart';
import 'function_codegen.dart';
import 'lazy_field_initializer_codegen.dart';
import 'constructor_codegen.dart';
import 'closure_environment.dart';
import '../bytecodes.dart';
import '../commands.dart';

class CompiledClass {
  final int id;
  final ClassElement element;
  final CompiledClass superclass;

  // The extra fields are synthetic fields not represented in any Dart source
  // code. They are used for the synthetic closure classes that are introduced
  // behind the scenes.
  final int extraFields;

  // TODO(kasperl): Hide these tables and go through a proper API to define
  // and lookup methods.
  final Map<int, int> implicitAccessorTable = <int, int>{};
  final Map<int, int> methodTable = <int, int>{};

  CompiledClass(this.id, this.element, this.superclass, {this.extraFields: 0});

  /**
   * Returns the number of instance fields of all the super classes of this
   * class.
   *
   * If this class has no super class (if it's Object), 0 is returned.
   */
  int get superclassFields => hasSuperClass ? superclass.fields : 0;

  bool get hasSuperClass => superclass != null;

  int get fields {
    int count = superclassFields + extraFields;
    if (element != null) {
      // TODO(kasperl): Once we change compiled class to be immutable, we
      // should cache the field count.
      element.implementation.forEachInstanceField((_, __) { count++; });
    }
    return count;
  }

  // The method table for a class is a mapping from Fletch's integer
  // selectors to method ids. It contains all methods defined for a
  // class including the implicit accessors.
  Map<int, int> computeMethodTable(FletchBackend backend) {
    Map<int, int> result = <int, int>{};
    List<int> selectors = implicitAccessorTable.keys.toList()
        ..addAll(methodTable.keys)
        ..sort();
    for (int selector in selectors) {
      if (methodTable.containsKey(selector)) {
        result[selector] = methodTable[selector];
      } else {
        result[selector] = implicitAccessorTable[selector];
      }
    }
    return result;
  }

  void createImplicitAccessors(FletchBackend backend) {
    implicitAccessorTable.clear();
    // If we don't have an element (stub class), we don't have anything to
    // generate accessors for.
    if (element == null) return;
    // TODO(ajohnsen): Don't do this once dart2js can enqueue field getters in
    // CodegenEnqueuer.
    int fieldIndex = superclassFields;
    element.implementation.forEachInstanceField((enclosing, field) {
      var getter = new Selector.getter(field.name, field.library);
      int getterSelector = backend.context.toFletchSelector(getter);
      implicitAccessorTable[getterSelector] = backend.makeGetter(fieldIndex);

      if (!field.isFinal) {
        var setter = new Selector.setter(field.name, field.library);
        var setterSelector = backend.context.toFletchSelector(setter);
        implicitAccessorTable[setterSelector] = backend.makeSetter(fieldIndex);
      }

      fieldIndex++;
    });
  }

  void createIsEntries(FletchBackend backend) {
    if (element == null) return;

    Set superclasses = new Set();
    for (CompiledClass current = superclass;
         current != null;
         current = current.superclass) {
      superclasses.add(current.element);
    }

    void createFor(ClassElement classElement) {
      if (superclasses.contains(classElement)) return;
      int fletchSelector = backend.context.toFletchIsSelector(classElement);
      // TODO(ajohnsen): '0' is a placeholder. Generate dummy function?
      methodTable[fletchSelector] = 0;
    }

    // Create for the current element.
    createFor(element);

    // Add all types related to 'implements'.
    for (InterfaceType interfaceType in element.interfaces) {
      createFor(interfaceType.element);
      for (DartType type in interfaceType.element.allSupertypes) {
        createFor(type.element);
      }
    }
  }

  void createIsFunctionEntry(FletchBackend backend) {
    int fletchSelector = backend.context.toFletchIsSelector(
        backend.compiler.functionClass);
    // TODO(ajohnsen): '0' is a placeholder. Generate dummy function?
    methodTable[fletchSelector] = 0;
  }

  String toString() => "CompiledClass(${element.name}, $id)";
}

class FletchBackend extends Backend {
  static const String growableListName = '_GrowableList';
  static const String constantListName = '_ConstantList';
  static const String constantMapName = '_ConstantMap';
  static const String linkedHashMapName = '_CompactLinkedHashMap';
  static const String noSuchMethodName = '_noSuchMethod';
  static const String noSuchMethodTrampolineName = '_noSuchMethodTrampoline';

  final FletchContext context;

  final DartConstantTask constantCompilerTask;

  final Map<FunctionElement, CompiledFunction> compiledFunctions =
      <FunctionElement, CompiledFunction>{};

  final Map<ConstructorElement, CompiledFunction> constructors =
      <ConstructorElement, CompiledFunction>{};

  final List<CompiledFunction> functions = <CompiledFunction>[];

  final Set<FunctionElement> externals = new Set<FunctionElement>();

  final Map<ClassElement, CompiledClass> compiledClasses =
      <ClassElement, CompiledClass>{};
  final Map<ClassElement, Set<ClassElement>> directSubclasses =
      <ClassElement, Set<ClassElement>>{};

  final List<CompiledClass> classes = <CompiledClass>[];

  final Set<ClassElement> builtinClasses = new Set<ClassElement>();

  final Map<MemberElement, ClosureEnvironment> closureEnvironments =
      <MemberElement, ClosureEnvironment>{};

  final Map<FunctionElement, CompiledClass> closureClasses =
      <FunctionElement, CompiledClass>{};

  final Map<FieldElement, CompiledFunction> lazyFieldInitializers =
      <FieldElement, CompiledFunction>{};

  final Map<CompiledFunction, CompiledClass> tearoffClasses =
      <CompiledFunction, CompiledClass>{};

  final Map<int, int> getters = <int, int>{};
  final Map<int, int> setters = <int, int>{};

  Map<CompiledClass, CompiledFunction> tearoffFunctions;

  List<Command> commands;

  LibraryElement fletchSystemLibrary;
  LibraryElement fletchFFILibrary;
  LibraryElement fletchIOSystemLibrary;
  LibraryElement collectionLibrary;
  LibraryElement mathLibrary;

  FunctionElement fletchSystemEntry;

  FunctionElement fletchExternalInvokeMain;

  FunctionElement fletchExternalYield;

  FunctionElement fletchExternalNativeError;

  FunctionElement fletchExternalCoroutineChange;

  FunctionElement fletchUnresolved;
  FunctionElement fletchCompileError;

  CompiledClass compiledObjectClass;

  ClassElement stringClass;
  ClassElement smiClass;
  ClassElement mintClass;
  ClassElement growableListClass;
  ClassElement linkedHashMapClass;
  ClassElement coroutineClass;

  final Set<FunctionElement> alwaysEnqueue = new Set<FunctionElement>();

  FletchBackend(FletchCompiler compiler)
      : this.context = compiler.context,
        this.constantCompilerTask = new DartConstantTask(compiler),
        super(compiler) {
    context.resolutionCallbacks = new FletchResolutionCallbacks(context);
  }

  CompiledClass registerClassElement(ClassElement element) {
    if (element == null) return null;
    assert(element.isDeclaration);
    return compiledClasses.putIfAbsent(element, () {
      directSubclasses[element] = new Set<ClassElement>();
      CompiledClass superclass = registerClassElement(element.superclass);
      if (superclass != null) {
        Set<ClassElement> subclasses = directSubclasses[element.superclass];
        subclasses.add(element);
      }
      int id = classes.length;
      CompiledClass compiledClass = new CompiledClass(id, element, superclass);
      if (element.lookupLocalMember(Compiler.CALL_OPERATOR_NAME) != null) {
        compiledClass.createIsFunctionEntry(this);
      }
      classes.add(compiledClass);
      return compiledClass;
    });
  }

  CompiledClass createCallableStubClass(int fields, CompiledClass superclass) {
    int id = classes.length;
    CompiledClass compiledClass = new CompiledClass(
        id, null, superclass, extraFields: fields);
    classes.add(compiledClass);
    compiledClass.createIsFunctionEntry(this);
    return compiledClass;
  }

  FletchResolutionCallbacks get resolutionCallbacks {
    return context.resolutionCallbacks;
  }

  List<CompilerTask> get tasks => <CompilerTask>[];

  ConstantSystem get constantSystem {
    return constantCompilerTask.constantCompiler.constantSystem;
  }

  BackendConstantEnvironment get constants => constantCompilerTask;

  bool classNeedsRti(ClassElement cls) => false;

  bool methodNeedsRti(FunctionElement function) => false;

  void enqueueHelpers(
      ResolutionEnqueuer world,
      CodegenRegistry registry) {
    compiler.patchAnnotationClass = patchAnnotationClass;

    FunctionElement findHelper(String name) {
      Element helper = fletchSystemLibrary.findLocal(name);
      // TODO(ahe): Make it cleaner.
      if (helper.isAbstractField) {
        AbstractFieldElement abstractField = helper;
        helper = abstractField.getter;
      }
      if (helper == null) {
        compiler.reportError(
            fletchSystemLibrary, MessageKind.GENERIC,
            {'text': "Required implementation method '$name' not found."});
      }
      return helper;
    }

    FunctionElement findExternal(String name) {
      FunctionElement helper = findHelper(name);
      externals.add(helper);
      return helper;
    }

    fletchSystemEntry = findHelper('entry');
    if (fletchSystemEntry != null) {
      world.registerStaticUse(fletchSystemEntry);
    }
    fletchExternalInvokeMain = findExternal('invokeMain');
    fletchExternalYield = findExternal('yield');
    fletchExternalCoroutineChange = findExternal('coroutineChange');
    fletchExternalNativeError = findExternal('nativeError');
    fletchUnresolved = findExternal('unresolved');
    world.registerStaticUse(fletchUnresolved);
    fletchCompileError = findExternal('compileError');
    world.registerStaticUse(fletchCompileError);

    CompiledClass loadClass(String name, LibraryElement library) {
      var classImpl = library.findLocal(name);
      if (classImpl == null) classImpl = library.implementation.find(name);
      if (classImpl == null) {
        compiler.internalError(library, "Internal class '$name' not found.");
        return null;
      }
      // TODO(ahe): Register in ResolutionCallbacks. The 3 lines below should
      // not happen at this point in time.
      classImpl.ensureResolved(compiler);
      CompiledClass compiledClass = registerClassElement(classImpl);
      world.registerInstantiatedType(classImpl.rawType, registry);
      // TODO(ahe): This is a hack to let both the world and the codegen know
      // about the instantiated type.
      registry.registerInstantiatedType(classImpl.rawType);
      return compiledClass;
    }

    CompiledClass loadBuiltinClass(String name, LibraryElement library) {
      CompiledClass compiledClass = loadClass(name, library);
      builtinClasses.add(compiledClass.element);
      return compiledClass;
    }

    compiledObjectClass = loadBuiltinClass("Object", compiler.coreLibrary);
    smiClass = loadBuiltinClass("_Smi", compiler.coreLibrary).element;
    mintClass = loadBuiltinClass("_Mint", compiler.coreLibrary).element;
    stringClass = loadBuiltinClass("_StringImpl", compiler.coreLibrary).element;
    // TODO(ahe): Register _ConstantList through ResolutionCallbacks.
    loadBuiltinClass(constantListName, fletchSystemLibrary);
    loadBuiltinClass(constantMapName, fletchSystemLibrary);
    loadBuiltinClass("_DoubleImpl", compiler.coreLibrary);
    loadBuiltinClass("Null", compiler.coreLibrary);
    loadBuiltinClass("bool", compiler.coreLibrary);
    coroutineClass =
        loadBuiltinClass("Coroutine", compiler.coreLibrary).element;
    loadBuiltinClass("Port", compiler.coreLibrary);
    loadBuiltinClass("Foreign", fletchFFILibrary);

    growableListClass =
        loadClass(growableListName, fletchSystemLibrary).element;
    // The linked hash map depends on LinkedHashMap.
    loadClass("LinkedHashMap", collectionLibrary).element;
    linkedHashMapClass =
        loadClass(linkedHashMapName, collectionLibrary).element;
    // Register list constructors to world.
    // TODO(ahe): Register growableListClass through ResolutionCallbacks.
    growableListClass.constructors.forEach(world.registerStaticUse);
    linkedHashMapClass.constructors.forEach(world.registerStaticUse);

    // TODO(ajohnsen): Remove? String interpolation does not enqueue '+'.
    // Investigate what else it may enqueue, could be StringBuilder, and then
    // consider using that instead.
    world.registerDynamicInvocation(new Selector.binaryOperator('+'));
    world.registerDynamicInvocation(new Selector.call('add', null, 1));

    alwaysEnqueue.add(coroutineClass.lookupLocalMember('_coroutineStart'));
    alwaysEnqueue.add(compiler.objectClass.implementation.lookupLocalMember(
        noSuchMethodTrampolineName));
    alwaysEnqueue.add(compiler.objectClass.implementation.lookupLocalMember(
        noSuchMethodName));

    for (FunctionElement element in alwaysEnqueue) {
      world.registerStaticUse(element);
    }
  }

  void onElementResolved(Element element, TreeElements elements) {
    if (alwaysEnqueue.contains(element)) {
      var registry = new CodegenRegistry(compiler, elements);
      registry.registerStaticInvocation(element);
    }
  }

  ClassElement get stringImplementation => stringClass;

  ClassElement get intImplementation => smiClass;

  /// Class of annotations to mark patches in patch files.
  ///
  /// The patch parser (pkg/compiler/lib/src/patch_parser.dart). The patch
  /// parser looks for an annotation on the form "@patch", where "patch" is
  /// compile-time constant instance of [patchAnnotationClass].
  ClassElement get patchAnnotationClass {
    // TODO(ahe): Introduce a proper constant class to identify constants. For
    // now, we simply put "const patch = "patch";" in the beginning of patch
    // files.
    return super.stringImplementation;
  }

  CompiledClass createClosureClass(
      FunctionElement closure,
      ClosureEnvironment closureEnvironment) {
    return closureClasses.putIfAbsent(closure, () {
      ClosureInfo info = closureEnvironment.closures[closure];
      int fields = info.free.length;
      if (info.isThisFree) fields++;
      return createCallableStubClass(fields, compiledObjectClass);
    });
  }

  /**
   * Create a tearoff class for function [function].
   *
   * The class will have one method named 'call', accepting the same arguments
   * as [function]. The method will load the arguments received and statically
   * call [function] (essential a tail-call).
   *
   * If [function] is an instance member, the class will have one field, the
   * instance.
   */
  CompiledClass createTearoffClass(CompiledFunction function) {
    return tearoffClasses.putIfAbsent(function, () {
      FunctionSignature signature = function.signature;
      bool hasThis = function.hasThisArgument;
      CompiledClass compiledClass = createCallableStubClass(
          hasThis ? 1 : 0,
          compiledObjectClass);
      CompiledFunction compiledFunction = new CompiledFunction(
          functions.length,
          'call',
          null,
          signature,
          compiledClass);
      functions.add(compiledFunction);

      BytecodeBuilder builder = compiledFunction.builder;
      int argumentCount = signature.parameterCount;
      if (hasThis) {
        argumentCount++;
        // If the tearoff has a 'this' value, load it. It's the only field
        // in the tearoff class.
        builder
            ..loadParameter(0)
            ..loadField(0);
      }
      for (int i = 0; i < signature.parameterCount; i++) {
        // The closure-class is at parameter index 0, so argument i is at
        // i + 1.
        builder.loadParameter(i + 1);
      }
      int constId = compiledFunction.allocateConstantFromFunction(
          function.methodId);
      // TODO(ajohnsen): Create a tail-call bytecode, so we don't have to
      // load all the arguments.
      builder
          ..invokeStatic(constId, argumentCount)
          ..ret()
          ..methodEnd();

      String symbol = context.getCallSymbol(signature);
      int id = context.getSymbolId(symbol);
      int fletchSelector = FletchSelector.encodeMethod(
          id,
          signature.parameterCount);
      compiledClass.methodTable[fletchSelector] = compiledFunction.methodId;

      if (hasThis && function.memberOf.element != null) {
        // Create == function that tests for equality.
        int isSelector = context.toFletchTearoffIsSelector(
            function.name,
            function.memberOf.element);
        compiledClass.methodTable[isSelector] = 0;

        CompiledFunction equal = new CompiledFunction.normal(
            functions.length,
            2);
        functions.add(equal);

        BytecodeBuilder builder = equal.builder;
        BytecodeLabel isFalse = new BytecodeLabel();
        builder
          // First test for class. This ensures it's the exact function that
          // we expect.
          ..loadParameter(1)
          ..invokeTest(isSelector, 0)
          ..branchIfFalse(isFalse)
          // Then test that the receiver is identical.
          ..loadParameter(0)
          ..loadField(0)
          ..loadParameter(1)
          ..loadField(0)
          ..identicalNonNumeric()
          ..branchIfFalse(isFalse)
          ..loadLiteralTrue()
          ..ret()
          ..bind(isFalse)
          ..loadLiteralFalse()
          ..ret()
          ..methodEnd();

        int id = context.getSymbolId("==");
        int fletchSelector = FletchSelector.encodeMethod(id, 1);
        compiledClass.methodTable[fletchSelector] = equal.methodId;
      }
      return compiledClass;
    });
  }

  CompiledFunction createCompiledFunction(FunctionElement function) {
    assert(function.memberContext == function);

    CompiledClass holderClass;
    if (function.isInstanceMember || function.isGenerativeConstructor) {
      ClassElement enclosingClass = function.enclosingClass.declaration;
      holderClass = registerClassElement(enclosingClass);
    }
    return internalCreateCompiledFunction(
        function,
        function.name,
        holderClass);
  }

  CompiledFunction internalCreateCompiledFunction(
      FunctionElement function,
      String name,
      CompiledClass holderClass) {
    return compiledFunctions.putIfAbsent(function.declaration, () {
      FunctionTypedElement implementation = function.implementation;
      CompiledFunction compiledFunction = new CompiledFunction(
          functions.length,
          name,
          function,
          // Parameter initializers are expressed in the potential
          // implementation.
          implementation.functionSignature,
          holderClass,
          kind: function.isAccessor
              ? CompiledFunctionKind.ACCESSOR
              : CompiledFunctionKind.NORMAL);
      functions.add(compiledFunction);
      return compiledFunction;
    });
  }

  int functionMethodId(FunctionElement function) {
    return createCompiledFunction(function).methodId;
  }

  CompiledFunction compiledFunctionFromTearoffClass(CompiledClass klass) {
    if (tearoffFunctions == null) {
      tearoffFunctions = <CompiledClass, CompiledFunction>{};
      tearoffClasses.forEach((k, v) => tearoffFunctions[v] = k);
    }
    return tearoffFunctions[klass];
  }

  void ensureDebugInfo(CompiledFunction function) {
    if (function.debugInfo != null) return;
    function.debugInfo = new DebugInfo(function);
    AstElement element = function.element;
    if (element == null) return;
    List<Bytecode> expectedBytecodes = function.builder.bytecodes;
    element = element.implementation;
    TreeElements elements = element.resolvedAst.elements;
    ClosureEnvironment closureEnvironment = createClosureEnvironment(
        element,
        elements);
    CodegenVisitor codegen;
    if (function.isLazyFieldInitializer) {
      codegen = new DebugInfoLazyFieldInitializerCodegen(
          function,
          context,
          elements,
          null,
          closureEnvironment,
          element,
          compiler);
    } else if (function.isInitializerList) {
      ClassElement enclosingClass = element.enclosingClass;
      CompiledClass compiledClass = compiledClasses[enclosingClass];
      codegen = new DebugInfoConstructorCodegen(
          function,
          context,
          elements,
          null,
          closureEnvironment,
          element,
          compiledClass,
          compiler);
    } else {
      codegen = new DebugInfoFunctionCodegen(
          function,
          context,
          elements,
          null,
          closureEnvironment,
          element,
          compiler);
    }
    if (isNative(element)) {
      compiler.withCurrentElement(element, () {
        codegenNativeFunction(element, codegen);
      });
    } else if (isExternal(element)) {
      compiler.withCurrentElement(element, () {
        codegenExternalFunction(element, codegen);
      });
    } else {
      compiler.withCurrentElement(element, () { codegen.compile(); });
    }
    // The debug codegen should generate the same bytecodes as the original
    // codegen. If that is not the case debug information will be useless.
    assert(Bytecode.identicalBytecodes(expectedBytecodes,
                                       codegen.builder.bytecodes));
  }

  void codegen(CodegenWorkItem work) {
    Element element = work.element;
    if (compiler.verbose) {
      compiler.reportHint(
          element, MessageKind.GENERIC, {'text': 'Compiling ${element.name}'});
    }

    if (element.isFunction ||
        element.isGetter ||
        element.isSetter ||
        element.isGenerativeConstructor) {
      compiler.withCurrentElement(element.implementation, () {
        codegenFunction(
            element.implementation, work.resolutionTree, work.registry);
      });
    } else {
      compiler.internalError(
          element, "Uninimplemented element kind: ${element.kind}");
    }
  }

  void codegenFunction(
      FunctionElement function,
      TreeElements elements,
      Registry registry) {
    registry.registerStaticInvocation(fletchSystemEntry);

    ClosureEnvironment closureEnvironment = createClosureEnvironment(
        function,
        elements);

    CompiledFunction compiledFunction;

    if (function.memberContext != function) {
      compiledFunction = internalCreateCompiledFunction(
          function,
          Compiler.CALL_OPERATOR_NAME,
          createClosureClass(function, closureEnvironment));
    } else {
      compiledFunction = createCompiledFunction(function);
    }

    FunctionCodegen codegen = new FunctionCodegen(
        compiledFunction,
        context,
        elements,
        registry,
        closureEnvironment,
        function);

    if (isNative(function)) {
      codegenNativeFunction(function, codegen);
    } else if (isExternal(function)) {
      codegenExternalFunction(function, codegen);
    } else {
      codegen.compile();
    }

    // TODO(ahe): Don't do this.
    compiler.enqueuer.codegen.generatedCode[function.declaration] = null;

    if (compiledFunction.memberOf != null &&
        !function.isGenerativeConstructor) {
      // Inject the function into the method table of the 'holderClass' class.
      // Note that while constructor bodies has a this argument, we don't inject
      // them into the method table.
      String symbol = context.getSymbolForFunction(
          compiledFunction.name,
          function.functionSignature,
          function.library);
      int id = context.getSymbolId(symbol);
      int arity = function.functionSignature.parameterCount;
      SelectorKind kind = SelectorKind.Method;
      if (function.isGetter) kind = SelectorKind.Getter;
      if (function.isSetter) kind = SelectorKind.Setter;
      int fletchSelector = FletchSelector.encode(id, kind, arity);
      int methodId = compiledFunction.methodId;
      compiledFunction.memberOf.methodTable[fletchSelector] = methodId;
      // Inject method into all mixin usages.
      Iterable<ClassElement> mixinUsage =
          compiler.world.mixinUsesOf(function.enclosingClass);
      for (ClassElement usage in mixinUsage) {
        // TODO(ajohnsen): Consider having multiple 'memberOf' in
        // CompiledFunction, to avoid duplicates.
        // Create a copy with a unique 'memberOf', so we can detect missing
        // stubs for the mixin applications as well.
        CompiledClass compiledUsage = registerClassElement(usage);
        FunctionTypedElement implementation = function.implementation;
        CompiledFunction copy = new CompiledFunction(
            functions.length,
            function.name,
            implementation,
            implementation.functionSignature,
            compiledUsage,
            kind: function.isAccessor
                ? CompiledFunctionKind.ACCESSOR
                : CompiledFunctionKind.NORMAL);
        functions.add(copy);
        compiledUsage.methodTable[fletchSelector] = copy.methodId;
        copy.copyFrom(compiledFunction);
      }
    }

    if (compiler.verbose) {
      print(compiledFunction.verboseToString());
    }
  }

  void codegenNativeFunction(
      FunctionElement function,
      FunctionCodegen codegen) {
    String name = '.${function.name}';

    ClassElement enclosingClass = function.enclosingClass;
    if (enclosingClass != null) name = '${enclosingClass.name}$name';

    FletchNativeDescriptor descriptor = context.nativeDescriptors[name];
    if (descriptor == null) {
      throw "Unsupported native function: $name";
    }

    int arity = codegen.builder.functionArity;
    if (name == "Port.send" ||
        name == "Port._sendList" ||
        name == "Port._sendExit" ||
        name == "Process._divide") {
      codegen.builder.invokeNativeYield(arity, descriptor.index);
    } else {
      codegen.builder.invokeNative(arity, descriptor.index);
    }

    EmptyStatement empty = function.node.body.asEmptyStatement();
    if (empty != null) {
      // A native method without a body.
      codegen.builder
          ..emitThrow()
          ..methodEnd();
    } else {
      codegen.compile();
    }
  }

  void codegenExternalFunction(
      FunctionElement function,
      FunctionCodegen codegen) {
    if (function == fletchExternalYield) {
      codegenExternalYield(function, codegen);
    } else if (function == context.compiler.identicalFunction.implementation) {
      codegenIdentical(function, codegen);
    } else if (function == fletchExternalInvokeMain) {
      codegenExternalInvokeMain(function, codegen);
    } else if (function.name == noSuchMethodTrampolineName &&
               function.library == compiler.coreLibrary) {
      codegenExternalNoSuchMethodTrampoline(function, codegen);
    } else {
      compiler.reportError(
          function.node,
          MessageKind.GENERIC,
          {'text': 'External function is not supported'});
      codegen
          ..handleCompileError()
          ..builder.ret()
          ..builder.methodEnd();
    }
  }

  void codegenIdentical(
      FunctionElement function,
      FunctionCodegen codegen) {
    codegen.builder
        ..loadLocal(2)
        ..loadLocal(2)
        ..identical()
        ..ret()
        ..methodEnd();
  }

  void codegenExternalYield(
      FunctionElement function,
      FunctionCodegen codegen) {
    codegen.builder
        ..loadLocal(1)
        ..processYield()
        ..ret()
        ..methodEnd();
  }

  void codegenExternalInvokeMain(
      FunctionElement function,
      FunctionCodegen codegen) {
    compiler.internalError(
        function, "[codegenExternalInvokeMain] not implemented.");
    // TODO(ahe): This code shouldn't normally be called, only if invokeMain is
    // torn off. Perhaps we should just say we don't support that.
  }

  void codegenExternalNoSuchMethodTrampoline(
      FunctionElement function,
      FunctionCodegen codegen) {
    int id = context.getSymbolId(
        context.mangleName(noSuchMethodName, compiler.coreLibrary));
    int fletchSelector = FletchSelector.encodeMethod(id, 1);
    codegen.builder
        ..enterNoSuchMethod()
        ..invokeMethod(fletchSelector, 1)
        ..exitNoSuchMethod()
        ..methodEnd();
  }

  bool isNative(Element element) {
    if (element is FunctionElement) {
      for (var metadata in element.metadata) {
        // TODO(ahe): This code should ensure that @native resolves to precisely
        // the native variable in fletch:system.
        if (metadata.constant == null) continue;
        ConstantValue value = metadata.constant.value;
        if (!value.isString) continue;
        StringConstantValue stringValue = value;
        if (stringValue.toDartString().slowToString() != 'native') continue;
        return true;
      }
    }
    return false;
  }

  bool isExternal(Element element) {
    if (element is FunctionElement) return element.isExternal;
    return false;
  }

  bool get canHandleCompilationFailed => true;

  ClosureEnvironment createClosureEnvironment(
      ExecutableElement element,
      TreeElements elements) {
    MemberElement member = element.memberContext;
    return closureEnvironments.putIfAbsent(member, () {
      ClosureVisitor environment = new ClosureVisitor(member, elements);
      return environment.compute();
    });
  }

  void createParameterMatchingStubs() {
    int length = functions.length;
    for (int i = 0; i < length; i++) {
      CompiledFunction function = functions[i];
      if (!function.hasThisArgument || function.isAccessor) continue;
      String name = function.name;
      Set<Selector> usage = compiler.resolverWorld.invokedNames[name];
      if (usage == null) continue;
      for (Selector use in usage) {
        // TODO(ajohnsen): Somehow filter out private selectors of other
        // libraries.
        if (function.canBeCalledAs(use) &&
            !function.matchesSelector(use)) {
          function.createParameterMappingFor(use, context);
        }
      }
    }
  }

  void createTearoffStubs() {
    int length = functions.length;
    for (int i = 0; i < length; i++) {
      CompiledFunction function = functions[i];
      if (!function.hasThisArgument || function.isAccessor) continue;
      String name = function.name;
      if (compiler.resolverWorld.invokedGetters.containsKey(name)) {
        createTearoffGetterForFunction(function);
      }
    }
  }

  void createTearoffGetterForFunction(CompiledFunction function) {
    CompiledClass tearoffClass = createTearoffClass(function);
    CompiledFunction getter = new CompiledFunction.accessor(
        functions.length,
        false);
    functions.add(getter);
    int constId = getter.allocateConstantFromClass(tearoffClass.id);
    getter.builder
        ..loadParameter(0)
        ..allocate(constId, tearoffClass.fields)
        ..ret()
        ..methodEnd();
    // If the name is private, we need the library.
    // Invariant: We only generate public stubs, e.g. 'call'.
    LibraryElement library;
    if (function.memberOf.element != null) {
      library = function.memberOf.element.library;
    }
    int fletchSelector = context.toFletchSelector(
        new Selector.getter(function.name, library));
    function.memberOf.methodTable[fletchSelector] = getter.methodId;
  }

  int assembleProgram() {
    createTearoffStubs();
    createParameterMatchingStubs();

    for (CompiledClass compiledClass in classes) {
      compiledClass.createIsEntries(this);
      // TODO(ajohnsen): Currently, the CodegenRegistry does not enqueue fields.
      // This is a workaround, where we basically add getters for all fields.
      compiledClass.createImplicitAccessors(this);
    }

    List<Command> commands = <Command>[
        const NewMap(MapId.methods),
        const NewMap(MapId.classes),
        const NewMap(MapId.constants),
    ];

    List<Function> deferredActions = <Function>[];

    functions.forEach((f) => pushNewFunction(f, commands, deferredActions));

    int changes = 0;

    for (CompiledClass compiledClass in classes) {
      ClassElement element = compiledClass.element;
      if (builtinClasses.contains(element)) {
        int nameId = context.getSymbolId(element.name);
        commands.add(new PushBuiltinClass(nameId, compiledClass.fields));
      } else {
        commands.add(new PushNewClass(compiledClass.fields));
      }

      commands.add(const Dup());
      commands.add(new PopToMap(MapId.classes, compiledClass.id));

      Map<int, int> methodTable = compiledClass.computeMethodTable(this);
      methodTable.forEach((int selector, int methodId) {
        commands.add(new PushNewInteger(selector));
        commands.add(new PushFromMap(MapId.methods, methodId));
      });
      commands.add(new ChangeMethodTable(methodTable.length));

      changes++;
    }

    context.forEachStatic((element, index) {
      CompiledFunction initializer = lazyFieldInitializers[element];
      if (initializer != null) {
        commands.add(new PushFromMap(MapId.methods, initializer.methodId));
        commands.add(const PushNewInitializer());
      } else {
        commands.add(const PushNull());
      }
    });
    commands.add(new ChangeStatics(context.staticIndices.length));
    changes++;

    context.compiledConstants.forEach((constant, id) {
      void addList(List<ConstantValue> list) {
        for (ConstantValue entry in list) {
          int entryId = context.compiledConstants[entry];
          commands.add(new PushFromMap(MapId.constants, entryId));
        }
        commands.add(new PushConstantList(list.length));
      }

      if (constant.isInt) {
        commands.add(new PushNewInteger(constant.primitiveValue));
      } else if (constant.isDouble) {
        commands.add(new PushNewDouble(constant.primitiveValue));
      } else if (constant.isTrue) {
        commands.add(new PushBoolean(true));
      } else if (constant.isFalse) {
        commands.add(new PushBoolean(false));
      } else if (constant.isNull) {
        commands.add(const PushNull());
      } else if (constant.isString) {
        commands.add(
            new PushNewString(constant.primitiveValue.slowToString()));
      } else if (constant.isList) {
        ListConstantValue value = constant;
        addList(constant.entries);
      } else if (constant.isMap) {
        MapConstantValue value = constant;
        addList(value.keys);
        addList(value.values);
        commands.add(new PushConstantMap(value.length * 2));
      } else if (constant.isConstructedObject) {
        ConstructedConstantValue value = constant;
        ClassElement classElement = value.type.element;
        CompiledClass compiledClass = compiledClasses[classElement];
        for (ConstantValue field in value.fields.values) {
          int fieldId = context.compiledConstants[field];
          commands.add(new PushFromMap(MapId.constants, fieldId));
        }
        commands
            ..add(new PushFromMap(MapId.classes, compiledClass.id))
            ..add(const PushNewInstance());
      } else if (constant is FletchClassInstanceConstant) {
        commands
            ..add(new PushFromMap(MapId.classes, constant.classId))
            ..add(const PushNewInstance());
      } else {
        throw "Unsupported constant: ${constant.toStructuredString()}";
      }
      commands.add(new PopToMap(MapId.constants, id));
    });

    for (CompiledClass compiledClass in classes) {
      CompiledClass superclass = compiledClass.superclass;
      if (superclass == null) continue;
      commands.add(new PushFromMap(MapId.classes, compiledClass.id));
      commands.add(new PushFromMap(MapId.classes, superclass.id));
      commands.add(const ChangeSuperClass());
      changes++;
    }

    for (Function action in deferredActions) {
      action();
      changes++;
    }

    commands.add(new CommitChanges(changes));

    commands.add(const PushNewInteger(0));

    commands.add(new PushFromMap(
        MapId.methods,
        compiledFunctions[fletchSystemEntry].methodId));

    this.commands = commands;

    return 0;
  }

  void pushNewFunction(
      CompiledFunction compiledFunction,
      List<Command> commands,
      List<Function> deferredActions) {
    int arity = compiledFunction.builder.functionArity;
    int constantCount = compiledFunction.constants.length;
    int methodId = compiledFunction.methodId;

    assert(functions[methodId] == compiledFunction);
    assert(compiledFunction.builder.bytecodes.isNotEmpty);

    compiledFunction.constants.forEach((constant, int index) {
      if (constant is ConstantValue) {
        if (constant is FletchFunctionConstant) {
          commands.add(const PushNull());
          deferredActions.add(() {
            commands
                ..add(new PushFromMap(MapId.methods, methodId))
                ..add(new PushFromMap(MapId.methods, constant.methodId))
                ..add(new ChangeMethodLiteral(index));
          });
        } else if (constant is FletchClassConstant) {
          commands.add(const PushNull());
          deferredActions.add(() {
            commands
                ..add(new PushFromMap(MapId.methods, methodId))
                ..add(new PushFromMap(MapId.classes, constant.classId))
                ..add(new ChangeMethodLiteral(index));
          });
        } else {
          commands.add(const PushNull());
          deferredActions.add(() {
            int id = context.compiledConstants[constant];
            if (id == null) {
              throw "Unsupported constant: ${constant.toStructuredString()}";
            }
            commands
                ..add(new PushFromMap(MapId.methods, methodId))
                ..add(new PushFromMap(MapId.constants, id))
                ..add(new ChangeMethodLiteral(index));
          });
        }
      } else {
        throw "Unsupported constant: ${constant.runtimeType}";
      }
    });

    commands.add(
        new PushNewFunction(
            arity,
            constantCount,
            compiledFunction.builder.bytecodes,
            compiledFunction.builder.catchRanges));

    commands.add(new PopToMap(MapId.methods, methodId));
  }

  Future onLibraryScanned(LibraryElement library, LibraryLoader loader) {
    // TODO(ajohnsen): Find a better way to do this.
    // Inject non-patch members in a patch library, into the declaration
    // library.
    if (library.isPatch && library.declaration == compiler.coreLibrary) {
      library.entryCompilationUnit.forEachLocalMember((element) {
        if (!element.isPatch && !isPrivateName(element.name)) {
          LibraryElementX declaration = library.declaration;
          declaration.addToScope(element, compiler);
        }
      });
    }

    if (Uri.parse('dart:_fletch_system') == library.canonicalUri) {
      fletchSystemLibrary = library;
    } else if (Uri.parse('dart:ffi') == library.canonicalUri) {
      fletchFFILibrary = library;
    } else if (Uri.parse('dart:system') == library.canonicalUri) {
      fletchIOSystemLibrary = library;
    } else if (Uri.parse('dart:collection') == library.canonicalUri) {
      collectionLibrary = library;
    } else if (Uri.parse('dart:math') == library.canonicalUri) {
      mathLibrary = library;
    }

    if (library.isPlatformLibrary && !library.isPatched) {
      // Apply patch, if any.
      Uri patchUri = compiler.resolvePatchUri(library.canonicalUri.path);
      if (patchUri != null) {
        return compiler.patchParser.patchLibrary(loader, patchUri, library);
      }
    }
  }

  bool isBackendLibrary(LibraryElement library) {
    return library == fletchSystemLibrary;
  }

  /// Return non-null to enable patching. Possible return values are 'new' and
  /// 'old'. Referring to old and new emitter. Since the new emitter is the
  /// future, we assume 'old' will go away. So it seems the best option for
  /// Fletch is 'new'.
  String get patchVersion => 'new';

  FunctionElement resolveExternalFunction(FunctionElement element) {
    if (element.isPatched) {
      FunctionElementX patch = element.patch;
      compiler.withCurrentElement(patch, () {
        patch.parseNode(compiler);
        patch.computeType(compiler);
      });
      element = patch;
      // TODO(ahe): Don't use ensureResolved (fix TODO in isNative instead).
      element.metadata.forEach((m) => m.ensureResolved(compiler));
    } else if (element.library == fletchSystemLibrary) {
      // Nothing needed for now.
    } else if (element.library == compiler.coreLibrary) {
      // Nothing needed for now.
    } else if (element.library == mathLibrary) {
      // Nothing needed for now.
    } else if (element.library == fletchFFILibrary) {
      // Nothing needed for now.
    } else if (element.library == fletchIOSystemLibrary) {
      // Nothing needed for now.
    } else if (externals.contains(element)) {
      // Nothing needed for now.
    } else {
      compiler.reportError(
          element, MessageKind.PATCH_EXTERNAL_WITHOUT_IMPLEMENTATION);
    }
    return element;
  }

  int compileLazyFieldInitializer(FieldElement field, Registry registry) {
    int index = context.getStaticFieldIndex(field, null);

    if (field.initializer == null) return index;

    lazyFieldInitializers.putIfAbsent(field, () {
      CompiledFunction compiledFunction = new CompiledFunction.lazyInit(
          functions.length,
          "${field.name} lazy initializer",
          field,
          0);
      functions.add(compiledFunction);

      TreeElements elements = field.resolvedAst.elements;

      ClosureEnvironment closureEnvironment = createClosureEnvironment(
          field,
          elements);

      LazyFieldInitializerCodegen codegen = new LazyFieldInitializerCodegen(
          compiledFunction,
          context,
          elements,
          registry,
          closureEnvironment,
          field);

      codegen.compile();

      return compiledFunction;
    });

    return index;
  }

  CompiledFunction compileConstructor(ConstructorElement constructor,
                                      Registry registry) {
    assert(constructor.isDeclaration);
    return constructors.putIfAbsent(constructor, () {
      ClassElement classElement = constructor.enclosingClass;
      CompiledClass compiledClass = registerClassElement(classElement);

      constructor = constructor.implementation;

      if (compiler.verbose) {
        compiler.reportHint(
            constructor,
            MessageKind.GENERIC,
            {'text': 'Compiling constructor ${constructor.name}'});
      }

      TreeElements elements = constructor.resolvedAst.elements;

      ClosureEnvironment closureEnvironment = createClosureEnvironment(
          constructor,
          elements);

      CompiledFunction compiledFunction = new CompiledFunction(
          functions.length,
          constructor.name,
          constructor,
          constructor.functionSignature,
          null,
          kind: CompiledFunctionKind.INITIALIZER_LIST);
      functions.add(compiledFunction);

      ConstructorCodegen codegen = new ConstructorCodegen(
          compiledFunction,
          context,
          elements,
          registry,
          closureEnvironment,
          constructor,
          compiledClass);

      codegen.compile();

      if (compiler.verbose) {
        print(compiledFunction.verboseToString());
      }

      return compiledFunction;
    });
  }

  /**
   * Generate a getter for field [fieldIndex].
   */
  int makeGetter(int fieldIndex) {
    return getters.putIfAbsent(fieldIndex, () {
      CompiledFunction stub = new CompiledFunction.accessor(
          functions.length,
          false);
      functions.add(stub);
      stub.builder
          ..loadParameter(0)
          ..loadField(fieldIndex)
          ..ret()
          ..methodEnd();
      return stub.methodId;
    });
  }

  /**
   * Generate a setter for field [fieldIndex].
   */
  int makeSetter(int fieldIndex) {
    return setters.putIfAbsent(fieldIndex, () {
      CompiledFunction stub = new CompiledFunction.accessor(
          functions.length,
          true);
      functions.add(stub);
      stub.builder
          ..loadParameter(0)
          ..loadParameter(1)
          ..storeField(fieldIndex)
          // Top is at this point the rhs argument, thus the return value.
          ..ret()
          ..methodEnd();
      return stub.methodId;
    });
  }

  void generateUnimplementedError(
      Spannable spannable,
      String reason,
      CompiledFunction function) {
    compiler.reportError(
        spannable, MessageKind.GENERIC, {'text': reason});
    var constString = constantSystem.createString(
        new DartString.literal(reason));
    context.markConstantUsed(constString);
    function
        ..builder.loadConst(function.allocateConstant(constString))
        ..builder.emitThrow();
  }

  void forgetElement(Element element) {
    CompiledFunction compiledFunction = compiledFunctions[element];
    if (compiledFunction == null) return;
    compiledFunction.reuse();
  }
}
