Make sure there is a claude.md. If there isn't, exit this prompt, and instruct the user to run /init

If there is, add the following info:

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
- When importing a constant from an inner class or enum, import the inner class to avoid having to specify `Outer.Inner.CONSTANT` (thereby preferring `Inner.CONSTANT`).
- When a constant is sufficiently descriptive, use a static import for the constant. For example, `SomeClass.NUMBER_OF_COWS` should get a static import. If this creates ambiguity (e.g. results in `NUM` and `NUMBER` be imported, which are both confusing and insufficiently descriptive, do not use a static import).
- Bias towards creating constants, especially if the constant is used multiple times in the same class.

Workflow stuff:

- if there is a todo.md, then check off any work you have completed.

Tests:

- Make sure testing always passes before the task is done

Linting:

- Make sure linting passes before the task is done
