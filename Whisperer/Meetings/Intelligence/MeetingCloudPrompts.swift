//
//  MeetingCloudPrompts.swift
//  Whisperer
//
//  Prompts for connected (frontier) providers. The local Qwen prompts in
//  `MeetingAIService` are tuned around a 4B decoder's failure modes — numbered markers,
//  contrastive examples, no "stop" instructions — none of which a frontier model needs,
//  and a JSON schema replaces the line format entirely.
//

import Foundation

nonisolated enum MeetingCloudPrompts {

    static func notesInstructions(languageName: String?, isShortNote: Bool) -> String {
        let language = languageName.map {
            "Write every field in \($0). Quote names and terms in their original language."
        } ?? "Write every field in the language the transcript is mostly in."

        let length = isShortNote
            ? "This is a short voice note: the overview is 40 to 90 words, and topics, decisions, open questions, next meeting and action items are almost always empty."
            : "The overview is the part the user reads: 150 to 400 words depending on how much was said, in paragraphs separated by a blank line, covering every topic in order."

        return """
        You write meeting notes from a speech-to-text transcript recorded on the user's Mac. \
        The transcript contains filler words, false starts and misheard words; summarize what \
        was meant. Every line starts with a marker like [95s], the seconds from the start; copy \
        those numbers into the `seconds` fields of the item they support.

        Reply with one JSON object matching the schema, and nothing else.

        - title: 3 to 7 words naming the actual subject. Never "Meeting", "Recording" or "Notes".
        - overview: \(length) Keep the specifics — names, numbers, tools, reasons. State what \
        was said, not that something was said. No markdown.
        - topics: one entry per section of the conversation, in order.
        - decisions: only decisions actually made. label is 1 to 3 words.
        - openQuestions: questions raised and left unanswered.
        - nextMeeting: when and where the next session is, or null.
        - actionItems: tasks someone took on. owner is the person's name as said in the \
        transcript, or null if nobody was named. due is the deadline as said, or null. Never \
        invent an owner, a date, a decision or a task.
        - \(language)
        """
    }

    static func notesUserMessage(transcript: String) -> String {
        "TRANSCRIPT:\n\(transcript)"
    }

    static let askInstructions = """
    You answer questions about one meeting, using only its transcript below the question. \
    Each transcript line starts with [Ns], the seconds from the start. When a statement in \
    your answer comes from a specific moment, cite it as [Ns] using that line's number. \
    If the transcript does not contain the answer, say so plainly. Answer in the language \
    the question is written in; keep quoted words in their original language. Be concise. \
    Plain text or short bullet lists only, no headings.
    """

    static func askUserMessage(question: String, transcript: String) -> String {
        """
        QUESTION:
        \(question)

        TRANSCRIPT:
        \(transcript)
        """
    }
}
