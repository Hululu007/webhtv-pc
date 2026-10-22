/// 观影报告的 AI 解读（Phase 9 · P2-2）。
///
/// 只做「在本地统计结果之上加一段文字」：失败不影响基础报告，
/// 未配置 AI 时不发任何请求。
library;

import '../core/ai_config.dart';
import '../core/viewing_report.dart';
import 'ai_completion_client.dart';

class ViewingReportAiResult {
  const ViewingReportAiResult({
    required this.ok,
    required this.text,
    required this.message,
  });

  final bool ok;
  final String text;

  /// 失败原因（用户可读）；成功时为空。
  final String message;

  static const ViewingReportAiResult skipped = ViewingReportAiResult(
    ok: false,
    text: '',
    message: 'AI 未配置，基础报告已完整生成',
  );
}

class ViewingReportAiAnalyzer {
  ViewingReportAiAnalyzer({
    AiCompletionClient? client,
    this.timeout = AiCompletionClient.defaultTimeout,
  }) : _client = client ?? AiCompletionClient();

  final AiCompletionClient _client;
  final Duration timeout;

  /// 文本上限：防止模型输出极长内容把页面撑坏（不是安全边界，只是展示约束）。
  static const int maxTextLength = 2000;

  Future<ViewingReportAiResult> analyze({
    required AiConfig config,
    required ViewingReport report,
  }) async {
    if (!config.sanitized().isReady) return ViewingReportAiResult.skipped;
    final result = await _client.complete(
      config: config,
      prompt: buildViewingReportPrompt(report),
      timeout: timeout,
    );
    if (!result.ok) {
      return ViewingReportAiResult(
        ok: false,
        text: '',
        message: result.message,
      );
    }
    final text = result.text.trim();
    if (text.isEmpty) {
      return const ViewingReportAiResult(
        ok: false,
        text: '',
        message: 'AI 返回了空内容',
      );
    }
    return ViewingReportAiResult(
      ok: true,
      text: text.length > maxTextLength
          ? '${text.substring(0, maxTextLength)}…'
          : text,
      message: '',
    );
  }
}
