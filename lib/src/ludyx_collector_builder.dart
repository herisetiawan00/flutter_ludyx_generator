import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

class LudyxCollectorBuilder implements Builder {
  static const TypeChecker _componentChecker = TypeChecker.fromUrl(
    'package:flutter_ludyx_annotations/ludyx_component_annotations.dart#LudyxComponent',
  );

  static const Map<String, String> _typeMap = {
    'package:flutter/src/widgets/framework.dart#StatelessWidget':
        'StatelessComponentWidget',
    'package:flutter/src/widgets/framework.dart#StatefulWidget':
        'StatefulComponentWidget',
  };

  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.ludyx_cache.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!buildStep.inputId.path.startsWith('lib/')) return;
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) return;

    final library = await buildStep.inputLibrary;
    final reader = LibraryReader(library);
    final annotatedElements = reader.annotatedWith(_componentChecker);

    if (annotatedElements.isEmpty) return;

    final components = <dynamic>[];

    for (final annotated in annotatedElements) {
      final element = annotated.element;

      if (element is! ClassElement) {
        throw InvalidGenerationSourceError(
          '@LudyxComponent can only be applied to classes.',
          element: element,
        );
      }

      final type = _typeMap.keys.cast<String?>().firstWhere(
        (type) =>
            element.allSupertypes.any(TypeChecker.fromUrl(type).isExactlyType),
        orElse: () => null,
      );

      if (type == null) {
        throw InvalidGenerationSourceError(
          '@LudyxComponent can only be applied to a StatelessWidget or StatefulWidget.',
          todo: 'Extend StatelessWidget or StatefulWidget on ${element.name}.',
          element: element,
        );
      }

      final constructor = element.unnamedConstructor;
      final params = (constructor?.formalParameters ?? [])
          .where((p) => p.name != 'key')
          .map(
            (p) => {
              'name': p.name,
              'type': p.type.getDisplayString(),
              'isRequiredPositional': p.isRequiredPositional,
              'isOptionalPositional': p.isOptionalPositional,
              'isNamed': p.isNamed,
              'isRequiredNamed': p.isRequiredNamed,
              'isEnum': p.type.element is EnumElement,
              if (p.type.element is EnumElement)
                'enumValues': ?(p.type.element as EnumElement?)?.constants
                    .map((c) => c.name)
                    .toList(),
            },
          )
          .toList();

      components.add({
        'componentName': annotated.annotation.read('name').stringValue,
        'componentType': _typeMap[type],
        'className': element.name,
        'importUri': buildStep.inputId.uri.toString(),
        'params': params,
      });
    }

    final outputId = buildStep.inputId.changeExtension('.ludyx_cache.json');
    await buildStep.writeAsString(outputId, jsonEncode(components));
  }
}
