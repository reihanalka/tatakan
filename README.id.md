<p align="center">
  <img src="docs/screenshots/appicon-preview.png" width="128" alt="Ikon Tatakan">
</p>

<h1 align="center">Tatakan</h1>

<p align="center">
  Rak drag-and-drop buat file, plus panel kecil yang muncul dari notch MacBook.<br>
  Native Swift. Gratis dan open source (MIT).
</p>

<p align="center"><a href="README.md">Read in English</a></p>

---

Tatakan itu tempat naruh barang sebentar. Begitu juga app ini: taruh file dulu selagi pindah-pindah app, nanti tinggal drag keluar ke tempat tujuannya.

![Nook](docs/screenshots/nook-home.png)

## Fitur

- **Shelf**: lagi nge-drag file, goyangin pointer sebentar, rak melayang langsung muncul.
- **Aksi item**: copy, buka di Finder, share, AirDrop, thumbnail cepat.
- **Nook**: panel hitam di notch, isinya Now Playing, Tray, Kalender (agenda hari ini), Timer, dan Notes. Di layar tanpa notch, muncul sebagai pill tipis di atas.
- **Mirror**: cek kamera sebelum call. Nggak ada yang direkam.
- **Notifikasi Bluetooth**: notice kecil pas headphone atau device lain nyambung.

## Instal

Bisa di **Mac Apple Silicon maupun Intel**, minimal **macOS 14 Sonoma**.

### Cara 1: Installer (.pkg) — paling gampang

1. Download **`Tatakan-x.y.z.pkg`** dari [release terbaru](https://github.com/reihanalka/tatakan/releases/latest).
2. Double-click. Kalau macOS bilang developer-nya nggak bisa diverifikasi, buka **System Settings → Privacy & Security**, scroll ke bawah, klik **Open Anyway**, lalu buka installer-nya lagi.
3. Ikuti langkahnya sampai selesai. Tatakan kebuka sendiri dan ikonnya ada di menu bar.

### Cara 2: Terminal, satu baris

```bash
curl -fsSL https://raw.githubusercontent.com/reihanalka/tatakan/main/scripts/install.sh | bash
```

Otomatis download versi terbaru, taruh di `/Applications`, lalu dibuka. Jalanin baris yang sama buat update.

### Cara 3: Disk image (.dmg)

Buka **`Tatakan-x.y.z.dmg`**, drag Tatakan ke Applications, lalu izinkan sekali di **System Settings → Privacy & Security → Open Anyway**.

> [!NOTE]
> Tatakan belum dinotarisasi Apple (butuh akun developer berbayar), jadi macOS kasih peringatan di pembukaan pertama. Installer .pkg dan Terminal udah ngurusin itu. App ini nggak pakai internet sama sekali, dan cuma minta akses Kalender, Bluetooth, dan Kamera pas fiturnya dipakai.

### Uninstall

Quit Tatakan dari ikon menu bar, lalu buang `/Applications/Tatakan.app` ke Trash.

## Build sendiri

Cukup Command Line Tools (`xcode-select --install`), nggak perlu Xcode. Langkah lengkap ada di [README bahasa Inggris](README.md#build-from-source).

## Lisensi

Kode: MIT. Font: SIL OFL 1.1. Nama dan logo "Tatakan" nggak termasuk lisensi MIT, lihat [TRADEMARKS.md](TRADEMARKS.md). Fork boleh banget, asal pakai nama dan ikon sendiri.
