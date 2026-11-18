/// Voice command parsing for Mingtu AI, blind-first.
///
/// This is the command layer that a real speech recogniser must feed.
/// It contains no ASR call itself: on a phone, the text comes from the
/// system recogniser (see adapters/voice_io.dart, NOT yet integrated);
/// in the demo UI it comes from the command input field, labelled as
/// a simulation. Parsing never changes task state by itself -- the
/// caller in main.dart checks the state machine before acting, so an
/// illegal voice command is answered, never silently applied.
///
/// Priority order matters: "我需要帮助" must win over a generic "帮助"
/// request, because emergency is the highest-priority speech kind.
library;

enum VoiceCommand {
  startLibrary,
  // 任意地点：「带我去药店」「去超市」「到地铁站」。以前只有 startLibrary
  // 一个目的地，用户说别的词全落 unknown（「没听清」），而 App 的说法是
  // 「只能在固定位置」——地名必须由用户自己说，见 parseDestinationPhrase。
  startPlace,
  pause,
  resume,
  cancel,
  repeat,
  status,
  help,
  emergency,
  // v0.5 blind-first additions: a blind user must be able to stop
  // immediately, confirm a step, ask what is ahead, and keep/delete
  // the recording -- all by voice, not by finding a button on screen.
  confirmStep,
  environment,
  // On-demand cloud vision: "看看前面" captures ONE frame and asks
  // the cloud to describe it (low frequency, spoken disclaimer).
  // It is an explicit trigger only -- never a background action.
  cloudVision,
  saveRecording,
  deleteRecording,
  enablePocketMode,
  disablePocketMode,
  unknown,
}

/// Characters dropped before matching: Chinese and English punctuation,
/// typographic quotes and every kind of whitespace.
///
/// The recogniser almost always returns a trailing stop mark ("停。" /
/// "停！"), so an exact match on a one-character command can only work
/// if punctuation is removed first. This also subsumes the old
/// `replaceAll('，', '')` / `replaceAll(',', '')` calls.
final RegExp _ignorableChars = RegExp(
  r'[\s。，、！？；：…·'
  r'「」『』（）【】《》〈〉'
  r'()\[\]{}'
  r'"“”'
  r"'‘’"
  r'.,!?;:`~'
  r']',
);

/// "停停停": a panicking user repeats the same character instead of
/// forming a word. Only 停 is allowed to repeat, so this can never match
/// a phrase that merely contains 停 ("我要停车", "停车场").
final RegExp _repeatedStop = RegExp(r'^停+$');

/// True when the text ends in / carries a question marker.
///
/// Used only to keep the emergency-stop COMPOUND words from stealing a
/// traffic question: "前面有停住的车吗" is a question about the road, not
/// an order to stop. The bare "停" and the repeated "停停停" deliberately
/// ignore this flag -- for an emergency stop a false positive is much
/// cheaper than a false negative.
///
/// N2: a bare "么" is NOT a question marker -- 这么/那么/多么 are ordinary
/// words, and "这么多台阶，站住" must still stop. Only unambiguous
/// interrogatives are listed; "停住了么" therefore stays a stop, which is
/// the safe direction.
bool _looksLikeQuestion(String text) =>
    text.contains('吗') ||
    text.contains('什么') ||
    text.contains('怎么') ||
    text.contains('为什么') ||
    text.contains('有没有') ||
    text.contains('是不是') ||
    text.contains('在哪');

/// True when the text negates continuing/resuming ("别继续了",
/// "不要继续走了").
///
/// The bare "不" is only accepted when it sits right next to the verb
/// ("不继续" / "不恢复"): "我不知道怎么恢复导航" is a request for help, and
/// reading it as "stop" would pause the navigation the user is asking
/// about. The other negation words are unambiguous enough to match at a
/// distance.
///
/// N1: 不必 / 不需要 / 没必要 are plain refusals too. They were missing
/// because "不需要" does not contain the contiguous string "不要".
bool _isNegatedContinue(String text) {
  if (!text.contains('继续') && !text.contains('恢复')) return false;
  if (text.contains('不继续') || text.contains('不恢复')) return true;
  return text.contains('别') ||
      text.contains('不要') ||
      text.contains('不用') ||
      text.contains('不想') ||
      text.contains('不必') ||
      text.contains('不需') ||
      text.contains('没必要') ||
      text.contains('没必须') ||
      text.contains('甭') ||
      text.contains('莫');
}

/// True when the user is asking HOW to resume ("怎么恢复" / "如何继续"),
/// which is a help request, not a resume order. Answering it with a
/// silent resume would restart navigation the user never asked to
/// restart, so the caller treats it as unknown and keeps the guided
/// "没听清 + 你可以说…" loop available.
bool _isHowToQuestion(String text) =>
    text.contains('怎么恢复') ||
    text.contains('如何恢复') ||
    text.contains('怎么继续') ||
    text.contains('如何继续') ||
    text.contains('怎么才能恢复');

/// "别动我的录像" / "别碰录像": the negation, the verb and the recording
/// noun must be ADJACENT.
///
/// N3: a bare 别动/别碰 is an emergency stop ("别碰我，我在录像"), and
/// answering it with "已保存" would tell a blind user they stopped when
/// they did not. Matching the three parts as one contiguous phrase is what
/// separates "don't touch my recording" from "don't touch, I'm recording".
final RegExp _negatedRecordingTouch = RegExp(
  r'(别|不要|不用|不想|甭)(动|碰)(我?的)?(录像|录音|视频)',
);

/// True when the text asks to KEEP the recording by negating a delete
/// ("别删除录像" / "不要删录像" / "别动我的录像"). Data-safe: keeping is the
/// default, deleting must always be spelled positively.
bool _isNegatedDelete(String text) {
  final bool mentionsRecording =
      text.contains('录像') || text.contains('录音') || text.contains('视频');
  final bool negatedDelete = text.contains('别删') ||
      text.contains('不要删') ||
      text.contains('不用删') ||
      text.contains('不想删') ||
      text.contains('不删') ||
      text.contains('别抹') ||
      text.contains('不要抹') ||
      _negatedRecordingTouch.hasMatch(text);
  return mentionsRecording && negatedDelete;
}

/// True when the utterance NEGATES going somewhere ("我不去药店了",
/// "别去药店"): the app must withdraw the intent, never start a trip
/// the user just refused. Narrow on purpose -- the negation word has to
/// sit right next to 去/到/想/用 ("不去" / "不想去" / "别去" / "不用去"),
/// so a sentence that merely contains 不 and a place, such as
/// "我不知道图书馆在哪里", is not read as a withdrawal.
///
/// Destination-agnostic: it used to hard-require 图书馆, which was fine
/// while the library was the only destination the app understood. Now
/// that any landmark can be a destination (see
/// [parseDestinationPhrase]), the negation has to be recognised for any
/// place name -- otherwise 「我不去药店了」 would fall through to the
/// free-destination branch and walk the user to the place they just
/// refused. [parseDestinationPhrase] is the other caller.
bool _isNegatedDeparture(String text) {
  // D8: "我要不要去图书馆" is the user thinking out loud, not refusing.
  // 要不要 embeds 不要, so it has to be excluded before the scan.
  if (text.contains('要不要')) return false;
  const List<String> negatedForms = <String>[
    '不去',
    '不想去',
    '不要去',
    '不要到',
    '不要回',
    '别去',
    '别到',
    '别回',
    '不用去',
    '不需要去',
    '不必去',
    '没必要去',
    '不打算去',
    '不准备去',
    '不想再去',
    '不再去',
    '没有必要去',
    '无需去',
    '甭去',
    '不会去',
  ];
  for (final String form in negatedForms) {
    if (text.contains(form)) return true;
  }
  return false;
}

/// The library-specific negation check kept for the existing
/// `startLibrary`/`cancel` branches (its behaviour and its tests are
/// unchanged: only a sentence that mentions 图书馆 can be a library
/// withdrawal).
bool _isNegatedDestination(String text) =>
    text.contains('图书馆') && _isNegatedDeparture(text);

/// True when the utterance is asking ABOUT the destination rather than
/// asking to go there ("图书馆在哪里" / "图书馆多远" / "图书馆是什么地方").
/// Such a sentence must not start a trip, but it must also stay a plain
/// "没听清"-free answer: it returns unknown so the caller can route it.
///
/// Note 怎么走 / 怎么去 is deliberately NOT listed: that is a navigation
/// request ("take me there"), so it keeps starting the trip.
bool _isDestinationQuestion(String text) {
  if (!text.contains('图书馆')) return false;
  const List<String> questionForms = <String>[
    '在哪',
    '哪里',
    '什么地方',
    '多远',
    '是什么',
    // D8: "我要不要去图书馆" is a question about the trip, so it lands on
    // unknown instead of falling through to the positive branch.
    '要不要',
  ];
  for (final String form in questionForms) {
    if (text.contains(form)) return true;
  }
  return false;
}

/// Longest place name accepted from speech. A longer "name" is a whole
/// sentence the recogniser handed over ("带我去今天天气怎么样"), and
/// searching the map for it would answer 「附近没有找到…」 to a user who
/// never asked to go anywhere. 20 characters covers real landmarks
/// ("北京大学第三医院") with room to spare.
const int maxSpokenDestinationLength = 20;

/// Prefixes that turn a place name into a "take me there" request.
/// MUST be tried longest first: a bare 去 would otherwise strip only
/// 去 from 「带我去药店」 and leave 带我药店 as the "place".
const List<String> _destinationPrefixes = <String>[
  '带我去',
  '我要去',
  '我想去',
  '想去',
  '要去',
  '去',
  '到',
];

/// Trailing punctuation and fillers the recogniser adds: 「去超市吧。」
/// must yield 超市, not 超市吧。
const String _trailingPunctuation = '。！？!?，,、；;：:…·~';
const String _trailingParticles = '了吧呢啊';

/// Words that belong to OTHER commands. A destination containing one of
/// them is not a place: 「去停下」 would otherwise send the user to a
/// landmark called 停下.
const List<String> _otherCommandWords = <String>[
  '停下',
  '暂停',
  '继续',
  '取消',
  '紧急',
  '求助',
  '下一步',
  '再说一遍',
  '状态',
];

/// Control, format (zero-width / bidi) and unassigned-ish codepoints. A
/// place name carrying them is never spoken data, only a broken or
/// hostile transcript.
final RegExp _controlCharacters = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060\ufeff]',
);

/// Strip trailing punctuation and the fillers 了/吧/呢/啊, repeatedly.
///
/// A trailing filler is only removed when at least TWO characters
/// remain afterwards, because 吧/了 are also word-final inside real
/// names (「网吧」「酒吧」): asking for 网吧 must not search the map for 网.
String _stripTrailingNoise(String value) {
  String text = value.trim();
  bool changed = true;
  while (changed && text.isNotEmpty) {
    changed = false;
    final String last = text[text.length - 1];
    if (_trailingPunctuation.contains(last) || last.trim().isEmpty) {
      text = text.substring(0, text.length - 1).trim();
      changed = true;
      continue;
    }
    if (_trailingParticles.contains(last) && text.length >= 3) {
      text = text.substring(0, text.length - 1).trim();
      changed = true;
    }
  }
  return text;
}

/// Strip leading punctuation and whitespace ("，带我去药店").
String _stripLeadingNoise(String value) {
  String text = value.trim();
  while (text.isNotEmpty &&
      (_trailingPunctuation.contains(text[0]) || text[0].trim().isEmpty)) {
    text = text.substring(1).trim();
  }
  return text;
}

/// True when the sentence asks WHETHER to go somewhere ("我要不要去
/// 药店") or is a question ("去药店吗" / "去药店？"). Such an utterance
/// is not an order to start walking, so it must not become a
/// destination. Deliberately NOT `_looksLikeQuestion`: 怎么走 / 怎么去
/// are navigation requests, not questions about the destination.
bool _asksWhetherToGo(String text) {
  if (text.contains('要不要')) return true;
  if (text.contains('吗')) return true;
  final String trimmed = text.trim();
  return trimmed.endsWith('?') || trimmed.endsWith('？');
}

/// Shared implementation of [parseDestinationPhrase] and
/// [sanitizeSpokenDestination].
///
/// [requirePrefix] is the whole difference between the two: the voice
/// COMMAND layer only accepts an explicit "take me there" shape
/// (otherwise every sentence would be a destination and the command
/// parser would collapse into "search the map for whatever I heard"),
/// while the destination QUESTION accepts a bare answer ("药店").
String? _destinationCore(String raw, {required bool requirePrefix}) {
  String text = raw.trim().replaceAll('小途', '').trim();
  if (text.isEmpty) return null;
  // A withdrawal is never an intent to go: 「我不去药店了」 must not be
  // read as a request for 药店 (same inversion as D4, generalised).
  if (_isNegatedDeparture(text)) return null;
  if (_asksWhetherToGo(text)) return null;
  // Leading punctuation only ("，带我去药店"): the TRAILING run must be
  // stripped AFTER the prefix, on the place name itself. Stripping it
  // first would eat the 吧 of 「带我去网吧」 and leave the place 网 --
  // the residual-length guard below can only work on the real name.
  text = _stripLeadingNoise(text);
  bool sawPrefix = false;
  for (final String prefix in _destinationPrefixes) {
    if (text.startsWith(prefix) && text.length > prefix.length) {
      text = text.substring(prefix.length).trim();
      sawPrefix = true;
      break;
    }
  }
  if (requirePrefix && !sawPrefix) return null;
  text = _stripTrailingNoise(text);
  if (text.isEmpty) return null;
  if (text.length > maxSpokenDestinationLength) return null;
  if (_controlCharacters.hasMatch(text)) return null;
  for (final String word in _otherCommandWords) {
    if (text.contains(word)) return null;
  }
  return text;
}

/// 从「带我去X」「去X」「到X」里取出 X；不是目的地意图时返回 null。
///
/// This is what makes 「带我去药店」(or any other landmark the user
/// names) a navigation request instead of "没听清". Returns null -- i.e.
/// "not a destination" -- for a negation, a question, a missing/empty
/// place, a name longer than [maxSpokenDestinationLength], a control
/// character, or a phrase that carries another command's words.
String? parseDestinationPhrase(String text) =>
    _destinationCore(text, requirePrefix: true);

/// 清洗「用户说出的一个地名」：允许裸地名（"药店"），也会剥掉礼貌前缀
/// （"我想去药店" → 药店）。否定、问句、空、超长、控制字符一律 null。
///
/// Used by the destination question, whose valid answer is just the
/// place name. Kept in this file so the command layer and the dialogue
/// layer cannot drift apart on what counts as a place.
String? sanitizeSpokenDestination(String raw) =>
    _destinationCore(raw, requirePrefix: false);

VoiceCommand parseVoiceCommand(String raw) {
  final String text = raw
      .trim()
      .replaceAll('小途', '')
      .replaceAll(_ignorableChars, '')
      .trim();
  if (text.isEmpty) return VoiceCommand.unknown;
  final negatedHelp = RegExp(r'(不需要|不需|不用|不想|无需|没必要)帮助').hasMatch(text);
  if (text.contains('救命') || text.contains('紧急') ||
      (text.contains('需要帮助') && !negatedHelp)) {
    return VoiceCommand.emergency;
  }
  // Data safety (D7): a negated delete runs BEFORE the stop words,
  // because "别动我的录像" contains 别动 (a stop word) but is a request to
  // KEEP the recording. Wrong direction here is expensive: the other
  // order pauses the navigation and never answers the data request.
  if (_isNegatedDelete(text)) {
    final remaining = text.replaceAll(_negatedRecordingTouch, '').replaceAll(
        RegExp(r'(不要|不用|不必|别|不)(再)?(停下|暂停|停住|站住|停一下|停一停|快停)'), '');
    if (RegExp(r'停下|暂停|停住|站住|快停|停一下|停一停|先别走|别走|别动|不要动|别碰|停+$')
        .hasMatch(remaining)) {
      return VoiceCommand.pause;
    }
    return VoiceCommand.saveRecording;
  }
  // Safety (D1): an emergency stop is the shortest, most natural thing a
  // blind user can shout -- one character, "停". Without this branch it
  // falls through to unknown and the app answers "没听清", i.e. it says
  // "I did not understand you" exactly when the user is in danger.
  //
  // Matching must stay precise: a bare `text.contains('停')` would also
  // swallow "我要停车" (I want to park) and turn it into a pause, so the
  // single character is an exact match and the rest are compound words.
  // `_repeatedStop` additionally accepts the panicked repeat "停停停"
  // (the single "停" case is covered by both spellings on purpose: the
  // literal comparison is the readable contract, the regex the extension).
  //
  // D6: the COMPOUND words additionally require that the sentence is not
  // a question -- "前面有停住的车吗" asks about the road, and pausing the
  // navigation there is a false stop. The bare 停 / 停停停 stay exempt on
  // purpose (false stop beats a missed stop).
  //
  // N4: a stop command at the HEAD of the sentence wins over the question
  // exemption. "站住，有人吗" is an order followed by an afterthought, not
  // a question about standing still; the punctuation that separated the
  // two halves is stripped by the normaliser, so the head check is the
  // only thing that still tells them apart.
  final bool hasStopCompound = text.contains('停住') ||
      text.contains('站住') ||
      text.contains('别动') ||
      text.contains('不要动') ||
      // N3: once 别碰 stopped meaning "keep my recording", the bare "别碰"
      // had no home at all and "别碰我，我在录像" answered "没听清".
      // Only 别碰 is listed: "不要碰我" stays unknown on purpose (out of
      // scope this round).
      text.contains('别碰') ||
      text.contains('快停') ||
      // N6: "停一停" is the most common colloquial short stop ("stop for a
      // moment"). It matched none of 停住/停下/停一下, so it fell through to
      // "没听清" -- same family as the missed single "停" in D1. The phrase
      // can only appear in a stop context, so there is no over-match risk.
      text.contains('停一停') ||
      text.contains('先别走');
  final bool startsWithStopCommand = text.startsWith('停住') ||
      text.startsWith('站住') ||
      text.startsWith('别动') ||
      text.startsWith('不要动') ||
      text.startsWith('别碰') ||
      text.startsWith('快停') ||
      text.startsWith('停一停') ||
      text.startsWith('先别走');
  final bool isEmergencyStop = text == '停' ||
      _repeatedStop.hasMatch(text) ||
      (hasStopCompound && (startsWithStopCommand || !_looksLikeQuestion(text)));
  if (isEmergencyStop) {
    return VoiceCommand.pause;
  }
  if (text.contains('暂停') ||
      text.contains('停一下') ||
      text.contains('先停下') ||
      text.contains('停下') ||
      text.contains('别走') ||
      text.contains('别走了')) {
    return VoiceCommand.pause;
  }
  // Safety (D2): "别继续了" / "不继续了" / "不要继续走了" mean STOP.
  // This check has to sit BEFORE the resume branch, otherwise
  // `contains('继续')` wins and the app does the exact opposite of what
  // the user asked (it resumes navigating and keeps talking).
  if (_isNegatedContinue(text)) {
    return VoiceCommand.pause;
  }
  // D8: "我不知道怎么恢复导航" is a request for help, not a resume order.
  if (_isHowToQuestion(text)) {
    return VoiceCommand.unknown;
  }
  if (RegExp(r'(不需要|没必要|不打算|不准备|不要|不用|不必|不想|无需|别|不)取消')
      .hasMatch(text)) {
    return VoiceCommand.unknown;
  }
  if (text.contains('继续') || text.contains('恢复')) {
    return VoiceCommand.resume;
  }
  if (text.contains('取消') || text.contains('不去了') || text.contains('结束任务')) {
    return VoiceCommand.cancel;
  }
  if (text.contains('再说一遍') || text.contains('重复') || text.contains('刚才说什么')) {
    return VoiceCommand.repeat;
  }
  if (text.contains('到哪') ||
      text.contains('现在在哪') ||
      text.contains('我在哪') ||
      text.contains('什么状态') ||
      text.contains('走到哪')) {
    return VoiceCommand.status;
  }
  if (text.contains('保存录像') || text.contains('保留录像') || text.contains('留着录像')) {
    return VoiceCommand.saveRecording;
  }
  // D3's negated-delete guard now lives at the top (D7), before the stop
  // words; keeping a second copy here would only be dead code.
  if (text.contains('删除录像') || text.contains('删掉录像') || text.contains('不要录像')) {
    return VoiceCommand.deleteRecording;
  }
  if (text.contains('确认') ||
      text.contains('我到了') ||
      text.contains('完成了') ||
      text.contains('下一步')) {
    return VoiceCommand.confirmStep;
  }
  if (text.contains('看看前面') ||
      text.contains('看一下前面') ||
      text.contains('看看前方') ||
      text.contains('看一下前方') ||
      text.contains('看看周围') ||
      text.contains('看一下周围') ||
      text.contains('看一下前面有什么')) {
    return VoiceCommand.cloudVision;
  }
  if (text.contains('前面有什么') ||
      text.contains('周围有什么') ||
      text.contains('附近有什么') ||
      text.contains('前面是什么')) {
    return VoiceCommand.environment;
  }
  // Safety (D4): "我不去图书馆了" / "别去图书馆" is a WITHDRAWAL.
  // The cancel branch above only recognises the contiguous string
  // "不去了"; in "我不去图书馆了" the characters 不/去/了 are separated
  // by the destination, so the sentence used to fall through to
  // `contains('图书馆')` and the app started walking the user to a place
  // they had just refused. Same family of inversion as D2/D3.
  if (_isNegatedDestination(text)) {
    return VoiceCommand.cancel;
  }
  // Asking ABOUT the destination is not asking to go there, so it must
  // not start a trip. Deliberately narrow: only information questions.
  if (_isDestinationQuestion(text)) {
    return VoiceCommand.unknown;
  }
  // Positive branch kept as it always was: merely naming the destination
  // is enough to start the trip. "图书馆" alone is a valid answer while
  // the destination question is open and a valid repeat request while a
  // task runs ("已有任务在进行…"), and "图书馆怎么走" is a navigation
  // request, not an information question -- narrowing this into
  // "library + movement verb" made all of those answer "没听清".
  if (text.contains('去图书馆') || text.contains('图书馆')) {
    return VoiceCommand.startLibrary;
  }
  if ((text.contains('帮助') && !negatedHelp) ||
      text.contains('能做什么') || text.contains('怎么用')) {
    return VoiceCommand.help;
  }
  if (text.contains('打开口袋') || text.contains('开启口袋模式')) {
    return VoiceCommand.enablePocketMode;
  }
  if (text.contains('关闭口袋') || text.contains('关掉口袋模式')) {
    return VoiceCommand.disablePocketMode;
  }
  // 任意地点（「带我去药店」「去超市」「到地铁站」）。LAST on purpose:
  // an explicit command word must win over a destination-shaped sentence,
  // so this sits after every concrete command and before `unknown`.
  // 图书馆 keeps its own branch above (startLibrary), which is pinned by
  // its own tests. A clause-less place name ("药店" with no 去/到) is NOT
  // a command here -- it answers the destination question instead, via
  // resolveSpokenDestination.
  if (parseDestinationPhrase(text) != null) {
    return VoiceCommand.startPlace;
  }
  return VoiceCommand.unknown;
}

String voiceCommandHelpText() => '你可以说：带我去图书馆、停下、暂停、继续、取消、再说一遍、'
    '现在到哪了、前面有什么、看看前面、确认、保存录像、删除录像、我需要帮助、打开口袋模式、关闭口袋模式。';

/// UI-A11Y S1 (UI-01): semantics labels of the big button
/// in TalkBack TOGGLE mode (MediaQuery.accessibleNavigation
/// on). Idle invites a double-tap to start; while a press
/// session is live the label says how to end it. The
/// hold-mode label stays in main.dart, unchanged.
const String talkBackToggleIdleLabel = '按住说话，双击开始';
const String talkBackToggleListeningLabel = '正在听，双击结束';
