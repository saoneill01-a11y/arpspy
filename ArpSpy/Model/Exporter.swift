import Foundation
import AppKit

enum Exporter {
    static let columns = ["Status", "Name", "Type", "IP", "Description", "Manufacturer", "MAC address", "Open ports",
                          "Response (ms)", "Comments", "First seen", "Last seen"]
    static let responseColumn = columns.firstIndex(of: "Response (ms)")!
    /// Column widths in Excel, in characters.
    static let widths = [9, 26, 14, 15, 34, 26, 19, 26, 13, 30, 17, 17]

    static func row(_ d: Device) -> [String] {
        [d.isOnline ? "Online" : "Offline", d.name, d.kind?.label ?? "", d.ip.description, d.details, d.vendor, d.mac,
         d.portsSort, d.responseMs.map { String(format: "%.0f", $0) } ?? "", d.comment,
         d.firstSeen.formatted(date: .numeric, time: .shortened), d.lastSeen.formatted(date: .numeric, time: .shortened)]
    }

    /// The device table for export, with an "In DHCP range" column when the site has a DHCP range.
    static func deviceTable(_ devices: [Device], dhcp: DHCPRange?) -> (header: [String], rows: [[String]], widths: [Int]) {
        guard let dhcp else { return (columns, devices.map(row), widths) }
        return (columns + ["In DHCP range"], devices.map { row($0) + [dhcp.contains($0.ip) ? "Yes" : "No"] }, widths + [14])
    }

    static func csv(_ devices: [Device]) -> String { csv(header: columns, rows: devices.map(row)) }

    /// Any table as CSV.
    static func csv(header: [String], rows: [[String]]) -> String {
        return ([header] + rows)
            .map { $0.map(csvCell).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    /// One CSV cell. Quoted when it needs to be. A cell that starts like a formula (=, +, -, @, tab, return)
    /// gets a leading apostrophe so Excel and Numbers show it as text instead of running it: device names,
    /// web page titles and SNMP strings come straight off the network and could say anything.
    static func csvCell(_ s: String) -> String { CSV.cell(s) }

    /// Tab-separated, so it pastes cleanly into Excel. Tabs and line breaks inside a cell become spaces.
    static func tsv(_ devices: [Device]) -> String {
        ([columns] + devices.map(row)).map { $0.map(tsvCell).joined(separator: "\t") }.joined(separator: "\n")
    }

    static func tsvCell(_ s: String) -> String {
        String(s.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Excel

    /// A real .xlsx: bold header row, frozen top row, sized columns, IP sorted as text.
    static func xlsx(_ devices: [Device], sheetName: String = "ARPradar") -> Data {
        xlsx(header: columns, rows: devices.map(row), widths: widths, numberColumns: [responseColumn], sheetName: sheetName)
    }

    /// One sheet of a workbook.
    struct Sheet {
        var name: String
        var header: [String]
        var rows: [[String]]
        var widths: [Int]
        var numberColumns: Set<Int> = []
    }

    /// Any table as a real .xlsx: bold frozen header, column widths, filter; `numberColumns` are stored as numbers.
    static func xlsx(header columns: [String], rows body: [[String]], widths: [Int], numberColumns: Set<Int> = [],
                     sheetName: String = "ARPradar") -> Data {
        workbook([Sheet(name: sheetName, header: columns, rows: body, widths: widths, numberColumns: numberColumns)])
    }

    /// Excel sheet names: at most 31 characters, none of []:*?/\, and unique in the workbook.
    static func sheetNames(_ wanted: [String]) -> [String] {
        var used = Set<String>()
        return wanted.map { w in
            var base = String(w.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
            if base.isEmpty { base = "Sheet" }
            var name = base, n = 2
            while used.contains(name.lowercased()) {
                let suffix = " (\(n))"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return name
        }
    }

    static func sheetXML(_ sh: Sheet) -> String {
        let rows = [sh.header] + sh.rows
        let width = max(1, rows.map(\.count).max() ?? 1)
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
        <cols>
        """
        for (i, w) in sh.widths.enumerated() { sheet += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>" }
        sheet += "</cols><sheetData>"
        for (r, cells) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in cells.enumerated() {
                let ref = cellRef(column: c, row: r + 1)
                let style = r == 0 ? " s=\"1\"" : ""
                if r > 0, sh.numberColumns.contains(c), let n = Int(value) {
                    sheet += "<c r=\"\(ref)\"><v>\(n)</v></c>"
                } else {
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        let last = cellRef(column: width - 1, row: rows.count)
        sheet += "</sheetData><autoFilter ref=\"A1:\(last)\"/></worksheet>"
        return sheet
    }

    /// A workbook with one sheet per table.
    static func workbook(_ input: [Sheet]) -> Data {
        let sheets = input.isEmpty ? [Sheet(name: "ARPradar", header: [""], rows: [], widths: [])] : input
        let names = sheetNames(sheets.map(\.name))
        var overrides = "", sheetList = "", defined = "", rels = ""
        for (i, sh) in sheets.enumerated() {
            let n = i + 1
            let name = xmlEscape(names[i])
            let width = max(1, ([sh.header] + sh.rows).map(\.count).max() ?? 1)
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheetList += "<sheet name=\"\(name)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            defined += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">'\(name.replacingOccurrences(of: "'", with: "''"))'!$A$1:$\(columnName(width - 1))$\(sh.rows.count + 1)</definedName>"
            rels += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
        }
        rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        var files: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            \(overrides)\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheetList)</sheets><definedNames>\(defined)</definedNames></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """),
            ("xl/styles.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """),
        ]
        for (i, sh) in sheets.enumerated() { files.append(("xl/worksheets/sheet\(i + 1).xml", sheetXML(sh))) }
        return Zip.archive(files.map { ($0.0, Data($0.1.utf8)) })
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func cellRef(column: Int, row: Int) -> String { columnName(column) + String(row) }

    /// Escapes XML and drops characters Excel can't store.
    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Writes a plain (uncompressed) .zip, which is all an .xlsx needs.
enum Zip {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        let time = 0, date = (46 << 9) | (1 << 5) | 1        // 2026-01-01 00:00
        for f in files {
            let name = Array(f.name.utf8)
            let crc = crc32(f.data)
            let size = UInt32(f.data.count)
            let offset = UInt32(out.count)
            let common = u16(20) + u16(0x0800) + u16(0) + u16(time) + u16(date) + u32(crc) + u32(size) + u32(size)
                + u16(name.count) + u16(0)
            out += [0x50, 0x4B, 0x03, 0x04] + common + name
            out += f.data
            central += [0x50, 0x4B, 0x01, 0x02] + u16(20) + common + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + name
        }
        let centralOffset = UInt32(out.count)
        out += central
        out += [0x50, 0x4B, 0x05, 0x06] + u16(0) + u16(0) + u16(files.count) + u16(files.count)
            + u32(UInt32(central.count)) + u32(centralOffset) + u16(0)
        return out
    }

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
