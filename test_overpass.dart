// test_gemini_key.dart
//
// 用于诊断 Google Gemini API key 的小工具。
//
// 用法:
//   1) 通过环境变量传 key (推荐,不会留在 shell 历史里):
//        GEMINI_API_KEY=你的key dart run test_gemini_key.dart
//
//   2) 或者直接当参数传:
//        dart run test_gemini_key.dart 你的key
//
//   3) 可选:指定要测试的模型 (默认是 gemini-1.5-flash):
//        dart run test_gemini_key.dart 你的key gemini-1.5-pro
//
// 依赖: 只用了 dart:io + dart:convert,不需要额外安装任何包,
// 直接用系统自带的 Dart SDK 就能跑。

import 'dart:convert';
import 'dart:io';

const String baseUrl = 'https://generativelanguage.googleapis.com';

void main(List<String> args) async {
  final apiKey = _resolveApiKey(args);

  if (apiKey == null || apiKey.trim().isEmpty) {
    stderr.writeln('❌ 没找到 API key。');
    stderr.writeln('   请用以下任一方式提供:');
    stderr.writeln('   1) GEMINI_API_KEY=你的key dart run test_gemini_key.dart');
    stderr.writeln('   2) dart run test_gemini_key.dart 你的key');
    exit(1);
  }

  final model = args.length > 1 ? args[1] : 'gemini-1.5-flash';

  print('=' * 60);
  print('Gemini API Key 诊断工具');
  print('=' * 60);
  print('Key 预览: ${_maskKey(apiKey)}');
  print('测试模型: $model');
  print('');

  _checkKeyFormat(apiKey);

  final client = HttpClient();
  try {
    final modelsOk = await _testListModels(client, apiKey);
    print('');
    if (modelsOk) {
      await _testGenerateContent(client, apiKey, model);
    } else {
      print('⏭  跳过 generateContent 测试,因为 ListModels 已经失败了。');
      print('   先解决上面报的问题再继续测试。');
    }
  } finally {
    client.close(force: true);
  }

  print('');
  print('=' * 60);
  print('诊断结束');
  print('=' * 60);
}

/// 从参数或环境变量中取出 API key
String? _resolveApiKey(List<String> args) {
  if (args.isNotEmpty && args[0].trim().isNotEmpty) {
    return args[0].trim();
  }
  final envKey = Platform.environment['GEMINI_API_KEY'];
  if (envKey != null && envKey.trim().isNotEmpty) {
    return envKey.trim();
  }
  return null;
}

String _maskKey(String key) {
  if (key.length <= 8) return '*' * key.length;
  return '${key.substring(0, 4)}${'*' * (key.length - 8)}${key.substring(key.length - 4)}';
}

/// 基本格式检查,提前发现明显问题
void _checkKeyFormat(String key) {
  print('--- 基本格式检查 ---');

  final issues = <String>[];

  if (key.contains(' ')) {
    issues.add('key 里包含空格,可能是复制粘贴时多带了空格或换行符。');
  }
  if (key.contains('\n') || key.contains('\r')) {
    issues.add('key 里包含换行符,请检查是否复制完整/多复制了内容。');
  }
  if (!key.startsWith('AIza')) {
    issues.add(
        'key 一般以 "AIza" 开头 (Google API key 的常见前缀),你的 key 不是这个格式,'
        '确认一下是不是把 OAuth token、项目 ID 或其他东西当成 key 用了。');
  }
  if (key.length < 30) {
    issues.add('key 长度看起来偏短 (${key.length} 字符),正常 Google API key 一般在 39 字符左右。');
  }

  if (issues.isEmpty) {
    print('✅ 格式看起来正常。');
  } else {
    print('⚠️  发现潜在格式问题:');
    for (final issue in issues) {
      print('   - $issue');
    }
  }
}

/// 调用 ListModels,验证 key 本身是否有效、有没有权限
Future<bool> _testListModels(HttpClient client, String apiKey) async {
  print('--- 测试 1: ListModels (验证 key 有效性) ---');
  final uri = Uri.parse('$baseUrl/v1beta/models?key=$apiKey');

  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      print('✅ 请求成功 (HTTP 200)。Key 有效,且有基本访问权限。');
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final models = (json['models'] as List?) ?? [];
        print('   账号下可见模型数量: ${models.length}');
        if (models.isNotEmpty) {
          final sample = models
              .take(5)
              .map((m) => (m as Map<String, dynamic>)['name'])
              .join(', ');
          print('   部分模型: $sample');
        }
      } catch (_) {
        // 解析失败不影响主结论
      }
      return true;
    } else {
      print('❌ 请求失败 (HTTP ${response.statusCode})');
      _explainError(response.statusCode, body);
      return false;
    }
  } catch (e) {
    print('❌ 网络请求本身失败: $e');
    print('   检查网络连接、代理设置,或者是不是被防火墙/地区限制挡住了。');
    return false;
  }
}

/// 调用 generateContent,验证实际推理是否可用(配额、模型权限等)
Future<void> _testGenerateContent(
    HttpClient client, String apiKey, String model) async {
  print('--- 测试 2: generateContent (验证实际推理调用) ---');
  final uri =
      Uri.parse('$baseUrl/v1beta/models/$model:generateContent?key=$apiKey');

  final payload = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': 'Say "ok" and nothing else.'}
        ]
      }
    ]
  });

  try {
    final request = await client.postUrl(uri);
    request.headers.set('Content-Type', 'application/json');
    request.write(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      print('✅ 请求成功 (HTTP 200)。模型 "$model" 可以正常调用。');
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final candidates = json['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final text = (((candidates[0] as Map)['content']
              as Map)['parts'] as List)[0]['text'];
          print('   模型返回: $text');
        }
      } catch (_) {
        print('   (返回成功,但解析内容时出了点小问题,不影响 key 本身没问题的结论)');
      }
    } else {
      print('❌ 请求失败 (HTTP ${response.statusCode})');
      _explainError(response.statusCode, body);
    }
  } catch (e) {
    print('❌ 网络请求本身失败: $e');
  }
}

/// 把常见的 HTTP 状态码和错误信息翻译成人话
void _explainError(int statusCode, String body) {
  String? googleMessage;
  String? googleStatus;
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final error = json['error'] as Map<String, dynamic>?;
    googleMessage = error?['message'] as String?;
    googleStatus = error?['status'] as String?;
  } catch (_) {
    // body 不是 JSON 或格式不对,忽略
  }

  if (googleMessage != null) {
    print('   Google 返回的错误信息: $googleMessage');
  }
  if (googleStatus != null) {
    print('   错误状态: $googleStatus');
  }

  print('   可能的原因:');
  switch (statusCode) {
    case 400:
      print('   - 请求格式有问题,或者 key 格式不对 (比如带了多余字符)。');
      break;
    case 401:
      print('   - Key 无效、被撤销,或者根本不存在。去 Google AI Studio / '
          'Google Cloud Console 里确认这个 key 是否还有效。');
      break;
    case 403:
      print('   - Key 有效,但没有权限访问这个接口/模型。常见原因:');
      print('     a) 对应的 Google Cloud 项目没启用 Generative Language API。');
      print('     b) Key 设置了 API 限制 (API restrictions),没有勾选 Generative Language API。');
      print('     c) Key 设置了应用限制 (application restrictions),比如限定了 IP/域名,'
          '和你现在发请求的环境不匹配。');
      print('     d) 账号所在地区/项目不支持 Gemini API (地区限制)。');
      break;
    case 404:
      print('   - 模型名字不对,或者这个模型对你的 key/项目不可用。'
          '试试换个模型名,比如 gemini-1.5-flash 或 gemini-1.5-pro。');
      break;
    case 429:
      print('   - 超出配额或速率限制 (rate limit / quota exceeded)。'
          '如果是免费层级,可能是每分钟请求数或每日请求数用完了,过一会儿再试,'
          '或者去 Cloud Console 检查配额设置。');
      break;
    case 500:
    case 503:
      print('   - Google 服务端问题,不是你 key 的问题,过会儿重试即可。');
      break;
    default:
      print('   - 未分类的错误,请参考上面 Google 返回的原始错误信息。');
  }
}