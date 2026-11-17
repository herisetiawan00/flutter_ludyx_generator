import 'package:build/build.dart';
import 'package:flutter_ludyx_generator/src/ludyx_aggregator_generator.dart';
import 'package:flutter_ludyx_generator/src/ludyx_collector_builder.dart';
import 'package:flutter_ludyx_generator/src/ludyx_lua_builder.dart';
import 'package:source_gen/source_gen.dart';

Builder ludyxCollectorBuilder(BuilderOptions options) =>
    LudyxCollectorBuilder();

Builder ludyxAggregatorBuilder(BuilderOptions options) =>
    LibraryBuilder(LudyxAggregatorGenerator(), generatedExtension: '.ldx.dart');

Builder ludyxLuaBuilder(BuilderOptions options) {
  final outputPath =
      options.config['output_path'] as String? ?? 'assets/lua/components.lua';
  return LudyxLuaBuilder(outputPath: outputPath);
}
