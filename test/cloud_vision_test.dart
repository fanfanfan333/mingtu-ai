import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';

/// Cloud vision assist tests. Fixtures only: no real API call, no
/// real key, no real camera frame (a generated 1x1/synthetic PNG).

const String _okBody = '{"choices":[{"message":{"role":"assistant",'
    '"content":"画面中有一张桌子和两把椅子。"}}]}';

Uint8List _fakeImage(int bytes) =>
    Uint8List.fromList(List<int>.filled(bytes, 7));

CloudVisionClient _client({
  String proxy = 'https://proxy.example.test',
  VisionSender? sender,
  ImageDownsampler? downsampler,
  VisionRateLimiter? limiter,
}) =>
    CloudVisionClient(
      proxyBaseUrl: proxy,
      sender: sender ?? (Uri url, String body) async => _okBody,
      downsampler: downsampler ?? (Uint8List b, int d) async => b,
      limiter: limiter,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('model and request contract', () {
    test('model id is the exact lowercase qwen3.7-flash', () {
      expect(cloudVisionModelId, 'qwen3.7-flash');
      expect(cloudVisionModelId, cloudVisionModelId.toLowerCase());
    });

    test('request body pins model, token cap, thinking off, data URI',
        () {
      final Map<String, Object> body =
          buildVisionRequestBody(imageBase64: 'QUJD');
      expect(body['model'], 'qwen3.7-flash');
      expect(body['max_tokens'], 256);
      expect(body['enable_thinking'], false);
      final List<Object> messages = body['messages']! as List<Object>;
      final Map<String, Object> msg = messages.single as Map<String, Object>;
      final List<Object> content = msg['content']! as List<Object>;
      final Map<String, Object> image = content.first as Map<String, Object>;
      final Map<String, String> imageUrl =
          image['image_url']! as Map<String, String>;
      expect(imageUrl['url'], startsWith('data:image/png;base64,'));
      // The prompt itself forbids safety judgements.
      final Map<String, String> text = content.last as Map<String, String>;
      expect(text['text'], contains('不要判断道路是否安全'));
    });
  });

  group('downsample size math', () {
    test('landscape and portrait scale to the cap, small is untouched',
        () {
      final a = computeDownsampledSize(4000, 3000);
      expect(a.width, 768);
      expect(a.height, 576);
      final b = computeDownsampledSize(3000, 4000);
      expect(b.width, 576);
      expect(b.height, 768);
      final c = computeDownsampledSize(640, 480);
      expect(c.width, 640);
      expect(c.height, 480);
    });
  });

  group('rate limiter', () {
    test('first call passes, immediate retry blocked, later passes',
        () {
      final limiter = VisionRateLimiter();
      final t0 = DateTime(2026, 1, 1, 12);
      expect(limiter.tryAcquire(t0), isTrue);
      expect(
        limiter.tryAcquire(t0.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(
        limiter.tryAcquire(t0.add(const Duration(seconds: 21))),
        isTrue,
      );
    });
  });

  group('CloudVisionClient with fixture sender', () {
    test('not configured: no send, Chinese degrade announcement',
        () async {
      bool called = false;
      final client = _client(
        proxy: '',
        sender: (Uri url, String body) async {
          called = true;
          return _okBody;
        },
      );
      final result = await client.describe(imageBytes: _fakeImage(100));
      expect(called, isFalse);
      expect(result.failure, CloudVisionFailure.notConfigured);
      expect(result.speechText, contains('已降级为本地检测'));
    });

    test('ok: parses the description; request carries NO credential',
        () async {
      Uri? seenUrl;
      String? seenBody;
      final client = _client(sender: (Uri url, String body) async {
        seenUrl = url;
        seenBody = body;
        return _okBody;
      });
      final result = await client.describe(imageBytes: _fakeImage(100));
      expect(result.ok, isTrue);
      expect(result.description, contains('桌子'));
      expect(seenUrl!.path, '/vision');
      // The client has no key: no Authorization, no key field.
      expect(seenBody, isNot(contains('Authorization')));
      expect(seenBody, isNot(contains('Bearer')));
      expect(seenBody, isNot(contains('"key"')));
      final Map<String, Object?> sent =
          jsonDecode(seenBody!) as Map<String, Object?>;
      expect(sent['model'], 'qwen3.7-flash');
      expect(sent['max_tokens'], 256);
      expect(sent['enable_thinking'], false);
      // Spoken success is framed as unverified assist, never safety.
      expect(result.speechText, contains('不能当作道路安全判断'));
      expect(result.speechText, isNot(contains('可以安全')));
    });

    test('second call inside the interval is rate-limited, no resend',
        () async {
      int calls = 0;
      final client = _client(sender: (Uri url, String body) async {
        calls += 1;
        return _okBody;
      });
      final t0 = DateTime(2026, 1, 1, 12);
      expect((await client.describe(imageBytes: _fakeImage(10), now: t0)).ok,
          isTrue);
      final second = await client.describe(
        imageBytes: _fakeImage(10),
        now: t0.add(const Duration(seconds: 3)),
      );
      expect(second.failure, CloudVisionFailure.rateLimited);
      expect(calls, 1);
    });

    test('payload still too large after downsampling: skipped, no send',
        () async {
      bool called = false;
      final client = _client(
        sender: (Uri url, String body) async {
          called = true;
          return _okBody;
        },
        downsampler: (Uint8List b, int d) async =>
            _fakeImage(cloudVisionMaxImageBytes + 1),
      );
      final result = await client.describe(imageBytes: _fakeImage(10));
      expect(result.failure, CloudVisionFailure.imageTooLarge);
      expect(called, isFalse);
    });

    test('explicit timeout: a hanging request degrades with a '
        'timeout announcement, not silence', () async {
      final client = CloudVisionClient(
        proxyBaseUrl: 'https://proxy.example.test',
        sender: (Uri url, String body) =>
            Completer<String>().future, // never completes
        downsampler: (Uint8List b, int d) async => b,
        requestTimeout: const Duration(milliseconds: 60),
      );
      final result = await client.describe(imageBytes: _fakeImage(10));
      expect(result.failure, CloudVisionFailure.timeout);
      expect(result.speechText, contains('请求超时'));
      expect(result.speechText, contains('已降级为本地检测'));
    });

    test('transport failure -> network degrade, announced', () async {
      final client = _client(
        sender: (Uri url, String body) async =>
            throw Exception('socket closed'),
      );
      final result = await client.describe(imageBytes: _fakeImage(10));
      expect(result.failure, CloudVisionFailure.network);
      expect(result.speechText, contains('网络失败'));
      expect(result.speechText, contains('已降级为本地检测'));
    });

    test('upstream error object -> upstream degrade', () async {
      final client = _client(
        sender: (Uri url, String body) async =>
            '{"error":{"message":"model not found"}}',
      );
      final result = await client.describe(imageBytes: _fakeImage(10));
      expect(result.failure, CloudVisionFailure.upstream);
    });

    test('malformed success body -> badResponse degrade', () async {
      final client = _client(
        sender: (Uri url, String body) async => '{"unexpected":true}',
      );
      final result = await client.describe(imageBytes: _fakeImage(10));
      expect(result.failure, CloudVisionFailure.badResponse);
      expect(result.speechText, contains('已降级为本地检测'));
    });
  });

  group('real codec downsampler', () {
    test('a 128x64 PNG is really shrunk to a 32px longest edge',
        () async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 128, 64),
        ui.Paint()..color = const ui.Color(0xFF336699),
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(128, 64);
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      final Uint8List bytes = png!.buffer.asUint8List();

      final Uint8List small = await codecDownsampler(bytes, 32);
      final ui.Codec codec = await ui.instantiateImageCodec(small);
      final ui.FrameInfo frame = await codec.getNextFrame();
      expect(frame.image.width, 32);
      expect(frame.image.height, 16);
    });
  });

  group('failure announcements never claim verified safety', () {
    test('no failure text promises safety or verified detection', () {
      for (final CloudVisionFailure f in CloudVisionFailure.values) {
        final String text =
            CloudVisionResult.failed(f).speechText;
        expect(text, contains('本地检测'), reason: '$f');
        expect(text, isNot(contains('安全通过')), reason: '$f');
        expect(text, isNot(contains('已经验证')), reason: '$f');
      }
    });
  });
}
