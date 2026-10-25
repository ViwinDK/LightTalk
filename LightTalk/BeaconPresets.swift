import Foundation

/// Canned messages for the two lead stories:
///  1. Camp / disaster coordination beacons (the headline use case)
///  2. Screen-less device diagnostics (the supporting use case)
///
/// Codes are short on purpose — at 5 bits/sec, every character costs ~1.4 s
/// of airtime. The app expands them to full sentences deterministically
/// (BeaconPresets.expansion), and the AI layer can translate them.
struct BeaconPreset: Identifiable {
    let id = UUID()
    let code: String        // what the Arduino actually blinks
    let title: String       // short label
    let detail: String      // what it means, in plain words
    let category: Category

    enum Category: String {
        case camp = "Camp coordination"
        case device = "Device diagnostics"
    }
}

enum BeaconPresets {

    static let camp: [BeaconPreset] = [
        // Codes are compact on purpose: at 1.4 s/character, every character
        // costs hold-time. The phone expands them to full sentences.
        BeaconPreset(code: "WTR 1400", title: "Water distribution",
                     detail: "Water truck arrives at 2:00 PM. Bring containers.",
                     category: .camp),
        BeaconPreset(code: "MED 3", title: "Medical",
                     detail: "Medical tent has moved to location 3.",
                     category: .camp),
        BeaconPreset(code: "FOOD 1800", title: "Food distribution",
                     detail: "Food distribution at 6:00 PM at the main tent.",
                     category: .camp),
        BeaconPreset(code: "CRFW 2000", title: "Curfew",
                     detail: "Curfew begins at 8:00 PM. Stay in your tents.",
                     category: .camp),
        BeaconPreset(code: "SHL B", title: "Shelter",
                     detail: "Shelter B is now open for new arrivals.",
                     category: .camp),
        BeaconPreset(code: "ALCLR", title: "All clear",
                     detail: "All clear. Normal camp activity may resume.",
                     category: .camp),
    ]

    static let device: [BeaconPreset] = [
        BeaconPreset(code: "T23 OK", title: "Sensor reading",
                     detail: "Temperature sensor reads 23°C — within range.",
                     category: .device),
        BeaconPreset(code: "FNFLT", title: "Fan fault",
                     detail: "Cooling fan fault detected. Check the fan unit.",
                     category: .device),
        BeaconPreset(code: "BATLO", title: "Battery low",
                     detail: "Backup battery low. Charge or replace soon.",
                     category: .device),
        BeaconPreset(code: "PMP OK", title: "Pump status",
                     detail: "Pump running normally.",
                     category: .device),
    ]

    static var all: [BeaconPreset] { camp + device }

    /// Deterministic expansion of a decoded code to its full sentence.
    /// Returns nil when the text isn't a known preset (then it's shown raw).
    static func expansion(for raw: String) -> String? {
        localizedExpansion(for: raw, language: "en")
    }

    /// Built-in translations of every preset code (camp + device), so the
    /// language picker works on EVERY phone — no AI model needed. Free text
    /// (not a known code) is the only thing that needs the AI layer to
    /// translate; codes always translate deterministically.
    private static let translations: [String: [String: String]] = [
        "WTR 1400": [
            "es": "El camión de agua llega a las 2:00 PM. Traigan recipientes.",
            "fr": "Le camion d'eau arrive à 14h00. Apportez des récipients.",
            "hi": "पानी का ट्रक दोपहर 2:00 बजे आएगा। बर्तन साथ लाएं।",
            "ta": "தண்ணீர் லாரி பிற்பகல் 2:00 மணிக்கு வரும். பாத்திரங்களைக் கொண்டு வாருங்கள்.",
            "ar": "تصل شاحنة المياه الساعة 2:00 ظهراً. أحضروا أوعية.",
        ],
        "MED 3": [
            "es": "La carpa médica se ha trasladado al lugar 3.",
            "fr": "La tente médicale a déménagé à l'emplacement 3.",
            "hi": "चिकित्सा तंबू स्थान 3 पर चला गया है।",
            "ta": "மருத்துவ கூடாரம் இடம் 3க்கு மாற்றப்பட்டுள்ளது.",
            "ar": "انتقلت الخيمة الطبية إلى الموقع 3.",
        ],
        "FOOD 1800": [
            "es": "Distribución de comida a las 6:00 PM en la carpa principal.",
            "fr": "Distribution de nourriture à 18h00 à la tente principale.",
            "hi": "शाम 6:00 बजे मुख्य तंबू में भोजन वितरण।",
            "ta": "மாலை 6:00 மணிக்கு முதன்மை கூடாரத்தில் உணவு விநியோகம்.",
            "ar": "توزيع الطعام الساعة 6:00 مساءً في الخيمة الرئيسية.",
        ],
        "CRFW 2000": [
            "es": "El toque de queda comienza a las 8:00 PM. Permanezcan en sus carpas.",
            "fr": "Le couvre-feu commence à 20h00. Restez dans vos tentes.",
            "hi": "रात 8:00 बजे से कर्फ्यू शुरू। अपने तंबू में रहें।",
            "ta": "இரவு 8:00 மணி முதல் ஊரடங்கு. உங்கள் கூடாரங்களில் இருங்கள்.",
            "ar": "يبدأ حظر التجول الساعة 8:00 مساءً. ابقوا في خيامكم.",
        ],
        "SHL B": [
            "es": "El refugio B ya está abierto para nuevos llegados.",
            "fr": "L'abri B est désormais ouvert aux nouveaux arrivants.",
            "hi": "शेल्टर B नए लोगों के लिए अब खुला है।",
            "ta": "தங்குமிடம் B புதியவர்களுக்கு திறக்கப்பட்டுள்ளது.",
            "ar": "الملجأ B مفتوح الآن للقادمين الجدد.",
        ],
        "ALCLR": [
            "es": "Todo despejado. Pueden reanudar la actividad normal del campamento.",
            "fr": "Tout est dégagé. Vous pouvez reprendre l'activité normale du camp.",
            "hi": "सब ठीक है। शिविर की सामान्य गतिविधि फिर से शुरू कर सकते हैं।",
            "ta": "அனைத்தும் சரி. முகாமின் வழக்கமான செயல்பாடுகளைத் தொடரலாம்.",
            "ar": "كل شيء واضح. يمكن استئناف النشاط الطبيعي للمخيم.",
        ],
        "T23 OK": [
            "es": "El sensor de temperatura marca 23°C — dentro del rango normal.",
            "fr": "Le capteur de température indique 23°C — dans la plage normale.",
            "hi": "तापमान सेंसर 23°C दिखा रहा है — सामान्य सीमा के भीतर है।",
            "ta": "வெப்பநிலை சென்சார் 23°C காட்டுகிறது — சாதாரண வரம்பிற்குள் உள்ளது.",
            "ar": "مستشعر الحرارة يسجل 23 درجة مئوية — ضمن النطاق الطبيعي.",
        ],
        "FNFLT": [
            "es": "Fallo detectado en el ventilador de refrigeración. Revisen la unidad del ventilador.",
            "fr": "Panne du ventilateur de refroidissement détectée. Vérifiez le ventilateur.",
            "hi": "कूलिंग फैन में खराबी मिली है। फैन यूनिट की जांच करें।",
            "ta": "குளிரூட்டும் விசிறியில் கோளாறு கண்டறியப்பட்டது. விசிறி அலகைச் சரிபார்க்கவும்.",
            "ar": "تم اكتشاف عطل في مروحة التبريد. افحصوا وحدة المروحة.",
        ],
        "BATLO": [
            "es": "Batería de respaldo baja. Cárguenla o reemplácenla pronto.",
            "fr": "Batterie de secours faible. Chargez-la ou remplacez-la bientôt.",
            "hi": "बैकअप बैटरी कम है। जल्द चार्ज करें या बदलें।",
            "ta": "காப்பு பேட்டரி குறைவாக உள்ளது. விரைவில் சார்ஜ் செய்யவும் அல்லது மாற்றவும்.",
            "ar": "بطارية الاحتياط منخفضة. اشحنوها أو استبدلوها قريباً.",
        ],
        "PMP OK": [
            "es": "La bomba funciona con normalidad.",
            "fr": "La pompe fonctionne normalement.",
            "hi": "पंप सामान्य रूप से चल रहा है।",
            "ta": "பம்ப் சாதாரணமாக இயங்குகிறது.",
            "ar": "المضخة تعمل بشكل طبيعي.",
        ],
    ]

    /// Expansion in the requested language (falls back to English).
    static func localizedExpansion(for raw: String, language: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Pattern codes first: "WTR 1000", "WTR 1530" — any time works.
        if let timed = waterExpansion(for: key, language: language) {
            return timed
        }
        // "MED 5", "MED 12" — any location works, same as WTR's time.
        if let med = medicalExpansion(for: key, language: language) {
            return med
        }
        guard let preset = all.first(where: { $0.code.uppercased() == key }) else { return nil }
        if language != "en", let t = translations[preset.code]?[language] {
            return t
        }
        return preset.detail
    }

    /// "WTR <HHMM>" → "Water truck arrives at h:MM AM/PM. Bring containers."
    /// in the requested language. The time is variable — the codebook doesn't
    /// need an entry for every possible time.
    private static func waterExpansion(for key: String, language: String) -> String? {
        guard key.hasPrefix("WTR ") else { return nil }
        let timePart = String(key.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(timePart.count), timePart.allSatisfy({ $0.isNumber }) else { return nil }
        let padded = timePart.count == 3 ? "0" + timePart : timePart
        guard let hour = Int(padded.prefix(2)), let minute = Int(padded.suffix(2)),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        let timeEN = "\(hour12):\(String(format: "%02d", minute)) \(ampm)"
        // 24h for French, localized markers elsewhere.
        let time24 = "\(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
        switch language {
        case "es":
            return "El camión de agua llega a las \(timeEN). Traigan recipientes."
        case "fr":
            return "Le camion d'eau arrive à \(time24). Apportez des récipients."
        case "hi":
            let period = hour < 12 ? "सुबह" : (hour < 17 ? "दोपहर" : "शाम")
            return "पानी का ट्रक \(period) \(timeEN) बजे आएगा। बर्तन साथ लाएं।"
        case "ta":
            let period = hour < 12 ? "காலை" : (hour < 17 ? "பிற்பகல்" : "மாலை")
            return "தண்ணீர் லாரி \(period) \(timeEN) மணிக்கு வரும். பாத்திரங்களைக் கொண்டு வாருங்கள்."
        case "ar":
            let period = hour < 12 ? "صباحاً" : "مساءً"
            return "تصل شاحنة المياه الساعة \(timeEN) \(period). أحضروا أوعية."
        default:
            return "Water truck arrives at \(timeEN). Bring containers."
        }
    }

    /// "MED <n>" → "Medical tent has moved to location <n>."
    /// in the requested language. The location number is variable — the
    /// codebook doesn't need an entry for every possible location.
    /// (MED 3's output here is identical to its preset entry, so
    /// existing behavior is unchanged.)
    private static func medicalExpansion(for key: String, language: String) -> String? {
        guard key.hasPrefix("MED ") else { return nil }
        let numPart = String(key.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }) else { return nil }
        switch language {
        case "es":
            return "La carpa médica se ha trasladado al lugar \(numPart)."
        case "fr":
            return "La tente médicale a déménagé à l'emplacement \(numPart)."
        case "hi":
            return "चिकित्सा तंबू स्थान \(numPart) पर चला गया है।"
        case "ta":
            return "மருத்துவ கூடாரம் இடம் \(numPart)க்கு மாற்றப்பட்டுள்ளது।"
        case "ar":
            return "انتقلت الخيمة الطبية إلى الموقع \(numPart)."
        default:
            return "Medical tent has moved to location \(numPart)."
        }
    }
}
