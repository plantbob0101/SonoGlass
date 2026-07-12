import Foundation

public enum XMLText {
    public static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    public static func unescape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&#34;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }
}

/// Flattens an XML document into leaf-element-name → accumulated text.
/// Escaped inner XML (e.g. DIDL inside <TrackMetaData>) arrives already unescaped.
final class FlatXMLParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var currentElement = ""

    static func parse(_ data: Data) -> [String: String] {
        let p = FlatXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        return p.values
    }

    static func parse(_ string: String) -> [String: String] {
        parse(Data(string.utf8))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !currentElement.isEmpty else { return }
        values[currentElement, default: ""] += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !currentElement.isEmpty, let s = String(data: CDATABlock, encoding: .utf8) else { return }
        values[currentElement, default: ""] += s
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        currentElement = ""
    }
}

/// Parses DIDL-Lite documents into DIDLItem values (items and containers).
final class DIDLParser: NSObject, XMLParserDelegate {
    private(set) var items: [DIDLItem] = []
    private var current: DIDLItem?
    private var currentElement = ""
    private var buffer = ""

    static func parse(_ didl: String) -> [DIDLItem] {
        let p = DIDLParser()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "item", "container":
            var item = DIDLItem()
            item.id = attributeDict["id"] ?? ""
            item.isContainer = (elementName == "container")
            current = item
        default:
            break
        }
        currentElement = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard var item = current else { return }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "dc:title": item.title = text
        case "dc:creator": item.artist = text
        case "upnp:album": item.album = text
        case "upnp:albumArtURI": if item.albumArtURI.isEmpty { item.albumArtURI = text }
        case "upnp:class": item.upnpClass = text
        case "r:description": item.description = text
        case "res": if item.res.isEmpty { item.res = text }
        case "r:resMD": item.resMD = text
        case "item", "container":
            items.append(item)
            current = nil
            buffer = ""
            return
        default:
            break
        }
        current = item
        buffer = ""
    }
}

/// Parses the (already unescaped) ZoneGroupState document.
final class ZoneGroupParser: NSObject, XMLParserDelegate {
    private(set) var groups: [ZoneGroup] = []
    private var currentID = ""
    private var currentCoordinator = ""
    private var currentMembers: [SonosDevice] = []

    static func parse(_ xml: String) -> [ZoneGroup] {
        let p = ZoneGroupParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.groups
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            currentID = a["ID"] ?? ""
            currentCoordinator = a["Coordinator"] ?? ""
            currentMembers = []
        case "ZoneGroupMember", "Satellite":
            guard elementName == "ZoneGroupMember" else { return } // skip bonded satellites
            if a["Invisible"] == "1" { return }
            guard let udn = a["UUID"], let location = a["Location"],
                  let ip = URL(string: location)?.host else { return }
            let name = a["ZoneName"] ?? ip
            currentMembers.append(SonosDevice(udn: udn, ip: ip, roomName: name))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "ZoneGroup", !currentMembers.isEmpty {
            groups.append(ZoneGroup(id: currentID, coordinatorUDN: currentCoordinator, members: currentMembers))
        }
    }
}

/// Parses a GENA LastChange <Event> document: element name → val attribute.
/// For channel-scoped values (Volume/Mute) only the Master channel is kept.
final class LastChangeParser: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]

    static func parse(_ xml: String) -> [String: String] {
        let p = LastChangeParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        guard let val = a["val"] else { return }
        if let channel = a["channel"], channel != "Master" { return }
        values[elementName] = val
    }
}

/// Parses ListAvailableServices' AvailableServiceDescriptorList (unescaped).
final class ServiceListParser: NSObject, XMLParserDelegate {
    private(set) var services: [MusicService] = []

    static func parse(_ xml: String) -> [MusicService] {
        let p = ServiceListParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = p
        parser.parse()
        return p.services
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        guard elementName == "Service", let idStr = a["Id"], let id = Int(idStr),
              let name = a["Name"] else { return }
        services.append(MusicService(id: id, name: name))
    }
}
