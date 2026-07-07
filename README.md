# Deck

Çoklu proje geliştirme kokpiti — macOS için native SwiftUI uygulaması.

Her projen bir **masaüstü**: Claude, servis, terminal ve web ikonlarını ekranda istediğin yere dizersin. Çift tıkla çalıştırır, sekmeli tam ekran workspace'te yönetirsin.

## Özellikler

- 🗂 **Çoklu proje** — her proje kendi dizini ve kendi masaüstü ekranıyla
- ▶️ **Servis yönetimi** — backend/frontend servislerini ikondan başlat/durdur/yeniden başlat; port hazır olunca yeşil, çökünce kırmızı
- ✳️ **Kalıcı Claude sekmeleri** — tmux destekli; uygulamayı kapatsan da Claude oturumların yaşar, açınca sekmeler geri gelir
- ⏪ **Claude resume** — kapattığın oturumlara sağ tıkla geri dön (`claude --resume`)
- 🔔 **Claude hook bildirimleri** — Claude beklemeye geçince ses + bildirim + Dock rozeti
- 🌐 **Gömülü tarayıcı** — proje linklerin uygulama içinde, Web Inspector (sağ tık → Inspect Element) dahil
- ⌨️ **Terminal** — tek seferlik komutlar (`php artisan optimize`...) veya proje dizininde açılan interaktif shell

## Kurulum

```bash
brew install tmux        # Claude sekmeleri için gerekli
./install.sh             # /Applications/Deck.app
```

## Geliştirme

```bash
swift build              # derle
./build.sh               # Deck.app paketle
./dist.sh                # dağıtım (universal + Deck.zip)
```

Mimari: `docs/DESIGN.md` · API sözleşmesi: `docs/API.md`
