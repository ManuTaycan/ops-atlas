# Working rules for Codex

Before changing this repository, read [Project scope](PROJECT_SCOPE.md), [Decisions](DECISIONS.md), the relevant issue, and open pull requests. Inspect the current tree and preserve unrelated changes. Keep work on a task branch, create or update a pull request targeting `main`, never push directly to `main`, and never merge autonomously.

This is a public repository. Sanitize content before committing or uploading it. Never include secrets, personal email addresses, customer or company identifiers, real internal domains or hostnames, tenant, subscription or resource IDs, IP addresses from real environments, or unredacted logs and screenshots. Use clearly fictional placeholders when an example is essential, and check that they cannot be mistaken for real infrastructure.

Build articles from real solved cases. Do not invent technical facts, sources, practical tests, supported versions, or root causes. Prefer current primary or vendor sources for facts that can change. State uncertainty explicitly. Keep source verification (checking documentation) distinct from practical testing (performing steps in a stated environment). Never run article commands against real infrastructure as part of repository work.

Use the appropriate template without filling irrelevant sections. Give administrators the command or UI path when known, why a relevant step matters, what its result means, and how to verify the intended final state. Keep one canonical location for each article and add a topic folder only when a real article needs it.
