import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_asr_client.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart'
    show visionTokenHeader;
import 'package:mingtu_ai/core/cloud_asr.dart';

/// Pure-logic and client tests for the cloud ASR fallback
/// (MT-1111-PTT): body shape, response parsing, truncation,
/// failure mapping. No network: every sender is a fixture.
void main() {
  group('cloud_asr pure logic', () {
    test('constants pin the model and the caps', () {
      expect(asrModelId, 'qwen3-asr-flash');
      expect(asrMaxRecordMs, 10000);
      expect(asrMaxAudioBytes, 400000);
      expect(asrMaxBodyBytes, 1048576);
    });

    test('buildAsrRequestBody has exactly the audio + format keys', () {
      final Map<String, Object?> body =
          buildAsrRequestBody(audioBase64: 'QUJD');
      expect(body.keys.toSet(), <String>{'audio', 'format'});
      expect(body['audio'], 'data:audio/wav;base64,QUJD');
      expect(body['format'], 'wav');
    });

    test('parseAsrResponse trims and returns the text', () {
      expect(parseAsrResponse(<String, Object?>{'text': '  去图书馆  '}),
          '去图书馆');
    });

    test('parseAsrResponse truncates beyond 200 chars', () {
      final String long = '字' * 250;
      final String? parsed =
          parseAsrResponse(<String, Object?>{'text': long});
      expect(parsed, isNotNull);
      expect(parsed!.length, asrMaxTranscriptChars);
    });

    test('parseAsrResponse returns null for missing/empty/non-string', () {
      expect(parseAsrResponse(<String, Object?>{}), isNull);
      expect(parseAsrResponse(<String, Object?>{'text': ''}), isNull);
      expect(parseAsrResponse(<String, Object?>{'text': '   '}), isNull);
      expect(parseAsrResponse(<String, Object?>{'text': 42}), isNull);
    });

    test('every failure detail is a fixed local text', () {
      for (final AsrFailure f in AsrFailure.values) {
        final String detail = asrFailureDetail(f);
        expect(detail, isNotEmpty, reason: '$f');
        // Fixed texts never carry upstream wording.
        expect(detail, isNot(contains('Exception')), reason: '$f');
      }
      expect(asrFailureDetail(AsrFailure.notConfigured),
          '云端识别未配置，无法识别。');
    });
  });

  group('CloudAsrClient', () {
    Uint8List clip([int n = 100]) =>
        Uint8List.fromList(List<int>.filled(n, 7));

    test('unconfigured client fails locally without calling the sender',
        () async {
      int calls = 0;
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: '',
        sender: (Uri url, String body, Map<String, String> headers) async {
          calls++;
          return '{}';
        },
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.ok, isFalse);
      expect(r.failure, AsrFailure.notConfigured);
      expect(calls, 0);
    });

    test('non-https base URL is refused as not configured', () async {
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'http://example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async =>
            '{}',
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.failure, AsrFailure.notConfigured);
    });

    test('oversize clip is refused before sending', () async {
      int calls = 0;
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'https://fc.example',
        sender: (Uri url, String body, Map<String, String> headers) async {
          calls++;
          return '{}';
        },
      );
      final CloudAsrResult r =
          await client.transcribe(clip(asrMaxAudioBytes + 1));
      expect(r.failure, AsrFailure.tooLarge);
      expect(calls, 0);
    });

    test('success: posts the two-key body to /asr with the token header',
        () async {
      Uri? seenUrl;
      Map<String, Object?>? seenBody;
      Map<String, String>? seenHeaders;
      Future<String> sender(
          Uri url, String body, Map<String, String> headers) async {
        seenUrl = url;
        seenBody = jsonDecode(body) as Map<String, Object?>;
        seenHeaders = headers;
        return jsonEncode(<String, Object?>{'text': '去图书馆'});
      }
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'https://fc.example/',
        demoToken: 'tok',
        sender: sender,
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.ok, isTrue);
      expect(r.text, '去图书馆');
      expect(seenUrl.toString(), 'https://fc.example/asr');
      expect(seenBody!.keys.toSet(), <String>{'audio', 'format'});
      expect(seenHeaders![visionTokenHeader], 'tok');
    });

    test('rate_limited maps to the rateLimited failure', () async {
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'https://fc.example',
        sender: (Uri url, String body, Map<String, String> headers) async =>
            jsonEncode(<String, Object?>{'error': 'rate_limited'}),
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.failure, AsrFailure.rateLimited);
    });

    test('server not-configured codes map to unavailable', () async {
      for (final String code in <String>[
        'asr_not_configured',
        'vision_not_configured',
        'unauthorized',
        // MT-1111-PTT-2 server WAV-validation codes map to
        // the same fixed unavailable failure.
        'audio format not allowed',
        'audio too long',
        'audio invalid',
      ]) {
        final CloudAsrClient client = CloudAsrClient(
          proxyBaseUrl: 'https://fc.example',
          sender:
              (Uri url, String body, Map<String, String> headers) async =>
                  jsonEncode(<String, Object?>{'error': code}),
        );
        final CloudAsrResult r = await client.transcribe(clip());
        expect(r.failure, AsrFailure.unavailable, reason: code);
      }
    });

    test('malformed success body maps to badResponse', () async {
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'https://fc.example',
        sender: (Uri url, String body, Map<String, String> headers) async =>
            jsonEncode(<String, Object?>{'unexpected': 1}),
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.failure, AsrFailure.badResponse);
    });

    test('a throwing sender maps to network, never leaks its text',
        () async {
      final CloudAsrClient client = CloudAsrClient(
        proxyBaseUrl: 'https://fc.example',
        sender: (Uri url, String body, Map<String, String> headers) async {
          throw StateError('boom-secret-fixture');
        },
      );
      final CloudAsrResult r = await client.transcribe(clip());
      expect(r.failure, AsrFailure.network);
      expect(r.detail, isNot(contains('boom')));
    });
  });
}
