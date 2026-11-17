import 'dart:io';

/// The probe a candidate must survive: a trivial command (the
/// shell itself runs) PLUS every EXTERNAL tool
/// `tool/check_release_manifest.sh` can reach for.
///
/// Which externals, and why each one:
///  * `dirname`  -- line 3, `cd "$(dirname "$0")/.."`. Runs on EVERY
///    invocation, so without it the script dies before doing anything.
///  * `find`     -- line 14/16 (locate the merged manifest) and line 65
///    (locate `aapt`). Exercised by the zero-argument invocation.
///  * `sort -V`  -- line 65, picks the newest build-tools.
///  * `tail`     -- line 65, same pipeline.
///  * `grep -E`  -- line 68, scans `aapt dump permissions`.
///  * `python3`  -- line 23/72, the manifest/APK parser itself.
///
/// Why the externals at all: `echo` is a bash BUILT-IN, so a bash whose
/// PATH resolves to nothing at all still answers `echo ok`. On
/// this host the harness injects `BASH_ENV=...safe-delete-bash-env.sh`,
/// which rebuilds `PATH` and drops coreutils (`dirname: command
/// not found`) and leaves `python3` as a non-working Store stub
/// (rc 9009). Probing only `echo ok` therefore reported "usable",
/// the checker test ran, and it failed on the script's own line 3
/// instead of skipping -- exactly the "silently pass / fail
/// confusingly" outcome the contract below forbids.
///
/// `command -v` is itself a built-in, so each check genuinely asks "is
/// this tool on PATH", not "does bash exist".
const String _bashProbeCommand = 'echo ok'
    ' && command -v dirname >/dev/null'
    ' && command -v find >/dev/null'
    ' && command -v sort >/dev/null'
    ' && command -v tail >/dev/null'
    ' && command -v grep >/dev/null'
    ' && python3 -c "" >/dev/null 2>&1';

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
    final result = Process.runSync(path, ['-c', _bashProbeCommand]);
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
/// locations, the standard POSIX locations, and -- on non-Windows hosts
/// only -- a bare `bash` lookup.
///
/// Windows `CreateProcess` resolves executables as "application directory →
/// current directory → System32 → Windows directory → PATH", so
/// `C:\Windows\System32` wins over `PATH` and the WSL stub shadows any Git
/// Bash entry added to `PATH`. That is why the absolute Git Bash paths are
/// tried first, and why the bare `bash` fallback is skipped entirely on
/// Windows (probing it would launch the WSL relay stub -- useless at best,
/// a hard launch failure where wsl.exe is blocked).
///
/// Returns `null` when no candidate can run the probe in
/// [_bashProbeCommand] -- i.e. the shell AND every external tool the
/// manifest checker can reach for (`dirname`, `find`, `sort`, `tail`,
/// `grep`, `python3`) -- in which case the caller must skip explicitly
/// rather than silently pass or fail on a script that could never work
/// here.
String? findUsableBash() {
  final fromEnv = (Platform.environment['MINGTU_BASH'] ?? '').trim();
  final candidates = <String>[
    if (fromEnv.isNotEmpty) fromEnv,
    if (Platform.isWindows) ...<String>[
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
      // NOTE: the bare `bash` fallback is deliberately NOT offered on
      // Windows. CreateProcess resolves a bare `bash` to
      // C:\Windows\System32\bash.exe -- the WSL relay stub -- before any
      // PATH entry (see the shadowing note above), and PROBING it
      // launches wsl.exe: it can never run a POSIX script here, and on
      // some hosts launching wsl.exe is blocked outright, which turns a
      // "should skip" into a hard failure of the whole run. A Windows
      // host whose Git Bash lives somewhere unusual must point
      // MINGTU_BASH at it.
    ] else ...<String>[
      '/bin/bash',
      '/usr/bin/bash',
      'bash',
    ],
  ];
  for (final candidate in candidates) {
    if (_isUsableBash(candidate)) {
      return candidate;
    }
  }
  return null;
}
