Stok Meta
Aplikasi Android untuk membuat judul, keyword, dan kategori foto/video stok secara otomatis dengan AI, lalu menanamkannya ke file dan membuat CSV untuk Adobe Stock. Berjalan di HP, memakai API key milikmu sendiri.
Fitur
Banyak API key sekaligus, dipakai bergantian. Key yang kena limit ditunda otomatis.
Penyedia AI: Gemini, OpenRouter, Groq, Mistral, dan Kustom (penyedia lain bergaya OpenAI, mis. Together atau NVIDIA NIM).
Proses satu folder penuh, sebagian file dari folder, atau file pilihan dari galeri.
Judul bergaya Deskriptif, Singkat, atau SEO, dalam bahasa English atau Indonesia.
Rename file sesuai judul, pindah atau salin ke folder output.
Metadata ditanam langsung ke file: JPG (IPTC + XMP) dan MP4 (tag iTunes + XMP). Setelah menulis, aplikasi membaca ulang file untuk memastikan datanya benar.
Export `metadata_adobe_stock.csv` (kolom Filename, Title, Keywords, Category, Releases).
Nama brand seperti Firefly, Adobe, atau Topaz dibuang otomatis dari judul dan keyword.
Instal
Buka halaman Releases di repositori ini dan unduh `stok-meta.apk` terbaru.
Buka file APK. Android akan meminta izin Install dari sumber tidak dikenal, izinkan untuk browser atau file manager yang kamu pakai.
Buka Stok Meta. Saat diminta, aktifkan Akses semua file agar aplikasi bisa membaca dan memindah file di foldermu.
API key gratis
Penyedia	Tempat mengambil key
Gemini	aistudio.google.com/apikey
OpenRouter	openrouter.ai/keys
Groq	console.groq.com/keys
Mistral	console.mistral.ai/api-keys
Model yang dipakai harus bisa membaca gambar (vision). Nama model sering berganti. Kalau muncul pesan "model tidak ditemukan", ganti dengan model terbaru di dashboard penyedia, lalu tekan Cek key aktif untuk mengujinya.
Cara pakai
Pilih penyedia, tempel API key (satu per baris), dan isi nama model. Tekan Cek key aktif.
Pilih sumber file: Pilih folder, lalu opsional Pilih sebagian untuk mencentang file tertentu. Atau tekan Pilih file untuk memilih dari galeri.
Pilih Folder output.
Atur jumlah keyword (maksimal 49), jeda antar file, style judul, dan bahasa.
Tekan MULAI PROSES. Jangan menutup aplikasi dan jangan mengunci layar sampai selesai.
Hasilnya ada di folder output: file yang sudah di-rename dan ditanami metadata, serta `metadata_adobe_stock.csv`.
Coba dulu dengan 3 sampai 5 file sebelum memproses ratusan file.
Catatan untuk Adobe Stock
Judul, keyword, dan kategori terisi dari metadata di file atau dari CSV. Untuk file yang sudah terlanjur diupload, pakai tombol Upload CSV di portal, karena portal tidak membaca ulang file yang sama.
Setahu kami portal membaca metadata foto JPG dengan baik. Untuk video, kalau judul dan keyword tidak terisi otomatis, pakai CSV.
Pilih file saat upload lewat Files/Dokumen, bukan lewat Photo Picker galeri, karena sebagian pemilih foto Android memberi salinan yang sudah diubah.
Konten buatan AI harus ditandai Created using generative AI tools di portal. Aplikasi ini tidak mengisi kolom itu.
Kamu tetap bertanggung jawab memeriksa judul dan keyword sebelum submit, dan mematuhi aturan Adobe Stock.
Tombol bantu
Periksa metadata file (JPG atau MP4) menampilkan judul dan jumlah keyword yang benar-benar ada di dalam sebuah file. Berguna untuk memastikan metadata tertanam sebelum diupload.
Privasi
API key hanya disimpan di HP-mu dan tidak dikirim ke mana pun selain ke penyedia AI yang kamu pilih.
Gambar (foto, atau 3 frame dari video) dikirim ke penyedia AI yang kamu pilih untuk dianalisis. Baca kebijakan data penyedia itu sebelum memakai konten yang sensitif.
Aplikasi tidak memakai server milik pengembang.
Batasan
Hanya Android. Tidak ada versi iPhone.
Metadata ditanam hanya ke JPG dan MP4. File PNG, WebP, dan MOV tetap diproses dan masuk CSV, tapi metadatanya tidak ditanam.
MP4 jenis fragmen (fMP4) tidak didukung untuk penanaman metadata.
Menanam metadata ke video menulis ulang file, jadi butuh ruang kosong sebesar file itu dan makan waktu untuk video besar.
Proses berhenti kalau aplikasi ditutup atau layar terkunci. Mode latar belakang belum ada.
Mode Pilih file (dari galeri) membuat salinan sementara di cache, jadi video besar akan lebih lambat.
Untuk pengembang
Aplikasi dibuat dengan Flutter. Setiap push ke `main` menjalankan GitHub Actions yang membangun APK dan menerbitkannya di Releases. Berkas di akar repositori:
`main.dart` dan `processor.dart`: kode aplikasi (dipindahkan ke `lib/` saat build)
`pubspec.yaml`: daftar paket
`.github/workflows/build.yml`: build dan rilis APK
`.github/workflows/buat-kunci.yml`: membuat kunci tanda tangan tetap (dijalankan sekali)
Tanpa kunci tetap, APK ditandatangani dengan kunci sementara yang berubah tiap build, sehingga update harus didahului uninstall. Dengan kunci tetap (disimpan di GitHub Secrets), update bisa langsung dipasang di atas versi lama.
