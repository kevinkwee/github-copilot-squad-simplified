---
name: project-docs
description: 'Bootstrap or update the user and engineering docs of a project, including its architecture map and decision records, so people can understand and use it without reading its code. Use when: asked to document a project or set up a docs site, a change alters behavior, a flag, a contract, components, or anything users see in a project whose AGENTS.md declares a Docs Setup, or a design decision comes up that may deserve a decision record.'
argument-hint: '[bootstrap | update]'
license: MIT
---

# Project Docs

Docs let people understand a project, use it, and predict how it behaves without reading its code. The code and tests stay the source of truth, and the docs must match them.

Two modes:

- **bootstrap**: document an existing project, or record the setup of the docs it already has. Runs only when the user asks for it.
- **update**: keep the docs in step with a change, inside the same change.

The docs have two areas:

- **User docs**, under the docs root and outside the engineering root and the decision records folder: what the project does and how to use it.
- **Engineering docs**: the architecture map and the split model's feature internals, under the engineering root, plus the decision records in their own folder. They are repo-only by default.

## Docs Setup

A project declares its docs in a `### Docs Setup` subsection of the `## Documentation` section in its root `AGENTS.md`. Agents look nowhere else, so a project without that subsection has no docs setup, and neither update mode nor decision records apply to it until bootstrap adds one. The subsection carries these fields:

```markdown
### Docs Setup

- Audiences: who reads the docs, for example developers who call the library, or end users plus the engineers who maintain the product.
- Page model: `shared` or `split`.
- Docs root: the folder that holds the user docs source, for example `docs/`.
- Engineering root: the folder that holds the architecture map and, in the split model, the feature internals, for example `engineering/`.
- Decision records: the folder that holds the decision records, for example `engineering/decisions/`. It stays set after an opt-out, because accepted records stay in force.
- New decision records: `on` or `off`. `off` stops proposing records for new decisions. A missing field means `on`.
- Framework: the docs framework and its config file, or `markdown` for plain Markdown with no site.
- Build command: the command that builds the docs and fails on broken links, or `none`.
- Generated reference: each generated page with its source and the command that regenerates it, or `none`.
```

Engineering docs are repo-only by default. They stay repo-only while the engineering root and the decision records folder sit outside the docs root, or while the framework config excludes them from the site build. Engineering docs inside the docs root without such an exclusion are published by the site.

A Docs Setup may lack the engineering fields. Without an Engineering root, the project has no architecture map, and split-model feature internals stay where its docs keep them. Without a Decision records field, the project has no decision records and proposes none. Rerunning bootstrap captures the existing docs setup and adds the missing fields once the user approves the plan.

Page models:

- **shared**: each feature page carries a `How it works` topic for engineers, before any troubleshooting topics. Fits projects whose users are technical, such as libraries, CLIs, APIs, and developer tools.
- **split**: feature pages stay at the user's level, and each feature's internals are a page in the engineering docs. Fits products whose end users are not technical, because the user asks how to complete a task while the engineer asks how the system behaves.

## Shared rules (both modes)

- Write for a cold reader. Describe the current behavior, never how it changed. No change narration, no ticket or iteration mentions, and no references to conversations or documents the reader cannot find.
- Name pages and sections in the vocabulary of their audience. User pages use the names the product shows, not internal module or class names.
- Never restate what the code already states, such as signatures, field lists, and configuration keys with their defaults. When the project has a source for that material (an OpenAPI spec, a schema, `--help` output), generate a reference page from it and link to it. Never hand-edit a generated page. Change its source and regenerate it.
- Every statement must be checkable against the code or tests. Read the code behind a statement before writing it. Delete a statement you cannot verify instead of softening it.
- Never put secrets, credentials, tokens, internal hostnames, or personal data in docs or examples. Use obvious placeholders.
- User pages never link into the engineering docs. Engineering pages may link to user pages.
- `How it works` topics and pages explain behavior: the flow, invariants, and contracts. The reasons behind a design choice belong in its decision record.
- Keep `README.md` a short landing page: what the project is, a quick start, and a link to the docs. Move content out of it only with the user's approval.
- The writing rules of the project's `AGENTS.md` apply. Without such rules: no em-dashes, en-dashes, or other non-ASCII dashes, no ASCII hyphen as a clause separator, and periods or commas over semicolons and colons.
- Create only pages and sections that have content. No empty placeholder pages.

## Page kinds

This skill fixes the kinds of pages and what each contains. Folder names, navigation, and file placement follow the framework's conventions and the project's size, so a small project may need a handful of pages and no subfolders. The framework also decides where the docs root is, for example `src/content/docs/` for Starlight.

User docs:

- **Home**: what the project is and where to start.
- **Get started**: one guided path from install to a first result.
- **Feature pages**: one per feature, built from typed topics as described below.
- **Tutorials**: only for a journey that spans several features.
- **Reference**: generated or exhaustive lookup material.

Engineering docs:

- **Architecture map**: one page, described below.
- **Decision records**: one file per decision in the decision records folder, described below.
- **Feature internals** (split model only): the `How it works` page of each feature.

### Feature pages

Feature pages follow the topic types of the GitLab documentation style guide. Each topic is exactly one type, and a page drops the types it does not need:

1. **Concept**: what the feature is, when to use it, and what it does not do. One concept topic opens the page.
2. **Task**: one topic per user goal, written as numbered steps with a minimal example.
3. **Reference**: the options that change the behavior and their effect. Link to the generated reference for exhaustive lists.
4. **How it works** (shared model only): a concept topic for engineers that covers the flow, invariants, and contracts. In the split model this is a feature internals page instead.
5. **Troubleshooting**: the errors and edge cases a user can hit, each with its fix. Troubleshooting topics come last on the page, as the GitLab guide requires.

### Architecture map

One page at the engineering root, mostly diagrams. Draw the diagrams as Mermaid code blocks, so they show in diffs and reviews and agents can update them, and structure them by the C4 model:

- a system context diagram: the system, its users, and the external systems it talks to
- a container diagram: the apps, services, and data stores, and how they talk
- a component diagram only for a container complex enough to need one
- a dynamic diagram, drawn in sequence style, for each of the few flows that matter most

Keep each diagram small enough to read at a glance. Text is limited to what a diagram cannot carry: a one-line caption per diagram, a short list of invariants that hold across components, and links to the decision records behind the structure. Every box and arrow matches something in the code, under the name the code uses.

### Decision records

A decision record captures one design decision that is expensive to reverse and not obvious from the code, for example the choice of a framework, a storage engine, a protocol, or an auth model, or a trade-off in a public contract. Naming, refactors, and small library picks never qualify.

- **Ask before writing.** When a qualifying decision comes up, whether in a question to the user or in the agent's own plan, ask whether to record it inside that same question or plan approval, not as a separate round. A qualifying decision that would otherwise be settled without a question gets a question for this. Write the record only after the user says yes. Never ask about a decision that does not qualify. When New decision records is `off`, skip all of this for new decisions.
- **Capture at decision time**, from the question, the options, and the answer. Never reconstruct the reasons for a past decision. Bootstrap writes a record for a past decision only when the user supplies the reasoning.
- **Format**: one file per decision, named `NNNN-short-title.md` with a four-digit sequence number, based on the MADR minimal template plus a Status line. It carries a title, the Status line (`accepted`, `deprecated`, or `superseded by NNNN`), Context and problem, Considered options, Decision, and Consequences. A project that already keeps records keeps its own format, and its own folder unless the user chooses a move during bootstrap.
- **Never edit the content of an accepted record.** Its status line is the only change it takes, to `superseded by NNNN` or `deprecated`.
- **Enforcement**: the user's request always wins, and no record stays `accepted` while the code contradicts it. When a request or plan contradicts an accepted record, ask the user to pick one of these, even when New decision records is `off`:
  1. Make the change and write a new record that supersedes the old one. Recommend this one.
  2. Make the change without a new record, and set the old record's status to `deprecated`.
  3. Keep to the accepted record, and find another approach.

  Leaving the record `accepted` while making the change is not a path. A user who wants the change without a new record gets path 2.

## Bootstrap mode

Run it only when the user asks, for example "document this project" or "set up docs". It is a large job, so it never starts as a side effect of another request.

1. **Inspect the repo.** Find existing docs (a docs folder, a framework config such as `zensical.toml`, `mkdocs.yml`, a Docusaurus config, an Astro config that uses Starlight, or a Sphinx `conf.py`), existing engineering docs such as architecture pages and decision records (common folders are `docs/decisions/`, `docs/adr/`, and `doc/adr/`), `README.md` content that belongs in the docs, the stack and package manager, the surface users touch (commands, flags, routes, screens, public API, configuration), and reference sources (an OpenAPI spec, a schema, `--help` output).
2. **Ask the user which framework to use**. Put the [framework comparison](#framework-comparison) and a recommendation for this project, with its reason, into the question, and ask for the audiences too when the repo does not show them. Pick the recommendation by the first case that matches:
   - **No docs**: follow the recommendation by stack below the comparison.
   - **Docs on a framework that is in maintenance mode or unmaintained, or has announced or reached its end of life**, such as Material for MkDocs: migrate to its successor, for example Zensical. Without a successor, follow the recommendation by stack.
   - **Docs on any other framework**: keep that framework.

   The framework choice qualifies for a decision record, so the same question may offer to record it.
3. **Plan** and present it before writing anything:
   - the Docs Setup values, with the engineering root and the decision records folder outside the docs root unless the user wants them published
   - for existing decision records or engineering pages inside the docs root, a choice between moving them out of the docs root and excluding them from the site build
   - the feature list in the audience's vocabulary, and the user pages to create
   - the engineering pages to create, listed apart from the user pages: the architecture map and, in the split model, one feature internals page per feature
   - the decision records to write: the framework choice record when the user asked for it, and past decisions the user supplies the reasoning for. The decision records folder is created together with its first record and is never empty
   - the framework config and its pinned dependencies (or the migration), with Mermaid enabled when published pages carry diagrams
   - any content to move out of `README.md`
   - the build command

   For existing docs, keep their layout and conventions, and plan only the missing pages. Write nothing until the user approves the plan.
4. **Write** the framework config with the docs dependencies pinned in the project's lockfile or a pinned requirements file, then the user pages, the generated reference, the engineering pages, the planned decision records, and the Docs Setup subsection in the root `AGENTS.md`. Point the `## Architecture` section of that `AGENTS.md` to the architecture map instead of re-explaining the flows there.
5. **Validate**, and fix what fails:
   - the build command passes
   - every statement, box, and arrow was checked against the code
   - no user page links into the engineering docs
   - no non-ASCII dashes remain and no ASCII hyphen separates clauses, where the writing rules that apply ban them (`rg -n '[\p{Pd}&&[^-]]'` and `rg -n '[^\s>|] -{1,3}(\s|$)'` across the docs root, the engineering root, and the decision records folder find no violations in the pages and records this run wrote by hand, except that a hit inside code or a math expression does not count as a violation). Report the violations in other files instead of fixing them, because a generated page changes only through its source, existing pages outside the plan keep their content, and an accepted record's content is never edited.
6. **Report** the Docs Setup values, the pages created, anything left undocumented with the reason, and the writing-rule violations left unfixed.

### Framework comparison

The table reflects the state in November 2026. When web access is available, check the latest release and maintenance status of each candidate before recommending one. When web access is not available, say in the question that the table could not be checked. Repo-only engineering docs need no framework for their diagrams, because GitHub and GitLab render Mermaid code blocks.

| Framework | Build needs | Fits | Watch out for | Strict build | Mermaid diagrams |
| --- | --- | --- | --- | --- | --- |
| Zensical | Python | Any stack that wants a Markdown site with search and navigation built in. From the Material for MkDocs team, and builds existing `mkdocs.yml` projects. | Still 0.x, so pin the version and expect changes between releases. | `zensical build --strict` | Built in, enabled with a `pymdownx.superfences` custom fence |
| Material for MkDocs | Python | Projects that already use it, until they migrate. | Maintenance mode since November 2025, with critical and security fixes until its end of life on May 5, 2027, and MkDocs 1.x itself is unmaintained. Do not start a new site on it, and recommend migrating an existing one to Zensical. | `mkdocs build --strict` | Built in, enabled with a `pymdownx.superfences` custom fence |
| Starlight (Astro) | Node | Node and TypeScript projects, with fast static output, MDX components, and built-in translations. | Still 0.x, so pin the version. No built-in docs versions per release. Internal links are validated only with the `starlight-links-validator` plugin. | `astro build` with that plugin | The `astro-mermaid` community plugin |
| Docusaurus | Node | Product docs that need a docs version per release, or React components. | Heavier setup and dependency tree than the others. Broken anchors and broken Markdown links only warn by default. | `docusaurus build`, with `onBrokenLinks`, `onBrokenAnchors`, and `markdown.hooks.onBrokenMarkdownLinks` set to `throw` | The `@docusaurus/theme-mermaid` theme |
| Sphinx | Python | Python libraries whose API reference comes from docstrings. | reStructuredText by default, and Markdown needs the MyST extension. | `sphinx-build -W --keep-going` with the source and output folders | The `sphinxcontrib-mermaid` extension, plus `myst_fence_as_directive = ["mermaid"]` for plain Markdown fences |
| Plain Markdown | Nothing | Projects with a handful of pages, rendered by the git host. | No search or navigation, and no build to catch broken links. | `none` | Rendered by GitHub and GitLab |

Recommendation by stack:

- **Node or TypeScript**: Starlight, or Docusaurus when the docs need a version per release.
- **Python library with an API reference from docstrings**: Sphinx.
- **Any other stack**: Zensical.
- **A handful of pages**: plain Markdown.

## Update mode

Run it inside the change itself, and only for a project with a Docs Setup. A request that changes only docs pages runs it too.

1. **Decide what changes.**
   - User docs change when the change alters behavior, a flag or option, a contract (inputs, outputs, errors, permissions), or anything users see, or adds or removes a feature.
   - The architecture map, when the project has one, changes when a component is added, removed, or renamed, or when the connections or data flows between components change.
   - Feature internals (split model) change when the flow, invariants, or contracts of a feature change.
   - Decision records change when the change settles a qualifying decision and New decision records is not `off` (ask first, as [Decision records](#decision-records) describes), or when the change contradicts an accepted record (the user picks a superseding record, a deprecation, or another approach that keeps to the record).
   - Nothing changes for refactors, renames that no page or diagram shows, and fixes that restore documented behavior.
2. **Find the affected pages.** Search the docs root for the names users see that the change touches: commands, flags, options, endpoints, screens, error messages, and the feature name. Search the engineering root and the decision records folder for the components and technologies the change touches. Without an engineering root, search the pages where the docs keep feature internals instead.
3. **Update** the affected pages. Add a page for a new feature. For a removed feature, delete its page, its navigation entry, and the links that pointed to it. Regenerate the reference pages whose source changed.
4. **Build** with the build command unless it is `none`, and fix what fails.
5. **Report** the docs impact: the pages changed, including the architecture map and decision records, or why no page needed a change. Mark each new decision record and each deprecation as confirmed by the user.
