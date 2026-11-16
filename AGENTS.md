# Agent guide

This project tracks work as Org cards managed by the `c` CLI. Cards live at
`notes/C<ID>/index.org`; run `c --help` for every command.

## Work loop

1. `c next` shows started work and the ready queue.
2. `c ID` reads a card; review its scope and gate before starting.
3. `c set ID started` starts the card.
4. Work its open task headings in order and keep notes under them; close a
   task heading with `c todo FILE ORG-ID DONE`.
5. `c set ID done --note RESULT` closes the card with its result.

Record new or unrelated work with `c new TITLE --origin TEXT` instead of
expanding the current card. Run `c check` before committing card or lane files.

## Project conventions

- There is one lane, `main`, entered through `notes/main/index.org`.
- Cards are the source of planned and in-flight work. Do not start new
  handoff documents under `notes/handoffs/`; file a card instead.
- Put the card ID in commit messages (for example `C3: bump amazonka`) so
  `c related ID commits` finds them.
- A card's long write-ups (reviews, audits, research) go beside it as
  `notes/C<ID>/report--<slug>.org` and are linked from the task that produced
  them.
- Coding standards, testing, build and git rules live in `CLAUDE.md` and
  apply to all card work.
