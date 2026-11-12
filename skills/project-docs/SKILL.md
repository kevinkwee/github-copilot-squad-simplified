---
name: project-docs
description: 'Bootstrap or update the user and engineering docs of a project, so people can understand and use it without reading its code. Use when: asked to document a project or set up a docs site, or a change alters behavior, a flag, a contract, or anything users see in a project whose AGENTS.md declares a Docs Setup.'
argument-hint: '[bootstrap | update]'
license: MIT
---

# Project Docs

Docs let people understand a project, use it, and predict how it behaves without reading its code. The code and tests stay the source of truth, and the docs must match them.

Two modes:

- **bootstrap**: document an existing project, or record the setup of the docs it already has. Runs only when the user asks for it.
- **update**: keep the docs in step with a change, inside the same change.

## Docs Setup

A project declares its docs in a `### Docs Setup` subsection of the `## Documentation` section in its root `AGENTS.md`. Agents look nowhere else, so a project without that subsection has no docs setup and update mode does not run for it. The subsection carries these fields:

```markdown
### Docs Setup

- Audiences: who reads the docs, for example developers who call the library, or end users plus the engineers who maintain the product.
- Page model: `shared` or `split`.
- Docs root: the folder that holds the docs source, for example `docs/`.
- Framework: the docs framework and its config file, or `markdown` for plain Markdown with no site.
- Build command: the command that builds the docs and fails on broken links, or `none`.
- Generated reference: each generated page with its source and the command that regenerates it, or `none`.
```

Page models:

- **shared**: one page per feature. User content comes first, followed by a `How it works` section for engineers. Fits projects whose users are technical, such as libraries, CLIs, APIs, and developer tools.
- **split**: a user guide and an internals section in the same site. Fits products whose end users are not technical, because the user asks how to complete a task while the engineer asks how the system behaves.

## Shared rules (both modes)

- Write for a cold reader. Describe the current behavior, never how it changed. No change narration, no ticket or iteration mentions, and no references to conversations or documents the reader cannot find.
- Name pages and sections in the vocabulary of their audience. User pages use the names the product shows, not internal module or class names.
- Never restate what the code already states, such as signatures, field lists, and configuration keys with their defaults. When the project has a source for that material (an OpenAPI spec, a schema, `--help` output), generate a reference page from it and link to it. Never hand-edit a generated page. Change its source and regenerate it.
- Every statement must be checkable against the code or tests. Read the code behind a statement before writing it. Delete a statement you cannot verify instead of softening it.
- Never put secrets, credentials, tokens, internal hostnames, or personal data in docs or examples. Use obvious placeholders.
- Keep `README.md` a short landing page: what the project is, a quick start, and a link to the docs. Move content out of it only with the user's approval.
- The writing rules of the project's `AGENTS.md` apply. Without such rules: no em-dashes, en-dashes, or other non-ASCII dashes, no ASCII hyphen as a clause separator, and periods or commas over semicolons and colons.
- Create only pages and sections that have content. No empty placeholder pages.

## Page layout

Organize the docs root by what the reader needs, and create only the folders that have pages:

```text
docs/
├── index.md              # what the project is and where to start
├── getting-started.md    # one guided path from install to a first result
├── guides/               # one task per page
├── features/             # one page per feature
├── reference/            # generated or exhaustive lookup material
└── internals/            # split model only: architecture, flows, decisions
```

A feature page follows this outline and drops the sections that do not apply:

1. **Purpose**: what the feature is for, in one paragraph.
2. **Usage**: how to use it, with one minimal example.
3. **Behavior**: what happens, including the errors and edge cases a user can hit.
4. **Configuration**: the options that change the behavior and their effect. Link to the reference pages for exhaustive lists.
5. **Limitations**: what the feature does not do.
6. **How it works**: the flow, invariants, and contracts engineers need, plus the reasons behind non-obvious design choices. In the split model this section is a page under `internals/` instead.

## Bootstrap mode

Run it only when the user asks, for example "document this project" or "set up docs". It is a large job, so it never starts as a side effect of another request.

1. **Inspect the repo.** Find existing docs (a docs folder, a framework config such as `zensical.toml`, `mkdocs.yml`, a Docusaurus config, an Astro config that uses Starlight, or a Sphinx `conf.py`), `README.md` content that belongs in the docs, the stack and package manager, the surface users touch (commands, flags, routes, screens, public API, configuration), and reference sources (an OpenAPI spec, a schema, `--help` output).
2. **Ask the user which framework to use**. Put the [framework comparison](#framework-comparison) and a recommendation for this project, with its reason, into the question, and ask for the audiences too when the repo does not show them. Pick the recommendation by the first case that matches:
   - **No docs**: follow the recommendation by stack below the comparison.
   - **Docs on a framework that is in maintenance mode or unmaintained, or has announced or reached its end of life**, such as Material for MkDocs: migrate to its successor, for example Zensical. Without a successor, follow the recommendation by stack.
   - **Docs on any other framework**: keep that framework.
3. **Plan** and present it before writing anything: the Docs Setup values, the feature list in the audience's vocabulary, the pages to create, the framework config and its pinned dependencies (or the migration), any content to move out of `README.md`, and the build command. For existing docs, keep their layout and conventions, and plan only the missing pages. Write nothing until the user approves the plan.
4. **Write** the framework config with the docs dependencies pinned in the project's lockfile or a pinned requirements file, then the pages, the generated reference, and the Docs Setup subsection in the root `AGENTS.md`.
5. **Validate**, and fix what fails:
   - the build command passes
   - every statement on every page was checked against the code
   - no non-ASCII dashes remain unless the project's writing rules allow them (`rg -n '[\x{2010}-\x{2015}]'` across the docs root returns nothing), and no ASCII hyphen separates clauses
6. **Report** the Docs Setup values, the pages created, and anything left undocumented with the reason.

### Framework comparison

The table reflects the state in November 2026. When web access is available, check the latest release and maintenance status of each candidate before recommending one. When it is not, say in the question that the table could not be checked.

| Framework | Build needs | Fits | Watch out for | Strict build |
| --- | --- | --- | --- | --- |
| Zensical | Python | Any stack that wants a Markdown site with search and navigation built in. From the Material for MkDocs team, and builds existing `mkdocs.yml` projects. | Still 0.x, so pin the version and expect changes between releases. | `zensical build --strict` |
| Material for MkDocs | Python | Projects that already use it, until they migrate. | Maintenance mode since November 2025, with critical and security fixes until its end of life on May 5, 2027, and MkDocs 1.x itself is unmaintained. Do not start a new site on it, and recommend migrating an existing one to Zensical. | `mkdocs build --strict` |
| Starlight (Astro) | Node | Node and TypeScript projects, with fast static output, MDX components, and built-in translations. | Still 0.x, so pin the version. No built-in docs versions per release. Internal links are validated only with the `starlight-links-validator` plugin. | `astro build` with that plugin |
| Docusaurus | Node | Product docs that need a docs version per release, or React components. | Heavier setup and dependency tree than the others. Broken anchors and broken Markdown links only warn by default. | `docusaurus build`, with `onBrokenLinks`, `onBrokenAnchors`, and `markdown.hooks.onBrokenMarkdownLinks` set to `throw` |
| Sphinx | Python | Python libraries whose API reference comes from docstrings. | reStructuredText by default, and Markdown needs the MyST extension. | `sphinx-build -W --keep-going` with the source and output folders |
| Plain Markdown | Nothing | Projects with a handful of pages, rendered by the git host. | No search or navigation, and no build to catch broken links. | `none` |

Recommendation by stack:

- **Node or TypeScript**: Starlight, or Docusaurus when the docs need a version per release.
- **Python library with an API reference from docstrings**: Sphinx.
- **Any other stack**: Zensical.
- **A handful of pages**: plain Markdown.

## Update mode

Run it inside the change itself, and only for a project with a Docs Setup. A request that changes only docs pages runs it too.

1. **Decide whether the docs change.** They change when the change alters behavior, a flag or option, a contract (inputs, outputs, errors, permissions), or anything users see, or adds or removes a feature. Refactors, renames of internal names, and fixes that restore documented behavior leave the docs alone.
2. **Find the affected pages.** Search the docs root for the names users see that the change touches, such as commands, flags, options, endpoints, screens, error messages, and the feature name.
3. **Update** the affected pages. Add a page for a new feature. For a removed feature, delete its page, its navigation entry, and the links that pointed to it. Regenerate the reference pages whose source changed.
4. **Build** with the build command unless it is `none`, and fix what fails.
5. **Report** the docs impact: the pages changed, or why no page needed a change.
