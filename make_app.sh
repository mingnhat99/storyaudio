#!/bin/bash
# StoryAudio — build release + đóng gói StoryAudio.app (ad-hoc codesign)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT/app"

echo "==> swift build -c release"
swift build -c release

BIN="$ROOT/app/.build/release/StoryAudio"
APP="$ROOT/build-app/StoryAudio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/StoryAudio"
# Tài nguyên phải nằm trong StoryAudio_StoryAudio.bundle — app đọc qua bundle
# SPM, copy trải phẳng vào Contents/Resources app sẽ không thấy (bản cũ thiếu
# bundle này crash trên máy người dùng mới ngay khi chọn thư mục làm việc).
SPM_RES="$APP/Contents/Resources/StoryAudio_StoryAudio.bundle"
mkdir -p "$SPM_RES"
cp "$ROOT/app/Sources/StoryAudio/Resources/tts_worker.py" "$SPM_RES/"
cp "$ROOT/app/Sources/StoryAudio/Resources/catalog.json" "$SPM_RES/"
cp "$ROOT/app/Sources/StoryAudio/Resources/setup_runtime.sh" "$SPM_RES/"
if [ -f "$ROOT/app/AppIcon.icns" ]; then
	cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>StoryAudio</string>
	<key>CFBundleDisplayName</key>
	<string>StoryAudio</string>
	<key>CFBundleIdentifier</key>
	<string>com.storyaudio.app</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>StoryAudio</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>EPUB ebook</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>org.idpf.epub-container</string></array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>PDF</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>com.adobe.pdf</string></array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Text</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>public.plain-text</string></array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Word document</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSItemContentTypes</key>
			<array><string>org.openxmlformats.wordprocessingml.document</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --sign - --deep "$APP" 2>/dev/null || codesign --force --sign - "$APP"

echo "==> Xong: $APP"
echo "    Chạy:  open $APP"
echo "    (Lần đầu macOS có thể hỏi xác nhận app chưa ký danh tính — chuột phải → Mở)"
