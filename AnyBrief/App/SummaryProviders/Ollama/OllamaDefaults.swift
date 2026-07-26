import Foundation

enum OllamaDefaults {
    static let chatCompletionsURLString = "http://127.0.0.1:11434/v1/chat/completions"
    static let chatURLString = "http://127.0.0.1:11434/api/chat"
    static let tagsURLString = "http://127.0.0.1:11434/api/tags"
    static let psURLString = "http://127.0.0.1:11434/api/ps"
    static let showURLString = "http://127.0.0.1:11434/api/show"

    static let contextLength = 32_768
    static let chunkThreshold = 16_000
    static let chunkSize = 12_000

    static let prompt = """
    Create a concise, structured Markdown meeting summary.

    If meeting metadata/frontmatter is present, use it as context: title, date, participants, calendar description, duration, and other useful fields.

    Output format by meaning. Translate every Markdown heading below into %lang%; do not keep these English heading labels verbatim unless %lang% is English:
    # Meeting Summary

    ## Meeting Goal
    One short paragraph: why the meeting happened and what was discussed.

    ## Participants
    List participants, companies, or roles if they are clear from the text or metadata.

    ## Main Topics
    Split the content into several meaningful sections with concrete titles based on the actual meeting topics.
    In each section, include only important facts, agreements, arguments, and context.

    ## Key Takeaways
    List the main conclusions, decisions, risks, constraints, and important observations.

    ## Next Steps
    List follow-up actions. Include owners and deadlines only if they were explicitly mentioned.

    Rules:
    - Write in %lang%.
    - All Markdown headings, section names, and bullet text must be in %lang%.
    - Do not include questions.
    - Do not invent facts.
    - Do not copy timestamps or raw transcript lines.
    - Do not summarize everything line by line.
    - Preserve important names, companies, products, metrics, and agreements.
    - If the meeting was split into parts, produce one final summary and do not mention the split.
    """
}
