#!/usr/bin/env fvm dart
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const appName = 'ServerBox';

const buildDataFilePath = 'lib/data/res/build_data.dart';
const apkPath = 'build/app/outputs/flutter-apk/app-release.apk';
const appleXCConfigPath = 'Runner.xcodeproj/project.pbxproj';

var regAppleProjectVer = RegExp(r'CURRENT_PROJECT_VERSION = .+;');
var regAppleMarketVer = RegExp(r'MARKETING_VERSION = .+');

const buildFuncs = {
  'ios': flutterBuildIOS,
  'android': flutterBuildAndroid,
  'macos': flutterBuildMacOS,
};

int? build;

Future<ProcessResult> fvmRun(List<String> args) async {
  return await Process.run('fvm', args, runInShell: true);
}

Future<void> getGitCommitCount() async {
  final result = await Process.run('git', ['log', '--oneline']);
  build = (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<void> writeStaicConfigFile(
    Map<String, dynamic> data, String className, String path) async {
  final buffer = StringBuffer();
  buffer.writeln('// This file is generated by ./make.dart');
  buffer.writeln('');
  buffer.writeln('class $className {');
  for (var entry in data.entries) {
    final type = entry.value.runtimeType;
    final value = json.encode(entry.value);
    buffer.writeln('  static const $type ${entry.key} = $value;');
  }
  buffer.writeln('}');
  await File(path).writeAsString(buffer.toString());
}

Future<int> getGitModificationCount() async {
  final result =
      await Process.run('git', ['ls-files', '-mo', '--exclude-standard']);
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<String> getFlutterVersion() async {
  final result = await fvmRun(['flutter', '--version']);
  final stdout = result.stdout as String;
  return stdout.split('\n')[0].split('•')[0].split(' ')[1].trim();
}

Future<Map<String, dynamic>> getBuildData() async {
  final data = {
    'name': appName,
    'build': build,
    'engine': await getFlutterVersion(),
    'buildAt': DateTime.now().toString(),
    'modifications': await getGitModificationCount(),
  };
  return data;
}

String jsonEncodeWithIndent(Map<String, dynamic> json) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(json);
}

Future<void> updateBuildData() async {
  print('Updating BuildData...');
  final data = await getBuildData();
  print(jsonEncodeWithIndent(data));
  await writeStaicConfigFile(data, 'BuildData', buildDataFilePath);
}

Future<void> dartFormat() async {
  final result = await fvmRun(['dart', 'format', '.']);
  print(result.stdout);
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
}

void flutterRun(String? mode) {
  Process.start(
      'fvm', mode == null ? ['flutter', 'run'] : ['flutter', 'run', '--$mode'],
      mode: ProcessStartMode.inheritStdio, runInShell: true);
}

Future<void> flutterBuild(String buildType) async {
  final args = [
    'build',
    buildType,
    '--build-number=$build',
    '--build-name=1.0.$build',
  ];
  final skslPath = '$buildType.sksl.json';
  if (await File(skslPath).exists()) {
    args.add('--bundle-sksl-path=$skslPath');
  }
  final isAndroid = 'apk' == buildType;
  // [--target-platform] only for Android
  if (isAndroid) {
    args.addAll([
      '--target-platform=android-arm64',
    ]);
  }
  print('\n[$buildType]\nBuilding with args: ${args.join(' ')}');
  final buildResult = await fvmRun(['flutter', ...args]);
  final exitCode = buildResult.exitCode;

  if (exitCode != 0) {
    print(buildResult.stdout);
    print(buildResult.stderr);
    print('\nBuild failed with exit code $exitCode');
    exit(exitCode);
  }
}

Future<void> flutterBuildIOS() async {
  await flutterBuild('ipa');
}

Future<void> flutterBuildMacOS() async {
  await flutterBuild('macos');
}

Future<void> flutterBuildAndroid() async {
  await flutterBuild('apk');
  await killJava();
  await scp2CDN();
}

Future<void> scp2CDN() async {
  final result = await Process.run(
    'scp',
    [apkPath, 'hk:/var/www/res/serverbox/apks/$build.apk'],
    runInShell: true,
  );
  print(result.stdout);
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
}

Future<void> changeAppleVersion() async {
  for (final path in ['ios', 'macos']) {
    final file = File('$path/$appleXCConfigPath');
    final contents = await file.readAsString();
    final newContents = contents
        .replaceAll(regAppleMarketVer, 'MARKETING_VERSION = 1.0.$build;')
        .replaceAll(regAppleProjectVer, 'CURRENT_PROJECT_VERSION = $build;');
    await file.writeAsString(newContents);
  }
}

Future<void> killJava() async {
  final result = await Process.run('ps', ['-A']);
  final lines = (result.stdout as String).split('\n');
  for (final line in lines) {
    if (line.contains('java')) {
      final pid = line.split(' ')[0];
      print('Killing java process: $pid');
      await Process.run('kill', [pid]);
    }
  }
}

void main(List<String> args) async {
  if (args.isEmpty) {
    print('No action. Exit.');
    return;
  }

  final command = args[0];

  switch (command) {
    case 'build':
      final stopwatch = Stopwatch()..start();
      await dartFormat();
      await getGitCommitCount();
      // always change version to avoid dismatch version between different
      // platforms
      await changeAppleVersion();
      await updateBuildData();
      if (args.length > 1) {
        final platforms = args[1];
        for (final platform in platforms.split(',')) {
          if (buildFuncs.keys.contains(platform)) {
            await buildFuncs[platform]!();
            print('Build finished in [${stopwatch.elapsed}]');
            stopwatch.reset();
            stopwatch.start();
          } else {
            print('Unknown platform: $platform');
          }
        }

        return;
      }
      for (final func in buildFuncs.values) {
        await func();
      }
      print('Build finished in ${stopwatch.elapsed}\n');
      return;
    default:
      print('Unsupported command: $command');
      return;
  }
}
