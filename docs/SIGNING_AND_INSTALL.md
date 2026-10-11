# بناء IPA من Windows وتوقيعه وتثبيته

لا تحتاج جهاز Mac: GitHub Actions يوفّر macOS مع Xcode. لكن **iOS لا يثبّت أي تطبيق غير موقّع**. لا يوجد طريق رسمي لتشغيل IPA غير موقّع على iPhone عادي.

## ما ينتجه الـ CI

| Artifact | متى | قابل للتثبيت؟ |
|---|---|---|
| `test-results` | كل دفع | — نتائج الاختبارات |
| `WezCryptSecureStudio-unsigned` | كل دفع | **لا.** يثبت أن الكود يُبنى لأجهزة iOS فقط. يمكن إعادة توقيعه بأدوات خارجية (انظر الخيار ج) |
| `WezCryptSecureStudio-signed-<method>` | بعد إضافة أسرار التوقيع | **نعم** حسب نوع التوزيع |

## الخيار (أ) — موصى به: Apple Developer Program (99$ سنويًا)

1. اشترك من https://developer.apple.com/programs/ .
2. **App ID:** Certificates, Identifiers & Profiles ← Identifiers ← `+` ← App IDs ← Bundle ID صريح `com.wezcrypt.securestudio` (أو معرّفك). لا حاجة لتفعيل Capabilities إضافية.
3. **سجّل جهاز الـ iPhone** (لتوزيع Ad Hoc): Devices ← `+` ← UDID (يظهر في Finder/iTunes على Windows، أو عبر https://udid.tech ).
4. **إنشاء الشهادة من Windows بدون Mac** (OpenSSL متاح مع Git for Windows):
   ```bash
   openssl genrsa -out wezcrypt.key 2048
   openssl req -new -key wezcrypt.key -out wezcrypt.csr -subj "/emailAddress=you@example.com/CN=wezcrypt/C=US"
   ```
   ارفع `wezcrypt.csr` في Certificates ← `+` ← **Apple Distribution**، ونزّل `distribution.cer` ثم:
   ```bash
   openssl x509 -inform DER -in distribution.cer -out distribution.pem
   openssl pkcs12 -export -legacy -inkey wezcrypt.key -in distribution.pem -out wezcrypt.p12
   ```
   (اختر كلمة مرور قوية للـ p12. إن لم يدعم OpenSSL لديك `-legacy` احذف الخيار.)
5. **Provisioning Profile:** Profiles ← `+` ← **Ad Hoc** (أو App Store Connect لـ TestFlight) ← اختر App ID والشهادة والجهاز ← نزّل `.mobileprovision`.
6. **أضف الأسرار في GitHub** (Settings ← Secrets and variables ← Actions). لا تضعها في المستودع ولا ترسلها في أي محادثة:

   | Secret | القيمة |
   |---|---|
   | `IOS_CERTIFICATE_P12_BASE64` | `base64 -w0 wezcrypt.p12` |
   | `IOS_CERTIFICATE_PASSWORD` | كلمة مرور الـ p12 |
   | `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -w0 profile.mobileprovision` |
   | `IOS_TEAM_ID` | Team ID من صفحة Membership |
   | `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID` / `APP_STORE_CONNECT_KEY_P8_BASE64` | اختياري — للرفع التلقائي إلى TestFlight |

   في PowerShell: `[Convert]::ToBase64String([IO.File]::ReadAllBytes("wezcrypt.p12"))`.

   متغيّر اختياري (Variables): `IOS_EXPORT_METHOD` = `ad-hoc` | `development` | `app-store-connect`.
7. شغّل workflow **iOS** (Actions ← iOS ← Run workflow) واختر طريقة التصدير. معرّف الحزمة يُقرأ من الـ provisioning profile تلقائيًا.
8. **التثبيت:**
   - *Ad Hoc:* نزّل الـ IPA وثبّته عبر Apple Configurator (Mac) أو **Sideloadly / 3uTools على Windows** (تثبيت IPA موقّع مسبقًا لجهاز مسجّل) أو استضافة OTA (`itms-services`) على HTTPS.
   - *TestFlight (الأسهل):* اختر `app-store-connect` مع مفتاح API، ثم ثبّت من تطبيق TestFlight. يتطلب إنشاء التطبيق في App Store Connect مرة واحدة. سيُسأل عن **Export Compliance** لأن التطبيق يستخدم التشفير — أجب حسب وضعك القانوني.
   - فعّل **Developer Mode** على iPhone لتوزيعات Development/Ad Hoc إن طُلب (Settings ← Privacy & Security).

## الخيار (ب) — Apple ID مجاني
الحساب المجاني لا يتيح تصدير IPA من CI بدون Xcode على Mac، والتطبيقات الموقّعة به تنتهي بعد **7 أيام** وبحد 3 تطبيقات.

## الخيار (ج) — إعادة توقيع الـ IPA غير الموقّع (Sideloadly / AltStore)
أدوات مثل Sideloadly وAltStore **تعيد توقيع** IPA بحسابك. قد ينجح ذلك مع `WezCryptSecureStudio-UNSIGNED.ipa` لأن التطبيق لا يستخدم entitlements خاصة، لكن:
- هذا ليس مضمونًا ويعتمد على الأداة وإصدار iOS وقيود الحساب.
- بالحساب المجاني: صلاحية 7 أيام، ومهام الخلفية قد تكون محدودة.
- ليس طريق توزيع رسمي من Apple.

## اختبار محلي بدون جهاز
الـ CI يشغّل اختبارات الوحدة والواجهة على iPhone Simulator في كل دفع — راجع artifact `test-results`.

## ملاحظات
- لا تُرفع الشهادات أو ملفات `.p12/.mobileprovision/.p8` إلى المستودع (محظورة في `.gitignore`).
- الـ CI ينشئ keychain مؤقتًا ويحذفه بعد كل تشغيل.
