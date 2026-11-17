abstract final class LudyxGeneratorUtils {
  static const _builtInTypes = {
    'String',
    'int',
    'double',
    'num',
    'bool',
    'void',
    'Null',
    'Never',
    'dynamic',
    'Object',
    'Record',
    'Symbol',
    'Type',
    'Enum',
    'List',
    'Map',
    'Set',
    'Iterable',
    'Future',
    'FutureOr',
    'Stream',
    'Function',
    'Widget',
  };

  /// Splits [input] by top-level commas, ignoring commas inside `<>`, `()`, `[]`, and `{}`.
  static List<String> splitTopLevelArgs(String input) {
    final result = <String>[];
    final depth = _DepthTracker();
    var start = 0;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == ',' && depth.isTopLevel) {
        result.add(input.substring(start, i).trim());
        start = i + 1;
      } else {
        depth.update(ch);
      }
    }

    final tail = input.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }

  /// Matches a top-level function type (e.g. `void Function(int a)?` or `T Function<T>(T)`),
  /// returning its [returnType] and raw [params] inside the parameter list.
  static ({String returnType, String params})? matchTopLevelFunction(
    String type,
  ) {
    final trimmed = type.trim();
    final depth = _DepthTracker();

    for (var i = 0; i < trimmed.length; i++) {
      if (depth.isTopLevel && trimmed.startsWith('Function', i)) {
        // Ensure 'Function' is a standalone keyword, not part of an identifier like 'MyFunction'
        final beforeOk = i == 0 || !_isIdentifierChar(trimmed[i - 1]);
        if (!beforeOk) {
          depth.update(trimmed[i]);
          continue;
        }

        var cursor = i + 'Function'.length;

        // Skip optional type parameters on generic functions: Function<T, R>(...)
        if (cursor < trimmed.length && trimmed[cursor] == '<') {
          final closeAngle = _findMatchingClose(trimmed, cursor, '<', '>');
          if (closeAngle == -1) return null;
          cursor = closeAngle + 1;
        }

        // Skip optional whitespace before '('
        while (cursor < trimmed.length && trimmed[cursor] == ' ') {
          cursor++;
        }

        if (cursor < trimmed.length && trimmed[cursor] == '(') {
          final closeParen = _findMatchingClose(trimmed, cursor, '(', ')');
          if (closeParen == -1) return null;

          // Ensure nothing follows except an optional nullable '?'
          final suffix = trimmed.substring(closeParen + 1).trim();
          if (suffix.isEmpty || suffix == '?') {
            return (
              returnType: trimmed.substring(0, i).trim(),
              params: trimmed.substring(cursor + 1, closeParen),
            );
          }
        }
      }
      depth.update(trimmed[i]);
    }
    return null;
  }

  /// Returns the index of the first top-level [target] character, or `-1` if not found.
  static int findTopLevelChar(String input, String target) {
    assert(target.length == 1, 'target must be a single character');
    final depth = _DepthTracker();

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == target && depth.isTopLevel) return i;
      depth.update(ch);
    }
    return -1;
  }

  /// Heuristic check for whether [token] represents a type rather than a parameter name.
  static bool looksLikeTypeOnly(String token) {
    var clean = token.trim();
    if (clean.endsWith('?')) {
      clean = clean.substring(0, clean.length - 1).trim();
    }
    if (clean.isEmpty) return false;
    if (_builtInTypes.contains(clean)) return true;
    if (clean.contains('<') || clean.contains('(')) return true;

    // Check if it's a PascalCase identifier (e.g., CustomModel or prefix.CustomModel)
    final lastDot = clean.lastIndexOf('.');
    final typeName = lastDot == -1 ? clean : clean.substring(lastDot + 1);
    return typeName.isNotEmpty &&
        typeName[0].toUpperCase() == typeName[0] &&
        typeName[0].toLowerCase() != typeName[0];
  }

  /// Splits a parameter declaration (without default value or modifiers) into [type] and [name].
  static ({String type, String? name}) splitTypeAndName(String param) {
    final trimmed = param.trim();
    final lastSpaceIndex = _findLastTopLevelSpace(trimmed);

    if (lastSpaceIndex == -1) {
      return (type: trimmed, name: null);
    }

    final left = trimmed.substring(0, lastSpaceIndex).trim();
    final right = trimmed.substring(lastSpaceIndex + 1).trim();

    // Handle cases like `void Function(int)` where `Function(int)` is part of the type
    if (right.startsWith('Function(') ||
        right.startsWith('Function<') ||
        right.endsWith('>') ||
        right.endsWith(')') ||
        right.endsWith(')?')) {
      return (type: trimmed, name: null);
    }

    return (type: left, name: right);
  }

  /// Extracts the parameter name from a raw Dart parameter declaration,
  /// falling back to `arg$fallbackIndex` for unnamed positional parameters (e.g., in typedefs).
  static String extractParamName(
    String rawParam, {
    required int fallbackIndex,
  }) {
    var p = rawParam.trim();

    // Strip leading parameter modifiers
    const modifiers = ['required ', 'covariant ', 'final ', 'var '];
    var stripped = true;
    while (stripped) {
      stripped = false;
      for (final mod in modifiers) {
        if (p.startsWith(mod)) {
          p = p.substring(mod.length).trimLeft();
          stripped = true;
        }
      }
    }

    // Strip default value (`= ...`)
    final eqIndex = findTopLevelChar(p, '=');
    if (eqIndex != -1) {
      p = p.substring(0, eqIndex).trim();
    }

    final (:type, :name) = splitTypeAndName(p);

    if (name == null) {
      return looksLikeTypeOnly(type)
          ? 'arg$fallbackIndex'
          : _stripFieldPrefix(type);
    }

    return _stripFieldPrefix(name);
  }

  /// Returns `true` if [type] ends with a top-level nullable `?` modifier.
  static bool hasTopLevelNullableSuffix(String type) {
    final trimmed = type.trim();
    if (!trimmed.endsWith('?')) return false;

    final depth = _DepthTracker();
    for (var i = 0; i < trimmed.length - 1; i++) {
      depth.update(trimmed[i]);
    }
    return depth.isTopLevel;
  }

  // --- Private Helpers ---

  static String _stripFieldPrefix(String identifier) {
    if (identifier.startsWith('this.')) return identifier.substring(5);
    if (identifier.startsWith('super.')) return identifier.substring(6);
    return identifier;
  }

  static int _findLastTopLevelSpace(String input) {
    final depth = _DepthTracker();
    var lastSpaceIndex = -1;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == ' ' && depth.isTopLevel) {
        lastSpaceIndex = i;
      } else {
        depth.update(ch);
      }
    }
    return lastSpaceIndex;
  }

  static int _findMatchingClose(
    String input,
    int openIndex,
    String openChar,
    String closeChar,
  ) {
    var depth = 0;
    for (var i = openIndex; i < input.length; i++) {
      final ch = input[i];
      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) return i;
      }
    }
    return -1;
  }

  static bool _isIdentifierChar(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 65 && code <= 90) || // A-Z
        (code >= 97 && code <= 122) || // a-z
        (code >= 48 && code <= 57) || // 0-9
        code == 95 || // _
        code == 36; // $
  }
}

class _DepthTracker {
  int angle = 0;
  int paren = 0;
  int bracket = 0;
  int brace = 0;

  bool get isTopLevel => angle == 0 && paren == 0 && bracket == 0 && brace == 0;

  void update(String ch) {
    switch (ch) {
      case '<':
        angle++;
      case '>':
        angle--;
      case '(':
        paren++;
      case ')':
        paren--;
      case '[':
        bracket++;
      case ']':
        bracket--;
      case '{':
        brace++;
      case '}':
        brace--;
    }
  }
}
