# UI mock — preserved design baseline

- Open [index.html](index.html) for the standalone interactive Mac/iPhone preview.
- Edit [manga-ui.fragment.html](manga-ui.fragment.html), the original design source preserved from the conversation on 2026-10-13.
- Regenerate the preview from repository root: `python3 scripts/export-mock.py`.
- The preview shell bundles its renderer/icon assets and runs the fragment in a sandboxed frame. It makes no auth, NAS, database or Ollama requests; interaction state is local mock state.

The original mock uses Chinese interface labels from the earlier design rounds. The latest product requirement is **English by default**, implemented in the native app and documented in the UI spec. We preserve the reference source rather than silently rewrite approved designs. Future design edits should update the fragment, regenerate `index.html`, and record changed requirements/status.

The mock depicts the full intended product, including unfinished screens. It is not embedded in either native app and is not an implementation readiness claim. iPhone management controls were removed in the later mock revisions; native iPhone remains a viewing/download companion.

Canonical interaction/page requirements: [Apple UI spec](../apple/ui-spec.md). Actual native coverage: [implementation status](../implementation-status.md).
