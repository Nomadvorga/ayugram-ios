# Double-tap action dialog and message menu

Source references: frame 85 (incoming action dialog), frames 53/56/57 (7-child
message-menu group and grouping notice), and Android
`preferences/chats/ChatsPreferencesActivity.kt:198–209`, `SwitchGroup.kt:101–150`.

The incoming dialog has exactly ten actions, in reference order: Disabled,
Reactions, Reply, Copy, Forward, Save, Repeat, Delete, Translate, Read. It excludes
inherit/edit. The outgoing dialog excludes Read and retains its persisted native
inherit/edit options. Both use a centered card with leading glyphs and a separate
trailing Cancel button. Tall text and landscape use a scrolling action region;
Cancel remains outside that region. Selection persists only after a row tap;
Cancel, backdrop and accessibility escape do not write preferences. The
accessibility selected trait identifies the current effective action.

The current dialog uses SF glyphs as fallbacks. Exact Android artwork and custom
UI pack integration remain pending the expanded icon-provider checkpoint.

Message Menu now counts the seven base Android actions. Export Message as Image
remains a separate working preference and is not changed by the seven-child
master. Optional Android AI Generate is not shown without a functional consumer.
SwitchGroup source confirms `enabled > 0` for the master and setting all visible
children together on a master tap; it does not restore a former mixed selection.

Grouping reuses the already permission-filtered native Reply/Delete/Copy/Edit/
Link/Forward actions and adds their horizontal row at the bottom. It keeps
informational content, deferred destructive rows and other native actions intact.
The English/Russian label and notice describe this actual behavior.

## Required recording and acceptance (not yet executed)

Before recording, expect a centered card to fade together with its title, glyphs,
rows and Cancel; no item may slide independently, appear twice, wrap mid-flight
or clip against a rounded corner. UIKit cross-dissolve should settle in roughly
0.3 s, with no spring or overshoot. The dimmer must cover the whole screen.
Closing must reverse the fade without a blank card frame. Opening and cancelling
must preserve the selected value. Choosing Read must enter the explicit receipt
flow only on a later qualifying incoming-message double tap.

Record incoming/outgoing open, selection and Cancel, backdrop and accessibility
escape; light/dark, portrait/landscape and large text. Record grouped/ungrouped
menus for a text message, photo, protected message and restricted peer. The main
action row must be below every other action; no permission-denied action may
appear after regrouping. Reopen settings to check 3/7 and independent image export.

Use `simctl io recordVideo` and `tools/animation_sheet.py`; evaluate labelled
frame sheets with indices/timestamps, including every flagged gap/jump. No runtime,
visual, animation or device-performance acceptance is claimed by this document.
