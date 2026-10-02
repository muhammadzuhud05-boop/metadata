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

/// Pengaturan aplikasi (disimpan di HP).
class Settings {
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
  String inputDir = '';
  String outputDir = '';

  List<String> get keyList => keys
      .split(RegExp(r'[\s,;]+'))
      .map((e) => e.trim())
      .where((e) => e.length > 10)
      .toSet()
      .toList();

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    keys = sp.getString('keys') ?? keys;
    model = sp.getString('model') ?? model;
    keywordCount = sp.getInt('keywordCount') ?? keywordCount;
    delaySec = sp.getInt('delaySec') ?? delaySec;
    style = sp.getString('style') ?? style;
    language = sp.getString('language') ?? language;
    rename = sp.getBool('rename') ?? rename;
    move = sp.getBool('move') ?? move;
    csv = sp.getBool('csv') ?? csv;
    retry = sp.getBool('retry') ?? retry;
    inputDir = sp.getString('inputDir') ?? inputDir;
    outputDir = sp.getString('outputDir') ?? outputDir;
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('keys', keys);
    await sp.setString('model', model);
    await sp.setInt('keywordCount', keywordCount);
    await sp.setInt('delaySec', delaySec);
    await sp.setString('style', style);
    await sp.setString('language', language);
    await sp.setBool('rename', rename);
    await sp.setBool('move', move);
    await sp.setBool('csv', csv);
    await sp.setBool('retry', retry);
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

class Processor {
  Processor(this.s, this.log, this.onProgress);

  final Settings s;
  final void Function(String) log;
  final void Function(int ok, int fail, int total) onProgress;
  bool _stop = false;

  void stop() => _stop = true;

  // ---------------------------------------------------------------- utama

  Future<void> run() async {
    final keys = s.keyList;
    if (keys.isEmpty) {
      log('✖ Isi minimal satu API key.');
      return;
    }
    if (s.inputDir.isEmpty || !await Directory(s.inputDir).exists()) {
      log('✖ Folder input belum dipilih atau tidak ditemukan.');
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

    List<File> files;
    try {
      files = Directory(s.inputDir)
          .listSync()
          .whereType<File>()
          .where((f) {
            final e = p.extension(f.path).toLowerCase();
            return photoExt.contains(e) || videoExt.contains(e);
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (e) {
      log('✖ Tidak bisa membaca folder input: $e');
      return;
    }
    if (files.isEmpty) {
      log('Tidak ada foto/video di folder input.');
      return;
    }

    log('Mulai: ${files.length} file, ${keys.length} API key, model ${s.model}');
    final pool = _KeyPool(keys);
    var ok = 0, fail = 0, streak = 0;
    onProgress(0, 0, files.length);

    for (var i = 0; i < files.length; i++) {
      if (_stop) {
        log('■ Dihentikan.');
        break;
      }
      final f = files[i];
      log('── [${i + 1}/${files.length}] ${p.basename(f.path)}');
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
      onProgress(ok, fail, files.length);
      if (streak >= 5 && !_stop) {
        log('■ Berhenti otomatis: 5 file gagal berturut-turut. Cek key, model, atau koneksi.');
        break;
      }
      if (i < files.length - 1 && !_stop) await _wait(s.delaySec);
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
        final m = await _callGemini(key.value, images, isVideo);
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

  // -------------------------------------------------------------- Gemini

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

  Future<Meta> _callGemini(String key, List<Uint8List> images, bool video) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/${s.model}:generateContent?key=$key',
    );
    final parts = <Map<String, dynamic>>[
      {'text': _prompt(video)},
      for (final b in images)
        {
          'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(b)},
        },
    ];
    final body = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'temperature': 0.4,
        'responseMimeType': 'application/json',
      },
    });
    final res = await http
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 90));

    if (res.statusCode == 429) throw KeyLimitException();
    if (res.statusCode == 403 ||
        (res.statusCode == 400 && res.body.contains('API key'))) {
      throw KeyDeadException(_errMsg(res));
    }
    if (res.statusCode == 404) {
      throw FatalException('Model "${s.model}" tidak ditemukan. Periksa nama model.');
    }
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}: ${_errMsg(res)}');
    }

    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final cands = j['candidates'];
    if (cands is! List || cands.isEmpty) {
      throw Exception('AI tidak memberi jawaban (mungkin diblokir filter).');
    }
    final partList = (cands[0]['content']?['parts'] ?? []) as List;
    final text = partList
        .where((e) => e is Map && e['text'] != null && e['thought'] != true)
        .map((e) => e['text'].toString())
        .join();
    return _parse(text);
  }

  String _errMsg(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final m = j['error']?['message'];
      if (m != null) return m.toString();
    } catch (_) {}
    final b = res.body;
    return b.length > 120 ? b.substring(0, 120) : b;
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
    if (!p.equals(dest, src.path)) {
      if (s.move) {
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
    log('  ✔ ${s.move ? "Dipindah" : "Disalin"} → $name');
    if (s.csv) await _appendCsv(out, name, m);
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

  static Future<void> checkKeys(
    List<String> keys,
    String model,
    void Function(String) log,
  ) async {
    if (keys.isEmpty) {
      log('✖ Belum ada API key.');
      return;
    }
    log('Mengecek ${keys.length} key...');
    for (final k in keys) {
      final tail = k.length > 4 ? k.substring(k.length - 4) : k;
      try {
        final res = await http
            .post(
              Uri.parse(
                'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$k',
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'contents': [
                  {
                    'parts': [
                      {'text': 'Reply with OK'},
                    ],
                  },
                ],
                'generationConfig': {'maxOutputTokens': 8},
              }),
            )
            .timeout(const Duration(seconds: 30));
        if (res.statusCode == 200) {
          log('  ✔ ...$tail aktif');
        } else if (res.statusCode == 429) {
          log('  ⚠ ...$tail valid tapi kena limit sementara');
        } else if (res.statusCode == 404) {
          log('  ✖ Model "$model" tidak ditemukan (key ...$tail).');
        } else {
          log('  ✖ ...$tail tidak valid (HTTP ${res.statusCode})');
        }
      } catch (e) {
        log('  ✖ ...$tail gagal dicek: $e');
      }
    }
    log('Cek key selesai.');
  }
}
