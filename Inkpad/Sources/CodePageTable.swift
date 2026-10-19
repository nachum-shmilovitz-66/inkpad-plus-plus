// Generated from upstream v8.9.8.1 EncodingMapper.cpp (code page + uchardet aliases) and
// Notepad_plus.rc (menu label + Character sets group). Regenerate; do not edit by hand.

struct CodePageInfo {
    let codePage: Int
    /// upstream's menu label, also shown in the status bar.
    let name: String
    /// The Encoding › Character sets submenu it belongs to.
    let group: String
    /// Charset names uchardet may report for it (matched case-insensitively).
    let aliases: [String]
}

let codePageTable: [CodePageInfo] = [
    CodePageInfo(codePage: 1250, name: "Windows-1250", group: "Central European", aliases: ["windows-1250"]),
    CodePageInfo(codePage: 1251, name: "Windows-1251", group: "Cyrillic", aliases: ["windows-1251"]),
    CodePageInfo(codePage: 1252, name: "Windows-1252", group: "Western European", aliases: ["windows-1252"]),
    CodePageInfo(codePage: 1253, name: "Windows-1253", group: "Greek", aliases: ["windows-1253"]),
    CodePageInfo(codePage: 1254, name: "Windows-1254", group: "Turkish", aliases: ["windows-1254"]),
    CodePageInfo(codePage: 1255, name: "Windows-1255", group: "Hebrew", aliases: ["windows-1255"]),
    CodePageInfo(codePage: 1256, name: "Windows-1256", group: "Arabic", aliases: ["windows-1256"]),
    CodePageInfo(codePage: 1257, name: "Windows-1257", group: "Baltic", aliases: ["windows-1257"]),
    CodePageInfo(codePage: 1258, name: "Windows-1258", group: "Vietnamese", aliases: ["windows-1258"]),
    CodePageInfo(codePage: 28591, name: "ISO 8859-1", group: "Western European", aliases: ["latin1", "ISO_8859-1", "ISO-8859-1", "CP819", "IBM819", "csISOLatin1", "iso-ir-100", "l1"]),
    CodePageInfo(codePage: 28592, name: "ISO 8859-2", group: "Eastern European", aliases: ["latin2", "ISO_8859-2", "ISO-8859-2", "csISOLatin2", "iso-ir-101", "l2"]),
    CodePageInfo(codePage: 28593, name: "ISO 8859-3", group: "Turkish", aliases: ["latin3", "ISO_8859-3", "ISO-8859-3", "csISOLatin3", "iso-ir-109", "l3"]),
    CodePageInfo(codePage: 28594, name: "ISO 8859-4", group: "Baltic", aliases: ["latin4", "ISO_8859-4", "ISO-8859-4", "csISOLatin4", "iso-ir-110", "l4"]),
    CodePageInfo(codePage: 28595, name: "ISO 8859-5", group: "Cyrillic", aliases: ["cyrillic", "ISO_8859-5", "ISO-8859-5", "csISOLatinCyrillic", "iso-ir-144"]),
    CodePageInfo(codePage: 28596, name: "ISO 8859-6", group: "Arabic", aliases: ["arabic", "ISO_8859-6", "ISO-8859-6", "csISOLatinArabic", "iso-ir-127", "ASMO-708", "ECMA-114"]),
    CodePageInfo(codePage: 28597, name: "ISO 8859-7", group: "Greek", aliases: ["greek", "ISO_8859-7", "ISO-8859-7", "csISOLatinGreek", "greek8", "iso-ir-126", "ELOT_928", "ECMA-118"]),
    CodePageInfo(codePage: 28598, name: "ISO 8859-8", group: "Hebrew", aliases: ["hebrew", "ISO_8859-8", "ISO-8859-8", "csISOLatinHebrew", "iso-ir-138"]),
    CodePageInfo(codePage: 28599, name: "ISO 8859-9", group: "Turkish", aliases: ["latin5", "ISO_8859-9", "ISO-8859-9", "csISOLatin5", "iso-ir-148", "l5"]),
    CodePageInfo(codePage: 28603, name: "ISO 8859-13", group: "Baltic", aliases: ["ISO_8859-13", "ISO-8859-13"]),
    CodePageInfo(codePage: 28604, name: "ISO 8859-14", group: "Celtic", aliases: ["iso-celtic", "latin8", "ISO_8859-14", "ISO-8859-14", "18", "iso-ir-199"]),
    CodePageInfo(codePage: 28605, name: "ISO 8859-15", group: "Western European", aliases: ["Latin-9", "ISO_8859-15", "ISO-8859-15"]),
    CodePageInfo(codePage: 437, name: "OEM-US : CP437", group: "Western European", aliases: ["IBM437", "cp437", "437", "csPC8CodePage437"]),
    CodePageInfo(codePage: 720, name: "OEM 720", group: "Arabic", aliases: ["IBM720", "cp720", "oem720", "720"]),
    CodePageInfo(codePage: 737, name: "OEM 737", group: "Greek", aliases: ["IBM737", "cp737", "oem737", "737"]),
    CodePageInfo(codePage: 775, name: "OEM 775", group: "Baltic", aliases: ["IBM775", "cp775", "oem775", "775"]),
    CodePageInfo(codePage: 850, name: "OEM 850", group: "Western European", aliases: ["IBM850", "cp850", "oem850", "850"]),
    CodePageInfo(codePage: 852, name: "OEM 852", group: "Central European", aliases: ["IBM852", "cp852", "oem852", "852"]),
    CodePageInfo(codePage: 855, name: "OEM 855", group: "Cyrillic", aliases: ["IBM855", "cp855", "oem855", "855", "csIBM855"]),
    CodePageInfo(codePage: 857, name: "OEM 857", group: "Turkish", aliases: ["IBM857", "cp857", "oem857", "857"]),
    CodePageInfo(codePage: 858, name: "OEM 858", group: "Western European", aliases: ["IBM858", "cp858", "oem858", "858"]),
    CodePageInfo(codePage: 860, name: "OEM 860 : Portuguese", group: "Western European", aliases: ["IBM860", "cp860", "oem860", "860"]),
    CodePageInfo(codePage: 861, name: "OEM 861 : Icelandic", group: "North European", aliases: ["IBM861", "cp861", "oem861", "861"]),
    CodePageInfo(codePage: 862, name: "OEM 862", group: "Hebrew", aliases: ["IBM862", "cp862", "oem862", "862"]),
    CodePageInfo(codePage: 863, name: "OEM 863 : French", group: "Western European", aliases: ["IBM863", "cp863", "oem863", "863"]),
    CodePageInfo(codePage: 865, name: "OEM 865 : Nordic", group: "North European", aliases: ["IBM865", "cp865", "oem865", "865"]),
    CodePageInfo(codePage: 866, name: "OEM 866", group: "Cyrillic", aliases: ["IBM866", "cp866", "oem866", "866"]),
    CodePageInfo(codePage: 869, name: "OEM 869", group: "Greek", aliases: ["IBM869", "cp869", "oem869", "869"]),
    CodePageInfo(codePage: 950, name: "Big5 (Traditional)", group: "Chinese", aliases: ["big5", "csBig5"]),
    CodePageInfo(codePage: 936, name: "GB2312 (Simplified)", group: "Chinese", aliases: ["gb2312", "gbk", "csGB2312", "gb18030"]),
    CodePageInfo(codePage: 932, name: "Shift-JIS", group: "Japanese", aliases: ["Shift_JIS", "MS_Kanji", "csShiftJIS", "csWindows31J"]),
    CodePageInfo(codePage: 949, name: "Windows 949", group: "Korean", aliases: ["windows-949", "korean"]),
    CodePageInfo(codePage: 51949, name: "EUC-KR", group: "Korean", aliases: ["euc-kr", "csEUCKR"]),
    CodePageInfo(codePage: 874, name: "TIS-620", group: "Thai", aliases: ["tis-620"]),
    CodePageInfo(codePage: 10007, name: "Macintosh", group: "Cyrillic", aliases: ["x-mac-cyrillic", "xmaccyrillic"]),
    CodePageInfo(codePage: 21866, name: "KOI8-U", group: "Cyrillic", aliases: ["koi8_u"]),
    CodePageInfo(codePage: 20866, name: "KOI8-R", group: "Cyrillic", aliases: ["koi8_r", "csKOI8R"]),
]
