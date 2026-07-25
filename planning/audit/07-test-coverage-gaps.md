# Test Coverage Gaps

Reconciled 2026-07-25 (second pass). **No open findings.**

T-1 through T-10 are all implemented and verified. The suite stands at 107
Elixir tests plus 21 worker JS tests. The final item, T-10's threshold pin,
landed with the D-6 strict-floor decision: worker tests assert 499 cleaned
characters → `no_content` (`content_text_shorter_than_500`) and 500 → `ok`
(`sufficient_content`) at the default minimum.

## Guardrail pointers for future work

- The C-6 lineage now has two history-preservation tests
  (`digestion_pipeline_test.exs`): passive advancement and explicit
  re-request. Any future change to `ensure_item_step`/`advance_item`
  semantics should keep both green.
- Refresh-coalescing behavior is pinned in `processing_test.exs` and
  `output_feed_test.exs` (burst → one queued refresh). New LiveViews that
  subscribe to `:processing_changed` should copy the pattern and the test.
- R-9's corrupt-pipeline-definition test (`pipeline_output_feed_test.exs`)
  doubles as the template for asserting "no silent failure" on future
  publish-path error handling.
