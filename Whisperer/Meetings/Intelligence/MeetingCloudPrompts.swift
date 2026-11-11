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
    You answer the user's questions about one of their meetings. The user was in the meeting; \
    you work for them. Everything you know about the meeting is in the <meeting> block: its \
    details, the full transcript from the first second to the last, and the user's notes. \
    The question comes after it.

    How to read the transcript:
    - It is automatic speech-to-text, already cleaned up once. Words can still be misheard, \
    speakers are guessed from voices (a label can be wrong, "Speaker 2" is just a voice), and \
    it may be in Hebrew, Russian, English or a mix. Read it as someone who sat in the meeting \
    would: reconstruct what was meant, and do not refuse or hedge because it is imperfect.
    - Each line starts with [Ns], seconds from the start, then the speaker.
    - Read all of it before you answer. Summaries, decisions, action items and "what did X \
    say" questions must cover the whole meeting, not the first part that matches.

    How to answer:
    - Ground every statement about the meeting in the transcript or notes. Never invent a \
    name, number, date, decision or quote. If something the question needs was not said, say \
    so once in one short sentence and answer with what is there.
    - When the question asks for your judgment (feedback, advice, an assessment), give a real, \
    specific one, built on what was said in the meeting — and keep it clear which parts were \
    said and which are your view.
    - Cite the moment a fact comes from as [Ns], using that line's number.
    - Do exactly what the question asks, in the shape it asks for: every section or point it \
    names, in its order, each with its own heading line, and nothing it did not ask for. When \
    it asks you to write as the user (an email, feedback, a summary in their voice), write it \
    in the first person, ready to send.
    - Answer in the language the question is written in; quote transcript words in their \
    original language. As long as the question needs, no longer. Plain text: short headings on \
    their own line and "-" bullets are fine; no markdown symbols like # or **.
    """

    /// The meeting first and the question last: with a long document in the prompt, models answer
    /// better when the question follows it than when the document trails the question.
    static func askUserMessage(question: String, transcript: String) -> String {
        """
        <meeting>
        \(transcript)
        </meeting>

        <question>
        \(question)
        </question>
        """
    }
}
