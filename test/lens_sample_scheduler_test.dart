import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/lens_sample_scheduler.dart';

void main() {
  late DateTime now;
  late LensSampleScheduler scheduler;

  setUp(() {
    now = DateTime(2026);
    scheduler = LensSampleScheduler(now: () => now);
  });

  test('skips an in-flight capture and permits a later capture', () async {
    final Completer<void> pending = Completer<void>();
    int captures = 0;
    Future<void> capture() {
      captures++;
      return pending.future;
    }

    final Future<void> first = scheduler.request(capture);
    now = now.add(const Duration(milliseconds: 600));
    await scheduler.request(capture);
    expect(captures, 1);
    pending.complete();
    await first;
    now = now.add(const Duration(milliseconds: 400));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 2);
  });

  test(
      'hung capture times out and its late completion cannot release a new capture',
      () async {
    final first = Completer<void>();
    final second = Completer<void>();
    var captures = 0;
    final firstRequest = scheduler.request(() {
      captures++;
      return first.future;
    });
    now = now.add(const Duration(seconds: 3));
    final secondRequest = scheduler.request(() {
      captures++;
      return second.future;
    });
    expect(captures, 2);
    first.complete();
    await firstRequest;
    now = now.add(const Duration(milliseconds: 600));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 2);
    second.complete();
    await secondRequest;
  });

  test('cool and fast permits a capture at 500 ms', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture);
    now = now.add(const Duration(milliseconds: 500));
    await scheduler.request(capture);
    expect(captures, 2);
  });

  test('low adaptive fps stays at 500 ms without heat', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture);
    now = now.add(const Duration(milliseconds: 500));
    await scheduler.request(capture);
    expect(captures, 2);
  });

  test('720p analysis cap requires one second between starts', () async {
    int captures = 0;
    Future<void> capture() async {
      captures++;
    }

    await scheduler.request(capture, analysisCap720p: true);
    now = now.add(const Duration(milliseconds: 999));
    await scheduler.request(capture, analysisCap720p: true);
    expect(captures, 1);
    now = now.add(const Duration(milliseconds: 1));
    await scheduler.request(capture, analysisCap720p: true);
    expect(captures, 2);
  });

  test('a slow sample requires one second between starts', () async {
    int captures = 0;
    await scheduler.request(() async {
      captures++;
      now = now.add(const Duration(milliseconds: 500));
    });
    now = now.add(const Duration(milliseconds: 499));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 1);
    now = now.add(const Duration(milliseconds: 1));
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 2);
  });

  test('a failed sample releases the in-flight guard', () async {
    await expectLater(
      scheduler.request(() async => throw StateError('capture failed')),
      throwsStateError,
    );
    now = now.add(const Duration(milliseconds: 500));
    int captures = 0;
    await scheduler.request(() async {
      captures++;
    });
    expect(captures, 1);
  });
}
