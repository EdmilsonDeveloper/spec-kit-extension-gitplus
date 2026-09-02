<!--
  git-typed-branch wrap of /speckit-specify. Keeps the full core workflow (embedded
  at the placeholder below) but pins the spec directory to the branch created by the
  before_specify git hook, so branch and spec share the exact same <number>-<slug>.
  This matters under timestamp numbering: if /specify recomputed the number on its
  own, its timestamp would land seconds after the branch's and the two would not
  match. (Do not write the core placeholder token in this comment — the renderer
  would expand it here too.)
-->

## Spec directory — mirror the feature branch (this rule overrides core numbering)

Do this BEFORE following the core workflow below:

- If a `before_specify` git hook created a branch on this turn (it printed
  `BRANCH_NAME`), set
  `SPECIFY_FEATURE_DIRECTORY = specs/<final "/"-separated segment of BRANCH_NAME>`.
  That final segment is `<number>-<slug>` — use it verbatim as the spec directory
  name (e.g. branch `edmilson/fix/20260902-143022-corrige-carga-xp`
  → `specs/20260902-143022-corrige-carga-xp`).
- In the core workflow's directory-resolution step, do **NOT** compute a new
  sequential/timestamp number: the value above wins.
- If there was no `before_specify` hook / no `BRANCH_NAME` this turn, ignore this
  note and use the core behavior unchanged.

{CORE_TEMPLATE}
