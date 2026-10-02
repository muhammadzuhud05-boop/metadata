import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
  final logScroll = ScrollController();
  final logs = <String>[];

  bool loaded = false;
  bool running = false;
  int ok = 0, fail = 0, total = 0;
  Processor? proc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    keysCtrl.dispose();
    modelCtrl.dispose();
    logScroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await s.load();
    keysCtrl.text = s.keys;
    modelCtrl.text = s.model;
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() async {
    s.keys = keysCtrl.text;
    s.model = modelCtrl.text.trim().isEmpty ? 'gemini-3.6-flash' : modelCtrl.text.trim();
    await s.save();
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

  Future<void> _pickDir(bool input) async {
    if (!await _ensureStorage()) {
      _log('✖ Aktifkan "Akses semua file" untuk aplikasi ini, lalu pilih folder lagi.');
      return;
    }
    final d = await FilePicker.platform.getDirectoryPath();
    if (d == null) return;
    setState(() {
      if (input) {
        s.inputDir = d;
      } else {
        s.outputDir = d;
      }
    });
    await _save();
  }

  Future<void> _checkKeys() async {
    await _save();
    await Processor.checkKeys(s.keyList, s.model, _log);
  }

  Future<void> _start() async {
    await _save();
    if (!await _ensureStorage()) {
      _log('✖ Izin akses penyimpanan belum diberikan. Aktifkan "Akses semua file" lalu tekan Mulai lagi.');
      return;
    }
    setState(() {
      running = true;
      ok = 0;
      fail = 0;
      total = 0;
      logs.clear();
    });
    await WakelockPlus.enable();
    proc = Processor(s, _log, (o, f, t) {
      if (mounted) {
        setState(() {
          ok = o;
          fail = f;
          total = t;
        });
      }
    });
    try {
      await proc!.run();
    } catch (e) {
      _log('✖ Error tak terduga: $e');
    }
    await WakelockPlus.disable();
    if (mounted) setState(() => running = false);
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
            _section('API Key Gemini', [
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
              TextField(
                controller: modelCtrl,
                enabled: !running,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  border: OutlineInputBorder(),
                ),
              ),
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
            _section('Folder', [
              _dirTile('Folder input (foto/video)', s.inputDir, () => _pickDir(true)),
              const SizedBox(height: 6),
              _dirTile('Folder output', s.outputDir, () => _pickDir(false)),
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
              _switch('Export CSV Adobe Stock', s.csv, (v) => s.csv = v),
              _switch('Auto retry', s.retry, (v) => s.retry = v),
            ]),
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
