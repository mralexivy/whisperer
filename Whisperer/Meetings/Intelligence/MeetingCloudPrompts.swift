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
    You help the user with one of their meetings; its transcript is below the question. You \
    are working for the user, who was in the meeting. \
    The transcript is automatic speech-to-text: words are misheard, sentences run together, \
    speakers are guessed, and it may be in another language than the question (often Hebrew \
    or Russian). Read it the way someone who sat in the meeting would — reconstruct what was \
    meant and work from that. Do not refuse or hedge because the transcript is noisy; if a \
    detail is genuinely missing, say so once, in one short sentence, and still give your best \
    answer from what is there. \
    Do exactly what the question asks, in the shape it asks for: every section or point it \
    names, in its order, with its own heading line, and nothing it did not ask for. When it asks \
    you to write something as the user (feedback, an email, a summary in their voice), write it \
    in the first person as them, ready to send, with real judgments and specifics — not a \
    description of what such a text could contain. \
    Each transcript line starts with [Ns], the seconds from the start. When a statement comes \
    from a specific moment, cite it as [Ns] using that line's number. \
    Answer in the language the question is written in; keep quoted words in their original \
    language. Use as much length as the question calls for. Plain text: short headings on \
    their own line and bullet lists are fine; no markdown symbols like # or **.
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
