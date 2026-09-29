import Foundation
import Testing
@testable import PinTabCore

@Suite("Pin list")
struct PinListTests {
    @Test func initDropsDuplicatesAndEmptyIdentities() {
        let list = PinList([
            PinnedApp(id: App.a, name: "Alpha"),
            PinnedApp(id: AppID(""), name: "Nothing"),
            PinnedApp(id: App.b, name: "Bravo"),
            PinnedApp(id: App.a, name: "Alpha again"),
        ])
        #expect(list.ids == [App.a, App.b])
        #expect(list.name(of: App.a) == "Alpha", "the first occurrence wins")
    }

    @Test func setPinnedAppendsAndReportsWhetherMembershipChanged() {
        var list = PinList([PinnedApp(id: App.a, name: "Alpha")])
        let pinnedC = list.setPinned(App.c, name: "Charlie", pinned: true)
        let pinnedB = list.setPinned(App.b, name: "Bravo", pinned: true)
        #expect(pinnedC && pinnedB)
        #expect(list.ids == [App.a, App.c, App.b], "insertion order is kept")
        let pinnedCAgain = list.setPinned(App.c, name: "Other", pinned: true)
        #expect(!pinnedCAgain, "pinning twice is not a change")
        #expect(list.name(of: App.c) == "Charlie")
        let unpinnedA = list.setPinned(App.a, name: "", pinned: false)
        #expect(unpinnedA)
        let unpinnedAAgain = list.setPinned(App.a, name: "", pinned: false)
        #expect(!unpinnedAAgain, "unpinning a non-member is not a change")
        let pinnedEmpty = list.setPinned(AppID(""), name: "", pinned: true)
        #expect(!pinnedEmpty, "an empty identity can never be pinned")
        #expect(list.ids == [App.c, App.b])
        #expect(!list.contains(App.a))
    }

    @Test func updateNameNeverChangesMembership() {
        var list = PinList([PinnedApp(id: App.a, name: "Alpha")])
        list.updateName(App.a, to: "Alpha 2")
        #expect(list.name(of: App.a) == "Alpha 2")
        list.updateName(App.a, to: "")
        #expect(list.name(of: App.a) == "Alpha 2", "empty names are ignored")
        list.updateName(App.b, to: "Bravo")
        #expect(!list.contains(App.b))
        #expect(list.name(of: App.b) == nil)
        #expect(list.ids == [App.a])
    }
}

@Suite("Preferences codec")
struct PreferencesCodecTests {
    func data(_ json: String) -> Data { Data(json.utf8) }

    @Test func pinsRoundTripPreservingOrderAndNames() {
        let list = PinList([
            PinnedApp(id: App.c, name: "Charlie"),
            PinnedApp(id: App.a, name: "Alpha"),
            PinnedApp(id: App.b, name: "Bravo ✨"),
        ])
        #expect(PreferencesCodec.decodePins(PreferencesCodec.encodePins(list)) == list)
        #expect(PreferencesCodec.decodePins(PreferencesCodec.encodePins(PinList())) == PinList())
    }

    @Test func malformedEntriesAreDroppedIndividually() {
        let json = """
        [
          {"id": "com.test.alpha", "name": "Alpha"},
          {"name": "no identity"},
          42,
          null,
          {"id": 7, "name": "numeric identity"},
          {"id": ""},
          {"id": "com.test.bravo", "name": "Bravo", "extra": true},
          [1, 2]
        ]
        """
        let list = PreferencesCodec.decodePins(data(json))
        #expect(list.ids == [App.a, App.b])
        #expect(list.name(of: App.b) == "Bravo")
    }

    @Test func missingOrInvalidNameFallsBackToBundleIdentifier() {
        let list = PreferencesCodec.decodePins(data("""
        [{"id": "com.test.alpha"}, {"id": "com.test.bravo", "name": 5}, {"id": "com.test.charlie", "name": null}]
        """))
        #expect(list.ids == [App.a, App.b, App.c])
        #expect(list.name(of: App.a) == "com.test.alpha")
        #expect(list.name(of: App.b) == "com.test.bravo")
        #expect(list.name(of: App.c) == "com.test.charlie")
    }

    @Test func duplicatePinsCollapseToFirstOccurrence() {
        let list = PreferencesCodec.decodePins(data("""
        [{"id": "com.test.alpha", "name": "First"}, {"id": "com.test.bravo"}, {"id": "com.test.alpha", "name": "Second"}]
        """))
        #expect(list.ids == [App.a, App.b])
        #expect(list.name(of: App.a) == "First")
    }

    @Test func bareListOfBundleIdentifiersIsAccepted() {
        // PreferencesCodec.decodePins documents: "Accept a bare list of bundle identifiers as well."
        let list = PreferencesCodec.decodePins(data(#"["com.test.alpha", "com.test.bravo", "com.test.alpha"]"#))
        #expect(list.ids == [App.a, App.b])
        #expect(list.name(of: App.a) == "com.test.alpha")
    }

    @Test(arguments: [
        nil,
        Data(),
        Data("not json".utf8),
        Data(#"{"pins": [{"id": "com.test.alpha"}]}"#.utf8),
        Data("\"com.test.alpha\"".utf8),
        Data([0xFF, 0x00, 0x13]),
    ] as [Data?])
    func garbageYieldsNoPins(_ input: Data?) {
        #expect(PreferencesCodec.decodePins(input) == PinList())
    }

    @Test func validShortcutRoundTrips() {
        let shortcut = Shortcut(keyCode: KeyCode.tab, modifiers: [.command, .option])
        #expect(PreferencesCodec.decodeShortcut(PreferencesCodec.encodeShortcut(shortcut)) == shortcut)
        let controlTab = Shortcut(keyCode: KeyCode.tab, modifiers: .control)
        #expect(PreferencesCodec.decodeShortcut(PreferencesCodec.encodeShortcut(controlTab)) == controlTab)
    }

    @Test func invalidStoredShortcutDecodesToNil() {
        let invalid = [
            Shortcut(keyCode: KeyCode.tab, modifiers: .command),             // reserved
            Shortcut(keyCode: KeyCode.tab, modifiers: [.control, .shift]),   // shift
            Shortcut(keyCode: KeyCode.tab, modifiers: .option),              // option only
            Shortcut(keyCode: KeyCode.escape, modifiers: .control),          // escape
            Shortcut(keyCode: 0x37, modifiers: .command),                    // modifier key
        ]
        for shortcut in invalid {
            #expect(PreferencesCodec.decodeShortcut(PreferencesCodec.encodeShortcut(shortcut)) == nil)
        }
    }

    @Test func missingOrMalformedShortcutDecodesToNil() {
        #expect(PreferencesCodec.decodeShortcut(nil) == nil)
        #expect(PreferencesCodec.decodeShortcut(Data()) == nil)
        #expect(PreferencesCodec.decodeShortcut(data("garbage")) == nil)
        #expect(PreferencesCodec.decodeShortcut(data(#"{"keyCode": 48}"#)) == nil)
        #expect(PreferencesCodec.decodeShortcut(data(#"{"keyCode": -1, "modifiers": 2}"#)) == nil)
        #expect(PreferencesCodec.decodeShortcut(data(#"{"keyCode": 48, "modifiers": 300}"#)) == nil)
    }

    @Test func storedShortcutWithUnknownModifierBitsIsRejected() {
        // Modifiers are stored as a raw UInt8 option set. Bits above Shift have no meaning, but they
        // defeat the equality checks in validate(): Cmd+Tab plus an unknown bit passes validation,
        // yet its carbonFlags register plain Cmd+Tab (the macOS app switcher).
        let corrupted = PreferencesCodec.decodeShortcut(data(#"{"keyCode": 48, "modifiers": 17}"#))
        // Unknown bits are stripped on decode, leaving plain Cmd+Tab, which validation rejects.
        #expect(corrupted == nil)
    }
}

@Suite struct PreferencesMixedEntryTests {
    @Test func mixedStringAndRecordEntriesAreBothKept() {
        let list = PreferencesCodec.decodePins(Data(#"["com.test.alpha", {"id": "com.test.bravo", "name": "Bravo"}, 7]"#.utf8))
        #expect(list.ids == [AppID("com.test.alpha"), AppID("com.test.bravo")])
        #expect(list.name(of: AppID("com.test.bravo")) == "Bravo")
    }
}
