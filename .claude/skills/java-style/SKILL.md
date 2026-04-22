---
name: java-style
description: Andrew's personal Java and Kotlin style rules — linter hygiene, Guava/Apache Commons bias, test access patterns, constant and import conventions. Complementary to (not overlapping with) the Netflix-generic java-context skill.
when_to_use: When writing, editing, or reviewing Java or Kotlin source files. When deciding between Guava/Apache Commons vs. hand-rolled helpers. When adding a test that needs access to a private method. When importing a constant from an inner class or enum.
version: 1.0.0
languages: java, kotlin
---

# Java Style

## Overview

Personal style rules beyond what a linter catches. Apply alongside the Netflix-generic java-context skill — these don't replace it.

## Imports

- **No wildcard imports.** Ever.
- **No shaded imports without asking Andrew first.** Shaded imports typically have "shade" or "shaded" in the package path — they're repackaged copies of a dependency and cause subtle classpath issues.
- **Import inner classes for constants.** When pulling a constant from an inner class or enum, import the inner class itself so the code reads `Inner.CONSTANT` rather than `Outer.Inner.CONSTANT`.
- **Static-import sufficiently descriptive constants.** `SomeClass.NUMBER_OF_COWS` should get a static import. If static-importing would create ambiguity (e.g., `NUM` and `NUMBER` both get pulled in and the reader can't tell which is which), skip the static import.

## Test access

When a test needs a private method, don't use reflection. Instead:

1. Relax the method to package-private.
2. Annotate with `@VisibleForTesting`.
3. Put the test in the same package as the class.

Reflection-based tests are brittle and obscure intent.

## Collections

- **Bias toward Guava Immutable collections** for read-heavy patterns (`ImmutableList`, `ImmutableMap`, `ImmutableSet`). Signals intent and prevents accidental mutation.
- **Pre-size collections** when the expected size is reasonably determinable: `Lists.newArrayListWithCapacity(n)`, `Maps.newHashMapWithExpectedSize(n)`, `Sets.newHashSetWithExpectedSize(n)`. Avoids resize churn.

## Use Guava and Apache Commons

Don't hand-roll helpers for things Guava or Apache Commons already provide. Check before writing. `@Beta` methods in Guava are acceptable as long as there are no known CVEs against them.

Examples: `Strings.isNullOrEmpty`, `Preconditions.checkArgument`, `Iterables.getFirst`, `StringUtils.isBlank`, `CollectionUtils.isEmpty`.

## Constants

- **Create a named constant** for any value used more than once in the same class — even simple numerics or strings. Easier to change, easier to grep.
- **Constants in `ALL_CAPS_WITH_UNDERSCORES`.**

## Relationship to java-context

`java-context` covers Netflix-generic Java setup (Gradle/Nebula, Spring Boot Netflix, DGS, gRPC, JUnit/Mockito/AssertJ, test slices, Newt app types). This skill covers Andrew's personal preferences on top. When they conflict, ask Andrew.
