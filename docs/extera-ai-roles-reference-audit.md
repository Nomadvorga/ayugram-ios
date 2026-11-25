# AI roles, providers and defaults: reference audit

Reference: exteraGram Android commit
`b4d852f48f2734a0bee1a74a0939be621612262a` in
`C:\Users\PC\exteragram-reference`. Files were read directly with `git show`
because the checkout is sparse. A bulk archive failed while fetching a promisor
object; the files used below were individually readable. No Android file changed.

All exact images `photo_N_2026-11-25_21-26-04.jpg`, N = 40…47, in
`C:\Users\PC\Downloads\Telegram Desktop` were visually opened. Frame 39 was also
opened for the AI home context. The unrelated Sigilforge instructions stored
beside those images do not govern this iOS implementation.

| Frame | Visible content | Implication for this wave |
| --- | --- | --- |
| 40 | AI Chat: Telegram Editor and Summaries on, streaming on, response-only off, quote on, temperature 1.0 with 0.0…2.0 bounds | Check consumers/defaults against source; screenshot toggle values alone do not prove defaults. |
| 41 | Calculation results: feature switches, grouping, angle/currency/unit settings | Not an AI-role screen. |
| 42 | Calculation results: collapsed capabilities and settings | Not an AI-role screen. |
| 43 | Calculation results: expanded arithmetic examples | Not an AI-role screen. |
| 44 | Calculation results: expanded math/number-base examples | Not an AI-role screen. |
| 45 | Calculation results: percentages, abbreviations and currency examples | Not an AI-role screen. |
| 46 | Calculation results: units and duration examples | Not an AI-role screen. |
| 47 | Calculation results: time-zone examples | Not an AI-role screen. |

There is no role editor screenshot in 40…47. The roles implementation is audited
against actual Android source, not inferred from the calculation examples.

| Android source under `TMessagesProj/src/main/java/com/exteragram/messenger/ai/` | Finding and iOS implementation |
| --- | --- |
| `data/Suggestions.java` | Three immutable suggestions: Assistant, Summarizer, Proofreader. Exact names/instructions are in `ExteraAIRole.suggestions`; fresh configuration selects Assistant and stores no custom roles. |
| `ui/activities/RolesActivity.kt` | Separate Suggestions/custom groups; preview suggestions, custom create/edit/copy/delete, independent selection; name limit 64 and prompt limit 1024. iOS supplies these actions through native lists/editor; UTF-16 limits match Android text length. Deleting the active custom role returns to Assistant. |
| `data/Role.java`, `AiController.java` | Android identifies duplicate roles by exact name, selects by name and falls back to Assistant. iOS rejects new duplicate/reserved names and uses stable IDs so renaming preserves selection. Previously saved v1 roles retain every ID/name/prompt; reserved legacy names may be retained while editing their existing role. |
| `AiConfig.kt` | History/streaming true, response-only false, quote true, temperature 10/10; editor/summaries default to `!isPremium`. Missing editor preference is now optional; explicit persisted booleans survive. All native editor consumers resolve against the current account. |
| `ui/activities/EditServiceActivity.kt` | Gemini `gemini-3.5-flash`, OpenAI `gpt-5.4-mini`, OpenRouter `openai/gpt-5.4-mini`, Perplexity agent `perplexity/glm-5.3-flash`, Custom. iOS presets match URL/model/order and retain manual model entry and discovery. Test and Save persists only a successful immutable draft. |
| `ui/activities/ServicesActivity.kt`, `AiController.java` | Service selection, editing, deletion; Android also exposes AICore on-device management. Existing iOS REST service editing remains; no fake AICore toggle is introduced. |
| `network/backend/RestBackend.java` | Fixed 4096-token output, history 32 messages/24000 chars, temperature 0…2. No adjustable max-token preference exists. Requests retain API-specific budget keys and isolated role/history handling. |
| `network/backend/RestBackend.java` | Reasoning policy depends on exact host/model: OpenRouter none; supported GPT/o and Gemini generations use source-defined none/minimal/low; Perplexity sets minimal only for supported GPT/Gemini models. Unknown Responses providers get no unsolicited reasoning field. Explicit 400/422 reasoning errors advance none→minimal→low→omitted; finite retries preserve prompt/role/budget. |
| `ui/activities/AiPreferencesActivity.kt` | Services/Roles/History destinations plus generation/temperature controls. Existing iOS settings root route already opens the AI home. |

The previous iOS four starter roles were ordinary mutable persisted objects.
They cannot safely be replaced by new defaults: users could have edited them.
Decoding preserves them verbatim in the custom group. A legacy document with a
roles array and omitted selectedRoleId means the previous no-role choice; it is
preserved. New writes encode null explicitly for that choice. Unknown non-null
role IDs resolve to Assistant, while selection actions reject a stale ID. Failed
role mutations throw before configuration publication. Existing long legacy
instructions remain usable; saving an edit requires the new 1024-unit limit and
does not silently truncate the original.

No embedded/provider/server API key was added. iOS still starts with no configured
REST service. Android's default Gemini object has a null key, and Android blocks
REST availability/save without a key. iOS intentionally retains its working
custom-server path with an empty key, omitting Authorization; configured paid
providers return their own authentication errors without fallback. Keychain
access and backup privacy boundaries remain in place.

This closes the audited role catalog/CRUD/default/request gaps at source level;
it does not establish complete Android or pixel parity. Remaining differences:
Android custom-emoji role artwork/picker and on-device AICore backend are absent;
clipboard service triplet import/export remains unimplemented (individual native
fields support paste); iOS retains explicit no-role, separate Test/Save, model
discovery, strict URL validation and account-isolated bounded history. These are
recorded differences, not platform-tested exceptions or proof of 1:1 completion.
The calculation screens are owned by their separate implementation.

Validation artifacts and exact commands: `Tests/ExteraAI/README.md`,
`root-integration.md`, `strings-handoff.json`, `root-backup.patch`,
`changed-manifest.json`. Host tests cover real production configuration and
URLProtocol payloads. Eleven files parse cleanly; the additional TextProcessingScreen
file has one exact tree-sitter diagnostic unchanged from HEAD at `playOnce.invoke(())`.
The checker reports that baseline explicitly. Swift compilation, XCTest,
UIKit interactions and recorded-frame evidence remain unavailable here.
