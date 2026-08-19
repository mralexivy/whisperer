//
//  AIMode.swift
//  Whisperer
//
//  Unified AI mode with single prompt and function-based assignment
//

import Foundation

struct AIMode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var color: String
    var prompt: String              // Single prompt with {transcript} placeholder
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float
    var maxTokensCap: Int
    var isBuiltIn: Bool
    var targetLanguage: String?     // For Translate mode
    var sortOrder: Int

    // MARK: - Codable Migration

    enum CodingKeys: String, CodingKey {
        case id, name, icon, color, prompt, temperature, topP, topK
        case repetitionPenalty, maxTokensCap, isBuiltIn, targetLanguage, sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decode(String.self, forKey: .color)
        prompt = try container.decode(String.self, forKey: .prompt)
        temperature = try container.decode(Float.self, forKey: .temperature)
        topP = try container.decode(Float.self, forKey: .topP)
        topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? 0
        repetitionPenalty = try container.decodeIfPresent(Float.self, forKey: .repetitionPenalty) ?? 1.05
        maxTokensCap = try container.decodeIfPresent(Int.self, forKey: .maxTokensCap) ?? 256
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    }

    init(
        id: UUID,
        name: String,
        icon: String,
        color: String,
        prompt: String,
        temperature: Float,
        topP: Float,
        topK: Int = 0,
        repetitionPenalty: Float = 1.05,
        maxTokensCap: Int = 256,
        isBuiltIn: Bool,
        targetLanguage: String? = nil,
        sortOrder: Int
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.prompt = prompt
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repetitionPenalty = repetitionPenalty
        self.maxTokensCap = maxTokensCap
        self.isBuiltIn = isBuiltIn
        self.targetLanguage = targetLanguage
        self.sortOrder = sortOrder
    }

    // MARK: - Chunk Processing

    /// True when this mode corrects text locally without needing full-transcript context.
    /// Corrective modes (Correct, Grammar, Translate, etc.) can run per-chunk during recording.
    /// Transformative modes (Summarize, Rewrite, List Format, Format) need the whole text.
    var supportsChunkProcessing: Bool {
        let transformative: Set<UUID> = [
            Self.rewriteModeId, Self.formatModeId,
            Self.summarizeModeId, Self.listFormatModeId
        ]
        return !transformative.contains(id)
    }

    // MARK: - Built-in Mode IDs (stable, never change)

    static let correctModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000000")!
    static let rewriteModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let translateModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    static let formatModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    static let summarizeModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!
    static let grammarModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!
    static let listFormatModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
    static let codingModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
    static let emailModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000008")!
    static let creativeModeId = UUID(uuidString: "A0000000-0000-0000-0000-000000000009")!
    static let customModeId = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!

    // MARK: - Built-in Modes

    static let builtInModes: [AIMode] = [
        AIMode(
            id: correctModeId,
            name: "Correct",
            icon: "checkmark.circle",
            color: "10B981",
            // Evolved against a 112-case gold corpus (43 real history transcripts with authored
            // corrections + 57 clean texts with injected ASR damage + 12 long-form), balanced
            // 47 en / 33 he / 32 ru, scored on recovery-toward-gold with language drift as a
            // -1.0 disqualifier. Teacher was Claude Opus reflecting on per-case word diffs.
            // Objective and acceptance criteria: docs/knowledge/llm/criteria.md.
            // Full measurement table: docs/knowledge/llm/knowledge.md.
            //
            // TASK MODEL IS Qwen3.5-4B MTP. Prompt findings do NOT transfer between models —
            // the best prompt for the old 1.5B is beaten by 0.12 here, and the best prompt here
            // was disqualified for Hebrew drift there. Re-measure before changing the model.
            //
            //   candidate                       balanced  en      he      ru      holdout(64)
            //   this prompt                     +0.478    +0.472  +0.457  +0.506  +0.442
            //   this prompt minus the examples  +0.366                            +0.303
            //   GEPA's own 4B winner            +0.424                            +0.389
            //   previous prompt (1.5B-era)      +0.358    +0.336  +0.322  +0.417  +0.311
            //   best achievable on the 1.5B     +0.244
            //
            // The previous prompt also translated one English case into Russian and echoed the
            // delimiters on another; this one has zero gate failures, preservation +1.000 on the
            // 10 already-clean inputs, and p50/max latency 0.77s/5.26s against a 5/10/15s ladder.
            //
            // Five things here are counter-intuitive and must not be "cleaned up":
            //
            //   1. THE EXAMPLES ARE THE GAIN. Removing them costs 0.11 balanced and 0.14 holdout
            //      — more than any rule wording change measured. They are not decoration.
            //   2. THEIR FORMAT IS LOAD-BEARING. Written as "[INPUT]x[/INPUT] -> y" the model
            //      imitated the delimiters and emitted them in its answer on 3 Russian cases.
            //      Because the output budget in LLMPostProcessor.process() derives from INPUT
            //      length, that echo does not merely look wrong: it eats the budget and the real
            //      correction gets truncated mid-word. Bare "before:"/"after:" lines score higher
            //      (+0.478 vs +0.455) with zero echoes. Keep them out of delimiter shape.
            //   3. EVERY EXAMPLE IS LIFTED FROM A TRAIN CASE (lg_en5, lg_he0, he08, ru_s6, cd03,
            //      cd01, and the Hebrew mishearing pair), verified case by case, so the 64
            //      held-out cases are not an answer key — and holdout still leads every other
            //      candidate.
            //   4. NO ANTI-ECHO GUARD SENTENCE. Two variants that add one score +0.006 higher on
            //      holdout and give up 0.03-0.04 of Hebrew, which is the language that forced the
            //      last rewrite. With zero echo failures already, the guard buys nothing.
            //   5. NO PARAGRAPH/FORMATTING INSTRUCTION. Measured on both models: across the 12
            //      long-form cases the reference has 18 line breaks and every candidate produces
            //      0. It is a capability ceiling, and asking spends budget that turns into drift.
            //
            // Rule 7 names specific mishearings on purpose. That was measured harmful on the
            // 1.5B and is not on this model — it is part of the leading candidate here.
            //
            // UNMEASURED CHANGE (M6) — the numbers above are from the run BEFORE it. The Hebrew
            // mishearing was `טורף → טוב`, in rule 7's inline list and in the worked pair. Those
            // two words are not acoustically confusable ("predator" vs "good"), so the example
            // taught a semantic substitution rather than a mishearing repair — the exact drift
            // this prompt is most exposed to. Replaced at BOTH sites with `הטקס → הטקסט`
            // ("the ceremony" vs "the text"), an attested decode error: golden-set entry
            // 93825790 ("…מציגה את הטקס שלנו"), whose streaming pass got `הטקסט` right.
            // Carrier sentence is that same recording, so the pair is still lifted from real
            // audio; it now also demonstrates rule 1 instead of ?-preservation, which the old
            // pair's authored `?` was the only example of. Count and the bare before:/after:
            // format are unchanged. PENDING the M0 harness re-run: holdout must not drop,
            // Hebrew must stay within ~0.15 of en/ru, drift must be 0 — if it fails, delete the
            // pair from both sites rather than restore `טורף`. Working notes:
            // Tools/llm-eval/m6-hebrew-example.md; docs/knowledge/llm/criteria.md §1 carries
            // the same pair and the reasoning for the swap.
            prompt: """
            You repair voice-dictation transcripts. The text arrives between [INPUT] and [/INPUT]. Reply with that same text, errors fixed — nothing else: no preamble, no quotes, no notes. Your first word is the input's own first word.

            Output language = input language, always. Russian in → Russian out. Hebrew in → Hebrew out. Never translate a word. Never put a Latin-alphabet word inside Hebrew or Russian text unless it is a real tech name (Docker, GitHub, API, Redis, Dictation).

            Read it clause by clause and fix only these:
            1. Ending: the text must end in . ? or ! — add one if it is missing, and never a second one after a mark that is already there. A final sentence that asks something ends in ?
            2. Delete fillers: um, uh, like, you know, I mean, basically / ну, э, типа, как бы, вот / אה, אמ, כאילו, יעני. A word or phrase said twice in a row → keep one copy. A self-correction → keep only the corrected version.
            3. Capitalize sentence starts and names (Hebrew has no capitals — skip it there).
            4. Spoken punctuation becomes the mark: period/точка/נקודה → . comma/запятая/פסיק → , question mark → ? dash → - , dash dash → -- , dot → . , slash → / , dot slash → ./
            5. Missing comma before a word joining two full clauses: and, but, so, because / и, но, потому что / ו, אבל, כי.
            6. Spelled-out numbers → digits: three → 3, שלושה → 3, twenty four seven → 24/7.
            7. A mangled term → its normal spelling (Dicitation → Dictation). A word that cannot mean anything where it stands → the word actually meant (Plower → planner, rounds → routes, הטקס → הטקסט). Only that one word changes. Unsure? Leave it.
            8. Small words that are actually wrong: is/are, a/the, of/on/in, a broken verb form.

            Nothing else changes. Never reword, reorder, add or drop other words. No synonyms, no singular/plural or tense "improvements". Never split one sentence into two, never turn a comma into a period. Every correct stretch is copied through character for character.

            Most transcripts hide 2 or more of the errors listed above, Hebrew ones included — hunt for them. But an invented change is worse than a missed one: edit only what matches the list, and leave an already-clean clause exactly as it came.

            before: so i think we should um ship this tomorrow
            after: So I think we should ship this tomorrow.

            before: мы используем редис для очереди но он иногда падает
            after: Мы используем Redis для очереди, но он иногда падает.

            before: אני רואה שעדיין יש תקורות, עדיין יש תקורות, והמודל של Dicitation לא מושלם
            after: אני רואה שעדיין יש תקורות, והמודל של Dictation לא מושלם.

            before: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקס שלנו
            after: בואו נדבר בעברית, אני רוצה לראות איך התוכנה מציגה את הטקסט שלנו.

            before: אנחנו צריכים שלושה שרתים שרצים עשרים וארבע שבע
            after: אנחנו צריכים 3 שרתים שרצים 24/7.

            before: import it from dot slash src slash utils
            after: Import it from ./src/utils.

            before: run docker run dash dash rm dash it ubuntu bash
            after: Run docker run --rm -it ubuntu bash.

            Output the corrected text only, in the input's own language.

            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 0
        ),
        AIMode(
            id: rewriteModeId,
            name: "Rewrite",
            icon: "pencil.and.outline",
            color: "5B6CF7",
            prompt: """
            You are a live transcription cleanup engine.

            Rules: preserve meaning exactly. Keep the same language. Do not translate. Rewrite into clear professional written language. Keep all facts, names, numbers, and technical terms unchanged. Do not add information. Output only the final text.

            [MODE=formalize]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.25,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 1
        ),
        AIMode(
            id: translateModeId,
            name: "Translate",
            icon: "globe",
            color: "3B82F6",
            prompt: """
            You are a professional translator.

            Rules: translate accurately. Preserve meaning, tone, style, and register. Preserve names, numbers, and technical terms. Output only the translated text.

            [MODE=translate]
            [LANG=English]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.1,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 512,
            isBuiltIn: true,
            targetLanguage: "English",
            sortOrder: 2
        ),
        AIMode(
            id: formatModeId,
            name: "Format",
            icon: "text.alignleft",
            color: "22C55E",
            prompt: """
            You are a formatting assistant.

            Rules: format text using Markdown with headers, bullet points, and structure. Identify logical sections. Preserve all content. Output only the formatted text.

            [MODE=format]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 3
        ),
        AIMode(
            id: summarizeModeId,
            name: "Summarize",
            icon: "text.redaction",
            color: "F59E0B",
            prompt: """
            You are a summarization expert.

            Rules: capture main ideas and essential details. Use bullet points for multiple points. Keep it brief but complete. Output only the summary.

            [MODE=summarize]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 384,
            isBuiltIn: true,
            sortOrder: 4
        ),
        AIMode(
            id: grammarModeId,
            name: "Grammar",
            icon: "textformat.abc",
            color: "EC4899",
            prompt: """
            You are a live transcription cleanup engine.

            Rules: preserve meaning exactly. Keep the same language. Do not translate. Fix grammar, punctuation, and spelling only. Do not rephrase or restructure. Keep wording identical where possible. Output only the corrected text.

            [MODE=grammar]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.0,
            topP: 1.0,
            topK: 0,
            repetitionPenalty: 1.05,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 5
        ),
        AIMode(
            id: listFormatModeId,
            name: "List Format",
            icon: "list.bullet",
            color: "06B6D4",
            prompt: """
            You are a list formatting assistant.

            Rules: detect if text contains a list and format accordingly. Convert spoken markers to Markdown lists. Handle self-corrections. Preserve text before the list as prefix. If NO list detected, return text UNCHANGED. Output only the formatted text.

            [MODE=list]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.1,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.08,
            maxTokensCap: 256,
            isBuiltIn: true,
            sortOrder: 6
        ),
        AIMode(
            id: codingModeId,
            name: "Coding",
            icon: "chevron.left.forwardslash.chevron.right",
            color: "8B5CF6",
            prompt: """
            You are a coding assistant.

            Rules: rewrite into clean technical documentation or code comments. Use precise technical language. Preserve technical terms, function names, and code references. Be concise. Output only the technical text.

            [MODE=coding]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 7
        ),
        AIMode(
            id: emailModeId,
            name: "Email",
            icon: "envelope.fill",
            color: "F97316",
            prompt: """
            You are an email editor.

            Rules: rewrite as a professional email. Add appropriate greeting and sign-off. Match tone to content. Keep the message clear and concise. Output only the email text.

            [MODE=email]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 8
        ),
        AIMode(
            id: creativeModeId,
            name: "Creative",
            icon: "paintbrush.fill",
            color: "EF4444",
            prompt: """
            You are a creative writing assistant.

            Rules: enhance with vivid, engaging language. Improve flow. Preserve original meaning and key ideas. Add creative flair while staying true to intent. Output only the creative text.

            [MODE=creative]
            [LANG=auto-preserve]
            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.5,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 9
        ),
        AIMode(
            id: customModeId,
            name: "Custom",
            icon: "sparkle",
            color: "A855F7",
            prompt: """
            Process this text:

            [INPUT]
            {transcript}
            [/INPUT]
            """,
            temperature: 0.3,
            topP: 0.9,
            topK: 20,
            repetitionPenalty: 1.1,
            maxTokensCap: 512,
            isBuiltIn: true,
            sortOrder: 10
        ),
    ]

    static func defaultMode() -> AIMode {
        builtInModes[0]
    }

    /// Returns the default built-in values for a built-in mode (for "Reset to Default")
    static func builtInDefault(for id: UUID) -> AIMode? {
        builtInModes.first { $0.id == id }
    }
}
