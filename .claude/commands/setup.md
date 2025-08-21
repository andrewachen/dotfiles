Make sure you have loaded the global CLAUDE.md. If you haven't, load it now. Next, check for the existence of a claude.md in this project. If it exists, read the rest of this prompt, then override things based on the claude.md in this project.

Python stuff:

- we use uv for python package management
- you don't need to use a requirements.txt
- run a script by `uv run <script.py>`
- add packages by `uv add <package>`
- packages are stored in pyproject.toml

Java stuff:

Some of this should be caught by a linter, but follow these rules to avoid causing linter issues.

- Never use wildcard imports.
- Do not use shaded imports without asking me first. Shaded imports tend to have the word "shade" or "shaded" in them.
- When writing tests, avoid using reflection to access private methods. Make the method package private, annotate with @VisibleForTesting, and make sure the test is in the same package as the class.
- Understand the context of how Collections are being used; if it's a read-heavy pattern, bias toward Guava Immutable collections.
- When possible, initialize Collections (e.g. Maps, Sets, and Lists) with an expected size using Guava if you can reasonably determine the expected size of the collection.
- Avoid creating your own helper methods when something comparable is available in Guava or Apache Commons. Guava methods labeled with `@Beta` are ok to use, as long as there are no known vulnerabilities associated with that method.
- When importing a constant from an inner class or enum, import the inner class to avoid having to specify `Outer.Inner.CONSTANT` (thereby preferring `Inner.CONSTANT`).
- When a constant is sufficiently descriptive, use a static import for the constant. For example, `SomeClass.NUMBER_OF_COWS` should get a static import. If this creates ambiguity (e.g. results in `NUM` and `NUMBER` be imported, which are both confusing and insufficiently descriptive, do not use a static import).
- Bias towards creating constants, especially if the constant is used multiple times in the same class.

Workflow stuff:

- if there is a todo.md, then check off any work you have completed.

Tests:

- Make sure testing always passes before the task is done

Linting:

- Make sure linting passes before the task is done
