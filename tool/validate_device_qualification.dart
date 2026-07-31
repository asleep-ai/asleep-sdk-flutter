import 'dart:convert';
import 'dart:io';

import 'src/device_qualification.dart';

void main(List<String> arguments) {
  final options = _parse(arguments);
  final evidencePath = options['evidence'];
  if (evidencePath == null) {
    stderr.writeln(
      'Usage: dart run tool/validate_device_qualification.dart '
      '--evidence <path> [--allow-incomplete] [--expected-*=<value>]',
    );
    exitCode = 64;
    return;
  }

  Object? evidence;
  try {
    evidence = jsonDecode(File(evidencePath).readAsStringSync());
  } on Object catch (error) {
    stderr.writeln('Could not read evidence: $error');
    exitCode = 1;
    return;
  }

  final errors = validateDeviceQualification(
    evidence,
    allowIncomplete: options.containsKey('allow-incomplete'),
    expectations: QualificationExpectations(
      commitSha: options['expected-commit'],
      packageVersion: options['expected-package-version'],
      flutterVersion: options['expected-flutter-version'],
      dartVersion: options['expected-dart-version'],
      androidNativeVersion: options['expected-android-native-version'],
      iosNativeVersion: options['expected-ios-native-version'],
      operator: options['expected-operator'],
    ),
  );
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('- $error');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln(
    options.containsKey('allow-incomplete')
        ? 'Device qualification evidence structure is valid.'
        : 'Device qualification evidence is release-ready.',
  );
}

Map<String, String?> _parse(List<String> arguments) {
  final result = <String, String?>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--')) continue;
    final equals = argument.indexOf('=');
    if (equals >= 0) {
      result[argument.substring(2, equals)] = argument.substring(equals + 1);
    } else if (index + 1 < arguments.length &&
        !arguments[index + 1].startsWith('--')) {
      result[argument.substring(2)] = arguments[++index];
    } else {
      result[argument.substring(2)] = null;
    }
  }
  return result;
}
