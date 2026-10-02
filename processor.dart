import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

const photoExt = {'.jpg', '.jpeg', '.png', '.webp'};
const videoExt = {'.mp4', '.mov', '.m4v'};

/// Penyedia AI yang didukung.
class ProviderInfo {
  const ProviderInfo(this.id, this.label, this.base, this.defaultModel, this.keyHelp);
  final String id;
  final String label;
  final String base; // alamat dasar API gaya OpenAI (kosong untuk Gemini/Kustom)
  final String defaultModel;
  final String keyHelp;
}

const providers = <ProviderInfo>[
  ProviderInfo('gemini', 'Gemini', '', 'gemini-3.6-flash', 'aistudio.google.com/apikey'),
  ProviderInfo('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1',
      'google/gemma-3-27b-it:free', 'openrouter.ai/keys'),
  ProviderInfo('groq', 'Groq', 'https://api.groq.com/openai/v1',
      'meta-llama/llama-4-scout-17b-16e-instruct', 'console.groq.com/keys'),
  ProviderInfo('mistral', 'Mistral', 'https://api.mistral.ai/v1', 'mistral-small-latest',
      'console.mistral.ai/api-keys'),
  ProviderInfo('custom', 'Kustom (gaya OpenAI)', '', '',
      'isi alamat API dan nama model sendiri (mis. Together, NVIDIA NIM)'),
];

ProviderInfo providerOf(String id) =>
    providers.firstWhere((x) => x.id == id, orElse: () => providers.first);

/// Pengaturan aplikasi (disimpan di HP).
class Settings {
  String provider = 'gemini';
  String customBase = '';
  String keys = '';
  String model = 'gemini-3.6-flash';
  int keywordCount = 49;
  int delaySec = 7;
  String style = 'Deskriptif';
  String language = 'English';
  bool rename = true;
  bool move = true;
  bool csv = true;
  bool retry = true;
  bool embed = true;
  String inputDir = '';
  String outputDir = '';

  List<String> get keyList => keys
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim())
      .where((e) => e.length > 10)
      .toSet()
      .toList();

  /// Muat key + model milik penyedia yang sedang aktif.
  Future<void> loadProviderFields() async {
    final sp = await SharedPreferences.getInstance();
    final legacyKeys = provider == 'gemini' ? sp.getString('keys') : null;
    final legacyModel = provider == 'gemini' ? sp.getString('model') : null;
    keys = sp.getString('keys_$provider') ?? legacyKeys ?? '';
    model = sp.getString('model_$provider') ??
        legacyModel ??
        providerOf(provider).defaultModel;
    customBase = sp.getString('customBase') ?? customBase;
  }

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    provider = sp.getString('provider') ?? provider;
    keywordCount = sp.getInt('keywordCount') ?? keywordCount;
    delaySec = sp.getInt('delaySec') ?? delaySec;
    style = sp.getString('style') ?? style;
    language = sp.getString('language') ?? language;
    rename = sp.getBool('rename') ?? rename;
    move = sp.getBool('move') ?? move;
    csv = sp.getBool('csv') ?? csv;
    retry = sp.getBool('retry') ?? retry;
    embed = sp.getBool('embed') ?? embed;
    inputDir = sp.getString('inputDir') ?? inputDir;
    outputDir = sp.getString('outputDir') ?? outputDir;
    await loadProviderFields();
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('provider', provider);
    await sp.setString('keys_$provider', keys);
    await sp.setString('model_$provider', model);
    await sp.setString('customBase', customBase);
    await sp.setInt('keywordCount', keywordCount);
    await sp.setInt('delaySec', delaySec);
    await sp.setString('style', style);
    await sp.setString('language', language);
    await sp.setBool('rename', rename);
    await sp.setBool('move', move);
    await sp.setBool('csv', csv);
    await sp.setBool('retry', retry);
    await sp.setBool('embed', embed);
    await sp.setString('inputDir', inputDir);
    await sp.setString('outputDir', outputDir);
  }
}

class Meta {
  Meta(this.title, this.keywords, this.category);
  final String title;
  final List<String> keywords;
  final int category;
}

class KeyLimitException implements Exception {}

class KeyDeadException implements Exception {
  KeyDeadException(this.msg);
  final String msg;
}

class FatalException implements Exception {
  FatalException(this.msg);
  final String msg;
}

class _KeyState {
  _KeyState(this.value);
  final String value;
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool dead = false;
  String get tail => value.length > 4 ? value.substring(value.length - 4) : value;
}

class _KeyPool {
  _KeyPool(List<String> keys) : _keys = keys.map((k) => _KeyState(k)).toList();
  final List<_KeyState> _keys;
  int _i = 0;

  int get length => _keys.length;
  bool get allDead => _keys.every((k) => k.dead);

  Future<_KeyState?> next(bool Function() stopped) async {
    while (!allDead && !stopped()) {
      final now = DateTime.now();
      for (var n = 0; n < _keys.length; n++) {
        final k = _keys[(_i + n) % _keys.length];
        if (!k.dead && !k.blockedUntil.isAfter(now)) {
          _i = (_i + n + 1) % _keys.length;
          return k;
        }
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }
}

final _brandRe = RegExp(
  r'\b(firefly|midjourney|adobe|topaz|dall-?e|stable diffusion|runway|sora|kling|gemini|chatgpt|openai)\b',
  caseSensitive: false,
);

Uint8List _prepPhoto(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return bytes;
  final longSide = im.width > im.height ? im.width : im.height;
  img.Image r = im;
  if (longSide > 1024) {
    r = im.width >= im.height
        ? img.copyResize(im, width: 1024)
        : img.copyResize(im, height: 1024);
  }
  return Uint8List.fromList(img.encodeJpg(r, quality: 80));
}

// ------------------------------------------------------------------
// Tanam metadata ke JPEG (IPTC-IIM + XMP) tanpa mengompres ulang gambar.
// ------------------------------------------------------------------

String _xmlEsc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

List<int> _iptcRec(int rec, int ds, List<int> data) =>
    [0x1c, rec, ds, (data.length >> 8) & 0xff, data.length & 0xff, ...data];

List<int> _segment(int marker, List<int> payload) {
  final len = payload.length + 2;
  if (len > 0xffff) throw Exception('Metadata terlalu besar');
  return [0xff, marker, (len >> 8) & 0xff, len & 0xff, ...payload];
}

bool _hasPrefix(Uint8List d, int start, List<int> prefix) {
  if (start + prefix.length > d.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (d[start + i] != prefix[i]) return false;
  }
  return true;
}

List<int> _buildApp13(String title, List<String> kws) {
  final t = utf8.encode(title);
  final b = BytesBuilder();
  b.add(_iptcRec(1, 0x5a, [0x1b, 0x25, 0x47])); // UTF-8
  b.add(_iptcRec(2, 0, [0x00, 0x04]));
  b.add(_iptcRec(2, 5, t)); // Object Name (judul)
  b.add(_iptcRec(2, 105, t)); // Headline
  b.add(_iptcRec(2, 120, t)); // Caption/Abstract
  for (final k in kws) {
    final kb = utf8.encode(k);
    if (kb.length <= 64) b.add(_iptcRec(2, 25, kb)); // Keywords
  }
  final iptc = b.toBytes();
  final out = BytesBuilder();
  out.add(ascii.encode('Photoshop 3.0'));
  out.addByte(0);
  out.add(ascii.encode('8BIM'));
  out.add([0x04, 0x04, 0x00, 0x00]);
  out.add([
    (iptc.length >> 24) & 0xff,
    (iptc.length >> 16) & 0xff,
    (iptc.length >> 8) & 0xff,
    iptc.length & 0xff,
  ]);
  out.add(iptc);
  if (iptc.length.isOdd) out.addByte(0);
  return out.toBytes();
}

List<int> _buildXmp(String title, List<String> kws) {
  final t = _xmlEsc(title);
  final li = kws.map((k) => '<rdf:li>${_xmlEsc(k)}</rdf:li>').join();
  final x = '<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
      '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
      '<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">'
      '<dc:title><rdf:Alt><rdf:li xml:lang="x-default">$t</rdf:li></rdf:Alt></dc:title>'
      '<dc:description><rdf:Alt><rdf:li xml:lang="x-default">$t</rdf:li></rdf:Alt></dc:description>'
      '<dc:subject><rdf:Bag>$li</rdf:Bag></dc:subject>'
      '<photoshop:Headline>$t</photoshop:Headline>'
      '</rdf:Description></rdf:RDF></x:xmpmeta>\n'
      '<?xpacket end="w"?>';
  return utf8.encode(x);
}

Uint8List embedJpegMetadata(Uint8List data, String title, List<String> kws) {
  if (data.length < 4 || data[0] != 0xff || data[1] != 0xd8) {
    throw Exception('Bukan file JPEG');
  }
  final xmpHead = ascii.encode('http://ns.adobe.com/xap/1.0/\x00');
  final psHead = ascii.encode('Photoshop 3.0\x00');
  const exifHead = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

  var pos = 2;
  var head = true;
  final keepHead = BytesBuilder();
  final keepTail = BytesBuilder();
  while (pos + 4 <= data.length && data[pos] == 0xff) {
    final m = data[pos + 1];
    if (m == 0xff) {
      pos++;
      continue;
    }
    if (m == 0xda) break; // mulai data gambar
    final len = (data[pos + 2] << 8) | data[pos + 3];
    final end = pos + 2 + len;
    if (len < 2 || end > data.length) throw Exception('Struktur JPEG rusak');
    final isXmp = m == 0xe1 && _hasPrefix(data, pos + 4, xmpHead);
    final isPs = m == 0xed && _hasPrefix(data, pos + 4, psHead);
    final isHead =
        head && (m == 0xe0 || (m == 0xe1 && _hasPrefix(data, pos + 4, exifHead)));
    if (!isXmp && !isPs) {
      if (isHead) {
        keepHead.add(data.sublist(pos, end));
      } else {
        head = false;
        keepTail.add(data.sublist(pos, end));
      }
    }
    pos = end;
  }

  final out = BytesBuilder();
  out.add([0xff, 0xd8]);
  out.add(keepHead.toBytes());
  out.add(_segment(0xed, _buildApp13(title, kws)));
  out.add(_segment(0xe1, [...xmpHead, ..._buildXmp(title, kws)]));
  out.add(keepTail.toBytes());
  out.add(data.sublist(pos));
  return out.toBytes();
}

class Processor {
  /// [files] diisi bila pengguna memilih file tertentu. Kalau null, semua file
  /// di folder input diproses.
  /// [fromPicker] true bila file berasal dari pemilih file sistem (salinan
  /// sementara di cache). File asli tidak dihapus dan salinan cache dibersihkan.
  Processor(this.s, this.log, this.onProgress, {this.files, this.fromPicker = false});

  final Settings s;
  final void Function(String) log;
  final void Function(int ok, int fail, int total) onProgress;
  final List<File>? files;
  final bool fromPicker;
  bool _stop = false;

  void stop() => _stop = true;

  static bool isMedia(String path) {
    final e = p.extension(path).toLowerCase();
    return photoExt.contains(e) || videoExt.contains(e);
  }

  static List<File> scanFolder(String dir) {
    try {
      return Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => isMedia(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      return <File>[];
    }
  }

  // ---------------------------------------------------------------- utama

  Future<void> run() async {
    try {
      await _run();
    } finally {
      if (fromPicker) {
        for (final f in files ?? const <File>[]) {
          try {
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _run() async {
    final keys = s.keyList;
    if (keys.isEmpty) {
      log('✖ Isi minimal satu API key.');
      return;
    }
    if (s.model.trim().isEmpty) {
      log('✖ Isi nama model.');
      return;
    }
    if (s.provider == 'custom' && s.customBase.trim().isEmpty) {
      log('✖ Isi alamat API untuk penyedia Kustom.');
      return;
    }
    if (s.outputDir.isEmpty) {
      log('✖ Folder output belum dipilih.');
      return;
    }
    final outDir = Directory(s.outputDir);
    try {
      await outDir.create(recursive: true);
    } catch (e) {
      log('✖ Tidak bisa membuat folder output: $e');
      return;
    }

    List<File> list;
    if (files != null) {
      list = [for (final f in files!) if (await f.exists()) f];
    } else {
      if (s.inputDir.isEmpty || !await Directory(s.inputDir).exists()) {
        log('✖ Folder input belum dipilih atau tidak ditemukan.');
        return;
      }
      list = scanFolder(s.inputDir);
    }
    if (list.isEmpty) {
      log('Tidak ada foto/video yang bisa diproses.');
      return;
    }

    log('Mulai: ${list.length} file, ${keys.length} API key, '
        '${providerOf(s.provider).label} / ${s.model}');
    if (fromPicker) log('Mode pilih file: file asli tidak diubah, hasil disalin ke output.');
    final pool = _KeyPool(keys);
    var ok = 0, fail = 0, streak = 0;
    onProgress(0, 0, list.length);

    for (var i = 0; i < list.length; i++) {
      if (_stop) {
        log('■ Dihentikan.');
        break;
      }
      final f = list[i];
      log('── [${i + 1}/${list.length}] ${p.basename(f.path)}');
      final meta = await _analyze(f, pool);
      if (meta == null) {
        fail++;
        streak++;
      } else {
        try {
          await _save(f, meta, outDir);
          ok++;
          streak = 0;
        } catch (e) {
          fail++;
          streak++;
          log('  ✖ Gagal memindah/menyalin file: $e');
        }
      }
      onProgress(ok, fail, list.length);
      if (streak >= 5 && !_stop) {
        log('■ Berhenti otomatis: 5 file gagal berturut-turut. Cek key, model, atau koneksi.');
        break;
      }
      if (i < list.length - 1 && !_stop) await _wait(s.delaySec);
    }
    log('SELESAI! Berhasil: $ok | Gagal: $fail');
  }

  Future<void> _wait(int seconds) async {
    for (var i = 0; i < seconds * 2 && !_stop; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  // ------------------------------------------------------------ analisis

  Future<Meta?> _analyze(File f, _KeyPool pool) async {
    final isVideo = videoExt.contains(p.extension(f.path).toLowerCase());
    List<Uint8List> images;
    try {
      images = isVideo ? await _videoFrames(f.path) : [await _photoBytes(f)];
    } catch (e) {
      log('  ✖ Gagal membaca file: $e');
      return null;
    }
    if (images.isEmpty) {
      log('  ✖ Tidak bisa mengambil gambar dari file ini.');
      return null;
    }
    log('  ${isVideo ? "Tipe: Video" : "Tipe: Foto"} (${images.length} gambar dikirim ke AI)');

    final maxErrors = s.retry ? 3 : 1;
    final maxSwaps = pool.length * 3 + 3;
    var errors = 0, swaps = 0;
    while (errors < maxErrors && swaps < maxSwaps) {
      if (_stop) return null;
      final key = await pool.next(() => _stop);
      if (key == null) {
        if (!_stop) log('  ✖ Semua API key tidak aktif.');
        _stop = true;
        return null;
      }
      try {
        final res = await _send(key.value, prompt: _prompt(isVideo), images: images);
        _throwForStatus(res);
        final m = _parse(_extractText(res));
        log('  Title   : ${m.title}');
        log('  Keywords: ${m.keywords.length} → ${m.keywords.take(6).join(", ")}...');
        log('  Kategori: ${m.category}');
        return m;
      } on KeyLimitException {
        key.blockedUntil = DateTime.now().add(const Duration(seconds: 60));
        swaps++;
        log('  ⚠ Key ...${key.tail} kena limit, ganti key.');
      } on KeyDeadException catch (e) {
        key.dead = true;
        swaps++;
        log('  ✖ Key ...${key.tail} tidak valid (${e.msg}).');
      } on FatalException catch (e) {
        log('  ✖ ${e.msg}');
        _stop = true;
        return null;
      } catch (e) {
        errors++;
        log('  ⚠ Error: $e (percobaan $errors/$maxErrors)');
        await _wait(2);
      }
    }
    if (!_stop) log('  ✖ Gagal memproses file ini.');
    return null;
  }

  Future<List<Uint8List>> _videoFrames(String path) async {
    final out = <Uint8List>[];
    for (final ms in const [300, 2000, 4500]) {
      try {
        final d = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          timeMs: ms,
          maxWidth: 768,
          quality: 75,
        );
        if (d != null && d.isNotEmpty) out.add(d);
      } catch (_) {}
    }
    return out;
  }

  Future<Uint8List> _photoBytes(File f) async {
    final bytes = await f.readAsBytes();
    return Isolate.run(() => _prepPhoto(bytes));
  }

  // ------------------------------------------------------------- jaringan

  String _chatUrl() {
    var base = s.provider == 'custom' ? s.customBase.trim() : providerOf(s.provider).base;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base.endsWith('/chat/completions') ? base : '$base/chat/completions';
  }

  /// Kirim permintaan ke penyedia aktif. [maxTokens] > 0 membatasi panjang jawaban.
  Future<http.Response> _send(
    String key, {
    required String prompt,
    List<Uint8List> images = const [],
    int maxTokens = 0,
  }) {
    if (s.provider == 'gemini') {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/${s.model}:generateContent?key=$key',
      );
      final parts = <Map<String, dynamic>>[
        {'text': prompt},
        for (final b in images)
          {
            'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(b)},
          },
      ];
      final gen = <String, dynamic>{'temperature': 0.4};
      if (images.isNotEmpty) gen['responseMimeType'] = 'application/json';
      if (maxTokens > 0) gen['maxOutputTokens'] = maxTokens;
      return http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {'parts': parts},
              ],
              'generationConfig': gen,
            }),
          )
          .timeout(const Duration(seconds: 90));
    }

    final content = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt},
      for (final b in images)
        {
          'type': 'image_url',
          'image_url': s.provider == 'mistral'
              ? 'data:image/jpeg;base64,${base64Encode(b)}'
              : {'url': 'data:image/jpeg;base64,${base64Encode(b)}'},
        },
    ];
    final body = <String, dynamic>{
      'model': s.model,
      'messages': [
        {'role': 'user', 'content': images.isEmpty ? prompt : content},
      ],
      'temperature': 0.4,
    };
    if (maxTokens > 0) body['max_tokens'] = maxTokens;
    return http
        .post(
          Uri.parse(_chatUrl()),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
            'X-Title': 'Stok Meta',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 90));
  }

  void _throwForStatus(http.Response res) {
    final code = res.statusCode;
    if (code == 200) return;
    final msg = _errMsg(res);
    if (code == 429) throw KeyLimitException();
    if (code == 401 ||
        code == 402 ||
        code == 403 ||
        (code == 400 && res.body.contains('API key'))) {
      throw KeyDeadException(msg);
    }
    if (code == 404) {
      throw FatalException(
        'Model "${s.model}" atau alamat API tidak ditemukan. ($msg)',
      );
    }
    if (code == 400 &&
        RegExp(r'(vision|multimodal|image input|does not support image|image_url)',
                caseSensitive: false)
            .hasMatch(msg)) {
      throw FatalException(
        'Model "${s.model}" sepertinya tidak mendukung gambar. Pakai model vision. ($msg)',
      );
    }
    throw Exception('HTTP $code: $msg');
  }

  String _errMsg(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final e = j['error'];
      if (e is Map && e['message'] != null) return e['message'].toString();
      if (e is String) return e;
      if (j['message'] != null) return j['message'].toString();
    } catch (_) {}
    final b = res.body;
    return b.length > 120 ? b.substring(0, 120) : b;
  }

  String _extractText(http.Response res) {
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (s.provider == 'gemini') {
      final cands = j['candidates'];
      if (cands is! List || cands.isEmpty) {
        throw Exception('AI tidak memberi jawaban (mungkin diblokir filter).');
      }
      final partList = (cands[0]['content']?['parts'] ?? []) as List;
      return partList
          .where((e) => e is Map && e['text'] != null && e['thought'] != true)
          .map((e) => e['text'].toString())
          .join();
    }
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) {
      final e = j['error'];
      final m = e is Map ? e['message'] : null;
      throw Exception('AI tidak memberi jawaban${m != null ? ": $m" : ""}');
    }
    final c = choices[0]['message']?['content'];
    if (c is String) return c;
    if (c is List) {
      return c.map((e) => e is Map ? (e['text'] ?? '').toString() : '').join();
    }
    throw Exception('Format jawaban AI tidak dikenali.');
  }

  // -------------------------------------------------------------- prompt

  String _prompt(bool video) {
    final styleRule = switch (s.style) {
      'Singkat' => 'a short, clear title of 4 to 8 words',
      'SEO' => 'a keyword-rich title of 12 to 20 words with the main subject first',
      _ => 'a descriptive, natural title of 8 to 15 words that states the subject, action and setting',
    };
    final lang = s.language == 'Indonesia' ? 'Indonesian' : 'English';
    final source = video
        ? 'These images are frames taken in order from ONE stock video clip. Describe the whole clip, including the action or movement.'
        : 'This is ONE stock photo.';
    return '''You are an expert metadata writer for Adobe Stock.
$source
Return ONLY a JSON object, no markdown, in exactly this shape:
{"title": "...", "keywords": ["..."], "category": 3}
Rules:
- Title: $styleRule. Write it in $lang. Describe only what is visible. No quotation marks and no trailing period.
- Never mention brand names, trademarks, real people's names, or the software, AI tool or camera used.
- Keywords: up to ${s.keywordCount} keywords in $lang, most relevant first, no duplicates, single words or short phrases.
- Category: pick ONE number: 1 Animals, 2 Buildings and Architecture, 3 Business, 4 Drinks, 5 The Environment, 6 States of Mind, 7 Food, 8 Graphic Resources, 9 Hobbies and Leisure, 10 Industry, 11 Landscapes, 12 Lifestyle, 13 People, 14 Plants and Flowers, 15 Culture and Religion, 16 Science, 17 Social Issues, 18 Sports, 19 Technology, 20 Transport, 21 Travel.''';
  }

  Meta _parse(String text) {
    final t = text.trim();
    final a = t.indexOf('{');
    final b = t.lastIndexOf('}');
    if (a < 0 || b <= a) throw Exception('Balasan AI bukan JSON');
    final j = jsonDecode(t.substring(a, b + 1)) as Map<String, dynamic>;

    var title = (j['title'] ?? '').toString().replaceAll(_brandRe, '');
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    title = title.replaceAll(RegExp(r'^["\x27]+|["\x27.,;:]+$'), '').trim();
    if (title.length > 190) {
      title = title.substring(0, 190);
      final cut = title.lastIndexOf(' ');
      if (cut > 100) title = title.substring(0, cut);
    }
    if (title.isEmpty) throw Exception('Judul kosong');

    final raw = j['keywords'];
    final List<String> list = raw is List
        ? raw.map((e) => e.toString()).toList()
        : raw is String
            ? raw.split(',')
            : <String>[];
    final seen = <String>{};
    final kws = <String>[];
    for (var k in list) {
      k = k
          .replaceAll(RegExp(r'[^\p{L}\p{N}\s\-]', unicode: true), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim()
          .toLowerCase();
      if (k.isEmpty || _brandRe.hasMatch(k)) continue;
      if (seen.add(k)) kws.add(k);
      if (kws.length >= s.keywordCount) break;
    }
    if (kws.isEmpty) throw Exception('Keyword kosong');

    var cat = int.tryParse((j['category'] ?? '').toString().trim()) ?? 12;
    if (cat < 1 || cat > 21) cat = 12;
    return Meta(title, kws, cat);
  }

  // -------------------------------------------------------------- output

  String _safeName(String title) {
    var n = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (n.length > 120) {
      n = n.substring(0, 120);
      final cut = n.lastIndexOf(' ');
      if (cut > 60) n = n.substring(0, cut);
    }
    return n.isEmpty ? 'untitled' : n;
  }

  Future<void> _save(File src, Meta m, Directory out) async {
    final ext = p.extension(src.path).toLowerCase();
    final base = s.rename ? _safeName(m.title) : p.basenameWithoutExtension(src.path);
    var name = '$base$ext';
    var n = 2;
    while (true) {
      final c = p.join(out.path, name);
      if (p.equals(c, src.path) || !await File(c).exists()) break;
      name = '$base ($n)$ext';
      n++;
    }
    final dest = p.join(out.path, name);
    final moved = s.move && !fromPicker;
    if (!p.equals(dest, src.path)) {
      if (moved) {
        try {
          await src.rename(dest);
        } on FileSystemException {
          await src.copy(dest);
          await src.delete();
        }
      } else {
        await src.copy(dest);
      }
    }
    log('  ✔ ${moved ? "Dipindah" : "Disalin"} → $name');
    if (s.embed) await _embed(dest, m);
    if (s.csv) await _appendCsv(out, name, m);
  }

  bool _warnedNoEmbed = false;

  Future<void> _embed(String path, Meta m) async {
    final ext = p.extension(path).toLowerCase();
    if (ext != '.jpg' && ext != '.jpeg') {
      if (!_warnedNoEmbed) {
        _warnedNoEmbed = true;
        log('  ℹ Metadata hanya ditanam ke JPG. Video/PNG/WebP memakai CSV.');
      }
      return;
    }
    try {
      final data = await File(path).readAsBytes();
      final out = embedJpegMetadata(data, m.title, m.keywords);
      final tmp = File('$path.tmp');
      await tmp.writeAsBytes(out, flush: true);
      await tmp.rename(path);
      log('  ✔ Metadata tertanam di file (IPTC + XMP)');
    } catch (e) {
      log('  ⚠ Gagal menanam metadata: $e');
    }
  }

  Future<void> _appendCsv(Directory out, String filename, Meta m) async {
    final f = File(p.join(out.path, 'metadata_adobe_stock.csv'));
    final exists = await f.exists();
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final sb = StringBuffer();
    if (!exists) sb.writeln('Filename,Title,Keywords,Category,Releases');
    sb.writeln('${q(filename)},${q(m.title)},${q(m.keywords.join(", "))},${m.category},');
    await f.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
  }

  // ----------------------------------------------------------- cek key

  Future<void> checkKeys() async {
    final keys = s.keyList;
    if (keys.isEmpty) {
      log('✖ Belum ada API key.');
      return;
    }
    if (s.provider == 'custom' && s.customBase.trim().isEmpty) {
      log('✖ Isi alamat API untuk penyedia Kustom.');
      return;
    }
    log('Mengecek ${keys.length} key (${providerOf(s.provider).label} / ${s.model})...');
    for (final k in keys) {
      final tail = k.length > 4 ? k.substring(k.length - 4) : k;
      try {
        final res = await _send(k, prompt: 'Reply with OK', maxTokens: 8);
        final code = res.statusCode;
        if (code == 200) {
          log('  ✔ ...$tail aktif');
        } else if (code == 429) {
          log('  ⚠ ...$tail valid tapi kena limit sementara');
        } else if (code == 404) {
          log('  ✖ Model atau alamat API tidak ditemukan (key ...$tail).');
        } else {
          log('  ✖ ...$tail bermasalah (HTTP $code: ${_errMsg(res)})');
        }
      } catch (e) {
        log('  ✖ ...$tail gagal dicek: $e');
      }
    }
    log('Cek key selesai.');
  }
}

