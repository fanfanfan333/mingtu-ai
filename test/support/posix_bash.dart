import 'dart:io';

/// Runs [path] as a POSIX bash and reports whether it is actually usable.
///
/// A mere file-existence check is not enough: on Windows
/// `C:\Windows\System32\bash.exe` exists but is only a WSL relay stub that
/// fails with `execvpe(/bin/bash) failed` when no WSL distribution is
/// installed. Only a successful probe counts.
bool _isUsableBash(String path) {
  if (path != 'bash' && !File(path).existsSync()) {
    return false;
  }
  try {
    final result = Process.runSync(path, ['-c', 'echo ok']);
    return result.exitCode == 0 && result.stdout.toString().trim() == 'ok';
  } on ProcessException {
    return false;
  } on FileSystemException {
    return false;
  }
}

/// Locates a genuinely usable POSIX bash interpreter.
///
/// Lookup order: `MINGTU_BASH` env var, well-known Git-for-Windows install
/// locations, the standard POSIX locations, and finally a bare `bash` lookup.
///
/// Windows `CreateProcess` resolves executables as "application directory →
/// current directory → System32 → Windows directory → PATH", so
/// `C:\Windows\System32` wins over `PATH` and the WSL stub shadows any Git
/// Bash entry added to `PATH`. That is why the absolute Git Bash paths are
/// tried before falling back to a bare `bash` resolution.
///
/// Returns `null` when no candidate can execute a trivial command, in which
/// case the caller must skip explicitly rather than silently pass.
String? findUsableBash() {
  final fromEnv = (Platform.environment['MINGTU_BASH'] ?? '').trim();
  final candidates = <String>[
    if (fromEnv.isNotEmpty) fromEnv,
    if (Platform.isWindows) ...<String>[
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
    ],
    '/bin/bash',
    '/usr/bin/bash',
    'bash',
  ];
  for (final candidate in candidates) {
    if (_isUsableBash(candidate)) {
      return candidate;
    }
  }
  return null;
}
