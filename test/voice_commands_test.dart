import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:test/test.dart';

void main() {
  test('emergency wins over generic help', () {
    expect(parseVoiceCommand('小途，我需要帮助'), VoiceCommand.emergency);
    expect(parseVoiceCommand('救命'), VoiceCommand.emergency);
    expect(parseVoiceCommand('能做什么'), VoiceCommand.help);
  });

  test('pause, resume, cancel, repeat, status, start', () {
    expect(parseVoiceCommand('暂停一下'), VoiceCommand.pause);
    expect(parseVoiceCommand('继续走'), VoiceCommand.resume);
    expect(parseVoiceCommand('取消任务'), VoiceCommand.cancel);
    expect(parseVoiceCommand('再说一遍'), VoiceCommand.repeat);
    expect(parseVoiceCommand('现在到哪了'), VoiceCommand.status);
    expect(parseVoiceCommand('带我去图书馆'), VoiceCommand.startLibrary);
    expect(parseVoiceCommand('今天天气怎么样'), VoiceCommand.unknown);
    expect(parseVoiceCommand(''), VoiceCommand.unknown);
  });

  // D1（安全）：急停口令。盲人遇险时最自然的喊法是一个字「停」，
  // 或「站住」「别动」。ASR 输出常带标点，归一化必须先去掉标点，
  // 否则「停。」永远精确匹配不上，用户会被回一句「没听清」。
  test('急停口令表驱动：单字「停」与复合急停词都必须判 pause', () {
    const List<String> emergencyStops = <String>[
      '停',
      '停。',
      '停！',
      '小途，停。',
      '站住',
      '别动',
      '停住',
      // 人在慌乱时会把同一个字重复喊出来，归一化去空白后是「停停」/「停停停」。
      '停停',
      '停停停',
      '停 停',
      // N6：「停一停」是最口语的短停说法，以前整条落 unknown。
      '停一停',
      '小途，停一停。',
    ];
    for (final String phrase in emergencyStops) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」是急停口令，必须判 pause，不能落到 unknown',
      );
    }
    // 反向锚点：不允许用裸 contains('停') 蒙对，否则「我要停车」会被
    // 误判成暂停（用户想停车，不是想暂停播报）。
    expect(
      parseVoiceCommand('我要停车'),
      VoiceCommand.unknown,
      reason: '「我要停车」不是急停口令，必须保持 unknown',
    );
    // N6 的反向锚点：加了「停一停」之后，「停车场」这类词仍然不得被判 pause。
    expect(
      parseVoiceCommand('停车场在哪'),
      isNot(VoiceCommand.pause),
      reason: '「停车场在哪」是在问路，加「停一停」不许把它带成暂停',
    );
  });

  // D6（过匹配）：复合急停词是裸 contains，于是「前面有停住的车吗」这种
  // 路况提问也会把导航暂停掉。问句里只保留单字「停」/「停停停」的急停，
  // 复合词必须先通过"不是问句"这道门。
  test('问句里的复合急停词不得抢占路况问答', () {
    const List<String> trafficQuestions = <String>[
      '前面有停住的车吗',
      '有站住的狗吗',
      // N4 不许把这些锚点打死：它们都没有句首命令，仍然不是急停。
      '前面有没有停住的车',
      '是不是该停住',
      '停在哪里',
    ];
    for (final String phrase in trafficQuestions) {
      expect(
        parseVoiceCommand(phrase),
        isNot(VoiceCommand.pause),
        reason: '「$phrase」是在问路况，不能把导航暂停（unknown 或 environment 都可以）',
      );
    }
    // 不回归：真正的急停复合词仍然必须是 pause（「站住！」带标点也要中）。
    const List<String> realStops = <String>['停住', '站住！', '别动', '快停'];
    for (final String phrase in realStops) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」是急停口令，问句豁免不能把它一起豁免掉',
      );
    }
  });

  // N2 + N4：问句豁免的两个漏洞。
  // N2：裸「么」把「这么/那么」全当问句 →「这么多台阶，站住」丢掉急停。
  // N4：命令在句首、后面顺口一问 →「站住，有人吗」被整条豁免掉。
  test('句首命令 + 顺口一问仍要急停，这么/那么不算问句', () {
    const List<String> headedStops = <String>[
      '站住，有人吗',
      '别动，有车吗',
      '停住，什么声音',
      '停住，前面有什么东西',
      '快停，是不是有台阶',
      // N2：这么/那么 是普通词，不是问句标记。
      '这么多台阶，站住',
      '那么多人，别动',
    ];
    for (final String phrase in headedStops) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」句首就是停的命令，后面那句顺口问不能把急停吃掉',
      );
    }
  });

  // D7（数据安全）：`contains('别动')` 抢在 `_isNegatedDelete` 之前，
  // 于是「别动我的录像」被判成 pause，用户想留证据却得不到任何回应。
  test('「别动我的录像」是保留录像，不是暂停', () {
    const List<String> keepRecording = <String>[
      '别动我的录像',
      '不要动录像',
      // N3：否定词 + 动词 + 录像 相邻才算「保留」。
      '别碰录像',
      '不要碰我的录音',
    ];
    for (final String phrase in keepRecording) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.saveRecording,
        reason: '「$phrase」是想保留录像，必须判 saveRecording',
      );
    }
    // N3：动词和录像之间隔着别的成分时，这是在喊急停，不是数据请求。
    // 判成 saveRecording 会播「已保存」，让盲人以为自己停住了。
    const List<String> realStopsWithRecordingTalk = <String>[
      '别碰我，我在录像',
      '不要动，我在录视频',
      '别动，我在录像',
      '停住别动，有录像',
    ];
    for (final String phrase in realStopsWithRecordingTalk) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」是急停，不能被当成「保留录像」而回一句已保存',
      );
    }
    // 不回归：不带录像时「别动」仍然是急停。
    expect(parseVoiceCommand('别动'), VoiceCommand.pause);
    // 不回归：D3 的两条否定删除仍然保留。
    expect(parseVoiceCommand('别删除录像'), VoiceCommand.saveRecording);
    expect(parseVoiceCommand('不要删除录像'), VoiceCommand.saveRecording);
  });

  // N1（P0）：不必 / 不需要 / 没必要 也是拒绝，之前漏在词表外，
  // 「不需要恢复导航」被 contains('恢复') 判成 resume，导航继续播报。
  // 「不需要」里没有连续的「不要」，所以必须单独列。
  test('不必/不需要/没必要 + 继续/恢复 必须判 pause', () {
    const List<String> refusals = <String>[
      '不必继续了',
      '不必恢复了',
      '不需要继续了',
      '不需要恢复导航',
      '没必要继续走了',
      '没必要恢复',
    ];
    for (final String phrase in refusals) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」是明确的拒绝，必须暂停，不能反转成 resume',
      );
    }
    // 不回归：正向恢复仍然是 resume；求助式仍然是 unknown（不能被词表吃掉）。
    expect(parseVoiceCommand('继续'), VoiceCommand.resume);
    expect(parseVoiceCommand('恢复导航'), VoiceCommand.resume);
    expect(parseVoiceCommand('我不知道怎么恢复导航'), VoiceCommand.unknown);
  });

  // D8（过匹配）：两处「疑问句被当成命令」。
  // 1) `_isNegatedContinue` 用裸 contains('不') → 「我不知道怎么恢复导航」
  //    被判 pause，用户正在求助，导航反被暂停。
  // 2) `_isNegatedDestination` 含「不要去」→「我要不要去图书馆」被判 cancel。
  test('求助式与自问式的疑问句不得被当成命令', () {
    expect(
      parseVoiceCommand('我不知道怎么恢复导航'),
      isNot(VoiceCommand.pause),
      reason: '用户在问怎么恢复，导航不能被暂停（落 unknown 可接受）',
    );
    expect(
      parseVoiceCommand('我要不要去图书馆'),
      isNot(VoiceCommand.cancel),
      reason: '用户在自问，不能撤回意图（落 unknown）',
    );
    // 不回归：真正的否定继续仍然是 pause。
    expect(parseVoiceCommand('别继续了'), VoiceCommand.pause);
    expect(parseVoiceCommand('不继续了'), VoiceCommand.pause);
    expect(parseVoiceCommand('不要继续走了'), VoiceCommand.pause);
    // 不回归：正向恢复仍然是 resume。
    expect(parseVoiceCommand('继续'), VoiceCommand.resume);
    expect(parseVoiceCommand('恢复导航'), VoiceCommand.resume);
    // 不回归：真正的否定目的地仍然是 cancel。
    expect(parseVoiceCommand('我不去图书馆了'), VoiceCommand.cancel);
    expect(parseVoiceCommand('别去图书馆'), VoiceCommand.cancel);
  });

  // D2（安全）：否定式的「继续/恢复」= 暂停。以前 contains('继续') 排在
  // 否定判断前面，结果「别继续了」被判成 resume，和用户意图完全相反。
  test('否定式不得反转成 resume', () {
    const List<String> negatedContinues = <String>[
      '别继续了',
      '不继续了',
      '不要继续走了',
    ];
    for (final String phrase in negatedContinues) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.pause,
        reason: '「$phrase」是否定式，必须暂停，不能反转成恢复',
      );
    }
    // 肯定式仍然必须恢复，否定判断不能吃掉正向口令。
    expect(parseVoiceCommand('继续走'), VoiceCommand.resume);
    // 只含「不」但与继续/恢复无关的句子不能被当成暂停。
    expect(parseVoiceCommand('我不知道'), VoiceCommand.unknown);
  });

  // D3（数据安全）：带否定的「删除录像」其实是「保留」。以前会真的删，
  // 用户想留下证据却被抹掉了。
  test('删除录像的否定式是保留，绝不能真删', () {
    const List<String> negatedDeletes = <String>[
      '别删除录像',
      '不要删除录像',
    ];
    for (final String phrase in negatedDeletes) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.saveRecording,
        reason: '「$phrase」是想保留录像，必须判 saveRecording',
      );
    }
    // 肯定式仍然必须删除。
    expect(parseVoiceCommand('删除录像'), VoiceCommand.deleteRecording);
  });

  // D4（安全）：目的地否定式是「撤回」，不是「出发」。以前「我不去图书馆了」
  // 里「不」「去」「了」被目的地隔开，穿过 cancel 分支的连续子串 '不去了'，
  // 落到 contains('图书馆')，App 于是带着刚说「不去」的用户出发。
  // 同一处还有两个方向要钉死：
  //   问句（在哪/多远）只打听信息，不能出发 → unknown；
  //   而正向分支不接受「目的地 + 移动动词」式收窄 —— 「图书馆」单说、
  //   「图书馆怎么走」都必须仍是 startLibrary，否则会退化成「没听清」。
  test('目的地否定式是撤回，不是出发', () {
    const List<String> negatedDestinations = <String>[
      '我不去图书馆了',
      '我不想去图书馆',
      '别去图书馆',
      '我不要去图书馆',
      '不用去图书馆',
    ];
    for (final String phrase in negatedDestinations) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.cancel,
        reason: '「$phrase」是拒绝目的地，必须撤回意图，不能判 startLibrary',
      );
    }
    // 正向锚点：肯定式绝不能因为新增的否定判断而被吃掉。
    // 「图书馆」单说 / 「图书馆怎么走」也是导航请求，不是信息问句，
    // 钉在这里防止以后有人再把正向分支收窄成「目的地 + 移动动词」。
    const List<String> positiveDestinations = <String>[
      '带我去图书馆',
      '我要去图书馆',
      '去图书馆',
      '我想去图书馆',
      '图书馆',
      '图书馆怎么走',
    ];
    for (final String phrase in positiveDestinations) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.startLibrary,
        reason: '「$phrase」是出发口令，必须仍判 startLibrary',
      );
    }
    // 问句组：问「在哪/多远」只是打听信息，既不能撤回也不能出发。
    const List<String> destinationQuestions = <String>[
      '我不知道图书馆在哪里',
      '图书馆在哪里',
      '图书馆多远',
    ];
    for (final String phrase in destinationQuestions) {
      expect(
        parseVoiceCommand(phrase),
        VoiceCommand.unknown,
        reason: '「$phrase」是问路句，不能判 cancel，也不能判 startLibrary',
      );
    }
  });
}
