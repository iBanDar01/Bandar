# CineBridge 0.1 — iPhone Cinematic → Windows Virtual Camera

هذا مشروع أولي مفتوح المصدر هدفه إرسال صورة كاميرا الآيفون مباشرة إلى ويندوز بدون Screen Mirroring وبدون Iriun/Camo.

## ما الذي يفعله؟

**iPhone:**
`AVCaptureSession → Apple Cinematic (عند توفره) → VideoToolbox H.264 → RTP`

**Windows:**
`RTP → PyAV H.264 decode → NV12 → OBS/Unity Virtual Camera`

يوجد وضعان للنقل:

- **Wi‑Fi UDP:** أقل طبقات ممكنة، مناسب للشبكة المحلية السريعة.
- **USB TCP:** Port Forward عبر usbmuxd/pymobiledevice3 مباشرة داخل Receiver، مفيد لتجنب تقطيع الواي فاي. إرسال TCP يستخدم micro-batching بحوالي 1ms لتقليل overhead مع 4K.

## التوافق

- Deployment Target: **iOS 18+**.
- Apple native live Cinematic capture API: **iOS 26+ فقط** وعلى جهاز/Format يدعمه.
- على iOS 18–25 يعمل التطبيق بوضع Standard عالي الجودة بدل Cinematic native.
- الأجيال الجديدة من iPhone لا تعتمد على قائمة أسماء أجهزة؛ يتم فحص قدرات الكاميرا Runtime، لذلك iPhone 18 وما بعده يدخل تلقائيًا طالما AVFoundation يعلن الدعم.
- ويندوز 10/11.

## Cinematic

عند iOS 26+:

- `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled = true`
- Bokeh مطبق على `AVCaptureVideoDataOutput` نفسه، وليس Blur صناعي على الكمبيوتر.
- `simulatedAperture` يتم ضبطه قبل بدء الالتقاط.
- الضغط على الشخص داخل المعاينة يستعمل `setCinematicVideoTrackingFocus` لتغيير هدف التتبع.

## الدقة والأداء

Presets:

- 1920×1080 @ 60 fps
- 1920×1080 @ 30 fps
- 3840×2160 @ 30 fps

VideoToolbox:

- H.264 hardware encode
- RealTime = true
- B-frames disabled
- 1-second GOP تقريبًا
- SPS/PPS يعاد إرسالهما مع كل Keyframe
- RTP RFC 6184 مع FU-A للـ NAL الكبيرة

## بناء تطبيق iPhone

### الطريقة A — Mac + Xcode 26

1. ثبّت XcodeGen: `brew install xcodegen`
2. داخل مجلد `ios`: شغّل `xcodegen generate`.
3. افتح `CineBridge.xcodeproj`.
4. اختر Signing Team الخاص بك.
5. Build & Run على الآيفون.

### الطريقة B — Windows فقط باستخدام GitHub Actions

المشروع يحتوي `.github/workflows/build-ipa.yml`.

1. ارفع المجلد إلى GitHub.
2. افتح Actions → **Build unsigned IPA** → Run workflow.
3. نزّل artifact باسم `CineBridge-unsigned-IPA`.
4. الـIPA غير موقّع؛ وقّعه وثبّته على الآيفون بأداة sideloading موثوقة وحساب Apple الخاص بك.

> لا يمكن بناء تطبيق iOS فعليًا على ويندوز محليًا بدون toolchain من Apple/macOS؛ الـworkflow يستخدم macOS runner للبناء فقط.

## تشغيل ويندوز

ابدأ بـ `QUICK_START_AR.txt` ثم راجع `windows/README_WINDOWS_AR.md` للتفاصيل.

## إعداد أنصح به كبداية

1. الآيفون أفقي على حامل.
2. الكاميرا الخلفية Wide الرئيسية.
3. Cinematic ON.
4. f/2.8 إلى f/4.0.
5. 4K30 / 32 Mbps للجودة، أو 1080p60 / 18 Mbps للأقل تأخير.
6. اضغط على وجهك في Preview لتثبيت/توجيه التتبع.
7. لا تستخدم Digital Zoom إن لم تكن مضطرًا.
8. ثبّت الإضاءة أمامك؛ جودة العزل والفوكس تتحسن جدًا مع الإضاءة الجيدة.

## حدود الإصدار 0.1

- لم يتم توقيع IPA لأن التوقيع مرتبط بحساب Apple الخاص بك.
- لم يتم اختبار هذا البناء على جهاز iPhone فعلي داخل بيئة التنفيذ الحالية؛ Swift/iOS يحتاج Xcode 26 وجهاز حقيقي لاختبار Cinematic.
- Receiver على ويندوز يفك H.264 بالـFFmpeg/PyAV ثم يدفع NV12 إلى Virtual Camera. للحصول على أقل زمن ممكن داخل OBS تحديدًا، مستقبلًا يمكن استبداله بPlugin GPU zero-copy مشابه لـ AVOLO-CAM.
- الصوت غير مضاف في 0.1؛ هذا الإصدار Video only.

## لماذا ليس Screen Mirroring؟

لأن Screen Mirroring يصور واجهة الشاشة نفسها ويضيف scaling/compression إضافي. هنا نحن نأخذ `CVPixelBuffer` من AVFoundation مباشرة، نضغطه Hardware H.264، ثم نرسله للكمبيوتر.
