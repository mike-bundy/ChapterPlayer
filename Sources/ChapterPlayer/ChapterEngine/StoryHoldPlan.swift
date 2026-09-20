//
//  StoryHoldPlan.swift
//  ChapterPlayer
//
//  WHAT ONE CONTINUATION MEANS TO A PLAYER, DECIDED WITHOUT A PLAYER.
//
//  `ChapterPlayerCore.applyStoryContinuation` used to make this decision and
//  issue the media command in the same switch, which is why two of its
//  answers were wrong for a year with nothing to catch them: the decision
//  could only be exercised by wearing a headset. This is the decision alone —
//  a pure function from (what the author chose, what kind of content it is)
//  to a command — so the table in `docs/STORY_REGIONS.md` §6 has a test.
//
//  EXHAUSTIVE, NO `default`. A new behavior or a new kind of target must be
//  answered here, not inherit somebody else's answer.
//

import Foundation
import ChapterScript

public enum StoryHoldPlan {

    /// What a continuation is aimed at, as far as a player is concerned.
    public enum Content: Sendable, Equatable {
        case video
        case audio
        /// An Environment cue on the backdrop track.
        case backdrop
    }

    /// What the host does as the story parks at the boundary.
    public enum Command: Sendable, Equatable {
        /// Freeze it where it is. Released when the hold ends.
        case pause
        /// End it at the boundary. Nothing to release.
        case stop
        /// It keeps running on its own clock, which it is already doing.
        case leaveRunning
        /// The runtime cannot perform this. It is left running, and the
        /// reason is logged — never silently dropped.
        case refuse(reason: String)
    }

    /// The command for one authored behavior on entering the hold.
    public static func command(for behavior: StoryContinuationBehavior,
                               on content: Content) -> Command {
        switch (behavior, content) {
        case (.hold, .video), (.hold, .audio), (.hold, .backdrop):
            return .pause
        case (.continue, .video), (.continue, .audio), (.continue, .backdrop):
            return .leaveRunning
        case (.stop, .video), (.stop, .audio):
            return .stop
        case (.stop, .backdrop):
            return .refuse(reason: backdropStopRefusal)
        case (.loop, .video), (.loop, .audio), (.loop, .backdrop):
            return .refuse(reason: mediaLoopRefusal)
        }
    }

    /// What content does when the author said NOTHING about it.
    ///
    /// Video holds its frame — "everything holds unless the author said
    /// otherwise". Audio and the Environment keep going, because that is what
    /// they have always done on device and an ambience that cut out at every
    /// boundary by default would be the wrong surprise.
    public static func defaultCommand(on content: Content) -> Command {
        switch content {
        case .video:            return .pause
        case .audio, .backdrop: return .leaveRunning
        }
    }

    /// The video channels that hold their frame BY DEFAULT.
    ///
    /// Every channel the Sequence asked to play, minus the ones the author
    /// gave an explicit policy (those were already handled, whatever they
    /// said) and minus protected channels such as the Environment's, which is
    /// a backdrop cue's business and never a video occurrence's.
    public static func videoChannelsHeldByDefault(
        playing: [String],
        explicitlyConfigured: Set<String>,
        protected: Set<String>
    ) -> [String] {
        playing
            .filter { !explicitlyConfigured.contains($0) && !protected.contains($0) }
            .sorted()
    }

    // MARK: - The refusals, in the words the editors show

    /// An Environment cannot be stopped for the length of a hold.
    public static let backdropStopRefusal =
        "An Environment cannot stop during an Explore Area. Add an empty Environment cue at the boundary instead."

    /// Shown by the editors in place of an audio Hold item until the
    /// per-channel pause has been heard on a headset. The runtime PERFORMS an
    /// audio hold; this is about what the editors may promise.
    public static let audioHoldUnverifiedNotice =
        "Pausing one sound during an Explore Area has not been verified on Vision Pro. Use Stop or Fade out on exit."

    /// Media cannot start looping at the boundary. See `docs/STORY_REGIONS.md` §6.
    public static let mediaLoopRefusal =
        "Video and audio cannot start looping during an Explore Area. Set the clip to loop, then choose Keep Playing."
}
