import 'dart:async';
import 'package:flutter/material.dart';

import '../services/linux_environment_service.dart';
import './linux_environment_provider.dart';

class TerminalProvider extends ChangeNotifier {
  final LinuxEnvironmentProvider _linuxProvider;
  final LinuxEnvironmentService  _service;

  final List<TerminalLine> _lines           = [];
  final List<String>       _commandHistory  = [];
  final _inputController = StreamController<String>.broadcast();

  bool   _isReady      = false;
  bool   _isExecuting  = false;
  String _currentDir   = '~';
  String _prompt       = '~ \$ ';

  StreamSubscription? _outputSub;

  TerminalProvider(this._linuxProvider, this._service) {
    _initialize();
  }

  List<TerminalLine> get lines          => List.unmodifiable(_lines);
  List<String>       get commandHistory => List.unmodifiable(_commandHistory);
  bool               get isReady        => _isReady;
  bool               get isExecuting    => _isExecuting;
  String             get prompt         => _prompt;

  void _initialize() {
    _outputSub = _service.outputStream.listen(
      (out) => _add(out),
      onError: (e) => _add('Error: $e', type: TerminalLineType.error),
    );

    _add('┌─ Pyom Terminal ─────────────────────────────', type: TerminalLineType.system);
    _add('│  Linux environment loading…',                  type: TerminalLineType.system);
    _add('└──────────────────────────────────────────────', type: TerminalLineType.system);

    // Poll until environment is ready
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (_linuxProvider.isReady) {
        _isReady = true;
        _add('✅ Environment ready. Type help for commands.', type: TerminalLineType.system);
        _updatePrompt();
        t.cancel();
        notifyListeners();
      }
    });
  }

  void _add(String text, {TerminalLineType type = TerminalLineType.output}) {
    // Split multiline output into separate lines for proper rendering
    for (final line in text.split('\n')) {
      if (line.isEmpty && type == TerminalLineType.output) continue;
      _lines.add(TerminalLine(text: line, type: type, timestamp: DateTime.now()));
    }
    // Memory cap
    while (_lines.length > 2000) _lines.removeAt(0);
    notifyListeners();
  }

  void _updatePrompt() {
    _prompt = '$_currentDir \$ ';
    notifyListeners();
  }

  // ── Execute command ────────────────────────────────────────────────────────

  Future<void> executeCommand(String command) async {
    final cmd = command.trim();
    if (cmd.isEmpty) return;

    // Add to history (dedup consecutive)
    if (_commandHistory.isEmpty || _commandHistory.first != cmd) {
      _commandHistory.insert(0, cmd);
      if (_commandHistory.length > 100) _commandHistory.removeLast();
    }

    _add('$_prompt$cmd', type: TerminalLineType.input);
    _isExecuting = true;
    notifyListeners();

    try {
      if (_handleBuiltin(cmd)) {
        _isExecuting = false;
        notifyListeners();
        return;
      }

      final result = await _linuxProvider.executeCommand(cmd);

      if (result.output.trim().isNotEmpty) {
        _add(result.output.trimRight());
      }
      if (result.error.trim().isNotEmpty) {
        // Filter proot warnings from errors
        final err = result.error.trimRight();
        final isProotWarning = err.contains('proot warning:') || err.contains('proot info:');
        _add(err, type: isProotWarning ? TerminalLineType.warn : TerminalLineType.error);
      }
      if (result.exitCode != 0 && result.output.trim().isEmpty && result.error.trim().isEmpty) {
        _add('Exit code: ${result.exitCode}', type: TerminalLineType.warn);
      }

      // Update directory after cd
      if (cmd.startsWith('cd ') || cmd == 'cd') {
        await _updateDir();
      }
    } catch (e) {
      _add('Error: $e', type: TerminalLineType.error);
    } finally {
      _isExecuting = false;
      notifyListeners();
    }
  }

  bool _handleBuiltin(String cmd) {
    switch (cmd.toLowerCase()) {
      case 'clear':
      case 'cls':
        clear();
        return true;
      case 'exit':
        _add('Use the × button to close the terminal.', type: TerminalLineType.system);
        return true;
      case 'help':
        _add('''
┌─ Available commands ────────────────────────────
│  clear / cls    Clear terminal output
│  python3        Run Python interpreter
│  pip3 install   Install Python packages
│  ls / pwd / cd  File navigation
│  cat / nano     View / edit files
│  apt / apk      Package manager (distro)
│  help           Show this help
└─────────────────────────────────────────────────
  ↑ / ↓  Navigate command history''',
          type: TerminalLineType.system);
        return true;
      default:
        return false;
    }
  }

  Future<void> _updateDir() async {
    try {
      final r = await _linuxProvider.executeCommand('pwd');
      if (r.isSuccess && r.output.trim().isNotEmpty) {
        _currentDir = r.output.trim();
        _updatePrompt();
      }
    } catch (_) {}
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _inputController.close();
    _outputSub?.cancel();
    super.dispose();
  }
}

// ── Line types ─────────────────────────────────────────────────────────────

enum TerminalLineType { input, output, error, system, warn, info }

class TerminalLine {
  final String           text;
  final TerminalLineType type;
  final DateTime         timestamp;

  const TerminalLine({
    required this.text,
    required this.type,
    required this.timestamp,
  });
}
