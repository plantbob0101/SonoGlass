import Testing
import Foundation
@testable import SonosKit
@testable import PandoraKit

// MARK: - Pandora URI token extraction

@Suite struct PandoraTokenTests {
    @Test func parsesDocumentedShape() {
        let uri = "x-sonos-http:trackTokenABC123%3a%3aST%3a4001234567890123456%3a%3aRINCON_B8E93712345601400?sid=236&flags=8224&sn=1"
        let tokens = PandoraTokens.parse(trackURI: uri)
        #expect(tokens != nil)
        #expect(tokens?.trackToken == "trackTokenABC123")
        #expect(tokens?.stationToken == "4001234567890123456")
    }

    @Test func parsesProgVariantAndUppercaseEscapes() {
        let uri = "x-sonosprog-http:TOK%3A%3AST%3A987654%3A%3ARINCON_000E58AAAAAA01400?sid=236&sn=3"
        let tokens = PandoraTokens.parse(trackURI: uri)
        #expect(tokens?.trackToken == "TOK")
        #expect(tokens?.stationToken == "987654")
    }

    @Test func rejectsNonPandoraURIs() {
        #expect(PandoraTokens.parse(trackURI: "x-sonos-spotify:spotify%3atrack%3aabc?sid=9") == nil)
        #expect(PandoraTokens.parse(trackURI: "") == nil)
        #expect(PandoraTokens.parse(trackURI: "x-sonos-http:song%3a12345.mp4?sid=204") == nil)
    }
}

// MARK: - Blowfish crypto

@Suite struct PandoraCryptoTests {
    @Test func blowfishRoundtrip() throws {
        let plaintext = #"{"username":"test@example.com","password":"hunter2","syncTime":1700000000}"#
        let hex = try PandoraCrypto.encrypt(plaintext, key: PandoraCrypto.encryptKey)
        #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })
        let decrypted = try PandoraCrypto.decrypt(hex, key: PandoraCrypto.encryptKey)
        let roundtripped = String(decoding: decrypted.prefix(plaintext.utf8.count), as: UTF8.self)
        #expect(roundtripped == plaintext)
    }

    @Test func syncTimeDecodeSkipsFourBytesThenTenDigits() throws {
        // Server layout: 4 junk bytes, then 10 ASCII digits (then padding).
        var payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        payload.append(contentsOf: Array("1234567890".utf8))
        let plaintext = String(decoding: payload, as: UTF8.self)
        let hex = try PandoraCrypto.encrypt(plaintext, key: PandoraCrypto.decryptKey)
        let decrypted = try PandoraCrypto.decrypt(hex, key: PandoraCrypto.decryptKey)
        #expect(PandoraCrypto.decodeSyncTime(decrypted) == 1_234_567_890)
    }

    @Test func hexRoundtrip() throws {
        let bytes: [UInt8] = [0x00, 0x7f, 0xff, 0x10]
        let hex = PandoraCrypto.hexEncode(bytes)
        #expect(hex == "007fff10")
        #expect(try PandoraCrypto.hexDecode(hex) == bytes)
    }
}

// MARK: - DIDL parsing

@Suite struct DIDLTests {
    @Test func parsesTrackMetadata() {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item id="-1" parentID="-1" restricted="true">
            <res protocolInfo="sonos.com-http:*:audio/mp4:*">x-sonos-http:tt%3a%3aST%3a42%3a%3aRINCON_AAA01400?sid=236</res>
            <upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack.mp4</upnp:albumArtURI>
            <dc:title>Song Title &amp; More</dc:title>
            <dc:creator>The Artist</dc:creator>
            <upnp:album>The Album</upnp:album>
            <upnp:class>object.item.audioItem.musicTrack</upnp:class>
          </item>
        </DIDL-Lite>
        """
        let items = DIDLParser.parse(didl)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.title == "Song Title & More")
        #expect(item.artist == "The Artist")
        #expect(item.album == "The Album")
        #expect(item.albumArtURI.hasPrefix("/getaa?"))
        let art = item.artURL(via: "192.168.1.42")
        #expect(art?.absoluteString.hasPrefix("http://192.168.1.42:1400/getaa?") == true)
    }

    @Test func parsesFavoriteWithResMD() {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
          <item id="FV:2/13" parentID="FV:2" restricted="false">
            <dc:title>My Pandora Station</dc:title>
            <upnp:class>object.itemobject.item.sonos-favorite</upnp:class>
            <r:description>Pandora Station</r:description>
            <res protocolInfo="x-sonosapi-radio:*:*:*">x-sonosapi-radio:ST%3a4001234?sid=236&amp;flags=8300&amp;sn=2</res>
            <r:resMD>&lt;DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"&gt;&lt;item id="100c206cST%3a4001234"&gt;&lt;dc:title&gt;My Pandora Station&lt;/dc:title&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</r:resMD>
          </item>
        </DIDL-Lite>
        """
        let items = DIDLParser.parse(didl)
        #expect(items.count == 1)
        let fav = items[0]
        #expect(fav.description == "Pandora Station")
        #expect(fav.res == "x-sonosapi-radio:ST%3a4001234?sid=236&flags=8300&sn=2")
        // resMD arrives unescaped, ready to pass back as the metadata argument.
        #expect(fav.resMD.contains("<dc:title>My Pandora Station</dc:title>"))
        #expect(SonosURI.queryParam("sn", in: fav.res) == "2")
        #expect(SonosURI.queryParam("sid", in: fav.res) == "236")
    }
}

// MARK: - Favorite res-scheme classification

@Suite struct ClassifierTests {
    @Test func streams() {
        for res in [
            "x-sonosapi-stream:s12345?sid=254",
            "x-sonosapi-radio:ST%3a1?sid=236",
            "x-sonosapi-hls:catalog?sid=204",
            "x-rincon-mp3radio://http://stream.example/live",
            "hls-radio://example.com/master.m3u8",
            "aac://stream.example/live.aac",
        ] {
            #expect(FavoriteClassifier.classify(res: res) == .stream, "expected stream for \(res)")
        }
    }

    @Test func containers() {
        for res in [
            "x-rincon-cpcontainer:1006206ccatalog%2fplaylists?sid=204",
            "file:///jffs/settings/savedqueues.rsq#7",
        ] {
            #expect(FavoriteClassifier.classify(res: res) == .container, "expected container for \(res)")
        }
    }

    @Test func unknown() {
        #expect(FavoriteClassifier.classify(res: "spotify:playlist:abc") == .unknown)
    }
}

// MARK: - Zone group topology

@Suite struct ZoneGroupTests {
    @Test func parsesCannedZoneGroupState() {
        let xml = """
        <ZoneGroupState>
          <ZoneGroups>
            <ZoneGroup Coordinator="RINCON_AAAA01400" ID="RINCON_AAAA01400:12">
              <ZoneGroupMember UUID="RINCON_AAAA01400" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="0"/>
              <ZoneGroupMember UUID="RINCON_BBBB01400" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Kitchen"/>
              <ZoneGroupMember UUID="RINCON_SUB01400" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="Living Room (Sub)" Invisible="1"/>
            </ZoneGroup>
            <ZoneGroup Coordinator="RINCON_CCCC01400" ID="RINCON_CCCC01400:5">
              <ZoneGroupMember UUID="RINCON_CCCC01400" Location="http://192.168.1.20:1400/xml/device_description.xml" ZoneName="Office"/>
            </ZoneGroup>
          </ZoneGroups>
        </ZoneGroupState>
        """
        let groups = ZoneGroupParser.parse(xml)
        #expect(groups.count == 2)

        let living = groups.first { $0.coordinatorUDN == "RINCON_AAAA01400" }
        #expect(living != nil)
        #expect(living?.members.count == 2)          // invisible sub skipped
        #expect(living?.displayName == "Living Room + 1")
        #expect(living?.coordinator?.ip == "192.168.1.10")

        let office = groups.first { $0.coordinatorUDN == "RINCON_CCCC01400" }
        #expect(office?.displayName == "Office")
        #expect(office?.members.count == 1)
    }

    @Test func parsesEscapedResponseViaFlatParser() {
        // GetZoneGroupState returns the document XML-escaped inside <ZoneGroupState>;
        // FlatXMLParser must hand back the unescaped inner document.
        let soap = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:GetZoneGroupStateResponse xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1">
        <ZoneGroupState>&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;&lt;ZoneGroup Coordinator="RINCON_X01400" ID="RINCON_X01400:1"&gt;&lt;ZoneGroupMember UUID="RINCON_X01400" Location="http://192.168.1.30:1400/xml/device_description.xml" ZoneName="Den"/&gt;&lt;/ZoneGroup&gt;&lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;</ZoneGroupState>
        </u:GetZoneGroupStateResponse></s:Body></s:Envelope>
        """
        let flat = FlatXMLParser.parse(soap)
        let inner = flat["ZoneGroupState"]
        #expect(inner?.contains("<ZoneGroup ") == true)
        let groups = ZoneGroupParser.parse(inner ?? "")
        #expect(groups.count == 1)
        #expect(groups[0].members[0].roomName == "Den")
    }
}

// MARK: - LastChange events

@Suite struct LastChangeTests {
    @Test func parsesTransportAndTrack() {
        let event = """
        <Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
          <InstanceID val="0">
            <TransportState val="PLAYING"/>
            <CurrentTrackURI val="x-sonos-http:tok%3a%3aST%3a99%3a%3aRINCON_Z01400?sid=236"/>
          </InstanceID>
        </Event>
        """
        let values = LastChangeParser.parse(event)
        #expect(values["TransportState"] == "PLAYING")
        #expect(values["CurrentTrackURI"]?.contains("%3a%3aST%3a99") == true)
    }

    @Test func keepsOnlyMasterChannel() {
        let event = """
        <Event xmlns="urn:schemas-upnp-org:metadata-1-0/RCS/">
          <InstanceID val="0">
            <Volume channel="Master" val="31"/>
            <Volume channel="LF" val="100"/>
            <Mute channel="Master" val="0"/>
          </InstanceID>
        </Event>
        """
        let values = LastChangeParser.parse(event)
        #expect(values["Volume"] == "31")
        #expect(values["Mute"] == "0")
    }
}

// MARK: - XML escaping

@Suite struct XMLTextTests {
    @Test func escapeRoundtrip() {
        let raw = #"<DIDL-Lite a="1">Tom & Jerry's "show"</DIDL-Lite>"#
        let escaped = XMLText.escape(raw)
        #expect(!escaped.contains("<"))
        #expect(XMLText.unescape(escaped) == raw)
    }
}
