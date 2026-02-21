import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../models/linux_environment.dart';
import '../models/python_package.dart';
import '../models/execution_result.dart';

class LinuxEnvironmentService {
  static const _channel       = MethodChannel('com.pyom/linux_environment');
  static const _outputChannel = EventChannel('com.pyom/process_output');

  LinuxEnvironment? _currentEnvironment;
  StreamSubscription? _outputSubscription;
  final _outputController   = StreamController<String>.broadcast();
  final _statsController    = StreamController<EnvironmentStats>.broadcast();
  final _progressController = StreamController<SetupProgress>.broadcast();

  Stream<String>          get outputStream   => _outputController.stream;
  Stream<EnvironmentStats>get statsStream    => _statsController.stream;
  Stream<SetupProgress>   get progressStream => _progressController.stream;

  LinuxEnvironment? get currentEnvironment => _currentEnvironment;
  bool get isEnvironmentReady => _currentEnvironment?.isReady ?? false;

  // ─── PATHS ─────────────────────────────────────────────────────────────────
  //
  // CRITICAL: _envRoot must use EXTERNAL storage to match Kotlin's envRoot.
  //
  // Kotlin:  getExternalFilesDir(null)
  //        = /storage/emulated/0/Android/data/com.pyom/files/
  //
  // Dart:    getApplicationDocumentsDirectory() on Android
  //        → maps to getExternalFilesDir(null) via path_provider plugin
  //        = /storage/emulated/0/Android/data/com.pyom/files/  ✅ MATCH
  //
  // OLD BUG: getApplicationSupportDirectory() → filesDir (INTERNAL /data/data/...)
  //          = completely different path → isEnvironmentInstalled always false
  //          → app asked to reinstall on every launch
  //
  String? _externalDir;   // external storage — linux_env rootfs lives here
  String? _internalDir;   // internal storage — projects, bin metadata

  Future<String> get _envRoot async {
    _externalDir ??= (await getApplicationDocumentsDirectory()).path;
    return path.join(_externalDir!, 'linux_env');
  }

  Future<String> get _projectsDir async {
    _internalDir ??= (await getApplicationSupportDirectory()).path;
    return path.join(_internalDir!, 'projects');
  }

  // ─── INIT ──────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    _externalDir = (await getApplicationDocumentsDirectory()).path;
    _internalDir = (await getApplicationSupportDirectory()).path;

    // linux_env on external (matches Kotlin extDir)
    await Directory(path.join(_externalDir!, 'linux_env')).create(recursive: true);
    // projects + bin on internal
    await Directory(path.join(_internalDir!, 'projects')).create(recursive: true);
    await Directory(path.join(_internalDir!, 'bin')).create(recursive: true);

    _outputSubscription = _outputChannel.receiveBroadcastStream().listen(
      (data) => _outputController.add(data.toString()),
      onError: (e) => _outputController.addError(e),
    );

    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onSetupProgress':
        final message  = call.arguments['message']  as String? ?? '';
        final progress = (call.arguments['progress'] as num?)?.toDouble() ?? 0.0;
        _progressController.add(SetupProgress(message: message, progress: progress));
      case 'onProotUpdated':
        final version = call.arguments['version'] as String? ?? 'unknown';
        _progressController.add(SetupProgress(
          message: '🔄 proot v$version', progress: -1,
        ));
      case 'onOutput':
        _outputController.add(call.arguments.toString());
      case 'onStatsUpdate':
        if (call.arguments is Map) {
          final m = call.arguments as Map;
          _statsController.add(EnvironmentStats(
            cpuUsage:     (m['cpu']       ?? 0.0).toDouble(),
            memoryUsage:  (m['memory']    ?? 0.0).toDouble(),
            diskUsage:    (m['disk']      ?? 0.0).toDouble(),
            processCount: (m['processes'] ?? 0).toInt(),
            timestamp:    DateTime.now(),
          ));
        }
    }
  }

  // ─── ENVIRONMENT CHECK ─────────────────────────────────────────────────────

  Future<bool> checkEnvironmentInstalled(String envId) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isEnvironmentInstalled', {'envId': envId},
      );
      return result ?? false;
    } catch (_) {
      // Fallback: check filesystem directly
      final root   = await _envRoot;
      final envDir = Directory(path.join(root, envId));
      if (!await envDir.exists()) return false;
      // Check sh OR busybox (Alpine uses busybox)
      return await File(path.join(envDir.path, 'bin', 'sh')).exists()
          || await File(path.join(envDir.path, 'usr', 'bin', 'sh')).exists()
          || await File(path.join(envDir.path, 'bin', 'busybox')).exists();
    }
  }

  // ─── INSTALL ENVIRONMENT ───────────────────────────────────────────────────

  Future<LinuxEnvironment> installEnvironment(LinuxEnvironment env) async {
    try {
      env.status = EnvironmentStatus.downloading;
      final result = await _channel.invokeMethod('setupEnvironment', {
        'distro': env.distribution,
        'envId':  env.id,
      });
      if (result is Map && result['success'] == true) {
        env.status      = EnvironmentStatus.ready;
        env.installedAt = DateTime.now();
        _currentEnvironment = env;
      } else {
        throw Exception('Setup returned no success flag');
      }
      return env;
    } on PlatformException catch (e) {
      env.status = EnvironmentStatus.error;
      env.errorMessage = e.message ?? 'Platform error';
      rethrow;
    } catch (e) {
      env.status = EnvironmentStatus.error;
      env.errorMessage = e.toString();
      rethrow;
    }
  }

  // ─── EXECUTE COMMAND ───────────────────────────────────────────────────────

  Future<ExecutionResult> executeInEnvironment(
    LinuxEnvironment env,
    String command, {
    String workingDir = '/',
    Duration timeout  = const Duration(minutes: 10),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await _channel.invokeMethod('executeCommand', {
        'environmentId': env.id,   // Kotlin reads 'environmentId'
        'command':       command,
        'workingDir':    workingDir,
        'timeoutMs':     timeout.inMilliseconds,
      });
      sw.stop();
      return ExecutionResult(
        output:        (result['stdout'] ?? '') as String,
        error:         (result['stderr'] ?? '') as String,
        exitCode:      (result['exitCode'] ?? -1) as int,
        executionTime: sw.elapsed,
      );
    } on PlatformException catch (e) {
      sw.stop();
      return ExecutionResult(
        output: '', error: e.message ?? 'Error',
        exitCode: -1, executionTime: sw.elapsed,
      );
    }
  }

  // ─── PYTHON EXECUTION ──────────────────────────────────────────────────────
  //
  // Scripts are written to INTERNAL storage but bound into proot as /pdata/
  // (Kotlin binds: -b filesDir:/pdata)
  // chrootPath references /pdata/tmp/script.py inside proot.
  //

  Future<ExecutionResult> executePythonCode(
    String code, {
    Duration timeout = const Duration(minutes: 30),
  }) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(
        output: '', exitCode: -1, executionTime: Duration.zero,
        error: 'No Linux environment configured. Install one from Settings.',
      );
    }

    // Write script to internal filesDir/tmp (NOT envRoot)
    // Kotlin binds filesDir → /pdata inside proot
    final internalDir  = await getApplicationSupportDirectory();
    final tmpDir       = Directory(path.join(internalDir.path, 'tmp'));
    await tmpDir.create(recursive: true);

    final tmpFile = File(path.join(tmpDir.path, 'script_${DateTime.now().millisecondsSinceEpoch}.py'));
    await tmpFile.writeAsString(code);

    // Path as seen from inside proot: /pdata/tmp/filename.py
    final chrootPath = '/pdata/tmp/${path.basename(tmpFile.path)}';

    final result = await executeInEnvironment(
      _currentEnvironment!,
      'python3 "$chrootPath" 2>&1',
      workingDir: '/tmp',
      timeout:    timeout,
    );

    try { await tmpFile.delete(); } catch (_) {}
    return result;
  }

  // ─── PACKAGES ──────────────────────────────────────────────────────────────

  Future<List<PythonPackage>> listInstalledPackages() async {
    if (_currentEnvironment == null) return [];
    final result = await executeInEnvironment(
      _currentEnvironment!,
      'pip3 list --format=json 2>/dev/null || pip list --format=json 2>/dev/null',
    );
    if (!result.isSuccess) return [];
    try {
      final packages = jsonDecode(result.output) as List<dynamic>;
      return packages.map((p) => PythonPackage(
        name: p['name'] as String, version: p['version'] as String, isInstalled: true,
      )).toList();
    } catch (_) { return []; }
  }

  Future<ExecutionResult> installPackage(String packageName, {String? version}) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment', exitCode: -1, executionTime: Duration.zero);
    }
    final spec = version != null ? '$packageName==$version' : packageName;
    return executeInEnvironment(
      _currentEnvironment!,
      'pip3 install $spec --break-system-packages 2>&1 || pip3 install $spec 2>&1',
      timeout: const Duration(minutes: 60),
    );
  }

  Future<ExecutionResult> uninstallPackage(String packageName) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment', exitCode: -1, executionTime: Duration.zero);
    }
    return executeInEnvironment(_currentEnvironment!, 'pip3 uninstall -y $packageName');
  }

  // ─── GENERIC COMMAND ───────────────────────────────────────────────────────

  Future<ExecutionResult> runCommand(String command, {int timeoutMs = 120000}) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment', exitCode: -1, executionTime: Duration.zero);
    }
    return executeInEnvironment(
      _currentEnvironment!, command,
      timeout: Duration(milliseconds: timeoutMs),
    );
  }

  // ─── LLM MODELS ────────────────────────────────────────────────────────────

  Future<ExecutionResult> runLlamaModel(
    String modelPath, {
    String prompt      = '',
    int    maxTokens   = 256,
    double temperature = 0.7,
    String backend     = 'llama_cpp_python',
  }) async {
    if (_currentEnvironment == null) {
      return ExecutionResult(output: '', error: 'No environment', exitCode: -1, executionTime: Duration.zero);
    }

    final safe = prompt
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\$', '\\\$');

    String script, pkgName;
    if (backend == 'ctransformers') {
      pkgName = 'ctransformers';
      script  = '''
from ctransformers import AutoModelForCausalLM
llm = AutoModelForCausalLM.from_pretrained(
    "$modelPath", model_type="llama",
    config={"max_new_tokens": $maxTokens, "temperature": $temperature, "context_length": 2048}
)
print(llm("$safe"), end="", flush=True)
''';
    } else {
      pkgName = 'llama-cpp-python';
      script  = '''
from llama_cpp import Llama
llm = Llama(model_path="$modelPath", n_ctx=2048, n_threads=4, verbose=False)
out = llm("$safe", max_tokens=$maxTokens, temperature=$temperature,
          stop=["</s>", "<|end|>", "<|im_end|>"])
print(out["choices"][0]["text"], end="", flush=True)
''';
    }

    // Auto-install if needed
    final check = await executeInEnvironment(
      _currentEnvironment!, 'pip3 show $pkgName 2>/dev/null | grep -c Name');
    if (check.output.trim() == '0' || check.output.trim().isEmpty) {
      await executeInEnvironment(
        _currentEnvironment!,
        'pip3 install $pkgName --break-system-packages 2>&1 || pip3 install $pkgName 2>&1',
        timeout: const Duration(minutes: 45),
      );
    }

    return executePythonCode(script);
  }

  // ─── FILE / STORAGE ────────────────────────────────────────────────────────

  Future<String?> saveFileToDownloads(String sourcePath, String fileName) async {
    try {
      final result = await _channel.invokeMethod('saveFileToDownloads', {
        'sourcePath': sourcePath,
        'fileName':   fileName,
      });
      return result['path'] as String?;
    } on PlatformException catch (e) {
      throw Exception('Failed to save: ${e.message}');
    }
  }

  Future<void> shareFile(String filePath) async {
    try { await _channel.invokeMethod('shareFile', {'filePath': filePath}); }
    on PlatformException catch (e) { throw Exception('Failed to share: ${e.message}'); }
  }

  Future<Map<String, dynamic>> getStorageInfo() async {
    try {
      final result = await _channel.invokeMethod('getStorageInfo');
      return Map<String, dynamic>.from(result as Map);
    } catch (_) { return {}; }
  }

  Future<String> get projectsBasePath async => await _projectsDir;

  Future<void> createProjectDirectory(String projectId) async {
    await Directory(path.join(await _projectsDir, projectId)).create(recursive: true);
  }

  Future<void> writeProjectFile(String projectId, String fileName, String content) async {
    await File(path.join(await _projectsDir, projectId, fileName)).writeAsString(content);
  }

  Future<String> readProjectFile(String projectId, String fileName) async {
    return File(path.join(await _projectsDir, projectId, fileName)).readAsString();
  }

  Future<void> checkProotUpdate() async {
    try { await _channel.invokeMethod('checkProotUpdate'); } catch (_) {}
  }

  void setCurrentEnvironment(LinuxEnvironment env) => _currentEnvironment = env;

  void dispose() {
    _outputSubscription?.cancel();
    _outputController.close();
    _statsController.close();
    _progressController.close();
  }
}

class SetupProgress {
  final String message;
  final double progress;
  SetupProgress({required this.message, required this.progress});
}
