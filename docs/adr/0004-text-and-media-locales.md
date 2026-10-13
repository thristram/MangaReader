# ADR 0004 — Separate localized text from media variants

Status: Accepted · 2026-10-13

## Context

The same images/video can have several titles/descriptions. Translating a few fields must not create empty language directories or duplicate media. Actual translated images may have different page order/count.

## Decision

Store field-level `localizations[locale]` independently of `media[]` version UUIDs/languages/path order and alignment. Interface default is English; content preference defaults Chinese. Text fallback is per field. Media selection prefers requested language, then original, then available. Filesystem language folders are based only on number of actual media languages.

## Consequences

Ollama metadata translation writes locale text only. Partial translations preserve original fallback and can be regenerated. Media alignment and full image translation require distinct workflows. Localized UI strings do not redefine filenames or storage versions.
