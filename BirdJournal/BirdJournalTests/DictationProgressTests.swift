import Testing
@testable import BirdJournal

// Issue #194 (of #185): what a dictation makes of what the toolkit's Speech reports. `GlassesDictation` is the shell over
// Speech and its timers; `DictationProgress` is every decision in it, as a value, so the ways a dictation ends that Mock
// Device Kit cannot stage (Speech stopping by itself) are held here.
@Suite("Dictation progress")
struct DictationProgressTests {
    typealias Event = GlassesDictation.Event

    @Test("words are told as they come and restart the wait as a pause; the final words end the dictation")
    func wordsThenFinal() {
        var progress = DictationProgress()
        #expect(progress.heard("black", isFinal: false) == .init(event: .words("black"), wait: .pause))
        #expect(progress.heard(" black pho ", isFinal: false) == .init(event: .words("black pho"), wait: .pause))
        #expect(progress.heard("Black Phoebe", isFinal: true) == .init(event: .final("Black Phoebe")))
        #expect(progress.isOver)
        #expect(progress.heard("house finch", isFinal: true) == .init(), "nothing more is told")
        #expect(progress.failed("late") == .init())
        #expect(progress.waited(.pause) == .init())
    }

    @Test("words with nothing in them are no words: an empty partial changes nothing, and an empty final does not end the dictation")
    func emptyWords() {
        var progress = DictationProgress()
        #expect(progress.heard("  ", isFinal: false) == .init())
        #expect(progress.heard("", isFinal: true) == .init())
        #expect(!progress.isOver)
        #expect(progress.heard("wren", isFinal: true) == .init(event: .final("wren")))
    }

    @Test("nothing heard by the limit ends the dictation on silence; words heard and then a pause are final as they stand")
    func theWaitRunsOut() {
        var silent = DictationProgress()
        #expect(silent.waited(.silence) == .init(event: .ended(.silence)))
        #expect(silent.isOver)

        var paused = DictationProgress()
        _ = paused.heard("house finch", isFinal: false)
        #expect(paused.waited(.pause) == .init(event: .final("house finch")))
        #expect(paused.isOver)
    }

    @Test("a Speech error ends the dictation with nothing to match, whatever was heard before it")
    func speechError() {
        var progress = DictationProgress()
        _ = progress.heard("black", isFinal: false)
        #expect(progress.failed("Unexpected error") == .init(event: .ended(.failed("Unexpected error"))))
        #expect(progress.isOver)
    }

    @Test("Speech stopping by itself, once it had started, ends the dictation after a moment's grace: with nothing heard there is nothing to match, and words heard are final as they stand")
    func speechStopsByItself() {
        // The state a capability reports before it has started is no stop.
        var fresh = DictationProgress()
        #expect(fresh.speechStopped() == .init())
        #expect(!fresh.isOver)

        var silent = DictationProgress()
        silent.speechStarted()
        #expect(silent.speechStopped() == .init(wait: .stopGrace))
        #expect(!silent.isOver, "an error that explains the stop may follow")
        #expect(silent.waited(.stopGrace) == .init(event: .ended(.stopped)))

        var heard = DictationProgress()
        heard.speechStarted()
        _ = heard.heard("mourning dove", isFinal: false)
        #expect(heard.speechStopped() == .init(wait: .stopGrace))
        #expect(heard.waited(.stopGrace) == .init(event: .final("mourning dove")))

        // The error that stopped it, told a moment after the state: the error is what happened.
        var failed = DictationProgress()
        failed.speechStarted()
        _ = failed.heard("mourning", isFinal: false)
        _ = failed.speechStopped()
        #expect(failed.failed("device disconnected") == .init(event: .ended(.failed("device disconnected"))))
        #expect(failed.waited(.stopGrace) == .init())
    }

    @Test("Speech that cannot be added to the session ends the dictation before it starts")
    func unavailable() {
        var progress = DictationProgress()
        #expect(progress.unavailable("the session is not started") == .init(event: .ended(.unavailable("the session is not started"))))
        #expect(progress.isOver)
    }
}
