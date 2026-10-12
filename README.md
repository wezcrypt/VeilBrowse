# WezCrypt Secure Studio

نسخ احتياطي **مشفّر طرفيًا** لصور وفيديوهات وملفات iPhone إلى سيرفرك الشخصي — بالجودة الأصلية، بدون أي اعتماد على تيليجرام.

| | |
|---|---|
| المطوّر | wezcrypt — https://wezcrypt.com |
| المنصة | iPhone · iOS 17+ · Swift 6 · SwiftUI · PhotoKit · CryptoKit |
| معرّف الحزمة | `com.wezcrypt.securestudio` |
| السيرفر | `https://studio.rextv.sbs` — FastAPI + SQLite على Ubuntu 24.04 خلف nginx |
| مجلد النسخ | `iphone-backups` |
| النقل | HTTPS (رفع مجزّأ قابل للاستكمال) |

## الفكرة باختصار

- **التشفير يتم على الآيفون قبل الرفع** (AES-256-GCM، مفتاح عشوائي لكل ملف، صيغة WZCE v1 مُوثّقة ومُجزّأة). السيرفر يخزّن نصًا مشفرًا فقط ولا يملك أي مفتاح.
- **مفتاح الاستعادة** (55 حرفًا) هو أصل كل المفاتيح. محفوظ على الجهاز داخل Keychain ومختوم بمفتاح Secure Enclave، ويمكن إدخاله على iPhone جديد أو على كمبيوتر لاستعادة كل شيء.
- **الأصل كما هو**: HEIC/JPEG/PNG/RAW/ProRAW، الصور الحية (الصورة + الفيديو المقترن)، RAW+JPEG، MOV/MP4/HEVC/HDR/4K. لا ضغط ولا تحويل.
- **أسماء الملفات والتواريخ والأبعاد** داخل manifest مشفّر. ما يراه السيرفر موضح في [`SECURITY.md`](SECURITY.md) §6.
- **لا يُحذف أي شيء من مكتبة الصور** إطلاقًا.

## محتويات المستودع

```
ios/                                   تطبيق iPhone (SwiftUI)
  WezCryptSecureStudio/App             نقطة الدخول، AppModel، التنقل
  WezCryptSecureStudio/Core/Crypto     WZCE، VaultKeys، RecoveryKit، KeyVault (Secure Enclave)
  WezCryptSecureStudio/Core/Sync       SyncEngine، QueueStore (SQLite)، TransferPolicy، Background URLSession
  WezCryptSecureStudio/Core/Photos     فحص المكتبة وتصدير الموارد الأصلية
  WezCryptSecureStudio/Core/Server     BackupAPI، اختبار الاتصال، إعدادات السيرفر (Keychain)
  WezCryptSecureStudio/Core/Restore    التنزيل وفك التشفير والتحقق والاستعادة
  WezCryptSecureStudio/Features        Onboarding · Dashboard · Library · Transfers · Settings
  WezCryptSecureStudioTests            اختبارات وحدة + تكامل مع سيرفر حقيقي
  WezCryptSecureStudioUITests          اختبارات واجهة
backend/                               خدمة النسخ المشفّر (حزمة wezcrypt_backup)
  deploy/                              install.sh · rollback.sh · systemd · nginx · أداة الإدارة
  tools/                               wzce.py + wezcrypt_restore.py (استعادة من أي كمبيوتر)
  tests/                               اختبارات pytest
docs/                                  ARCHITECTURE · INSTALLATION · DEPLOYMENT · RECOVERY · STATUS
.github/workflows/                     iOS (اختبارات + IPA + Release) · Backend (pytest)
```

## الشاشات

Welcome ← Connect Server ← Test Connection (6 خطوات فعلية) ← Encryption Setup ← Permissions ← **Dashboard**.
بعدها التبويبات: **Dashboard** (الحالة والمساحة) · **Library** (Photos / Videos / Files + Restore) · **Transfers** (مركز المزامنة: السرعة، الوقت المتبقي، الأخطاء، إعادة المحاولة) · **Settings** (الاتصال، المزامنة، Security، About).

كل عنصر في الواجهة مربوط بوظيفة حقيقية، ولا تُعرض أي حالة نجاح لم تؤكدها استجابة فعلية من السيرفر.

## البدء السريع

1. **السيرفر**: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)
   ```bash
   sudo bash backend/deploy/install.sh
   # أضف backend/deploy/nginx-wezcrypt-backup.conf داخل server block الخاص بـ studio.rextv.sbs
   sudo nginx -t && sudo systemctl reload nginx
   sudo wezcrypt-backup-admin create-user wez
   ```
2. **التطبيق**: [`docs/INSTALLATION.md`](docs/INSTALLATION.md). حمّل `WezCryptSecureStudio-ipa` من GitHub Actions، ثم وقّعه بـ KravaSigner، ثم ثبّته.
3. **الاستعادة**: [`docs/RECOVERY.md`](docs/RECOVERY.md).

## العمل في الخلفية — بصراحة

iOS **لا يسمح** بمزامنة مستمرة في الخلفية. التطبيق يستخدم الآليات الرسمية فقط:
- **Background URLSession**: الأجزاء المشفرة الجاهزة تستمر في الرفع بعد تعليق التطبيق.
- **BGProcessingTask / BGAppRefreshTask**: فرص يحددها النظام (غالبًا أثناء الشحن على Wi‑Fi) لفحص الصور الجديدة وتشفيرها.
- **مراقبة PhotoKit**: الصور الجديدة تُضاف فورًا أثناء فتح التطبيق.

**إغلاق التطبيق بالسحب من مبدّل التطبيقات يلغي عمليات الرفع في الخلفية** حتى تفتحه مجددًا. التفاصيل في [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## التطوير والاختبار

```bash
cd backend && pip install -r requirements-dev.txt && python -m pytest -q
ruby ios/scripts/generate_xcodeproj.rb     # بعد إضافة/حذف ملفات Swift (gem install xcodeproj)
```
اختبارات iOS تعمل على macOS runner ضد نسخة حقيقية من الـ backend على `127.0.0.1`. ما تم اختباره فعلًا وما لم يُختبر موثّق في [`docs/STATUS.md`](docs/STATUS.md).

## الوثائق

| الملف | المحتوى |
|---|---|
| [`SECURITY.md`](SECURITY.md) | نموذج التهديد، هرم المفاتيح، صيغة WZCE، ما يراه السيرفر |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | المكونات، خط المزامنة، الأداء، حدود الخلفية، API |
| [`docs/INSTALLATION.md`](docs/INSTALLATION.md) | تحميل IPA والتحقق منه وتوقيعه وتثبيته |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) | نشر الـ backend وnginx وTLS والتشغيل والتراجع |
| [`docs/RECOVERY.md`](docs/RECOVERY.md) | مفتاح الاستعادة، جهاز جديد، استعادة من كمبيوتر، كشف التلف |
| [`docs/STATUS.md`](docs/STATUS.md) | سجل التقدم ونتائج الاختبارات الفعلية والقيود المعروفة |

## الترخيص
© wezcrypt. جميع الحقوق محفوظة.
