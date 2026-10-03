import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'processor.dart';

void main() => runApp(const StokMetaApp());

const _green = Color(0xFF2E9E6B);
const _panel = Color(0xFF1B2420);

class StokMetaApp extends StatelessWidget {
  const StokMetaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Stok Meta',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _green,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF111815),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final s = Settings();
  final keysCtrl = TextEditingController();
  final modelCtrl = TextEditingController();
  final baseCtrl = TextEditingController();
  final logScroll = ScrollController();
  final logs = <String>[];

  bool loaded = false;
  bool running = false;
  int ok = 0, fail = 0, total = 0;
  bool modelBusy = false;
  Processor? proc;

  // Sumber file
  List<File> folderFiles = []; // isi folder input
  List<File> picked = []; // file yang dipilih lewat pemilih file

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    keysCtrl.dispose();
    modelCtrl.dispose();
    baseCtrl.dispose();
    logScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await s.load();
    keysCtrl.text = s.keys;
    modelCtrl.text = s.model;
    baseCtrl.text = s.customBase;
    if (s.inputDir.isNotEmpty) folderFiles = Processor.scanFolder(s.inputDir);
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() async {
    s.keys = keysCtrl.text;
    if (s.provider == 'custom') s.model = modelCtrl.text.trim();
    s.customBase = baseCtrl.text.trim();
    await s.save();
  }

  Future<void> _changeProvider(String id) async {
    await _save();
    s.provider = id;
    await s.loadProviderFields();
    keysCtrl.text = s.keys;
    modelCtrl.text = s.model;
    baseCtrl.text = s.customBase;
    await s.save();
    if (mounted) setState(() {});
  }

  void _log(String m) {
    if (!mounted) return;
    setState(() {
      logs.add(m);
      if (logs.length > 600) logs.removeRange(0, logs.length - 600);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (logScroll.hasClients) {
        logScroll.jumpTo(logScroll.position.maxScrollExtent);
      }
    });
  }

  Future<bool> _ensureStorage() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    var st = await Permission.manageExternalStorage.request();
    if (st.isGranted) return true;
    st = await Permission.storage.request();
    if (st.isGranted) return true;
    await openAppSettings();
    return false;
  }

  // ------------------------------------------------------- pilih sumber

  Future<void> _pickFolder() async {
    if (!await _ensureStorage()) {
      _log('✖ Aktifkan "Akses semua file" untuk aplikasi ini, lalu pilih folder lagi.');
      return;
    }
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    setState(() {
      s.inputDir = d;
      folderFiles = Processor.scanFolder(d);
      picked = [];
    });
    await _save();
    if (folderFiles.isEmpty) {
      _log('Folder ini tidak berisi foto/video yang didukung (jpg, png, webp, mp4, mov).');
    }
  }

  Future<void> _pickFiles() async {
    final r = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.media,
    );
    if (r == null) return;
    final list = <File>[
      for (final f in r.files)
        if (f.path != null && Processor.isMedia(f.path!)) File(f.path!),
    ];
    if (list.isEmpty) {
      _log('Tidak ada foto/video yang didukung pada pilihan tadi.');
      return;
    }
    setState(() {
      picked = list;
    });
  }

  Future<void> _checkFile() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
    if (r == null || r.files.isEmpty || r.files.first.path == null) return;
    final f = File(r.files.first.path!);
    _log('── Periksa metadata: ${p.basename(f.path)}');
    try {
      final ext = p.extension(f.path).toLowerCase();
      final isVideo = ext == '.mp4' || ext == '.m4v';
      final m = isVideo ? await readMp4Metadata(f.path) : readJpegMetadata(await f.readAsBytes());
      _log('  XMP  judul   : ${m.xmpTitle ?? "(kosong)"}');
      _log('  XMP  keyword : ${m.xmpKeywords.length}');
      if (isVideo) {
        _log('  iTunes judul   : ${m.itunesTitle ?? "(kosong)"}');
        _log('  iTunes keyword : ${m.itunesKeywords.length}');
      } else {
        _log('  IPTC judul   : ${m.iptcTitle ?? "(kosong)"}');
        _log('  IPTC keyword : ${m.iptcKeywords.length}');
      }
      if (m.xmpKeywords.isNotEmpty) {
        _log('  Contoh: ${m.xmpKeywords.take(8).join(", ")}');
      }
    } catch (e) {
      _log('  ✖ $e');
    }
    try {
      f.deleteSync(); // salinan sementara di cache, bukan file asli
    } catch (_) {}
  }

  Future<void> _resetSource() async {
    setState(() {
      picked = [];
      folderFiles = [];
      s.inputDir = '';
    });
    await _save();
  }

  String get _sourceText {
    if (picked.isNotEmpty) {
      return '${picked.length} file dipilih. File asli tidak dihapus, hasilnya disalin ke output.';
    }
    if (s.inputDir.isEmpty) return 'Belum ada sumber. Pilih file atau pilih folder.';
    return 'Semua ${folderFiles.length} file di folder akan diproses.';
  }

  // ------------------------------------------------------------- model

  List<ModelOpt> _modelItems() {
    final byId = <String, ModelOpt>{};
    for (final x in s.modelsFor(s.provider)) {
      byId.putIfAbsent(x.id, () => x);
    }
    if (s.model.isNotEmpty && !byId.containsKey(s.model)) {
      return [ModelOpt(s.model, 'tersimpan'), ...byId.values];
    }
    return byId.values.toList();
  }

  Future<void> _refreshModels() async {
    await _save();
    final prov = s.provider;
    final keys = s.keyList;
    if (prov != 'openrouter' && keys.isEmpty) {
      _log('✖ Isi API key dulu untuk memperbarui daftar model ${providerOf(prov).label}.');
      return;
    }
    setState(() => modelBusy = true);
    try {
      final list = await fetchModels(prov, keys.isEmpty ? '' : keys.first);
      if (list.isEmpty) {
        _log('Tidak ditemukan model yang bisa membaca gambar. Daftar bawaan tetap dipakai.');
      } else {
        await s.saveModels(prov, list);
        if (!list.any((x) => x.id == s.model)) {
          s.model = list.first.id;
          await s.save();
          _log('Model diganti ke ${s.model} karena model sebelumnya tidak ada di daftar baru.');
        }
        _log('✔ ${providerOf(prov).label}: ${list.length} model yang bisa membaca gambar.');
      }
    } catch (e) {
      _log('✖ Gagal memperbarui daftar model: $e');
    }
    if (mounted) setState(() => modelBusy = false);
  }

  Widget _modelDropdown() {
    final items = _modelItems();
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Model (otomatis, bisa membaca gambar)',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: s.model,
          isExpanded: true,
          itemHeight: null,
          selectedItemBuilder: (_) => [
            for (final x in items)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(x.id, overflow: TextOverflow.ellipsis),
              ),
          ],
          items: [
            for (final x in items)
              DropdownMenuItem<String>(
                value: x.id,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(x.id, overflow: TextOverflow.ellipsis),
                      if (x.note.isNotEmpty)
                        Text(
                          x.note,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: Color(0xFF9DB5A8)),
                        ),
                    ],
                  ),
                ),
              ),
          ],
          onChanged: running
              ? null
              : (v) async {
                  if (v == null) return;
                  setState(() => s.model = v);
                  await _save();
                },
        ),
      ),
    );
  }

  // ------------------------------------------------------------- proses

  Future<void> _checkKeys() async {
    await _save();
    await Processor(s, _log, (a, b, c) {}).checkKeys();
  }

  Future<void> _start() async {
    await _save();
    if (!await _ensureStorage()) {
      _log('✖ Izin akses penyimpanan belum diberikan. Aktifkan "Akses semua file" lalu tekan Mulai lagi.');
      return;
    }
    if (s.inputDir.isNotEmpty) {
      folderFiles = Processor.scanFolder(s.inputDir);
    }

    List<File>? files;
    var fromPicker = false;
    if (picked.isNotEmpty) {
      files = picked;
      fromPicker = true;
    }

    setState(() {
      running = true;
      ok = 0;
      fail = 0;
      total = 0;
      logs.clear();
    });
    await WakelockPlus.enable();
    proc = Processor(
      s,
      _log,
      (o, f, t) {
        if (mounted) {
          setState(() {
            ok = o;
            fail = f;
            total = t;
          });
        }
      },
      files: files,
      fromPicker: fromPicker,
    );
    try {
      await proc!.run();
    } catch (e) {
      _log('✖ Error tak terduga: $e');
    }
    await WakelockPlus.disable();
    if (mounted) {
      setState(() {
        running = false;
        if (fromPicker) picked = [];
        if (s.inputDir.isNotEmpty) {
          folderFiles = Processor.scanFolder(s.inputDir);
        }
      });
    }
  }

  void _stop() {
    proc?.stop();
    _log('Menghentikan setelah file ini selesai...');
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    if (!loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final info = providerOf(s.provider);
    final done = ok + fail;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stok Meta'),
        backgroundColor: const Color(0xFF111815),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            _section('Penyedia AI dan API key', [
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Penyedia',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: s.provider,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      for (final x in providers)
                        DropdownMenuItem(value: x.id, child: Text(x.label)),
                    ],
                    onChanged: running
                        ? null
                        : (v) {
                            if (v != null && v != s.provider) _changeProvider(v);
                          },
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Key gratis: ${info.keyHelp}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9DB5A8)),
              ),
              const SizedBox(height: 8),
              if (s.provider == 'custom') ...[
                TextField(
                  controller: baseCtrl,
                  enabled: !running,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Alamat API (contoh: https://api.together.xyz/v1)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: keysCtrl,
                enabled: !running,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Satu key per baris (boleh banyak, dipakai bergantian)',
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (s.provider == 'custom')
                TextField(
                  controller: modelCtrl,
                  enabled: !running,
                  decoration: const InputDecoration(
                    labelText: 'Nama model (harus bisa membaca gambar)',
                    border: OutlineInputBorder(),
                  ),
                )
              else ...[
                _modelDropdown(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: running || modelBusy ? null : _refreshModels,
                    icon: modelBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Perbarui daftar model'),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: running ? null : _checkKeys,
                    icon: const Icon(Icons.bolt),
                    label: const Text('Cek key aktif'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: running
                        ? null
                        : () async {
                            await _save();
                            _log('✔ Pengaturan disimpan.');
                          },
                    icon: const Icon(Icons.save),
                    label: const Text('Simpan'),
                  ),
                ),
              ]),
            ]),
            _section('Sumber file', [
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                    onPressed: running ? null : _pickFiles,
                    child: const Text('Pilih file'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                    onPressed: running ? null : _pickFolder,
                    child: const Text('Pilih folder'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                    onPressed: running ? null : _resetSource,
                    child: const Text('Reset'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              if (s.inputDir.isNotEmpty && picked.isEmpty)
                Text('Folder: ${s.inputDir}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF9DB5A8))),
              Text(_sourceText),
              const SizedBox(height: 4),
              const Text(
                'Pilih file: dari galeri, file asli aman. Pilih folder: semua file di folder diproses, lalu dipindah atau disalin.',
                style: TextStyle(fontSize: 11, color: Color(0xFF7F978A)),
              ),
            ]),
            _section('Folder output', [
              _dirTile(
                'Hasil rename dan CSV disimpan di',
                s.outputDir,
                () async {
                  if (!await _ensureStorage()) {
                    _log('✖ Aktifkan "Akses semua file" untuk aplikasi ini, lalu pilih folder lagi.');
                    return;
                  }
                  final d = await FilePicker.platform.getDirectoryPath();
                  if (d == null) return;
                  setState(() => s.outputDir = d);
                  await _save();
                },
              ),
            ]),
            _section('Pengaturan', [
              Text('Jumlah keyword: ${s.keywordCount}'),
              Slider(
                value: s.keywordCount.toDouble(),
                min: 1,
                max: 49,
                divisions: 48,
                label: '${s.keywordCount}',
                onChanged: running ? null : (v) => setState(() => s.keywordCount = v.round()),
              ),
              Text('Jeda antar file: ${s.delaySec} detik'),
              Slider(
                value: s.delaySec.toDouble(),
                min: 0,
                max: 30,
                divisions: 30,
                label: '${s.delaySec}',
                onChanged: running ? null : (v) => setState(() => s.delaySec = v.round()),
              ),
              Row(children: [
                Expanded(
                  child: _dropdown('Style judul', s.style, const ['Deskriptif', 'Singkat', 'SEO'],
                      (v) => setState(() => s.style = v)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _dropdown('Bahasa', s.language, const ['English', 'Indonesia'],
                      (v) => setState(() => s.language = v)),
                ),
              ]),
              _switch('Rename file sesuai judul', s.rename, (v) => s.rename = v),
              _switch('Pindah ke output (mati = salin)', s.move, (v) => s.move = v),
              _switch('Tanam metadata ke file (JPG dan MP4)', s.embed, (v) => s.embed = v),
              _switch('Export CSV Adobe Stock', s.csv, (v) => s.csv = v),
              _switch('Auto retry', s.retry, (v) => s.retry = v),
            ]),
            OutlinedButton.icon(
              onPressed: running ? null : _checkFile,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Periksa metadata file (JPG atau MP4)'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('MULAI PROSES'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF59E0B),
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: running ? _stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('HENTIKAN'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB3363B),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: total == 0 ? (running ? null : 0) : done / total,
              minHeight: 8,
              color: const Color(0xFFF59E0B),
            ),
            const SizedBox(height: 6),
            Text(
              total == 0
                  ? (running ? 'Menyiapkan...' : 'Siap.')
                  : '$done / $total  •  berhasil $ok  •  gagal $fail',
            ),
            const SizedBox(height: 12),
            Container(
              height: 340,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF07100B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: logs.isEmpty
                  ? const Text('Log proses akan muncul di sini.',
                      style: TextStyle(color: Color(0xFF6E8F7C), fontSize: 12))
                  : ListView.builder(
                      controller: logScroll,
                      itemCount: logs.length,
                      itemBuilder: (_, i) => Text(
                        logs[i],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Color(0xFF7CFFB2),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  Widget _dirTile(String label, String path, VoidCallback onTap) {
    return InkWell(
      onTap: running ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF3A4A42)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          const Icon(Icons.folder_open, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF9DB5A8))),
                Text(path.isEmpty ? 'Ketuk untuk memilih' : path,
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> items, ValueChanged<String> onChanged) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [for (final i in items) DropdownMenuItem(value: i, child: Text(i))],
          onChanged: running
              ? null
              : (v) {
                  if (v != null) onChanged(v);
                },
        ),
      ),
    );
  }

  Widget _switch(String label, bool value, void Function(bool) set) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: running ? null : (v) => setState(() => set(v)),
    );
  }
}
