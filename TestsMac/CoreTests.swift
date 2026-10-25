import XCTest
import CoreGraphics

final class PlaylistParserTests: XCTestCase {

    func testM3UWithKodiPropsAndVLCOptions() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV-1" tvg-logo="https://logo/1.png" group-title="央视",CCTV-1 综合
        #KODIPROP:inputstream.adaptive.manifest_type=mpd
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=feedf00d-eede-adbe-eff0-baadf00dd00d:00112233445566778899aabbccddeeff
        #EXTVLCOPT:http-user-agent=Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)
        #EXTVLCOPT:http-referrer=https://example.com/
        https://example.com/live/manifest.mpd
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 1)
        guard let channel = channels.first else { return }

        XCTAssertEqual(channel.name, "CCTV-1 综合")
        XCTAssertEqual(channel.group, "央视")
        XCTAssertEqual(channel.tvgID, "cctv1")
        XCTAssertEqual(channel.logo, "https://logo/1.png")
        XCTAssertEqual(channel.manifestType, .dash)
        XCTAssertTrue(channel.isDASH)
        XCTAssertTrue(channel.hasClearKey)
        XCTAssertEqual(channel.keys.count, 1)
        XCTAssertEqual(channel.keys["feedf00deedeadbeeff0baadf00dd00d"], "00112233445566778899aabbccddeeff")
        XCTAssertEqual(channel.headers["User-Agent"], "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)")
        XCTAssertEqual(channel.headers["Referer"], "https://example.com/")
        XCTAssertEqual(channel.licenseType, "clearkey")
    }

    func testRemoteLicenseURL() {
        let text = """
        #EXTINF:-1 group-title="测试",加密频道
        #KODIPROP:inputstream.adaptive.manifest_type=mpd
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=https://license.example.com/clearkey
        https://example.com/manifest.mpd
        """
        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].licenseURL, "https://license.example.com/clearkey")
        XCTAssertTrue(channels[0].keys.isEmpty)
    }

    func testSameNameChannelsAreMergedIntoSingleGroupWithMultipleLines() {
        let text = """
        #EXTINF:-1 group-title="央视频道",CCTV-1 综合
        http://a.example.com/cctv1/index.m3u8
        #EXTINF:-1 group-title="央视频道",CCTV-1 综合
        http://b.example.com/cctv1/index.m3u8
        #EXTINF:-1 group-title="央视频道",CCTV-1 综合
        http://c.example.com/cctv1/index.m3u8
        #EXTINF:-1 group-title="央视频道",CCTV-2 财经
        http://a.example.com/cctv2/index.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 4)

        let groups = ChannelGrouping.groups(from: channels)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "CCTV-1 综合")
        XCTAssertEqual(groups[0].lineCount, 3)
        XCTAssertEqual(groups[0].lines[2].url, "http://c.example.com/cctv1/index.m3u8")
        XCTAssertEqual(groups[1].lineCount, 1)
    }

    func testTXTWithGenreAndPipeHeaders() {
        let text = """
        央视频道,#genre#
        CCTV-1,http://a.example.com/1.m3u8
        CCTV-2|http://a.example.com/2.m3u8|User-Agent=Mozilla/5.0 Test&Referer=https://ref.example.com/
        卫视频道,#genre#
        湖南卫视|http://b.example.com/hunan.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[0].group, "央视频道")
        XCTAssertEqual(channels[1].group, "央视频道")
        XCTAssertEqual(channels[1].name, "CCTV-2")
        XCTAssertEqual(channels[1].url, "http://a.example.com/2.m3u8")
        XCTAssertEqual(channels[1].headers["User-Agent"], "Mozilla/5.0 Test")
        XCTAssertEqual(channels[1].headers["Referer"], "https://ref.example.com/")
        XCTAssertEqual(channels[2].group, "卫视频道")
        XCTAssertEqual(channels[2].name, "湖南卫视")
    }

    func testEXTVLCOPTArbitraryHeader() {
        let text = """
        #EXTINF:-1,某频道
        #EXTVLCOPT:http-origin=https://origin.example.com
        #EXTVLCOPT:http-cookie=a=b
        http://example.com/live.m3u8
        """
        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.first?.headers["Origin"], "https://origin.example.com")
        XCTAssertEqual(channels.first?.headers["Cookie"], "a=b")
    }

    func testClearKeyJSON() {
        let raw = """
        {"keys":[{"kty":"oct","kid":"feedf00deedeadbeeff0baadf00dd00d","k":"00112233445566778899aabbccddeeff"}]}
        """
        let keys = ClearKeyParser.parseInlineJSON(raw)
        XCTAssertEqual(keys?["feedf00deedeadbeeff0baadf00dd00d"], "00112233445566778899aabbccddeeff")
    }

    func testEmptyAndCommentsOnly() {
        XCTAssertTrue(PlaylistParser.parse("#EXTM3U\n\n#EXTINF:-1,\n").isEmpty)
    }

    func testCatchUpTags() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="央视" catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}" catchup-days="7",CCTV-1 综合
        http://example.com/live/cctv1.m3u8?token=abc
        #EXTINF:-1 timeshift="3",湖南卫视
        http://example.com/live/hunan.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].catchUpMode, "append")
        XCTAssertEqual(channels[0].catchUpDays, 7)
        XCTAssertEqual(channels[0].catchUpSource, "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")
        XCTAssertTrue(CatchUp.supports(channels[0]))
        XCTAssertEqual(channels[1].catchUpDays, 3)
        XCTAssertTrue(CatchUp.supports(channels[1]))
    }

    func testCatchUpTagWithCommaInGroupTitle() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="cctv1" group-title="央视,综合" catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",CCTV-1 综合
        http://example.com/live/cctv1.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].name, "CCTV-1 综合")
        XCTAssertEqual(channels[0].group, "央视,综合")
        XCTAssertEqual(channels[0].catchUpSource, "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")
        XCTAssertTrue(CatchUp.supports(channels[0]))
    }

    func testCatchUpUnderscoreKeys() {
        let text = """
        #EXTM3U
        #EXTINF:-1 catchup="append" catchup_source="&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}" catchup_days="3",CCTV-2
        http://example.com/live/cctv2.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels[0].catchUpDays, 3)
        XCTAssertEqual(channels[0].catchUpSource, "&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")
        XCTAssertTrue(CatchUp.supports(channels[0]))
    }
}

final class ResolutionLabelTests: XCTestCase {

    func testMappings() {
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 3840, height: 2160)), "4K")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 1920, height: 1080)), "1080P")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 1280, height: 720)), "720P")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 1024, height: 576)), "576P")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 854, height: 480)), "480P")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 640, height: 360)), "360P")
        XCTAssertNil(ResolutionLabel.text(for: .zero))
    }

    func testPortraitVideoUsesShortSide() {
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 1080, height: 1920)), "1080P")
        XCTAssertEqual(ResolutionLabel.text(for: CGSize(width: 720, height: 1280)), "720P")
    }
}

final class XMLTVTests: XCTestCase {

    private let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="cctv1">
        <display-name>CCTV-1 综合</display-name>
      </channel>
      <channel id="hunan">
        <display-name>湖南卫视</display-name>
      </channel>
      <programme start="20261021120000 +0800" stop="20261021130000 +0800" channel="cctv1">
        <title lang="zh">新闻联播</title>
        <desc>晚间新闻</desc>
      </programme>
      <programme start="20261021130000 +0800" stop="20261021140000 +0800" channel="cctv1">
        <title lang="zh">综艺节目</title>
        <sub-title>第 1 期</sub-title>
      </programme>
    </tv>
    """

    func testParseAndMatch() {
        let data = Data(xml.utf8)
        let database = XMLTVParser.parse(data: data)

        XCTAssertEqual(database.totalPrograms, 2)
        XCTAssertEqual(database.channelNames["cctv1"], ["CCTV-1 综合"])

        let channel = Channel(name: "CCTV-1 综合", url: "http://example.com/1.m3u8", tvgID: "cctv1")
        let matched = EPGMatching.match(channel: channel, in: database)
        XCTAssertEqual(matched, "cctv1")

        let date = XMLTVDate.parse("20261021123000 +0800")!
        let result = database.nowNext(channelID: "cctv1", at: date)
        XCTAssertEqual(result.now?.title, "新闻联播")
        XCTAssertEqual(result.next?.title, "综艺节目")
    }

    func testMatchByNameWithoutTvgID() {
        let database = XMLTVParser.parse(data: Data(xml.utf8))
        let channel = Channel(name: "湖南卫视", url: "http://example.com/hunan.m3u8")
        XCTAssertEqual(EPGMatching.match(channel: channel, in: database), "hunan")
    }

    func testMatchNormalizesSuffixes() {
        let database = XMLTVParser.parse(data: Data(xml.utf8))
        let channel = Channel(name: "CCTV-1 综合 高清", url: "http://example.com/1.m3u8")
        XCTAssertEqual(EPGMatching.match(channel: channel, in: database), "cctv1")
    }
}

final class JSONEPGTests: XCTestCase {

    func testParseWrappedProgramsArray() {
        let json = """
        {
          "programs": [
            {"title":"新闻联播","start":"2026-10-25 19:00:00","stop":"2026-10-25 19:30:00"},
            {"title":"天气预报","start":"2026-10-25 19:30:00","end":"2026-10-25 19:35:00"}
          ]
        }
        """.data(using: .utf8)!
        let programs = JSONEPGParser.parse(data: json, channelID: "cctv1")
        XCTAssertEqual(programs.count, 2)
        XCTAssertEqual(programs[0].title, "新闻联播")
        XCTAssertEqual(programs[1].title, "天气预报")
        XCTAssertLessThan(programs[0].start, programs[1].start)
    }

    func testParseTopLevelArrayWithChineseKeys() {
        let json = """
        [
          {"标题":"早间新闻","开始":"2026-10-25 07:00:00","结束":"2026-10-25 08:00:00"},
          {"标题":"午间新闻","开始":"2026-10-25 12:00:00","结束":"2026-10-25 13:00:00"}
        ]
        """.data(using: .utf8)!
        let programs = JSONEPGParser.parse(data: json, channelID: "cctv1")
        XCTAssertEqual(programs.count, 2)
        XCTAssertEqual(programs[0].title, "早间新闻")
        XCTAssertEqual(programs[1].title, "午间新闻")
    }

    func testParseChannelKeyedObject() {
        let json = """
        {
          "CCTV1": [
            {"title":"测试节目","start":"2026-10-25 20:00:00","stop":"2026-10-25 21:00:00"}
          ]
        }
        """.data(using: .utf8)!
        let programs = JSONEPGParser.parse(data: json, channelID: "cctv1")
        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs[0].title, "测试节目")
    }

    func testMissingStartOrTitleSkipped() {
        let json = """
        [
          {"title":"有效节目","start":"2026-10-25 20:00:00","stop":"2026-10-25 21:00:00"},
          {"title":"","start":"2026-10-25 21:00:00","stop":"2026-10-25 22:00:00"},
          {"start":"2026-10-25 22:00:00","stop":"2026-10-25 23:00:00"}
        ]
        """.data(using: .utf8)!
        let programs = JSONEPGParser.parse(data: json, channelID: "cctv1")
        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs[0].title, "有效节目")
    }
}

final class CatchUpTests: XCTestCase {

    func testSupportsPlayseekTemplate() {
        let long = Channel(name: "回看频道",
                           url: "http://example.com/live.m3u8?token=1&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")
        XCTAssertTrue(CatchUp.supports(long))
        XCTAssertTrue(CatchUp.supports(url: "http://example.com/live.m3u8?playseek=${(b)}-${(e)}"))
        XCTAssertFalse(CatchUp.supports(url: "http://example.com/live.m3u8?playseek=20260101000000-20260101010000"))
        XCTAssertFalse(CatchUp.supports(url: "http://example.com/live.m3u8"))
    }

    func testBuildCatchUpURLReplacesTokens() {
        let channel = Channel(name: "回看频道",
                              url: "http://example.com/live.m3u8?a=1&amp;playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}&amp;b=2")
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)

        let expected = "http://example.com/live.m3u8?a=1&playseek="
            + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))&b=2"
        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to), expected)
    }

    func testBuildCatchUpURLSupportsShortTokens() {
        let raw = "http://example.com/live.m3u8?playseek=${(b)}-${(e)}"
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        XCTAssertEqual(CatchUp.url(for: raw, from: from, to: to),
                       "http://example.com/live.m3u8?playseek=\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testLiveURLStripsPlayseek() {
        XCTAssertEqual(CatchUp.liveURL(from: "http://example.com/live.m3u8?playseek=${(b)}-${(e)}"),
                       "http://example.com/live.m3u8")
        XCTAssertEqual(CatchUp.liveURL(from: "http://example.com/live.m3u8?a=1&playseek=${(b)}-${(e)}&b=2"),
                       "http://example.com/live.m3u8?a=1&b=2")
        XCTAssertEqual(CatchUp.liveURL(from: "http://example.com/live.m3u8?a=1"),
                       "http://example.com/live.m3u8?a=1")
    }

    func testTimeStringFormat() {
        let value = CatchUp.timeString(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(value.count, 14)
        XCTAssertTrue(value.allSatisfy { $0.isNumber })
    }

    func testCatchUpSourceAppendsToLiveURL() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let channel = Channel(name: "CCTV-1",
                              url: "http://example.com/live/cctv1.m3u8?token=abc",
                              catchUpMode: "append",
                              catchUpSource: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")

        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       "http://example.com/live/cctv1.m3u8?token=abc&playseek="
                       + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testCatchUpSourceFullURL() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let channel = Channel(name: "CCTV-1",
                              url: "http://example.com/live/cctv1.m3u8",
                              catchUpMode: "default",
                              catchUpSource: "http://example.com/timeshift/cctv1.m3u8?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")

        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       "http://example.com/timeshift/cctv1.m3u8?playseek="
                       + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testTimeshiftDaysWithoutSourceAppendsPlayseek() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let channel = Channel(name: "湖南卫视",
                              url: "http://example.com/live/hunan.m3u8",
                              catchUpDays: 3)

        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       "http://example.com/live/hunan.m3u8?playseek="
                       + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testUnixPlaceholders() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        XCTAssertEqual(CatchUp.expand("http://example.com/x?start={utc}&end={utcend}", from: from, to: to),
                       "http://example.com/x?start=1700000000&end=1700003600")
        XCTAssertEqual(CatchUp.expand("http://example.com/x?start=${start}&end=${end}", from: from, to: to),
                       "http://example.com/x?start=1700000000&end=1700003600")
    }

    func testAmpersandSuffixAddsQuestionMark() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let channel = Channel(name: "CCTV-1",
                              url: "http://example.com/live/cctv1.m3u8",
                              catchUpMode: "append",
                              catchUpSource: "&playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")

        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       "http://example.com/live/cctv1.m3u8?playseek="
                       + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testQuestionSuffixWithExistingQuery() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let channel = Channel(name: "CCTV-1",
                              url: "http://example.com/live/cctv1.m3u8?token=abc",
                              catchUpMode: "append",
                              catchUpSource: "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}")

        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       "http://example.com/live/cctv1.m3u8?token=abc&playseek="
                       + "\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    /// 运营商列表没有 catchup 标签，但地址本身支持 `&playseek=开始-结束`。
    func testProviderPlayseekWithoutTags() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_700_003_600)
        let url = "http://120.87.19.109:80/PLTV/88888973/224/3221226352/"
            + "10000100000000060000000001464824_0.smil/01.m3u8"
            + "?fmt=ts2hls,244,01.m3u8&accountinfo=ABC+DEF/123,END&tenantId=8601"
        let channel = Channel(name: "CCTV5", url: url)

        XCTAssertTrue(CatchUp.supports(channel))
        XCTAssertEqual(CatchUp.url(for: channel, from: from, to: to),
                       url + "&playseek=\(CatchUp.timeString(from))-\(CatchUp.timeString(to))")
    }

    func testPlainChannelIsNotCatchUp() {
        let channel = Channel(name: "X", url: "http://example.com/live/x.m3u8")
        XCTAssertFalse(CatchUp.supports(channel))
    }
}
