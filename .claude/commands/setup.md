Make sure there is a claude.md. If there isn't, exit this prompt, and instruct the user to run /init

If there is, add the following info:

Python stuff:

- we use uv for python package management
- you don't need to use a requirements.txt
- run a script by `uv run <script.py>`
- add packages by `uv add <package>`
- packages are stored in pyproject.toml

Java stuff:

- When writing tests, avoid using reflection to access private methods. Make the method package private, annotate with @VisibleForTesting, and make sure the test is in the same package as the class.
- Understand the context of how Collections are being used; if it's a read-heavy pattern, bias toward Guava Immutable collections.

Workflow stuff:

- if there is a todo.md, then check off any work you have completed.

Tests:

- Make sure testing always passes before the task is done

Linting:

- Make sure linting passes before the task is done
