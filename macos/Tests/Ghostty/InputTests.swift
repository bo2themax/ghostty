import SwiftUI
import Testing
@testable import Ghostty
@testable import GhosttyKit

@Suite
struct InputTests {

    // MARK: - equivalentToKey reverse map

    @Test func equivalentToKeyContainsAllArrowKeys() throws {
        let physicalTrigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: []), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(physicalTrigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(physicalTrigger.key.physical == GHOSTTY_KEY_ARROW_UP)

        let unicodeTrigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: []), tag: GHOSTTY_TRIGGER_UNICODE))
        #expect(unicodeTrigger.tag == GHOSTTY_TRIGGER_UNICODE)
        #expect(unicodeTrigger.key.unicode == KeyEquivalent.upArrow.character.unicodeScalars.first?.value)

        #expect(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: []), tag: GHOSTTY_TRIGGER_CATCH_ALL) == nil)
    }

    @Test func equivalentToKeyDistinguishesDeleteAndBackspace() throws {
        let backspace = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.delete, modifiers: []), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(backspace.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(backspace.key.physical == GHOSTTY_KEY_BACKSPACE)

        let forwardDelete = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.deleteForward, modifiers: []), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(forwardDelete.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(forwardDelete.key.physical == GHOSTTY_KEY_DELETE)
    }

    @Test func equivalentToKeyMapsAllSpecialKeys() throws {
        let expected: [(KeyEquivalent, ghostty_input_key_e)] = [
            (.upArrow, GHOSTTY_KEY_ARROW_UP),
            (.downArrow, GHOSTTY_KEY_ARROW_DOWN),
            (.leftArrow, GHOSTTY_KEY_ARROW_LEFT),
            (.rightArrow, GHOSTTY_KEY_ARROW_RIGHT),
            (.home, GHOSTTY_KEY_HOME),
            (.end, GHOSTTY_KEY_END),
            (.pageUp, GHOSTTY_KEY_PAGE_UP),
            (.pageDown, GHOSTTY_KEY_PAGE_DOWN),
            (.escape, GHOSTTY_KEY_ESCAPE),
            (.return, GHOSTTY_KEY_ENTER),
            (.tab, GHOSTTY_KEY_TAB),
            (.delete, GHOSTTY_KEY_BACKSPACE),
            (.deleteForward, GHOSTTY_KEY_DELETE),
            (.space, GHOSTTY_KEY_SPACE),
        ]

        for (equiv, expectedKey) in expected {
            let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(equiv, modifiers: []), tag: GHOSTTY_TRIGGER_PHYSICAL))
            #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
            #expect(trigger.key.physical == expectedKey,
                "Expected \(expectedKey) for \(equiv), got \(String(describing: trigger.key.physical))")
        }
    }

    // MARK: - ghosttyTrigger

    @Test func ghosttyTriggerPhysicalKeyWithModifiers() throws {
        let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut(.upArrow, modifiers: .command), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(trigger.key.physical == GHOSTTY_KEY_ARROW_UP)
        #expect(trigger.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)

        let trigger1 = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut("\\", modifiers: [.command, .shift]), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(trigger1.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(trigger1.key.physical == GHOSTTY_KEY_BACKSLASH)
        #expect(trigger1.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test func ghosttyTriggerUnicodeFallback() throws {
        // Regular letter keys are not in keyToEquivalent, so they fall through to unicode.
        let trigger = try #require(Ghostty.ghosttyTrigger(KeyboardShortcut("c", modifiers: .command), tag: GHOSTTY_TRIGGER_PHYSICAL))
        #expect(trigger.tag == GHOSTTY_TRIGGER_PHYSICAL)
        #expect(trigger.key.physical == Ghostty.Input.Key.c.cKey)
        #expect(trigger.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    // MARK: - ghosttyKeyEvent: physical keys

    @Test func keyEventArrowKeyHasCorrectKeycode() throws {
        let ev = try #require(KeyboardShortcut(.upArrow, modifiers: []).ghosttyKeyEvent())
        #expect(ev.keycode == 0x007e)
        #expect(ev.mods == GHOSTTY_MODS_NONE)
    }

    @Test func keyEventSpecialKeyWithMultipleMods() throws {
        let ev = try #require(KeyboardShortcut(.tab, modifiers: [.control, .shift]).ghosttyKeyEvent(
            ))
        #expect(ev.keycode == 0x0030)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
    }

    @Test func keyEventEscapeKey() throws {
        let ev = try #require(KeyboardShortcut(.escape, modifiers: []).ghosttyKeyEvent())
        #expect(ev.keycode == 0x0035)
    }

    @Test func keyEventBackspaceAndDeleteForward() throws {
        let backspace = try #require(KeyboardShortcut(.delete, modifiers: []).ghosttyKeyEvent())
        #expect(backspace.keycode == 0x0033)

        let fwdDelete = try #require(KeyboardShortcut(.deleteForward, modifiers: []).ghosttyKeyEvent())
        #expect(fwdDelete.keycode == 0x0075)
    }

    @Test func keyEventSpaceKey() throws {
        let ev = try #require(KeyboardShortcut(.space, modifiers: .command).ghosttyKeyEvent())
        #expect(ev.keycode == 0x0031)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    // MARK: - ghosttyKeyEvent: unicode keys

    @Test func keyEventLetterWithCommand() throws {
        let ev = try #require(KeyboardShortcut("c", modifiers: .command).ghosttyKeyEvent())
        #expect(ev.action == GHOSTTY_ACTION_PRESS)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
        #expect(ev.keycode == Ghostty.Input.Key.c.keyCode.flatMap(UInt32.init(_:)))
        #expect(ev.text == nil)
        #expect(ev.composing == false)
    }

    @Test func keyEventNonAsciiUnicode() throws {
        // Characters like ü and ß should work — they get codepoint but no keycode
        let ev = try #require(KeyboardShortcut("ü", modifiers: .command).ghosttyKeyEvent())
        #expect(ev.unshifted_codepoint == 0xFC) // U+00FC LATIN SMALL LETTER U WITH DIAERESIS
        #expect(ev.keycode == 0)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)

        let ev2 = try #require(KeyboardShortcut("ß", modifiers: .command).ghosttyKeyEvent())
        #expect(ev2.unshifted_codepoint == 0xDF) // U+00DF LATIN SMALL LETTER SHARP S
        #expect(ev2.keycode == 0)
    }

    // MARK: - ghosttyKeyEvent: modifiers and action

    @Test func keyEventAllModifiers() throws {
        let ev = try #require(KeyboardShortcut("a", modifiers: [.shift, .control, .option, .command]).ghosttyKeyEvent())
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(ev.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    }

    @Test func keyEventConsumedModsExcludesCtrlAndCommand() throws {
        let ev = try #require(KeyboardShortcut("a", modifiers: [.shift, .control, .option, .command]).ghosttyKeyEvent())
        #expect(ev.consumed_mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
        #expect(ev.consumed_mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0)
        #expect(ev.consumed_mods.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)
        #expect(ev.consumed_mods.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0)
    }

    @Test func keyEventDefaultActionIsPress() throws {
        let ev = try #require(KeyboardShortcut("a", modifiers: []).ghosttyKeyEvent())
        #expect(ev.action == GHOSTTY_ACTION_PRESS)
    }

    @Test func keyEventCustomAction() throws {
        let ev = try #require(KeyboardShortcut("a", modifiers: []).ghosttyKeyEvent(action: GHOSTTY_ACTION_RELEASE))
        #expect(ev.action == GHOSTTY_ACTION_RELEASE)
    }

    // MARK: - roundtrip: keyboardShortcut → ghosttyTrigger

    @Test func roundtripPhysicalKeys() {
        // For physical keys, converting trigger → KeyboardShortcut → ghosttyTrigger
        // should produce the same physical key.
        let physicalKeys: [(ghostty_input_key_e, ghostty_input_mods_e)] = [
            (GHOSTTY_KEY_ARROW_UP, ghostty_input_mods_e(0)),
            (GHOSTTY_KEY_TAB, GHOSTTY_MODS_CTRL),
            (GHOSTTY_KEY_ENTER, GHOSTTY_MODS_SUPER),
        ]

        for (key, mods) in physicalKeys {
            let original = ghostty_input_trigger_s(
                tag: GHOSTTY_TRIGGER_PHYSICAL,
                key: .init(physical: key),
                mods: mods
            )

            guard let shortcut = Ghostty.keyboardShortcut(for: original) else {
                Issue.record("Could not create KeyboardShortcut for \(key)")
                continue
            }

            guard let back = Ghostty.ghosttyTrigger(shortcut, tag: GHOSTTY_TRIGGER_PHYSICAL) else {
                Issue.record("Could not convert KeyboardShortcut back for \(key)")
                continue
            }

            #expect(back.tag == GHOSTTY_TRIGGER_PHYSICAL)
            #expect(back.key.physical == key)
        }
    }

    // MARK: - Key(character:)

    @Test func keyCharacterInitRoundtripsKeyToEquivalent() throws {
        // Every entry in keyToEquivalent should round-trip via Key(character:).
        for (cKey, equiv) in Ghostty.keyToEquivalent {
            let key = try #require(Ghostty.Input.Key(character: equiv.character),
                "Key(character:) returned nil for \(cKey)")
            #expect(key.cKey == cKey,
                "Expected \(cKey), got \(key.cKey) via \(equiv.character)")
        }
    }

    @Test func keyCharacterInitMapsLetters() {
        let lowercase: [(Character, Ghostty.Input.Key)] = [
            ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e),
            ("f", .f), ("g", .g), ("h", .h), ("i", .i), ("j", .j),
            ("k", .k), ("l", .l), ("m", .m), ("n", .n), ("o", .o),
            ("p", .p), ("q", .q), ("r", .r), ("s", .s), ("t", .t),
            ("u", .u), ("v", .v), ("w", .w), ("x", .x), ("y", .y), ("z", .z),
        ]
        for (ch, expected) in lowercase {
            #expect(Ghostty.Input.Key(character: ch) == expected, "lowercase \(ch)")
        }

        // Uppercase should map to the same Key.
        let uppercase: [(Character, Ghostty.Input.Key)] = [
            ("A", .a), ("M", .m), ("Z", .z),
        ]
        for (ch, expected) in uppercase {
            #expect(Ghostty.Input.Key(character: ch) == expected, "uppercase \(ch)")
        }
    }

    @Test func keyCharacterInitMapsDigits() {
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("0", .digit0), ("1", .digit1), ("2", .digit2), ("3", .digit3),
            ("4", .digit4), ("5", .digit5), ("6", .digit6), ("7", .digit7),
            ("8", .digit8), ("9", .digit9),
        ]
        for (ch, expected) in pairs {
            #expect(Ghostty.Input.Key(character: ch) == expected, "digit \(ch)")
        }
    }

    @Test func keyCharacterInitMapsPunctuation() {
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("-", .minus), ("=", .equal), ("`", .backquote),
            ("[", .bracketLeft), ("]", .bracketRight), ("\\", .backslash),
            (";", .semicolon), ("'", .quote), (",", .comma),
            (".", .period), ("/", .slash),
        ]
        for (ch, expected) in pairs {
            #expect(Ghostty.Input.Key(character: ch) == expected, "punctuation \(ch)")
        }
    }

    @Test func keyCharacterInitMapsFunctionKeysViaNSEvent() {
        let pairs: [(NSEvent.SpecialKey, Ghostty.Input.Key)] = [
            (.f1, .f1), (.f2, .f2), (.f3, .f3), (.f4, .f4), (.f5, .f5),
            (.f6, .f6), (.f7, .f7), (.f8, .f8), (.f9, .f9), (.f10, .f10),
            (.f11, .f11), (.f12, .f12), (.f13, .f13), (.f14, .f14), (.f15, .f15),
            (.f16, .f16), (.f17, .f17), (.f18, .f18), (.f19, .f19), (.f20, .f20),
        ]
        for (special, expected) in pairs {
            let ch = Character(special.unicodeScalar)
            #expect(Ghostty.Input.Key(character: ch) == expected,
                "F-key \(special.unicodeScalar)")
        }
    }

    @Test func keyCharacterInitMapsInsertAndContextMenu() {
        let insert = Character(NSEvent.SpecialKey.insert.unicodeScalar)
        #expect(Ghostty.Input.Key(character: insert) == .insert)

        let menu = Character(NSEvent.SpecialKey.menu.unicodeScalar)
        #expect(Ghostty.Input.Key(character: menu) == .contextMenu)
    }

    @Test func keyCharacterInitDistinguishesDeleteAndBackspace() {
        // SwiftUI naming is reversed from Ghostty: .delete is backspace, .deleteForward is DEL.
        #expect(KeyEquivalent.delete.inputKey == .backspace)
        #expect(KeyEquivalent.deleteForward.inputKey == .delete)
    }

    @Test func keyCharacterInitReturnsNilForUnmapped() {
        #expect(Ghostty.Input.Key(character: "€") == nil)
        #expect(Ghostty.Input.Key(character: "!") == nil)
        #expect(Ghostty.Input.Key(character: "あ") == nil)
    }

    // MARK: - Layout-specific specs (pending TODO in Key.init?(character:))
    //
    // These tests document the expected mapping for non-US keyboard layouts where
    // characters sit at fixed physical positions. They are wrapped in `withKnownIssue`
    // because the implementation hasn't landed yet — once it does, the wrappers
    // start failing and should be removed.

    @Test func keyCharacterInitMapsGermanLayout() {
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("ü", .bracketLeft), ("Ü", .bracketLeft),
            ("ö", .semicolon), ("Ö", .semicolon),
            ("ä", .quote), ("Ä", .quote),
            ("ß", .minus),
        ]
        withKnownIssue("TODO: layout-aware character mapping (German)") {
            for (ch, expected) in pairs {
                #expect(Ghostty.Input.Key(character: ch) == expected, "german \(ch)")
            }
        }
    }

    @Test func keyCharacterInitMapsSwedishLayout() {
        // Nordic layouts (Swedish, Finnish, Norwegian, Danish variants) all share
        // the å/ö/ä cluster at these physical positions.
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("å", .bracketLeft), ("Å", .bracketLeft),
            ("ö", .semicolon), ("Ö", .semicolon),
            ("ä", .quote), ("Ä", .quote),
        ]
        withKnownIssue("TODO: layout-aware character mapping (Swedish/Nordic)") {
            for (ch, expected) in pairs {
                #expect(Ghostty.Input.Key(character: ch) == expected, "swedish \(ch)")
            }
        }
    }

    @Test func keyCharacterInitMapsSpanishLayout() {
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("ñ", .semicolon), ("Ñ", .semicolon),
        ]
        withKnownIssue("TODO: layout-aware character mapping (Spanish)") {
            for (ch, expected) in pairs {
                #expect(Ghostty.Input.Key(character: ch) == expected, "spanish \(ch)")
            }
        }
    }

    @Test func keyCharacterInitMapsFrenchAzertyLayout() {
        // AZERTY swaps several letters and places accented characters at digit-row
        // positions. These don't conflict with US ASCII letters because the
        // accented characters are unique.
        let pairs: [(Character, Ghostty.Input.Key)] = [
            ("à", .digit0),
            ("ç", .digit9),
            ("é", .digit2),
            ("è", .digit7),
            ("ù", .quote),
        ]
        withKnownIssue("TODO: layout-aware character mapping (French AZERTY)") {
            for (ch, expected) in pairs {
                #expect(Ghostty.Input.Key(character: ch) == expected, "french \(ch)")
            }
        }
    }

    // MARK: - KeyEquivalent.inputKey wrapper

    @Test func inputKeyDelegatesToKeyCharacterInit() {
        // The KeyEquivalent.inputKey extension should produce the same result as
        // calling Key(character:) directly on its character.
        let samples: [KeyEquivalent] = [
            .upArrow, .downArrow, .escape, .return, .tab, .space, .delete, .deleteForward,
            KeyEquivalent("a"), KeyEquivalent("Z"), KeyEquivalent("0"), KeyEquivalent("/"),
            KeyEquivalent(Character(NSEvent.SpecialKey.f1.unicodeScalar)),
            KeyEquivalent(Character(NSEvent.SpecialKey.menu.unicodeScalar)),
            KeyEquivalent("ü"), // unmapped (TODO: layout-aware)
        ]
        for equiv in samples {
            #expect(equiv.inputKey == Ghostty.Input.Key(character: equiv.character),
                "wrapper diverged for \(equiv.character)")
        }
    }
}

extension SwiftUI.KeyEquivalent {
    var inputKey: Ghostty.Input.Key? {
        Ghostty.Input.Key(character: character)
    }
}

private extension KeyboardShortcut {
    func ghosttyKeyEvent(action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS) -> ghostty_input_key_s? {
        Ghostty.ghosttyKeyEvent(self, action: action)
    }
}
