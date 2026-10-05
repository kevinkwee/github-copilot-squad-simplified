# AGENTS.md (Example)

This file provides guidance to AI coding agents when working with code in this repository.

<!-- This is a template. Adapt it per project: fill in the placeholder comments, delete the sections the project does not need, and keep only the rules agents in that codebase must obey. Some rules carry Python-flavored examples (Ruff, pytest, Pydantic-style validation). Keep the principle, then adapt or drop whichever parts do not fit the language or tooling. -->

## Project Overview

<!-- Provide a brief overview of the project, its purpose, its tech stack, and key features here. -->

## Prerequisites

<!-- List required runtimes, package managers, and external services. Pin versions where they are hard constraints, and add local paths (runtime location, venv) that agents need. -->

## Project Map

<!-- Delete this section unless the workspace spans several folders or repos, each with its own AGENTS.md file. -->

| Folder | Purpose | Precedence file |
|--------|---------|-----------------|
| `path/to/module-a` | One-line purpose | [`module-a/AGENTS.md`](module-a/AGENTS.md) |

When working inside a mapped folder, read and follow that folder's `AGENTS.md` in addition to this file. Where they conflict, the folder-level file wins for module-specific rules. This file wins for cross-cutting rules such as runtime version, security, and testing philosophy.

## Core Philosophy

### Trade-off Priority (when conflicts arise)

1. **Correctness**: code does what it should
2. **Simplicity and readability**: code is easy to understand
3. **Testability**: code is easy to test
4. **Performance**: code is fast enough
5. **Abstraction and reuse**: code is DRY

<!-- Adapt the priority order and entries to the project (stability or backward compatibility can rank higher in framework-heavy or legacy codebases). -->

### Ground Rules

- Read and understand existing code before modifying it.
- Treat the project's existing patterns and code as a starting point, not as evidence of correctness. Legacy code can carry bad practices, over-complex code, and code smells. If something looks wrong, speak up and write new code the right way (correct, secure, performant, readable, maintainable) instead of propagating the problem, even if that means departing from the existing code.
- Isolate new code from legacy where possible, and never copy legacy code into new code without reviewing its quality.
- If a requirement is ambiguous, ask before writing code.
- Prefer incremental delivery: core logic first, then edge cases, then refinements.
- Do not overengineer. Build for today's requirements, not hypothetical future ones.
- Do not break foundation code. Changes to widely-depended-on modules ripple into every dependent, so verify dependents before changing a shared field, method, or contract.

## Design Principles

### SOLID

| Principle | Rule | Common Mistake |
|-----------|------|----------------|
| **SRP** (Single Responsibility) | Each class/function/file has ONE reason to change. If you need "and" or "or" to describe it, split it. | Interpreting SRP as "one function per class." SRP means one *axis of change*. |
| **OCP** (Open/Closed) | Add new behavior by writing new code, not modifying existing code. Use polymorphism or strategy patterns where change is expected. | Over-engineering with premature abstractions. Apply OCP where you have *evidence* of changing requirements. |
| **LSP** (Liskov Substitution) | Subclasses must honor the contract of their parent. Prefer composition over inheritance when "is-a" is not strict. | Overriding a method to throw `NotImplementedError` or do nothing. |
| **ISP** (Interface Segregation) | Define small, role-specific interfaces. Clients depend only on methods they use. | Creating one "service" interface stuffed with methods for many unrelated roles. |
| **DIP** (Dependency Inversion) | Depend on abstractions at module boundaries, not concrete implementations. | Confusing DIP with "just use dependency injection." DIP is about inverting the *direction of source-code dependency*. |

### DRY (Don't Repeat Yourself)

- Extract shared logic when the *exact same business rule* is duplicated in 3+ places (Rule of Three).
- Single source of truth for configuration, constants, and schema definitions.
- **Prefer duplication over wrong abstraction.** Two pieces of code that look similar but serve different business purposes are NOT duplication, because merging them creates accidental coupling.
- "Wrong abstraction" means: premature generalization, unclear purpose, or coupling unrelated concerns.

### KISS (Keep It Simple)

- Choose the simplest implementation that satisfies current requirements.
- Prefer standard library solutions over custom implementations.
- A plain function call beats metaprogramming. A dictionary beats a class when all you need is data grouping.
- Do not add design patterns, abstractions, or frameworks "just in case."

### YAGNI (You Aren't Gonna Need It)

- Implement features only when there is a concrete, current requirement.
- Do not build generic/extensible frameworks before you have at least two concrete use cases.
- Delete speculative code and unused feature flags regularly.
- Three similar lines of code is better than a premature abstraction.

## Language and Runtime Constraints

<!-- Delete this section unless the project is pinned to an older language/runtime version. State the version and list the features unavailable in it (with the version they appeared in), plus the accepted alternatives. -->

- Example (a Python project pinned to 3.6): walrus `:=` and positional-only `/` parameters (3.8+), builtin generics `list[int]` (3.9+), `match`/`case` and PEP 604 unions `int | None` (3.10+). For these, use `typing.Optional`, `typing.List`, and friends instead.

## Code Quality

### Linting and Formatting

<!-- Adapt to the project's tooling and record the exact commands here. Agents run them on the files they changed. -->

- We use **Ruff** for linting and formatting.
- After making changes, always run `uv run ruff check` to lint and `uv run ruff format` to format, and only on the files you changed.
- Ensure all rules defined in the linter config (`pyproject.toml`, `ruff.toml`, `eslint.config.*`) are followed (e.g. standard line length, quotes, no unused imports).

#### Handling Linter Violations (Decision Tree)

When the linter reports a violation, follow this decision tree **in order**. Use the **least invasive** option that keeps the codebase correct and the rule meaningful. Do not jump straight to suppressing a rule. Always evaluate fixing or configuring it first.

1. **Fix the code** (preferred, almost always the right choice)
   - Resolve the underlying issue so the rule passes naturally.
   - Example: remove an unused import, rename a shadowed variable, simplify a complex conditional, add a type annotation.
   - This is the only option that improves the codebase.

2. **Configure the rule** (when the rule is valid but its **default settings/thresholds don't fit the project**). Tuning keeps the rule active while fitting the project's conventions.
   - Example tuning knobs: line length, docstring convention, complexity thresholds, quote style, magic-value allowlists.
   - Prefer **configuring** a rule over **ignoring** it when the rule's intent is sound but its defaults are too strict/loose for the codebase.
   - Add an inline comment in the config when the reason isn't obvious from the setting name.

3. **Per-line suppression** (when the violation is a **genuine, localized exception** and fixing it would make the code *worse*).
   - Use the **specific rule code(s)**, never a blanket suppression:

     ```python
     API_KEY = "test-key-not-a-real-secret"  # noqa: S106  # test fixture, never a real secret
     ```

   - Add a brief reason comment explaining *why* the suppression is necessary.
   - Suppress only the offending rule(s), not everything on that line.
   - Valid reasons: false positive, a necessary inline pattern (e.g. a security rule in a test fixture), or a framework/decorator quirk.

4. **Block-scope suppression (`disable`/`enable`)** (when a **contiguous block** of lines legitimately violates a rule and per-line suppression would be noisy).
   - Wrap the block between the disable and enable markers:

     ```python
     # ruff: disable[E501]
     LONG_STRING = """\
         ...long multi-line content where line-length violations are intentional...
     """
     # ruff: enable[E501]
     ```

   - Use the specific rule code(s), and always re-enable on the other side. Never leave a rule disabled for the rest of the file.
   - Prefer this over per-line when the block spans more than ~3 lines, or the rule would be violated on every line of the block.
   - Add a brief reason comment on the disable line when the justification isn't obvious from context.

5. **Per-file ignore in the linter config** (when a **whole file or directory** legitimately violates the rule).
   - Example: tests that intentionally use hardcoded secrets, or `__init__.py` files that re-export names.
   - Scope the glob pattern as narrowly as possible (e.g. `"tests/services/*_test.py"`, not `"**/*.py"`).
   - Document *why* each rule is ignored for that path with an inline config comment.

6. **Global ignore of the rule** (**last resort**, only when the rule is incompatible with the project's conventions or produces widespread false positives).
   - Before adding it, confirm the rule isn't catching real bugs across the codebase, and check that it isn't already ignored.
   - Always add an inline comment explaining *why* it is disabled.

### Naming

- Use clear, meaningful, intention-revealing names. The name should answer *why* it exists and *what* it does.
- Functions start with a verb that names the action they perform.
- When a framework or convention dictates the name (interface implementations, overrides, event handlers, generated hooks), follow it.
- Classes are nouns: the type is a thing, and its functions are its behavior.
- Booleans read as a yes/no question to the reader. A prefix (`is_`, `has_`, `can_`, `should_`) works, and so does a plain adjective or past participle (`enabled`, `deprecated`) when the declaration or context makes the type clear. Prefer whichever form the surrounding code already uses, so related names stay consistent.
- No abbreviations unless universally understood (`id`, `url`, `api`).
- No generic names: `data`, `result`, `obj`, `thing`, `temp`, `misc`, `utils`.
- The joiners "and" or "or" in a unit's name signal that the unit may hold two responsibilities. Treat them as a reason to re-examine the unit, and usually to split it, not as words that must never appear. When the joined form is genuinely one domain concept, the name is fine.

### Strong Typing

- Use strong typing everywhere. Avoid `any`, `object`, `dynamic`, `Object`.
- Use typed parameters and return types for all public functions.
- Never cast to `any` just to make something compile.

### Immutability

- Default to immutable. Use `const`, `readonly`, `final`, `frozen`, `tuple`, `frozenset`.
- Return new objects from transformation functions instead of mutating inputs.
- Never expose mutable internal collections. Return copies or read-only views.
- Mutable local variables inside a function are fine. The danger is mutable *shared state*.

### Early Returns and Guard Clauses

- Validate preconditions at the top of functions and return/throw early.
- Reduce nesting by inverting conditions and returning early.
- Keep the "happy path" at the lowest indentation level.

### No Magic Values

- Extract repeated numbers and strings to named constants.
- Use descriptive variable names instead of inline literals.

### Comments and Docstrings

- Do not comment obvious code. Prefer self-explanatory code through good naming, and prefer code over comments. A comment that exists only to compensate for a poor name is a failure to express yourself in code.
- Comments explain **WHY**, never **WHAT**. The code already says what it does, so a comment that restates it is noise. Before writing a comment, ask whether removing it leaves the code harder to understand. If not, delete it.
- A docstring is a concise summary of what the unit does or is, not how it is wired. Do not restate mechanics already obvious from the code it documents (signatures, type hints, decorator arguments, configuration keys). Follow the project's docstring style, omit empty sections, and keep a one-liner for obvious helpers.
- Avoid section separator comments (`# ======` banners between functions), since file structure already separates the sections.
- No commented-out code. Use version control.
- No TODO comments without ticket references (the referenced ticket must be findable by a cold reader).
- **Cold-reader oriented.** Every comment and docstring must make sense to a reader with no prior context. Do not reference internal plans, phases, iterations, decision tables, meetings, or documents the reader cannot find. If a design decision needs context, state the constraint itself.
- **No change narration.** Comments and docstrings describe the current code, not how it got there. No "previously", "no longer", "was removed", "was refactored", "moved to", "used to". If a negative statement is genuinely needed for correctness (e.g. a guard that explicitly rejects an input), state the positive contract (what *is* required). Narrate changes in the chat response, not in the code.
- **Describe the unit, not its sibling.** Do not write that code "mirrors", "reflects", "parallels", or "matches" another module or an external contract as a substitute for describing it. That couples two facts and goes stale when the sibling changes. State each fact directly where it lives.
- **No cross-repo file paths** in comments or docstrings, since readers may not have the other repos checked out. State the rule inline instead.
- **No PII-rule restatements.** The rule that PII is never logged lives in [Security](#security) and [Observability](#observability). Do not restate it on every field, method, or module. State what the unit *is*, not what must not be done with it.
- **No unverified performance claims.** Do not write estimated timings ("10-60s", "<100ms") in comments or docstrings unless they were actually measured and the measurement is load-bearing for the design.

### Functions

- Keep functions short with a single level of abstraction.
- One function does one thing. If it does two things, split it.
- Do not use boolean parameters that switch behavior. Split them into two named functions.
- Eliminate dead code and unused imports on every change.

### Performance

- Avoid N+1 queries in loops. Use bulk fetch, batch writes, and the framework's filtering/aggregation primitives instead of per-item queries or count-in-a-loop.
- Reach for raw SQL/escape hatches only for reports the framework cannot express, and always with parameterized values.

## Architecture

<!-- State which architectural style the project follows (layered, clean architecture, modular monolith, ...) and sketch it. A directory tree works well. For multi-service systems, add a C4 L1 system-context diagram. -->

```
project/
├── <layer_or_package>/     # one-line purpose
├── <layer_or_package>/     # one-line purpose
└── tests/
```

This structure can be updated as the project evolves. If you add new files or modules, update this diagram and the corresponding sections to reflect the changes.

### Separation of Concerns

- Separate domain, application, and infrastructure concerns.
- Domain/business logic must have zero imports from frameworks, databases, or HTTP layers.
- Keep side effects (I/O, logging, metrics) at the edges. Business logic should be pure.
- Use DTOs or value objects at layer boundaries, and never pass ORM models or HTTP request objects into business logic.

### Layer Rules

| Layer | CAN | CANNOT |
|-------|-----|--------|
| **Handler/Controller** | Receive input, delegate to service, return output | Contain business logic, call DB directly |
| **Service/Orchestrator** | Coordinate operations, apply business rules | Know about HTTP/transport, execute SQL directly |
| **Repository/Data Access** | Execute queries, map data | Make business decisions, call external APIs |
| **Helper** | Transform data, validate, format | Have side effects, do I/O, maintain state |
| **External Client** | Communicate with external services | Contain business logic, access database |

<!-- Adapt the layers above to the project's actual layering (e.g. framework controllers, ORM models). -->

### Dependency Injection

- Inject dependencies through constructors or method parameters. Make all dependencies explicit.
- Inject I/O boundaries (database, HTTP clients, filesystem, clock) so they are swappable in tests.
- Keep the composition root at the application entry point, separate from business logic.
- Only inject things that have *side effects* or *vary between environments*. Do not inject pure utility functions.

### Dependency Direction

- Base/shared modules are depended upon by feature modules, never the reverse. Foundation code must not import feature code.
- Do not modify vendored, generated, or third-party code, because it is an upstream snapshot. The only exception is a minimal, clearly-marked patch for a confirmed upstream bug.

## File Structure

### Avoid Over-Engineering

- Split when you have clear, reusable responsibilities. Keep together when separation adds complexity without benefit.

### File Naming

- **NEVER** use generic names: `utils`, `helpers`, `misc`, `common`, `shared` as standalone files.
- Name files after what they do, not after a contract nickname or an internal artifact.
- Keep new file names consistent with the project's existing naming scheme.

## Error Handling

- Handle expected errors explicitly. No silent failures.
- Do not use generic exceptions (`Exception`, `Error`, `object`). Use domain-relevant error types.
- Do not swallow exceptions silently. If an upstream or external call fails, log the failure (with approved identifiers, not payloads or secrets) and surface a meaningful error to the caller.
- Return or throw errors with meaningful context (what failed, what input caused it, how to fix it).
- Errors are part of the API contract.
- Validate inputs at system boundaries. Fail fast on invalid data.
- Distinguish between recoverable errors and fatal exceptions.
- Never silently coerce or fix invalid input. Reject it with a clear message.

```python
# BAD
try:
    result = do_something()
except:
    pass

# GOOD
try:
    result = do_something()
except ValidationError as e:
    logger.warning("Validation failed", extra={"error": str(e), "field": e.field})
    raise DomainError(f"Invalid input: {e.field}") from e
```

### Exception Chaining (`raise ... from`)

Always be explicit when re-raising a caught exception. Never rely on implicit chaining (a bare `raise NewError(...)` after an `except ... as e`).

| Form | Use when |
|------|----------|
| `raise NewError(...) from e` | The original exception adds diagnostic value across a layer boundary (e.g. translating an HTTP-client error into a domain error). Preserves `__cause__` and the original traceback. |
| `raise NewError(...) from None` | Converting to a user-facing error (e.g. an HTTP response) where the original cause would leak internal details or add noise. Suppresses the original traceback entirely. |
| `raise NewError(...)` (bare) | Outside an `except` block, a bare raise is fine because there is no caught exception to chain. Inside an `except` block, a bare raise is almost never intended, because implicit chaining surfaces "During handling of the above exception, another exception occurred". Pick `from e` or `from None` deliberately. |

Decision guide (only applies when the `raise` is **inside** an `except ... as e` block):

1. Does the new exception's message already capture everything useful from the cause, and would the cause's traceback leak internals? Use `from None`.
2. Is this an abstraction boundary translating infra errors into domain errors? Use `from e` to preserve the cause, unless the low-level type/traceback exposes internals.
3. Is the new exception a programming/precondition error (e.g. `ValueError` for bad input) where the caught exception is irrelevant noise? Use `from None`.
4. Do not both embed the cause's text in the new message and chain with `from e`, because that prints the cause three times (message, `__cause__` text, traceback). Pick one: chain with `from e` and let the traceback speak for itself, or fold the cause into the message and use `from None`.

## Security

- Sanitize and validate all user and external inputs at the boundary.
- Never trust data from outside the system boundary.
- Use allowlists, not denylists. Reject by default, accept only known-good patterns.
- Use schema validation libraries (Pydantic, zod, JSON Schema), and do not hand-roll validation for complex structures.
- Keep secrets out of code. Use environment variables or secret managers.
- No hardcoded API keys, tokens, or passwords.
- SQL queries use parameterized statements, never string concatenation.
- Enforce access control on every new resource. Grant permissions granularly (least privilege). Do not make features universally accessible. Re-check access rules when touching existing resources.
- Do not expose internal details in error messages to end users.
- Validate on the server side always, because client-side validation is a UX convenience, not a security measure.
- Use fake or anonymized data in tests, never real user data.

## Observability

### Logging

- Use structured logging (key-value / JSON), not formatted strings.
- When structured logging is not available (plain-text logs), use the logger's lazy formatting (`logger.info("Order %s created", order.name)`) instead of f-strings or `%` interpolation, so the message is only formatted when actually emitted.
- Log at key decision points and boundaries, not inside tight loops.
- Include: operation name, relevant IDs, outcome (success/failure), duration if relevant.
- Use consistent field names across the entire codebase.

### Log an Exception at Exactly One Layer

A given exception should be logged by exactly **one** handler: the layer that **terminates** its lifecycle (it swallows the exception, converts it to a domain error that callers act on, or translates it into an HTTP response). Every other layer that touches it must either re-raise silently or transform it without logging.

| Situation | Action |
|-----------|--------|
| You **swallow** the exception (catch and continue, return a fallback, return a result object) | **Log it**: no caller will see it, so this is your last chance. |
| You **re-raise** (bare `raise`, or `raise NewError(...) from e`) | **Do not log**: let the next handler own the log. |
| You are at the **top boundary** (HTTP handler, SSE stream, lifespan) and convert to a response | **Log it**: this is the terminal handler. |
| You are an **intermediate layer** translating infra errors into domain errors | **Do not log**: chain with `from e` and let the boundary log. |

- `logger.exception(...)` immediately followed by `raise` is a smell, because it duplicates the traceback at the next handler that also logs. Use it only when you are certain no upstream handler will log (e.g. the top boundary).
- When logging at a re-raise site is unavoidable (e.g. during startup, where the framework will also log), accept the minor duplication. Outside those rare spots, keep the one-log-per-exception rule strict.

### Log Levels

| Level | When to Use |
|-------|-------------|
| **ERROR** | Something is broken and needs human attention |
| **WARN** | Degraded but self-recoverable |
| **INFO** | Significant business events |
| **DEBUG** | Diagnostic detail, off in production |

### PII in Logs (Zero Tolerance)

- **NEVER** log: email addresses, user names, phone numbers, physical addresses, tokens, passwords.
- **Approved identifiers**: only the project's approved identifier set (e.g. `user_id`). <!-- fill in the project's identifier names -->
- No `print()` or `console.log()` with user data, since these go to production logs.

## Testing

> **Test code is production code.** It receives the same care, review, and quality standards.

### Core Principles

- Write unit tests for all core logic.
- Write integration tests for all API endpoints and external integrations.
- Distribute tests as a pyramid: many fast unit tests at the base, focused integration tests at service and external boundaries, and only a few end-to-end tests for critical user journeys.
- Follow Arrange-Act-Assert (AAA) structure. ONE act per test, ONE logical assertion per test.
- Tests MUST be independent, deterministic, and not depend on execution order.
- Mock or fake all external dependencies (DB, APIs, filesystem, time, randomness). Never hit real external services in tests.
- Test behavior through public APIs rather than calling private/internal methods directly. Preserve meaningful branch coverage while minimizing coupling to implementation details.
- When a mock must raise, have it raise a concrete type (the domain error the real code would raise), not a bare or generic `Exception`. Likewise, raise-assertions (e.g. `pytest.raises`) must pin the *specific* exception type the production code is expected to raise, so a regression that raises a different (broader) error is caught.
- Use the test commands documented in this file for the touched modules. Do not invent new test commands.

### How to Run Tests

<!-- Record the project's canonical test command(s) here. Agents and reviewers run them on the touched modules. -->

```bash
# Example (replace with the project's command)
uv run pytest tests/services -v
```

### Test Naming

Every test function MUST start with the project's test prefix (pytest only collects functions named `test_`).

Choose the pattern that matches the test:

| Pattern | When to use | Example |
|---------|-------------|---------|
| `test_[subject]_[aspect]` | **Default.** Name the thing under test, then the scenario or outcome. Most behavior tests. | `test_login_endpoint_invalid_credentials`, `test_provider_matching_case_insensitive` |
| `test_[behavior]` | One descriptive phrase for pure behavior/state checks where splitting into subject + aspect adds no value. | `test_collection_name_generation`, `test_all_expected_routes_exist` |

Rules that apply to all patterns:

- Prefer the split form when there is a clear subject and a distinguishable aspect (an input variant, an error state, a missing field, an empty collection). Use the single-phrase form only when splitting would be artificial.
- Keep names concise and readable, and prefer `_not_found` over `_doesnt_exist`. Do not pad names with `should`/`when` ceremony.
- Do not encode the assertion type or the fixture names in the test name.
- Group tests with a `class TestXxx` whose name matches the unit under test.

### Tests Must Also Challenge the Code, Not Only Confirm It

**Happy path tests are the foundation**, because they validate the code works under normal conditions. Always start with these.

**But happy path tests ALONE are not enough.** You MUST also write adversarial tests that actively try to break the code and find defects:

- Unexpected input types: `None`, `""`, `[]`, `{}`, `0`, `-1`
- Boundary values: max int, max length, exactly at the limit, one past the limit
- Malformed data: missing fields, extra fields, wrong types, invalid formats
- Error states: what happens when dependencies fail?
- What should NOT happen: verify that forbidden states are correctly rejected
- Error messages and types: not just that it fails, but *how* it fails

**Write tests based on REQUIREMENTS/SPEC, not on what the source code currently does.** This is how you catch bugs where the code diverges from expected behavior.

**When a test fails:** first ask if the CODE is wrong, not the test. Do NOT silently change a failing assertion to match the current code without understanding WHY.

### Test File Rules

- Split test files by logical separation, not by an arbitrary line count. One file per unit, module, or service is fine even at 800+ lines, and unrelated behaviors belong in separate files.
- Keep the Arrange part of each test small. When one test's setup grows past ~20 lines, extract it into helpers or factories.

### Coverage

- **Minimum acceptable: 75%.** Below it, the task is not complete. <!-- choose the project's minimum -->
- Focus on **branch coverage** (both sides of `if/else`, all `catch` blocks), not just line coverage.
- High coverage with no assertions is worthless. Every test MUST have at least one meaningful assertion.
- Coverage must be **run and shown** at the end for ALL created tests.

```bash
# Python
pytest tests/your_tests.py --cov=src/module_under_test --cov-report=term-missing --cov-branch -v

# JavaScript/TypeScript (Jest)
npx jest tests/your_tests.test.ts --coverage --collectCoverageFrom="src/module/**/*.{ts,tsx}"

# JavaScript/TypeScript (Vitest)
npx vitest run tests/your_tests.test.ts --coverage
```

### All Created Tests MUST Pass

- Every test you create or modify MUST pass. Zero failures, zero skips.
- Never disable, skip, or delete a test to hide a failure.
- Never leave a test "to fix later". Fix it now.
- If coverage is below the agreed minimum: write more tests, re-run, repeat until the minimum is met.

### What NOT to Test

- Simple getters, setters, and trivial mappers are not worth testing.
- Implementation details such as method call order or internal state. Test behavior instead.
- Do not inflate coverage with meaningless assertions.

### Anti-Patterns (Forbidden)

| Pattern | Problem |
|---------|---------|
| **The Liar** | Test passes but doesn't verify the behavior it claims to test |
| **The Mirror** | Test reads the source code and asserts exactly what the code does, so it finds zero bugs |
| **The Giant** | 50+ lines of setup, multiple acts, and dozens of assertions. Should be 5+ separate tests |
| **The Mockery** | So many mocks that the test only tests the mock setup |
| **The Inspector** | Coupled to implementation details, breaks on any refactor |
| **The Chain Gang** | Tests depend on execution order or share mutable state |
| **The Flaky** | Sometimes passes, sometimes fails with no code changes |

## Migrations (when the project has database migrations)

<!-- Delete this section if not applicable. Document the framework's specifics (migration phases, version allocation) here, with a link to the authoritative doc. -->

- Every migration script MUST be idempotent: safe to run more than once on the same database without corrupting data or raising errors. A repeated run must be a no-op or a guarded pass, never a crash or a data-duplicating write.
- DELETE/UPDATE by a stable key (a unique business key, or the framework's stable record identifier), never by shifting row ids/ranges.
- Guard DDL and back-fills with existence checks (`IF EXISTS` / `IF NOT EXISTS`, column/table existence checks) so a repeated run, or a database at a different schema point, does not crash.
- Do not assume legacy columns/tables exist: existence-check reads and DDL against a possibly-different schema, or derive back-fill data from surviving columns.
- Make best-effort statements isolated so one failing statement cannot abort the whole migration transaction. On engines that abort a transaction on any statement error, wrap each best-effort statement in a savepoint and catch the re-raised error. A savepoint undoes only the work done since it was set, which keeps the transaction alive and the rest of the migration runnable.
- State which phases the framework runs in which order (e.g. schema vs data, pre vs post migration) and what each phase can and cannot touch.

## Code Review

### Priority (blockers first)

1. **Security & PII**: no PII in logs, no hardcoded secrets, input validation
2. **DRY**: no duplicate types, classes, functions, or logic
3. **File Structure**: single responsibility per file, naming respected
4. **Architecture**: single responsibility, proper layer separation
5. **Code Quality**: SOLID, strong typing, error handling
6. **Testing**: both happy path and adversarial tests, coverage met
7. **Observability**: structured logging, no PII

### Review Questions for Tests

1. "Are there BOTH happy path AND adversarial tests?"
2. "Would these tests catch a regression if someone broke the logic?"
3. "Are there edge cases or failure modes that aren't being tested?"
4. "If I remove a line of business logic, will at least one test fail?"

### Legacy Code

- Do NOT prolong bad patterns. Even if the surrounding code is bad, write good code.
- Do NOT copy-paste from legacy code without reviewing quality.
- Isolate new code from legacy where possible.

## Documentation

Update `README.md` when you add new features, endpoints, or significant changes. Update this file (`AGENTS.md`) when you add new modules, classes, or change architecture. Both `README.md` and `AGENTS.md` must be kept in sync with the codebase.

## Key Concepts

> This section is a reference for AI agents to understand the domain and architecture of the project.
> You should update this section whenever you add or change key concepts, modules, or architecture.
> This section must be kept in sync with the codebase.

<!-- Record the concepts an agent must understand to work safely in this codebase: startup/lifecycle order, request and data flow, ownership boundaries, external integration contracts, and similar. Use numbered per-concept subsections with references to the relevant files. -->

## Rule of Thumb

**When in doubt, choose simplicity. When trade-offs arise, follow the priority order in [Core Philosophy](#core-philosophy).**
**Build for correctness first. Optimize later. Test always.**
