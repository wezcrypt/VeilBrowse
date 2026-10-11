# WezCrypt Secure Studio

خزنة صور وفيديوهات خاصة ومشفّرة — تطبيق iPhone أصلي (SwiftUI) متصل بسيرفر WezCrypt.

| | |
|---|---|
| المطوّر | wezcrypt — https://wezcrypt.com |
| النظام | iOS 17+ (مُصمَّم لـ iPhone 15) |
| اللغة / الواجهة | Swift 6 · SwiftUI · PhotoKit · AVFoundation · CryptoKit |
| السيرفر | `https://studio.rextv.sbs` — FastAPI على Ubuntu 24.04 |
| معرّف الحزمة | `com.wezcrypt.securestudio` |

> **صراحة أمنية:** التشفير الحالي **تشفير على السيرفر** (AES-256-GCM عند التخزين + HTTPS أثناء النقل). السيرفر يملك المفتاح الرئيسي، لذلك **ليس End-to-End Encrypted**. تصميم التشفير على الجهاز موثّق في [`SECURITY.md`](SECURITY.md) كخيار مستقبلي.

---

## محتويات المستودع

```
ios/                               تطبيق iPhone
  WezCryptSecureStudio.xcodeproj   مشروع Xcode (مُولَّد من scripts/generate_xcodeproj.rb)
  WezCryptSecureStudio/
    App/                           نقطة الدخول، AppDelegate، تركيب الاعتماديات
    Core/Auth                      AuthManager — ربط الجهاز عبر بوت تيليجرام
    Core/Security                  Keychain، مفتاح Secure Enclave، قفل Face ID
    Core/Crypto                    WZC2 (AES-256-GCM مجزّأ)، SHA-256، RecoveryKit
    Core/Networking                APIClient (HTTPS فقط) ونماذج الـ API
    Core/Photos                    PhotoKit: الصلاحيات، التصدير من iCloud، المسح
    Core/Sync                      Sync All: SyncEngine، SQLite، رفع مجزّأ في الخلفية
    Core/Media                     تحميل الصور المصغّرة، بث الفيديو بـ HTTP Range
    Core/Albums                    إدارة الألبومات
    Features/                      Library · Albums · Search · Transfers · Settings · Viewer
  WezCryptSecureStudioTests/       اختبارات وحدة (تشمل توافق WZC2 مع بايثون بايتًا ببايت)
  WezCryptSecureStudioUITests/     اختبار واجهة
backend/                           Mobile API (حزمة wezcrypt_mobile) — إضافة لا تمس الاستوديو الحالي
  wezcrypt_mobile/migrations/      ترحيلات قاعدة البيانات
  deploy/                          systemd · nginx · install.sh
  tests/                           اختبارات pytest
docs/                              API.md · BACKEND_INTEGRATION.md · SIGNING_AND_INSTALL.md
.github/workflows/                 بناء iOS على macOS، اختبارات الـ backend
```

## المزايا

**المكتبة (Library):** All Photos · Recent · Days · Months · Years، مع مصدرين: *الخزنة* (السيرفر) و*هذا الـ iPhone* (PhotoKit مع علامة ✓ للعناصر المرفوعة). تحميل كسول بالصفحات (cursor) — يتحمّل مكتبات 100,000+ عنصر.

**Sync All:** زر واحد يفحص المكتبة كاملة، يحدد غير المرفوع، ويرفعه تلقائيًا:
- مسح كامل أول مرة، ثم **مسح تزايدي** عبر `PHPersistentChangeToken`.
- تصدير **الملف الأصلي** وتنزيله من iCloud Photos عند الحاجة. لا حذف من الجهاز إطلاقًا.
- SHA-256 لكل ملف ولكل جزء؛ منع التكرار على السيرفر حسب البصمة.
- رفع **مجزّأ قابل للاستكمال** (8 MiB) — السيرفر هو مرجع الـ offset، فالاستئناف يعمل بعد انقطاع الشبكة أو إغلاق التطبيق.
- إيقاف مؤقت/استئناف، 1–4 رفعات متوازية، Wi‑Fi فقط أو Wi‑Fi + خلوي، احترام Low Data Mode.
- عرض السرعة، الوقت المتبقي، العدد/الحجم المتبقي، المساحة الحرة على الجهاز.
- **Background URLSession** لإكمال الجزء الجاري عند تعليق التطبيق، و**BGProcessingTask/BGAppRefreshTask**.

> iOS **لا يسمح** بمزامنة مستمرة غير محدودة في الخلفية. النظام يقرر متى تعمل مهام الخلفية (غالبًا أثناء الشحن على Wi‑Fi) ولمدة محدودة. التطبيق يستأنف من حيث توقف كلما سمح النظام، وعند فتحه.

**Transfers:** Pending · Uploading · Completed · Failed مع Retry فردي وجماعي.

**العارض:** ملء الشاشة، Pinch‑to‑Zoom ونقر مزدوج، سحب بين العناصر، مشغّل فيديو مخصص (تشغيل/إيقاف، ±10 ث، شريط تقدم، المدة)، بث تدريجي عبر `AVAssetResourceLoaderDelegate` بطلبات HTTP Range مصادَق عليها (بدون رموز في الروابط وبدون تحميل الفيديو كاملًا في الذاكرة)، رسالة واضحة للصيغ غير المدعومة. الصور الكاملة تُفك بـ ImageIO بحجم الشاشة ثم يُحذف الملف المؤقت فورًا.

**الألبومات:** إنشاء، إعادة تسمية، حذف، إضافة/إزالة دون حذف الملفات، المفضلة، Videos، Screenshots، Recently Added، حجم كل ألبوم، تحديد متعدد، تفاصيل الملف (الاسم، الحجم، التاريخ، النوع، الأبعاد، المدة).

**البحث:** باسم الملف، حسب التاريخ ونوع الوسائط، وداخل ألبوم.

**الإعدادات:** Storage · Encryption · Synchronization · Security (Face ID، مهلة القفل، إخفاء المحتوى في مبدّل التطبيقات، الأجهزة المرتبطة وإلغاؤها) · Account · About Developer.

## التشغيل السريع

### 1) السيرفر (Ubuntu 24.04)
الخدمة الجديدة تعمل **كعملية منفصلة** على `127.0.0.1:8090` ويوجّه nginx المسار `/api/mobile/` فقط إليها. الاستوديو الحالي و`/api/files` و`/api/preview` و`/api/video` لا تُمس.

```bash
sudo bash backend/deploy/install.sh          # ينشئ المستخدم، venv، المفاتيح، الترحيلات، systemd
sudo nano /etc/wezcrypt-mobile/mobile.env     # WZC_MOBILE_ALLOWED_TELEGRAM_IDS و WZC_MOBILE_BOT_USERNAME
sudo bash backend/deploy/install.sh          # إعادة التشغيل بالإعدادات
# أضف backend/deploy/nginx-mobile.conf داخل server block الخاص بـ studio.rextv.sbs
sudo nginx -t && sudo systemctl reload nginx
```
**احفظ نسخة احتياطية خارجية من `/etc/wezcrypt-mobile/master.keys`** — فقدانه يعني استحالة فك ملفات WZC2.

ثم اربط البوت: أضف أمر `/pair` كما في [`docs/BACKEND_INTEGRATION.md`](docs/BACKEND_INTEGRATION.md).

### 2) التطبيق (من Windows بدون Mac)
1. ادفع المستودع إلى GitHub — workflow **iOS** يبني ويختبر على macOS تلقائيًا.
2. من تبويب Actions حمّل artifact:
   - `WezCryptSecureStudio-unsigned` — **غير موقّع، لا يُثبّت مباشرة** على iPhone.
   - `WezCryptSecureStudio-signed-*` — يظهر فقط بعد إضافة أسرار التوقيع.
3. التفاصيل الكاملة للتوقيع والتثبيت: [`docs/SIGNING_AND_INSTALL.md`](docs/SIGNING_AND_INSTALL.md).

### 3) الربط
افتح التطبيق ← **Generate Pairing Code** ← اضغط **Open Telegram** (أو أرسل `/pair XXXX-XXXX` للبوت) ← يفتح التطبيق تلقائيًا. ثم Transfers ← **Sync All**.

## التطوير

```bash
# Backend
cd backend && pip install -r requirements-dev.txt && python -m pytest -q

# إعادة توليد مشروع Xcode بعد إضافة/حذف ملفات (يعمل على Windows/Linux/macOS)
gem install xcodeproj
ruby ios/scripts/generate_xcodeproj.rb
```

عنوان الـ API قابل للتغيير عبر build setting `WZC_API_BASE_URL` (HTTPS فقط).

## ما يتطلب حسابك أو أسرارك
- **Apple Developer Program** لتوقيع IPA قابل للتثبيت (راجع الدليل).
- أسرار GitHub للتوقيع — لا تُوضع أبدًا داخل المستودع ولا في المحادثة.
- ربط خطافات WZC1 (`WZC_MOBILE_LEGACY_*`) بدوال الاستوديو الحالي إن أردت عرض الملفات القديمة في التطبيق — الكود الحالي للسيرفر لم يكن متاحًا في هذا المستودع لفحصه، لذا لم يُعدّل ولم يُفترض شكله.

## الترخيص
© wezcrypt. جميع الحقوق محفوظة.
