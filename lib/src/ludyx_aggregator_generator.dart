import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:flutter_ludyx_generator/src/utils.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

class LudyxAggregatorGenerator extends Generator {
  static const TypeChecker _componentsChecker = TypeChecker.fromUrl(
    'package:flutter_ludyx_annotations/flutter_ludyx_annotations.dart#LudyxComponents',
  );

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    final buffer = StringBuffer();
    buffer.writeln('// ignore_for_file: sort_child_properties_last');

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

    buffer.writeln(importDirectives);

    buffer.writeAll(allComponents.map(generateComponentClass), '\n');

    buffer.writeln('void setup() {');
    buffer.writeAll(allComponents.map(generateRegister), '\n');
    buffer.writeln('}');

    return buffer.toString();
  }

  String generateComponentClass(dynamic data) {
    final buffer = StringBuffer();
    final params = [];

    for (final param in data['params']) {
      params.add(generateParam(param));
    }

    buffer
      ..writeln(
        'class _\$${data['className']}Component extends ${data['componentType']} {',
      )
      ..writeln('  const new({super.key, required super.data});')
      ..writeln()
      ..writeln('  @override')
      ..writeln(
        '  Widget build(BuildContext context) => ${data['className']}(${params.join(', ')});',
      )
      ..writeln()
      ..writeln('  @override')
      ..writeln('  String get component => \'${data['componentName']}\';')
      ..writeln('}');

    return buffer.toString();
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
      String v when v.contains('Function') => generateFunction(
        v,
        '($valueString as LudyxFn)',
      ),
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
    final buffer = StringBuffer();

    buffer
      ..write('  ')
      ..write('Components.register(')
      ..write('\'${data['componentName']}\', ')
      ..write('_\$${data['className']}Component.new')
      ..write(');');
    return buffer.toString();
  }

  String generateFunction(String fnType, String fnName) {
    var raw = fnType.trim();

    if (raw.endsWith('?')) {
      raw = raw.substring(0, raw.length - 1).trim();
    }

    final fnMatch = LudyxGeneratorUtils.matchTopLevelFunction(raw);
    if (fnMatch == null) {
      throw ArgumentError('Invalid Function type string: "$fnType"');
    }

    final paramsStr = fnMatch.params.trim();
    if (paramsStr.isEmpty) {
      return '() => $fnName.call([])';
    }

    final rawSections = LudyxGeneratorUtils.splitTopLevelArgs(paramsStr);

    final signatureParts = <String>[];
    final callArgNames = <String>[];
    var positionalCounter = 1;

    for (final section in rawSections) {
      final trimmed = section.trim();
      if (trimmed.isEmpty) continue;

      // 1. Named parameters: "{required String arg2, int arg3}"
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        final namedItems = LudyxGeneratorUtils.splitTopLevelArgs(inner);
        final namedSigNames = <String>[];

        for (final item in namedItems) {
          final name = LudyxGeneratorUtils.extractParamName(
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

      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        final optItems = LudyxGeneratorUtils.splitTopLevelArgs(inner);
        final optSigNames = <String>[];

        for (final item in optItems) {
          final name = LudyxGeneratorUtils.extractParamName(
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

      final name = LudyxGeneratorUtils.extractParamName(
        trimmed,
        fallbackIndex: positionalCounter++,
      );
      signatureParts.add(name);
      callArgNames.add(name);
    }

    return '(${signatureParts.join(', ')}) => $fnName.call([${callArgNames.join(', ')}])';
  }
}
