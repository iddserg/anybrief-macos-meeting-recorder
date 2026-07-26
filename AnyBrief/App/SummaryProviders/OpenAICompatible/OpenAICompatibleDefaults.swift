import Foundation

enum OpenAICompatibleDefaults {
    static let prompt = """
    Summarize this meeting transcript as a concise, structured Markdown report.

    Use the meeting metadata/frontmatter if it is present: title, date, participants, duration, calendar context, and any other useful fields.

    Target format by meaning. Translate every Markdown heading below into %lang%; do not keep these English heading labels verbatim unless %lang% is English:
    # Meeting Summary

    ## Meeting Goal
    Briefly describe why the meeting happened and what the participants tried to decide or discuss.

    ## Participants
    List participants and organizations/roles if they can be inferred from the transcript or metadata.

    ## Main Topics
    Summarize the key topics as separate Markdown sections. Use clear section titles based on the actual discussion, not generic labels.

    ## Key Takeaways
    List the most important conclusions, agreements, risks, constraints, and open points.

    ## Next Steps
    Write concrete next steps as bullet points. Include owners and deadlines only if they are mentioned.

    Rules:
    - Write in %lang%.
    - All Markdown headings, section names, and bullet text must be in %lang%.
    - Do not invent facts.
    - Do not include questions.
    - Do not copy raw transcript lines or timestamps.
    - Prefer concise business-style wording.
    - Preserve specific names, products, companies, metrics, and decisions when they are important.
    """
}
