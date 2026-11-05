import 'package:flutter/material.dart';
import 'core/task_manager.dart';

/// Mingtu AI v0.1 Flutter entry point.
///
/// Blind-first note: the screen is auxiliary. The primary interaction in
/// the full design is voice; this v0.1 screen only shows the current
/// task state and the honesty status, so a sighted reviewer can see what
/// is and is not implemented. It does not claim any real-road safety
/// validation. Voice, map SDK and on-device YOLO integrations are
/// NOT_IMPLEMENTED in this scaffold; see README.md.
void main() {
  runApp(const MingtuApp());
}

class MingtuApp extends StatelessWidget {
  const MingtuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '明途 AI v0.1',
      home: const MingtuHomePage(),
    );
  }
}

class MingtuHomePage extends StatefulWidget {
  const MingtuHomePage({super.key});

  @override
  State<MingtuHomePage> createState() => _MingtuHomePageState();
}

class _MingtuHomePageState extends State<MingtuHomePage> {
  final TaskManager _tasks = TaskManager();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('明途 AI v0.1（演示原型）')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '明途 AI：面向视障人士的校园出行辅助演示原型。',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 12),
            const Text(
              '本版本只做一个校园图书馆完整场景演示。'
              '语音、地图 SDK、本地 YOLO 推理尚未接入真机验证，'
              '请勿将其作为真实道路安全工具使用，也不能替代盲杖、'
              '导盲犬或专业定向行走训练。',
            ),
            const SizedBox(height: 24),
            Text('当前任务状态：${_tasks.state.name}'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _tasks.startTask(id: 'demo-1', goalText: '校园图书馆演示');
                });
              },
              child: const Text('开始演示任务（仅状态机演示）'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _tasks.transitionTo(TaskState.cancelled);
                  _tasks.reset();
                });
              },
              child: const Text('取消并重置'),
            ),
          ],
        ),
      ),
    );
  }
}
