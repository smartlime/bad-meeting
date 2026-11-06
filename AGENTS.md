# Interface copy

Do not add explanatory interface hints unless the user explicitly requests them.

# Interface controls

- Pair every numeric setting with a digits-only text field and a stepper. Keep both controls synchronized and enforce the setting's range when editing ends.
- Show the pointing-hand cursor over every hyperlink, including links embedded in selectable text. Keep the ordinary text cursor outside link ranges.
- Use small secondary-colored text and a small chevron for expand/collapse controls. Do not style these controls as hyperlinks.
- Keep the application bundle named `Bad Meeting.app` at `desktop/macos/dist/Bad Meeting.app`. Replace that bundle for local updates and preserve the `/Applications/Bad Meeting.app` symlink. Do not create separately named app copies.

# Git workflow and versions

Explicitly enable the `aiw-git` skill for all Git, versioning, and release work throughout this project. Read its `SKILL.md` when available. This project instruction is a standing explicit invocation, not permission to publish or release. The application and its build must not require aiw or an installed agent skill.

The following project rules also apply when the skill is unavailable:

- Develop in `feat/<name>` branches based on `dev`; merge completed and validated work into `dev`. Large initiatives may use `epic/<name>` as an intermediate integration branch.
- Keep `main` for releases promoted from `dev`. Do not commit ordinary development directly to `dev` or `main`. Integrate release metadata back into `dev`.
- Write commit and merge messages in Russian using completed-action wording. Use `fix: Исправлено...` for corrective subjects; enhancement subjects have no mandatory prefix. Detailed change lists use `new: Добавлено...` and `fix: Исправлено...`. Derive merge descriptions and release notes from the final diff. The user reviews release notes before publication.
- The public foundation and its private extension edition share `X.Y` in `X.Y.Z`. `Z` is each repository's independent build number. A build increment in one repository does not require an increment in the other. Coordinate changes to `X` or `Y` across both repositories; do not change them without an agreed version-line decision.
- Pin the private edition to an exact foundation revision during development and an exact released foundation version/revision for releases. Verify matching `X.Y` and test the actual pairing; matching numbers alone do not establish compatibility.
- Keep private implementations, endpoints, settings, and history out of every public branch. Review all outgoing commits and publication metadata. Keep temporary results and secrets out of commits.
- Skill activation does not authorize commits, merges, pushes, or releases beyond the user's request. Honor explicitly requested review gates.
