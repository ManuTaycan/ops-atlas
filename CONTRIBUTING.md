# Contributing

## From solved case to article

1. Start with a real solved case and identify the reusable lesson. Record only facts that can be shared publicly. Choose a [note, explanation, or guide](README.md#content-types) according to the reader's need, not the length of the original case.
2. Draft in the [matching template](templates/). Create a topic folder only when the article is ready for it, and keep one canonical copy. Remove template prompts and sections that do not apply.
3. Explain the context and, for a procedure, why relevant diagnostic or configuration steps are used. Give commands or UI paths, expected observations, and how to interpret alternatives when these are known. Describe the intended final state and a way to verify it. Include preparation, impact, risks, and recovery where relevant.
4. Separate a **confirmed root cause** (supported by case evidence) from a **plausible explanation** (not established). Label a **workaround** as temporary and distinguish it from the **recommended permanent state**. If the cause or outcome remains uncertain, say so.
5. Check changeable technical claims against current primary or vendor documentation when possible. Cite the sources and record the source-check date. Do not create citations or version claims from memory. Source verification establishes what a source says; it does not establish that a procedure worked in practice.
6. Record practical-test status separately: tested or not tested, with the relevant environment and limits if tested. Editorial review checks clarity and consistency; source verification checks cited claims; practical testing checks observed behavior. Do not claim a test that did not happen.
7. Sanitize **before committing or uploading**. Remove secrets, personal email addresses, customer or company identifiers, internal domains, real hostnames, tenant/subscription/resource IDs, IP addresses from real environments, and unredacted logs or screenshots. Inspect commands, output, links, file names, and image metadata too. Use unmistakably fictional placeholders only where needed.
8. Review the diff, links, and English, then open a task-branch pull request with the [PR template](.github/pull_request_template.md). State validation, evidence, testing limits, and remaining uncertainty. Do not run article commands against real infrastructure for repository validation.

Contributions should stay within [project scope](PROJECT_SCOPE.md). The [project decisions](DECISIONS.md) explain the initial conventions.
