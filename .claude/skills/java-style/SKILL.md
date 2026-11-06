---
name: java-style
description: Andrew's personal Java and Kotlin style rules — linter hygiene, Guava/Apache Commons bias, test access patterns, constant and import conventions. Additive to the generic java-context skill.
when_to_use: When writing, editing, or reviewing Java or Kotlin source files, or Gradle build scripts (Groovy or Kotlin DSL). When deciding between Guava/Apache Commons vs. hand-rolled helpers. When adding a test that needs access to a private method. When importing a constant from an inner class or enum.
version: 1.0.0
languages: java, kotlin, groovy
---

# Java Style

## Overview

Personal style rules beyond what a linter catches; additive to the generic java-context skill.

## Nullness (JSR-305)

All of our Java code declares nullness via JSR-305 annotations (`javax.annotation.Nonnull`/`@Nullable`, often package-wide via `@ParametersAreNonnullByDefault`). Trust them:

- Do NOT add defensive null checks, ternary null guards, or null-to-exception mappings for annotated-non-null members — even when calling external/untrusted producers (Hollow feeds, gRPC clients). A producer that violates its own annotation fails loudly (NPE) by design; don't guard for it.
- Add null checks only where the API declares `@Nullable` (or documents null as possible without an annotation).
- SpotBugs `RCN_REDUNDANT_NULLCHECK_OF_NONNULL_VALUE` is a real finding under this convention: remove the check; do not add `@SuppressFBWarnings`.
- Never write tests that violate a declared nullness contract (passing `null` to a `@Nonnull` parameter, stubbing a non-null getter to return null). Such tests pin out-of-contract behavior; raise with Andrew before removing any test.

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

`java-context` covers generic Java project setup (Gradle/Nebula, Spring Boot Netflix, DGS, gRPC, JUnit/Mockito/AssertJ, test slices, Newt app types). This skill covers Andrew's personal rules on top. When they conflict, ask Andrew.
