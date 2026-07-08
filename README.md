<div align="center">
<img src="Resources/AppIcon.svg" width="128" alt="Dikta icon"/>

# Dikta

**הכתבה קולית לוקלית למק — עברית ואנגלית, בלי ענן, בלי מנוי**

Local push-to-talk dictation for macOS via whisper.cpp. Hold a key, speak, release — the text appears.
</div>

---

## מה זה עושה

מחזיקים קיצור מקלדת (ברירת מחדל: **Right Option**), מדברים, משחררים:

- אם הסמן בשדה טקסט — הטקסט המתומלל **מוקלד ישר פנימה** (והקליפבורד שלך משוחזר אחר כך)
- אם לא — הטקסט **מועתק ללוח** ומופיעה התראה

הכול רץ על המחשב. שום אודיו או טקסט לא עוזב אותו.

## פיצ'רים

- 🎙️ **Press-and-hold** — בלי לחיצות, בלי חלונות; מדברים וזהו
- 🌍 **זיהוי שפה אוטומטי** — עברית מנותבת למודל של [ivrit.ai](https://huggingface.co/ivrit-ai) (אם הורד), שאר השפות ל-Whisper large-v3-turbo
- ⌨️ **קיצור מותאם אישית** — מקש בודד או צירוף (⌃⌥Space וכו'), נלכד מהתפריט
- 🧠 **ניהול זיכרון** — המודלים נפרקים מהזיכרון אחרי 5 דקות ללא שימוש ונטענים מחדש תוך פחות משנייה
- ⚡ **מהיר** — ‏Metal על Apple Silicon; ~0.25 שניות ל-4 שניות דיבור על M5 Pro

## דרישות

- macOS 14+ על Apple Silicon
- Xcode Command Line Tools בלבד (`xcode-select --install`) — **לא צריך Xcode**
- ~600MB דיסק למודל הבסיסי (+1.6GB למודל העברי האופציונלי)

## התקנה

```bash
git clone https://github.com/yahelhai/Dikta.git
cd Dikta
make fetch     # מוריד את whisper.cpp XCFramework (חד-פעמי)
make models    # מוריד את מודל התמלול הבסיסי (~574MB)
make cert      # חד-פעמי: תעודת חתימה כדי שההרשאות ישרדו עדכונים
make install   # בונה ומתקין ל-/Applications
open /Applications/Dikta.app
```

### הרשאות (חד-פעמי)

Dikta צריכה שלוש הרשאות — התפריט שלה מציג ✓/✗ ופותח את המסך הנכון בלחיצה:

| הרשאה | למה |
|---|---|
| מיקרופון | הקלטת הדיבור |
| Accessibility | הזרקת הטקסט וזיהוי שדה הטקסט הממוקד |
| Input Monitoring | האזנה לקיצור הגלובלי (CGEventTap) |

אחרי אישור Input Monitoring יש לצאת ולהפעיל מחדש את Dikta.

## שימוש

1. מחזיקים **Right Option**, מדברים, משחררים
2. **שינוי קיצור:** תפריט → "קיצור: … — שנה…" → מקישים את הצירוף הרצוי
3. **עברית מדויקת יותר:** תפריט → "הורד מודל עברית משופר (ivrit.ai)…" — אחרי ההורדה, במצב Auto כל הכתבה בעברית תנותב אליו אוטומטית
4. **מצבי שפה:** Auto (זיהוי אוטומטי) / English / עברית

## פיתוח

```bash
swift build                                    # בנייה
./.build/debug/Dikta sysinfo                   # בדיקת whisper + Metal
./.build/debug/Dikta transcribe file.wav --language he
./.build/debug/Dikta detect file.wav           # זיהוי שפה בלבד
make bundle && make install                    # אריזה + התקנה
```

יצירת אודיו לבדיקה:

```bash
say -v Carmit "שלום עולם" -o test.wav --data-format=LEI16@16000
```

### מבנה

| קובץ | תפקיד |
|---|---|
| `HotkeyManager.swift` | CGEventTap — לכידת הקיצור הגלובלי ובליעתו |
| `AudioRecorder.swift` | AVAudioEngine → ‏16kHz mono Float32 |
| `Transcriber.swift` | whisper.cpp (actor); cache מודלים + פריקה אוטומטית |
| `FocusInspector.swift` | AX API — האם המוקד בשדה טקסט |
| `OutputRouter.swift` | הזרקה (pasteboard + ⌘V) או העתקה ללוח |
| `ModelManager.swift` | רישום, הורדה ואחסון מודלים |
| `scripts/bundle.sh` | הרכבת `.app` וחתימה — בלי Xcode |

## קרדיטים

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — מנוע התמלול
- [OpenAI Whisper](https://github.com/openai/whisper) — המודלים
- [ivrit.ai](https://www.ivrit.ai) — הפיין-טיון העברי
