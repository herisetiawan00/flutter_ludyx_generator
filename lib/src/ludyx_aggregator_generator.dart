import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

class LudyxAggregatorGenerator extends Generator {
  static const TypeChecker _componentsChecker = TypeChecker.fromUrl(
    'package:flutter_ludyx_annotations/ludyx_component_annotations.dart#LudyxComponents',
  );

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final annotatedFunctions = library.annotatedWith(_componentsChecker);
    if (annotatedFunctions.isEmpty) return null;

    final target = annotatedFunctions.first.element;
    if (target is! TopLevelFunctionElement) {
      throw InvalidGenerationSourceError(
        '@LudyxComponents can only be applied to a top-level function.',
        element: target,
      );
    }

    final cacheAssets = buildStep.findAssets(Glob('lib/**.ludyx_cache.json'));
    final allComponents = <dynamic>[];

    await for (final assetId in cacheAssets) {
      final rawJson = await buildStep.readAsString(assetId);
      final decoded = jsonDecode(rawJson) as List<dynamic>;
      allComponents.addAll(decoded.cast<dynamic>());
    }

    allComponents.sort((a, b) {
      final nameA = a['componentName'] as String;
      final nameB = b['componentName'] as String;
      return nameA.compareTo(nameB);
    });

    // 2. Collect unique package imports
    final imports = {
      ...allComponents.map((c) => c['importUri'] as String),
      'package:flutter_ludyx/flutter_ludyx.dart',
      'package:flutter/widgets.dart',
    }.toList()..sort();

    final importDirectives = imports.map((uri) => "import '$uri';").join('\n');

    // 3. Build centralized registration entries
    final classes = allComponents.map(generateComponentClass).join('\n');
    final registers = allComponents.map(generateRegister).join('\n');

    return '''
// ignore_for_file: sort_child_properties_last

$importDirectives

$classes

void setup() {
$registers
}

''';
  }

  String generateComponentClass(dynamic data) {
    final params = [];

    for (final param in data['params']) {
      params.add(generateParam(param));
    }

    return '''
class _\$${data['className']}Component extends ${data['componentType']} {
  const new({super.key, required super.data});

  @override
  Widget build(BuildContext context) => ${data['className']}(${params.join(', ')});
  

  @override
  String get component => '${data['componentName']}';
}
''';
  }

  String generateParam(dynamic param) {
    final isNamed = param['isNamed'] == true;
    final isEnum = param['isEnum'] == true;
    final type = param['type'] as String;
    final name = param['name'] as String;
    final nullable = type.endsWith('?');
    final cleanType = type.replaceFirst('?', '');

    final valueString = 'data[\'$name\']';

    String value = switch (cleanType) {
      'double' => '($valueString as num).toDouble()',
      'int' => '($valueString as num).toInt()',
      'Widget' => 'Components.build($valueString)',
      'List<Widget>' =>
        'List<Map<String, dynamic>>.from($valueString).map(Components.build).toList()',
      String v when v.contains('Function') => generateFunction(v, '($valueString as LudyxFn)'),
      _ when isEnum => '$cleanType.values.byName($valueString as String)',
      _ => 'data[\'$name\'] as $type',
    };

    if (nullable) {
      value = '$valueString != null ? $value : null';
    }

    if (isNamed) {
      return '$name: $value';
    } else {
      return value;
    }
  }

  String generateRegister(dynamic data) {
    return '  Components.register(\'${data['componentName']}\', _\$${data['className']}Component.new);';
  }

  String generateFunction(String fnType, String fnName) {
    var raw = fnType.trim();

    if (raw.endsWith('?')) {
      raw = raw.substring(0, raw.length - 1).trim();
    }

    final fnMatch = _matchTopLevelFunction(raw);
    if (fnMatch == null) {
      throw ArgumentError('Invalid Function type string: "$fnType"');
    }

    final paramsStr = fnMatch.params.trim();
    if (paramsStr.isEmpty) {
      return '() => $fnName.call([])';
    }

    final rawSections = _splitTopLevelArgs(paramsStr);

    final signatureParts = <String>[];
    final callArgNames = <String>[];
    var positionalCounter = 1;

    for (final section in rawSections) {
      final trimmed = section.trim();
      if (trimmed.isEmpty) continue;

      // 1. Named parameters: "{required String arg2, int arg3}"
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        final namedItems = _splitTopLevelArgs(inner);
        final namedSigNames = <String>[];

        for (final item in namedItems) {
          final name = _extractParamName(
            item,
            fallbackIndex: positionalCounter++,
          );
          namedSigNames.add(name);
          callArgNames.add(name);
        }

        if (namedSigNames.isNotEmpty) {
          signatureParts.add('{${namedSigNames.join(', ')}}');
        }
        continue;
      }

      // 2. Optional positional parameters: "[String arg2, int arg3]"
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        final optItems = _splitTopLevelArgs(inner);
        final optSigNames = <String>[];

        for (final item in optItems) {
          final name = _extractParamName(
            item,
            fallbackIndex: positionalCounter++,
          );
          optSigNames.add(name);
          callArgNames.add(name);
        }

        if (optSigNames.isNotEmpty) {
          signatureParts.add('[${optSigNames.join(', ')}]');
        }
        continue;
      }

      // 3. Required positional parameter: "String" or "String arg1" or "arg1"
      final name = _extractParamName(
        trimmed,
        fallbackIndex: positionalCounter++,
      );
      signatureParts.add(name);
      callArgNames.add(name);
    }

    return '(${signatureParts.join(', ')}) => $fnName.call([${callArgNames.join(', ')}])';
  }

  String _extractParamName(String rawParam, {required int fallbackIndex}) {
    var p = rawParam.trim();

    // Strip 'required ' modifier if present
    if (p.startsWith('required ')) {
      p = p.substring('required '.length).trim();
    }

    // Strip default value if present (e.g. "int count = 0" -> "int count")
    final eqIndex = _findTopLevelChar(p, '=');
    if (eqIndex != -1) {
      p = p.substring(0, eqIndex).trim();
    }

    // Find the last top-level space separating Type and Name
    var depthAngle = 0;
    var depthParen = 0;
    var lastSpaceIndex = -1;

    for (var i = 0; i < p.length; i++) {
      final ch = p[i];
      if (ch == '<') depthAngle++;
      if (ch == '>') depthAngle--;
      if (ch == '(') depthParen++;
      if (ch == ')') depthParen--;
      if (ch == ' ' && depthAngle == 0 && depthParen == 0) {
        lastSpaceIndex = i;
      }
    }

    // Case A: Single token (either just a type like "String" or just a name like "arg1")
    if (lastSpaceIndex == -1) {
      if (_looksLikeTypeOnly(p)) {
        return 'arg$fallbackIndex';
      }
      return p; // Already an identifier like "arg1"
    }

    // Case B: "Type name" or nested "void Function(int)"
    final right = p.substring(lastSpaceIndex + 1).trim();
    if (right.startsWith('Function(') ||
        right.endsWith('>') ||
        right.endsWith(')')) {
      return 'arg$fallbackIndex';
    }

    return right;
  }

  bool _looksLikeTypeOnly(String token) {
    const builtInTypes = {
      'String',
      'int',
      'double',
      'num',
      'bool',
      'void',
      'Null',
      'dynamic',
      'Object',
      'List',
      'Map',
      'Set',
      'Iterable',
      'Future',
      'Stream',
      'Function',
      'Widget',
    };
    final clean = token.endsWith('?')
        ? token.substring(0, token.length - 1)
        : token;
    if (builtInTypes.contains(clean)) return true;
    if (clean.contains('<') || clean.contains('(')) return true;
    // In Dart, UpperCamelCase tokens are types (e.g., "BuildContext"), lowerCamelCase are param names ("arg1")
    return clean.isNotEmpty &&
        clean[0].toUpperCase() == clean[0] &&
        clean[0].toLowerCase() != clean[0];
  }

  int _findTopLevelChar(String input, String target) {
    var depthAngle = 0;
    var depthParen = 0;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '<') depthAngle++;
      if (ch == '>') depthAngle--;
      if (ch == '(') depthParen++;
      if (ch == ')') depthParen--;
      if (ch == target && depthAngle == 0 && depthParen == 0) return i;
    }
    return -1;
  }

  ({String returnType, String params})? _matchTopLevelFunction(String type) {
    var depthAngle = 0;
    var depthParen = 0;

    for (var i = 0; i < type.length; i++) {
      final ch = type[i];
      if (ch == '<') depthAngle++;
      if (ch == '>') depthAngle--;
      if (ch == '(') depthParen++;
      if (ch == ')') depthParen--;

      if (depthAngle == 0 &&
          depthParen == 0 &&
          type.startsWith('Function(', i)) {
        final returnType = type.substring(0, i).trim();
        final openParen = i + 'Function'.length;
        if (type.endsWith(')')) {
          final params = type.substring(openParen + 1, type.length - 1);
          return (returnType: returnType, params: params);
        }
      }
    }
    return null;
  }

  List<String> _splitTopLevelArgs(String input) {
    final result = <String>[];
    var depthAngle = 0;
    var depthParen = 0;
    var depthBracket = 0;
    var depthBrace = 0;
    var start = 0;

    for (var i = 0; i < input.length; i++) {
      switch (input[i]) {
        case '<':
          depthAngle++;
        case '>':
          depthAngle--;
        case '(':
          depthParen++;
        case ')':
          depthParen--;
        case '[':
          depthBracket++;
        case ']':
          depthBracket--;
        case '{':
          depthBrace++;
        case '}':
          depthBrace--;
        case ',':
          if (depthAngle == 0 &&
              depthParen == 0 &&
              depthBracket == 0 &&
              depthBrace == 0) {
            result.add(input.substring(start, i).trim());
            start = i + 1;
          }
      }
    }

    final tail = input.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }
}
